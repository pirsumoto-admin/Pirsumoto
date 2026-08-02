import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'vehicle_data_service.dart';
import 'whatsapp_message_bridge_service.dart';
import 'yad2_accessibility_automation_service_optimized.dart';

/// Result of form field validation.
class FormValidationResult {
  final bool isValid;
  final List<String> errors;
  final Map<String, String> fieldErrors;
  final int? kilometerTestAharon;

  const FormValidationResult({
    required this.isValid,
    required this.errors,
    required this.fieldErrors,
    this.kilometerTestAharon,
  });

  @override
  String toString() =>
      'FormValidationResult(isValid: $isValid, errors: $errors, kmTestAharon: $kilometerTestAharon)';
}

/// Result of WhatsApp text validation and field extraction.
class WhatsAppValidationResult {
  final bool isValid;
  final Map<String, String> extractedFields;
  final List<String> missingFields;
  final List<String> validationErrors;
  final String replyHebrew;
  final bool readyToPublish;
  final bool usedAiModel;
  final int? kilometerTestAharon;

  const WhatsAppValidationResult({
    required this.isValid,
    required this.extractedFields,
    required this.missingFields,
    required this.validationErrors,
    required this.replyHebrew,
    required this.readyToPublish,
    this.usedAiModel = false,
    this.kilometerTestAharon,
  });
}

/// Service for extracting WhatsApp vehicle text fields, running AI model validation,
/// validating form fields, managing persistent sender state, and handling full WhatsApp dialog flow.
class WhatsAppTextValidationService {
  static const String _govApiUrl =
      'https://data.gov.il/api/3/action/datastore_search';
  static const String _testHistoryResourceId =
      '56063a99-8a3e-4ff4-912e-5966c0279bad';

  static const instance = WhatsAppTextValidationService();

  final String? anthropicApiKey;
  final String aiModel;

  const WhatsAppTextValidationService({
    this.anthropicApiKey,
    this.aiModel = 'claude-haiku-4-5-20251001',
  });

  // ── Persistent State Management & WhatsApp Event Pipeline ─────────────────────────

  static final Map<String, Map<String, String>> _senderStateCache = {};

  static String _statePrefKey(String senderKey) => 'wa_state_$senderKey';

