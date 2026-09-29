import 'dart:typed_data';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:publication_protocol/publication_protocol.dart';

import '../services/p2p_auto_publish_launcher.dart';
import '../services/worker_backend.dart';

/// The backend owns queue selection; the idle listener only signals availability.
/// Firestore transactions fence callbacks by request, attempt and worker process.
class DownloadedAttachment {
  final Uint8List bytes;
  final String? generation;
  DownloadedAttachment(this.bytes, this.generation);
}

class FirebaseChatReceiver {
  final FirebaseFirestore _firestore;
  final String deviceId;
  final Stream<String?>? ownerChanges;
  final Future<DownloadedAttachment> Function(String)? downloadAttachment;
  final Future<Directory> Function()? mediaDirectory;
  final Future<bool> Function(Map<String, String>, PublicationIdentity)? launch;
  final Future<Map<String, dynamic>?> Function(String workerRunId)? claimNext;
  // Diagnostics used to verify that unrelated documents never wake the worker.
  final void Function(String event)? onActivity;
  String? _watchedRequestId;
  bool _paused = false;
  Map<String, String>? _preparedVehicle;
  Future<void> poll() => _requestTick();
  late final String _runId;
  static FirebaseChatReceiver? _instance;
  StreamSubscription? _authSub, _requestsSub, _queueSub;
  String? _queueOwner;
  Timer? _timer, _recoveryTimer, _retryTimer;
  Future<void>? _tickTask;
  bool _tickAgain = false, _maintenancePending = false;
  DateTime? _reportedExpiry;
  Future<void> _serial = Future.value();
  PublicationIdentity? _active, _takeoverPausedIdentity;
  String? _uid, _activeOwnerUid;
  bool _disposed = false;
  bool _recovered = false;
  DateTime? _leaseExpiry;
  Future<void> Function()? _pause;
  VoidCallback? _resume;
  Future<void> Function()? _stop;
  Object? _controlOwner;
  final List<Future<void> Function()> _pendingReports = [];

  FirebaseChatReceiver({
    FirebaseFirestore? firestore,
    required this.deviceId,
    this.ownerChanges,
    this.downloadAttachment,
    this.mediaDirectory,
    this.launch,
    this.claimNext,
    this.onActivity,
  }) : _firestore = firestore ?? FirebaseFirestore.instance {
    _runId = _firestore.collection('_ids').doc().id;
    _instance = this;
  }
  DocumentReference<Map<String, dynamic>> get _device =>
      _firestore.collection('remote_chats').doc(deviceId);
  CollectionReference<Map<String, dynamic>> get _requests =>
      _device.collection('requests');
  static bool get isPublishingActive => _instance?._active != null;
  static String? get activeOwnerUid => _instance?._activeOwnerUid;
  static bool isCurrent(PublicationIdentity? id) =>
      id == null ||
      (_instance?._active?.matches(id) == true &&
          _instance?._disposed == false &&
          _instance?._uid != null &&
          _instance?._uid == _instance?._activeOwnerUid);

  static Future<bool> waitUntilPublishing(PublicationIdentity? id) async {
    if (id == null) return true;
    final self = _instance;
    if (self == null || !isCurrent(id)) return false;
    final snapshot = await self._requests
        .doc(id.requestId)
        .snapshots()
        .firstWhere((snapshot) {
          final data = snapshot.data();
          return data == null ||
              data['attemptId'] != id.attemptId ||
              data['state'] == 'publishing' ||
              data['state'] == 'canceling' ||
              PublicationState.terminal.contains(data['state']);
        });
    return isCurrent(id) && snapshot.data()?['state'] == 'publishing';
  }

  static void bindControls(
    PublicationIdentity? id,
    Object owner, {
    required Future<void> Function() pause,
    required VoidCallback resume,
    required Future<void> Function() stop,
  }) {
    final self = _instance;
    if (id == null || self == null || !isCurrent(id)) return;
    self._controlOwner = owner;
    self._pause = pause;
    self._resume = resume;
    self._stop = stop;
    if (self._paused) self._pauseSafely();
  }

