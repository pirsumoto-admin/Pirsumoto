import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'remote_protocol.dart';
import 'webrtc_ice_config.dart';
import 'remote_video_budget.dart';

typedef RemoteWebRtcReceiverFactory =
    RemoteWebRtcReceiver Function({
      required Function(RTCIceCandidate candidate) onLocalCandidate,
      required Function(RemoteCommand command) onCommandReceived,
      required Function(RTCPeerConnectionState state) onConnectionStateChange,
    });

class RemoteWebRtcReceiver {
  RTCPeerConnection? _peerConnection;
  final Future<RTCPeerConnection> Function(Map<String, dynamic>) _createPeer;
  bool _closed = true;
  bool _hasScreenCapture = false;
  bool _frameRepeaterRunning = false;
  int _captureWidth = 1080;
  int _captureHeight = 2400;
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
    Future<RTCPeerConnection> Function(Map<String, dynamic>)?
    peerConnectionFactory,
  }) : _createPeer =
           peerConnectionFactory ?? ((config) => createPeerConnection(config));

  RTCPeerConnectionState? get connectionState =>
      _peerConnection?.connectionState;

  /// Default WebRTC configuration with Google STUN + GCP TURN
  Map<String, dynamic> _buildRtcConfig({
    List<Map<String, dynamic>>? customIceServers,
  }) {
    return {
      'iceServers': customIceServers ?? WebRtcIceConfig.defaultIceServers,
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
    _closed = false;
    _hasScreenCapture = enableScreenCapture;
    _captureWidth = width;
    _captureHeight = height;

    final config = _buildRtcConfig(customIceServers: iceServers);
    final peer = await _createPeer(config);
    if (_closed) {
      await peer.close();
      await peer.dispose();
      throw StateError('Screen-sharing session ended during initialization');
    }
    _peerConnection = peer;

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
          'video': {'width': width, 'height': height, 'frameRate': 30},
          'audio': false,
        });

        for (final track in _screenStream!.getVideoTracks()) {
          track.enabled = true;
          await _peerConnection!.addTrack(track, _screenStream!);
          if (defaultTargetPlatform == TargetPlatform.android) {
            await const MethodChannel(
              'com.pirsumoto/accessibility',
            ).invokeMethod('startScreenFrameRepeater', {'trackId': track.id});
            _frameRepeaterRunning = true;
          }
        }
        debugPrint(
          '[ReceiverWebRTC] Screen video track added to PeerConnection ($width x $height)',
        );
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
          // Controllers only start pinging after a video frame was rendered.
          // The bootstrap cache is no longer needed: remove all copying/replay
          // work from the live capture path while automation is running.
          unawaited(_stopFrameRepeater());
          sendReply(
            RemotePongCommand(clientTimestamp: command.clientTimestamp),
          );
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
    if (_commandsChannel != null &&
        _commandsChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
      _commandsChannel!.send(RTCDataChannelMessage(command.encode()));
    }
  }

  /// Send chat message/reply back to the controller
  void sendChatReply(RemoteCommand command) {
    if (_chatChannel != null &&
        _chatChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
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
    // Apply real sender limits; Android getDisplayMedia ignores width/fps hints.
    if (_hasScreenCapture) await setInteractive(false);
    return answer;
  }

  Future<void> setInteractive(bool interactive) async {
    final peer = _peerConnection;
    if (_closed || peer == null || !_hasScreenCapture) return;
    final senders = await peer.getSenders();
    var applied = false;
    for (final sender in senders) {
      if (_closed || _peerConnection != peer) return;
      if (sender.track?.kind != 'video') continue;
      await RemoteVideoBudget.apply(
        sender,
        width: _captureWidth,
        height: _captureHeight,
        interactive: interactive,
      );
      applied = true;
    }
    if (!applied) {
      throw StateError('Screen capture has no video sender to limit');
    }
  }

  Future<void> _stopFrameRepeater() async {
    if (!_frameRepeaterRunning) return;
    _frameRepeaterRunning = false;
    try {
      await const MethodChannel(
        'com.pirsumoto/accessibility',
      ).invokeMethod('stopScreenFrameRepeater');
    } catch (error) {
      _frameRepeaterRunning = true;
      debugPrint('[ReceiverWebRTC] Could not release bootstrap cache: $error');
    }
  }

  /// Add remote ICE candidate sent by controller
  Future<void> addCandidate(RTCIceCandidate candidate) async {
    if (_closed) return;

    if (_peerConnection == null || !_hasRemoteDescription) {
      debugPrint(
        '[ReceiverWebRTC] Queuing ICE candidate until remote description set',
      );
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
    _closed = true;
    _hasRemoteDescription = false;
    _pendingCandidates.clear();
    final stream = _screenStream;
    final peer = _peerConnection;
    final channels = [_commandsChannel, _pointerChannel, _chatChannel];
    _screenStream = null;
    _peerConnection = null;
    _commandsChannel = null;
    _pointerChannel = null;
    _chatChannel = null;

    // One failed disposal must not keep capture or another channel alive.
    Future<void> release(Future<dynamic> Function() action) async {
      try {
        await action();
      } catch (error) {
        debugPrint('[ReceiverWebRTC] Cleanup failed: $error');
      }
    }

    await _stopFrameRepeater();
    _hasScreenCapture = false;
    for (final channel in channels) {
      if (channel != null) await release(channel.close);
    }
    if (stream != null) {
      for (final track in stream.getTracks()) {
        await release(track.stop);
      }
      await release(stream.dispose);
    }
    if (peer != null) {
      await release(peer.close);
      await release(peer.dispose);
    }
  }
}
