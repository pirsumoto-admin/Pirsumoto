import 'dart:ui';

class CoordinateMapper {
  /// Maps a local widget touch coordinate to normalized remote display coordinates (0.0 ... 1.0)
  /// taking into account video aspect ratio and letterbox/pillarbox padding.
  static Offset? mapLocalToNormalized({
    required Offset localPosition,
    required Size containerSize,
    required double videoAspectRatio, // width / height
  }) {
    if (containerSize.width <= 0 || containerSize.height <= 0 || videoAspectRatio <= 0) {
      return null;
    }

    final containerAspectRatio = containerSize.width / containerSize.height;

    double renderedWidth;
    double renderedHeight;
    double offsetX;
    double offsetY;

    if (containerAspectRatio > videoAspectRatio) {
      // Container is wider than video -> pillarboxing (bars on left and right)
      renderedHeight = containerSize.height;
      renderedWidth = renderedHeight * videoAspectRatio;
      offsetX = (containerSize.width - renderedWidth) / 2.0;
      offsetY = 0.0;
    } else {
      // Container is taller than video -> letterboxing (bars on top and bottom)
      renderedWidth = containerSize.width;
      renderedHeight = renderedWidth / videoAspectRatio;
      offsetX = 0.0;
      offsetY = (containerSize.height - renderedHeight) / 2.0;
    }

    // Check if the tap landed within the active video area
    final videoRect = Rect.fromLTWH(offsetX, offsetY, renderedWidth, renderedHeight);
    if (!videoRect.contains(localPosition)) {
      return null;
    }

    final normalizedX = ((localPosition.dx - offsetX) / renderedWidth).clamp(0.0, 1.0);
    final normalizedY = ((localPosition.dy - offsetY) / renderedHeight).clamp(0.0, 1.0);

    return Offset(normalizedX, normalizedY);
  }

  /// Calculates the active video frame Rect inside the container
  static Rect calculateVideoRect({
    required Size containerSize,
    required double videoAspectRatio,
  }) {
    if (containerSize.width <= 0 || containerSize.height <= 0 || videoAspectRatio <= 0) {
      return Rect.zero;
    }

    final containerAspectRatio = containerSize.width / containerSize.height;

    if (containerAspectRatio > videoAspectRatio) {
      final renderedHeight = containerSize.height;
      final renderedWidth = renderedHeight * videoAspectRatio;
      final offsetX = (containerSize.width - renderedWidth) / 2.0;
      return Rect.fromLTWH(offsetX, 0.0, renderedWidth, renderedHeight);
    } else {
      final renderedWidth = containerSize.width;
      final renderedHeight = renderedWidth / videoAspectRatio;
      final offsetY = (containerSize.height - renderedHeight) / 2.0;
      return Rect.fromLTWH(0.0, offsetY, renderedWidth, renderedHeight);
    }
  }
}
