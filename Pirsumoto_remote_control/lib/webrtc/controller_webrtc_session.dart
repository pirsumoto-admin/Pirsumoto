import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../remote/remote_protocol.dart';
import '../signaling/controller_signaling.dart';

class ControllerWebRtcSession extends ChangeNotifier {
  final ControllerSignalingClient signaling;
  final String sessionType; // 'remote_control' or 'chat'
  final RTCVideoRenderer videoRenderer = RTCVideoRenderer();

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _commandsChannel;
  RTCDataChannel? _pointerChannel;
  RTCDataChannel? _chatChannel;

  final _chatReplyController = StreamController<RemoteChatReplyMessage>.broadcast();
  Stream<RemoteChatReplyMessage> get chatReplies => _chatReplyController.stream;

  final _chatStatusController = StreamController<RemoteChatStatusMessage>.broadcast();
  Stream<RemoteChatStatusMessage> get chatStatuses => _chatStatusController.stream;

  bool _isConnecting = false;
  bool get isConnecting => _isConnecting;

  bool _isConnected = false;
  bool get isConnected => _isConnected;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  int _pingMs = 0;
  int get pingMs => _pingMs;

  int _remoteWidth = 1080;
  int _remoteHeight = 2400;
  double get remoteAspectRatio => _remoteWidth / _remoteHeight;

  Timer? _pingTimer;

  ControllerWebRtcSession({
    required this.signaling,
    this.sessionType = 'remote_control',
  });

  Future<void> initRenderer() async {
    await videoRenderer.initialize();
    videoRenderer.onResize = () {
      debugPrint('[ControllerWebRTC] videoRenderer onResize: ${videoRenderer.videoWidth}x${videoRenderer.videoHeight}');
      if (videoRenderer.videoWidth > 0 && videoRenderer.videoHeight > 0) {
        _remoteWidth = videoRenderer.videoWidth;
        _remoteHeight = videoRenderer.videoHeight;
      }
      notifyListeners();
    };
    videoRenderer.onFirstFrameRendered = () {
      debugPrint('[ControllerWebRTC] videoRenderer onFirstFrameRendered!');
      notifyListeners();
    };
  }

  /// Connect to the remote receiver
  Future<void> connect({List<Map<String, dynamic>>? customIceServers}) async {
    if (_peerConnection != null) {
      await disconnect();
    }

    _isConnecting = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final config = {
        'iceServers': customIceServers ??
            [
              {'urls': 'stun:stun.l.google.com:19302'},
              {'urls': 'stun:stun1.l.google.com:19302'},
            ],
        'sdpSemantics': 'unified-plan',
        'bundlePolicy': 'max-bundle',
        'rtcpMuxPolicy': 'require',
        'mandatory': {},
        'optional': [
          {'DtlsSrtpKeyAgreement': true},
        ],
      };

      _peerConnection = await createPeerConnection(config);

      // On ICE candidate, send to signaling
      _peerConnection!.onIceCandidate = (candidate) {
        if (candidate.candidate != null) {
          signaling.sendIceCandidate(candidate);
        }
      };

      void bindStream(MediaStream stream) {
        for (final track in stream.getVideoTracks()) {
          try {
            track.enabled = true;
          } catch (_) {}
        }
        if (videoRenderer.srcObject?.id == stream.id) {
          debugPrint('[ControllerWebRTC] Stream ${stream.id} already bound');
          return;
        }
        debugPrint('[ControllerWebRTC] Binding stream ${stream.id} to videoRenderer');
        videoRenderer.srcObject = stream;
        notifyListeners();
      }

      // Listen for remote video track
      _peerConnection!.onTrack = (RTCTrackEvent event) async {
        debugPrint('[ControllerWebRTC] Received remote track: ${event.track.kind}, streams: ${event.streams.length}');
        try {
          event.track.enabled = true;
        } catch (_) {}

        if (event.track.kind == 'video') {
          MediaStream stream;
          if (event.streams.isNotEmpty) {
            stream = event.streams[0];
          } else {
            stream = await createLocalMediaStream('remote_stream');
            stream.addTrack(event.track);
          }
          bindStream(stream);
        }
      };

      _peerConnection!.onAddStream = (MediaStream stream) {
        debugPrint('[ControllerWebRTC] onAddStream received with ${stream.getVideoTracks().length} video tracks');
        bindStream(stream);
      };

      // Ensure Unified Plan SDP includes m=video in recvonly direction
      try {
        await _peerConnection!.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
          init: RTCRtpTransceiverInit(
            direction: TransceiverDirection.RecvOnly,
          ),
        );
      } catch (e) {
        debugPrint('[ControllerWebRTC] addTransceiver note: $e');
      }

