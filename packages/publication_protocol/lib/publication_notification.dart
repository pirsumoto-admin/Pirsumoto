/// Presentation follows the request state, never an old cancellation message.
class PublicationNotification {
  static bool needsAttention(String state, String text) =>
      const {'stuck', 'failed', 'completed'}.contains(state) ||
      (state == 'paused' && text.contains('נדרשת הזנה ידנית'));

  static String textFor(String state, String text) {
    final canceledText =
        text.contains('הפרסום בוטל') ||
        text.contains('תהליך הפרסום בוטל') ||
        text.contains('הבקשה בוטלה');
    if (text.trim().isNotEmpty && (!canceledText || state == 'canceled')) {
      return text;
    }
    return switch (state) {
      'queued' => 'הבקשה ממתינה לפרסום',
      'preparing' => 'מכין את בקשת הפרסום',
      'publishing' => 'הפרסום בתהליך',
      'paused' => 'הפרסום מושהה',
      'stuck' => 'האוטומציה נתקעה ונדרשת התערבות',
      'failed' => 'הפרסום נכשל. יש לבדוק את התוצאה לפני ניסיון נוסף',
      'completed' => 'הפרסום הושלם בהצלחה!',
      'canceling' => 'ממתין לאישור ביטול מהמכשיר',
      'canceled' => 'הפרסום בוטל',
      _ => 'מצב בקשת הפרסום עודכן',
    };
  }
}
