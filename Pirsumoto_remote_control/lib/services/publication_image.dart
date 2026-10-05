import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;

Uint8List normalizeImageBytes(Uint8List bytes) {
  image.Image? decoded;
  try {
    decoded = image.decodeImage(bytes);
  } catch (_) {
    throw const FormatException('קובץ התמונה אינו תקין');
  }
  if (decoded == null) throw const FormatException('קובץ התמונה אינו נתמך');
  final oriented = image.bakeOrientation(decoded);
  final resized = oriented.width > 1920
      ? image.copyResize(oriented, width: 1920)
      : oriented;
  return Uint8List.fromList(image.encodeJpg(resized, quality: 85));
}

/// Persist camera/gallery input as oriented JPEG before transferring to Android.
Future<File> preparePublicationImage(File source, Directory destination) async {
  final target = File(
    p.join(
      destination.path,
      'photo_${DateTime.now().microsecondsSinceEpoch}.jpg',
    ),
  );
  if (Platform.isIOS) {
    await const MethodChannel('com.pirsumoto.controller/media').invokeMethod(
      'normalizeImage',
      {'source': source.path, 'destination': target.path},
    );
  } else {
    await target.writeAsBytes(
      await compute(normalizeImageBytes, await source.readAsBytes()),
      flush: true,
    );
  }
  if (!await target.exists() || await target.length() == 0) {
    throw const FormatException('לא ניתן לשמור את התמונה');
  }
  return target;
}