  static void unbindControls(Object owner) {
    final self = _instance;
    if (self?._controlOwner != owner) return;
    self!._pause = null;
    self._resume = null;
    self._stop = null;
    self._controlOwner = null;
  }

  static Future<void> pauseForTakeover() async {
    final self = _instance;
    final identity = self?._active;
    if (self == null || identity == null) return;
    await self._schedule(() async {
      if (!isCurrent(identity)) return;
      final state =
          (await self._requests.doc(identity.requestId).get()).data()?['state'];
      if (!['publishing', 'preparing'].contains(state)) return;
      await self._pause?.call();
      if (await self._report(
        identity,
        'paused',
        'האוטומציה הושהתה לשליטה מרחוק',
      )) {
        self._takeoverPausedIdentity = identity;
      } else if (isCurrent(identity)) {
        throw StateError('Unable to acknowledge automation pause');
      }
    }, propagateErrors: true);
  }

  static Future<void> setLocalPaused(
    PublicationIdentity id,
    bool paused,
  ) async {
    final self = _instance;
    if (self == null || !isCurrent(id)) return;
    await self._schedule(() async {
      final state =
          (await self._requests.doc(id.requestId).get()).data()?['state'];
      if (state == 'canceling' || PublicationState.terminal.contains(state))
        return;
      if (paused) {
        self._takeoverPausedIdentity = null;
        await self._pause?.call();
        await self._report(id, 'paused', 'האוטומציה הושהתה');
      } else if (!self._recovered) {
        if (!await self._report(id, 'publishing', 'האוטומציה ממשיכה')) return;
        if (await waitUntilPublishing(id)) await self._resumeExecution(id);
      }
    });
  }

  static void resumeAfterTakeover() {
    final self = _instance;
    if (self?._active == null || self!._recovered) return;
    final identity = self._takeoverPausedIdentity;
    self._takeoverPausedIdentity = null;
    if (identity == null || !isCurrent(identity)) return;
    unawaited(
      self._schedule(() async {
        if (self._active?.matches(identity) != true) return;
        final data =
            (await self._requests.doc(self._active!.requestId).get()).data();
        if (data?['state'] != 'paused') return;
        if (await self._report(identity, 'publishing', 'האוטומציה ממשיכה'))
          await self._resumeExecution(identity);
      }),
    );
  }

  Future<void> _schedule(
    Future<void> Function() operation, {
    bool propagateErrors = false,
  }) {
    final next = _serial.then((_) async {
      if (!_disposed) await operation();
    });
    _serial = next.catchError((Object error, StackTrace stack) {
      debugPrint('[PublicationWorker] $error');
    });
    return propagateErrors ? next : _serial;
  }

  void _pauseSafely() {
    _paused = true;
    final pause = _pause;
    if (pause != null)
      unawaited(
        pause().catchError((Object error) {
          debugPrint("[PublicationWorker] Pause could not finish: $error");
        }),
      );
  }

