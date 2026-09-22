import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service responsible for fetching, caching, and providing the latest
/// agent validation system prompt and business rules from Firestore.
class AgentConfigService {
  AgentConfigService._();
  static final AgentConfigService instance = AgentConfigService._();

  static const String collectionName = 'agent_config';
  static const String documentId = 'whatsapp_validation';

  static const String _prefKeyLastUpdated = 'agent_config_last_updated_ms';
  static const String _prefKeySystemPrompt = 'agent_config_system_prompt';
  static const String _prefKeyColorPrompt = 'agent_config_color_prompt';
  static const String _prefKeyRulesJson = 'agent_config_rules_json';
  static const String _prefKeyGeneralRulesJson =
      'agent_config_general_rules_json';
  static const String _prefKeyRulesMd = 'agent_config_rules_md';
  static const String _prefKeyVersion = 'agent_config_version';

  // In-memory cached state
  DateTime? _lastUpdated;
  DateTime? get lastUpdated => _lastUpdated;
  String? _systemPrompt;
  String? _colorMatchingPrompt;
  String? _version;
  Map<String, dynamic>? _rules;
  String? _rulesMd;
  dynamic _generalRulesRaw;
  bool _isInitialized = false;

  // Track the last time a Firestore check was made to throttle duplicate checks within seconds

  /// Default fallback allowed colors for Yad2
  static const List<String> defaultAllowedColors = [
    'אדום',
    'כחול',
    'צהוב',
    'אפור',
    'לבן',
    'שחור',
    'סגול',
    'ורוד',
    'חום',
    'ירוק',
    'כתום',
  ];

  /// Default fallback allowed ownership types
  static const List<String> defaultAllowedOwnerships = [
    'פרטית',
    'חברה',
    'השכרה',
    'ליסינג',
    'מונית',
    'לימוד נהיגה',
    'ייבוא אישי',
    'ייבוא מקביל',
    'ממשלתי',
    'או״ם',
    'השכרה / החכר',
  ];

  /// Default fallback allowed vehicle conditions
  static const List<String> defaultAllowedConditions = [
    'חדש',
    'כמו חדש',
    'מצוין',
    'טוב מאוד',
    'טוב',
    'סביר',
    'משומש',
    'גרוע',
  ];

  /// Default fallback allowed fuel types
  static const List<String> defaultAllowedFuelTypes = [
    'בנזין',
    'דיזל',
    'חשמל',
    'היברידי',
    'גז',
  ];

  /// Default initial color matching prompt template
  static const String defaultColorMatchingPromptTemplate = '''
נתון צבע רכב שנשלף ממאגר משרד התחבורה: "{raw_color}".
רשימת הצבעים המורשים היא: {allowed_colors}.

אנא בחר והחזר את הצבע הקרוב ביותר מתוך רשימת הצבעים המורשים בלבד.
החזר אך ורק את שם הצבע מתוך הרשימה, ללא שום מילים נוספות, ללא ניקוד וללא סימני פיסוק.
''';

