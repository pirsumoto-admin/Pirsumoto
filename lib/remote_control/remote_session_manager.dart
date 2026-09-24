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
import 'firebase_chat_receiver.dart';
import '../services/whatsapp_text_validation_service.dart';

class RemoteSessionManager extends ChangeNotifier {
  static const MethodChannel _channel = MethodChannel(
    'com.pirsumoto/accessibility',
  );

  final RemoteSignalingService signaling;
  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;
  final RemoteWebRtcReceiverFactory _createReceiver;
  final bool Function() _isAutomationRunning;
  Timer? _listenerRetry;
  String? _listeningOwnerUid;
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  RemoteSessionInfo _sessionInfo = const RemoteSessionInfo();
  RemoteSessionInfo get sessionInfo => _sessionInfo;

  RemoteWebRtcReceiver? _webrtc;
  RemoteChatReceiver? _chatReceiver;
  String _sessionType = 'remote_control';
  int _screenWidth = 1080;
  int _screenHeight = 2400;
  double _screenDensity = 2.6;
  String? _modelName;
  String? _sessionOwnerUid;
  int _sessionGeneration = 0;
  Future<void> _commands = Future.value();
  Future<void> _incomingRequests = Future.value();
  Future<void>? _termination;
  bool _authorizedSession(int generation) =>
      !_disposed &&
      generation == _sessionGeneration &&
      _sessionOwnerUid != null &&
      _auth.currentUser?.uid == _sessionOwnerUid;
  String? get modelName => _modelName;
  StreamSubscription<User?>? _authSub;

  // Callback for automation pause/resume
  Future<void> Function()? onAutomationPauseRequested;
  VoidCallback? onAutomationResumeRequested;

  RemoteSessionManager({
    required this.signaling,
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    RemoteWebRtcReceiverFactory? receiverFactory,
    bool Function()? isAutomationRunning,
  }) : _auth = auth ?? FirebaseAuth.instance,
       _firestore = firestore ?? FirebaseFirestore.instance,
       _createReceiver = receiverFactory ?? RemoteWebRtcReceiver.new,
       _isAutomationRunning =
           isAutomationRunning ??
           (() => FirebaseChatReceiver.isPublishingActive);

  /// Initialize and enter IDLE state listening for incoming remote connections
  Future<void> startListening() async {
    _updateState(_sessionInfo.copyWith(state: RemoteSessionState.connecting));

    // Fetch physical screen dimensions and device model from Android
    try {
      final dims = await _channel.invokeMapMethod<String, dynamic>(
        'getScreenDimensions',
      );
      if (dims != null) {
        _screenWidth = (dims['width'] as num?)?.toInt() ?? _screenWidth;
        _screenHeight = (dims['height'] as num?)?.toInt() ?? _screenHeight;
        _screenDensity =
            (dims['density'] as num?)?.toDouble() ?? _screenDensity;
        debugPrint(
          '[RemoteSessionManager] Screen size: ${_screenWidth}x$_screenHeight, density: $_screenDensity',
        );
      }
    } catch (e) {
      debugPrint('[RemoteSessionManager] Could not get screen dimensions: $e');
    }

    try {
      final info = await _channel.invokeMapMethod<String, dynamic>(
        'getDeviceInfo',
      );
      if (info != null) {
        final manufacturer = info['manufacturer'] as String? ?? '';
        final model = info['model'] as String? ?? '';
        if (manufacturer.isNotEmpty &&
            !model.toLowerCase().contains(manufacturer.toLowerCase())) {
          _modelName = '$manufacturer $model'.trim();
        } else {
          _modelName = model.isNotEmpty ? model : 'Android Device';
        }
        debugPrint('[RemoteSessionManager] Device model: $_modelName');
      }
    } catch (e) {
      debugPrint('[RemoteSessionManager] Could not get device info: $e');
    }

    // Authentication can arrive after app startup. A failed idle transaction
    // must never prevent us from subscribing to incoming offers.
    await _authSub?.cancel();
    if (_disposed) return;
    _listeningOwnerUid = null;
    _authSub = _auth.authStateChanges().listen((user) {
      if (_disposed) return;
      if (user != null && _listeningOwnerUid == user.uid) return;
      _listeningOwnerUid = user?.uid;
      _listenerRetry?.cancel();
      signaling.stopListening();
      if (_sessionOwnerUid != null && _sessionOwnerUid != user?.uid) {
        unawaited(terminateSession(error: 'Authentication changed'));
      }
      if (user == null) {
        _updateState(_sessionInfo.copyWith(state: RemoteSessionState.offline));
        return;
      }
      _listenForSessions(user.uid);
      unawaited(_registerDeviceInFirestore(status: 'idle'));
    });
  }

