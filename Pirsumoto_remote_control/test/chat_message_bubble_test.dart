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

  testWidgets('MissingFieldsInlineForm renders field labels on right and inputs on left', (tester) async {
    Map<String, String>? savedValues;
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: SingleChildScrollView(
              child: MissingFieldsInlineForm(
                missingFields: const ['price', 'gear_type'],
                currentData: const {'maker': 'מאזדה'},
                onSave: (val) async {
                  savedValues = val;
                },
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('להשלמת פרטי הרכב:'), findsOneWidget);
    expect(find.text('מחיר מבוקש'), findsOneWidget);
    expect(find.text('תיבת הילוכים'), findsOneWidget);
    expect(find.text('שמור פרטים'), findsOneWidget);

    // Enter a price in the text field
    final priceField = find.byType(TextField);
    expect(priceField, findsOneWidget);
    await tester.enterText(priceField, '45000');

    // Tap save button
    await tester.tap(find.text('שמור פרטים'));
    await tester.pumpAndSettle();

    expect(savedValues, isNotNull);
    expect(savedValues!['price'], '45000');
  });
}

