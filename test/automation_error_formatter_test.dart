import 'package:flutter_test/flutter_test.dart';
import 'package:pirsumoto/services/automation_error_formatter.dart';

void main() {
  group('AutomationErrorFormatter', () {
    test('formats click / tap errors', () {
      expect(
        AutomationErrorFormatter.format('Could not tap "חיפוש".'),
        'נכשל בלחיצה על "חיפוש" (Failed to click on "חיפוש")',
      );
      expect(
        AutomationErrorFormatter.format('Search button not found.'),
        'נכשל בלחיצה על כפתור חיפוש (Failed to click on search button)',
      );
      expect(
        AutomationErrorFormatter.format('Photos-page submit not found.'),
        'נכשל בלחיצה על כפתור המשך מדף התמונות (Failed to click next on photos page)',
      );
      expect(
        AutomationErrorFormatter.format('Failed to publish'),
        'נכשל בלחיצה על כפתור הפרסום (Failed to click publish button)',
      );
    });

    test('formats enter text errors', () {
      expect(
        AutomationErrorFormatter.format('Failed to enter year'),
        'נכשל בהזנת שנת ייצור (Failed to enter year)',
      );
      expect(
        AutomationErrorFormatter.format('Failed to enter price'),
        'נכשל בהזנת מחיר (Failed to enter price)',
      );
      expect(
        AutomationErrorFormatter.format('Vehicle description was not confirmed.'),
        'נכשל בהזנת תיאור הרכב (Failed to enter vehicle description)',
      );
      expect(
        AutomationErrorFormatter.format('City text entry failed.'),
        'נכשל בהזנת עיר (Failed to enter city)',
      );
    });

    test('formats field not found errors', () {
      expect(
        AutomationErrorFormatter.format('Kilometers field not found.'),
        'לא הצליח לזהות את שדה הקילומטראז׳ (Failed to detect kilometers field)',
      );
      expect(
        AutomationErrorFormatter.format('City input label not found.'),
        'לא הצליח לזהות את שדה העיר (Failed to detect city field)',
      );
      expect(
        AutomationErrorFormatter.format('Model field not found.'),
        'לא הצליח לזהות את שדה הדגם (Failed to detect Model field)',
      );
      expect(
        AutomationErrorFormatter.format('Description page not found.'),
        'לא הצליח לזהות את דף התיאור (Failed to detect description page)',
      );
      expect(
        AutomationErrorFormatter.format('Option "קורולה" was not found.'),
        'לא הצליח לזהות את האפשרות "קורולה" (Failed to find option "קורולה")',
      );
    });

    test('formats selection and dropdown errors', () {
      expect(
        AutomationErrorFormatter.format('Dropdown "שנת ייצור" did not open.'),
        'לא הצליח לפתוח את תפריט הבחירה "שנת ייצור" (Failed to open dropdown "שנת ייצור")',
      );
      expect(
        AutomationErrorFormatter.format('Failed transmission'),
        'נכשל בבחירת תיבת הילוכים (Failed to select transmission)',
      );
      expect(
        AutomationErrorFormatter.format('Failed to select clean title'),
        'נכשל בסימון טייטל נקי (Failed to select clean title)',
      );
    });

    test('strips Stuck at prefix', () {
      expect(
        AutomationErrorFormatter.format('Stuck at Enter Year: Failed to enter year'),
        'נכשל בהזנת שנת ייצור (Failed to enter year)',
      );
      expect(
        AutomationErrorFormatter.format('Stuck at מילוי פרטים נוספים: Vehicle description was not confirmed.'),
        'נכשל בהזנת תיאור הרכב (Failed to enter vehicle description)',
      );
    });

    test('formats developer exceptions without showing stack traces', () {
      expect(
        AutomationErrorFormatter.format('PlatformException(error, AccessibilityNodeInfo is null, null)'),
        'שגיאה באינטראקציה עם רכיבי המסך (Failed to interact with screen elements)',
      );
      expect(
        AutomationErrorFormatter.format('TimeoutException after 0:00:10.000000: Future not completed'),
        'פג הזמן המוקצב לביצוע הפעולה במסך (Action timed out)',
      );
    });

    test('preserves user-friendly Hebrew messages', () {
      expect(
        AutomationErrorFormatter.format('נדרשת התחברות לחשבון יד2. לאחר ההתחברות חזור למסך הפרסום ולחץ המשך.'),
        'נדרשת התחברות לחשבון יד2. לאחר ההתחברות חזור למסך הפרסום ולחץ המשך.',
      );
    });

    test('strips emojis and pictographs from description while preserving normal text', () {
      const input = 'רכב שמור מאוד! 🚗 למכירה ✨ יד 1 🏎️ מחיר: 50,000₪ (גמיש) - מצב מעולה!! 👍🏼 100% 🌟\nטסט לשנה ✅ ללא תאונות 📞 050-1234567 📍 תל אביב';
      final cleaned = AutomationErrorFormatter.stripEmojis(input);
      expect(cleaned.contains('🚗'), isFalse);
      expect(cleaned.contains('✨'), isFalse);
      expect(cleaned.contains('🏎️'), isFalse);
      expect(cleaned.contains('👍🏼'), isFalse);
      expect(cleaned.contains('🌟'), isFalse);
      expect(cleaned.contains('✅'), isFalse);
      expect(cleaned.contains('📞'), isFalse);
      expect(cleaned.contains('📍'), isFalse);
      expect(cleaned.contains('רכב שמור מאוד!'), isTrue);
      expect(cleaned.contains('50,000₪ (גמיש)'), isTrue);
      expect(cleaned.contains('050-1234567'), isTrue);
      expect(cleaned.contains('תל אביב'), isTrue);
    });
  });
}
