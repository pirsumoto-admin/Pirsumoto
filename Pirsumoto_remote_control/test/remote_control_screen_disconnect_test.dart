import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:pirsumoto_remote_control/ui/remote_control_screen.dart';
import 'package:pirsumoto_remote_control/webrtc/controller_webrtc_session.dart';
import 'package:pirsumoto_remote_control/signaling/controller_signaling.dart';

class MockSignalingClient extends Fake implements ControllerSignalingClient {
  @override
  String get deviceId => 'test_device_123';
}

class TestControllerWebRtcSession extends ChangeNotifier
    implements ControllerWebRtcSession {
  @override
  final ControllerSignalingClient signaling = MockSignalingClient();

  @override
  final String sessionType = 'remote_control';

  bool _isConnected = true;
  final bool _isConnecting = false;
  int disconnectCallCount = 0;
  int disposeCallCount = 0;
  List<String> handoverOwners = [];

  @override
  bool get isConnected => _isConnected;

  @override
  bool get isConnecting => _isConnecting;

  @override
  bool get hasVideoFrame => true;

  @override
  String? get errorMessage => null;

  @override
  double get remoteAspectRatio => 9 / 16;

  @override
  RTCVideoRenderer get videoRenderer => FakeRTCVideoRenderer();

  @override
  void sendHandover(String owner) {
    handoverOwners.add(owner);
  }

  @override
  Future<void> disconnect() async {
    disconnectCallCount++;
    _isConnected = false;
    notifyListeners();
  }

  @override
  void dispose() {
    disposeCallCount++;
    super.dispose();
  }

  @override
  Future<void> connect({List<Map<String, dynamic>>? customIceServers}) async {
    _isConnected = true;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeRTCVideoRenderer extends Fake implements RTCVideoRenderer {
  @override
  int? get textureId => 1;

  @override
  bool get renderVideo => true;

  @override
  bool get muted => true;

  @override
  RTCVideoValue get value => const RTCVideoValue();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  int get videoWidth => 1080;

  @override
  int get videoHeight => 1920;

  @override
  MediaStream? get srcObject => null;

  @override
  set srcObject(MediaStream? value) {}
}

void main() {
  testWidgets('Leaving RemoteControlScreen via back button disconnects and disposes session',
      (WidgetTester tester) async {
    final session = TestControllerWebRtcSession();

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => RemoteControlScreen(
                    session: session,
                    deviceName: 'Test Phone',
                    ownsSession: true,
                  ),
                ),
              );
            },
            child: const Text('Open Remote'),
          ),
        ),
      ),
    );

    // Open screen
    await tester.tap(find.text('Open Remote'));
    await tester.pumpAndSettle();

    expect(find.byType(RemoteControlScreen), findsOneWidget);
    expect(session.disconnectCallCount, 0);
    expect(session.disposeCallCount, 0);

    // Tap AppBar back button (chevron_left_rounded)
    await tester.tap(find.byIcon(Icons.chevron_left_rounded));
    await tester.pumpAndSettle();

    // Verify back to home and disconnect was called immediately
    expect(find.byType(RemoteControlScreen), findsNothing);
    expect(session.disconnectCallCount, 1);
    expect(session.disposeCallCount, 1);
  });

  testWidgets('Leaving RemoteControlScreen while human control is active sends automation handover before disconnect',
      (WidgetTester tester) async {
    final session = TestControllerWebRtcSession();

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => RemoteControlScreen(
                    session: session,
                    deviceName: 'Test Phone',
                    ownsSession: true,
                  ),
                ),
              );
            },
            child: const Text('Open Remote'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Remote'));
    await tester.pumpAndSettle();

    // Take human control
    await tester.tap(find.text('קבלת שליטה'));
    await tester.pumpAndSettle();
    expect(session.handoverOwners, contains('remote_human'));

    // Tap back button
    await tester.tap(find.byIcon(Icons.chevron_left_rounded));
    await tester.pumpAndSettle();

    // Verify automation handover was sent on leaving
    expect(session.handoverOwners.last, 'automation');
    expect(session.disconnectCallCount, 1);
  });

  testWidgets('Popping route programmatically or via system pop triggers immediate disconnect',
      (WidgetTester tester) async {
    final session = TestControllerWebRtcSession();
    late BuildContext innerContext;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (ctx) {
                    innerContext = ctx;
                    return RemoteControlScreen(
                      session: session,
                      deviceName: 'Test Phone',
                      ownsSession: false,
                    );
                  },
                ),
              );
            },
            child: const Text('Open Remote'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Remote'));
    await tester.pumpAndSettle();

    expect(session.disconnectCallCount, 0);

    // Pop the screen programmatically
    Navigator.of(innerContext).pop();
    await tester.pumpAndSettle();

    // Even when ownsSession is false, disconnect must happen!
    expect(session.disconnectCallCount, 1);
    expect(session.disposeCallCount, 0);
  });

  testWidgets('App lifecycle state paused triggers disconnect',
      (WidgetTester tester) async {
    final session = TestControllerWebRtcSession();

    await tester.pumpWidget(
      MaterialApp(
        home: RemoteControlScreen(
          session: session,
          deviceName: 'Test Phone',
          ownsSession: true,
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(session.disconnectCallCount, 0);

    // Simulate going to phone home screen / background
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();

    expect(session.disconnectCallCount, 1);
  });

  testWidgets('Going back to HomeScreen without clicking disconnect triggers proper disconnect the second the screen is left',
      (WidgetTester tester) async {
    final session = TestControllerWebRtcSession();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => RemoteControlScreen(
                        session: session,
                        deviceName: 'Galaxy S21',
                        ownsSession: true,
                      ),
                    ),
                  );
                },
                child: const Text('Go To Remote Control'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Go To Remote Control'));
    await tester.pumpAndSettle();

    expect(find.text('Galaxy S21'), findsOneWidget);
    expect(session.disconnectCallCount, 0);

    // User navigates back to HomeScreen using the back arrow without clicking 'ניתוק'
    await tester.tap(find.byIcon(Icons.chevron_left_rounded));
    await tester.pump(); // immediate pump: verify call happened the second screen is left

    expect(session.disconnectCallCount, 1);
    await tester.pumpAndSettle();

    expect(find.text('Go To Remote Control'), findsOneWidget);
    expect(find.text('Galaxy S21'), findsNothing);
  });
}
