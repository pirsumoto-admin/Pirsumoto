/// Formats automation error messages into user-friendly, informative descriptions
/// suitable for end-users rather than developer stack traces or internal IDs.
class AutomationErrorFormatter {
  /// Strips emojis and special pictographic characters from description text
  /// before pasting into Yad2's description field.
  static String stripEmojis(String text) {
    if (text.isEmpty) return text;
    final emojiPattern = RegExp(
      r'[\u{1F600}-\u{1F64F}' // Emoticons
      r'\u{1F300}-\u{1F5FF}' // Misc Symbols and Pictographs
      r'\u{1F680}-\u{1F6FF}' // Transport and Map
      r'\u{1F700}-\u{1F77F}' // Alchemical Symbols
      r'\u{1F780}-\u{1F7FF}' // Geometric Shapes Extended
      r'\u{1F800}-\u{1F8FF}' // Supplemental Arrows-C
      r'\u{1F900}-\u{1F9FF}' // Supplemental Symbols and Pictographs
      r'\u{1FA00}-\u{1FA6F}' // Chess Symbols, Symbols and Pictographs Extended-A
      r'\u{1FA70}-\u{1FAFF}' // Symbols and Pictographs Extended-B
      r'\u{2600}-\u{26FF}'   // Misc Symbols (sun, car, etc.)
      r'\u{2700}-\u{27BF}'   // Dingbats (checkmarks, etc.)
      r'\u{2300}-\u{23FF}'   // Misc Technical
      r'\u{2B00}-\u{2BFF}'   // Misc Symbols and Arrows
      r'\u{25A0}-\u{25FF}'   // Geometric Shapes
      r'\u{2190}-\u{21FF}'   // Arrows
      r'\u{200C}-\u{200D}'   // Zero width joiners
      r'\u{20E3}'           // Keycap
      r'\u{FE00}-\u{FE0F}'   // Variation selectors
      r'\u{1F1E6}-\u{1F1FF}' // Regional indicator symbols (flags)
      r'\u{E0020}-\u{E007F}' // Tag characters
      r']+',
      unicode: true,
    );
    return text.replaceAll(emojiPattern, '');
  }

