import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirsumoto/services/yad2_accessibility_automation_service_optimized.dart';
import 'package:pirsumoto/services/yad2_automation_models.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
// Platform fakes keep these tests independent of an Android device.
// ignore: depend_on_referenced_packages
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';
import 'package:webview_flutter/webview_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class _Wakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
}

class _WebView extends PlatformWebViewController {
  _WebView()
    : super.implementation(const PlatformWebViewControllerCreationParams());

  @override
  Future<Object> runJavaScriptReturningResult(String script) async => 0;
}

const _data = VehiclePublishData(
  licenseNumber: '1234567',
  color: 'כחול',
  shade: 'כחול',
  hand: 'ראשונה',
  currentOwnership: 'פרטית',
  previousOwnership: 'פרטית',
  kilometers: '100',
  month: '1',
  price: '10000',
  handicapped: false,
  noTest: false,
);

class _Automation extends Yad2AccessibilityAutomationService {
  _Automation({super.onPhaseChanged, super.onPhaseError, super.phaseTimeout})
    : super(
        formData: _data,
        controller: WebViewController.fromPlatform(_WebView()),
        enableLlmRecovery: false,
        allowOcrFallback: false,
      );

  int searches = 0;
  int entries = 0;
  bool pauseOnColor = false;
  final colorTaps = <int>[];
  Completer<bool>? search;

  @override
  Future<bool> toolFindElementAndTap(
    String text, {
    int targetInstance = 1,
    double deltaY = 0,
    double threshold = 0.82,
  }) async => false;

  @override
  Future<bool> toolEnterTextBefore(String text, String value) async {
    entries++;
    return !isPaused;
  }

  @override
  Future<bool> tapSmart(
    String text, {
    int targetInstance = 1,
    double deltaY = 0,
    bool allowJsFallback = true,
    bool allowOcrFallbackOverride = true,
  }) async {
    if (isPaused) return false;
    if (text == 'חיפוש') {
      searches++;
      return search?.future ?? true;
    }
    if (text == _data.color) {
      colorTaps.add(targetInstance);
      if (pauseOnColor) {
        pauseOnColor = false;
        pauseAutomation();
      }
    }
    return true;
  }
}

