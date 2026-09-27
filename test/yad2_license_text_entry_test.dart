import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirsumoto/services/yad2_accessibility_automation_service_optimized.dart';
import 'package:pirsumoto/services/yad2_automation_models.dart';
import 'package:webview_flutter/webview_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class _WebView extends PlatformWebViewController {
  _WebView()
    : super.implementation(const PlatformWebViewControllerCreationParams());

  @override
  Future<void> runJavaScript(String script) async =>
      fail('Unexpected JavaScript');

  @override
  Future<Object> runJavaScriptReturningResult(String script) async =>
      fail('Unexpected JavaScript');
}

class _Automation extends Yad2AccessibilityAutomationService {
  _Automation()
    : super(
        controller: WebViewController.fromPlatform(_WebView()),
        formData: const VehiclePublishData(
          licenseNumber: '1234567',
          color: '',
          shade: '',
          hand: '',
          currentOwnership: '',
          previousOwnership: '',
          kilometers: '',
          month: '',
          price: '',
          handicapped: false,
          noTest: false,
        ),
      );

  int replacements = 0;
  Future<bool> Function(String)? replace;

  @override
  Future<bool> toolReplaceFocusedWebViewText(String value) async {
    replacements++;
    return await replace?.call(value) ?? false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('com.pirsumoto/accessibility');

  for (final scenario in [
    'normal',
    'rejected action',
    'silent failure',
    'formatted readback',
    'delayed readback',
    'both fail',
    'duplicate readback',
    'paused',
  ]) {
    testWidgets('License entry: $scenario', (tester) async {
      final service = _Automation();
      var actual = '';
      var reads = 0;
      service.replace = (value) async {
        if (scenario != 'both fail') actual = value;
        if (scenario == 'duplicate readback') actual = '$value$value';
        return true; // Acceptance alone must never count as verified entry.
      };
      messenger.setMockMethodCallHandler(channel, (call) async {
        expectSync((call.arguments as Map)['requireAppWindow'], isTrue);
        switch (call.method) {
          case 'findInputBeforeAndGetBounds':
            return {'x': 100.0, 'y': 200.0};
          case 'tapScreen':
            return true;
          case 'setTextBeforeTarget':
            expectSync((call.arguments as Map)['target'], 'חיפוש');
            if (scenario == 'normal') actual = '1234567';
            if (scenario == 'formatted readback') actual = '\u200f123-45-67';
            if (scenario == 'paused') service.pauseAutomation();
            return scenario != 'rejected action';
          case 'getInputTextBeforeTarget':
            reads++;
            if (scenario == 'delayed readback' && reads == 3) {
              actual = '1234567';
            }
            return actual;
          default:
            fail('Unexpected native call: ${call.method}');
        }
      });

      bool? result;
      final entry = service
          .toolEnterTextBefore('חיפוש', '1234567')
          .then((value) => result = value);
      for (var i = 0; i < 60 && result == null; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await entry;
      expect(
        result,
        !['both fail', 'duplicate readback', 'paused'].contains(scenario),
      );
      expect(
        service.replacements,
        [
              'normal',
              'formatted readback',
              'delayed readback',
              'paused',
            ].contains(scenario)
            ? 0
            : 1,
      );
      messenger.setMockMethodCallHandler(channel, null);
    });
  }
}
