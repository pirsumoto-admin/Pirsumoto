import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class RemoteSignalingService {
  final FirebaseFirestore _firestore;
  final String deviceId;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sessionSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _candidatesSub;

  RemoteSignalingService({FirebaseFirestore? firestore, required this.deviceId})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  DocumentReference<Map<String, dynamic>> get _sessionDoc =>
      _firestore.collection('remote_control_sessions').doc(deviceId);

  CollectionReference<Map<String, dynamic>> get _controllerCandidates =>
      _sessionDoc.collection('controller_candidates');

  CollectionReference<Map<String, dynamic>> get _receiverCandidates =>
      _sessionDoc.collection('receiver_candidates');

  /// Set receiver state to IDLE, waiting for an incoming session request
  Future<void> setReceiverIdle({String? endingSessionId}) async {
    // Compare and update atomically so teardown cannot erase a new request.
    await _firestore.runTransaction((transaction) async {
      final doc = await transaction.get(_sessionDoc);
      final data = doc.data();
      final currentSessionId = data?['sessionId'] as String?;
      if (currentSessionId != null && currentSessionId != endingSessionId) {
        return;
      }
      transaction.set(_sessionDoc, {
        'status': 'idle',
        'deviceId': deviceId,
        'updatedAt': FieldValue.serverTimestamp(),
        'offer': null,
        'answer': null,
        'sessionId': null,
        'controllerId': null,
      }, SetOptions(merge: true));
    });
    if (endingSessionId != null) {
      await _clearCandidates(forSessionId: endingSessionId);
    }
  }

  /// Listen for incoming session requests when in IDLE
  void listenForIncomingSession({
    required Function(
      String sessionId,
      String controllerId,
      String? controllerUid,
      RTCSessionDescription offer,
      String sessionType,
    )
    onSessionRequested,
    required Function() onSessionTerminated,
    void Function(Object error)? onError,
  }) {
    _sessionSub?.cancel();
    debugPrint(
      '[ReceiverSignaling] Listening for session requests on ${_sessionDoc.path}',
    );
    String? lastProcessedStatus;
    _sessionSub = _sessionDoc.snapshots().listen(
      (snapshot) {
        if (!snapshot.exists) {
          debugPrint('[ReceiverSignaling] Session doc does not exist yet');
          return;
        }
        final data = snapshot.data();
        if (data == null) return;

        final status = data['status'] as String?;
        final sessionId = data['sessionId'] as String?;
        final controllerId = data['controllerId'] as String?;
        final controllerUid = data['controllerUid'] as String?;
        final sessionType = data['sessionType'] as String? ?? 'remote_control';
        final offerMap = data['offer'] as Map<String, dynamic>?;

        if (status == lastProcessedStatus && status == 'closed') {
          return;
        }
        lastProcessedStatus = status;

        debugPrint(
          '[ReceiverSignaling] Snapshot update: status=$status, sessionId=$sessionId, controller=$controllerId, controllerUid=$controllerUid, sessionType=$sessionType',
        );

        if (status == 'requested' && sessionId != null && offerMap != null) {
          debugPrint(
            '[ReceiverSignaling] Valid offer detected! Triggering onSessionRequested',
          );
          final offer = RTCSessionDescription(
            offerMap['sdp'] as String,
            offerMap['type'] as String,
          );
          _activeSessionId = sessionId;
          onSessionRequested(
            sessionId,
            controllerId ?? 'unknown',
            controllerUid,
            offer,
            sessionType,
          );
        } else if (status == 'closed') {
          debugPrint('[ReceiverSignaling] Session closed by remote party');
          onSessionTerminated();
        }
      },
      onError: (e) {
        debugPrint('[ReceiverSignaling] Error in session snapshots stream: $e');
        onError?.call(e);
      },
    );
  }

  String? _activeSessionId;
  String? get activeSessionId => _activeSessionId;

  void setActiveSessionId(String? sessionId) {
    _activeSessionId = sessionId;
  }

  /// Send SDP Answer back to controller
  Future<void> sendAnswer(
    RTCSessionDescription answer,
    String sessionId,
  ) async {
    await _firestore.runTransaction((transaction) async {
      final snapshot = await transaction.get(_sessionDoc);
      if (snapshot.data()?['sessionId'] != sessionId ||
          snapshot.data()?['status'] != 'requested') {
        throw StateError('Screen-sharing request was replaced or cancelled');
      }
      transaction.update(_sessionDoc, {
        'status': 'connected',
        'answer': {'sdp': answer.sdp, 'type': answer.type},
        'connectedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  bool _isLoopbackOrInvalid(String? candidate) {
    if (candidate == null || candidate.trim().isEmpty) return true;
    if (candidate.contains(' 127.0.0.') ||
        candidate.contains(' ::1 ') ||
        candidate.contains(' 0.0.0.0 ') ||
        candidate.contains('localhost')) {
      return true;
    }
    return false;
  }

  /// Send local ICE Candidate generated by the receiver
  Future<void> sendIceCandidate(
    RTCIceCandidate candidate, {
    String? explicitSessionId,
  }) async {
    if (_isLoopbackOrInvalid(candidate.candidate)) {
      debugPrint(
        '[ReceiverSignaling] Dropping local loopback candidate: ${candidate.candidate}',
      );
      return;
    }
    final sid = explicitSessionId ?? _activeSessionId;
    if (sid == null || sid != _activeSessionId) return;
    await _receiverCandidates.add({
      'sessionId': sid,
      'candidate': candidate.candidate,
      'sdpMid': candidate.sdpMid,
      'sdpMLineIndex': candidate.sdpMLineIndex,
      'timestamp': FieldValue.serverTimestamp(),
    });
  }

  /// Listen for remote ICE Candidates sent by the controller
  void listenToRemoteCandidates({
    required Function(RTCIceCandidate candidate) onCandidate,
  }) {
    _candidatesSub?.cancel();
    final sessionId = _activeSessionId;
    if (sessionId == null) throw StateError('No active session');
    _candidatesSub = _controllerCandidates.snapshots().listen((snapshot) {
      if (_activeSessionId != sessionId) return;
      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final data = change.doc.data();
          if (data != null && data['candidate'] != null) {
            if (data['sessionId'] != sessionId) {
              continue;
            }
            final candStr = data['candidate'] as String;
            if (_isLoopbackOrInvalid(candStr)) {
              continue;
            }
            final candidate = RTCIceCandidate(
              candStr,
              data['sdpMid'] as String?,
              data['sdpMLineIndex'] as int?,
            );
            onCandidate(candidate);
          }
        }
      }
    });
  }

  /// Close the session and mark status as closed
  Future<void> closeSession({String? sessionId}) async {
    try {
      await _sessionDoc.update({
        'status': 'closed',
        'closedAt': FieldValue.serverTimestamp(),
      });
      await _clearCandidates(forSessionId: sessionId ?? _activeSessionId);
    } catch (_) {}
  }

  Future<void> _clearCandidates({String? forSessionId}) async {
    try {
      final cDocs = await _controllerCandidates.get();
      for (final doc in cDocs.docs) {
        if (forSessionId == null || doc.data()['sessionId'] == forSessionId) {
          await doc.reference.delete();
        }
      }
      final rDocs = await _receiverCandidates.get();
      for (final doc in rDocs.docs) {
        if (forSessionId == null || doc.data()['sessionId'] == forSessionId) {
          await doc.reference.delete();
        }
      }
    } catch (_) {}
  }

  void stopListening() {
    _sessionSub?.cancel();
    _candidatesSub?.cancel();
    _sessionSub = null;
    _candidatesSub = null;
    _activeSessionId = null;
  }

  void dispose() => stopListening();
}
