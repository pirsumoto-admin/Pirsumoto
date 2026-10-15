import 'dart:async';

/// Reports liveness and server reachability without claiming command delivery.
class ReceiverHealth {
  ReceiverHealth({
    required this.isSignedIn,
    required this.checkServer,
    required this.report,
    this.timeout = const Duration(seconds: 15),
  });

  final bool Function() isSignedIn;
  final Future<void> Function() checkServer;
  final Future<void> Function(String state) report;
  final Duration timeout;
  bool _checking = false;
  bool _disposed = false;

  Future<void> check() async {
    if (_checking || _disposed) return;
    _checking = true;
    try {
      if (!isSignedIn()) {
        await report('signed_out');
        return;
      }
      await checkServer().timeout(timeout);
      if (!_disposed) await report(isSignedIn() ? 'ready' : 'signed_out');
    } catch (_) {
      if (!_disposed) await report('error');
    } finally {
      _checking = false;
    }
  }

  void dispose() => _disposed = true;
}
