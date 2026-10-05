import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:publication_protocol/publication_protocol.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Reads dedicated DOM status elements, never text inside vehicle input fields.
Future<bool> publicationIsConfirmed(WebViewController controller, String platform) async {
  const script = "JSON.stringify({text:Array.from(document.querySelectorAll('h1,h2,[role=status],[role=alert]')).filter(e=>!e.closest('input,textarea,[contenteditable=true]')).map(e=>e.innerText).join(' '),url:location.href})";
  final native = controller.platform;
  final Object? raw = native is AndroidWebViewController
      ? await const MethodChannel('com.pirsumoto/automation_webview').invokeMethod('readPublicationStatus', {'identifier':native.webViewIdentifier})
      : await controller.runJavaScriptReturningResult(script);
  if (raw is! String) return false;
  dynamic parsed = jsonDecode(raw);
  if (parsed is String) parsed = jsonDecode(parsed);
  if (parsed is! Map) return false;
  final text = parsed['text']?.toString() ?? '';
  return platform == 'yad2' ? PublicationConfirmation.yad2(text) : PublicationConfirmation.facebook(text, parsed['url']?.toString() ?? '');
}
