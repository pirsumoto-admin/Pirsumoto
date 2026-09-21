import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'agent_config_service.dart';
import 'vehicle_data_service.dart';

class RemoteValidationResult {
  final Map<String, String> vehicleData;
  final String botReply;
  final bool isReadyToPublish;
  final bool allDataFilled;
  final List<String> missingFields;
  final List<String> validationErrors;

  const RemoteValidationResult({
    required this.vehicleData,
    required this.botReply,
    this.isReadyToPublish = false,
    this.allDataFilled = false,
    this.missingFields = const [],
    this.validationErrors = const [],
  });
}

/// Core conversational, Whisper STT, Gov.il querying, and LLM validation engine
/// in Pirsumoto_remote_control.
///
/// All LLM reasoning & Whisper transcriptions are securely proxied via Google Cloud Functions
/// so that NO API keys are ever bundled, cached, or stored on the mobile device.
class RemoteValidationService {
  /// Secure Firebase Cloud Function backend endpoint
  static const String cloudFunctionUrl =
      'https://me-west1-car-publisher.cloudfunctions.net/remoteValidation';

  /// Transcribe audio file securely via backend Cloud Function (Whisper)
  static Future<String?> transcribeAudio(File audioFile) async {
    try {
      final bytes = await audioFile.readAsBytes();
      final base64Audio = base64Encode(bytes);
      final fileName = audioFile.path.split('/').last;
      final ext = fileName.split('.').last.toLowerCase();
      final mimeType = ext == 'm4a' || ext == 'mp4' ? 'audio/m4a' : 'audio/ogg';

      final response = await http
          .post(
            Uri.parse(cloudFunctionUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'action': 'transcribe_audio',
              'audioBase64': base64Audio,
              'mimeType': mimeType,
              'fileName': fileName,
            }),
          )
          .timeout(const Duration(seconds: 35));

      if (response.statusCode == 200) {
        final resData =
            jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        if (resData['ok'] == true && resData['text'] != null) {
          return normalizeTranscribedText(resData['text'].toString());
        }
      } else {
        debugPrint(
          '[RemoteValidation] Cloud transcribe failed: ${response.statusCode} - ${response.body}',
        );
      }
    } catch (e) {
      debugPrint('[RemoteValidation] Cloud transcribe error: $e');
    }
    return null;
  }

  /// Normalize number words in Hebrew into digits
  static String normalizeTranscribedText(String text) {
    var s = text.trim();
    final wordToDigit = {
      'אפס': '0',
      'אחת': '1',
      'אחד': '1',
      'שתיים': '2',
      'שניים': '2',
      'שתים': '2',
      'שנים': '2',
      'שלוש': '3',
      'שלושה': '3',
      'ארבע': '4',
      'ארבעה': '4',
      'חמש': '5',
      'חמישה': '5',
      'שש': '6',
      'שישה': '6',
      'שבע': '7',
      'שבעה': '7',
      'שמונה': '8',
      'שמונה עשרה': '18',
      'תשע': '9',
      'תשעה': '9',
      'עשר': '10',
      'עשרה': '10',
      'עשרים': '20',
      'שלושים': '30',
      'ארבעים': '40',
      'חמישים': '50',
      'שישים': '60',
      'שבעים': '70',
      'שמונים': '80',
      'תשעים': '90',
      'מאה': '100',
    };

    for (final entry in wordToDigit.entries) {
      s = s.replaceAll(
        RegExp(
          '(?<=^|[\\s,.\\-!?])${RegExp.escape(entry.key)}(?=\$|[\\s,.\\-!?])',
          caseSensitive: false,
        ),
        entry.value,
      );
    }
    return s;
  }

  /// Process incoming text message against current session vehicle draft.
  /// Securely proxies turn processing to backend Cloud Function.
  static Future<RemoteValidationResult> processTurn({
    required String incomingText,
    required Map<String, String> currentVehicleData,
    required List<Map<String, String>> chatHistory,
    List<String> currentImagePaths = const [],
  }) async {
    final state = Map<String, String>.from(currentVehicleData);
    final trimmed = incomingText.trim();

    // 1. Try secure backend Cloud Function turn processing
    try {
      final prompt = AgentConfigService.instance.systemPrompt;
      final response = await http
          .post(
            Uri.parse(cloudFunctionUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'action': 'process_turn',
              'incomingText': trimmed,
              'currentVehicleData': state,
              'chatHistory': chatHistory,
              'currentImageCount': currentImagePaths.length,
              'systemPrompt': prompt,
            }),
          )
          .timeout(const Duration(seconds: 25));

      if (response.statusCode == 200) {
        final data =
            jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        if (data['ok'] == true) {
          final rawVehicle = data['vehicleData'] as Map<String, dynamic>? ?? {};
          final vehicleData = rawVehicle.map(
            (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
          );
          final botReply = data['botReply']?.toString() ?? '';
          final isReady = data['isReadyToPublish'] == true;
          final missing =
              (data['missingFields'] as List?)
                  ?.map((e) => e.toString())
                  .toList() ??
              [];
          final errors =
              (data['validationErrors'] as List?)
                  ?.map((e) => e.toString())
                  .toList() ??
              [];

          final allDataFilled = data['allDataFilled'] == true ||
              data['isAllFieldsFilled'] == true ||
              (missing.isEmpty && errors.isEmpty && vehicleData['license_plate']?.isNotEmpty == true);

          return RemoteValidationResult(
            vehicleData: vehicleData,
            botReply: botReply,
            isReadyToPublish: isReady,
            allDataFilled: allDataFilled,
            missingFields: missing,
            validationErrors: errors,
          );
        }
      } else {
        debugPrint(
          '[RemoteValidation] Cloud process_turn status ${response.statusCode}: ${response.body}',
        );
      }
    } catch (e) {
      debugPrint(
        '[RemoteValidation] Cloud process_turn error (falling back to local): $e',
      );
    }

    // 2. Offline / network fallback: local heuristic validation without requiring any API keys
    return _processTurnOfflineFallback(
      incomingText: trimmed,
      currentVehicleData: state,
      currentImagePaths: currentImagePaths,
    );
  }

  static Future<RemoteValidationResult> _processTurnOfflineFallback({
    required String incomingText,
    required Map<String, String> currentVehicleData,
    required List<String> currentImagePaths,
  }) async {
    final state = Map<String, String>.from(currentVehicleData);
    final trimmed = incomingText.trim();

    // 1. Check for Israeli License Plate (7 or 8 digits)
    final plateMatch = RegExp(r'\b\d{7,8}\b').firstMatch(trimmed);
    final rawPlate = plateMatch?.group(0);

    bool isFirstTurn = false;
    if (rawPlate != null &&
        (state['license_plate'] == null || state['license_plate']!.isEmpty)) {
      state['license_plate'] = rawPlate;
      state['license'] = rawPlate;
      isFirstTurn = true;

      final govData = await VehicleDataService.fetchVehicleData(rawPlate);
      if (govData != null) {
        state['maker'] = govData['maker'] ?? '';
        state['model'] = govData['model'] ?? '';
        state['year'] = govData['year'] ?? '';
        state['color'] = govData['color'] ?? '';
        state['fuel_type'] = govData['fuelType'] ?? '';
        state['current_ownership'] = govData['ownership'] ?? 'פרטית';
        state['previous_ownership'] = govData['ownership'] ?? 'פרטית';
        state['month'] = govData['registrationMonth'] ?? '';
        state['test_month'] = govData['registrationMonth'] ?? '';
        state['gear_type'] = govData['gear_type'] ?? 'הילוכים אוטומטיים';
      }
    }

    final hasActiveSession =
        state['license_plate'] != null && state['license_plate']!.isNotEmpty;
    if (hasActiveSession &&
        (state['vehicle_condition'] == null ||
            state['vehicle_condition']!.isEmpty)) {
      state['vehicle_condition'] = 'טוב';
    }

    final missingBeforeTurn =
        hasActiveSession
            ? getMissingFields(state)
            : const <String>['license_plate'];

    // Positional multi-line / comma sequential extraction according to rules_md
    if (hasActiveSession && missingBeforeTurn.isNotEmpty) {
      final parts =
          trimmed
              .split(RegExp(r'[\n,;/]+'))
              .map((p) => p.trim())
              .where((p) => p.isNotEmpty)
              .toList();

      if (parts.length > 1 ||
          (parts.length == 1 && missingBeforeTurn.length == 1)) {
        for (int i = 0; i < parts.length && i < missingBeforeTurn.length; i++) {
          final field = missingBeforeTurn[i];
          final val = parts[i];
          if (state[field] == null || state[field]!.isEmpty) {
            if (field == 'km' || field == 'price') {
              final digits = val.replaceAll(RegExp(r'\D'), '');
              if (int.tryParse(digits) != null && int.parse(digits) > 0) {
                var num = digits;
                if (val.contains('אלף') && int.parse(num) < 1000) {
                  num = '${int.parse(num) * 1000}';
                }
                state[field] = num;
              }
            } else if (field == 'hand') {
              state[field] = _normalizeHand(val);
            } else if (field == 'color') {
              state[field] = val;
            } else if (field == 'vehicle_condition') {
              state[field] = val;
            }
          }
        }
      }
    }

    // Heuristic extraction for numbers & hand
    if (hasActiveSession) {
      if (state['km'] == null || state['km']!.isEmpty) {
        final kmMatch = RegExp(
          r'\b(\d{1,3}(?:,\d{3})+|\d{4,6})\s*(?:ק"?מ|קילומטר)?\b',
        ).firstMatch(trimmed);
        if (kmMatch != null && kmMatch.group(1) != state['license_plate']) {
          state['km'] = kmMatch.group(1)!.replaceAll(',', '');
        }
      }
      if (state['price'] == null || state['price']!.isEmpty) {
        final priceMatch = RegExp(
          r'\b(?:מחיר|ב-?|סך)\s*(\d{2,6})\b|\b(\d{2,6})\s*(?:ש"ח|שח|שקל|אלף)\b',
        ).firstMatch(trimmed);
        if (priceMatch != null) {
          var p = priceMatch.group(1) ?? priceMatch.group(2)!;
          if (trimmed.contains('אלף') &&
              int.tryParse(p) != null &&
              int.parse(p) < 1000) {
            p = '${int.parse(p) * 1000}';
          }
          state['price'] = p;
        }
      }
      if (state['hand'] == null || state['hand']!.isEmpty) {
        final handMatch = RegExp(
          r'\bיד\s*(\d+|ראשונה|שנייה|שניה|שלישית|רביעית)\b',
        ).firstMatch(trimmed);
        if (handMatch != null) {
          state['hand'] = _normalizeHand(handMatch.group(1)!);
        }
      }
    }

    final missing =
        hasActiveSession
            ? getMissingFields(state)
            : const <String>['license_plate'];
    final errors = hasActiveSession ? validateValues(state) : const <String>[];
    final bool isReady =
        hasActiveSession &&
        missing.isEmpty &&
        errors.isEmpty &&
        currentImagePaths.isNotEmpty;

    final finalReply = _composeHebrewReply(
      state: state,
      missingKeys: missing,
      validationErrors: errors,
      isFirstTurn: isFirstTurn,
      imageCount: currentImagePaths.length,
    );

    final bool allDataFilled = hasActiveSession && missing.isEmpty && errors.isEmpty;

    return RemoteValidationResult(
      vehicleData: state,
      botReply: finalReply,
      isReadyToPublish: isReady,
      allDataFilled: allDataFilled,
      missingFields: missing,
      validationErrors: errors,
    );
  }

  static List<String> getMissingFields(Map<String, String> state) {
    final missing = <String>[];
    if (state['license_plate'] == null || state['license_plate']!.isEmpty) {
      missing.add('license_plate');
    }
    if (state['km'] == null || state['km']!.isEmpty) {
      missing.add('km');
    }
    if (state['price'] == null || state['price']!.isEmpty) {
      missing.add('price');
    }
    if (state['hand'] == null || state['hand']!.isEmpty) {
      missing.add('hand');
    }
    if (state['color'] == null || state['color']!.isEmpty) {
      missing.add('color');
    }
    return missing;
  }

  static List<String> validateValues(Map<String, String> state) {
    final errors = <String>[];
    final km = int.tryParse(state['km'] ?? '');
    if (state['km'] != null &&
        state['km']!.isNotEmpty &&
        (km == null || km < 0 || km > 1500000)) {
      errors.add('קילומטראז לא תקין');
    }
    final price = int.tryParse(state['price'] ?? '');
    if (state['price'] != null &&
        state['price']!.isNotEmpty &&
        (price == null || price <= 0)) {
      errors.add('מחיר לא תקין');
    }
    return errors;
  }

  static String _normalizeHand(String h) {
    if (h == 'ראשונה' || h == '1') return '1';
    if (h == 'שנייה' || h == 'שניה' || h == '2') return '2';
    if (h == 'שלישית' || h == '3') return '3';
    if (h == 'רביעית' || h == '4') return '4';
    if (h == 'חמישית' || h == '5') return '5';
    return h;
  }

  static String _composeHebrewReply({
    required Map<String, String> state,
    required List<String> missingKeys,
    required List<String> validationErrors,
    bool isFirstTurn = false,
    int imageCount = 0,
  }) {
    final sb = StringBuffer();
    final maker = state['maker'] ?? '';
    final model = state['model'] ?? '';
    final year = state['year'] ?? '';
    final plate = state['license_plate'] ?? '';

    if (plate.isEmpty) {
      return 'שלום! 👋 אני הבוט של פירסומוטו לפרסום רכב.\nכדי להתחיל, שלח מספר רישוי ישראלי (7 או 8 ספרות), או הקלט הודעה קולית עם פרטי הרכב.';
    }

    if (isFirstTurn) {
      if (maker.isNotEmpty) {
        sb.writeln(
          '🚗 זיהיתי את הרכב: $maker $model שנת $year (רישוי $plate).',
        );
      } else {
        sb.writeln('🚗 מספר רישוי נקלט: $plate.');
      }
    }

    if (validationErrors.isNotEmpty) {
      sb.writeln('\n⚠️ שים לב:');
      for (final err in validationErrors) {
        sb.writeln('• $err');
      }
    }

    if (missingKeys.isNotEmpty) {
      sb.writeln('\nכדי להשלים את הפרסום, אנא ציין:');
      for (final key in missingKeys) {
        switch (key) {
          case 'km':
            sb.writeln('• קילומטראז\' (ק"מ)');
            break;
          case 'price':
            sb.writeln('• מחיר מבוקש בש"ח');
            break;
          case 'hand':
            sb.writeln('• יד (למשל: יד 1, יד 2)');
            break;
          case 'color':
            sb.writeln('• צבע הרכב');
            break;
        }
      }
    } else {
      sb.writeln('\n✅ כל פרטי הרכב מלאים ומאומתים!');
      if (imageCount == 0) {
        sb.writeln('📷 אנא צרף לפחות תמונה אחת של הרכב כדי להתחיל בפרסום.');
      } else {
        sb.writeln(
          '📷 צורפו $imageCount תמונות. לחץ על "פרסם עכשיו" להתחלת הפרסום ביד2.',
        );
      }
    }

    return sb.toString().trim();
  }
}
