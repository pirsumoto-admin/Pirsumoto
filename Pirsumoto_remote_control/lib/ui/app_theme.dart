import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  // Brand & Actions
  static const Color primary = Color(0xFFF16D53);
  static const Color primaryAction = Color(0xFFC34432);
  static const Color primaryPressed = Color(0xFFA93627);
  static const Color primarySoft = Color(0xFFFDD4C8); // Vibrant peach/orange pastel from screenshot
  static const Color onPrimary = Color(0xFFFFFFFF);

  // Surfaces & Backgrounds
  static const Color neutral = Color(0xFFFAF8F5); // Warm canvas
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceSubtle = Color(0xFFF3F4F6);
  static const Color onSurface = Color(0xFF171A22); // Main text
  static const Color secondary = Color(0xFF596171); // Subtext / meta

  // Borders
  static const Color border = Color(0xFFE3E5EA);
  static const Color controlBorder = Color(0xFF858D9A);

  // Status Colors
  static const Color success = Color(0xFF007847);
  static const Color successSoft = Color(0xFFE8F7EF);

  static const Color warning = Color(0xFF955B00);
  static const Color warningSoft = Color(0xFFFFF3DB);

  static const Color offline = Color(0xFF626B79);
  static const Color offlineSoft = Color(0xFFF0F1F3);

  static const Color error = Color(0xFFB83229);
  static const Color errorSoft = Color(0xFFFFF0EC);

  static const Color focus = Color(0xFF1B62B5);

  // OS Identifiers
  static const Color windows = Color(0xFF0085E8);
  static const Color android = Color(0xFF72B844);
  static const Color mac = Color(0xFF89919C);
}

class AppTheme {
  static ThemeData get lightTheme {
    final base = ThemeData.light(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: AppColors.neutral,
      colorScheme: const ColorScheme.light(
        primary: AppColors.primaryAction,
        onPrimary: AppColors.onPrimary,
        secondary: AppColors.primary,
        surface: AppColors.surface,
        onSurface: AppColors.onSurface,
        error: AppColors.error,
        onError: Colors.white,
      ),
      textTheme: GoogleFonts.heeboTextTheme(base.textTheme).apply(
        bodyColor: AppColors.onSurface,
        displayColor: AppColors.onSurface,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
    );
  }
}

class PirsumotoRelayMark extends StatelessWidget {
  final double size;
  const PirsumotoRelayMark({super.key, this.size = 32});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: _PirsumotoMarkPainter(),
    );
  }
}

class _PirsumotoMarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFFF826D), Color(0xFFFF5944), Color(0xFFFF8A75)],
        stops: [0, 0.55, 1],
      ).createShader(Offset.zero & size)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final bubbleHeight = size.height * 0.81;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, bubbleHeight),
      Radius.circular(size.width * 0.29),
    );
    final path = Path()..addRRect(rrect);

    // Tail at bottom left
    final tailPath = Path()
      ..moveTo(size.width * 0.25, bubbleHeight * 0.8)
      ..lineTo(size.width * 0.25, size.height)
      ..lineTo(size.width * 0.58, bubbleHeight)
      ..close();
    canvas.drawPath(Path.combine(PathOperation.union, path, tailPath), paint);

    // Two white rounded lines with a shared left edge, as in the brand mark.
    final linePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final lineHeight = size.height * 0.085;
    final lineRadius = Radius.circular(lineHeight / 2);

    // Top line (wider)
    final topLineWidth = size.width * 0.46;
    final topLineY = size.height * 0.24;
    final topLineX = size.width * 0.28;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(topLineX, topLineY, topLineWidth, lineHeight),
        lineRadius,
      ),
      linePaint,
    );

    // Bottom line (shorter)
    final bottomLineWidth = size.width * 0.30;
    final bottomLineY = size.height * 0.43;
    final bottomLineX = topLineX;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(bottomLineX, bottomLineY, bottomLineWidth, lineHeight),
        lineRadius,
      ),
      linePaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
