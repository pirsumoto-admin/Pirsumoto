import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'remote_session_state.dart';
import 'remote_protocol.dart';
import 'remote_signaling.dart';
import 'remote_webrtc_receiver.dart';
import 'remote_chat_receiver.dart';

class RemoteSessionManager extends ChangeNotifier {
  static const MethodChannel _channel = MethodChannel('com.pirsumoto/accessibility');

  final RemoteSignalingService signaling;

  RemoteSessionInfo _sessionInfo = const RemoteSessionInfo();
  RemoteSessionInfo get sessionInfo => _sessionInfo;

  RemoteWebRtcReceiver? _webrtc;
  RemoteChatReceiver? _chatReceiver;
  String _sessionType = 'remote_control';
  int _screenWidth = 1080;
  int _screenHeight = 2400;
  double _screenDensity = 2.6;
  String? _modelName;
  String? get modelName => _modelName;
  StreamSubscription<User?>? _authSub;

  // Callback for automation pause/resume
  VoidCallback? onAutomationPauseRequested;
  VoidCallback? onAutomationResumeRequested;

  RemoteSessionManager({required this.signaling});

  /// Initialize and enter IDLE state listening for incoming remote connections
  Future<void> startListening() async {
    _updateState(_sessionInfo.copyWith(state: RemoteSessionState.connecting));

    // Fetch physical screen dimensions and device model from Android
    try {
      final dims = await _channel.invokeMapMethod<String, dynamic>('getScreenDimensions');
      if (dims != null) {
        _screenWidth = (dims['width'] as num?)?.toInt() ?? _screenWidth;
        _screenHeight = (dims['height'] as num?)?.toInt() ?? _screenHeight;
        _screenDensity = (dims['density'] as num?)?.toDouble() ?? _screenDensity;
        debugPrint('[RemoteSessionManager] Screen size: ${_screenWidth}x$_screenHeight, density: $_screenDensity');
      }
    } catch (e) {
      debugPrint('[RemoteSessionManager] Could not get screen dimensions: $e');
    }

    try {
      final info = await _channel.invokeMapMethod<String, dynamic>('getDeviceInfo');
      if (info != null) {
        final manufacturer = info['manufacturer'] as String? ?? '';
        final model = info['model'] as String? ?? '';
        if (manufacturer.isNotEmpty && !model.toLowerCase().contains(manufacturer.toLowerCase())) {
          _modelName = '$manufacturer $model'.trim();
        } else {
          _modelName = model.isNotEmpty ? model : 'Android Device';
        }
        debugPrint('[RemoteSessionManager] Device model: $_modelName');
      }
    } catch (e) {
      debugPrint('[RemoteSessionManager] Could not get device info: $e');
    }

    // Register device in Firestore and keep updated on Auth state changes
    await _registerDeviceInFirestore(status: 'idle');
    _authSub?.cancel();
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      debugPrint('[RemoteSessionManager] Auth state changed for user: ${user?.email}');
      _registerDeviceInFirestore();
    });

    try {
      await signaling.setReceiverIdle();
      signaling.listenForIncomingSession(
        onSessionRequested: _handleIncomingSession,
        onSessionTerminated: _handleSessionTerminatedRemotely,
      );
      _updateState(_sessionInfo.copyWith(
        state: RemoteSessionState.idle,
        inputOwner: InputOwner.automation,
      ));
      debugPrint('[RemoteSessionManager] Receiver is IDLE and listening for session requests');
    } catch (e) {
      _updateState(_sessionInfo.copyWith(
        state: RemoteSessionState.offline,
        lastError: e.toString(),
      ));
      debugPrint('[RemoteSessionManager] Error entering IDLE: $e');
    }
  }

  /// Register or update device record in Firestore
  Future<void> _registerDeviceInFirestore({String? status}) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      final docRef = FirebaseFirestore.instance
          .collection('remote_control_devices')
          .doc(signaling.deviceId);

      final data = <String, dynamic>{
        'deviceId': signaling.deviceId,
        'ownerUid': user?.uid,
        'ownerEmail': user?.email,
        'modelName': _modelName ?? 'Android Device',
        'updatedAt': FieldValue.serverTimestamp(),
      };
      if (status != null) {
        data['status'] = status;
      }
      await docRef.set(data, SetOptions(merge: true));
      debugPrint('[RemoteSessionManager] Registered device in Firestore: $data');
    } catch (e) {
      debugPrint('[RemoteSessionManager] Error registering device in Firestore: $e');
    }
  }

  /// Handle incoming session request from controller with automatic same-account approval
  Future<void> _handleIncomingSession(
    String sessionId,
    String controllerId,
    String? controllerUid,
    RTCSessionDescription offer, [
    String sessionType = 'remote_control',
  ]) async {
    _sessionType = sessionType;
    if (_sessionInfo.state == RemoteSessionState.active ||
        _sessionInfo.state == RemoteSessionState.connectingWebRTC) {
      if (_sessionInfo.activeSessionId == sessionId) {
        debugPrint('[RemoteSessionManager] Ignoring session request: already active/connecting with this sessionId');
        return;
      }
      debugPrint('[RemoteSessionManager] New session requested ($sessionId) while previous session was active (${_sessionInfo.activeSessionId}). Cleaning up old session...');
      await terminateSession();
    }

    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null || controllerUid == null || controllerUid != currentUser.uid) {
      debugPrint('[RemoteSessionManager] REJECTED: Session request from controllerUid=$controllerUid does not match receiver owner UID=${currentUser?.uid}');
      await signaling.closeSession();
      return;
    }

    debugPrint('[RemoteSessionManager] AUTO-APPROVED: Controller $controllerId authenticated under same account (${currentUser.email}), sessionType=$sessionType');
    _updateState(_sessionInfo.copyWith(
      state: RemoteSessionState.connectingWebRTC,
      activeSessionId: sessionId,
      controllerId: controllerId,
      inputOwner: InputOwner.remoteHuman,
    ));

    // Notify automation to pause so it doesn't conflict with human gestures
    onAutomationPauseRequested?.call();

    try {
      // 1. Enable AccessibilityService auto-approval to immediately dismiss and approve the system consent dialog
      try {
        await _channel.invokeMethod('startCaptureAutoApproval');
      } catch (e) {
        debugPrint('[RemoteSessionManager] Failed to start capture auto approval: $e');
      }

      // 2. Request Screen Capture Permission (auto-approved by AccessibilityService without manual user interaction)
      debugPrint('[RemoteSessionManager] Requesting screen capture permission...');
      final granted = await Helper.requestCapturePermission(fullScreenOnly: true);
      if (!granted) {
        throw Exception('User cancelled or denied screen capture permission');
      }
      debugPrint('[RemoteSessionManager] Screen capture permission granted');

      // 3. Start Android MediaProjection foreground service
      await _channel.invokeMethod('startRemoteCaptureService');

      // Initialize WebRTC receiver
      _webrtc = RemoteWebRtcReceiver(
        onLocalCandidate: (candidate) => signaling.sendIceCandidate(candidate),
        onCommandReceived: _handleIncomingCommand,
        onConnectionStateChange: _handleWebRtcStateChange,
      );

      _chatReceiver?.dispose();
      _chatReceiver = RemoteChatReceiver(
        webrtc: _webrtc!,
        deviceId: signaling.deviceId,
        controllerId: controllerId,
      );

      await _webrtc!.initializePeerConnection(
        width: _screenWidth,
        height: _screenHeight,
        enableScreenCapture: true,
      );

      // Listen to controller ICE candidates
      signaling.listenToRemoteCandidates(
        onCandidate: (candidate) => _webrtc?.addCandidate(candidate),
      );

      // Create SDP answer and send via Firestore
      final answer = await _webrtc!.handleOffer(offer);
      await signaling.sendAnswer(answer, sessionId);

      _updateState(_sessionInfo.copyWith(
        state: RemoteSessionState.active,
        connectedAt: DateTime.now(),
      ));

      await _registerDeviceInFirestore(status: 'active');

      // Send screen dimensions to controller so coordinate mapping is pixel-perfect
      Future.delayed(const Duration(milliseconds: 500), () {
        _webrtc?.sendReply(RemoteDimensionsCommand(
          width: _screenWidth,
          height: _screenHeight,
          density: _screenDensity,
        ));
      });

      debugPrint('[RemoteSessionManager] Remote session is ACTIVE ($sessionType)');
    } catch (e) {
      debugPrint('[RemoteSessionManager] Failed to start remote session: $e');
      await terminateSession(error: e.toString());
    }
  }

  /// Handle commands received from the controller DataChannel
  Future<void> _handleIncomingCommand(RemoteCommand command) async {
    // Intercept chat messages first
    if (await _chatReceiver?.handleIncomingCommand(command) == true) {
      return;
    }
    // Only process human input commands if inputOwner is remoteHuman
    if (_sessionInfo.inputOwner != InputOwner.remoteHuman &&
        command is! RemoteHandoverCommand &&
        command is! RemoteDisconnectCommand &&
        command is! RemotePingCommand) {
      debugPrint('[RemoteSessionManager] Command dropped: automation has input ownership');
      return;
    }

    try {
      if (command is RemoteTapCommand) {
        final pixelX = command.x * _screenWidth;
        final pixelY = command.y * _screenHeight;
        await _channel.invokeMethod('remoteTap', {
          'x': pixelX,
          'y': pixelY,
        });
      } else if (command is RemoteLongPressCommand) {
        final pixelX = command.x * _screenWidth;
        final pixelY = command.y * _screenHeight;
        await _channel.invokeMethod('remoteLongPress', {
          'x': pixelX,
          'y': pixelY,
          'duration': command.durationMs,
        });
      } else if (command is RemoteSwipeCommand) {
        final startX = command.startX * _screenWidth;
        final startY = command.startY * _screenHeight;
        final endX = command.endX * _screenWidth;
        final endY = command.endY * _screenHeight;
        await _channel.invokeMethod('remoteSwipe', {
          'startX': startX,
          'startY': startY,
          'endX': endX,
          'endY': endY,
          'duration': command.durationMs,
        });
      } else if (command is RemoteKeyCommand) {
        if (command.key == RemoteProtocolConstants.keyBack) {
          await _channel.invokeMethod('pressBack');
        } else if (command.key == RemoteProtocolConstants.keyHome) {
          await _channel.invokeMethod('pressHome');
        } else if (command.key == RemoteProtocolConstants.keyRecents) {
          await _channel.invokeMethod('pressRecents');
        } else if (command.key == RemoteProtocolConstants.keyEnter) {
          await _channel.invokeMethod('injectTextNative', {'value': '\n'});
        }
      } else if (command is RemoteTextCommand) {
        // First try entering text into the currently focused node via Accessibility
        final focusedSuccess = await _channel.invokeMethod<bool>(
          'enterTextAtFocused',
          {'value': command.text},
        );
        if (focusedSuccess != true) {
          // Fallback to native injection
          await _channel.invokeMethod('injectTextNative', {'value': command.text});
        }
      } else if (command is RemoteHandoverCommand) {
        final newOwner = command.owner == 'automation'
            ? InputOwner.automation
            : InputOwner.remoteHuman;
        _updateState(_sessionInfo.copyWith(inputOwner: newOwner));
        if (newOwner == InputOwner.automation) {
          onAutomationResumeRequested?.call();
        } else {
          onAutomationPauseRequested?.call();
        }
      } else if (command is RemoteDisconnectCommand) {
        await terminateSession();
      }
    } catch (e) {
      debugPrint('[RemoteSessionManager] Error executing command $command: $e');
    }
  }

  Timer? _failureGraceTimer;

  void _handleWebRtcStateChange(RTCPeerConnectionState state) {
    debugPrint('[RemoteSessionManager] WebRTC connection state changed: $state');
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      _failureGraceTimer?.cancel();
      _failureGraceTimer = null;
      return;
    }
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
      debugPrint('[RemoteSessionManager] WebRTC connection closed');
      terminateSession();
    } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
      debugPrint('[RemoteSessionManager] WebRTC connection failed, allowing 3s grace period for reconnect');
      _failureGraceTimer?.cancel();
      _failureGraceTimer = Timer(const Duration(seconds: 3), () {
        if (_sessionInfo.state == RemoteSessionState.active &&
            _webrtc?.connectionState == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          debugPrint('[RemoteSessionManager] WebRTC remained in failed state after grace period, terminating');
          terminateSession();
        }
      });
    }
  }

  void _handleSessionTerminatedRemotely() {
    if (_sessionInfo.state == RemoteSessionState.active ||
        _sessionInfo.state == RemoteSessionState.connectingWebRTC) {
      debugPrint('[RemoteSessionManager] Remote session terminated by signaling');
      terminateSession();
    }
  }

  /// Terminate the active remote session and return to IDLE
  Future<void> terminateSession({String? error}) async {
    _failureGraceTimer?.cancel();
    _failureGraceTimer = null;

    final endingSessionId = _sessionInfo.activeSessionId;

    _updateState(_sessionInfo.copyWith(
      state: RemoteSessionState.disconnecting,
      lastError: error,
    ));

    try {
      _chatReceiver?.dispose();
      _chatReceiver = null;

      await _webrtc?.close();
      _webrtc = null;

      // Stop MediaProjection foreground service if it was running
      if (_sessionType != 'chat') {
        try {
          await _channel.invokeMethod('stopRemoteCaptureService');
        } catch (_) {}
      }

      // Update signaling - retain new session request if one arrived during teardown!
      await signaling.setReceiverIdle(endingSessionId: endingSessionId);

      // Restore automation input ownership
      _updateState(_sessionInfo.copyWith(
        state: RemoteSessionState.idle,
        inputOwner: InputOwner.automation,
        activeSessionId: null,
        controllerId: null,
        connectedAt: null,
      ));

      onAutomationResumeRequested?.call();
      await _registerDeviceInFirestore(status: 'idle');
      debugPrint('[RemoteSessionManager] Cleaned up and returned to IDLE');
    } catch (e) {
      debugPrint('[RemoteSessionManager] Error terminating session: $e');
      _updateState(_sessionInfo.copyWith(
        state: RemoteSessionState.idle,
        inputOwner: InputOwner.automation,
      ));
      await _registerDeviceInFirestore(status: 'idle');
    }
  }

  void _updateState(RemoteSessionInfo newInfo) {
    _sessionInfo = newInfo;
    notifyListeners();
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _registerDeviceInFirestore(status: 'offline');
    signaling.dispose();
    _webrtc?.close();
    super.dispose();
  }
}