      // Create reliable data channel for commands
      final cmdInit = RTCDataChannelInit()
        ..ordered = true
        ..maxRetransmits = -1;
      _commandsChannel = await _peerConnection!.createDataChannel(
        RemoteProtocolConstants.channelCommands,
        cmdInit,
      );
      _setupCommandsChannel();

      // Create unreliable/fast data channel for pointer (needed for remote gestures)
      final ptrInit = RTCDataChannelInit()
        ..ordered = false
        ..maxRetransmits = 0;
      _pointerChannel = await _peerConnection!.createDataChannel(
        RemoteProtocolConstants.channelPointer,
        ptrInit,
      );

      // Create dedicated reliable data channel for chat messages and media transfer
      final chatInit = RTCDataChannelInit()
        ..ordered = true
        ..maxRetransmits = -1;
      _chatChannel = await _peerConnection!.createDataChannel(
        RemoteProtocolConstants.channelChat,
        chatInit,
      );
      _setupChatChannel();

      // Create SDP Offer
      final offerConstraints = <String, dynamic>{
        'mandatory': {
          'OfferToReceiveAudio': false,
          'OfferToReceiveVideo': true,
        },
        'optional': [],
      };

      final offer = await _peerConnection!.createOffer(offerConstraints);
      await _peerConnection!.setLocalDescription(offer);

      final sessionId = 'session_${DateTime.now().millisecondsSinceEpoch}';

      final List<RTCIceCandidate> pendingCandidates = [];
      bool hasRemoteDescription = false;

      // Start listening to receiver ICE candidates
      signaling.listenForReceiverCandidates(
        onCandidate: (candidate) async {
          if (!hasRemoteDescription) {
            debugPrint('[ControllerWebRTC] Queuing receiver candidate until answer set');
            pendingCandidates.add(candidate);
            return;
          }
          try {
            await _peerConnection?.addCandidate(candidate);
            debugPrint('[ControllerWebRTC] Added receiver ICE candidate');
          } catch (e) {
            debugPrint('[ControllerWebRTC] Error adding receiver candidate: $e');
          }
        },
      );

