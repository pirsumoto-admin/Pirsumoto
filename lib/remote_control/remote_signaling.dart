import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class RemoteSignalingService {
  final FirebaseFirestore _firestore;
  final String deviceId;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sessionSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _candidatesSub;

  RemoteSignalingService({
    FirebaseFirestore? firestore,
    required this.deviceId,
  }) : _firestore = firestore ?? FirebaseFirestore.instance;

  DocumentReference<Map<String, dynamic>> get _sessionDoc =>
      _firestore.collection('remote_control_sessions').doc(deviceId);

  CollectionReference<Map<String, dynamic>> get _controllerCandidates =>
      _sessionDoc.collection('controller_candidates');

  CollectionReference<Map<String, dynamic>> get _receiverCandidates =>
      _sessionDoc.collection('receiver_candidates');

  /// Set receiver state to IDLE, waiting for an incoming session request
  Future<void> setReceiverIdle({String? endingSessionId}) async {
    try {
      final doc = await _sessionDoc.get();
      if (doc.exists) {
        final data = doc.data();
        final currentSessionId = data?['sessionId'] as String?;
        final currentStatus = data?['status'] as String?;
        // If a new session was already requested while terminating the old one, do not overwrite it!
        if (currentStatus == 'requested' &&
            currentSessionId != null &&
            currentSessionId != endingSessionId) {
          debugPrint('[ReceiverSignaling] Retaining new session $currentSessionId while closing $endingSessionId');
          return;
        }
      }
    } catch (e) {
      debugPrint('[ReceiverSignaling] Error checking session doc before setReceiverIdle: $e');
    }

    await _clearCandidates(forSessionId: endingSessionId);
    await _sessionDoc.set({
      'status': 'idle',
      'deviceId': deviceId,
      'updatedAt': FieldValue.serverTimestamp(),
      'offer': null,
      'answer': null,
      'sessionId': null,
      'controllerId': null,
    }, SetOptions(merge: true));
  }

  /// Listen for incoming session requests when in IDLE
  void listenForIncomingSession({
    required Function(
      String sessionId,
      String controllerId,
      String? controllerUid,
      RTCSessionDescription offer,
      String sessionType,
    ) onSessionRequested,
    required Function() onSessionTerminated,
  }) {
    _sessionSub?.cancel();
    debugPrint('[ReceiverSignaling] Listening for session requests on ${_sessionDoc.path}');
    String? lastProcessedStatus;
    _sessionSub = _sessionDoc.snapshots().listen((snapshot) {
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

      debugPrint('[ReceiverSignaling] Snapshot update: status=$status, sessionId=$sessionId, controller=$controllerId, controllerUid=$controllerUid, sessionType=$sessionType');

      if (status == 'requested' && sessionId != null && offerMap != null) {
        debugPrint('[ReceiverSignaling] Valid offer detected! Triggering onSessionRequested');
        final offer = RTCSessionDescription(
          offerMap['sdp'] as String,
          offerMap['type'] as String,
        );
        _activeSessionId = sessionId;
        onSessionRequested(sessionId, controllerId ?? 'unknown', controllerUid, offer, sessionType);
      } else if (status == 'closed') {
        debugPrint('[ReceiverSignaling] Session closed by remote party');
        onSessionTerminated();
      }
    }, onError: (e) {
      debugPrint('[ReceiverSignaling] Error in session snapshots stream: $e');
    });
  }

  String? _activeSessionId;

  /// Send SDP Answer back to controller
  Future<void> sendAnswer(RTCSessionDescription answer, String sessionId) async {
    _activeSessionId = sessionId;
    await _sessionDoc.update({
      'status': 'connected',
      'answer': {
        'sdp': answer.sdp,
        'type': answer.type,
      },
      'connectedAt': FieldValue.serverTimestamp(),
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
  Future<void> sendIceCandidate(RTCIceCandidate candidate) async {
    if (_isLoopbackOrInvalid(candidate.candidate)) {
      debugPrint('[ReceiverSignaling] Dropping local loopback candidate: ${candidate.candidate}');
      return;
    }
    await _receiverCandidates.add({
      'sessionId': _activeSessionId,
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
    _candidatesSub = _controllerCandidates.snapshots().listen((snapshot) {
      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final data = change.doc.data();
          if (data != null && data['candidate'] != null) {
            if (_activeSessionId != null && data['sessionId'] != null && data['sessionId'] != _activeSessionId) {
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

  void dispose() {
    _sessionSub?.cancel();
    _candidatesSub?.cancel();
    _sessionSub = null;
    _candidatesSub = null;
  }
}
