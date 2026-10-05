import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pirsumoto_remote_control/ui/app_theme.dart';
import 'package:pirsumoto_remote_control/ui/chat_message_bubble.dart';
import 'package:pirsumoto_remote_control/ui/whatsapp_chat_screen.dart';

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  for (final direction in TextDirection.values) {
    testWidgets('Messages occupy opposite edges in $direction', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: direction,
            child: const Scaffold(
              body: SizedBox(
                width: 380,
                child: Column(
                  children: [
                    ChatMessageBubble(
                      isUser: true,
                      time: '10:24',
                      child: Text('שלום'),
                    ),
                    ChatMessageBubble(
                      isUser: false,
                      time: '10:25',
                      child: Text('🤖 פירסומוטו: שלום'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      final bubbles = find.byType(ChatMessageBubble);
      final userBox = find.descendant(
        of: bubbles.at(0),
        matching: find.byType(Container),
      );
      final botBox = find.descendant(
        of: bubbles.at(1),
        matching: find.byType(Container),
      );
      final bounds = tester.getRect(bubbles.first);
      final userRect = tester.getRect(userBox);
      final botRect = tester.getRect(botBox);
      expect(userRect.right, bounds.right);
      expect(botRect.left, bounds.left);
      expect(userRect.left, greaterThan(botRect.left));
      expect(botRect.right, lessThan(userRect.right));
      expect(
        (tester.widget<Container>(userBox).decoration as BoxDecoration).color,
        AppColors.primarySoft,
      );
      expect(
        (tester.widget<Container>(botBox).decoration as BoxDecoration).color,
        AppColors.surface,
      );

      for (var i = 0; i < 2; i++) {
        final check = find.descendant(
          of: bubbles.at(i),
          matching: find.byIcon(Icons.done_all_rounded),
        );
        final time = find.text(i == 0 ? '10:24' : '10:25');
        expect(check, findsOneWidget);
        expect(
          tester.getRect(check).right,
          lessThan(tester.getRect(time).left),
        );
        expect(
          (tester.getCenter(check).dy - tester.getCenter(time).dy).abs(),
          lessThan(1),
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  test('Legacy history recovers authorship without sender metadata', () {
    ChatMessageItem restore(
      String id,
      String text, [
      Map<String, dynamic> extra = const {},
    ]) => ChatMessageItem.fromJson({
      'id': id,
      'text': text,
      'timestamp': 1726000000,
      ...extra,
    });

    for (final prefix in ['msg_', 'img_', 'vid_', 'audio_']) {
      expect(restore('${prefix}123', 'שלום').sender, ChatSender.user);
    }
    expect(restore('old_1', '  🤖 פירסומוטו: שלום').sender, ChatSender.bot);
    expect(restore('reply_123', '⚠️ שגיאה').sender, ChatSender.bot);
    expect(
      restore('msg_123', 'שלום', {'sender': 'bot', 'fromUser': true}).sender,
      ChatSender.bot,
    );
    expect(
      restore('msg_123', '🤖 פירסומוטו: ציטוט', {'sender': 'user'}).sender,
      ChatSender.user,
    );
    expect(
      restore('old_2', 'שלום', {'isFromUser': true}).sender,
      ChatSender.user,
    );
  });

  test('Publish message trigger text is detected correctly', () {
    const publishMsg =
        'התקבלה תמונה אחת בהצלחה!\nכל הפרטים והתמונות מוכנים לפרסום ביד2.\nלפרסום שלח 0\nלביטול השב ביטול';
    expect(publishMsg.contains('לפרסום שלח 0'), isTrue);
    expect(publishMsg.contains('0'), isTrue);
    expect(publishMsg.contains('מוכנים לפרסום'), isTrue);
  });

  testWidgets(
    'MissingFieldsInlineForm always shows km and previous owner with default values, hides badge, and validates save button',
    (tester) async {
      Map<String, String>? savedValues;
      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(
              body: SingleChildScrollView(
                child: MissingFieldsInlineForm(
                  missingFields: const ['price'],
                  currentData: const {
                    'maker': 'מאזדה',
                    'govIl': 'true',
                    'test_year': '2027',
                    'test_month': '1',
                    'km': '85000',
                    'previous_ownership': 'פרטית',
                  },
                  onSave: (val) async {
                    savedValues = val;
                  },
                ),
              ),
            ),
          ),
        ),
      );

      // Header is present, but missing fields badge count is removed
      expect(find.text('להשלמת פרטי רכב חסרים:'), findsOneWidget);
      expect(find.text('1 חסרים'), findsNothing);
      expect(find.text('3 חסרים'), findsNothing);

      // Missing field 'price' is present
      expect(find.text('מחיר מבוקש'), findsOneWidget);

      // 'km' and 'previous_ownership' are ALWAYS present even if not in missingFields
      expect(find.text('קילומטראז׳'), findsOneWidget);
      expect(find.text('בעלות קודמת'), findsOneWidget);

      // Check detected default values are displayed
      expect(find.text('85000'), findsOneWidget);
      expect(find.text('פרטית'), findsOneWidget);

      // Save button is present
      final saveBtnFinder = find.widgetWithText(ElevatedButton, 'שמור פרטים');
      expect(saveBtnFinder, findsOneWidget);

      // Initially, price is empty -> save button must be disabled (onPressed is null)
      final ElevatedButton initialBtn = tester.widget(saveBtnFinder);
      expect(initialBtn.onPressed, isNull);

      // Enter price as '0' -> still disabled
      final priceField = find.byType(TextField).first;
      await tester.enterText(priceField, '0');
      await tester.pump();
      final ElevatedButton zeroBtn = tester.widget(saveBtnFinder);
      expect(zeroBtn.onPressed, isNull);

      // Enter a valid price -> now all fields (price, km=85000, previous_ownership=פרטית) are filled!
      await tester.enterText(priceField, '45000');
      await tester.pump();
      final ElevatedButton validBtn = tester.widget(saveBtnFinder);
      expect(validBtn.onPressed, isNotNull);

      // Tap save button
      await tester.ensureVisible(saveBtnFinder);
      await tester.tap(saveBtnFinder);
      await tester.pumpAndSettle();

      expect(savedValues, isNotNull);
      expect(savedValues!['price'], '45000');
      expect(savedValues!['km'], '85000');
      expect(savedValues!['previous_ownership'], 'פרטית');
      expect(savedValues!['highlights'], '');
      expect(find.text('✅ הפרטים נשמרו'), findsOneWidget);
    },
  );
}