  Future<Map<String, String>> loadSenderState(String senderKey) async {
    if (senderKey.isEmpty) return {};
    if (_senderStateCache.containsKey(senderKey)) {
      return Map<String, String>.from(_senderStateCache[senderKey]!);
    }
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_statePrefKey(senderKey));
    if (jsonStr == null || jsonStr.isEmpty) return {};
    try {
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      final result = map.map((k, v) => MapEntry(k, v?.toString() ?? ''));
      _senderStateCache[senderKey] = result;
      return Map<String, String>.from(result);
    } catch (_) {
      return {};
    }
  }

  Future<void> saveSenderState(
    String senderKey,
    Map<String, String> state,
  ) async {
    if (senderKey.isEmpty) return;
    _senderStateCache[senderKey] = Map<String, String>.from(state);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_statePrefKey(senderKey), jsonEncode(state));
  }

  Future<void> clearSenderState(String senderKey) async {
    if (senderKey.isEmpty) return;
    _senderStateCache.remove(senderKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_statePrefKey(senderKey));
  }

  /// Handle incoming text message from WhatsApp
  Future<Map<String, String>?> handleIncomingTextMessage({
    required String text,
    required String senderKey,
    String? senderName,
    int? timestamp,
  }) async {
    final trimmedText = text.trim();
    if (trimmedText.isEmpty) return null;

    if (isSystemNotification(trimmedText)) return null;

    final currentState = await loadSenderState(senderKey);

    // Filter out historical messages based on session start timestamp
    final sessionStartStr = currentState['session_start_timestamp'];
    if (sessionStartStr != null && timestamp != null) {
      final sessionStart = int.tryParse(sessionStartStr) ?? 0;
      if (timestamp < sessionStart) {
        debugPrint(
          '[WhatsAppValidation] Ignoring historic text message: $text '
          '(timestamp: $timestamp < sessionStart: $sessionStart)',
        );
        return currentState;
      }
    }

    // If automation is actively running, handle cancel commands or respond that publication is in progress.
    if (currentState['auto_publish_started'] == 'true' ||
        currentState['KEY_AUTO_PUBLISH_STARTED'] == 'true') {
      final norm = trimmedText.toLowerCase();
      if (norm.contains('בטל') ||
          norm.contains('ביטול') ||
          norm.contains('cancel') ||
          norm == '9') {
        Yad2AccessibilityAutomationService.stopAll();
        await clearSenderState(senderKey);
        await WhatsAppMessageBridgeService.instance.sendReplyToWhatsApp(
          senderKey: senderKey,
          message: 'תהליך הפרסום בוטל.',
        );
        return {};
      } else {
        await WhatsAppMessageBridgeService.instance.sendReplyToWhatsApp(
          senderKey: senderKey,
          message:
              'תהליך הפרסום ביד2 בעיצומו כעת. אנא נסה שוב מאוחר יותר.\n(כדי לעצור ולבטל את התהליך, שלח "בטל")',
        );
        return currentState;
      }
    }

    if (isCommand(trimmedText)) {
      return await _handleCommandText(
        trimmedText: trimmedText,
        senderKey: senderKey,
        senderName: senderName,
        currentState: currentState,
      );
    }

    // Step 1: Rule-based extraction
    var extracted = extractFieldsFromText(trimmedText);

    // Step 2: Fallback to AI model if fields missing
    final missingInExtracted = _checkMissingKeys(extracted);
    if (missingInExtracted.isNotEmpty &&
        trimmedText.length > 10 &&
        anthropicApiKey != null) {
      extracted = await askAiModelToExtractFields(trimmedText, extracted);
    }

    final hasActiveSession =
        (currentState['license_plate'] ?? currentState['license'] ?? '')
            .trim()
            .isNotEmpty;

    final hasNewVehicleData =
        extracted.isNotEmpty &&
        (hasActiveSession ||
            extracted.containsKey('license_plate') ||
            extracted.containsKey('license') ||
            extracted.containsKey('km') ||
            extracted.containsKey('price') ||
            extracted.containsKey('maker') ||
            extracted.containsKey('model'));

    if (!hasNewVehicleData) {
      await WhatsAppMessageBridgeService.instance.sendReplyToWhatsApp(
        senderKey: senderKey,
        message:
            'לא נמצאו נתוני רכב בהודעה. אנא שלח הודעה עם פרטי הרכב (מספר רישוי, ק"מ, מחיר).',
      );
      return currentState;
    }

    // A NEW vehicle message was received!
    final newLicense = extracted['license_plate'] ?? extracted['license'];

    // If a license is provided, start a completely fresh state and record session start timestamp!
    final Map<String, String> baseState;
    if (newLicense != null && newLicense.isNotEmpty) {
      baseState = <String, String>{};
      baseState['session_start_timestamp'] =
          '${timestamp ?? DateTime.now().millisecondsSinceEpoch}';
    } else {
      baseState = Map<String, String>.from(currentState);
    }

    extracted.forEach((k, v) {
      if (v.trim().isNotEmpty) {
        baseState[k] = v.trim();
      }
    });

    final newState = baseState;

    if (senderKey.isNotEmpty) {
      newState['whatsapp_sender_key'] = senderKey;
      newState['whatsapp_origin'] = 'true';
    }
    if (senderName != null && senderName.isNotEmpty) {
      newState['whatsapp_sender_name'] = senderName;
    }

    // Ensure vehicle_condition is preserved or defaulted
    if ((newState['vehicle_condition'] == null ||
            newState['vehicle_condition']!.isEmpty) &&
        (newState['vehicleCondition'] == null ||
            newState['vehicleCondition']!.isEmpty)) {
      newState['vehicle_condition'] = 'טוב';
    }

    int? kilometerTestAharon;
    final license = newState['license_plate'] ?? newState['license'];
    if (license != null && license.isNotEmpty) {
      kilometerTestAharon = await fetchKilometerTestAharon(license);
      if (kilometerTestAharon != null) {
        newState['kilometer_test_aharon'] = kilometerTestAharon.toString();
      }

      // Automatically fetch details from data.gov.il to fill vehicle details (maker, model, year, etc.)
      try {
        final vehicleData = await VehicleDataService.fetchVehicleData(license);
        if (vehicleData != null) {
          if (newState['maker'] == null || newState['maker']!.isEmpty) {
            newState['maker'] = vehicleData['maker'] ?? '';
          }
          if (newState['model'] == null || newState['model']!.isEmpty) {
            newState['model'] = vehicleData['model'] ?? '';
          }
          if (newState['year'] == null || newState['year']!.isEmpty) {
            newState['year'] = vehicleData['year'] ?? '';
          }
          if (newState['color'] == null || newState['color']!.isEmpty) {
            newState['color'] = vehicleData['color'] ?? '';
          }
          if (newState['fuel_type'] == null || newState['fuel_type']!.isEmpty) {
            newState['fuel_type'] = vehicleData['fuelType'] ?? '';
          }
          if (newState['current_ownership'] == null ||
              newState['current_ownership']!.isEmpty) {
            newState['current_ownership'] = vehicleData['ownership'] ?? '';
          }
          final testExpiry = vehicleData['testExpiry'] as String?;
          if (testExpiry != null && testExpiry.contains(',')) {
            final parts = testExpiry.split(',');
            if (parts.length == 2) {
              if (newState['test_month'] == null ||
                  newState['test_month']!.isEmpty) {
                newState['test_month'] = parts[0];
              }
              if (newState['test_year'] == null ||
                  newState['test_year']!.isEmpty) {
                newState['test_year'] = parts[1];
              }
            }
          }
        }
      } catch (e) {
        debugPrint(
          '[WhatsAppValidationService] Error fetching vehicle details: $e',
        );
      }
    }

    final formVal = await validateFormFields(
      newState,
      kilometerTestAharon: kilometerTestAharon,
    );

    final missingKeys = _checkMissingKeys(newState);

    await saveSenderState(senderKey, newState);

    final reply = composeHebrewReply(
      state: newState,
      formVal: formVal,
      missingKeys: missingKeys,
    );

    if (reply.isNotEmpty && senderKey.isNotEmpty) {
      await WhatsAppMessageBridgeService.instance.sendReplyToWhatsApp(
        senderKey: senderKey,
        message: reply,
      );
    }

    return newState;
  }

  Future<Map<String, String>?> _handleCommandText({
    required String trimmedText,
    required String senderKey,
    String? senderName,
    required Map<String, String> currentState,
  }) async {
    final lower = trimmedText.toLowerCase();

    if (lower == '9' ||
        lower == 'ביטול' ||
        lower == 'בטל' ||
        lower == 'cancel') {
      Yad2AccessibilityAutomationService.stopAll();
      await clearSenderState(senderKey);
      await WhatsAppMessageBridgeService.instance.sendReplyToWhatsApp(
        senderKey: senderKey,
        message: 'מבטל',
      );
      return {};
    }

    if (lower == '0' ||
        lower == 'פרסום' ||
        lower == 'פרסם' ||
        lower == 'publish') {
      final missingKeys = _checkMissingKeys(currentState);
      final formVal = await validateFormFields(currentState);

      if (missingKeys.isNotEmpty || !formVal.isValid) {
        final reply = composeHebrewReply(
          state: currentState,
          formVal: formVal,
          missingKeys: missingKeys,
        );
        await WhatsAppMessageBridgeService.instance.sendReplyToWhatsApp(
          senderKey: senderKey,
          message: reply,
        );
        return currentState;
      }

      currentState['auto_publish_started'] = 'false';
      currentState['KEY_AUTO_PUBLISH_STARTED'] = 'false';
      await saveSenderState(senderKey, currentState);

      await WhatsAppMessageBridgeService.instance.sendReplyToWhatsApp(
        senderKey: senderKey,
        message: 'מתחיל פרסום ביד2 עכשיו.',
      );

      await WhatsAppMessageBridgeService.instance.launchAutoPublish(
        currentState,
      );
      return currentState;
    }

    final countMatch = RegExp(r'^(\d{1,2})').firstMatch(trimmedText);
    if (countMatch != null) {
      final expectedCount = int.tryParse(countMatch.group(1)!) ?? 0;

      if (expectedCount > 8) {
        await WhatsAppMessageBridgeService.instance.sendReplyToWhatsApp(
          senderKey: senderKey,
          message:
              'מספר התמונות המרבי להעלאה הוא 8. אנא השב מספר בין 1 ל-8, 0 לפרסום ללא תמונות, או 9 לביטול.',
        );
        return currentState;
      }

      currentState['image_expected_count'] = '$expectedCount';
      currentState['KEY_IMAGE_EXPECTED_COUNT'] = '$expectedCount';
      currentState['image_paths'] = jsonEncode([]);
      currentState['KEY_IMAGE_PATHS'] = jsonEncode([]);
      currentState['image_received_count'] = '0';
      currentState['KEY_IMAGE_RECEIVED_COUNT'] = '0';
      currentState['image_command_timestamp'] =
          '${DateTime.now().millisecondsSinceEpoch}';

      if (expectedCount == 0) {
        currentState['auto_publish_started'] = 'false';
        currentState['KEY_AUTO_PUBLISH_STARTED'] = 'false';
        await saveSenderState(senderKey, currentState);

        await WhatsAppMessageBridgeService.instance.sendReplyToWhatsApp(
          senderKey: senderKey,
          message: 'מתחיל פרסום ביד2 עכשיו בלי תמונות.',
        );
        await WhatsAppMessageBridgeService.instance.launchAutoPublish(
          currentState,
        );
        return currentState;
      }

      // Save state and WAIT for incoming WhatsApp images (Do NOT grab old images from disk!)
      await saveSenderState(senderKey, currentState);

      await WhatsAppMessageBridgeService.instance.sendReplyToWhatsApp(
        senderKey: senderKey,
        message: 'ממתין להעלאת $expectedCount תמונות',
      );
      return currentState;
    }

    return currentState;
  }

  /// Handle incoming image message from WhatsApp
  Future<Map<String, String>?> handleIncomingImage({
    required String imageFilePath,
    required String senderKey,
    String? senderName,
    int? timestamp,
  }) async {
    final cleanPath = imageFilePath.trim();
    if (cleanPath.isEmpty || senderKey.isEmpty) return null;

    final file = File(cleanPath);
    if (!file.existsSync()) return null;

    final fileName = cleanPath.split(RegExp(r'[/\\]')).last.toLowerCase();

    // Ignore temporary files, thumbnails, non-image extensions
    if (fileName.endsWith('.tmp') ||
        fileName.endsWith('.pending') ||
        fileName.endsWith('.part') ||
        fileName.endsWith('.nomedia') ||
        fileName.contains('thumb')) {
      return null;
    }

    final isImageExt = RegExp(
      r'\.(jpg|jpeg|png|webp|heic)$',
    ).hasMatch(fileName);
    if (!isImageExt) return null;

    // Validate timestamp: Require image to have been created/modified in the last 5 minutes!
    final lastModified = file.lastModifiedSync();
    final ageMs = DateTime.now().difference(lastModified).inMilliseconds;
    if (ageMs > 300000) {
      debugPrint(
        '[WhatsAppValidation] Rejecting old image file (>300s): $cleanPath (age: ${ageMs}ms)',
      );
      return null;
    }

    final currentState = await loadSenderState(senderKey);

    // Filter out historical messages based on session start timestamp
    final sessionStartStr = currentState['session_start_timestamp'];
    if (sessionStartStr != null && timestamp != null) {
      final sessionStart = int.tryParse(sessionStartStr) ?? 0;
      if (timestamp < sessionStart) {
        debugPrint(
          '[WhatsAppValidation] Ignoring historic image: $imageFilePath '
          '(timestamp: $timestamp < sessionStart: $sessionStart)',
        );
        return currentState;
      }
    }
    final expectedCount =
        int.tryParse(
          currentState['image_expected_count'] ??
              currentState['KEY_IMAGE_EXPECTED_COUNT'] ??
              '0',
        ) ??
        0;

    List<String> existingPaths = [];
    final rawPaths =
        currentState['image_paths'] ?? currentState['KEY_IMAGE_PATHS'];
    if (rawPaths != null && rawPaths.isNotEmpty) {
      try {
        existingPaths = List<String>.from(jsonDecode(rawPaths));
      } catch (_) {}
    }

    final existingNames =
        existingPaths
            .map((p) => p.split(RegExp(r'[/\\]')).last.toLowerCase())
            .toSet();

    // Deduplicate by filename
    if (existingNames.contains(fileName)) {
      return currentState;
    }

    // STRICT GUARD: If already at target count (e.g. 2 out of 2 received), SILENTLY IGNORE extra image events!
    if (expectedCount > 0 && existingPaths.length >= expectedCount) {
      return currentState;
    }

    existingPaths.add(cleanPath);

    List<String> finalPaths = existingPaths;
    if (expectedCount > 0 && existingPaths.length > expectedCount) {
      finalPaths =
          existingPaths.skip(existingPaths.length - expectedCount).toList();
    }

    currentState['image_paths'] = jsonEncode(finalPaths);
    currentState['KEY_IMAGE_PATHS'] = jsonEncode(finalPaths);
    currentState['image_received_count'] = '${finalPaths.length}';
    currentState['KEY_IMAGE_RECEIVED_COUNT'] = '${finalPaths.length}';
    await saveSenderState(senderKey, currentState);

    final receivedCount = finalPaths.length;

    if (expectedCount > 0) {
      if (receivedCount >= expectedCount) {
        await WhatsAppMessageBridgeService.instance.sendReplyToWhatsApp(
          senderKey: senderKey,
          message:
              'התקבלו $receivedCount מתוך $expectedCount תמונות (עיבוד הושלם).\nלפרסום שלח 0\nלביטול שלח 9',
        );
      } else {
        await WhatsAppMessageBridgeService.instance.sendReplyToWhatsApp(
          senderKey: senderKey,
          message: 'נקלטה תמונה $receivedCount מתוך $expectedCount, מעבד...',
        );
      }
    } else {
      await WhatsAppMessageBridgeService.instance.sendReplyToWhatsApp(
        senderKey: senderKey,
        message:
            'קיבלתי תמונה. קודם שלח 1-8 כמספר התמונות להעלאה, 0 לפרסום ללא תמונות, או 9 לביטול.',
      );
    }

    return currentState;
  }

  bool isSystemNotification(String text) {
    final norm = text.trim().toLowerCase();
    return norm.startsWith('נקלטה תמונה') ||
        norm.startsWith('התקבלו') ||
        norm.startsWith('ממתין להעלאת') ||
        norm.startsWith('מתחיל פרסום') ||
        norm.startsWith('הפרסום בוטל') ||
        norm.startsWith('תהליך') ||
        norm.startsWith('האוטומציה') ||
        norm.startsWith('פרטי הרכב') ||
        norm.startsWith('מצאתי את הרכב') ||
        norm.startsWith('לא נמצאו') ||
        norm.startsWith('לא זיהיתי') ||
        norm.startsWith('נמצאו שגיאות') ||
        norm.startsWith('חסרים עדיין');
  }

  String composeHebrewReply({
    required Map<String, String> state,
    required FormValidationResult formVal,
    required List<String> missingKeys,
  }) {
    final replyBuilder = StringBuffer();

    final maker = state['maker'] ?? '';
    final model = state['model'] ?? '';
    final year = state['year'] ?? '';
    final titleParts = [
      maker,
      model,
      year,
    ].where((s) => s.isNotEmpty).join(' ');

    final hasErrors = formVal.errors.isNotEmpty;
    final hasMissing = missingKeys.isNotEmpty;

    if (hasErrors || hasMissing) {
      if (titleParts.isNotEmpty) {
        replyBuilder.writeln('מצאתי את הרכב: $titleParts\n');
      }

      if (hasErrors) {
        replyBuilder.writeln('נמצאו שגיאות בנתונים:');
        for (final err in formVal.errors) {
          replyBuilder.writeln('• $err');
        }
        replyBuilder.writeln();
      }

      if (hasMissing) {
        replyBuilder.writeln('חסרים עדיין הנתונים הבאים:');
        for (final key in missingKeys) {
          replyBuilder.writeln('• ${_hebrewFieldLabel(key)}');
        }
      }
    } else {
      replyBuilder.writeln('פרטי הרכב נקלטו בהצלחה ומוכנים לפרסום:');
      if (titleParts.isNotEmpty) {
        replyBuilder.writeln('• רכב: $titleParts');
      }
      replyBuilder.writeln(
        '• רישוי: ${state['license_plate'] ?? state['license']}',
      );
      replyBuilder.writeln('• ק"מ: ${state['km']}');
      replyBuilder.writeln('• מחיר: ${state['price']} ₪');
      if (state['hand'] != null && state['hand']!.isNotEmpty) {
        replyBuilder.writeln('• יד: ${state['hand']}');
      }
      final cond = state['vehicle_condition'] ?? state['vehicleCondition'];
      if (cond != null && cond.isNotEmpty) {
        replyBuilder.writeln('• מצב: $cond');
      }
      replyBuilder.writeln('\nהנתונים מוכנים. כמה תמונות תרצה להעלות?');
      replyBuilder.writeln(
        'השב 1 עד 8 עבור מספר התמונות, 0 לפרסום ללא תמונות, או 9 לביטול.',
      );
    }

    return replyBuilder.toString().trim();
  }

  // ── 1. Fetch kilometer_test_aharon from data.gov.il ────────────────────────

  /// Fetch the last test kilometer record (`kilometer_test_aharon`) for a license plate.
  Future<int?> fetchKilometerTestAharon(String licensePlate) async {
    final cleanPlate = _digitsOnly(licensePlate);
    if (cleanPlate.length < 7 || cleanPlate.length > 8) return null;

    try {
      final url =
          '$_govApiUrl?resource_id=$_testHistoryResourceId&q=$cleanPlate&offset=0';
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final result = decoded['result'] as Map<String, dynamic>?;
        final records = result?['records'] as List?;
        if (records != null && records.isNotEmpty) {
          final firstRecord = records.first as Map<String, dynamic>;
          final kmTest = firstRecord['kilometer_test_aharon'];
          if (kmTest != null) {
            if (kmTest is int) return kmTest;
            return int.tryParse(kmTest.toString());
          }
        }
      }
    } catch (e) {
      debugPrint(
        '[WhatsAppValidationService] Error fetching kilometer_test_aharon: $e',
      );
    }
    return null;
  }

  // ── 2. Form Fields & Kilometer Validation ─────────────────────────────────

  /// Validate form fields and verify that kilometers (`km`) is strictly greater than `kilometer_test_aharon`.
  Future<FormValidationResult> validateFormFields(
    Map<String, String> fields, {
    int? kilometerTestAharon,
  }) async {
    final errors = <String>[];
    final fieldErrors = <String, String>{};

    final license = _digitsOnly(
      fields['license'] ?? fields['license_plate'] ?? '',
    );
    final kmStr = _digitsOnly(fields['km'] ?? '');
    final priceStr = _digitsOnly(fields['price'] ?? '');
    final handStr = fields['hand']?.trim() ?? '';

    // License plate check
    if (license.isEmpty) {
      errors.add('מספר רישוי הוא שדה חובה');
      fieldErrors['license'] = 'חסר מספר רישוי';
    } else if (license.length < 7 || license.length > 8) {
      errors.add('מספר רישוי חייב להכיל 7 או 8 ספרות');
      fieldErrors['license'] = 'מספר רישוי לא תקין';
    }

    // Price check
    if (priceStr.isEmpty) {
      errors.add('מחיר הוא שדה חובה');
      fieldErrors['price'] = 'חסר מחיר';
    } else {
      final price = int.tryParse(priceStr) ?? 0;
      if (price <= 0) {
        errors.add('מחיר חייב להיות גדול מ-0');
        fieldErrors['price'] = 'מחיר לא תקין';
      }
    }

    // Hand check
    if (handStr.isEmpty) {
      errors.add('מספר יד הוא שדה חובה');
      fieldErrors['hand'] = 'חסר מספר יד';
    } else {
      final hand = _parseHand(handStr);
      if (hand == null || hand < 1 || hand > 15) {
        errors.add('מספר יד חייב להיות בין 1 ל-15');
        fieldErrors['hand'] = 'יד לא תקינה';
      }
    }

    // Kilometers check
    int? currentKm;
    if (kmStr.isEmpty) {
      errors.add('קילומטראז\' הוא שדה חובה');
      fieldErrors['km'] = 'חסר קילומטראז\'';
    } else {
      currentKm = int.tryParse(kmStr);
      if (currentKm == null || currentKm < 0) {
        errors.add('קילומטראז\' חייב להיות מספר חיובי');
        fieldErrors['km'] = 'קילומטראז\' לא תקין';
      }
    }

    // Fetch kilometer_test_aharon if not provided and license plate is valid
    int? kmTestAharon = kilometerTestAharon;
    if (kmTestAharon == null && license.length >= 7) {
      kmTestAharon = await fetchKilometerTestAharon(license);
    }

    // Enforce km > kilometer_test_aharon validation rule
    if (currentKm != null && kmTestAharon != null) {
      if (currentKm <= kmTestAharon) {
        final kmErr =
            'הקילומטראז\' שהוזן ($currentKm) חייב להיות גדול מהקילומטראז\' בטסט האחרון ($kmTestAharon)';
        errors.add(kmErr);
        fieldErrors['km'] = kmErr;
      }
    }

    return FormValidationResult(
      isValid: errors.isEmpty,
      errors: errors,
      fieldErrors: fieldErrors,
      kilometerTestAharon: kmTestAharon,
    );
  }

  // ── 3. WhatsApp Text Extraction & AI Model Check ─────────────────────────

  /// Extract vehicle fields from raw Hebrew WhatsApp text using regex rules.
  Map<String, String> extractFieldsFromText(String text) {
    if (text.trim().isEmpty) return {};

    final result = <String, String>{};

    _putIfNotEmpty(result, 'license_plate', _extractLicensePlate(text));

    // Test month/year regex
    final testDateMatch = RegExp(
      r'(?:טסט|test)[^\d]{0,20}(\d{1,2})\s*[./\-]\s*(\d{2,4})',
      caseSensitive: false,
    ).firstMatch(text);
    if (testDateMatch != null) {
      _putIfNotEmpty(
        result,
        'test_month',
        _normalizeMonth(testDateMatch.group(1)),
      );
      _putIfNotEmpty(
        result,
        'test_year',
        _normalizeYear(testDateMatch.group(2)),
      );
    }

    _putIfNotEmpty(result, 'hand', _extractHand(text));
    _putIfNotEmpty(
      result,
      'current_ownership',
      _extractOwnership(text, r'(?:בעלות\s*נוכחית|בעלים\s*נוכחי|בעלות)'),
    );
    _putIfNotEmpty(
      result,
      'previous_ownership',
      _extractOwnership(text, r'(?:בעלות\s*קודמת|בעלים\s*קודמים|בעלים\s*קודם)'),
    );
    _putIfNotEmpty(result, 'km', _extractKm(text));
    _putIfNotEmpty(result, 'price', _extractPrice(text));
    _putIfNotEmpty(result, 'vehicle_condition', _extractVehicleCondition(text));
    _putIfNotEmpty(result, 'description', _extractDescription(text));
    _putIfNotEmpty(result, 'gear_type', _extractGear(text));

    return result;
  }

  /// AI Model integration to refine extraction or validate complex unstructured WhatsApp text.
  Future<Map<String, String>> askAiModelToExtractFields(
    String rawText,
    Map<String, String> currentFields,
  ) async {
    if (anthropicApiKey == null || anthropicApiKey!.isEmpty) {
      return currentFields;
    }

    try {
      final prompt = '''
אתה עוזר AI לניתוח והובלת תהליך פרסום רכב ב-WhatsApp בישראל.

היגיון וזרימת עבודה (Logic Flow & Session Rules):
1. התחלת וסיום סשן (Session Lifecycle):
   - סשן מתחיל ומסתיים כאשר נשלח מספר רישוי (לוחית זיהוי/מספר רכב) חדש לאפליקציה.
   - יש להתעלם מכל הנתונים, הטקסטים והאחסון שקדמו לחותמת הזמן (timestamp) של קבלת מספר הרישוי החדש.

2. ניהול שיחה והיסטוריית סשן (Chat History & Progress):
   - סשן מורכב ממספר הודעות ותשובות מול המשתמש.
   - מטרת הסשן היא לוודא ולתקף שכל שדות החובה של הרכב מלאים ותקינים, ורק לאחר מכן להתחיל בתהליך הפרסום (Publish process).
   - היסטוריית השיחה של הסשן הנוכחי נשמרת ומועברת אליך כדי שתוכל להגיב ולהנחות את המשתמש בצעד הבא.

3. אימות מול משרד התחבורה (data.gov.il API) והשלמת שדות חסרים:
   - עבור מספר רישוי שמתקבל, המערכת שולפת נתונים מ-APIs של data.gov.il.
   - יש לבחון אילו נתונים כבר קיימים ואילו נתונים חסרים, ולבקש מהמשתמש להשלים את השדות החסרים.
   - בכל איטרציה/הודעה יש לתקף מחדש את שלמות ואיכות כל שדות הנתונים לפני תחילת הפרסום.

4. חילוץ שדות מהטקסט (Field Extraction):
   - נתח מתוך הטקסט שנשלח על ידי המשתמש מהם שדות הנתונים שהמשתמש ציין או סיפק.

5. איפוס סשן בעקבות מספר רישוי שגוי או חדש (Reset Session):
   - אם במהלך השיחה המשתמש מבין שמספר הרישוי שנשלח היה שגוי ושולח מספר רישוי חדש, יש לאפס כליל את הסשן וההיסטוריה ולהתחיל סשן חדש ונקי לחלוטין עבור מספר הרישוי החדש.

שדות הרכב לחילוץ ואימות בפורמט JSON:
- license_plate: מספר רישוי (ספרות בלבד. אם יש בהודעה מספר בעל 7 או 8 ספרות, עם או בלי מקפים, חלץ אותו כשדה זה)
- km: קילומטראז' (מספר בלבד. שים לב שהנתון יכול להופיע בפורמטים כמו: קילומטרים, ק״מ, קילומטראז׳, נסע, שעון - כאשר המספר יכול להופיע לפני או אחרי המילים האלו)
- price: מחיר (מספר בלבד. שים לב שהמחיר יכול להופיע עם סמל/טקסט מטבע אחריו כמו ש״ח, ₪, או עם מילים מקדימות כמו דורש, מבקש, רוצה, מחיר)
- hand: יד (מספר בלבד, 1, 2, 3...)
- vehicle_condition: מצב הרכב ("חדש", "כמו חדש", "מצוין", "טוב מאוד", "טוב", "סביר", "משומש", "גרוע")
- description: תיאור/הערות

נתונים קיימים כעת: ${jsonEncode(currentFields)}

הודעת המשתמש:
"$rawText"

החזר JSON תקין בלבד ללא שום טקסט נוסף.
''';

      final body = jsonEncode({
        'model': aiModel,
        'max_tokens': 256,
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
      });

      final response = await http.post(
        Uri.parse('https://api.anthropic.com/v1/messages'),
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': anthropicApiKey!,
          'anthropic-version': '2023-06-01',
        },
        body: body,
      );

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final contentText =
            (decoded['content'] as List?)
                ?.whereType<Map>()
                .where((c) => c['type'] == 'text')
                .map((c) => c['text'] as String)
                .join(' ')
                .trim() ??
            '';

        final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(contentText);
        if (jsonMatch != null) {
          final jsonMap =
              jsonDecode(jsonMatch.group(0)!) as Map<String, dynamic>;
          final merged = Map<String, String>.from(currentFields);
          jsonMap.forEach((k, v) {
            if (v != null && v.toString().trim().isNotEmpty) {
              final strVal = v.toString().trim();
              if (merged[k] == null || merged[k]!.isEmpty) {
                merged[k] = strVal;
              }
            }
          });
          return merged;
        }
      }
    } catch (e) {
      debugPrint('[WhatsAppValidationService] AI extraction error: $e');
    }

    return currentFields;
  }

  /// Check if input text is a control command or system notification rather than vehicle description.
  bool isCommand(String text) {
    final norm = text.trim().toLowerCase();
    if (norm.isEmpty) return false;

    // Filter system notification phrases
    if (isSystemNotification(norm)) {
      return true;
    }

    // Single digits or small numbers 0..20 (e.g. '0', '1', '3')
    if (RegExp(r'^\d{1,2}$').hasMatch(norm)) return true;

    // Command words
    if (norm == 'ביטול' ||
        norm == 'בטל' ||
        norm == 'cancel' ||
        norm == 'stop' ||
        norm == 'פרסום' ||
        norm == 'פרסם' ||
        norm == 'publish') {
      return true;
    }

    // Image count phrases e.g. "3 תמונות", "2 photos"
    if (RegExp(
      r'^\d{1,2}\s*(?:תמונה|תמונות|photos?|images?)$',
    ).hasMatch(norm)) {
      return true;
    }

    return false;
  }

  // ── 4. Full WhatsApp Text Processing Pipeline ──────────────────────────────

  /// Full validation flow for incoming WhatsApp text messages.
  Future<WhatsAppValidationResult> validateWhatsAppTextMessage({
    required String text,
    required Map<String, String> existingState,
    int? kilometerTestAharon,
  }) async {
    final trimmedText = text.trim();

    // If text is a command (e.g. "0", "1", "3") or auto-publish was started/completed, do NOT compose missing detail errors!
    if (isCommand(trimmedText) ||
        existingState['KEY_AUTO_PUBLISH_STARTED'] == 'true' ||
        existingState['auto_publish_started'] == 'true') {
      return const WhatsAppValidationResult(
        isValid: true,
        extractedFields: {},
        missingFields: [],
        validationErrors: [],
        replyHebrew: '',
        readyToPublish: false,
        usedAiModel: false,
      );
    }

    // Step 1: Rule-based extraction
    var extracted = extractFieldsFromText(trimmedText);

    // Step 2: Fallback to AI model if fields are missing or text is descriptive
    bool usedAi = false;
    final missingInExtracted = _checkMissingKeys(extracted);
    if (missingInExtracted.isNotEmpty &&
        trimmedText.length > 10 &&
        anthropicApiKey != null) {
      extracted = await askAiModelToExtractFields(trimmedText, extracted);
      usedAi = true;
    }

    // Step 3: Combine with existing state
    final combinedState = Map<String, String>.from(existingState);
    extracted.forEach((k, v) {
      if (v.isNotEmpty) combinedState[k] = v;
    });

    // Step 4: Validate form fields & kilometer_test_aharon
    final formVal = await validateFormFields(
      combinedState,
      kilometerTestAharon: kilometerTestAharon,
    );

    final missingKeys = _checkMissingKeys(combinedState);
    final isReady = formVal.isValid && missingKeys.isEmpty;

    final maker = combinedState['maker'] ?? '';
    final model = combinedState['model'] ?? '';
    final year = combinedState['year'] ?? '';
    final titleParts = [
      maker,
      model,
      year,
    ].where((s) => s.isNotEmpty).join(' ');

    // Step 5: Compose Hebrew reply
    final replyBuilder = StringBuffer();

    final hasErrors = formVal.errors.isNotEmpty;
    final hasMissing = missingKeys.isNotEmpty;

    if (hasErrors || hasMissing) {
      if (titleParts.isNotEmpty) {
        replyBuilder.writeln('מצאתי את הרכב: $titleParts\n');
      }

      if (hasErrors) {
        replyBuilder.writeln('נמצאו שגיאות בנתונים:');
        for (final err in formVal.errors) {
          replyBuilder.writeln('• $err');
        }
        replyBuilder.writeln();
      }

      if (hasMissing) {
        replyBuilder.writeln('חסרים עדיין הנתונים הבאים:');
        for (final key in missingKeys) {
          replyBuilder.writeln('• ${_hebrewFieldLabel(key)}');
        }
      }
    } else {
      replyBuilder.writeln('פרטי הרכב נקלטו בהצלחה ומוכנים לפרסום:');
      if (titleParts.isNotEmpty) {
        replyBuilder.writeln('• רכב: $titleParts');
      }
      replyBuilder.writeln(
        '• רישוי: ${combinedState['license_plate'] ?? combinedState['license']}',
      );
      replyBuilder.writeln('• ק"מ: ${combinedState['km']}');
      replyBuilder.writeln('• מחיר: ${combinedState['price']} ₪');
      if (combinedState['hand'] != null && combinedState['hand']!.isNotEmpty) {
        replyBuilder.writeln('• יד: ${combinedState['hand']}');
      }
      final cond =
          combinedState['vehicle_condition'] ??
          combinedState['vehicleCondition'];
      if (cond != null && cond.isNotEmpty) {
        replyBuilder.writeln('• מצב: $cond');
      }
      replyBuilder.writeln('\nהנתונים מוכנים. כמה תמונות תרצה להעלות?');
      replyBuilder.writeln(
        'השב מספר תמונות מתוכנן להעלאה, או 0 כדי להתחיל פרסום בלי תמונות.',
      );
    }

    return WhatsAppValidationResult(
      isValid: formVal.isValid,
      extractedFields: extracted,
      missingFields: missingKeys,
      validationErrors: formVal.errors,
      replyHebrew: replyBuilder.toString().trim(),
      readyToPublish: isReady,
      usedAiModel: usedAi,
      kilometerTestAharon: formVal.kilometerTestAharon,
    );
  }

  // ── Internal extraction helpers ─────────────────────────────────────────

  List<String> _checkMissingKeys(Map<String, String> state) {
    const requiredKeys = [
      'license_plate',
      'maker',
      'model',
      'year',
      'hand',
      'km',
      'price',
      'color',
      'test_month',
      'test_year',
      'current_ownership',
    ];
    final missing = <String>[];
    for (final key in requiredKeys) {
      final val = state[key] ?? state[_altKey(key)];
      if (val == null || val.trim().isEmpty) {
        missing.add(key);
      }
    }
    return missing;
  }

  String _altKey(String key) {
    switch (key) {
      case 'license_plate':
        return 'license';
      case 'vehicle_condition':
        return 'vehicleCondition';
      case 'gear_type':
        return 'gear';
      case 'test_month':
        return 'month';
      case 'current_ownership':
        return 'ownership';
      default:
        return key;
    }
  }

  String _hebrewFieldLabel(String key) {
    switch (key) {
      case 'license_plate':
      case 'license':
        return 'מספר רישוי';
      case 'km':
        return 'קילומטראז\'';
      case 'price':
        return 'מחיר';
      case 'hand':
        return 'יד';
      case 'vehicle_condition':
      case 'vehicleCondition':
        return 'מצב הרכב';
      case 'maker':
        return 'יצרן';
      case 'model':
        return 'דגם';
      case 'year':
        return 'שנת ייצור';
      case 'color':
        return 'צבע';
      case 'gear_type':
      case 'gear':
        return 'גיר (אוטומטי/ידני)';
      case 'test_month':
      case 'month':
        return 'חודש טסט';
      case 'test_year':
        return 'שנת טסט';
      case 'current_ownership':
      case 'ownership':
        return 'בעלות נוכחית';
      default:
        return key;
    }
  }

  String? _extractLicensePlate(String text) {
    final explicit = RegExp(
      r'(?:מספר\s*(?:רכב|רישוי)?|לוחית(?:\s*רישוי)?|רישוי|license)[^\d]{0,16}(\d[\d\s\-]{5,10}\d)',
      caseSensitive: false,
    ).firstMatch(text);
    if (explicit != null) {
      final digits = _digitsOnly(explicit.group(1) ?? '');
      if (digits.length >= 7 && digits.length <= 8) return digits;
    }

    for (final match in RegExp(
      r'(?<!\d)(\d[\d\s\-]{5,10}\d)(?!\d)',
    ).allMatches(text)) {
      final candidate = _digitsOnly(match.group(1) ?? '');
      if (candidate.length >= 7 && candidate.length <= 8) return candidate;
    }
    return null;
  }

  String? _extractHand(String text) {
    final raw =
        RegExp(
          r'(?:יד|hand)\s*[:=\-]?\s*(ראשונה|שניה|שנייה|שלישית|רביעית|חמישית|\d{1,2})',
          caseSensitive: false,
        ).firstMatch(text)?.group(1)?.trim();
    if (raw == null) return null;

    if (raw.contains('ראש')) return '1';
    if (raw.contains('שני')) return '2';
    if (raw.contains('שליש')) return '3';
    if (raw.contains('רביע')) return '4';
    if (raw.contains('חמיש')) return '5';
    return _digitsOnly(raw).isNotEmpty ? _digitsOnly(raw) : null;
  }

  String? _extractOwnership(String text, String labelPattern) {
    final match = RegExp(
      '$labelPattern\\s*[:=\\-\\s]?\\s*([^,.;\\n]+)',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return null;
    final val = match.group(1)?.trim() ?? '';
    if (val.contains('פרטי')) return 'פרטית';
    if (val.contains('חברה')) return 'חברה';
    if (val.contains('ליסינג')) return 'ליסינג';
    if (val.contains('השכרה')) return 'השכרה';
    if (val.contains('מונית')) return 'מונית';
    return val.isNotEmpty ? val : null;
  }

  String? _extractKm(String text) {
    final labelFirst = RegExp(
      r'''(?:קילומטראז['׳]?|קילומטרים|ק["״]מ|קמ|נסע|שעון|km)\s*[:=\-]?\s*([\d,.\s]{2,})(?:\s*אלף)?''',
      caseSensitive: false,
    ).firstMatch(text);
    final valueFirst = RegExp(
      r'''([\d,.\s]{2,})(?:\s*אלף)?\s*(?:קילומטראז['׳]?|קילומטרים|ק["״]מ|קמ|נסע|שעון|km)''',
      caseSensitive: false,
    ).firstMatch(text);

    final match = labelFirst ?? valueFirst;
    if (match == null) return null;

    final digits = _digitsOnly(match.group(1) ?? '');
    if (digits.isEmpty) return null;

    if (match.group(0)!.contains('אלף') && digits.length <= 3) {
      final num = int.tryParse(digits);
      return num != null ? (num * 1000).toString() : digits;
    }
    return digits;
  }

  String? _extractPrice(String text) {
    final labeled = RegExp(
      r'(?:מחיר|price|דורש|מבקש|רוצה)\s*[:=\-]?\s*([\d,.\s]{2,})(?:\s*אלף)?',
      caseSensitive: false,
    ).firstMatch(text);
    if (labeled != null) {
      final digits = _digitsOnly(labeled.group(1) ?? '');
      if (digits.isNotEmpty) {
        if (labeled.group(0)!.contains('אלף') && digits.length <= 3) {
          final num = int.tryParse(digits);
          return num != null ? (num * 1000).toString() : digits;
        }
        return digits;
      }
    }

    final currency = RegExp(
      r'([\d,.\s]{2,})(?:\s*אלף)?\s*(?:₪|ש["״]ח|שח|nis)',
      caseSensitive: false,
    ).firstMatch(text);
    if (currency != null) {
      final digits = _digitsOnly(currency.group(1) ?? '');
      if (digits.isNotEmpty) {
        if (currency.group(0)!.contains('אלף') && digits.length <= 3) {
          final num = int.tryParse(digits);
          return num != null ? (num * 1000).toString() : digits;
        }
        return digits;
      }
    }
    return null;
  }

  String? _extractVehicleCondition(String text) {
    final norm = text.toLowerCase();
    if (norm.contains('מצוין') ||
        norm.contains('מצויין') ||
        norm.contains('מעולה')) {
      return 'מצוין';
    }
    if (norm.contains('טוב מאוד') || norm.contains('טובה מאוד')) {
      return 'טוב מאוד';
    }
    if (norm.contains('סביר')) return 'סביר';
    if (norm.contains('טוב') || norm.contains('טובה')) return 'טוב';
    if (norm.contains('גרוע') || norm.contains('לא טוב')) return 'גרוע';
    return null;
  }

  String? _extractDescription(String text) {
    final match = RegExp(
      r'(?:תיאור|הערות|פירוט)\s*[:=\-]\s*(.+)',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return null;
    final line = match.group(1)?.split('\n').first.trim() ?? '';
    return line.isNotEmpty
        ? line.substring(0, line.length > 240 ? 240 : line.length)
        : null;
  }

  String? _extractGear(String text) {
    final norm = text.toLowerCase();
    if (norm.contains('ידני') || norm.contains('manual')) return 'שידור ידני';
    if (norm.contains('אוטומט') || norm.contains('auto')) {
      return 'הילוכים אוטומטיים';
    }
    return null;
  }

  String _normalizeMonth(String? raw) {
    final m = int.tryParse(_digitsOnly(raw ?? ''));
    if (m != null && m >= 1 && m <= 12) return m.toString();
    return '';
  }

  String? _normalizeYear(String? raw) {
    final digits = _digitsOnly(raw ?? '');
    if (digits.length == 2) return '20$digits';
    if (digits.length == 4) return digits;
    return null;
  }

  int? _parseHand(String handStr) {
    final clean = handStr.trim();
    if (clean.isEmpty) return null;
    final parsed = int.tryParse(clean);
    if (parsed != null) return parsed;

    // Check Hebrew text
    if (clean.contains('ראש')) return 1;
    if (clean.contains('שנ') || clean.contains('שני')) return 2;
    if (clean.contains('שלש') || clean.contains('שליש')) return 3;
    if (clean.contains('רבע') || clean.contains('רביע')) return 4;
    if (clean.contains('חמיש')) return 5;
    if (clean.contains('שש') || clean.contains('שישי')) return 6;
    if (clean.contains('שבע') || clean.contains('שביעי')) return 7;
    if (clean.contains('שמנ') || clean.contains('שמיני')) return 8;
    if (clean.contains('תשע') || clean.contains('תשיעי')) return 9;
    if (clean.contains('עשר') || clean.contains('עשירי')) return 10;

    // Try to extract any digits
    final digits = clean.replaceAll(RegExp(r'[^\d]'), '');
    return int.tryParse(digits);
  }

  void _putIfNotEmpty(Map<String, String> map, String key, String? val) {
    if (val != null && val.trim().isNotEmpty) {
      map[key] = val.trim();
    }
  }

  String _digitsOnly(String val) => val.replaceAll(RegExp(r'[^\d]'), '');
}
