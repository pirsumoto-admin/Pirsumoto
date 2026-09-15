import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirsumoto_remote_control/ui/app_theme.dart';

void main() {
  test('AppColors token values match design.md specification', () {
    expect(AppColors.primary, const Color(0xFFF16D53));
    expect(AppColors.primaryAction, const Color(0xFFC34432));
    expect(AppColors.primaryPressed, const Color(0xFFA93627));
    expect(AppColors.primarySoft, const Color(0xFFFDD4C8));
    expect(AppColors.neutral, const Color(0xFFFAF8F5));
    expect(AppColors.surface, const Color(0xFFFFFFFF));
    expect(AppColors.surfaceSubtle, const Color(0xFFF3F4F6));
    expect(AppColors.onSurface, const Color(0xFF171A22));
    expect(AppColors.secondary, const Color(0xFF596171));
    expect(AppColors.border, const Color(0xFFE3E5EA));
    expect(AppColors.controlBorder, const Color(0xFF858D9A));
    expect(AppColors.success, const Color(0xFF007847));
    expect(AppColors.successSoft, const Color(0xFFE8F7EF));
    expect(AppColors.warning, const Color(0xFF955B00));
    expect(AppColors.warningSoft, const Color(0xFFFFF3DB));
    expect(AppColors.offline, const Color(0xFF626B79));
    expect(AppColors.offlineSoft, const Color(0xFFF0F1F3));
    expect(AppColors.error, const Color(0xFFB83229));
    expect(AppColors.errorSoft, const Color(0xFFFFF0EC));
  });

  testWidgets('AppTheme light theme initializes with Heebo textTheme and warm scaffold', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        builder: (context, child) => Directionality(
          textDirection: TextDirection.rtl,
          child: child!,
        ),
        home: const Scaffold(
          body: Text('ברוכים השבים'),
        ),
      ),
    );

    expect(find.text('ברוכים השבים'), findsOneWidget);
    final scaffoldBg = Theme.of(tester.element(find.byType(Scaffold))).scaffoldBackgroundColor;
    expect(scaffoldBg, AppColors.neutral);

    final currentDirection = Directionality.of(tester.element(find.text('ברוכים השבים')));
    expect(currentDirection, TextDirection.rtl);
  });
}
