import 'package:flutter/services.dart';

/// Automation calls carry an explicit window guard; deliberate remote-human
/// commands use their separate, unrestricted channel path.
class AutomationAccessibilityChannel {
  static const _native = MethodChannel('com.pirsumoto/accessibility');
  final void Function(String reason) onInterrupted;
  AutomationAccessibilityChannel(this.onInterrupted);

  Future<T?> invokeMethod<T>(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    try {
      return await _native.invokeMethod<T>(method, {
        ...?arguments,
        'requireAppWindow': true,
      });
    } on PlatformException catch (e) {
      if (e.code == 'AUTOMATION_INTERRUPTED' || e.code == 'UNAVAILABLE') {
        onInterrupted(e.message ?? 'Accessibility window unavailable');
      }
      rethrow;
    }
  }

  Future<Map<K, V>?> invokeMapMethod<K, V>(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    final result = await invokeMethod<Map<dynamic, dynamic>>(method, arguments);
    return result?.cast<K, V>();
  }
}
