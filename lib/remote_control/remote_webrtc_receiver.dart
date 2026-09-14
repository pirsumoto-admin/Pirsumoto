import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'remote_protocol.dart';

class RemoteWebRtcReceiver {
  RTCPeerConnection? _peerConnection;
  MediaStream? _screenStream;
  RTCDataChannel? _commandsChannel;
  RTCDataChannel? _pointerChannel;
  RTCDataChannel? _chatChannel;

  final Function(RTCIceCandidate candidate) onLocalCandidate;
  final Function(RemoteCommand command) onCommandReceived;
  final Function(RTCPeerConnectionState state) onConnectionStateChange;

  RemoteWebRtcReceiver({
    required this.onLocalCandidate,
    required this.onCommandReceived,
    required this.onConnectionStateChange,
  });

  RTCPeerConnectionState? get connectionState => _peerConnection?.connectionState;

  /// Default WebRTC configuration with Google STUN
  Map<String, dynamic> _buildRtcConfig({List<Map<String, dynamic>>? customIceServers}) {
    return {
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
  }

  /// Initialize WebRTC PeerConnection and attach display capture stream (if enabled)
  Future<void> initializePeerConnection({
    List<Map<String, dynamic>>? iceServers,
    int width = 1080,
    int height = 2400,
    bool enableScreenCapture = true,
  }) async {
    await close();

    final config = _buildRtcConfig(customIceServers: iceServers);
    _peerConnection = await createPeerConnection(config);

    // ICE Candidate handler
    _peerConnection!.onIceCandidate = (candidate) {
      if (candidate.candidate != null) {
        onLocalCandidate(candidate);
      }
    };

    // Connection state monitor
    _peerConnection!.onConnectionState = (state) {
      debugPrint('[ReceiverWebRTC] Connection state: $state');
      onConnectionStateChange(state);
    };

    // Listen for incoming DataChannels created by the controller
    _peerConnection!.onDataChannel = (channel) {
      debugPrint('[ReceiverWebRTC] Incoming data channel: ${channel.label}');
      if (channel.label == RemoteProtocolConstants.channelCommands) {
        _setupCommandsChannel(channel);
      } else if (channel.label == RemoteProtocolConstants.channelPointer) {
        _setupPointerChannel(channel);
      } else if (channel.label == RemoteProtocolConstants.channelChat) {
        _setupChatChannel(channel);
      }
    };

    if (enableScreenCapture) {
      // Start Screen Capture stream via MediaProjection with native aspect ratio
      try {
        _screenStream = await navigator.mediaDevices.getDisplayMedia({
          'video': {
            'width': width,
            'height': height,
            'frameRate': 30,
          },
          'audio': false,
        });

        for (final track in _screenStream!.getVideoTracks()) {
          track.enabled = true;
          await _peerConnection!.addTrack(track, _screenStream!);
        }
        debugPrint('[ReceiverWebRTC] Screen video track added to PeerConnection ($width x $height)');
      } catch (e) {
        debugPrint('[ReceiverWebRTC] Error acquiring screen stream: $e');
        rethrow;
      }
    } else {
      debugPrint('[ReceiverWebRTC] Screen capture disabled (chat mode)');
    }
  }

  /// Setup the reliable remoteCommands DataChannel
  void _setupCommandsChannel(RTCDataChannel channel) {
    _commandsChannel = channel;
    _commandsChannel!.onMessage = (data) {
      if (data.isBinary) return;
      final command = RemoteCommand.decode(data.text);
      if (command != null) {
        // Automatically respond to ping with pong for round-trip latency measurement
        if (command is RemotePingCommand) {
          sendReply(RemotePongCommand(clientTimestamp: command.clientTimestamp));
        }
        onCommandReceived(command);
      }
    };
  }

  /// Setup the unreliable/fast remotePointer DataChannel
  void _setupPointerChannel(RTCDataChannel channel) {
    _pointerChannel = channel;
    _pointerChannel!.onMessage = (data) {
      if (data.isBinary) return;
      final command = RemoteCommand.decode(data.text);
      if (command != null) {
        onCommandReceived(command);
      }
    };
  }

  /// Setup the reliable remoteChat DataChannel
  void _setupChatChannel(RTCDataChannel channel) {
    _chatChannel = channel;
    _chatChannel!.onMessage = (data) {
      if (data.isBinary) return;
      final command = RemoteCommand.decode(data.text);
      if (command != null) {
        onCommandReceived(command);
      }
    };
  }

  /// Send a command reply back to the controller (e.g. Pong or Dimensions)
  void sendReply(RemoteCommand command) {
    if (_commandsChannel != null && _commandsChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
      _commandsChannel!.send(RTCDataChannelMessage(command.encode()));
    }
  }

  /// Send chat message/reply back to the controller
  void sendChatReply(RemoteCommand command) {
    if (_chatChannel != null && _chatChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
      _chatChannel!.send(RTCDataChannelMessage(command.encode()));
    } else {
      sendReply(command);
    }
  }

  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _hasRemoteDescription = false;

  /// Handle incoming SDP offer from controller and generate SDP answer
  Future<RTCSessionDescription> handleOffer(RTCSessionDescription offer) async {
    if (_peerConnection == null) {
      throw StateError('PeerConnection is not initialized');
    }

    await _peerConnection!.setRemoteDescription(offer);
    _hasRemoteDescription = true;

    // Drain queued candidates now that remote description is set
    for (final candidate in _pendingCandidates) {
      try {
        await _peerConnection!.addCandidate(candidate);
        debugPrint('[ReceiverWebRTC] Added queued remote ICE candidate');
      } catch (e) {
        debugPrint('[ReceiverWebRTC] Error adding queued candidate: $e');
      }
    }
    _pendingCandidates.clear();

    final answer = await _peerConnection!.createAnswer(<String, dynamic>{
      'mandatory': <String, dynamic>{
        'OfferToReceiveAudio': 'false',
        'OfferToReceiveVideo': 'true',
      },
      'optional': const <dynamic>[],
    });
    await _peerConnection!.setLocalDescription(answer);
    return answer;
  }

  /// Add remote ICE candidate sent by controller
  Future<void> addCandidate(RTCIceCandidate candidate) async {
    if (_peerConnection == null) return;

    if (!_hasRemoteDescription) {
      debugPrint('[ReceiverWebRTC] Queuing ICE candidate until remote description set');
      _pendingCandidates.add(candidate);
      return;
    }

    try {
      await _peerConnection!.addCandidate(candidate);
      debugPrint('[ReceiverWebRTC] Added remote ICE candidate');
    } catch (e) {
      debugPrint('[ReceiverWebRTC] Error adding candidate: $e');
    }
  }

  /// Stop screen streaming and close WebRTC peer connection
  Future<void> close() async {
    try {
      _commandsChannel?.close();
      _pointerChannel?.close();
      _commandsChannel = null;
      _pointerChannel = null;

      _screenStream?.getTracks().forEach((track) => track.stop());
      await _screenStream?.dispose();
      _screenStream = null;

      await _peerConnection?.close();
      await _peerConnection?.dispose();
      _peerConnection = null;
    } catch (e) {
      debugPrint('[ReceiverWebRTC] Error closing WebRTC: $e');
    }
  }
}
