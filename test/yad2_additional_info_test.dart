import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirsumoto/services/yad2_accessibility_automation_service_optimized.dart';
import 'package:pirsumoto/services/yad2_automation_models.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
// ignore: depend_on_referenced_packages
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';
import 'package:webview_flutter/webview_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

const description =
    'רכב שמור מאוד, מטופל בזמן וללא תאונות.\nכולל מערכת בטיחות מקורית.';
String node(String type, String text, {String desc = ''}) =>
    '[$type] text="$text" desc="$desc" clickable=false bounds=Rect(0, 0 - 100, 100)';
String descriptionTree(String value) => [
  node('android.view.View', 'סוג הרכב'),
  node('android.view.View', 'טויוטה קורולה היברידית'),
  node('android.view.View', 'פרטים חשובים על הרכב'),
  node('android.view.View', 'זה המקום לתאר את הפרטים הבולטים'),
  node('android.widget.EditText', value),
  node('android.widget.Button', 'לשלב הבא'),
].join('\n');

class _Wakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
}

class _WebView extends PlatformWebViewController {
  _WebView()
    : super.implementation(const PlatformWebViewControllerCreationParams());
  bool accessibilityOnly = false;
  int forbiddenCalls = 0;
  void check() {
    if (accessibilityOnly) forbiddenCalls++;
  }

  @override
  Future<void> runJavaScript(String script) async => check();
  @override
  Future<Object> runJavaScriptReturningResult(String script) async {
    check();
    return 0;
  }
}

