import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'remote_protocol.dart';
import 'webrtc_ice_config.dart';
import 'remote_video_budget.dart';
import 'remote_session_manager.dart' show RemoteAutomationGate;

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
  int _captureWidth = 540;
  int _captureHeight = 1200;
  static MediaStream? _screenStream;
  RTCRtpSender? _activeVideoSender;
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

  /// Dedicated method to acquire or reuse screen capture stream across WebRTC reconnects
  Future<bool> ensureScreenCapture({
    int width = 540,
    int height = 1200,
    int frameRate = 15,
  }) async {
    final existingTracks = _screenStream?.getVideoTracks() ?? const [];
    if (_screenStream != null &&
        existingTracks.isNotEmpty &&
        existingTracks.first.enabled) {
      _hasScreenCapture = true;
      return true;
    }
    try {
      _screenStream = await navigator.mediaDevices.getDisplayMedia({
        'video': {
          'width': width,
          'height': height,
          'frameRate': frameRate,
        },
        'audio': false,
      });
      _hasScreenCapture =
          _screenStream != null && _screenStream!.getVideoTracks().isNotEmpty;
      return _hasScreenCapture;
    } catch (e) {
      _hasScreenCapture = false;
      return false;
    }
  }

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
    int width = 540,
    int height = 1200,
    bool enableScreenCapture = true,
  }) async {
    await close(releaseScreenCapture: false);
    _closed = false;
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
      final success = await ensureScreenCapture(
        width: width,
        height: height,
        frameRate: 15,
      );
      if (!success || _screenStream == null) {
        throw StateError('Failed to ensure screen capture');
      }

      for (final track in _screenStream!.getVideoTracks()) {
        track.enabled = true;
        _activeVideoSender =
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
    } else {
      _hasScreenCapture = false;
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
        } else if (command is RemoteRequestFrameCommand) {
          unawaited(retriggerFrameRepeater());
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
      if (!RemoteAutomationGate.isInteractiveTakeover) return;
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

  Future<void> retriggerFrameRepeater() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final track = _screenStream?.getVideoTracks().firstOrNull;
    if (track != null) {
      try {
        await const MethodChannel(
          'com.pirsumoto/accessibility',
        ).invokeMethod('startScreenFrameRepeater', {'trackId': track.id});
        _frameRepeaterRunning = true;
        debugPrint('[ReceiverWebRTC] Re-triggered ScreenCaptureFrameRepeater');
      } catch (error) {
        debugPrint('[ReceiverWebRTC] Could not re-trigger frame repeater: $error');
      }
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
  Future<void> close({bool releaseScreenCapture = false}) async {
    _closed = true;
    _hasRemoteDescription = false;
    _pendingCandidates.clear();
    final peer = _peerConnection;
    final channels = [_commandsChannel, _pointerChannel, _chatChannel];
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

    if (_activeVideoSender != null) {
      try {
        await _activeVideoSender!.replaceTrack(null);
      } catch (e) {
        debugPrint(
          '[ReceiverWebRTC] Error detaching activeVideoSender track: $e',
        );
      }
      if (peer != null) {
        try {
          await peer.removeTrack(_activeVideoSender!);
        } catch (_) {}
      }
      _activeVideoSender = null;
    }

    for (final channel in channels) {
      if (channel != null) await release(channel.close);
    }

    if (releaseScreenCapture) {
      final stream = _screenStream;
      _screenStream = null;
      _hasScreenCapture = false;
      if (stream != null) {
        for (final track in stream.getTracks()) {
          await release(track.stop);
        }
        await release(stream.dispose);
      }
    }

    if (peer != null) {
      await release(peer.close);
      await release(peer.dispose);
    }
  }
}