  void _listenForSessions(String ownerUid) {
    if (_disposed || _auth.currentUser?.uid != ownerUid) return;
    signaling.listenForIncomingSession(
      onSessionRequested: _handleIncomingSession,
      onSessionTerminated: _handleSessionTerminatedRemotely,
      onError: (error) {
        if (_disposed || _auth.currentUser?.uid != ownerUid) return;
        debugPrint('[RemoteSessionManager] Session listener failed: $error');
        _listenerRetry?.cancel();
        _listenerRetry = Timer(const Duration(seconds: 5), () {
          _listenForSessions(ownerUid);
        });
      },
    );
    if (_sessionOwnerUid == null) {
      _updateState(
        _sessionInfo.copyWith(
          state: RemoteSessionState.idle,
          inputOwner: InputOwner.automation,
        ),
      );
    }
    debugPrint(
      '[RemoteSessionManager] Listening for session requests on device ${signaling.deviceId}',
    );
  }

  /// Register or update device record in Firestore
  Future<void> _registerDeviceInFirestore({String? status}) async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;
      final docRef = _firestore
          .collection('remote_control_devices')
          .doc(signaling.deviceId);

      final data = <String, dynamic>{
        'deviceId': signaling.deviceId,
        'ownerUid': user.uid,
        'ownerEmail': user.email,
        'modelName': _modelName ?? 'Android Device',
        'updatedAt': FieldValue.serverTimestamp(),
      };
      if (status != null) {
        data['status'] = status;
      }
      await _firestore.runTransaction((tx) async {
        final existing = (await tx.get(docRef)).data();
        if (existing?['ownerUid'] != null &&
            existing?['ownerUid'] != user.uid) {
          throw StateError('Device ID belongs to another account');
        }
        if (_auth.currentUser?.uid != user.uid) return;
        tx.set(docRef, data, SetOptions(merge: true));
      });
      debugPrint(
        '[RemoteSessionManager] Registered device in Firestore: $data',
      );
    } catch (e) {
      debugPrint(
        '[RemoteSessionManager] Error registering device in Firestore: $e',
      );
    }
  }

  /// Handle incoming session request from controller with automatic same-account approval
  Future<void> _handleIncomingSession(
    String sessionId,
    String controllerId,
    String? controllerUid,
    RTCSessionDescription offer, [
    String sessionType = 'remote_control',
  ]) {
    final task = _incomingRequests.then(
      (_) => _startIncomingSession(
        sessionId,
        controllerId,
        controllerUid,
        offer,
        sessionType,
      ),
    );
    _incomingRequests = task.catchError((Object e) {
      debugPrint('[RemoteSessionManager] Session setup: $e');
    });
    return _incomingRequests;
  }

  Future<void> _startIncomingSession(
    String sessionId,
    String controllerId,
    String? controllerUid,
    RTCSessionDescription offer,
    String sessionType,
  ) async {
    // Legacy chat-only offers must not trigger foregrounding, capture, or takeover.
    if (sessionType != 'remote_control') return;
    await _termination;
    final currentUser = _auth.currentUser;
    if (currentUser == null ||
        controllerUid == null ||
        controllerUid != currentUser.uid) {
      debugPrint(
        '[RemoteSessionManager] REJECTED: Session request from controllerUid=$controllerUid does not match receiver owner UID=${currentUser?.uid}',
      );
      return;
    }

    if (_sessionInfo.state == RemoteSessionState.active ||
        _sessionInfo.state == RemoteSessionState.connectingWebRTC) {
      if (_sessionInfo.activeSessionId == sessionId) {
        debugPrint(
          '[RemoteSessionManager] Ignoring session request: already active/connecting with this sessionId',
        );
        return;
      }
      debugPrint(
        '[RemoteSessionManager] New session requested ($sessionId) while previous session was active (${_sessionInfo.activeSessionId}). Cleaning up old session...',
      );
      await terminateSession();
    }

    final registered = await _firestore
        .collection('remote_control_devices')
        .doc(signaling.deviceId)
        .get(const GetOptions(source: Source.server));
    if (_auth.currentUser?.uid != controllerUid ||
        registered.data()?['ownerUid'] != controllerUid)
      return;
    _sessionType = sessionType;
    _sessionOwnerUid = controllerUid;
    final generation = ++_sessionGeneration;
    debugPrint(
      '[RemoteSessionManager] AUTO-APPROVED: Controller $controllerId authenticated under same account (${currentUser.email}), sessionType=$sessionType',
    );
    _updateState(
      _sessionInfo.copyWith(
        state: RemoteSessionState.connectingWebRTC,
        activeSessionId: sessionId,
        controllerId: controllerId,
        inputOwner: InputOwner.automation,
      ),
    );
    signaling.setActiveSessionId(sessionId);

    try {
      // Viewing leaves automation running; only explicit takeover pauses it.
      if (!_authorizedSession(generation)) return;
      // Ensure app is in the foreground so Android allows MediaProjection capture token initialization
      try {
        final bool? inForeground = await _channel.invokeMethod<bool>(
          'isAppInForeground',
        );
        if (inForeground != true) {
          if (_isAutomationRunning()) {
            throw StateError(
              'Cannot bring projection to the foreground while automation is running',
            );
          }
          debugPrint(
            '[RemoteSessionManager] App is in background. Bringing to foreground for screen capture...',
          );
          await _channel.invokeMethod('bringAppToForeground');
          for (int i = 0; i < 20; i++) {
            await Future.delayed(const Duration(milliseconds: 100));
            final bool? nowInForeground = await _channel.invokeMethod<bool>(
              'isAppInForeground',
            );
            if (nowInForeground == true) {
              debugPrint('[RemoteSessionManager] App is now in foreground');
              break;
            }
          }
        }
      } catch (e) {
        debugPrint(
          '[RemoteSessionManager] Error checking/bringing app to foreground: $e',
        );
        if (_isAutomationRunning()) rethrow;
      }

      if (!_authorizedSession(generation)) return;
      // Request Screen Capture Permission (immediately granted via PROJECT_MEDIA AppOp)
      debugPrint(
        '[RemoteSessionManager] Requesting screen capture permission...',
      );
      final granted = await Helper.requestCapturePermission(
        fullScreenOnly: true,
      );
      if (!granted) {
        throw Exception('User cancelled or denied screen capture permission');
      }
      if (!_authorizedSession(generation)) return;
      debugPrint('[RemoteSessionManager] Screen capture permission granted');

      // Start Android MediaProjection foreground service
      await _channel.invokeMethod('startRemoteCaptureService');
      bool captureReady = false;
      for (var attempt = 0; attempt < 50; attempt++) {
        if (!_authorizedSession(generation)) return;
        captureReady =
            await _channel.invokeMethod<bool>('isRemoteCaptureRunning') == true;
        if (captureReady) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (!captureReady)
        throw StateError('Screen capture foreground service did not start');
      if (!_authorizedSession(generation)) {
        await _channel.invokeMethod('stopRemoteCaptureService');
        return;
      }

      // Initialize WebRTC receiver
      final receiver = _createReceiver(
        onLocalCandidate:
            (candidate) => signaling.sendIceCandidate(
              candidate,
              explicitSessionId: sessionId,
            ),
        onCommandReceived: (command) {
          if (_authorizedSession(generation))
            unawaited(_handleIncomingCommand(command));
        },
        onConnectionStateChange: (state) {
          if (_authorizedSession(generation)) _handleWebRtcStateChange(state);
        },
      );

      _webrtc = receiver;
      _chatReceiver?.dispose();
      _chatReceiver = RemoteChatReceiver(
        webrtc: _webrtc!,
        deviceId: signaling.deviceId,
        controllerId: controllerId,
      );

      await receiver.initializePeerConnection(
        width: _screenWidth,
        height: _screenHeight,
        enableScreenCapture: true,
      );

      if (!_authorizedSession(generation)) {
        await receiver.close();
        return;
      }
      // Firestore replays existing candidates after the peer is ready.
      signaling.listenToRemoteCandidates(
        onCandidate: (candidate) {
          if (_authorizedSession(generation)) receiver.addCandidate(candidate);
        },
      );

      // Create SDP answer and send via Firestore
      final answer = await receiver.handleOffer(offer);
      if (!_authorizedSession(generation)) return;
      await signaling.sendAnswer(answer, sessionId);
      if (!_authorizedSession(generation)) return;

      _updateState(
        _sessionInfo.copyWith(
          state: RemoteSessionState.active,
          connectedAt: DateTime.now(),
        ),
      );

      await _registerDeviceInFirestore(status: 'active');

      // Send screen dimensions to controller so coordinate mapping is pixel-perfect
      Future.delayed(const Duration(milliseconds: 500), () {
        if (!_authorizedSession(generation)) return;
        _webrtc?.sendReply(
          RemoteDimensionsCommand(
            width: _screenWidth,
            height: _screenHeight,
            density: _screenDensity,
          ),
        );
      });

      debugPrint(
        '[RemoteSessionManager] Remote session is ACTIVE ($sessionType)',
      );
    } catch (e) {
      debugPrint('[RemoteSessionManager] Failed to start remote session: $e');
      if (_authorizedSession(generation))
        await terminateSession(error: e.toString());
    }
  }

  /// Handle commands received from the controller DataChannel
  Future<void> _handleIncomingCommand(RemoteCommand command) {
    final generation = _sessionGeneration;
    _commands = _commands
        .then((_) async {
          if (_authorizedSession(generation))
            await _processIncomingCommand(command, generation);
        })
        .catchError((Object e) {
          debugPrint('[RemoteSessionManager] Command: $e');
        });
    return _commands;
  }

  Future<void> _processIncomingCommand(
    RemoteCommand command,
    int generation,
  ) async {
    // Intercept chat messages first
    if (await _chatReceiver?.handleIncomingCommand(command) == true) {
      return;
    }
    // Only process human input commands if inputOwner is remoteHuman
    if (_sessionInfo.inputOwner != InputOwner.remoteHuman &&
        command is! RemoteHandoverCommand &&
        command is! RemoteDisconnectCommand &&
        command is! RemotePingCommand) {
      debugPrint(
        '[RemoteSessionManager] Command dropped: automation has input ownership',
      );
      return;
    }

    try {
      if (command is RemoteTapCommand) {
        final pixelX = command.x * _screenWidth;
        final pixelY = command.y * _screenHeight;
        await _channel.invokeMethod('remoteTap', {'x': pixelX, 'y': pixelY});
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
          await _channel.invokeMethod('injectTextNative', {
            'value': command.text,
          });
        }
      } else if (command is RemoteHandoverCommand) {
        final newOwner =
            command.owner == 'automation'
                ? InputOwner.automation
                : InputOwner.remoteHuman;
        if (newOwner == _sessionInfo.inputOwner) return;
        if (newOwner == InputOwner.automation) {
          // Lower projection work before allowing automation to resume.
          try {
            await _webrtc?.setInteractive(false);
          } catch (error) {
            // Never leave automation paused because video cannot be throttled.
            // Closing capture first removes the expensive stream before resume.
            await terminateSession(
              error: 'Could not lower projection load: $error',
            );
            return;
          }
          if (!_authorizedSession(generation)) return;
          _updateState(_sessionInfo.copyWith(inputOwner: newOwner));
          onAutomationResumeRequested?.call();
        } else {
          await onAutomationPauseRequested?.call();
          if (!_authorizedSession(generation)) {
            onAutomationResumeRequested?.call();
            return;
          }
          _updateState(_sessionInfo.copyWith(inputOwner: newOwner));
          // A quality upgrade failure must not prevent manual control.
          await _webrtc?.setInteractive(true);
        }
      } else if (command is RemoteDisconnectCommand) {
        await terminateSession();
      } else if (command is RemoteResetCommand) {
        debugPrint('[RemoteSessionManager] Handling RemoteResetCommand');
        final currentDeviceId = signaling.deviceId;
        await WhatsAppTextValidationService.instance.clearSenderState(
          'p2p_$currentDeviceId',
        );
        if (_sessionInfo.controllerId != null) {
          await WhatsAppTextValidationService.instance.clearSenderState(
            'p2p_${currentDeviceId}_${_sessionInfo.controllerId}',
          );
        }
        await onAutomationPauseRequested?.call();
      }
    } catch (e) {
      debugPrint('[RemoteSessionManager] Error executing command $command: $e');
    }
  }

  Timer? _failureGraceTimer;

  void _handleWebRtcStateChange(RTCPeerConnectionState state) {
    debugPrint(
      '[RemoteSessionManager] WebRTC connection state changed: $state',
    );
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      _failureGraceTimer?.cancel();
      _failureGraceTimer = null;
      return;
    }
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
      debugPrint('[RemoteSessionManager] WebRTC connection closed');
      terminateSession();
    } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
      debugPrint(
        '[RemoteSessionManager] WebRTC connection failed, allowing 3s grace period for reconnect',
      );
      _failureGraceTimer?.cancel();
      _failureGraceTimer = Timer(const Duration(seconds: 3), () {
        if (_sessionInfo.state == RemoteSessionState.active &&
            _webrtc?.connectionState ==
                RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          debugPrint(
            '[RemoteSessionManager] WebRTC remained in failed state after grace period, terminating',
          );
          terminateSession();
        }
      });
    }
  }

  void _handleSessionTerminatedRemotely() {
    if (_sessionInfo.state == RemoteSessionState.active ||
        _sessionInfo.state == RemoteSessionState.connectingWebRTC) {
      debugPrint(
        '[RemoteSessionManager] Remote session terminated by signaling',
      );
      terminateSession();
    }
  }

  /// Terminate the active remote session and return to IDLE
  Future<void> terminateSession({String? error}) {
    return _termination ??= _terminateSession(
      error: error,
    ).whenComplete(() => _termination = null);
  }

  Future<void> _terminateSession({String? error}) async {
    _sessionGeneration++;
    _sessionOwnerUid = null;
    _failureGraceTimer?.cancel();
    _failureGraceTimer = null;

    final endingSessionId = _sessionInfo.activeSessionId;
    final wasControlling = _sessionInfo.inputOwner == InputOwner.remoteHuman;

    _updateState(
      _sessionInfo.copyWith(
        state: RemoteSessionState.disconnecting,
        lastError: error,
      ),
    );

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

      // Capture is stopped. Network cleanup must not delay automation resuming.
      if (wasControlling) onAutomationResumeRequested?.call();

      // Update signaling - retain new session request if one arrived during teardown!
      await signaling.setReceiverIdle(endingSessionId: endingSessionId);

      // Restore automation input ownership
      _updateState(
        _sessionInfo.copyWith(
          state: RemoteSessionState.idle,
          inputOwner: InputOwner.automation,
          activeSessionId: null,
          controllerId: null,
          connectedAt: null,
        ),
      );

      await _registerDeviceInFirestore(status: 'idle');
      debugPrint('[RemoteSessionManager] Cleaned up and returned to IDLE');
    } catch (e) {
      debugPrint('[RemoteSessionManager] Error terminating session: $e');
      _updateState(
        _sessionInfo.copyWith(
          state: RemoteSessionState.idle,
          inputOwner: InputOwner.automation,
        ),
      );
      await _registerDeviceInFirestore(status: 'idle');
    }
  }

  void _updateState(RemoteSessionInfo newInfo) {
    _sessionInfo = newInfo;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _listenerRetry?.cancel();
    _authSub?.cancel();
    _registerDeviceInFirestore(status: 'offline');
    signaling.dispose();
    _webrtc?.close();
    super.dispose();
  }
}
