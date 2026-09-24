import 'dart:async';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:pirsumoto/remote_control/remote_protocol.dart';
import 'package:pirsumoto/remote_control/remote_session_manager.dart';
import 'package:pirsumoto/remote_control/remote_session_state.dart';
import 'package:pirsumoto/remote_control/remote_signaling.dart';
import 'package:pirsumoto/remote_control/remote_video_budget.dart';
import 'package:pirsumoto/remote_control/remote_webrtc_receiver.dart';

class _User extends Fake implements User {
  @override
  String get uid => 'owner';
  @override
  String get email => 'owner@example.com';
}

class _Auth extends Fake implements FirebaseAuth {
  final changes = StreamController<User?>.broadcast();
  @override
  User? currentUser = _User();
  @override
  Stream<User?> authStateChanges() => changes.stream;
}

class _Sender extends Fake implements RTCRtpSender {
  _Sender(this.events);
  final List<String> events;
  bool accept = true;
  @override
  MediaStreamTrack? track;
  @override
  final parameters = RTCRtpParameters(encodings: [RTCRtpEncoding()]);
  @override
  Future<bool> setParameters(RTCRtpParameters parameters) async {
    events.add('fps:${parameters.encodings!.single.maxFramerate}');
    return accept;
  }
}

class _Channel extends Fake implements RTCDataChannel {
  @override
  Function(RTCDataChannelMessage)? onMessage;
  @override
  String get label => RemoteProtocolConstants.channelCommands;
  @override
  RTCDataChannelState get state => RTCDataChannelState.RTCDataChannelOpen;
  @override
  Future<void> send(RTCDataChannelMessage message) async {}
  @override
  Future<void> close() async {}
  void receive(RemoteCommand command) =>
      onMessage!(RTCDataChannelMessage(command.encode()));
}

class _Peer extends Fake implements RTCPeerConnection {
  _Peer(this.sender);
  final _Sender sender;
  @override
  Function(RTCDataChannel)? onDataChannel;
  @override
  set onIceCandidate(Function(RTCIceCandidate)? callback) {}
  @override
  set onConnectionState(Function(RTCPeerConnectionState)? callback) {}
  @override
  Future<RTCRtpSender> addTrack(
    MediaStreamTrack track, [
    MediaStream? stream,
  ]) async {
    sender.track = track;
    return sender;
  }

