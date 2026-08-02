import 'dart:convert';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:webview_flutter/webview_flutter.dart';

part 'webview_service.g.dart';

@riverpod
WebviewService webviewService(Ref ref) {
  return WebviewService();
}

class WebviewService {
  WebViewController? _controller;
  bool _firstClick = true;

  void setController(WebViewController controller) {
    _controller = controller;
  }

  void setFirstClick(bool value) {
    _firstClick = value;
  }

  void injectLoginCheck(
    String currentUrl,
    Map<String, dynamic>? fieldValues,
    String scriptContent,
  ) {
    if (_controller == null) return;

    final secondCall = '''
            window.currentStep++;
            window.manager();
        ''';

    final jsonStr = jsonEncode(fieldValues);
    _controller!.runJavaScript('window.data = $jsonStr;');
    _controller!.runJavaScript(
      "console.log = function(...args) { window.ReactNativeWebView.postMessage(JSON.stringify({ type: 'log', message: args })); };",
    );

    final interpolatedScript = scriptContent
        .replaceAll('\${JSON.stringify(fieldValues)}', jsonStr)
        .replaceAll(
          '\${encodeURIComponent(currentUrl)}',
          Uri.encodeComponent(currentUrl),
        );

    if (_firstClick) {
      Future.delayed(const Duration(milliseconds: 500), () {
        _controller?.runJavaScript(interpolatedScript);
      });
    }
    _firstClick = false;

    if (fieldValues == null) {
      _controller!.runJavaScript(
        'setTimeout(() => { $secondCall true; }, 100);',
      );
    }
  }
}
