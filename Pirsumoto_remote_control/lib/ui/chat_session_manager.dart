import '../models/chat_session.dart';
import '../models/publication_queue.dart';
export '../models/chat_session.dart';
import 'dart:async';
import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:crypto/crypto.dart';
import 'package:publication_protocol/publication_protocol.dart';
import '../services/remote_api.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../database/sqlite_database_helper.dart';
import '../webrtc/controller_webrtc_session.dart';
import 'package:fluttertoast/fluttertoast.dart';

class ChatSessionManager {
  static final _changes = StreamController<String>.broadcast();
  static Stream<String> get changes => _changes.stream;
  static final Map<String, StreamSubscription> _subscriptions = {};
  static final Map<String, Map<String, Map<String, dynamic>>> _requests = {};
  static final Map<String, Future<void>> _submissions = {};
  static String? _owner;
  static final Map<String, String?> _priorities = {};
  static Future<void> _projection = Future.value();
  static Map<String, dynamic>? request(String deviceId, String sessionId) {
    if (_owner != FirebaseAuth.instance.currentUser?.uid) return null;
    return _requests[deviceId]?[sessionId];
  }

  static PublicationQueue queue(String deviceId) => PublicationQueue(
    _requests[deviceId] ?? {},
    priority: _priorities[deviceId],
  );

  static String queueLabel(String deviceId, String id) =>
      queue(deviceId).labelFor(id);

  static bool occupiesWorker(ChatSessionStatus status) => {
    ChatSessionStatus.running,
    ChatSessionStatus.preparing,
    ChatSessionStatus.paused,
    ChatSessionStatus.error,
    ChatSessionStatus.canceling,
  }.contains(status);
  static ChatSessionStatus statusFromRequest(String state) => switch (state) {
    'queued' => ChatSessionStatus.waiting,
    'preparing' => ChatSessionStatus.preparing,
    'publishing' => ChatSessionStatus.running,
    'paused' => ChatSessionStatus.paused,
    'stuck' => ChatSessionStatus.error,
    'canceling' => ChatSessionStatus.canceling,
    'completed' => ChatSessionStatus.done,
    'canceled' => ChatSessionStatus.canceled,
    'failed' => ChatSessionStatus.failed,
    _ => ChatSessionStatus.draft,
  };
  static Future<void> reset() async {
    for (final sub in _subscriptions.values) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _requests.clear();
    _priorities.clear();
    _owner = null;
  }