      // Request session via signaling
      await signaling.requestSession(
        sessionId: sessionId,
        offer: offer,
        sessionType: sessionType,
        onAnswerReceived: (answer) async {
          debugPrint('[ControllerWebRTC] Received SDP answer');
          await _peerConnection?.setRemoteDescription(answer);
          hasRemoteDescription = true;

          for (final candidate in pendingCandidates) {
            try {
              await _peerConnection?.addCandidate(candidate);
              debugPrint('[ControllerWebRTC] Added queued receiver candidate');
            } catch (e) {
              debugPrint('[ControllerWebRTC] Error adding queued receiver candidate: $e');
            }
          }
          pendingCandidates.clear();

          _isConnected = true;
          _isConnecting = false;
          _startPingTimer();
          notifyListeners();
        },
        onSessionClosed: () {
          disconnect();
        },
      );
    } catch (e) {
      debugPrint('[ControllerWebRTC] Connection failed: $e');
      _errorMessage = e.toString();
      _isConnecting = false;
      _isConnected = false;
      notifyListeners();
    }
  }

  void _setupCommandsChannel() {
    _commandsChannel?.onMessage = (RTCDataChannelMessage data) {
      if (data.isBinary) return;
      final command = RemoteCommand.decode(data.text);
      if (command is RemotePongCommand) {
        final now = DateTime.now().millisecondsSinceEpoch;
        _pingMs = (now - command.clientTimestamp).clamp(0, 5000);
        notifyListeners();
      } else if (command is RemoteDimensionsCommand) {
        _remoteWidth = command.width;
        _remoteHeight = command.height;
        debugPrint('[ControllerWebRTC] Remote dimensions: ${_remoteWidth}x$_remoteHeight');
        notifyListeners();
      } else if (command is RemoteChatReplyMessage) {
        _chatReplyController.add(command);
      } else if (command is RemoteChatStatusMessage) {
        _chatStatusController.add(command);
      }
    };
  }

  void _setupChatChannel() {
    _chatChannel?.onMessage = (RTCDataChannelMessage data) {
      if (data.isBinary) return;
      final command = RemoteCommand.decode(data.text);
      if (command is RemoteChatReplyMessage) {
        _chatReplyController.add(command);
      } else if (command is RemoteChatStatusMessage) {
        _chatStatusController.add(command);
      }
    };
  }

  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_isConnected) {
        final now = DateTime.now().millisecondsSinceEpoch;
        sendCommand(RemotePingCommand(clientTimestamp: now));
      }
    });
  }

  /// Send command over reliable DataChannel
  void sendCommand(RemoteCommand command) {
    if (_commandsChannel != null && _commandsChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
      _commandsChannel!.send(RTCDataChannelMessage(command.encode()));
    }
  }

  /// Send chat message/command over chat DataChannel (or fallback to commands channel)
  void sendChatCommand(RemoteCommand command) {
    if (_chatChannel != null && _chatChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
      _chatChannel!.send(RTCDataChannelMessage(command.encode()));
    } else {
      sendCommand(command);
    }
  }

  /// Send text chat message
  void sendChatMessage(String text, {String? senderName}) {
    final msg = RemoteChatTextMessage(
      id: 'msg_${DateTime.now().millisecondsSinceEpoch}',
      text: text,
      senderName: senderName,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    sendChatCommand(msg);
  }

  /// Send a media file (image, audio, video) in 32KB chunks over WebRTC DataChannel
  Future<void> sendChatMediaFile({
    required File file,
    required String mediaType, // 'image', 'audio', 'video'
    String? caption,
    Function(double progress)? onProgress,
  }) async {
    final bytes = await file.readAsBytes();
    final fileName = file.path.split(RegExp(r'[/\\]')).last;
    final mediaId = 'media_${DateTime.now().millisecondsSinceEpoch}_${fileName.hashCode.abs()}';
    final messageId = 'msg_${DateTime.now().millisecondsSinceEpoch}';

    const chunkSize = 32 * 1024; // 32KB
    final totalChunks = (bytes.length / chunkSize).ceil();

    debugPrint('[ControllerWebRTC] Sending $mediaType "$fileName" ($totalChunks chunks, ${bytes.length} bytes)');

    for (int i = 0; i < totalChunks; i++) {
      final start = i * chunkSize;
      final end = (start + chunkSize < bytes.length) ? start + chunkSize : bytes.length;
      final chunkBytes = bytes.sublist(start, end);
      final base64Data = base64Encode(chunkBytes);

      final chunkCommand = RemoteChatMediaChunk(
        mediaId: mediaId,
        messageId: messageId,
        mediaType: mediaType,
        fileName: fileName,
        chunkIndex: i,
        totalChunks: totalChunks,
        data: base64Data,
        caption: (i == 0) ? caption : null,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );

      sendChatCommand(chunkCommand);
      onProgress?.call((i + 1) / totalChunks);

      // Brief yield to prevent buffer overflow on large files
      if (totalChunks > 1) {
        await Future.delayed(const Duration(milliseconds: 8));
      }
    }

    debugPrint('[ControllerWebRTC] Finished sending $mediaType "$fileName"');
  }

  /// Send pointer/drag over fast DataChannel
  void sendPointer(RemoteCommand command) {
    if (_pointerChannel != null && _pointerChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
      _pointerChannel!.send(RTCDataChannelMessage(command.encode()));
    } else {
      sendCommand(command);
    }
  }

  // --- Convenience action helpers ---

  void sendTap(double normalizedX, double normalizedY) {
    sendCommand(RemoteTapCommand(x: normalizedX, y: normalizedY));
  }

  void sendLongPress(double normalizedX, double normalizedY, {int durationMs = 700}) {
    sendCommand(RemoteLongPressCommand(x: normalizedX, y: normalizedY, durationMs: durationMs));
  }

  void sendSwipe(double startX, double startY, double endX, double endY, {int durationMs = 300}) {
    sendCommand(RemoteSwipeCommand(
      startX: startX,
      startY: startY,
      endX: endX,
      endY: endY,
      durationMs: durationMs,
    ));
  }

  void sendKey(String key) {
    sendCommand(RemoteKeyCommand(key: key));
  }

  void sendBack() {
    sendKey(RemoteProtocolConstants.keyBack);
  }

  void sendHome() {
    sendKey(RemoteProtocolConstants.keyHome);
  }

  void sendText(String text) {
    sendCommand(RemoteTextCommand(text: text));
  }

  void sendHandover(String owner) {
    sendCommand(RemoteHandoverCommand(owner: owner));
  }

  Future<void> disconnect() async {
    _pingTimer?.cancel();
    _pingTimer = null;

    try {
      sendCommand(const RemoteDisconnectCommand());
    } catch (_) {}

    await signaling.disconnect();

    try {
      _chatChannel?.close();
      _commandsChannel?.close();
      _pointerChannel?.close();
      await _peerConnection?.close();
      await _peerConnection?.dispose();
    } catch (_) {}

    _peerConnection = null;
    _chatChannel = null;
    _commandsChannel = null;
    _pointerChannel = null;
    videoRenderer.srcObject = null;

    _isConnected = false;
    _isConnecting = false;
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    videoRenderer.dispose();
    _chatReplyController.close();
    _chatStatusController.close();
    super.dispose();
  }
}