  @override
  Future<List<RTCRtpSender>> getSenders() async => [sender];
  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {}
  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {}
  @override
  Future<void> addCandidate(RTCIceCandidate candidate) async {}
  @override
  Future<RTCSessionDescription> createAnswer([
    Map<String, dynamic>? constraints,
  ]) async => RTCSessionDescription('answer', 'answer');
  @override
  Future<void> close() async {
    sender.events.add('peerClosed');
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeFirebaseFirestore db;
  late _Auth auth;
  late _Sender sender;
  late _Peer peer;
  late _Channel commands;
  late RemoteSessionManager manager;
  late List<String> events;
  late bool appForeground;
  late bool automationActive;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    db = FakeFirebaseFirestore();
    auth = _Auth();
    events = [];
    appForeground = true;
    automationActive = true;
    sender = _Sender(events);
    peer = _Peer(sender);
    commands = _Channel();
    manager = RemoteSessionManager(
      signaling: RemoteSignalingService(firestore: db, deviceId: 'phone'),
      isAutomationRunning: () => automationActive,
      auth: auth,
      firestore: db,
      receiverFactory:
          ({
            required onLocalCandidate,
            required onCommandReceived,
            required onConnectionStateChange,
          }) => RemoteWebRtcReceiver(
            onLocalCandidate: onLocalCandidate,
            onCommandReceived: onCommandReceived,
            onConnectionStateChange: onConnectionStateChange,
            peerConnectionFactory: (_) async => peer,
          ),
    );
    manager.onAutomationPauseRequested = () async {
      events.add('pause');
    };
    manager.onAutomationResumeRequested = () {
      events.add('resume');
    };
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.pirsumoto/accessibility'),
      (call) async {
        events.add(call.method);
        if (call.method == 'isAppInForeground') return appForeground;
        if (call.method == 'getScreenDimensions') {
          return {'width': 1080, 'height': 2400, 'density': 3.0};
        }
        if (call.method == 'getDeviceInfo') return {'model': 'Phone'};
        return true;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      (call) async {
        if (call.method == 'requestCapturePermission') return true;
        if (call.method == 'getDisplayMedia') {
          return {
            'streamId': 'screen',
            'audioTracks': <dynamic>[],
            'videoTracks': [
              {
                'id': 'video',
                'label': 'screen',
                'kind': 'video',
                'enabled': true,
              },
            ],
          };
        }
        return null;
      },
    );
  });
  tearDown(() async {
    manager.dispose();
    await auth.changes.close();
    debugDefaultTargetPlatformOverride = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.pirsumoto/accessibility'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      null,
    );
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  Future<void> connect({bool expectActive = true}) async {
    await db.doc('remote_control_devices/phone').set({'ownerUid': 'owner'});
    await manager.startListening();
    auth.changes.add(auth.currentUser);
    await settle();
    await db.doc('remote_control_sessions/phone').set({
      'status': 'requested',
      'sessionId': 'session',
      'controllerUid': 'owner',
      'offer': {'sdp': 'offer', 'type': 'offer'},
    });
    for (var i = 0; i < 10; i++) {
      await settle();
    }
    if (expectActive) {
      expect(manager.sessionInfo.state, RemoteSessionState.active);
      peer.onDataChannel!(commands);
    }
  }

  test(
    'viewing cannot steal foreground focus from running automation',
    () async {
      appForeground = false;
      await connect(expectActive: false);
      expect(events, isNot(contains('bringAppToForeground')));
      expect(events, isNot(contains('startRemoteCaptureService')));
      expect(events, isNot(contains('pause')));
      expect(events, isNot(contains('resume')));
      expect(manager.sessionInfo.state, RemoteSessionState.idle);
    },
  );

  test('viewing and disconnecting never pause or resume automation', () async {
    await connect();
    expect(events, isNot(contains('pause')));
    expect(sender.parameters.encodings!.single.maxFramerate, 10);
    expect(sender.parameters.encodings!.single.scaleResolutionDownBy, 1.5);
    await manager.terminateSession();
    expect(events, isNot(contains('resume')));
  });

  test(
    'first video acknowledgement removes all bootstrap cache work',
    () async {
      await connect();
      expect(
        events.where((e) => e == 'startScreenFrameRepeater'),
        hasLength(1),
      );
      commands.receive(RemotePingCommand(clientTimestamp: 1));
      await settle();
      commands.receive(RemotePingCommand(clientTimestamp: 2));
      await settle();
      expect(events.where((e) => e == 'stopScreenFrameRepeater'), hasLength(1));
      await manager.terminateSession();
      expect(events.where((e) => e == 'stopScreenFrameRepeater'), hasLength(1));
    },
  );

  test(
    'takeover pauses before increasing video work; release lowers work before resume',
    () async {
      await connect();
      events.clear();
      commands.receive(const RemoteHandoverCommand(owner: 'remoteHuman'));
      await settle();
      expect(events, ['pause', 'fps:30']);
      expect(manager.sessionInfo.inputOwner, InputOwner.remoteHuman);
      events.clear();
      commands.receive(const RemoteHandoverCommand(owner: 'automation'));
      await settle();
      expect(events, ['fps:10', 'resume']);
      expect(manager.sessionInfo.inputOwner, InputOwner.automation);
      events.clear();
      commands.receive(const RemoteHandoverCommand(owner: 'automation'));
      await settle();
      expect(events, isEmpty);
      await manager.terminateSession();
    },
  );

  test(
    'failed initial budget closes projection without touching automation',
    () async {
      sender.accept = false;
      await connect(expectActive: false);
      expect(events, contains('peerClosed'));
      expect(events, isNot(contains('pause')));
      expect(events, isNot(contains('resume')));
      expect(manager.sessionInfo.state, RemoteSessionState.idle);
      expect(
        (await db.doc('remote_control_sessions/phone').get()).data()?['answer'],
        isNull,
      );
    },
  );

  test('failed downgrade closes capture before resuming automation', () async {
    await connect();
    commands.receive(const RemoteHandoverCommand(owner: 'remoteHuman'));
    await settle();
    events.clear();
    sender.accept = false;
    commands.receive(const RemoteHandoverCommand(owner: 'automation'));
    await settle();
    expect(events.indexOf('peerClosed'), greaterThanOrEqualTo(0));
    expect(events.indexOf('resume'), greaterThan(events.indexOf('peerClosed')));
    expect(events.where((e) => e == 'resume'), hasLength(1));
    expect(manager.sessionInfo.state, RemoteSessionState.idle);
  });

  test(
    'failed pause leaves passive video limits and automation ownership',
    () async {
      await connect();
      events.clear();
      manager.onAutomationPauseRequested = () async {
        throw StateError('pause failed');
      };
      commands.receive(const RemoteHandoverCommand(owner: 'remoteHuman'));
      await settle();
      expect(events, isEmpty);
      expect(manager.sessionInfo.inputOwner, InputOwner.automation);
      expect(sender.parameters.encodings!.single.maxFramerate, 10);
      await manager.terminateSession();
    },
  );

  test(
    'passive budget handles landscape and never upscales small displays',
    () async {
      await RemoteVideoBudget.apply(
        sender,
        width: 2400,
        height: 1080,
        interactive: false,
      );
      expect(sender.parameters.encodings!.single.scaleResolutionDownBy, 1.5);
      expect(sender.parameters.encodings!.single.maxBitrate, 1500000);
      await RemoteVideoBudget.apply(
        sender,
        width: 480,
        height: 800,
        interactive: false,
      );
      expect(sender.parameters.encodings!.single.scaleResolutionDownBy, 1.0);
      sender.accept = false;
      await expectLater(
        RemoteVideoBudget.apply(
          sender,
          width: 1080,
          height: 2400,
          interactive: false,
        ),
        throwsStateError,
      );
    },
  );
}
