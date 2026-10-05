import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirsumoto/services/publication_result_verifier.dart';
import 'package:webview_flutter/webview_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class _ResultController extends PlatformWebViewController {
  _ResultController(this.value) : super.implementation(const PlatformWebViewControllerCreationParams());
  final Object value;
  @override
  Future<Object> runJavaScriptReturningResult(String script) async => value;
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<bool> check(String platform, Map<String, String> result, {bool doubleEncoded = false}) {
    final value = jsonEncode(result);
    return publicationIsConfirmed(WebViewController.fromPlatform(_ResultController(doubleEncoded ? jsonEncode(value) : value)), platform);
  }
  test('leaving an unfinished form does not report success', () async {
    expect(await check('yad2', {'text':'', 'url':'https://www.yad2.co.il/'}), false);
    expect(await check('facebook', {'text':'Publish listing', 'url':'https://www.facebook.com/marketplace/create/vehicle'}), false);
  });
  test('only site confirmation counts, including Android double-encoded JS result', () async {
    expect(await check('yad2', {'text':'המודעה שלך פורסמה בהצלחה', 'url':'https://www.yad2.co.il/'}, doubleEncoded:true), true);
    expect(await check('facebook', {'text':'Your listing is now live', 'url':'https://www.facebook.com/marketplace/'}), true);
  });
}