Future<void> until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 2400 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(done(), isTrue, reason: 'Automation did not reach expected state');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('com.pirsumoto/accessibility');

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

  test(
    'extracts the description field instead of vehicle summary or prompt',
    () {
      expect(
        Yad2AccessibilityAutomationService.descriptionFromAccessibilityTree(
          descriptionTree(description),
        ),
        description,
      );
      expect(
        Yad2AccessibilityAutomationService.descriptionFromAccessibilityTree(
          descriptionTree('זה המקום לתאר את הפרטים הבולטים'),
        ),
        isEmpty,
      );
      expect(
        Yad2AccessibilityAutomationService.descriptionFromAccessibilityTree(
          descriptionTree(''),
        ),
        isEmpty,
      );
    },
  );

  test('never captures a city or unrelated text on the price page', () {
    final tree = [
      node('android.view.View', 'פרטים נוספים'),
      node('android.widget.EditText', 'תל אביב יפו'),
      node('android.view.View', 'מחיר'),
    ].join('\n');
    expect(
      Yad2AccessibilityAutomationService.descriptionFromAccessibilityTree(tree),
      isEmpty,
    );
  });

  for (final scenario in [
    'normal',
    'pause after entry',
    'next temporarily unavailable',
    'entry fails',
    'readback mismatch',
    'readback missing',
    'terms delayed',
    'terms missing',
    'terms pause after checkbox',
    'terms next temporarily unavailable',
  ]) {
    testWidgets('Yad2 publication sequence: $scenario', (tester) async {
      wakelockPlusPlatformInstance = _Wakelock();
      final webView = _WebView();
      late Yad2AccessibilityAutomationService service;
      var descriptionClicks = 0;
      var priceClicks = 0;
      var priceEntries = 0;
      var onPrice = false;
      String price = '';
      var priceBackPresses = 0;
      var priceNextLookups = 0;
      var nextAvailable = scenario != 'next temporarily unavailable';
      final testingTerms = scenario.startsWith('terms');
      var photoClicks = 0;
      var checkboxClicks = 0;
      var termsClicks = 0;
      var termsNextLookups = 0;
      var termsNextAvailable = scenario != 'terms next temporarily unavailable';
      DateTime? photoSubmittedAt;
      bool termsReady() =>
          photoSubmittedAt != null &&
          scenario != 'terms missing' &&
          tester.binding.clock.now().difference(photoSubmittedAt!) >=
              Duration(seconds: scenario == 'terms delayed' ? 6 : 0);
      final events = <String>[];
      service = Yad2AccessibilityAutomationService(
        controller: WebViewController.fromPlatform(webView),
        formData: const VehiclePublishData(
          licenseNumber: '1234567',
          color: 'כחול',
          shade: 'כחול',
          hand: 'ראשונה',
          currentOwnership: 'פרטית',
          previousOwnership: 'פרטית',
          kilometers: '100',
          month: '1',
          price: '80000',
          handicapped: false,
          noTest: false,
        ),
        enableLlmRecovery: false,
        allowOcrFallback: false,
        onPhaseChanged: (phase) {
          if (phase == AutomationPhase.phase13) {
            webView.accessibilityOnly = true;
          }
          if (phase ==
              (testingTerms
                  ? AutomationPhase.phase19
                  : AutomationPhase.phase17)) {
            service.pauseAutomation();
          }
        },
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = call.arguments as Map? ?? {};
        final target = args['target']?.toString() ?? '';
        final phase = service.currentPhase;
        if (call.method == 'checkAutomationWindow') return true;
        if (call.method == 'logTree') {
          if (onPrice) return node('android.view.View', 'מחיר');
          // Match the user's working flow: the description is already
          // generated when the additional-info action reads it.
          return descriptionTree(description);
        }
        if (call.method == 'findNodeTextAfterTarget') {
          if (target.contains('מחיר')) {
            if (scenario == 'readback missing') return null;
            return scenario == 'readback mismatch' ? '12345' : price;
          }
          return 'תל אביב יפו'; // prefilled dropdowns/city
        }
        if (call.method.startsWith('find')) {
          if ([
            'התחברות',
            'כניסה לאזור',
            'דוא"ל',
            'סיסמה',
            'הרשמה',
            'כניסה',
            'התחבר',
          ].contains(target)) {
            return null;
          }
          if (target.contains('קראתי ואישרתי')) {
            // The real page may expose only the short label, with the terms
            // link in a separate node. Require that alternative in the query.
            if (!termsReady() || !target.split('|').contains('קראתי ואישרתי')) {
              return null;
            }
            return {'x': 400.0, 'y': 100.0};
          }
          if (target.contains('לשלב הבא') && phase == AutomationPhase.phase18) {
            termsNextLookups++;
            if (!termsNextAvailable) return null;
          }
          if (target.contains('עדכנתי')) return null;
          if (target.contains('לשלב הבא') && phase == AutomationPhase.phase16) {
            priceNextLookups++;
            if (!nextAvailable) return null;
          }
          if (target.contains('מחיר') && !onPrice) return null;
          return {
            'x':
                target.contains('לשלב הבא')
                    ? 100.0
                    : target.contains('עדכנתי')
                    ? 200.0
                    : 300.0,
            'y': 100.0,
          };
        }
        if (call.method == 'enterTextAtFocused' &&
            phase == AutomationPhase.phase16) {
          priceEntries++;
          events.add('enter price');
          if (scenario == 'entry fails') return false;
          price = args['value'] as String;
          return true;
        }
        if (call.method == 'pressBack' && phase == AutomationPhase.phase16) {
          priceBackPresses++;
        }
        if (call.method == 'tapScreen') {
          if (args['x'] == 100.0 && phase == AutomationPhase.phase14) {
            descriptionClicks++;
            expectSync(service.extractedDescription, description);
            events.add('description next');
            onPrice = true;
          } else if (args['x'] == 100.0 && phase == AutomationPhase.phase16) {
            expectSync(price, '80000');
            priceClicks++;
            events.add('price next');
          } else if (args['x'] == 100.0 && phase == AutomationPhase.phase17) {
            photoClicks++;
            photoSubmittedAt = tester.binding.clock.now();
            events.add('photo next');
          } else if (args['x'] == 400.0 && phase == AutomationPhase.phase18) {
            expectSync(termsReady(), isTrue);
            checkboxClicks++;
            events.add('checkbox');
          } else if (args['x'] == 100.0 && phase == AutomationPhase.phase18) {
            termsClicks++;
            events.add('terms next');
          }
        }
        return true;
      });
      service.startAutomation();
      if (scenario == 'pause after entry') {
        await until(tester, () => priceEntries == 1);
        service.pauseAutomation();
        await tester.pump(const Duration(seconds: 2));
        service.resumeAutomation();
      } else if (scenario == 'next temporarily unavailable') {
        await until(tester, () => priceNextLookups >= 2);
        service.pauseAutomation();
        await tester.pump(const Duration(seconds: 2));
        nextAvailable = true;
        service.resumeAutomation();
      }
      if (scenario == 'terms pause after checkbox') {
        await until(tester, () => checkboxClicks == 1);
        service.pauseAutomation();
        await tester.pump(const Duration(seconds: 2));
        service.resumeAutomation();
      } else if (scenario == 'terms next temporarily unavailable') {
        await until(tester, () => termsNextLookups >= 2);
        service.pauseAutomation();
        await tester.pump(const Duration(seconds: 2));
        termsNextAvailable = true;
        service.resumeAutomation();
      }
      if (scenario == 'entry fails') {
        await until(tester, () => priceEntries >= 3);
        service.pauseAutomation();
        expect(priceClicks, 0);
        expect(priceBackPresses, 0);
      } else {
        if (scenario == 'terms missing') {
          await until(tester, () => photoClicks == 1);
          for (var i = 0; i < 300; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(service.currentPhase, AutomationPhase.phase18);
          expect(checkboxClicks, 0);
          expect(termsClicks, 0);
          service.pauseAutomation();
        } else {
          await until(
            tester,
            () =>
                service.pausedPhase ==
                (testingTerms
                    ? AutomationPhase.phase19
                    : AutomationPhase.phase17),
          );
        }
        if (testingTerms) {
          expect(photoClicks, 1);
          if (scenario != 'terms missing') {
            expect(checkboxClicks, 1);
            expect(termsClicks, 1);
            expect(
              events.indexOf('photo next'),
              lessThan(events.indexOf('checkbox')),
            );
            expect(
              events.indexOf('checkbox'),
              lessThan(events.indexOf('terms next')),
            );
          }
        }
        expect(priceEntries, 1);
        expect(priceClicks, 1);
        expect(priceBackPresses, 1);
        expect(
          events.indexOf('enter price'),
          lessThan(events.indexOf('price next')),
        );
      }
      expect(webView.forbiddenCalls, 0);
      expect(service.extractedDescription, description);
      expect(descriptionClicks, 1);
      service.dispose();
      await tester.pump(const Duration(seconds: 2));
      messenger.setMockMethodCallHandler(channel, null);
    });
  }
}