  /// Default initial complete system prompt
  static const String defaultSystemPrompt = '''
אתה עוזר שיחה חכם ומומחה לחילוץ מידע עבור צ׳אטבוט WhatsApp לפרסום רכב ביד2 ובפייסבוק מרקטפלייס בישראל.

תפקידך הכפול:
1. זיהוי כוונת המשתמש (intent) וחילוץ נתונים חדשים או מתוקנים עבור הרכב (extracted_fields) בהתאם לכללים המחמירים של יד2.
2. ניסוח הודעת מענה קצרה, אדיבה ועוזרת בעברית (assistant_reply) המתאימה לוואטסאפ, המנחה את המשתמש במדויק לעבר השלמת פרטי הרכב ופרסומו.

========================
זיהוי כוונות (intent)
====================
- "republish_last": המשתמש מבקש לפרסם שוב, להמשיך מהיכן שהפסיק/עצר, לשחזר נתוני רכב קודם, או לעשות שימוש בנתוני הרכב האחרון/הקודם שלו (למשל: "פרסם שוב את הרכב האחרון שלי", "תוכל לחזור להמשיך פרסום מהיכן שהפסקתי פעם קודמת", "להמשיך מאיפה שעצרתי", "use my last updated data to republish a car", "תפרסם שוב", "פרסם מחדש", "תשתמש בנתונים הקודמים", "להמשיך פרסום").
- "update_details": המשתמש מספק פרטי רכב (קילומטראז', מחיר, צבע וכו') או מעדכן פרט קודם.
- "greeting_or_help": המשתמש אומר שלום, מברך, שואל איך זה עובד, או מבקש עזרה כללית מבלי למסור עדיין מספר רישוי או פרטים.
- "cancel": המשתמש מבקש לבטל את התהליך.
- "chat": הודעה כללית אחרת.

========================
כללי מענה בשיחה (assistant_reply)
================================
ההודעה תהיה תמיד בעברית טבעית, תמציתית, מקצועית ומותאמת לווצאפ:
1. כאשר intent הוא "republish_last":
   - אם ב-last_saved_vehicle קיימים פרטי רכב: אשר שמצאת את הרכב (ציין יצרן, דגם, שנת ייצור ומספר רישוי). אם המשתמש ביקש לשנות פרט (למשל מחיר או ק"מ), אשר את השינוי. בקש תמונות של הרכב כדי להתחיל בפרסום, או שאל האם כל הנתונים מדויקים להמשך.
   - אם ב-last_saved_vehicle אין פרטי רכב: הסבר בנימוס שלא נמצאו פרטי רכב שמורים קודמים, ובקש לשלוח מספר רישוי בן 7 או 8 ספרות כדי להתחיל.
2. כאשר intent הוא "greeting_or_help" (ולא פעיל סשן):
   - הצג את עצמך בתור הבוט של פירסומוטו, הסבר בקצרה שאתה מסייע לפרסם את הרכב ביד2 ובפייסבוק, ובקש מהמשתמש לשלוח את מספר הרישוי של הרכב (7 או 8 ספרות) או להקליט הודעה קולית כדי להתחיל.
3. כאשר intent הוא "update_details":
   - אשר בקצרה את הנתונים שנקלטו, והצג את כל השדות החסרים יחד מתוך missing_fields_in_requested_order ברשימה מרוכזת אחת (מופרדים בנקודות או שורות), כך שהמשתמש יוכל למלא ולספק את כולם יחד. לעולם אל תשאל שדה אחד בודד בכל פעם כאשר ישנם מספר שדות חסרים.
   - אם כל השדות הושלמו, הודע שהפרטים מוכנים, ובקש להעלות תמונות או ללחוץ על "פרסם עכשיו" כדי להתחיל בפרסום ביד2 ובפייסבוק.
4. השאר את התשובות ממוקדות ונעימות בווצאפ - ללא טקסטים ארוכים מדי.

========================
כללי OUTPUT
===========

החזר אובייקט JSON אחד בלבד במבנה הבא:
{
  "intent": "update_details" | "republish_last" | "greeting_or_help" | "cancel" | "chat",
  "extracted_fields": {
     // שדות שחולצו מההודעה בלבד
  },
  "assistant_reply": "הודעת מענה לווצאפ בעברית"
}

כללים נוספים לחילוץ:
- החזר ב-extracted_fields רק שדות שהמידע שלהם ניתן להסיק באופן סביר מההודעה הנוכחית.
- אל תחזיר שדות שלא הופיעו בהודעה הנוכחית, גם אם הם מופיעים ב-current_verified_fields או בהיסטוריה.
- אל תעתיק ערכים קיימים רק משום שהם קיימים בהקשר.
- אל תנחש.
- אל תשלים ערכים חסרים באמצעות ברירת מחדל.
- אם המשתמש מתקן ערך קודם, החזר את הערך החדש ב-extracted_fields.
- אם אין מידע חדש שניתן לשייך בביטחון לאחד השדות המותרים, החזר extracted_fields ריק: {}.
- אם המשתמש מסר מספר פרטים באותה הודעה, החזר את כולם באותו JSON.
- לעולם אל תחזיר license_plate או license בתוך extracted_fields. זיהוי לוחית הרישוי מתבצע מחוץ למודל.

========================
השדות המותרים
=============

km
price
hand
maker
model
year
color
month
test_month
test_year
current_ownership
previous_ownership
vehicle_condition
gear_type
description
fuel_type

אין להחזיר שום מפתח אחר.
''';

  /// Loads local cached config from SharedPreferences if available.
  Future<void> _ensureInitialized() async {
    if (_isInitialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastUpdatedMs = prefs.getInt(_prefKeyLastUpdated);
      if (lastUpdatedMs != null && lastUpdatedMs > 0) {
        _lastUpdated = DateTime.fromMillisecondsSinceEpoch(lastUpdatedMs);
      }
      _systemPrompt =
          prefs.getString(_prefKeySystemPrompt) ?? defaultSystemPrompt;
      _colorMatchingPrompt =
          prefs.getString(_prefKeyColorPrompt) ??
          defaultColorMatchingPromptTemplate;
      _version = prefs.getString(_prefKeyVersion) ?? '1.0.0';

      final rulesJson = prefs.getString(_prefKeyRulesJson);
      if (rulesJson != null && rulesJson.isNotEmpty) {
        try {
          _rules = jsonDecode(rulesJson) as Map<String, dynamic>;
        } catch (_) {
          _rules = null;
        }
      }

      final generalRulesJson = prefs.getString(_prefKeyGeneralRulesJson);
      if (generalRulesJson != null && generalRulesJson.isNotEmpty) {
        try {
          _generalRulesRaw = jsonDecode(generalRulesJson);
        } catch (_) {
          _generalRulesRaw = generalRulesJson;
        }
      }

      _rulesMd = prefs.getString(_prefKeyRulesMd);
    } catch (e) {
      debugPrint('[AgentConfigService] Error reading local cached config: $e');
    } finally {
      _systemPrompt ??= defaultSystemPrompt;
      _colorMatchingPrompt ??= defaultColorMatchingPromptTemplate;
      _version ??= '1.0.0';
      _isInitialized = true;
    }
  }

