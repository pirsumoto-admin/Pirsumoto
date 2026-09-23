import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:pirsumoto/remote_control/remote_session_manager.dart';
import 'package:pirsumoto/remote_control/remote_session_state.dart';
import 'package:pirsumoto/remote_control/remote_signaling.dart';

class _User extends Fake implements User {
  @override
  String get uid => 'owner';
  @override
  String get email => 'owner@example.com';
}

class _Auth extends Fake implements FirebaseAuth {
  final changes = StreamController<User?>.broadcast();
  @override
  User? currentUser;
  @override
  Stream<User?> authStateChanges() => changes.stream;
  void emit(User? user) {
    currentUser = user;
    changes.add(user);
  }
}

class _OfflineWrites extends FakeFirebaseFirestore {
  @override
  Future<T> runTransaction<T>(
    TransactionHandler<T> transactionHandler, {
    Duration timeout = const Duration(seconds: 30),
    int maxAttempts = 5,
  }) => Future.error(StateError('Startup transaction unavailable'));
}

class _Signaling extends RemoteSignalingService {
  _Signaling(FirebaseFirestore db) : super(firestore: db, deviceId: 'phone');
  int subscriptions = 0;
  int requests = 0;
  void Function(Object)? failListener;

  @override
  void listenForIncomingSession({
    required Function(String, String, String?, RTCSessionDescription, String)
    onSessionRequested,
    required Function() onSessionTerminated,
    void Function(Object)? onError,
  }) {
    subscriptions++;
    failListener = onError;
    super.listenForIncomingSession(
      onSessionRequested: (id, controller, uid, offer, type) {
        requests++;
        onSessionRequested(id, controller, uid, offer, type);
      },
      onSessionTerminated: onSessionTerminated,
      onError: onError,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Auth auth;
  late _OfflineWrites db;
  late _Signaling signaling;
  late RemoteSessionManager manager;

  setUp(() {
    auth = _Auth();
    db = _OfflineWrites();
    signaling = _Signaling(db);
    manager = RemoteSessionManager(
      signaling: signaling,
      auth: auth,
      firestore: db,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.pirsumoto/accessibility'),
          (_) async => null,
        );
  });

  tearDown(() async {
    manager.dispose();
    await auth.changes.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.pirsumoto/accessibility'),
          null,
        );
  });

  testWidgets(
    'login after startup subscribes despite failed Firestore writes',
    (tester) async {
      await manager.startListening();
      auth.emit(null);
      await tester.pump();
      expect(signaling.subscriptions, 0);
      expect(manager.sessionInfo.state, RemoteSessionState.offline);

      auth.emit(_User());
      await tester.pump();
      expect(signaling.subscriptions, 1);
      expect(manager.sessionInfo.state, RemoteSessionState.idle);
      await db.doc('remote_control_sessions/phone').set({
        'status': 'requested',
        'sessionId': 'new',
        // An unauthenticated offer is observed but must still be rejected.
        'offer': {'sdp': 'offer', 'type': 'offer'},
      });
      await tester.pump();
      expect(signaling.requests, 1);
      expect(manager.sessionInfo.state, RemoteSessionState.idle);
    },
  );

  testWidgets('repeated auth events preserve the active listener', (
    tester,
  ) async {
    await manager.startListening();
    auth.emit(_User());
    await tester.pump();
    signaling.setActiveSessionId('active');
    auth.emit(_User());
    await tester.pump();
    expect(signaling.subscriptions, 1);
    expect(signaling.activeSessionId, 'active');
  });

  testWidgets('a failed session listener is reattached', (tester) async {
    await manager.startListening();
    auth.emit(_User());
    await tester.pump();
    signaling.failListener!(StateError('Listener permission error'));
    await tester.pump(const Duration(seconds: 5));
    expect(signaling.subscriptions, 2);
  });

  testWidgets('sign out cancels listener recovery until the next login', (
    tester,
  ) async {
    await manager.startListening();
    auth.emit(_User());
    await tester.pump();
    signaling.failListener!(StateError('Listener error'));
    auth.emit(null);
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(signaling.subscriptions, 1);
    auth.emit(_User());
    await tester.pump();
    expect(signaling.subscriptions, 2);
  });
}
