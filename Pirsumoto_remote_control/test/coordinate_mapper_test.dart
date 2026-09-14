import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirsumoto_remote_control/remote/coordinate_mapper.dart';
import 'package:pirsumoto_remote_control/remote/remote_protocol.dart';

void main() {
  group('CoordinateMapper Tests', () {
    test(
      'Maps centered tap accurately on 9:16 video inside identical container',
      () {
        final container = const Size(1080, 1920);
        final videoAspect = 1080 / 1920; // 9:16
        final touch = const Offset(540, 960);

        final norm = CoordinateMapper.mapLocalToNormalized(
          localPosition: touch,
          containerSize: container,
          videoAspectRatio: videoAspect,
        );

        expect(norm, isNotNull);
        expect(norm!.dx, closeTo(0.5, 0.001));
        expect(norm.dy, closeTo(0.5, 0.001));
      },
    );

    test('Maps tap on pillarboxed video (container wider than video)', () {
      final container = const Size(2000, 1000); // 2:1 aspect
      final videoAspect = 0.5; // 1:2 aspect
      // Rendered video width = 1000 * 0.5 = 500
      // offsetX = (2000 - 500) / 2 = 750

      // Tap in black bar outside video -> should return null
      final outsideTouch = const Offset(100, 500);
      expect(
        CoordinateMapper.mapLocalToNormalized(
          localPosition: outsideTouch,
          containerSize: container,
          videoAspectRatio: videoAspect,
        ),
        isNull,
      );

      // Tap at video center (750 + 250, 500) -> should be normalized (0.5, 0.5)
      final centerTouch = const Offset(1000, 500);
      final norm = CoordinateMapper.mapLocalToNormalized(
        localPosition: centerTouch,
        containerSize: container,
        videoAspectRatio: videoAspect,
      );
      expect(norm, isNotNull);
      expect(norm!.dx, closeTo(0.5, 0.001));
      expect(norm.dy, closeTo(0.5, 0.001));
    });
  });

  group('RemoteProtocol Tests', () {
    test('Encodes and decodes RemoteTapCommand', () {
      const tap = RemoteTapCommand(x: 0.45, y: 0.65);
      final jsonStr = tap.encode();
      final decoded = RemoteCommand.decode(jsonStr);

      expect(decoded, isA<RemoteTapCommand>());
      final decodedTap = decoded as RemoteTapCommand;
      expect(decodedTap.x, closeTo(0.45, 0.001));
      expect(decodedTap.y, closeTo(0.65, 0.001));
    });

    test('Encodes and decodes RemoteSwipeCommand', () {
      const swipe = RemoteSwipeCommand(
        startX: 0.5,
        startY: 0.8,
        endX: 0.5,
        endY: 0.2,
        durationMs: 400,
      );
      final jsonStr = swipe.encode();
      final decoded = RemoteCommand.decode(jsonStr);

      expect(decoded, isA<RemoteSwipeCommand>());
      final decodedSwipe = decoded as RemoteSwipeCommand;
      expect(decodedSwipe.durationMs, equals(400));
      expect(decodedSwipe.endY, closeTo(0.2, 0.001));
    });

    test('Encodes and decodes RemoteKeyCommand', () {
      const keyCmd = RemoteKeyCommand(key: RemoteProtocolConstants.keyBack);
      final decoded = RemoteCommand.decode(keyCmd.encode());
      expect(decoded, isA<RemoteKeyCommand>());
      expect(
        (decoded as RemoteKeyCommand).key,
        equals(RemoteProtocolConstants.keyBack),
      );
    });
  });
}
