import 'dart:math' as math;
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Passive observation yields bandwidth and encoder work to automation.
/// Full-rate video is reserved for an explicit, paused-automation takeover.
class RemoteVideoBudget {
  static Future<void> apply(
    RTCRtpSender sender, {
    required int width,
    required int height,
    required bool interactive,
  }) async {
    final parameters = sender.parameters;
    final encodings = parameters.encodings;
    if (encodings == null || encodings.isEmpty) {
      throw StateError('Video sender has no negotiated encodings');
    }
    final scale =
        interactive ? 1.0 : math.max(1.0, math.min(width, height) / 720.0);
    for (final encoding in encodings) {
      encoding.maxFramerate = interactive ? 30 : 10;
      encoding.maxBitrate = interactive ? 4000000 : 1500000;
      encoding.scaleResolutionDownBy = scale;
      encoding.priority = RTCPriorityType.low;
    }
    if (!await sender.setParameters(parameters)) {
      throw StateError('Unable to apply projection resource limits');
    }
  }
}