  static void watchDevice(String deviceId) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    if (_owner != uid) {
      for (final s in _subscriptions.values) {
        unawaited(s.cancel());
      }
      _subscriptions.clear();
      _requests.clear();
      _priorities.clear();
      _owner = uid;
    }
    if (_subscriptions.containsKey(deviceId)) return;
    _subscriptions['$deviceId:queue'] = FirebaseFirestore.instance
        .collection('remote_publication_queues')
        .doc(deviceId)
        .snapshots()
        .listen((doc) {
          if (FirebaseAuth.instance.currentUser?.uid != uid) return;
          _priorities[deviceId] = doc.data()?['nextRequestId'] as String?;
          _changes.add(deviceId);
        });
    _subscriptions[deviceId] = FirebaseFirestore.instance
        .collection('remote_chats')
        .doc(deviceId)
        .collection('requests')
        .where('ownerUid', isEqualTo: uid)
        .snapshots()
        .listen((snapshot) {
          _projection = _projection
              .then((_) async {
                if (FirebaseAuth.instance.currentUser?.uid != uid) return;
                for (final change in snapshot.docChanges) {
                  if (change.type == DocumentChangeType.removed) {
                    _requests[deviceId]?.remove(change.doc.id);
                    await SqliteDatabaseHelper.instance.deleteSession(
                      change.doc.id,
                    );
                    continue;
                  }
                  final doc = change.doc;
                  if (FirebaseAuth.instance.currentUser?.uid != uid) return;
                  final data = doc.data();
                  if (data != null) await _project(deviceId, doc.id, data);
                }
                _changes.add(deviceId);
              })
              .catchError((Object e) {
                /* next server snapshot retries the projection */
              });
        });
  }

  static Future<void> _project(
    String deviceId,
    String id,
    Map<String, dynamic> data,
  ) async {
    if (data['ownerUid'] != FirebaseAuth.instance.currentUser?.uid) return;
    final cache = _requests.putIfAbsent(deviceId, () => {});
    if ((cache[id]?['revision'] as int? ?? -1) >
        (data['revision'] as int? ?? 0))
      return;
    data = Map<String, dynamic>.from(data);
    for (final key in ['enqueuedAt', 'updatedAt']) {
      final value = data[key];
      if (value is Map && value['_seconds'] is num)
        data[key] = Timestamp(
          (value['_seconds'] as num).toInt(),
          (value['_nanoseconds'] as num? ?? 0).toInt(),
        );
      if (data[key] is! Timestamp && cache[id]?[key] is Timestamp)
        data[key] = cache[id]![key];
    }
    cache[id] = data;
    if (data['archived'] == true) {
      cache.remove(id);
      await SqliteDatabaseHelper.instance.deleteSession(id);
      return;
    }
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final old = await SqliteDatabaseHelper.instance.getSession(id);
    if (FirebaseAuth.instance.currentUser?.uid != uid) return;
    final vehicle = Map<String, String>.from(data['vehicleData'] as Map);
    final updated = ChatSession(
      id: id,
      deviceId: deviceId,
      licensePlate: vehicle['license_plate'] ?? '',
      startTimestamp:
          old?.startTimestamp ??
          (data['enqueuedAt'] is Timestamp
              ? (data['enqueuedAt'] as Timestamp).millisecondsSinceEpoch
              : DateTime.now().millisecondsSinceEpoch),
      status: statusFromRequest(data['state'] as String),
      lastMessage: data['lastMessage'] as String?,
      vehicleData: vehicle,
      imagePaths: old?.imagePaths,
      isReadyToPublish: true,
    );
    await SqliteDatabaseHelper.instance.insertSession(updated);
  }

  static Future<int> importLegacyDevice(String deviceId) async {
    final user = FirebaseAuth.instance.currentUser;
    final device = await FirebaseFirestore.instance
        .collection('remote_control_devices')
        .doc(deviceId)
        .get(const GetOptions(source: Source.server));
    if (user == null || device.data()?['ownerUid'] != user.uid)
      throw StateError('אין הרשאה למכשיר');
    final result = await SqliteDatabaseHelper.instance.importLegacyDevice(
      deviceId,
    );
    _changes.add(deviceId);
    return result;
  }

  static Future<List<ChatSession>> getSessions(String deviceId) async {
    watchDevice(deviceId);
    return SqliteDatabaseHelper.instance.getSessions(deviceId);
  }

  static Future<void> saveSession(ChatSession session) async {
    // Draft updates cannot overwrite the worker's authoritative state or submitted data.
    final r = request(session.deviceId, session.id);
    if (r != null) {
      await _project(session.deviceId, session.id, r);
    } else {
      await SqliteDatabaseHelper.instance.insertSession(session);
    }
    _changes.add(session.deviceId);
  }

  static Future<void> deleteSession(String deviceId, String sessionId) async {
    var r = request(deviceId, sessionId);
    if (r == null) {
      // A failed lookup must not make an active remote request disappear locally.
      final doc = await FirebaseFirestore.instance
          .collection('remote_chats')
          .doc(deviceId)
          .collection('requests')
          .doc(sessionId)
          .get(const GetOptions(source: Source.server));
      r = doc.data();
    }

    // Cancellation acknowledgment must precede archival. Writing a terminal
    // state here would strand the worker's lease while its engine is running.
    if (r != null && !PublicationState.terminal.contains(r['state'])) {
      await control(deviceId, sessionId, 'cancel');
      r = request(deviceId, sessionId);
      if (r == null || !PublicationState.terminal.contains(r['state'])) {
        throw StateError('הביטול נשלח. ניתן למחוק לאחר אישור מהמכשיר.');
      }
    }
    if (r != null && r['attemptId'] != null) {
      await RemoteApi.post(deviceId, {
        'action': 'archive_publication',
        'requestId': sessionId,
        'attemptId': r['attemptId'],
      });
    }

    // Remove from in-memory cache
    _requests[deviceId]?.remove(sessionId);

    // Delete session and all related messages from SQLite
    await SqliteDatabaseHelper.instance.deleteSession(sessionId);

    // Notify listeners so UI updates immediately
    _changes.add(deviceId);
  }

  static Future<void> prioritize(String deviceId, String id) async {
    final r = request(deviceId, id);
    if (r == null) return;
    await RemoteApi.post(deviceId, {
      'action': 'prioritize_publication',
      'requestId': id,
      'attemptId': r['attemptId'],
    });
  }

  static Future<void> control(
    String deviceId,
    String sessionId,
    String command,
  ) async {
    var r = request(deviceId, sessionId);
    r ??=
        (await FirebaseFirestore.instance
            .collection('remote_chats')
            .doc(deviceId)
            .collection('requests')
            .doc(sessionId)
            .get(const GetOptions(source: Source.server))).data();
    if (r == null) {
      if (command == 'cancel') {
        final draft = await SqliteDatabaseHelper.instance.getSession(sessionId);
        if (draft != null) {
          draft.status = ChatSessionStatus.canceled;
          await saveSession(draft);
        }
        return;
      }
      throw StateError('אין פרסום פעיל');
    }
    final result = await RemoteApi.post(deviceId, {
      'action': 'control_publication',
      'requestId': sessionId,
      'attemptId': r['attemptId'],
      'command': command,
    });
    await _project(
      deviceId,
      sessionId,
      Map<String, dynamic>.from(result['request'] as Map),
    );
    _changes.add(deviceId);
  }

  static Future<void> startSession(
    String deviceId,
    String sessionId, {
    ControllerWebRtcSession? session,
  }) async {
    final r = request(deviceId, sessionId);
    if (r != null) {
      if (r['state'] == 'paused' || r['state'] == 'stuck')
        await control(deviceId, sessionId, 'resume');
      return;
    }
    final draft = await SqliteDatabaseHelper.instance.getSession(sessionId);
    if (draft != null) await startPublication(deviceId, draft);
  }

  static Future<void> startPublication(
    String deviceId,
    ChatSession chatSession, {
    ControllerWebRtcSession? session,
  }) {
    final key =
        '${FirebaseAuth.instance.currentUser?.uid}/$deviceId/${chatSession.id}';
    if (_submissions.containsKey(key)) return _submissions[key]!;
    final task = _submit(deviceId, chatSession);
    _submissions[key] = task;
    return task.whenComplete(() => _submissions.remove(key));
  }

  static Future<void> _submit(String deviceId, ChatSession draft) async {
    watchDevice(deviceId);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('יש להתחבר');
    final requestRef = FirebaseFirestore.instance
        .collection('remote_chats')
        .doc(deviceId)
        .collection('requests')
        .doc(draft.id);
    // Reconcile an earlier ambiguous HTTP result before uploading or enqueueing again.
    final existing = await requestRef.get(
      const GetOptions(source: Source.server),
    );
    if (existing.exists) {
      final existingState = existing.data()?['state'];
      if (!PublicationState.terminal.contains(existingState)) {
        await _project(deviceId, draft.id, existing.data()!);
        _changes.add(deviceId);
        return;
      }
    }
    if (!VehicleSchema.isComplete(draft.vehicleData))
      throw StateError('יש להשלים ולתקן את פרטי הרכב לפני פרסום');
    final paths = draft.imagePaths.toSet().toList();
    if (paths.isEmpty || paths.length > 20)
      throw StateError('יש לצרף 1–20 תמונות');
    final attemptId = requestRef.collection('attempts').doc().id;
    final attachments = <Map<String, dynamic>>[];
    for (var i = 0; i < paths.length; i++) {
      if (FirebaseAuth.instance.currentUser?.uid != uid)
        throw StateError('החשבון השתנה');
      final file = File(paths[i]);
      if (!await file.exists())
        throw StateError('אחת התמונות חסרה; יש לצרף אותה שוב');
      final size = await file.length();
      if (size < 1 || size > 15 * 1024 * 1024)
        throw StateError('כל תמונה חייבת להיות קטנה מ־15MB');
      final bytes = await file.readAsBytes();
      final path = 'publication_media/$uid/$deviceId/${draft.id}/$attemptId/$i';
      final suffix = file.path.toLowerCase();
      final mime =
          suffix.endsWith('.png')
              ? 'image/png'
              : suffix.endsWith('.webp')
              ? 'image/webp'
              : 'image/jpeg';
      await FirebaseStorage.instance
          .ref(path)
          .putData(bytes, SettableMetadata(contentType: mime))
          .timeout(const Duration(minutes: 2));
      attachments.add({
        'path': path,
        'size': size,
        'sha256': sha256.convert(bytes).toString(),
      });
    }
    if (FirebaseAuth.instance.currentUser?.uid != uid)
      throw StateError('החשבון השתנה; יש להתחבר מחדש');
    final vehiclePayload = Map<String, String>.from(draft.vehicleData);
    if (!vehiclePayload.containsKey('govIl') ||
        vehiclePayload['govIl'] == null ||
        vehiclePayload['govIl']!.isEmpty) {
      final isGovIl = draft.vehicleData['govIl'] == 'true';
      vehiclePayload['govIl'] = isGovIl ? 'true' : 'false';
    }
    try {
      final userDoc =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final settings = userDoc.data()?['settings'] as Map<String, dynamic>?;
      final bool includeYad2 = settings?['includeYad2'] ?? true;
      vehiclePayload['includeYad2'] = includeYad2 ? 'true' : 'false';
    } catch (_) {
      if (!vehiclePayload.containsKey('includeYad2') &&
          !vehiclePayload.containsKey('include_yad2')) {
        vehiclePayload['includeYad2'] = 'true';
      }
    }
    // try {
    //   Fluttertoast.showToast(msg: 'govIl: ${vehiclePayload['govIl']} | Year: ${vehiclePayload['test_year']} | Month: ${vehiclePayload['test_month']} | Until: ${vehiclePayload['test_until']}');
    // } catch (_) {}

    // WORKAROUND: Pass govIl state via description because the deployed Cloud Function
    // strips the govIl field until IAM permissions are fixed and it can be redeployed.
    if (vehiclePayload['govIl'] == 'false') {
      final desc = vehiclePayload['description'] ?? '';
      vehiclePayload['description'] = '$desc [NO_GOVIL]'.trim();
    } else if (vehiclePayload['govIl'] == 'true') {
      final desc = vehiclePayload['description'] ?? '';
      vehiclePayload['description'] = '$desc [GOVIL]'.trim();
    }

    final result = await RemoteApi.post(deviceId, {
      'action': 'enqueue_publication',
      'requestId': draft.id,
      'attemptId': attemptId,
      'vehicleData': vehiclePayload,
      'attachments': attachments,
    });
    await _project(
      deviceId,
      draft.id,
      Map<String, dynamic>.from(result['request'] as Map),
    );
    _changes.add(deviceId);
  }
}
