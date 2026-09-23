import 'dart:async';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:pirsumoto/remote_control/remote_signaling.dart';
import 'package:pirsumoto/remote_control/remote_webrtc_receiver.dart';

// Integration coverage uses the receiver's Firestore fake for both apps.
// ignore: avoid_relative_lib_imports
import '../Pirsumoto_remote_control/lib/signaling/controller_signaling.dart';

class _Auth extends Fake implements FirebaseAuth {
  @override
  User? get currentUser => null;
}

class _Peer extends Fake implements RTCPeerConnection {
  final candidates = <RTCIceCandidate>[];
  bool remoteDescriptionSet = false;

  @override
  set onIceCandidate(Function(RTCIceCandidate candidate)? callback) {}
  @override
  set onConnectionState(Function(RTCPeerConnectionState state)? callback) {}
  @override
  set onDataChannel(Function(RTCDataChannel channel)? callback) {}
  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    remoteDescriptionSet = true;
  }

  @override
  Future<void> addCandidate(RTCIceCandidate candidate) async {
    expect(remoteDescriptionSet, isTrue);
    candidates.add(candidate);
  }

  @override
  Future<RTCSessionDescription> createAnswer([
    Map<String, dynamic>? constraints,
  ]) async => RTCSessionDescription('answer', 'answer');
  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> dispose() async {}
}

RTCIceCandidate candidate(String address) => RTCIceCandidate(
  'candidate:1 1 udp 2122260223 $address 50000 typ host',
  '0',
  0,
);