  /// Checks Firestore for updated prompt and rules.
  /// If [force] is false, throttles calls that happen within [_checkThrottleDuration].
  Future<bool> checkAndUpdateConfigIfNeeded({bool force = false}) async {
    await _ensureInitialized();
    return false; // The backend owns live prompts and validation rules.
  }

  /// Returns raw markdown rules from `rules_md` if present
  String? get rulesMd =>
      (_rulesMd != null && _rulesMd!.trim().isNotEmpty) ? _rulesMd : null;

  /// Returns general rules as a list of bullet points from either `generalRules` or `rules.generalRules`.
  List<String> get generalRules {
    final raw = _generalRulesRaw ?? _rules?['generalRules'];
    if (raw is List) {
      return raw
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    if (raw is String && raw.trim().isNotEmpty) {
      return raw
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
    }
    return const [];
  }

  /// System prompt to pass to the LLM agent turn, automatically including any `rules_md` and `generalRules`.
  String get systemPrompt {
    var base = (_systemPrompt != null && _systemPrompt!.trim().isNotEmpty)
        ? _systemPrompt!
        : defaultSystemPrompt;

    // Eliminate any older cached 1-by-1 phrasing
    base = base.replaceAll(
      'והנחה את המשתמש לספק את השדה הבא שחסר מתוך missing_fields_in_requested_order',
      'והצג את כל השדות החסרים יחד מתוך missing_fields_in_requested_order ברשימה מרוכזת אחת (מופרדים בנקודות או שורות) כדי שהמשתמש יוכל לספק את כולם יחד',
    );

    final md = rulesMd;
    final legacyRules = generalRules;

    final buffer = StringBuffer(base);

    if (md != null) {
      buffer.writeln('\n\n========================');
      buffer.writeln('הוראות סוכן וכללים (AGENT RULES)');
      buffer.writeln('================================');
      buffer.writeln('<agent_rules>');
      buffer.writeln(md.trim());
      buffer.writeln('</agent_rules>');
    }

    if (legacyRules.isNotEmpty) {
      buffer.writeln('\n\n========================');
      buffer.writeln('כללים כלליים נוספים (GENERAL RULES)');
      buffer.writeln('==================================');
      for (final r in legacyRules) {
        buffer.writeln('- $r');
      }
    }

    buffer.writeln('\n\n========================');
    buffer.writeln('כלל מחייב להצגת שדות חסרים (BATCHING MISSING FIELDS)');
    buffer.writeln('===================================================');
    buffer.writeln(
      'כאשר חסרים פרטים ברכב (missing_fields_in_requested_order מכיל יותר משדה אחד):',
    );
    buffer.writeln(
      'חובה תמיד להציג למשתמש את כל השדות החסרים יחד ברשימה מרוכזת אחת מופרדת בשורות או בנקודות (למשל: קילומטראז\', מחיר, יד, צבע), כדי שהמשתמש יוכל למלא ולספק את כולם יחד בהודעה אחת.',
    );
    buffer.writeln('לעולם אל תבקש רק שדה בודד אחד בכל פעם!');

    return buffer.toString();
  }

  /// Allowed Yad2 car colors
  List<String> get allowedColors {
    final list = _rules?['allowedColors'];
    if (list is List && list.isNotEmpty) {
      return list
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return defaultAllowedColors;
  }

  /// Allowed ownership types
  List<String> get allowedOwnerships {
    final list = _rules?['allowedOwnerships'];
    if (list is List && list.isNotEmpty) {
      return list
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return defaultAllowedOwnerships;
  }

  /// Allowed vehicle conditions
  List<String> get allowedConditions {
    final list = _rules?['allowedConditions'];
    if (list is List && list.isNotEmpty) {
      return list
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return defaultAllowedConditions;
  }

  /// Allowed fuel types
  List<String> get allowedFuelTypes {
    final list = _rules?['allowedFuelTypes'];
    if (list is List && list.isNotEmpty) {
      return list
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return defaultAllowedFuelTypes;
  }
}
