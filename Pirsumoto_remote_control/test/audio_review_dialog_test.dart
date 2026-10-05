import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirsumoto_remote_control/ui/audio_review_dialog.dart';

void main() {
  Future<void> openReview(
    WidgetTester tester,
    Map<String, dynamic> fields,
    void Function(Map<String, String>?) onResult,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              child: const Text('open'),
              onPressed: () async {
                onResult(
                  await showDialog<Map<String, String>>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => AudioReviewDialog(
                      transcript:
                          'אני מבאר שבע, מספר רכב שבע שמונה שמונה שתיים ארבע שלוש שלוש',
                      fields: fields,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Hebrew review submits edited values and preserves leading zeros',
    (tester) async {
      Map<String, String>? result;
      await openReview(tester, {
        'license_plate': '0782433',
        'maker': 'טויוטה',
      }, (value) => result = value);
      expect(find.text('מספר רישוי'), findsOneWidget);
      expect(find.text('רמת גימור'), findsOneWidget);
      expect(find.text('license_plate'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('audio_field_maker')),
        'מאזדה',
      );
      await tester.tap(find.text('אישור והמשך'));
      await tester.pumpAndSettle();
      expect(result, {'license_plate': '0782433', 'maker': 'מאזדה'});
    },
  );

  testWidgets('cancel does not submit fields', (tester) async {
    var completed = false;
    Map<String, String>? result;
    await openReview(tester, {'price': '120000'}, (value) {
      completed = true;
      result = value;
    });
    await tester.tap(find.text('ביטול'));
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(result, isNull);
  });

  testWidgets(
    'empty extraction still requires review and cannot approve an empty draft',
    (tester) async {
      var completed = false;
      await openReview(tester, {}, (_) => completed = true);
      expect(find.textContaining('לא זוהו פרטים'), findsOneWidget);
      await tester.tap(find.text('אישור והמשך'));
      await tester.pumpAndSettle();
      expect(completed, isFalse);
      expect(find.text('יש למלא לפחות פרט אחד לפני האישור.'), findsOneWidget);
    },
  );

  testWidgets('invalid license plate prevents approval', (tester) async {
    var completed = false;
    await openReview(tester, {'license_plate': '123'}, (_) => completed = true);
    await tester.tap(find.text('אישור והמשך'));
    await tester.pumpAndSettle();
    expect(completed, isFalse);
    expect(find.text('מספר רישוי: ערך לא תקין'), findsOneWidget);
  });
}