Future<void> flush() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fast Wi-Fi ICE survives publishing the session offer', () async {
    final db = FakeFirebaseFirestore();
    final controller = ControllerSignalingClient(
      firestore: db,
      auth: _Auth(),
      deviceId: 'phone',
      controllerId: 'controller',
    );
    addTearDown(controller.dispose);
    await controller.prepareSession('new');
    // setLocalDescription may emit this before requestSession is invoked.
    await controller.sendIceCandidate(
      candidate('192.168.1.20'),
      sessionId: 'new',
    );
    await controller.requestSession(
      sessionId: 'new',
      offer: RTCSessionDescription('offer', 'offer'),
      onAnswerReceived: (_) {},
      onSessionClosed: () {},
    );
    final docs =
        await db
            .collection('remote_control_sessions/phone/controller_candidates')
            .get();
    expect(docs.docs, hasLength(1));
    expect(docs.docs.single.data()['sessionId'], 'new');
  });

  test(
    'candidate listeners replay only current-session candidates, including mDNS',
    () async {
      final db = FakeFirebaseFirestore();
      final controller = ControllerSignalingClient(
        firestore: db,
        auth: _Auth(),
        deviceId: 'phone',
        controllerId: 'controller',
      );
      final receiver = RemoteSignalingService(firestore: db, deviceId: 'phone');
      addTearDown(controller.dispose);
      addTearDown(receiver.dispose);
      final fromController = <RTCIceCandidate>[];
      final fromReceiver = <RTCIceCandidate>[];
      for (final collection in [
        'controller_candidates',
        'receiver_candidates',
      ]) {
        for (final sessionId in [null, 'old', 'new']) {
          await db.collection('remote_control_sessions/phone/$collection').add({
            'sessionId': sessionId,
            'candidate': candidate('peer.local').candidate,
            'sdpMid': '0',
            'sdpMLineIndex': 0,
          });
        }
      }
      await controller.prepareSession('new');
      receiver.setActiveSessionId('new');
      controller.listenForReceiverCandidates(onCandidate: fromReceiver.add);
      receiver.listenToRemoteCandidates(onCandidate: fromController.add);
      await flush();
      expect(fromController, hasLength(1));
      expect(fromReceiver, hasLength(1));
      expect(fromReceiver.single.candidate, contains('peer.local'));
    },
  );

  test(
    'old controller teardown cannot close or erase a replacement session',
    () async {
      final db = FakeFirebaseFirestore();
      final controller = ControllerSignalingClient(
        firestore: db,
        auth: _Auth(),
        deviceId: 'phone',
        controllerId: 'controller',
      );
      await controller.prepareSession('old');
      final doc = db.doc('remote_control_sessions/phone');
      await doc.set({'sessionId': 'new', 'status': 'requested'});
      await doc.collection('controller_candidates').add({'sessionId': 'old'});
      await doc.collection('controller_candidates').add({'sessionId': 'new'});
      await controller.disconnect();
      expect((await doc.get()).data()?['status'], 'requested');
      final candidates = await doc.collection('controller_candidates').get();
      expect(candidates.docs, hasLength(1));
      expect(candidates.docs.single.data()['sessionId'], 'new');
    },
  );

  test('receiver teardown preserves a newer active session', () async {
    final db = FakeFirebaseFirestore();
    final receiver = RemoteSignalingService(firestore: db, deviceId: 'phone');
    final doc = db.doc('remote_control_sessions/phone');
    await doc.set({'sessionId': 'new', 'status': 'connected'});
    await doc.collection('receiver_candidates').add({'sessionId': 'new'});
    await receiver.setReceiverIdle(endingSessionId: 'old');
    expect((await doc.get()).data()?['status'], 'connected');
    expect(
      (await doc.collection('receiver_candidates').get()).docs,
      hasLength(1),
    );
  });

  test('late receiver answer cannot overwrite a replacement offer', () async {
    final db = FakeFirebaseFirestore();
    final receiver = RemoteSignalingService(firestore: db, deviceId: 'phone');
    final doc = db.doc('remote_control_sessions/phone');
    await doc.set({'sessionId': 'new', 'status': 'requested'});
    await expectLater(
      receiver.sendAnswer(RTCSessionDescription('answer', 'answer'), 'old'),
      throwsStateError,
    );
    expect((await doc.get()).data()?['sessionId'], 'new');
    expect((await doc.get()).data()?['status'], 'requested');
  });

  test('answer is applied once despite unrelated document updates', () async {
    final db = FakeFirebaseFirestore();
    final controller = ControllerSignalingClient(
      firestore: db,
      auth: _Auth(),
      deviceId: 'phone',
      controllerId: 'controller',
    );
    addTearDown(controller.dispose);
    var answers = 0;
    await controller.prepareSession('new');
    await controller.requestSession(
      sessionId: 'new',
      offer: RTCSessionDescription('offer', 'offer'),
      onAnswerReceived: (_) => answers++,
      onSessionClosed: () {},
    );
    final doc = db.doc('remote_control_sessions/phone');
    await doc.update({
      'status': 'connected',
      'answer': {'sdp': 'answer', 'type': 'answer'},
    });
    await flush();
    await doc.update({'updated': true});
    await flush();
    expect(answers, 1);
  });

  test(
    'receiver queues ICE during peer creation and resets SDP state on reconnect',
    () async {
      final firstPeer = _Peer();
      final secondPeer = _Peer();
      final creating = Completer<RTCPeerConnection>();
      var created = 0;
      final receiver = RemoteWebRtcReceiver(
        onLocalCandidate: (_) {},
        onCommandReceived: (_) {},
        onConnectionStateChange: (_) {},
        peerConnectionFactory:
            (_) => created++ == 0 ? creating.future : Future.value(secondPeer),
      );
      final initialization = receiver.initializePeerConnection(
        enableScreenCapture: false,
      );
      await flush();
      final early = candidate('192.168.1.20');
      await receiver.addCandidate(early);
      creating.complete(firstPeer);
      await initialization;
      expect(firstPeer.candidates, isEmpty);
      await receiver.handleOffer(RTCSessionDescription('offer', 'offer'));
      expect(firstPeer.candidates, [early]);
      await receiver.close();
      await receiver.addCandidate(candidate('192.168.1.99'));
      await receiver.initializePeerConnection(enableScreenCapture: false);
      final next = candidate('192.168.1.21');
      await receiver.addCandidate(next);
      expect(secondPeer.candidates, isEmpty);
      await receiver.handleOffer(RTCSessionDescription('offer2', 'offer'));
      expect(secondPeer.candidates, [next]);
      await receiver.close();
    },
  );
}
