import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirsumoto/services/automation_task_scheduler.dart';
import 'package:pirsumoto/services/automation_accessibility_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'pause invalidates old delayed phase so resume executes it only once',
    () async {
      final scheduler = AutomationTaskScheduler();
      var executions = 0;
      scheduler.schedule(const Duration(milliseconds: 10), () {
        executions++;
      });
      scheduler.invalidate();
      await scheduler.run(() async {
        executions++;
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(executions, 1);
    },
  );
  test(
    'phases never overlap, and queued work from before pause is discarded',
    () async {
      final scheduler = AutomationTaskScheduler(),
          running = Completer<void>(),
          release = Completer<void>();
      final events = <String>[];
      final one = scheduler.run(() async {
        events.add('start');
        running.complete();
        await release.future;
        events.add('end');
      });
      await running.future;
      final stale = scheduler.run(() async {
        events.add('stale');
      });
      scheduler.invalidate();
      final resume = scheduler.run(() async {
        events.add('resume');
      });
      release.complete();
      await Future.wait([one, stale, resume]);
      expect(events, ['start', 'end', 'resume']);
    },
  );
  test(
    'native focus loss is guarded and reported before phase fallback can run',
    () async {
      const native = MethodChannel('com.pirsumoto/accessibility');
      var interrupted = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(native, (call) async {
            expect((call.arguments as Map)['requireAppWindow'], true);
            throw PlatformException(
              code: 'AUTOMATION_INTERRUPTED',
              message: 'Foreign window',
            );
          });
      final channel = AutomationAccessibilityChannel((_) {
        interrupted = true;
      });
      await expectLater(
        channel.invokeMethod<void>('tapScreen', {'x': 1.0, 'y': 2.0}),
        throwsA(isA<PlatformException>()),
      );
      expect(interrupted, true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(native, null);
    },
  );
  test(
    'gesture calls stay pending until Android confirms completion',
    () async {
      const native = MethodChannel('com.pirsumoto/accessibility');
      final done = Completer<bool>();
      var interrupted = false, completed = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(native, (_) => done.future);
      final channel = AutomationAccessibilityChannel((_) {
        interrupted = true;
      });
      final operation = channel
          .invokeMethod<bool>('tapScreen', {'x': 1.0, 'y': 2.0})
          .then((_) {
            completed = true;
          });
      await Future<void>.delayed(Duration.zero);
      expect(completed, false);
      done.complete(true);
      await operation;
      expect(completed, true);
      expect(interrupted, false);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(native, null);
    },
  );
}
