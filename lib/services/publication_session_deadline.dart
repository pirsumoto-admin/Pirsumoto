import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

/// A deadline belongs to one publication attempt, never to the current route.
class PublicationSessionDeadline {
  static const channel = MethodChannel('com.pirsumoto/publication_deadline');
  static final _callbacks = <String, Future<void> Function()>{};
  static bool _listening = false;
  final String token;
  Timer? _timer;
  bool _canceled = false;
  Future<void> Function()? _expire;

  void handoff(Future<void> Function() expire) {
    _expire = expire;
  }

  PublicationSessionDeadline(this.token);

  Future<void> start(
    Future<void> Function() expire, {
    Duration remaining = const Duration(minutes: 15),
  }) async {
    _expire = expire;
    if (!_listening) {
      _listening = true;
      channel.setMethodCallHandler((call) async {
        if (call.method == 'expired')
          await _callbacks[call.arguments as String]?.call();
      });
    }
    Future<void> guarded() async {
      if (_canceled || !identical(_callbacks[token], guarded)) return;
      _timer?.cancel();
      _callbacks.remove(token);
      await _expire?.call();
    }

    _callbacks[token] = guarded;
    final delay = remaining.isNegative ? Duration.zero : remaining;
    _timer = Timer(delay, () => unawaited(guarded()));
    if (Platform.isAndroid) {
      await channel.invokeMethod('arm', {
        'token': token,
        'milliseconds': delay.inMilliseconds,
      });
    }
  }

  Future<void> cancel() async {
    if (_canceled) return;
    _canceled = true;
    _timer?.cancel();
    _callbacks.remove(token);
    if (Platform.isAndroid)
      await channel.invokeMethod('cancel', {'token': token});
  }
}
