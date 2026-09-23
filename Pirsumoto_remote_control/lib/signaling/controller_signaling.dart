import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class ControllerSignalingClient {
  final FirebaseFirestore _firestore;
  final FirebaseAuth? auth;
  final String deviceId;
  final String controllerId;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sessionSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _candidatesSub;

  ControllerSignalingClient({
    FirebaseFirestore? firestore,
    this.auth,
    required this.deviceId,
    required this.controllerId,
  }) : _firestore = firestore ?? FirebaseFirestore.instance;

  DocumentReference<Map<String, dynamic>> get _sessionDoc =>
      _firestore.collection('remote_control_sessions').doc(deviceId);

  CollectionReference<Map<String, dynamic>> get _controllerCandidates =>
      _sessionDoc.collection('controller_candidates');

  CollectionReference<Map<String, dynamic>> get _receiverCandidates =>
      _sessionDoc.collection('receiver_candidates');

  /// Establish identity before setLocalDescription starts emitting ICE candidates.
  Future<void> prepareSession(String sessionId) async {
    await _sessionSub?.cancel();
    await _candidatesSub?.cancel();
    _sessionSub = null;
    _candidatesSub = null;
    _activeSessionId = sessionId;
  }

  /// Initiate session by sending SDP offer to receiver document
  Future<void> requestSession({
    required String sessionId,
    required RTCSessionDescription offer,
    String sessionType = 'remote_control',
    required Function(RTCSessionDescription answer) onAnswerReceived,
    required Function() onSessionClosed,
  }) async {
    if (_activeSessionId != sessionId) {
      throw StateError('Prepare the session before creating the local offer');
    }

    // Write session request first
    try {
      debugPrint(
        '[ControllerSignaling] Writing session request to ${_sessionDoc.path} with sessionId=$sessionId, sessionType=$sessionType...',
      );
      final currentUser = (auth ?? FirebaseAuth.instance).currentUser;
      await _sessionDoc.set({
        'status': 'requested',
        'sessionId': sessionId,
        'controllerId': controllerId,
        'controllerUid': currentUser?.uid,
        'controllerEmail': currentUser?.email,
        'sessionType': sessionType,
        'offer': {'sdp': offer.sdp, 'type': offer.type},
        'answer': null,
        'requestedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      debugPrint(
        '[ControllerSignaling] Successfully wrote session request to Firestore!',
      );
    } catch (e) {
      debugPrint(
        '[ControllerSignaling] FAILED to write session request to Firestore: $e',
      );
      rethrow;
    }

    if (_activeSessionId != sessionId) return;

    // Listen to receiver document for SDP answer and status changes for THIS session
    _sessionSub?.cancel();
    debugPrint(
      '[ControllerSignaling] Listening for session updates on ${_sessionDoc.path} for sessionId=$sessionId',
    );
    bool answerDelivered = false;
    _sessionSub = _sessionDoc.snapshots().listen(
      (snapshot) {
        if (_activeSessionId != sessionId) return;
        if (!snapshot.exists) {
          debugPrint(
            '[ControllerSignaling] Document ${_sessionDoc.path} does not exist',
          );
          return;
        }
        final data = snapshot.data();
        if (data == null) return;

        final docSessionId = data['sessionId'] as String?;
        if (docSessionId != sessionId) {
          debugPrint(
            '[ControllerSignaling] Ignoring snapshot from different sessionId: $docSessionId (current: $sessionId)',
          );
          return;
        }

        final status = data['status'] as String?;
        final answerMap = data['answer'] as Map<String, dynamic>?;
        debugPrint(
          '[ControllerSignaling] Snapshot update for $sessionId: status=$status, hasAnswer=${answerMap != null}',
        );

        if (status == 'connected' && answerMap != null && !answerDelivered) {
          answerDelivered = true;
          debugPrint(
            '[ControllerSignaling] Received connected answer! Invoking onAnswerReceived',
          );
          final answer = RTCSessionDescription(
            answerMap['sdp'] as String,
            answerMap['type'] as String,
          );
          onAnswerReceived(answer);
        } else if (status == 'closed') {
          debugPrint('[ControllerSignaling] Session closed remotely');
          _sessionSub?.cancel();
          _sessionSub = null;
          onSessionClosed();
        }
      },
      onError: (e) {
        debugPrint(
          '[ControllerSignaling] ERROR in session snapshot listener: $e',
        );
      },
    );
  }

  String? _activeSessionId;

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

  /// Listen for ICE candidates emitted by the receiver
  void listenForReceiverCandidates({
    required Function(RTCIceCandidate candidate) onCandidate,
  }) {
    _candidatesSub?.cancel();
    final sessionId = _activeSessionId;
    if (sessionId == null) throw StateError('No prepared session');
    _candidatesSub = _receiverCandidates.snapshots().listen((snapshot) {
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

  /// Send controller local ICE candidate
  Future<void> sendIceCandidate(
    RTCIceCandidate candidate, {
    String? sessionId,
  }) async {
    final candidateSessionId = sessionId ?? _activeSessionId;
    if (candidateSessionId == null || candidateSessionId != _activeSessionId) {
      return;
    }
    try {
      if (_isLoopbackOrInvalid(candidate.candidate)) {
        debugPrint(
          '[ControllerSignaling] Dropping local loopback candidate: ${candidate.candidate}',
        );
        return;
      }
      await _controllerCandidates.add({
        'sessionId': candidateSessionId,
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('[ControllerSignaling] Error sending candidate: $e');
    }
  }

  /// Close the session
  Future<void> disconnect() async {
    _sessionSub?.cancel();
    _sessionSub = null;
    _candidatesSub?.cancel();
    _candidatesSub = null;

    final sessionId = _activeSessionId;
    _activeSessionId = null;
    if (sessionId == null) return;
    try {
      await _firestore.runTransaction((transaction) async {
        final doc = await transaction.get(_sessionDoc);
        final data = doc.data();
        if (data?['sessionId'] == sessionId &&
            data?['status'] != 'closed' &&
            data?['status'] != 'idle') {
          transaction.update(_sessionDoc, {
            'status': 'closed',
            'closedAt': FieldValue.serverTimestamp(),
          });
        }
      });
      await _clearCandidates(sessionId);
    } catch (e) {
      debugPrint('[ControllerSignaling] Error disconnecting: $e');
    }
  }

  Future<void> _clearCandidates(String sessionId) async {
    try {
      final cDocs = await _controllerCandidates.get();
      for (final doc in cDocs.docs) {
        if (doc.data()['sessionId'] == sessionId) await doc.reference.delete();
      }
      final rDocs = await _receiverCandidates.get();
      for (final doc in rDocs.docs) {
        if (doc.data()['sessionId'] == sessionId) await doc.reference.delete();
      }
    } catch (_) {}
  }

  void dispose() {
    _activeSessionId = null;
    _sessionSub?.cancel();
    _candidatesSub?.cancel();
    _sessionSub = null;
    _candidatesSub = null;
  }
}