  void startListening() {
    _authSub = (ownerChanges ??
            FirebaseAuth.instance.authStateChanges().map((user) => user?.uid))
        .listen((uid) {
          _watchActive(null);
          _stopWatchingQueue();
          _uid = uid;
          if (_active != null && uid != _activeOwnerUid) _pauseSafely();
          if (uid == null) {
            _pauseSafely();
            return;
          }
          if (uid == _activeOwnerUid) _watchActive(_active?.requestId);
          unawaited(_requestTick());
        });
    _timer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_leaseExpiry != null &&
          DateTime.now().isAfter(_leaseExpiry!) &&
          _reportedExpiry != _leaseExpiry) {
        _reportedExpiry = _leaseExpiry;
        _pauseSafely();
        final id = _active;
        if (id != null)
          unawaited(
            reportAutomationStatus(
              identity: id,
              statusType: 'stuck',
              text: 'החיבור אבד; יש לבדוק את מצב הפרסום לפני המשך',
            ),
          );
      }
      _maintainReservation();
    });
    // Safety net for failed listeners, interrupted writes and expired foreign leases.
    _recoveryTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      unawaited(_requestTick());
    });
  }

  Future<void> _requestTick() {
    if (_disposed) return Future.value();
    _tickAgain = true;
    // Coalesce events during slow network calls, without losing a later control.
    return _tickTask ??= _schedule(() async {
      try {
        while (_tickAgain && !_disposed) {
          _tickAgain = false;
          await _tick();
        }
      } catch (_) {
        _retryReconciliation();
        rethrow;
      } finally {
        _tickTask = null;
      }
    });
  }

  void _retryReconciliation() {
    if (_disposed || _retryTimer != null) return;
    _retryTimer = Timer(const Duration(seconds: 10), () {
      _retryTimer = null;
      unawaited(_requestTick());
    });
  }

  void _maintainReservation() {
    if (_disposed ||
        _active == null ||
        _uid != _activeOwnerUid ||
        _uid == null ||
        _maintenancePending) {
      return;
    }
    _maintenancePending = true;
    unawaited(
      _schedule(() async {
        try {
          if (_active == null || _uid == null || _uid != _activeOwnerUid) {
            return;
          }
          await _heartbeat();
          await _flushPendingReports();
        } catch (_) {
          _retryReconciliation();
          rethrow;
        } finally {
          _maintenancePending = false;
        }
      }),
    );
  }

  Future<void> _flushPendingReports() async {
    while (_pendingReports.isNotEmpty) {
      await _pendingReports.first();
      _pendingReports.removeAt(0);
    }
  }

  void _stopWatchingQueue() {
    _queueOwner = null;
    _queueSub?.cancel();
    _queueSub = null;
  }

  void _watchQueue() {
    final uid = _uid;
    if (_disposed || uid == null || _active != null || _queueOwner == uid) {
      return;
    }
    _stopWatchingQueue();
    _queueOwner = uid;
    _queueSub = _requests
        .where('ownerUid', isEqualTo: uid)
        .where('state', isEqualTo: 'queued')
        .limit(1)
        .snapshots()
        .listen(
          (snapshot) {
            if (_disposed ||
                _uid != uid ||
                _queueOwner != uid ||
                _active != null) {
              return;
            }
            if (snapshot.docs.isNotEmpty) {
              onActivity?.call('queue_available');
              unawaited(_requestTick());
            }
          },
          onError: (Object error) {
            if (_queueOwner != uid) return;
            debugPrint('[PublicationWorker] Queue listener: $error');
            _stopWatchingQueue();
            _retryReconciliation();
          },
        );
  }

  void _watchActive(String? requestId) {
    if (_watchedRequestId == requestId) return;
    _requestsSub?.cancel();
    _requestsSub = null;
    _watchedRequestId = requestId;
    if (requestId == null) return;
    _requestsSub = _requests
        .doc(requestId)
        .snapshots()
        .listen(
          (snapshot) {
            if (_disposed ||
                _active?.requestId != requestId ||
                _uid != _activeOwnerUid)
              return;
            onActivity?.call('active_snapshot');
            final data = snapshot.data();
            final control = data?['control'] as Map?;
            // Own status writes need no reconciliation. Only active-car controls or
            // invalidation wake the state machine; other request docs aren't listened to.
            if (data == null ||
                data['attemptId'] != _active?.attemptId ||
                PublicationState.terminal.contains(data['state']) ||
                (control != null &&
                    control['attemptId'] == _active?.attemptId &&
                    control['id'] != data['appliedControlId'])) {
              unawaited(_requestTick());
            }
          },
          onError: (Object error) {
            if (_disposed || _watchedRequestId != requestId) return;
            debugPrint('[PublicationWorker] Active listener: $error');
            _watchActive(null);
            _retryReconciliation();
          },
        );
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _recoveryTimer?.cancel();
    _retryTimer?.cancel();
    _stopWatchingQueue();
    _authSub?.cancel();
    _requestsSub?.cancel();
    _pauseSafely();
    if (identical(_instance, this)) _instance = null;
  }

  Future<void> _tick() async {
    onActivity?.call('tick');
    if (_uid == null || (_active != null && _activeOwnerUid != _uid)) return;
    final uid = _uid;
    final owner = await _firestore
        .collection('remote_control_devices')
        .doc(deviceId)
        .get(const GetOptions(source: Source.server));
    if (_disposed || _uid != uid) return;
    if (owner.data()?['ownerUid'] != uid) {
      _stopWatchingQueue();
      _pauseSafely();
      return;
    }
    await _flushPendingReports();
    final deviceData =
        (await _device.get(const GetOptions(source: Source.server))).data();
    final activeId = deviceData?['activeRequestId'] as String?;
    if (activeId != null) {
      _stopWatchingQueue();
      final snap = await _requests
          .doc(activeId)
          .get(const GetOptions(source: Source.server));
      final data = snap.data();
      if (data == null ||
          PublicationState.terminal.contains(data['state']) ||
          data['archived'] == true) {
        // Never free a live foreign lease, or release our slot before the engine drains.
        final lease = deviceData?['leaseUntil'] as Timestamp?;
        if (deviceData?['workerRunId'] != _runId &&
            lease != null &&
            lease.toDate().isAfter(DateTime.now()))
          return;
        if (_active != null) {
          final activeIdentity = _active!;
          await _stop?.call();
          unawaited(_cleanupMedia(activeIdentity));
        }
        final released = await _firestore.runTransaction<bool>((tx) async {
          final d = (await tx.get(_device)).data();
          final r = (await tx.get(snap.reference)).data();
          if (d?['activeRequestId'] != activeId ||
              d?['workerRunId'] != deviceData?['workerRunId'] ||
              (d?['workerRunId'] != _runId &&
                  ((d?['leaseUntil'] as Timestamp?)?.toDate().isAfter(
                        DateTime.now(),
                      ) ??
                      false)) ||
              (r != null &&
                  !PublicationState.terminal.contains(r['state']) &&
                  r['archived'] != true))
            return false;
          tx.update(_device, {
            'activeRequestId': FieldValue.delete(),
            'workerRunId': FieldValue.delete(),
            'leaseUntil': FieldValue.delete(),
          });
          return true;
        });
        if (!released) return;
        _clearActive();
      } else {
        if (_active != null &&
            (_active!.requestId != activeId ||
                _active!.attemptId != data['attemptId'])) {
          _pauseSafely();
          // An unexpected attempt change must never clear another reservation.
          return;
        }
        if (data['ownerUid'] != _uid) {
          _pauseSafely();
          return;
        }
        if (deviceData?['workerRunId'] != _runId) {
          final lease = deviceData?['leaseUntil'] as Timestamp?;
          if (lease != null && lease.toDate().isAfter(DateTime.now())) return;
          final recovered = await _firestore.runTransaction<bool>((tx) async {
            final d = (await tx.get(_device)).data();
            final r = (await tx.get(snap.reference)).data();
            if (d?['activeRequestId'] != activeId ||
                r == null ||
                ((d?['leaseUntil'] as Timestamp?)?.toDate().isAfter(
                      DateTime.now(),
                    ) ??
                    false))
              return false;
            tx.update(_device, {
              'workerRunId': _runId,
              'leaseUntil': Timestamp.fromDate(
                DateTime.now().add(const Duration(seconds: 60)),
              ),
            });
            tx.update(snap.reference, {
              'workerRunId': _runId,
              'state': r['state'] == 'canceling' ? 'canceling' : 'stuck',
              'revision': (r['revision'] as int) + 1,
              'lastMessage':
                  'המכשיר הופעל מחדש. יש לבדוק אם פורסם לפני ביטול ויצירת בקשה חדשה.',
              'updatedAt': FieldValue.serverTimestamp(),
            });
            return true;
          });
          if (!recovered) return;
          _active = PublicationIdentity(
            deviceId,
            activeId,
            data['attemptId'] as String,
          );
          _activeOwnerUid = data['ownerUid'] as String;
          _recovered = true;
        } else if (_active == null) {
          _active = PublicationIdentity(
            deviceId,
            activeId,
            data['attemptId'] as String,
          );
          _activeOwnerUid = data['ownerUid'] as String;
          _recovered = true;
        }
        _watchActive(activeId);
        await _heartbeat();
        await _handleControl();
        return;
      }
    }
    if (_active != null) {
      _pauseSafely();
      return;
    }
    onActivity?.call('claim');
    final Map<String, dynamic>? selected;
    if (claimNext != null) {
      selected = await claimNext!(_runId);
    } else {
      final result = await WorkerBackend.post({
        'action': 'claim_publication',
        'workerRunId': _runId,
      });
      selected =
          result['request'] == null
              ? null
              : Map<String, dynamic>.from(result['request'] as Map);
    }
    if (_disposed) return;
    if (selected == null) {
      _watchQueue();
      return;
    }
    _stopWatchingQueue();
    _active = PublicationIdentity(
      deviceId,
      selected['requestId'] as String,
      selected['attemptId'] as String,
    );
    _leaseExpiry = DateTime.now().add(const Duration(seconds: 60));
    _recovered = false;
    _activeOwnerUid = selected['ownerUid'] as String;
    if (_activeOwnerUid != _uid) {
      _pauseSafely();
      return;
    }
    _paused = false;
    _watchActive(_active!.requestId);
    await _prepare(selected);
  }

  void _clearActive() {
    _watchActive(null);
    _active = null;
    _activeOwnerUid = null;
    _takeoverPausedIdentity = null;
    _preparedVehicle = null;
    _leaseExpiry = null;
    _reportedExpiry = null;
    _pause = null;
    _resume = null;
    _stop = null;
    _controlOwner = null;
    _paused = false;
  }

  Future<void> _heartbeat() async {
    onActivity?.call('heartbeat');
    final id = _active, uid = _uid;
    if (id == null || uid == null || uid != _activeOwnerUid) return;
    final expiry = DateTime.now().add(const Duration(seconds: 60));
    final held = await _firestore.runTransaction<bool>((tx) async {
      final owner =
          (await tx.get(
            _firestore.collection('remote_control_devices').doc(deviceId),
          )).data();
      final d = (await tx.get(_device)).data();
      if (_uid != uid ||
          owner?['ownerUid'] != uid ||
          _active?.matches(id) != true ||
          d?['workerRunId'] != _runId ||
          d?['activeRequestId'] != id.requestId)
        return false;
      tx.update(_device, {'leaseUntil': Timestamp.fromDate(expiry)});
      return true;
    });
    if (!held) {
      _pauseSafely();
      throw StateError('Worker reservation was lost');
    }
    _leaseExpiry = expiry;
  }

  Future<void> _prepare(Map<String, dynamic> data) async {
    final id = _active!;
    try {
      if (!isCurrent(id)) return;
      if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id.attemptId))
        throw StateError('Invalid attempt');
      final vehicle = Map<String, String>.from(data['vehicleData'] as Map);
      if (!vehicle.containsKey('includeYad2') && !vehicle.containsKey('include_yad2')) {
        try {
          final ownerUid = data['ownerUid'] as String?;
          if (ownerUid != null && ownerUid.isNotEmpty) {
            final userDoc = await _firestore.collection('users').doc(ownerUid).get();
            final settings = userDoc.data()?['settings'] as Map<String, dynamic>?;
            if (settings != null && settings.containsKey('includeYad2')) {
              vehicle['includeYad2'] = (settings['includeYad2'] == true) ? 'true' : 'false';
            }
          }
        } catch (_) {}
      }
      if (!VehicleSchema.isComplete(vehicle))
        throw StateError('פרטי הרכב אינם תקינים');
      final attachments = List<Map<String, dynamic>>.from(
        (data['attachments'] as List).map(
          (a) => Map<String, dynamic>.from(a as Map),
        ),
      );
      if (attachments.isEmpty || attachments.length > 20)
        throw StateError('חסרות תמונות');
      final root =
          await (mediaDirectory?.call() ?? getApplicationDocumentsDirectory());
      final dir = Directory('${root.path}/publication_media/${id.attemptId}');
      await dir.create(recursive: true);
      final paths = <String>[];
      for (var i = 0; i < attachments.length; i++) {
        await _heartbeat();
        if (!isCurrent(id)) return;
        final current = (await _requests.doc(id.requestId).get()).data();
        if (current?['state'] == 'canceling') {
          await _handleControl();
          return;
        }
        final a = attachments[i];
        final prefix =
            'publication_media/${data['ownerUid']}/$deviceId/${id.requestId}/${id.attemptId}/';
        if (!(a['path'] as String).startsWith(prefix) ||
            (a['size'] as int) > 15 * 1024 * 1024)
          throw StateError('תמונה לא מורשית');
        final DownloadedAttachment downloaded;
        if (downloadAttachment != null) {
          downloaded = await downloadAttachment!(a['path'] as String);
        } else {
          final ref = FirebaseStorage.instance.ref(a['path'] as String);
          final metadata = await ref.getMetadata().timeout(
            const Duration(seconds: 20),
          );
          final bytes = await ref
              .getData(15 * 1024 * 1024)
              .timeout(const Duration(seconds: 30));
          if (bytes == null) throw StateError('התמונה חסרה');
          downloaded = DownloadedAttachment(bytes, metadata.generation);
        }
        final bytes = downloaded.bytes;
        if ((downloaded.generation != null &&
                a['generation'] != null &&
                downloaded.generation!.isNotEmpty &&
                a['generation']!.toString().isNotEmpty &&
                downloaded.generation != a['generation']) ||
            bytes.length != a['size'] ||
            sha256.convert(bytes).toString() != a['sha256'])
          throw StateError('התמונה לא התקבלה בשלמותה או השתנתה');
        final file = File('${dir.path}/$i.jpg');
        await file.writeAsBytes(bytes, flush: true);
        paths.add(file.path);
      }
      final current = (await _requests.doc(id.requestId).get()).data();
      if (current?['state'] == 'canceling') {
        await _handleControl();
        return;
      }
      vehicle['image_paths'] = jsonEncode(paths);
      vehicle['image_expected_count'] = '${paths.length}';
      _preparedVehicle = vehicle;
      // A pause requested during download is acknowledged before opening a site.
      await _handleControl();
      if (!isCurrent(id) || _paused) return;
      final bool includeYad2 = (vehicle['includeYad2'] ?? vehicle['include_yad2']) != 'false';
      if (!await _report(id, 'publishing', includeYad2 ? 'מתחיל פרסום ביד2' : 'מתחיל פרסום בפייסבוק')) {
        await _handleControl();
        return;
      }
      await _launchPrepared(id);
      await _handleControl();
    } catch (e) {
      await _report(id, 'failed', 'הכנת הפרסום נכשלה: $e');
    }
  }

  Future<void> _resumeExecution(PublicationIdentity id) async {
    if (_preparedVehicle != null) {
      await _launchPrepared(id);
    } else {
      _resume?.call();
    }
  }

  Future<void> _launchPrepared(PublicationIdentity id) async {
    final vehicle = _preparedVehicle;
    if (vehicle == null || !isCurrent(id)) return;
    try {
      if (!await (launch?.call(vehicle, id) ??
          P2PAutoPublishLauncher.launch(vehicle, identity: id))) {
        throw StateError('לא ניתן לפתוח את מסך הפרסום');
      }
      _preparedVehicle = null;
    } catch (e) {
      await _report(id, 'failed', 'פתיחת הפרסום נכשלה: $e');
    }
  }

  Future<void> _handleControl() async {
    final id = _active;
    if (id == null) return;
    final data = (await _requests.doc(id.requestId).get()).data();
    final control = data?['control'] as Map?;
    if (control == null ||
        control['id'] == data?['appliedControlId'] ||
        control['attemptId'] != id.attemptId)
      return;
    final command = control['command'];
    if (command == 'cancel') {
      _takeoverPausedIdentity = null;
      // Stop drains in-flight automation before the terminal acknowledgement releases the queue.
      await _stop?.call();
      await _report(
        id,
        'canceled',
        'הפרסום בוטל',
        controlId: control['id'] as String,
      );
    } else if (command == 'pause') {
      _takeoverPausedIdentity = null;
      await _pause?.call();
      await _report(
        id,
        'paused',
        'הפרסום הושהה',
        controlId: control['id'] as String,
      );
    } else if (command == 'resume') {
      if (!_recovered && _preparedVehicle != null) {
        if (await _report(
          id,
          'publishing',
          'מתחיל פרסום ביד2',
          controlId: control['id'] as String,
        ))
          await _launchPrepared(id);
      } else if (_recovered || _resume == null) {
        await _report(
          id,
          'stuck',
          'לא ניתן להמשיך אוטומטית לאחר הפעלה מחדש. בדוק את האתרים, בטל וצור בקשה חדשה.',
          controlId: control['id'] as String,
        );
      } else {
        if (await _report(
          id,
          'publishing',
          'ממשיך פרסום',
          controlId: control['id'] as String,
        ))
          _resume!.call();
      }
    }
  }

  static Future<void> reportAutomationStatus({
    required String statusType,
    required String text,
    PublicationIdentity? identity,
    String? platform,
  }) async {
    final self = _instance;
    if (self == null || identity == null || !isCurrent(identity)) return;
    await self._schedule(() async {
      Future<void> report() async {
        await self._report(identity, statusType, text, platform: platform);
      }

      try {
        await report();
      } catch (_) {
        self._pendingReports.add(report);
        self._retryReconciliation();
      }
    });
  }

  Future<void> _cleanupMedia(PublicationIdentity id) async {
    try {
      if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id.attemptId)) return;
      final root =
          await (mediaDirectory?.call() ?? getApplicationDocumentsDirectory());
      final directory = Directory(
        '${root.path}/publication_media/${id.attemptId}',
      );
      if (await directory.exists()) await directory.delete(recursive: true);
    } catch (e) {
      debugPrint('[PublicationWorker] Media cleanup: $e');
    }
  }

  Future<bool> _report(
    PublicationIdentity id,
    String status,
    String text, {
    String? platform,
    String? controlId,
  }) async {
    if (_active?.matches(id) != true) return false;
    final ref = _requests.doc(id.requestId);
    final accepted = await _firestore.runTransaction<String?>((tx) async {
      final d = (await tx.get(_device)).data();
      final r = (await tx.get(ref)).data();
      if (d?['activeRequestId'] != id.requestId ||
          d?['workerRunId'] != _runId ||
          r?['attemptId'] != id.attemptId ||
          r?['ownerUid'] != _uid)
        return null;
      final state = r!['state'] as String;
      if (controlId != null && (r['control'] as Map?)?['id'] != controlId)
        return null;
      if (state == 'canceling' && status != 'canceled') return null;
      if (state == 'publishing' && status == 'publishing') return null;
      final complete = List<String>.from(
        r['completedPlatforms'] as List? ?? [],
      );
      var next = status;
      if (status == 'platform_completed') {
        if (platform == null ||
            !['publishing', 'paused', 'stuck'].contains(state) ||
            !(r['platforms'] as List).contains(platform))
          return null;
        if (complete.contains(platform)) return null;
        complete.add(platform);
        next =
            (r['platforms'] as List).every(complete.contains)
                ? 'completed'
                : state;
      } else if (status == 'step') {
        next = state;
      }
      if (next != state && !PublicationState.canTransition(state, next))
        return null;
      if (PublicationState.terminal.contains(state)) return null;
      final revision = (r['revision'] as int) + 1;
      tx.update(ref, {
        'state': next,
        'revision': revision,
        'lastMessage': text,
        'completedPlatforms': complete,
        if (controlId != null) 'appliedControlId': controlId,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      final message = _device
          .collection('messages')
          .doc('${id.attemptId}_$revision');
      tx.set(message, {
        'id': message.id,
        'sessionId': id.requestId,
        'requestId': id.requestId,
        'attemptId': id.attemptId,
        'sender': 'bot',
        'type': 'status',
        'statusType': next,
        'text': text,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (PublicationState.terminal.contains(next))
        tx.update(_device, {
          'activeRequestId': FieldValue.delete(),
          'workerRunId': FieldValue.delete(),
          'leaseUntil': FieldValue.delete(),
        });
      return next;
    });
    if (accepted == null) return false;
    if (status == 'paused' || status == 'stuck') _paused = true;
    if (status == 'publishing') _paused = false;
    if (PublicationState.terminal.contains(accepted)) {
      _paused = false;
      unawaited(_cleanupMedia(id));
      _clearActive();
      // Run after this operation finishes, never recursively inside its transaction.
      unawaited(_requestTick());
    }
    return true;
  }
}
