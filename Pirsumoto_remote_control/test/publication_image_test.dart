import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:pirsumoto_remote_control/services/publication_image.dart';

void main() {
  test('camera and gallery image formats become transferable JPEGs', () {
    final source = image.Image(width: 24, height: 12);
    for (final bytes in [image.encodePng(source), image.encodeJpg(source)]) {
      final result = normalizeImageBytes(Uint8List.fromList(bytes));
      expect(result.take(3), [255, 216, 255]);
      final decoded = image.decodeJpg(result)!;
      expect(decoded.width, 24);
      expect(decoded.height, 12);
    }
  });
  test('invalid photo is rejected before entering the publication queue', () {
    expect(
      () => normalizeImageBytes(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
  });
}
