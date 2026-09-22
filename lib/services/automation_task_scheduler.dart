import 'dart:async';

/// Cancels delayed work across pause/resume boundaries and serializes phases.
/// Invalidating does not pretend to cancel a platform operation already running;
/// callers drain that operation before granting another input owner access.
class AutomationTaskScheduler {
  int _generation = 0;
  int get generation => _generation;
  Timer? _timer;
  Future<void> _tail = Future.value();

  void invalidate() {
    _generation++;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> run(Future<void> Function() action) {
    final generation = _generation;
    final next = _tail.then((_) async {
      if (generation == _generation) await action();
    });
    _tail = next.catchError((Object _) {});
    return next;
  }

  void schedule(Duration delay, void Function() action) {
    _timer?.cancel();
    final generation = _generation;
    _timer = Timer(delay, () {
      _timer = null;
      if (generation == _generation) action();
    });
  }
}