  /// Transforms raw technical automation errors, exceptions, or failure reasons
  /// into user-friendly messages (e.g. failed to click on..., failed to detect field..., failed to enter...).
  static String format(String rawError, {String? phaseDescription}) {
    var error = rawError.trim();
    if (error.isEmpty) {
      return 'אירעה שגיאה בביצוע הפעולה (Action failed)';
    }

    // Strip "Stuck at <phase>: " prefix if present
    final stuckPrefixMatch = RegExp(r'^Stuck at [^:]+:\s*', caseSensitive: false).firstMatch(error);
    if (stuckPrefixMatch != null) {
      error = error.substring(stuckPrefixMatch.end).trim();
    }

    // Strip "Exception: " prefix
    if (error.startsWith('Exception: ')) {
      error = error.substring('Exception: '.length).trim();
    }

    // Check for timeout exceptions or messages
    if (error.contains('TimeoutException') ||
        error.toLowerCase().contains('timed out') ||
        error.contains('לא התקדם בזמן הצפוי')) {
      return 'פג הזמן המוקצב לביצוע הפעולה במסך (Action timed out)';
    }

    // Check for platform or accessibility low-level exceptions
    if (error.contains('PlatformException') ||
        error.contains('NullPointerException') ||
        error.contains('AccessibilityNodeInfo is null') ||
        error.contains('MissingPluginException')) {
      return 'שגיאה באינטראקציה עם רכיבי המסך (Failed to interact with screen elements)';
    }

    // Check for general developer exceptions / errors
    if (error.contains('NoSuchMethodError') ||
        error.contains('StateError') ||
        error.contains('TypeError') ||
        error.contains('RangeError') ||
        error.contains('FormatException')) {
      return 'שגיאה בעיבוד נתוני המסך (Screen data processing error)';
    }

    // "No optimized step spec is registered"
    if (error.toLowerCase().contains('no optimized step spec')) {
      return 'השלב אינו נתמך באוטומציה (Unsupported automation step)';
    }

    // "Login required" or login gate
    if (error.toLowerCase().contains('login required') ||
        error.toLowerCase().contains('login gate')) {
      return 'נדרשת התחברות לחשבון (Login required)';
    }

    // "Action cancelled"
    if (error.toLowerCase().contains('action cancelled')) {
      return 'הפעולה בוטלה (Action was cancelled)';
    }

    // "Yad2 handoff interrupted"
    if (error.toLowerCase().contains('handoff interrupted')) {
      return 'המעבר בין השלבים הופסק (Handoff was interrupted)';
    }

    // Failed to click / tap
    final tapMatch = RegExp(r'Could not tap "([^"]+)"', caseSensitive: false).firstMatch(error) ??
        RegExp(r'Could not tap ([^.]+)', caseSensitive: false).firstMatch(error);
    if (tapMatch != null) {
      final target = tapMatch.group(1)?.trim() ?? '';
      return 'נכשל בלחיצה על "$target" (Failed to click on "$target")';
    }

    final clickMatch = RegExp(r'Failed to click on (.+)', caseSensitive: false).firstMatch(error) ??
        RegExp(r'Failed to tap (.+)', caseSensitive: false).firstMatch(error);
    if (clickMatch != null) {
      final target = clickMatch.group(1)?.trim() ?? '';
      return 'נכשל בלחיצה על "$target" (Failed to click on "$target")';
    }

    if (error.toLowerCase().contains('search button not found')) {
      return 'נכשל בלחיצה על כפתור חיפוש (Failed to click on search button)';
    }
    if (error.toLowerCase().contains('photos-page submit not found')) {
      return 'נכשל בלחיצה על כפתור המשך מדף התמונות (Failed to click next on photos page)';
    }
    if (error.toLowerCase().contains('terms-page submit not found')) {
      return 'נכשל בלחיצה על כפתור אישור תנאים (Failed to click terms confirmation)';
    }
    if (error.toLowerCase().contains('description submit not found')) {
      return 'נכשל בלחיצה על כפתור המשך מדף התיאור (Failed to click next on description page)';
    }
    if (error.toLowerCase() == 'failed to publish') {
      return 'נכשל בלחיצה על כפתור הפרסום (Failed to click publish button)';
    }

    // Failed to enter...
    if (error.toLowerCase() == 'failed to enter year') {
      return 'נכשל בהזנת שנת ייצור (Failed to enter year)';
    }
    if (error.toLowerCase() == 'failed to enter make') {
      return 'נכשל בהזנת יצרן (Failed to enter make)';
    }
    if (error.toLowerCase() == 'failed to enter model') {
      return 'נכשל בהזנת דגם (Failed to enter model)';
    }
    if (error.toLowerCase() == 'failed to enter mileage') {
      return 'נכשל בהזנת קילומטראז׳ (Failed to enter mileage)';
    }
    if (error.toLowerCase() == 'failed to enter price') {
      return 'נכשל בהזנת מחיר (Failed to enter price)';
    }
    if (error.toLowerCase() == 'failed to enter description') {
      return 'נכשל בהזנת תיאור (Failed to enter description)';
    }
    if (error.toLowerCase().contains('vehicle description was not confirmed')) {
      return 'נכשל בהזנת תיאור הרכב (Failed to enter vehicle description)';
    }
    if (error.toLowerCase().contains('city text entry failed')) {
      return 'נכשל בהזנת עיר (Failed to enter city)';
    }
    final genericEnterMatch = RegExp(r'Failed to enter (.+)', caseSensitive: false).firstMatch(error);
    if (genericEnterMatch != null) {
      final target = genericEnterMatch.group(1)?.trim() ?? '';
      return 'נכשל בהזנת $target (Failed to enter $target)';
    }

    // Failed to detect field / element
    if (error.toLowerCase().contains('kilometers field not found')) {
      return 'לא הצליח לזהות את שדה הקילומטראז׳ (Failed to detect kilometers field)';
    }
    if (error.toLowerCase().contains('city input label not found')) {
      return 'לא הצליח לזהות את שדה העיר (Failed to detect city field)';
    }
    if (error.toLowerCase().contains('description page not found')) {
      return 'לא הצליח לזהות את דף התיאור (Failed to detect description page)';
    }
    if (error.toLowerCase().contains('yad2 entry form not found')) {
      return 'לא הצליח לזהות את טופס הפרסום (Failed to detect entry form)';
    }

    final fieldNotFoundMatch = RegExp(r'([A-Za-z0-9א-ת ]+) field not found', caseSensitive: false).firstMatch(error);
    if (fieldNotFoundMatch != null) {
      final field = fieldNotFoundMatch.group(1)?.trim() ?? '';
      final heField = _translateFieldName(field);
      return 'לא הצליח לזהות את שדה $heField (Failed to detect $field field)';
    }

    final optionNotFoundMatch = RegExp(r'Option "([^"]+)" (?:was )?not found', caseSensitive: false).firstMatch(error);
    if (optionNotFoundMatch != null) {
      final opt = optionNotFoundMatch.group(1)?.trim() ?? '';
      return 'לא הצליח לזהות את האפשרות "$opt" (Failed to find option "$opt")';
    }

    final cityNotFoundMatch = RegExp(r'City option "([^"]+)" not found', caseSensitive: false).firstMatch(error);
    if (cityNotFoundMatch != null) {
      final city = cityNotFoundMatch.group(1)?.trim() ?? '';
      return 'לא הצליח לזהות את העיר "$city" (Failed to find city "$city")';
    }

    final dropdownNotOpenMatch = RegExp(r'Dropdown "([^"]+)" did not open', caseSensitive: false).firstMatch(error);
    if (dropdownNotOpenMatch != null) {
      final dd = dropdownNotOpenMatch.group(1)?.trim() ?? '';
      return 'לא הצליח לפתוח את תפריט הבחירה "$dd" (Failed to open dropdown "$dd")';
    }

    // Selection / Option failures
    if (error.toLowerCase().contains('failed body style')) {
      return 'נכשל בבחירת מרכב (Failed to select body style)';
    }
    if (error.toLowerCase().contains('failed to select clean title')) {
      return 'נכשל בסימון טייטל נקי (Failed to select clean title)';
    }
    if (error.toLowerCase().contains('failed condition')) {
      return 'נכשל בבחירת מצב רכב (Failed to select vehicle condition)';
    }
    if (error.toLowerCase().contains('failed fuel type')) {
      return 'נכשל בבחירת סוג דלק (Failed to select fuel type)';
    }
    if (error.toLowerCase().contains('failed transmission')) {
      return 'נכשל בבחירת תיבת הילוכים (Failed to select transmission)';
    }
    if (error.toLowerCase().contains('failed to select vehicle type')) {
      return 'נכשל בבחירת סוג רכב (Failed to select vehicle type)';
    }
    if (error.toLowerCase().contains('failed to upload photos natively')) {
      return 'נכשל בהעלאת תמונות (Failed to upload photos)';
    }
    if (error.toLowerCase().contains('failed to complete group selection')) {
      return 'נכשל בבחירת קבוצות (Failed to select groups)';
    }
    if (error.toLowerCase().contains('failed to set viewport')) {
      return 'נכשל בהגדרת תצוגת הדפדפן (Failed to set viewport)';
    }

    final selectMatch = RegExp(r'Could not select "([^"]+)"', caseSensitive: false).firstMatch(error);
    if (selectMatch != null) {
      final opt = selectMatch.group(1)?.trim() ?? '';
      return 'לא הצליח לבחור "$opt" (Failed to select "$opt")';
    }

    // If the message is already purely Hebrew and doesn't look like code/exception
    final isHebrew = RegExp(r'[\u0590-\u05FF]').hasMatch(error);
    final hasCodeArtifacts = error.contains('{') ||
        error.contains('(') && (error.contains('com.') || error.contains('android.')) ||
        error.contains('Exception') ||
        error.contains('Error') ||
        error.contains('class ') ||
        error.contains('null');

    if (isHebrew && !hasCodeArtifacts) {
      return error;
    }

    // Generic fallback with phase description context if available
    if (phaseDescription != null && phaseDescription.isNotEmpty) {
      return 'נכשל בביצוע שלב $phaseDescription (Failed at step $phaseDescription)';
    }

    return 'נכשל בביצוע הפעולה במסך (Failed to execute screen action)';
  }

  static String _translateFieldName(String field) {
    final lower = field.toLowerCase().trim();
    switch (lower) {
      case 'model':
        return 'הדגם';
      case 'year':
        return 'שנת ייצור';
      case 'hand':
        return 'היד';
      case 'gear':
        return 'תיבת הילוכים';
      case 'engine':
        return 'נפח מנוע';
      case 'color':
        return 'צבע';
      case 'price':
        return 'מחיר';
      case 'city':
        return 'עיר';
      case 'kilometers':
        return 'קילומטראז׳';
      case 'description':
        return 'תיאור';
      default:
        return field;
    }
  }
}
