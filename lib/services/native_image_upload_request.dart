import 'dart:async';

/// One Android WebView file-chooser response. No DOM or JavaScript is involved.
class NativeImageUploadRequest {
  NativeImageUploadRequest(List<String> paths)
    : _uris = paths.map((path) => Uri.file(path).toString()).toList();

  final List<String> _uris;
  final _completed = Completer<bool>();

  List<String> select({required bool allowMultiple}) {
    if (_completed.isCompleted) return const [];
    // Never silently drop images when the page exposes a single-file input.
    if (_uris.isEmpty || (!allowMultiple && _uris.length > 1)) {
      cancel();
      return const [];
    }
    _completed.complete(true);
    return List<String>.of(_uris);
  }

  Future<bool> wait({Duration timeout = const Duration(seconds: 10)}) =>
      _completed.future.timeout(
        timeout,
        onTimeout: () {
          cancel();
          return false;
        },
      );

  void cancel() {
    if (!_completed.isCompleted) _completed.complete(false);
  }
}
