import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Serializes browser ownership across publishing routes, including routes that
/// are still mounted underneath a new remote publication.
class AutomationWebViewSession {
  AutomationWebViewSession._(
    this.controller,
    this._stop,
    this._detach,
    this._parent,
  );

  static const _channel = MethodChannel('com.pirsumoto/automation_webview');
  static Future<void> _tail = Future.value();
  static AutomationWebViewSession? _active;
  static final _sessions = <AutomationWebViewSession>{};

  final WebViewController controller;
  Future<void> Function() _stop;
  final Future<void> Function() _detach;
  final AutomationWebViewSession? _parent;
  Future<void>? _closing;

  static Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  static Future<AutomationWebViewSession?> open({
    required bool Function() isCurrent,
    required Future<void> Function() stop,
    required Future<void> Function() detach,
    required Future<void> Function(WebViewController) configure,
    // Login screens may temporarily coexist with their paused automation.
    bool auxiliary = false,
  }) => _serialize(() async {
    if (!isCurrent()) return null;
    if (!auxiliary) {
      for (final session in _sessions.toList()) {
        await session._close();
      }
    }
    if (!isCurrent()) return null;

    final session = AutomationWebViewSession._(
      WebViewController(),
      stop,
      detach,
      auxiliary ? _active : null,
    );
    _sessions.add(session);
    if (!auxiliary) _active = session;
    try {
      // Await creation before resolving the native identifier. Configure single
      // window behavior before any URL can load or create an untracked popup.
      await session.controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await session._native('prepare');
      if (isCurrent()) await configure(session.controller);
      if (!isCurrent()) {
        await session._close();
        return null;
      }
      return session;
    } catch (_) {
      await session._close();
      rethrow;
    }
  });

  Future<void> _native(String method) async {
    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      await _channel.invokeMethod<void>(method, {
        'identifier': platform.webViewIdentifier,
      });
    }
  }

  Future<void> close() => _serialize(_close);

  /// Changes automation platforms without detaching or recreating the WebView.
  /// The screen that mounted the browser remains responsible for detaching it.
  Future<bool> continueWith({
    required bool Function() isCurrent,
    required Future<void> Function() stop,
    required Future<void> Function(WebViewController) configure,
  }) => _serialize(() async {
    if (!isCurrent()) return false;
    if (!identical(_active, this) || _closing != null) {
      throw StateError('Cannot continue a closed automation browser');
    }
    await _stop();
    if (!isCurrent()) return false;
    _stop = stop;
    await configure(controller);
    if (!isCurrent()) {
      await _close();
      return false;
    }
    return true;
  });

  Future<void> _close() =>
      _closing ??= _dispose().catchError((Object error, StackTrace stack) {
        _closing =
            null; // A later close may retry, but replacement remains blocked.
        Error.throwWithStackTrace(error, stack);
      });

  Future<void> _dispose() async {
    // A failed drain/teardown leaves this session active and blocks replacement.
    await _stop();
    for (final child
        in _sessions.where((s) => identical(s._parent, this)).toList()) {
      await child._close();
    }
    await _detach();
    await _native('destroy');
    _sessions.remove(this);
    if (identical(_active, this)) _active = null;
  }

  void closeInBackground() {
    unawaited(
      close().catchError((Object error) {
        debugPrint('[AutomationWebView] Could not close browser: $error');
      }),
    );
  }
}
