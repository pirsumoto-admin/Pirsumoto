import 'package:flutter_test/flutter_test.dart';
import 'package:pirsumoto/services/native_image_upload_request.dart';

void main() {
  test('returns ordered, encoded native file URIs only once', () async {
    final request = NativeImageUploadRequest(['/tmp/a b.jpg', '/tmp/רכב.png']);
    expect(request.select(allowMultiple: true), [
      Uri.file('/tmp/a b.jpg').toString(),
      Uri.file('/tmp/רכב.png').toString(),
    ]);
    expect(await request.wait(), isTrue);
    expect(request.select(allowMultiple: true), isEmpty);
  });

  test('single-file chooser does not silently discard extra images', () async {
    final request = NativeImageUploadRequest(['/tmp/a.jpg', '/tmp/b.jpg']);
    expect(request.select(allowMultiple: false), isEmpty);
    expect(await request.wait(), isFalse);
  });

  test('single-file chooser accepts one image', () async {
    final request = NativeImageUploadRequest(['/tmp/a.jpg']);
    expect(request.select(allowMultiple: false), ['file:///tmp/a.jpg']);
    expect(await request.wait(), isTrue);
  });

  test('pause or stop cancels a pending selection', () async {
    final request = NativeImageUploadRequest(['/tmp/a.jpg']);
    final completed = request.wait();
    request.cancel();
    expect(await completed, isFalse);
    expect(request.select(allowMultiple: true), isEmpty);
  });

  test('late chooser events cannot consume a timed-out request', () async {
    final request = NativeImageUploadRequest(['/tmp/a.jpg']);
    expect(await request.wait(timeout: Duration.zero), isFalse);
    expect(request.select(allowMultiple: true), isEmpty);
  });
}