Future<void> _until(bool Function() condition, {int seconds = 4}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for automation');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.pirsumoto/accessibility');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _Automation service;
  late Future<Object?> Function(MethodCall) native;
  final errors = <(AutomationPhase, String)>[];

  setUpAll(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global/events'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          messenger.setMockMethodCallHandler(
            MethodChannel('xyz.luan/audioplayers/events/$id'),
            (_) async => null,
          );
        }
        return null;
      },
    );
  });

  setUp(() {
    wakelockPlusPlatformInstance = _Wakelock();
    errors.clear();
    native =
        (call) async =>
            call.method == 'checkAutomationWindow'
                ? true
                : <String, Object>{'x': 100.0, 'y': 100.0};
    messenger.setMockMethodCallHandler(channel, (call) => native(call));
    service = _Automation(
      onPhaseError: (phase, error) => errors.add((phase, error)),
    );
  });

  tearDown(() async {
    service.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 550));
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'pause before start keeps the first step and resume starts it',
    () async {
      service.pauseAutomation();
      service.startAutomation();
      expect(service.pausedPhase, AutomationPhase.phase1);
      service.resumeAutomation();
      await _until(() => service.currentPhase == AutomationPhase.phase2);
      expect(service.isPaused, false);
    },
  );

  test(
    'pause during settling preserves next step without repeating search',
    () async {
      service.startAutomation();
      await _until(() => service.currentPhase == AutomationPhase.phase2);
      await service.pauseAndWait();
      expect(service.pausedPhase, AutomationPhase.phase2);
      service.resumeAutomation();
      await _until(() => service.currentPhase == AutomationPhase.phase3);
      await service.pauseAndWait();
      expect(service.pausedPhase, AutomationPhase.phase3);
      service.resumeAutomation();
      await _until(() => service.currentPhase == AutomationPhase.phase4);
      expect(service.searches, 1);
      expect(service.entries, 1);
    },
  );

  test('repeated start cannot reset a paused checkpoint', () async {
    service.dispose();
    final phases = <AutomationPhase>[];
    service = _Automation(onPhaseChanged: phases.add);
    service.startAutomation();
    await _until(() => service.currentPhase == AutomationPhase.phase2);
    await service.pauseAndWait();
    service.startAutomation();
    expect(service.pausedPhase, AutomationPhase.phase2);
    expect(
      phases.where((phase) => phase == AutomationPhase.phase1),
      hasLength(1),
    );
    await service.stepBack();
    expect(service.pausedPhase, AutomationPhase.phase1);
    service.resumeAutomation();
    await _until(() => service.currentPhase == AutomationPhase.phase2);
  });

  test(
    'resume within color/shade phase retains the successful color selection',
    () async {
      native = (call) async {
        if (call.method == 'checkAutomationWindow' ||
            call.method == 'tapScreen' ||
            call.method == 'scrollNode') {
          return true;
        }
        if (call.method == 'findNodeTextAfterTarget') return null;
        return <String, Object>{'x': 100.0, 'y': 100.0};
      };
      service.pauseOnColor = true;
      service.startAutomation();
      await _until(() => service.isPaused, seconds: 20);
      await service.pauseAndWait();
      expect(service.pausedPhase, AutomationPhase.phase5);
      expect(service.colorTaps, [1]);
      service.resumeAutomation();
      await _until(
        () => service.currentPhase == AutomationPhase.phase5a,
        seconds: 15,
      );
      expect(service.colorTaps, [1, 2]);
    },
  );

  test(
    'paused or rejected native taps cannot be reported as successful',
    () async {
      var taps = 0;
      native = (call) async {
        if (call.method == 'tapScreen') taps++;
        return false;
      };
      await expectLater(service.toolTapScreen(10, 10), throwsStateError);
      expect(taps, 1);
      service.pauseAutomation();
      await expectLater(service.toolTapScreen(10, 10), throwsStateError);
      expect(taps, 1);
    },
  );

  test(
    'resume drains an active tap and commits its success before continuing',
    () async {
      service.search = Completer<bool>();
      service.startAutomation();
      await _until(() => service.searches == 1);
      service.pauseAutomation();
      expect(service.pausedPhase, AutomationPhase.phase2);
      service.resumeAutomation();
      service.resumeAutomation();
      expect(service.isPaused, true);
      service.search!.complete(true);
      await _until(() => service.currentPhase == AutomationPhase.phase4);
      expect(service.searches, 1);
      expect(service.entries, 1);
    },
  );

  test('failed in-flight action resumes the interrupted step', () async {
    service.search = Completer<bool>();
    service.startAutomation();
    await _until(() => service.searches == 1);
    final paused = service.pauseAndWait();
    service.search!.complete(false);
    await paused;
    expect(service.pausedPhase, AutomationPhase.phase2);
    service.search = null;
    service.resumeAutomation();
    await _until(() => service.currentPhase == AutomationPhase.phase3);
    expect(service.entries, 2);
  });

  test('unavailable window reports step and remains resumable', () async {
    var windowReady = false;
    native =
        (call) async =>
            call.method == 'checkAutomationWindow'
                ? windowReady
                : <String, Object>{'x': 100.0, 'y': 100.0};
    service.startAutomation();
    await _until(() => errors.isNotEmpty);
    expect(service.isPaused, true);
    expect(service.pausedPhase, AutomationPhase.phase1);
    expect(errors.single.$2, contains('phase1'));
    expect(errors.single.$2, contains('המשך'));
    windowReady = true;
    service.resumeAutomation();
    await _until(() => service.currentPhase == AutomationPhase.phase2);
  });

  test(
    'watchdog reports stalled phase and resume waits for pending operation',
    () async {
      service.dispose();
      service = _Automation(
        phaseTimeout: const Duration(milliseconds: 50),
        onPhaseError: (phase, error) => errors.add((phase, error)),
      );
      final window = Completer<bool>();
      native =
          (call) async =>
              call.method == 'checkAutomationWindow'
                  ? window.future
                  : <String, Object>{'x': 100.0, 'y': 100.0};
      service.startAutomation();
      await _until(() => errors.isNotEmpty);
      expect(service.pausedPhase, AutomationPhase.phase1);
      service.resumeAutomation();
      expect(service.isPaused, true);
      window.complete(true);
      await _until(() => service.currentPhase == AutomationPhase.phase2);
      service.pauseAutomation();
    },
  );

  test(
    'stop prevents late action completion from restoring a checkpoint',
    () async {
      service.search = Completer<bool>();
      service.startAutomation();
      await _until(() => service.searches == 1);
      final stopped = service.stopAndWait();
      service.search!.complete(true);
      await stopped;
      service.resumeAutomation();
      expect(service.currentPhase, isNull);
      expect(service.pausedPhase, isNull);
      expect(service.searches, 1);
    },
  );
}
