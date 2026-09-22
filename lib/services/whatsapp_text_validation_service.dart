import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'agent_config_service.dart';
import 'p2p_auto_publish_launcher.dart';
import 'vehicle_data_service.dart';
// [WHATSAPP-DISABLED] whatsapp_message_bridge_service import disabled.
// import 'whatsapp_message_bridge_service.dart';
import 'yad2_accessibility_automation_service_optimized.dart';

typedef VehicleDataFetcher =
    Future<Map<String, dynamic>?> Function(String licensePlate);
typedef KilometerHistoryFetcher = Future<int?> Function(String licensePlate);
typedef WhatsAppReplySender =
    Future<bool> Function({required String senderKey, required String message});
typedef AutoPublishLauncher =
    Future<bool> Function(Map<String, String> vehicleData);
typedef AutomationStopper = void Function();
typedef AiTurnProcessor =
    Future<AiTurnResult?> Function(Map<String, dynamic> requestData);

/// Result of an agentic conversational turn with the AI model.
class AiTurnResult {
  final String intent;
  final Map<String, String> extractedFields;
  final String? assistantReply;
  final bool shouldRepublish;

  const AiTurnResult({
    this.intent = 'update_details',
    this.extractedFields = const {},
    this.assistantReply,
    this.shouldRepublish = false,
  });

  @override
  String toString() =>
      'AiTurnResult(intent: $intent, extractedFields: $extractedFields, assistantReply: $assistantReply, shouldRepublish: $shouldRepublish)';
}

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

  static List<String> get yad2AllowedColors =>
      AgentConfigService.instance.allowedColors;

  static const Set<String> _extractableAiFields = {
    'km',
    'price',
    'hand',
    'vehicle_condition',
    'maker',
    'model',
    'year',
    'color',
    'month',
    'test_month',
    'test_year',
    'current_ownership',
    'previous_ownership',
    'description',
    'gear_type',
    'fuel_type',
  };

  static const Set<String> _vehicleSnapshotFields = {
    'license_plate',
    'license',
    'maker',
    'model',
    'year',
    'month',
    'test_month',
    'test_year',
    'color',
    'km',
    'price',
    'hand',
    'current_ownership',
    'previous_ownership',
    'vehicle_condition',
    'gear_type',
    'description',
    'kilometer_test_aharon',
    'engine_size',
    'fuel_type',
    'trim_level',
  };

  static final Map<String, Map<String, String>> _senderStateCache = {};
  static final Map<String, Map<String, String>> _lastVehicleCache = {};
  static final Map<String, Future<void>> _senderOperations = {};
  static final Map<String, WhatsAppReplySender> _customReplySenders = {};
  static final List<AutoPublishLauncher> _customAutoPublishLaunchers = [];
  static final Map<String, Timer> _imageDebounceTimers = {};

  static void registerReplySender(String senderKey, WhatsAppReplySender sender) {
    _customReplySenders[senderKey] = sender;
  }

  static void unregisterReplySender(String senderKey) {
    _customReplySenders.remove(senderKey);
  }

  static void registerAutoPublishLauncher(AutoPublishLauncher launcher) {
    _customAutoPublishLaunchers.add(launcher);
  }

  static void unregisterAutoPublishLauncher(AutoPublishLauncher launcher) {
    _customAutoPublishLaunchers.remove(launcher);
  }

  final String? anthropicApiKey;
  final String aiModel;
  final VehicleDataFetcher? vehicleDataFetcher;
  final KilometerHistoryFetcher? kilometerHistoryFetcher;
  final WhatsAppReplySender? replySender;
  final AutoPublishLauncher? autoPublishLauncher;
  final AutomationStopper? automationStopper;
  final AiTurnProcessor? aiTurnProcessor;

  const WhatsAppTextValidationService({
    this.anthropicApiKey,
    this.aiModel = 'gpt-5.6-luna',
    this.vehicleDataFetcher,
    this.kilometerHistoryFetcher,
    this.replySender,
    this.autoPublishLauncher,
    this.automationStopper,
    this.aiTurnProcessor,
  });

  // ── Persistent State Management & WhatsApp Event Pipeline ─────────────────────────

  static String _statePrefKey(String senderKey) => 'wa_state_$senderKey';
  static String _lastVehiclePrefKey(String senderKey) =>
      'wa_last_vehicle_$senderKey';

  Future<Map<String, String>> loadLastVehicle(String senderKey) async {
    final cached = _lastVehicleCache[senderKey];
    if (cached != null && cached.isNotEmpty) {
      return Map<String, String>.from(cached);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      if (senderKey.isNotEmpty) {
        final jsonStr = prefs.getString(_lastVehiclePrefKey(senderKey));
        if (jsonStr != null && jsonStr.isNotEmpty) {
          final map = jsonDecode(jsonStr) as Map<String, dynamic>;
          final result = map.map((k, v) => MapEntry(k, v?.toString() ?? ''));
          _lastVehicleCache[senderKey] = result;
          return Map<String, String>.from(result);
        }
      }

      // Fallback across any saved vehicle in the app (e.g. if senderKey format changed or from another session)
      final keys = prefs.getKeys();
      for (final k in keys) {
        if (k.startsWith('wa_last_vehicle_')) {
          final s = prefs.getString(k);
          if (s != null && s.isNotEmpty) {
            try {
              final map = jsonDecode(s) as Map<String, dynamic>;
              final result =
                  map.map((key, v) => MapEntry(key, v?.toString() ?? ''));
              if ((result['license_plate'] ?? result['license'] ?? '')
                  .trim()
                  .isNotEmpty) {
                return Map<String, String>.from(result);
              }
            } catch (_) {}
          }
        }
      }
      return {};
    } catch (_) {
      return {};
    }
  }

  Future<void> saveLastVehicle(
    String senderKey,
    Map<String, String> vehicleData,
  ) async {
    if (senderKey.isEmpty) return;
    final current = await loadLastVehicle(senderKey);
    final updated = Map<String, String>.from(current);
    vehicleData.forEach((k, v) {
      final val = v.trim();
      if (val.isNotEmpty) {
        updated[k] = val;
      }
    });
    _lastVehicleCache[senderKey] = updated;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastVehiclePrefKey(senderKey), jsonEncode(updated));
  }

  Future<void> clearLastVehicle(String senderKey) async {
    if (senderKey.isEmpty) return;
    _lastVehicleCache.remove(senderKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastVehiclePrefKey(senderKey));
  }

  Future<Map<String, String>> loadSenderState(String senderKey) async {
    if (senderKey.isEmpty) return {};
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_statePrefKey(senderKey));
    if (jsonStr == null || jsonStr.isEmpty) {
      _senderStateCache.remove(senderKey);
      return {};
    }
    try {
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      final result = map.map((k, v) => MapEntry(k, v?.toString() ?? ''));
      _senderStateCache[senderKey] = result;
      return Map<String, String>.from(result);
    } catch (_) {
      return {};
    }
  }

  Future<T> _runForSender<T>(String senderKey, Future<T> Function() action) {
    if (senderKey.isEmpty) return action();

    final previous = _senderOperations[senderKey] ?? Future<void>.value();
    final completer = Completer<T>();
    late final Future<void> operation;
    operation = previous
        .then<void>(
          (_) async {
            try {
              completer.complete(await action());
            } catch (error, stackTrace) {
              completer.completeError(error, stackTrace);
            }
          },
          onError: (_) async {
            try {
              completer.complete(await action());
            } catch (error, stackTrace) {
              completer.completeError(error, stackTrace);
            }
          },
        )
        .whenComplete(() {
          if (identical(_senderOperations[senderKey], operation)) {
            _senderOperations.remove(senderKey);
          }
        });
    _senderOperations[senderKey] = operation;
    return completer.future;
  }

  Future<void> saveSenderState(
    String senderKey,
    Map<String, String> state,
  ) async {
    if (senderKey.isEmpty) return;
    _senderStateCache[senderKey] = Map<String, String>.from(state);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_statePrefKey(senderKey), jsonEncode(state));

    final vehicleFields = <String, String>{};
    for (final field in _vehicleSnapshotFields) {
      final val = state[field]?.trim() ?? '';
      if (val.isNotEmpty) {
        vehicleFields[field] = val;
      }
    }
    final license = (state['license_plate'] ?? state['license'] ?? '').trim();
    if (license.isNotEmpty) {
      vehicleFields['license_plate'] = license;
    }

    if (vehicleFields.isNotEmpty) {
      final existing = await loadLastVehicle(senderKey);
      final merged = Map<String, String>.from(existing)..addAll(vehicleFields);
      _lastVehicleCache[senderKey] = merged;
      await prefs.setString(_lastVehiclePrefKey(senderKey), jsonEncode(merged));
    }
  }

  Future<void> clearSenderState(String senderKey) async {
    if (senderKey.isEmpty) return;
    _imageDebounceTimers[senderKey]?.cancel();
    _imageDebounceTimers.remove(senderKey);
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
  }) {
    return _runForSender(
      senderKey,
      () => _handleIncomingTextMessageUnlocked(
        text: text,
        senderKey: senderKey,
        senderName: senderName,
        timestamp: timestamp,
      ),
    );
  }

  Future<Map<String, String>?> _handleIncomingTextMessageUnlocked({
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

    // Cancellation and a new plate are lifecycle events. They must take
    // precedence over image collection and an already-running publication.
    if (_isCancelCommand(trimmedText, allowNumericShortcut: true)) {
      _stopAutomation();
      await clearSenderState(senderKey);
      await _sendReply(senderKey, 'תהליך הפרסום בוטל והסשן נסגר.');
      return {};
    }

    // Ensure agent system prompt & rules are up-to-date from Firestore before processing session
    await AgentConfigService.instance.checkAndUpdateConfigIfNeeded();

    final incomingLicense = _extractLicensePlate(trimmedText);
    final startsNewSession = incomingLicense != null;

    if (!startsNewSession && _isAutomationRunning(currentState)) {
      await _sendReply(
        senderKey,
        'תהליך הפרסום ביד2 בעיצומו. '
        'לביטול שלח "ביטול", או שלח מספר רישוי כדי לסיים את הסשן ולהתחיל חדש.',
      );
      return currentState;
    }

    if (!startsNewSession && !_hasSession(currentState)) {
      final lastVehicle = await loadLastVehicle(senderKey);
      final hasAi = await _hasAiApiKey();

      if (hasAi) {
        final aiResult = await askAiModelToProcessTurn(
          trimmedText,
          const {},
          lastSavedVehicle: lastVehicle,
          hasActiveSession: false,
        );

        if (aiResult.shouldRepublish || aiResult.intent == 'republish_last') {
          final savedLicense =
              (lastVehicle['license_plate'] ?? lastVehicle['license'] ?? '')
                  .trim();
          if (savedLicense.isNotEmpty) {
            _stopAutomation();
            final eventTimestamp =
                timestamp ?? DateTime.now().millisecondsSinceEpoch;
            final newState = <String, String>{
              ...lastVehicle,
              'license_plate': savedLicense,
              'session_id': '$savedLicense-$eventTimestamp',
              'session_status': 'collecting_details',
              'session_start_timestamp': '$eventTimestamp',
              'chat_history': jsonEncode([
                {
                  'role': 'user',
                  'text': trimmedText,
                  'timestamp': '$eventTimestamp',
                }
              ]),
            };
            _attachSenderMetadata(newState, senderKey, senderName);
            _mergeNonEmpty(newState, aiResult.extractedFields);
            _normalizeStateFields(newState);

            if ((newState['vehicle_condition'] == null ||
                    newState['vehicle_condition']!.isEmpty) &&
                (newState['vehicleCondition'] == null ||
                    newState['vehicleCondition']!.isEmpty)) {
              newState['vehicle_condition'] = 'טוב';
            }

            final formVal = await validateFormFields(
              newState,
              kilometerTestAharon: int.tryParse(
                newState['kilometer_test_aharon'] ?? '',
              ),
              fetchKilometerWhenMissing: false,
            );
            final missingKeys = _checkMissingKeys(newState);
            final readyToPublish = formVal.isValid && missingKeys.isEmpty;
            newState['session_status'] =
                readyToPublish ? 'ready_for_images' : 'collecting_details';
            newState['last_requested_fields'] = jsonEncode(missingKeys);

            final carTitle = [
              newState['maker'] ?? '',
              newState['model'] ?? '',
              newState['year'] ?? ''
            ].where((s) => s.isNotEmpty).join(' ');

            final reply = (aiResult.assistantReply != null &&
                    aiResult.assistantReply!.trim().isNotEmpty)
                ? aiResult.assistantReply!
                : (readyToPublish
                    ? 'שחזרתי את פרטי הרכב ($carTitle, רישוי $savedLicense). כל הפרטים מלאים! אנא שלח תמונות של הרכב כדי להתחיל בפרסום.'
                    : composeHebrewReply(
                        state: newState,
                        formVal: formVal,
                        missingKeys: missingKeys,
                      ));

            final chatHistory = _parseChatHistory(newState['chat_history']);
            chatHistory.add({
              'role': 'assistant',
              'text': reply,
              'timestamp': '${DateTime.now().millisecondsSinceEpoch}',
            });
            newState['chat_history'] = jsonEncode(chatHistory);

            await saveSenderState(senderKey, newState);
            await _sendReply(senderKey, reply);
            return newState;
          } else {
            final noVehicleReply = (aiResult.assistantReply != null &&
                    aiResult.assistantReply!.trim().isNotEmpty)
                ? aiResult.assistantReply!
                : 'לא נמצאו פרטי רכב שמורים במערכת. כדי להתחיל פרסום רכב, שלח תחילה מספר רישוי ישראלי בעל 7 או 8 ספרות.';
            await _sendReply(senderKey, noVehicleReply);
            return currentState;
          }
        }

        if (aiResult.assistantReply != null &&
            aiResult.assistantReply!.trim().isNotEmpty) {
          await _sendReply(senderKey, aiResult.assistantReply!);
          return currentState;
        }
      }

      final isLiteralRepublish = _isRepublishCommand(trimmedText);
      final savedLicense =
          (lastVehicle['license_plate'] ?? lastVehicle['license'] ?? '').trim();
      if (isLiteralRepublish) {
        if (savedLicense.isNotEmpty) {
          _stopAutomation();
          final eventTimestamp =
              timestamp ?? DateTime.now().millisecondsSinceEpoch;
          final newState = <String, String>{
            ...lastVehicle,
            'license_plate': savedLicense,
            'session_id': '$savedLicense-$eventTimestamp',
            'session_status': 'collecting_details',
            'session_start_timestamp': '$eventTimestamp',
            'chat_history': jsonEncode([
              {
                'role': 'user',
                'text': trimmedText,
                'timestamp': '$eventTimestamp',
              }
            ]),
          };
          _attachSenderMetadata(newState, senderKey, senderName);
          _normalizeStateFields(newState);
          if ((newState['vehicle_condition'] == null ||
              newState['vehicle_condition']!.isEmpty)) {
            newState['vehicle_condition'] = 'טוב';
          }

          final formVal = await validateFormFields(
            newState,
            kilometerTestAharon: int.tryParse(
              newState['kilometer_test_aharon'] ?? '',
            ),
            fetchKilometerWhenMissing: false,
          );
          final missingKeys = _checkMissingKeys(newState);
          final readyToPublish = formVal.isValid && missingKeys.isEmpty;
          newState['session_status'] =
              readyToPublish ? 'ready_for_images' : 'collecting_details';
          newState['last_requested_fields'] = jsonEncode(missingKeys);

          final carTitle = [
            newState['maker'] ?? '',
            newState['model'] ?? '',
            newState['year'] ?? ''
          ].where((s) => s.isNotEmpty).join(' ');

          final reply = readyToPublish
              ? 'שחזרתי את פרטי הרכב ($carTitle, רישוי $savedLicense). כל הפרטים מלאים! אנא שלח תמונות של הרכב כדי להתחיל בפרסום.'
              : composeHebrewReply(
                  state: newState,
                  formVal: formVal,
                  missingKeys: missingKeys,
                );

          final chatHistory = _parseChatHistory(newState['chat_history']);
          chatHistory.add({
            'role': 'assistant',
            'text': reply,
            'timestamp': '${DateTime.now().millisecondsSinceEpoch}',
          });
          newState['chat_history'] = jsonEncode(chatHistory);

          await saveSenderState(senderKey, newState);
          await _sendReply(senderKey, reply);
          return newState;
        } else {
          await _sendReply(
            senderKey,
            'לא נמצאו פרטי רכב שמורים מהעבר. שלח מספר רישוי (7 או 8 ספרות) כעת, ומעכשיו הפרטים יישמרו אוטומטית בכל שלב!',
          );
          return currentState;
        }
      }

      await _sendReply(
        senderKey,
        'כדי להתחיל פרסום רכב, שלח תחילה מספר רישוי ישראלי בעל 7 או 8 ספרות.',
      );
      return currentState;
    }

    if (!startsNewSession &&
        currentState['license_not_found_gov'] == 'true' &&
        currentState['gov_not_found_acknowledged'] != 'true' &&
        _isAffirmativeResponse(trimmedText)) {
      final updatedState = Map<String, String>.from(currentState);
      updatedState['gov_not_found_acknowledged'] = 'true';
      updatedState['manual_entry_confirmed'] = 'true';

      final missingKeys = _checkMissingKeys(updatedState);
      updatedState['last_requested_fields'] = jsonEncode(missingKeys);

      final reply = StringBuffer()
        ..writeln('מצוין, נמשיך בהזנה ידנית של פרטי הרכב.\n')
        ..writeln('אנא הזן את כל פרטי הרכב הנדרשים:');
      for (final key in missingKeys) {
        reply.writeln('• ${_hebrewFieldLabel(key)}');
      }
      reply.writeln(
        '\nשלח את הערכים עם שם השדה, או כרשימה לפי הסדר למעלה. אפשר לשלוח ערך אחד או כמה ערכים יחד.',
      );

      final replyStr = reply.toString().trim();
      final chatHistory = _parseChatHistory(updatedState['chat_history']);
      final eventTimestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch;
      chatHistory.add({
        'role': 'user',
        'text': trimmedText,
        'timestamp': '$eventTimestamp',
      });
      chatHistory.add({
        'role': 'assistant',
        'text': replyStr,
        'timestamp': '${DateTime.now().millisecondsSinceEpoch}',
      });
      updatedState['chat_history'] = jsonEncode(chatHistory);
      await saveSenderState(senderKey, updatedState);
      await _sendReply(senderKey, replyStr);
      return updatedState;
    }

    if (!startsNewSession &&
        _shouldHandleAsCommand(trimmedText, currentState)) {
      return await _handleCommandText(
        trimmedText: trimmedText,
        senderKey: senderKey,
        senderName: senderName,
        currentState: currentState,
      );
    }

    final eventTimestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch;
    final Map<String, String> newState;
    if (startsNewSession) {
      _stopAutomation();
      final previousSaved = await loadLastVehicle(senderKey);
      final previousLicense =
          (previousSaved['license_plate'] ?? previousSaved['license'] ?? '')
              .trim();
      if (previousLicense.isNotEmpty && previousLicense != incomingLicense) {
        await clearLastVehicle(senderKey);
      }
      newState = <String, String>{
        'license_plate': incomingLicense,
        'session_id': '$incomingLicense-$eventTimestamp',
        'session_status': 'collecting_details',
        'session_start_timestamp': '$eventTimestamp',
        'chat_history': jsonEncode([]),
        'gov_vehicle_lookup_status': 'pending',
        'gov_kilometer_lookup_status': 'pending',
      };
      _attachSenderMetadata(newState, senderKey, senderName);
      await saveSenderState(senderKey, newState);
      await _sendStatus(
        senderKey,
        'מחפש את פרטי הרכב ב-gov.il עבור מספר רישוי $incomingLicense...',
      );

      await _enrichNewSessionFromGovernment(
        state: newState,
        senderKey: senderKey,
        license: incomingLicense,
      );
    } else {
      newState = Map<String, String>.from(currentState);
      _attachSenderMetadata(newState, senderKey, senderName);
    }

    final chatHistory = _parseChatHistory(newState['chat_history']);
    chatHistory.add({
      'role': 'user',
      'text': trimmedText,
      'timestamp': '$eventTimestamp',
    });

    // Deterministic extraction runs first. Positional answers are interpreted
    // against the exact ordered list sent to the user on the previous turn.
    final requestedFields = _requestedFieldsForTurn(newState);
    final extracted = _extractPositionalFields(trimmedText, requestedFields);
    extracted.remove('license_plate');
    extracted.remove('license');
    _mergeNonEmpty(newState, extracted);

    // The LLM reviews every conversational turn when configured.
    String? aiAssistantReply;
    if (await _hasAiApiKey()) {
      final lastVehicle = await loadLastVehicle(senderKey);
      final aiResult = await askAiModelToProcessTurn(
        trimmedText,
        newState,
        missingFields: _checkMissingKeys(newState),
        chatHistory: chatHistory,
        lastSavedVehicle: lastVehicle,
        hasActiveSession: true,
      );
      _mergeNonEmpty(extracted, aiResult.extractedFields);
      _mergeNonEmpty(newState, aiResult.extractedFields);
      aiAssistantReply = aiResult.assistantReply;
    }

    _normalizeStateFields(newState);

    if (extracted.isNotEmpty) {
      newState['gov_not_found_acknowledged'] = 'true';
      newState['manual_entry_confirmed'] = 'true';
    }

    // Yad2 currently defaults this optional field to "טוב" as well.
    if ((newState['vehicle_condition'] == null ||
            newState['vehicle_condition']!.isEmpty) &&
        (newState['vehicleCondition'] == null ||
            newState['vehicleCondition']!.isEmpty)) {
      newState['vehicle_condition'] = 'טוב';
    }

    final kilometerTestAharon = int.tryParse(
      newState['kilometer_test_aharon'] ?? '',
    );

    final formVal = await validateFormFields(
      newState,
      kilometerTestAharon: kilometerTestAharon,
      fetchKilometerWhenMissing: false,
    );

    final missingKeys = _checkMissingKeys(newState);
    final missingValidationKeys = missingKeys
        .map((key) => key == 'license_plate' ? 'license' : key)
        .toSet();
    final actualFieldErrors = formVal.fieldErrors.entries
        .where((entry) => !missingValidationKeys.contains(entry.key))
        .map((entry) => entry.value)
        .toList();
    final hasValidationErrors = actualFieldErrors.isNotEmpty;

    final invalidKeys = formVal.fieldErrors.keys
        .map((k) => k == 'license' ? 'license_plate' : k)
        .toList();
    final allFieldsNeedingAttention = <String>[
      ...invalidKeys,
      ...missingKeys.where((k) => !invalidKeys.contains(k)),
    ];

    final readyToPublish = formVal.isValid && missingKeys.isEmpty;
    final rawImgs = newState['image_paths'] ?? newState['KEY_IMAGE_PATHS'];
    bool hasImages = false;
    if (rawImgs != null && rawImgs.isNotEmpty) {
      try {
        hasImages = (jsonDecode(rawImgs) as List).isNotEmpty;
      } catch (_) {}
    }
    if (readyToPublish && hasImages) {
      newState['session_status'] = 'ready_to_publish';
      newState['ready_to_publish'] = 'true';
    } else {
      newState['session_status'] =
          readyToPublish ? 'ready_for_images' : 'collecting_details';
    }
    newState['last_requested_fields'] = jsonEncode(allFieldsNeedingAttention);
    newState['last_validation_timestamp'] =
        '${DateTime.now().millisecondsSinceEpoch}';

    final isGovNotFound = newState['license_not_found_gov'] == 'true';
    final bool isEvasiveAiReply = aiAssistantReply != null &&
        (aiAssistantReply.contains('מתחיל לאתר') ||
            aiAssistantReply.contains('אאתר') ||
            aiAssistantReply.contains('בודק במאגר') ||
            aiAssistantReply.contains('קיבלתי את מספר הרישוי'));

    final reply = (!hasValidationErrors &&
            !startsNewSession &&
            !isGovNotFound &&
            !isEvasiveAiReply &&
            aiAssistantReply != null &&
            aiAssistantReply.trim().isNotEmpty)
        ? aiAssistantReply
        : composeHebrewReply(
            state: newState,
            formVal: formVal,
            missingKeys: missingKeys,
            isIrrelevantInput:
                !startsNewSession &&
                extracted.isEmpty &&
                allFieldsNeedingAttention.isNotEmpty,
            isFirstTurn: startsNewSession,
          );

    if (reply.isNotEmpty) {
      chatHistory.add({
        'role': 'assistant',
        'text': reply,
        'timestamp': '${DateTime.now().millisecondsSinceEpoch}',
      });
    }

    newState['chat_history'] = jsonEncode(
      chatHistory.length > 40
          ? chatHistory.sublist(chatHistory.length - 40)
          : chatHistory,
    );

    await saveSenderState(senderKey, newState);

    if (reply.isNotEmpty && senderKey.isNotEmpty) {
      await _sendReply(senderKey, reply);
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

    _imageDebounceTimers[senderKey]?.cancel();
    _imageDebounceTimers.remove(senderKey);

    if (_isCancelCommand(trimmedText, allowNumericShortcut: true)) {
      _stopAutomation();
      await clearSenderState(senderKey);
      await _sendReply(senderKey, 'תהליך הפרסום בוטל והסשן נסגר.');
      return {};
    }

    final isContinueCommand =
        lower == 'המשך מהפרסום הנוכחי' ||
        lower == 'המשך' ||
        lower.contains('המשך מהפרסום') ||
        lower == 'continue';

    if (isContinueCommand) {
      currentState['continue_from_current'] = 'true';
      return _publishIfReady(
        senderKey: senderKey,
        state: currentState,
        startMessage: 'ממשיך את האוטומציה מהפרסום הנוכחי...',
      );
    }

    if (lower == '0' ||
        lower == 'פרסום' ||
        lower == 'פרסם' ||
        lower == 'publish') {
      return _publishIfReady(
        senderKey: senderKey,
        state: currentState,
        startMessage: 'מתחיל פרסום ביד2 עכשיו.',
      );
    }

    final countMatch = RegExp(r'^(\d{1,2})').firstMatch(trimmedText);
    if (countMatch != null) {
      final expectedCount = int.tryParse(countMatch.group(1)!) ?? 0;

      if (expectedCount > 8) {
        await _sendReply(
          senderKey,
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
        return _publishIfReady(
          senderKey: senderKey,
          state: currentState,
          startMessage: 'מתחיל פרסום ביד2 עכשיו בלי תמונות.',
        );
      }

      // Save state and WAIT for incoming WhatsApp images (Do NOT grab old images from disk!)
      currentState['session_status'] = 'waiting_for_images';
      await saveSenderState(senderKey, currentState);

      await _sendReply(senderKey, 'ממתין להעלאת $expectedCount תמונות');
      return currentState;
    }

    return currentState;
  }

  Future<Map<String, String>?> _publishIfReady({
    required String senderKey,
    required Map<String, String> state,
    required String startMessage,
  }) async {
    final missingKeys = _checkMissingKeys(state);
    final formVal = await validateFormFields(
      state,
      kilometerTestAharon: int.tryParse(state['kilometer_test_aharon'] ?? ''),
      fetchKilometerWhenMissing: false,
    );

    if (missingKeys.isNotEmpty || !formVal.isValid) {
      state['session_status'] = 'collecting_details';
      state['last_requested_fields'] = jsonEncode(missingKeys);
      await saveSenderState(senderKey, state);
      await _sendReply(
        senderKey,
        composeHebrewReply(
          state: state,
          formVal: formVal,
          missingKeys: missingKeys,
        ),
      );
      return state;
    }
    final expectedImages =
        int.tryParse(
          state['image_expected_count'] ??
              state['KEY_IMAGE_EXPECTED_COUNT'] ??
              '0',
        ) ??
        0;

    List<String> currentImagePaths = [];
    final rawPaths = state['image_paths'] ?? state['KEY_IMAGE_PATHS'];
    if (rawPaths != null && rawPaths.isNotEmpty) {
      try {
        currentImagePaths = List<String>.from(jsonDecode(rawPaths));
      } catch (_) {}
    }

    if (expectedImages == 0) {
      if (currentImagePaths.isNotEmpty) {
        final actualCount = currentImagePaths.length;
        state['image_paths'] = jsonEncode(currentImagePaths);
        state['KEY_IMAGE_PATHS'] = jsonEncode(currentImagePaths);
        state['image_expected_count'] = '$actualCount';
        state['KEY_IMAGE_EXPECTED_COUNT'] = '$actualCount';
        state['image_received_count'] = '$actualCount';
        state['KEY_IMAGE_RECEIVED_COUNT'] = '$actualCount';
        await saveSenderState(senderKey, state);
      } else {
        state['image_paths'] = jsonEncode([]);
        state['KEY_IMAGE_PATHS'] = jsonEncode([]);
        state['image_received_count'] = '0';
        state['KEY_IMAGE_RECEIVED_COUNT'] = '0';
        state['image_expected_count'] = '0';
        state['KEY_IMAGE_EXPECTED_COUNT'] = '0';
        await saveSenderState(senderKey, state);
      }
    } else {
      if (currentImagePaths.length < expectedImages) {
        state['session_status'] = 'waiting_for_images';
        await saveSenderState(senderKey, state);
        await _sendReply(
          senderKey,
          'עדיין חסרות ${expectedImages - currentImagePaths.length} תמונות. '
          'התקבלו ${currentImagePaths.length} מתוך $expectedImages. '
          'חובה להעלות בדיוק $expectedImages תמונות כדי להתחיל בפרסום.',
        );
        return state;
      }

      if (currentImagePaths.length > expectedImages) {
        currentImagePaths = currentImagePaths.sublist(
          currentImagePaths.length - expectedImages,
        );
        state['image_paths'] = jsonEncode(currentImagePaths);
        state['KEY_IMAGE_PATHS'] = jsonEncode(currentImagePaths);
        state['image_received_count'] = '$expectedImages';
        state['KEY_IMAGE_RECEIVED_COUNT'] = '$expectedImages';
        await saveSenderState(senderKey, state);
      }
    }

    state['auto_publish_started'] = 'true';
    state['KEY_AUTO_PUBLISH_STARTED'] = 'true';
    state['auto_publish_running'] = 'true';
    state['session_status'] = 'publishing';
    state['publication_started_timestamp'] =
        '${DateTime.now().millisecondsSinceEpoch}';
    await saveSenderState(senderKey, state);
    await _sendReply(senderKey, startMessage);

    final launched = await _launchAutoPublish(state);
    if (!launched) {
      state['auto_publish_started'] = 'false';
      state['KEY_AUTO_PUBLISH_STARTED'] = 'false';
      state['auto_publish_running'] = 'false';
      state['session_status'] = 'ready_for_images';
      await saveSenderState(senderKey, state);
      await _sendReply(
        senderKey,
        'לא הצלחתי להפעיל את פרסום יד2. נסה שוב בעוד רגע או שלח "ביטול".',
      );
    }
    return state;
  }

  Future<void> _enrichNewSessionFromGovernment({
    required Map<String, String> state,
    required String senderKey,
    required String license,
  }) async {
    Map<String, dynamic>? vehicleData;
    try {
      final fetcher = vehicleDataFetcher ?? VehicleDataService.fetchVehicleData;
      vehicleData = await fetcher(
        license,
      ).timeout(const Duration(seconds: 20));
      if (vehicleData == null) {
        state['license_not_found_gov'] = 'true';
        state['gov_vehicle_lookup_status'] = 'not_found';
      } else {
        state['license_not_found_gov'] = 'false';
        state['gov_vehicle_lookup_status'] = 'succeeded';
        _putIfEmpty(state, 'maker', vehicleData['maker']);
        _putIfEmpty(state, 'model', vehicleData['model']);
        _putIfEmpty(state, 'year', vehicleData['year']);
        _putIfEmpty(state, 'fuel_type', vehicleData['fuelType']);
        _putIfEmpty(
          state,
          'gear_type',
          vehicleData['gear_type'] ??
              vehicleData['gear'] ??
              'הילוכים אוטומטיים',
        );
        _putIfEmpty(
          state,
          'current_ownership',
          _normalizeOwnership(vehicleData['ownership']?.toString()),
        );
        _putIfEmpty(
          state,
          'month',
          vehicleData['registrationMonth'] ?? vehicleData['month'],
        );

        final testExpiry = vehicleData['testExpiry']?.toString() ?? '';
        final testParts = testExpiry.split(',');
        if (testParts.length == 2) {
          _putIfEmpty(state, 'test_month', testParts[0]);
          _putIfEmpty(state, 'test_year', testParts[1]);
        }

        final rawColor = vehicleData['color']?.toString().trim() ?? '';
        if (rawColor.isNotEmpty) {
          state['gov_raw_color'] = rawColor;
          final mappedColor = await matchColorToYad2Value(rawColor);
          state['color'] = mappedColor;
          state['color_mapping_source'] =
              rawColor == mappedColor ? 'exact' : 'llm_or_fallback';
        }

        if (vehicleData['lastTestDate'] != null &&
            vehicleData['lastTestDate'].toString().isNotEmpty) {
          state['gov_last_test_date'] = vehicleData['lastTestDate'].toString();
        }
        if (vehicleData['tokef_dt'] != null &&
            vehicleData['tokef_dt'].toString().isNotEmpty) {
          state['gov_tokef_dt'] = vehicleData['tokef_dt'].toString();
        }
        if (vehicleData['moed_aliya_lakvish'] != null &&
            vehicleData['moed_aliya_lakvish'].toString().isNotEmpty) {
          state['gov_moed_aliya_lakvish'] =
              vehicleData['moed_aliya_lakvish'].toString();
        }
      }
    } catch (error) {
      state['license_not_found_gov'] = 'true';
      state['gov_vehicle_lookup_status'] = 'error';
      debugPrint('[WhatsAppValidationService] Vehicle lookup failed: $error');
    }

    await saveSenderState(senderKey, state);

    try {
      final kmFetcher = kilometerHistoryFetcher ?? fetchKilometerTestAharon;
      final kilometer = await kmFetcher(
        license,
      ).timeout(const Duration(seconds: 20));
      if (kilometer == null) {
        state['gov_kilometer_lookup_status'] = 'not_found';
        // In case where there is no test data for the vehicle returned from the API,
        // do not populate state['km']. It remains missing and the user will be asked
        // to fill this information as a required field.
      } else {
        state['kilometer_test_aharon'] = '$kilometer';
        state['gov_kilometer_lookup_status'] = 'succeeded';

        // When test data exists, do not require user to enter it. Calculate estimated km:
        final calculatedKm = calculateEstimatedKm(
          rawKm: kilometer,
          lastTestDate: vehicleData?['lastTestDate'] ?? state['gov_last_test_date'],
          tokefDt: vehicleData?['tokef_dt'] ?? state['gov_tokef_dt'],
          testMonth: state['test_month'],
          testYear: state['test_year'],
          moedAliya: vehicleData?['moed_aliya_lakvish'] ?? state['gov_moed_aliya_lakvish'],
          shnatYitzur: vehicleData?['year'] ?? state['year'],
          registrationMonth: state['month'],
        );
        state['km'] = '$calculatedKm';
      }
    } catch (error) {
      state['gov_kilometer_lookup_status'] = 'error';
      debugPrint('[WhatsAppValidationService] Kilometer lookup failed: $error');
    }
    state['gov_lookup_completed_timestamp'] =
        '${DateTime.now().millisecondsSinceEpoch}';
    await saveSenderState(senderKey, state);
  }

  bool _hasSession(Map<String, String> state) =>
      (state['license_plate'] ?? state['license'] ?? '').trim().isNotEmpty;

  bool _isAutomationRunning(Map<String, String> state) =>
      state['auto_publish_started'] == 'true' ||
      state['KEY_AUTO_PUBLISH_STARTED'] == 'true' ||
      state['auto_publish_running'] == 'true' ||
      state['session_status'] == 'publishing';

  bool _isCancelCommand(String text, {required bool allowNumericShortcut}) {
    final normalized =
        text
            .trim()
            .toLowerCase()
            .replaceAll(RegExp(r'[^\w\u0590-\u05FF]+'), ' ')
            .trim();
    if (allowNumericShortcut && normalized == '9') return true;
    return normalized == 'ביטול' ||
        normalized == 'לבטל' ||
        normalized == 'בטל' ||
        normalized == 'cancel' ||
        normalized == 'stop' ||
        normalized == 'בבקשה לבטל' ||
        normalized == 'אנא לבטל';
  }

  bool _isAffirmativeResponse(String text) {
    final normalized = text
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\u0590-\u05FF]+'), ' ')
        .trim();
    return normalized == 'כן' ||
        normalized == 'כן תמשיך' ||
        normalized == 'תמשיך' ||
        normalized == 'להמשיך' ||
        normalized == 'המשך' ||
        normalized == 'המשך בכל זאת' ||
        normalized == 'להמשיך בכל זאת' ||
        normalized == 'בטח' ||
        normalized == 'בסדר' ||
        normalized == 'סבבה' ||
        normalized == 'אוקי' ||
        normalized == 'אוקיי' ||
        normalized == 'ok' ||
        normalized == 'yes' ||
        normalized == 'proceed' ||
        normalized == 'continue';
  }

  bool _isRepublishCommand(String text) {
    final normalized = text
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\u0590-\u05FF]+'), ' ')
        .trim();
    if (normalized == 'פרסם שוב' ||
        normalized == 'שוב' ||
        normalized == 'לפרסם שוב' ||
        normalized == 'פרסם מחדש' ||
        normalized == 'תפרסם שוב' ||
        normalized == 'המשך' ||
        normalized == 'להמשיך' ||
        normalized == 'שחזר' ||
        normalized == 'לשחזר' ||
        normalized == 'republish' ||
        normalized == 'republish car' ||
        normalized == 'publish again' ||
        normalized == 'resume' ||
        normalized == 'continue') {
      return true;
    }

    if (normalized.contains('פרסום קודם') ||
        normalized.contains('פרסום אחרון') ||
        normalized.contains('הפרסום הקודם') ||
        normalized.contains('הפרסום האחרון') ||
        normalized.contains('לחזור על הפרסום') ||
        normalized.contains('חזור על הפרסום') ||
        normalized.contains('לחזור לפרסום') ||
        normalized.contains('חזור לפרסום') ||
        normalized.contains('לחזור להמשיך') ||
        normalized.contains('רכב קודם') ||
        normalized.contains('רכב אחרון') ||
        normalized.contains('הרכב הקודם') ||
        normalized.contains('הרכב האחרון') ||
        normalized.contains('גישה לפרסום') ||
        normalized.contains('נתונים קודמים') ||
        normalized.contains('נתונים אחרונים') ||
        normalized.contains('פרסם שוב') ||
        normalized.contains('לפרסם שוב') ||
        normalized.contains('להמשיך פרסום') ||
        normalized.contains('להמשיך את הפרסום') ||
        normalized.contains('המשך פרסום') ||
        normalized.contains('המשך את הפרסום') ||
        normalized.contains('להמשיך מאיפה') ||
        normalized.contains('להמשיך מהיכן') ||
        normalized.contains('לחזור מאיפה') ||
        normalized.contains('לחזור מהיכן') ||
        normalized.contains('שחזר פרסום') ||
        normalized.contains('שחזור פרסום') ||
        normalized.contains('שחזר נתונים') ||
        normalized.contains('שחזור נתונים') ||
        normalized.contains('פעם קודמת') ||
        normalized.contains('בפעם הקודמת') ||
        normalized.contains('מהפעם הקודמת') ||
        normalized.contains('מהיכן שהפסקתי') ||
        normalized.contains('מאיפה שהפסקתי') ||
        normalized.contains('איפה שהפסקתי') ||
        normalized.contains('היכן שהפסקתי') ||
        normalized.contains('מהיכן שעצרתי') ||
        normalized.contains('מאיפה שעצרתי') ||
        normalized.contains('איפה שעצרתי') ||
        normalized.contains('היכן שעצרתי') ||
        normalized.contains('מהיכן שעצרנו') ||
        normalized.contains('איפה שעצרנו') ||
        normalized.contains('היכן שעצרנו') ||
        normalized.contains('מהיכן שהפסקנו') ||
        normalized.contains('איפה שהפסקנו') ||
        normalized.contains('left off') ||
        normalized.contains('where i stopped') ||
        normalized.contains('previous car')) {
      return true;
    }

    final hasResumeAction = normalized.contains('להמשיך') ||
        normalized.contains('המשך') ||
        normalized.contains('לחזור') ||
        normalized.contains('חזור') ||
        normalized.contains('שחזר') ||
        normalized.contains('לשחזר');

    final hasPreviousReference = normalized.contains('הפסקתי') ||
        normalized.contains('עצרתי') ||
        normalized.contains('הפסקנו') ||
        normalized.contains('עצרנו') ||
        normalized.contains('קודם') ||
        normalized.contains('קודמת') ||
        normalized.contains('אחרון') ||
        normalized.contains('אחרונה');

    if (hasResumeAction && hasPreviousReference) {
      return true;
    }

    return false;
  }

  bool _shouldHandleAsCommand(String text, Map<String, String> state) {
    final normalized = text.trim().toLowerCase();
    if (isSystemNotification(normalized) ||
        _isCancelCommand(text, allowNumericShortcut: true)) {
      return true;
    }
    if (normalized == 'פרסום' ||
        normalized == 'פרסם' ||
        normalized == 'publish' ||
        normalized == 'המשך' ||
        normalized == 'המשך מהפרסום הנוכחי' ||
        normalized.contains('המשך מהפרסום') ||
        normalized == 'continue') {
      return true;
    }

    final isImageCount = RegExp(
      r'^\d{1,2}(?:\s*(?:תמונה|תמונות|photos?|images?))?$',
    ).hasMatch(normalized);
    if (!isImageCount) return false;
    return _checkMissingKeys(state).isEmpty ||
        state['session_status'] == 'ready_for_images' ||
        state['session_status'] == 'waiting_for_images';
  }

  List<String> _requestedFieldsForTurn(Map<String, String> state) {
    final raw = state['last_requested_fields'];
    if (raw != null && raw.isNotEmpty) {
      try {
        final requested = List<String>.from(jsonDecode(raw));
        if (requested.isNotEmpty) return requested;
      } catch (_) {}
    }
    return _checkMissingKeys(state);
  }

  void _attachSenderMetadata(
    Map<String, String> state,
    String senderKey,
    String? senderName,
  ) {
    if (senderKey.isNotEmpty) {
      state['whatsapp_sender_key'] = senderKey;
      state['whatsapp_origin'] = 'true';
    }
    if (senderName != null && senderName.trim().isNotEmpty) {
      state['whatsapp_sender_name'] = senderName.trim();
    }
  }

  void _mergeNonEmpty(Map<String, String> target, Map<String, String> source) {
    source.forEach((key, value) {
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) target[key] = trimmed;
    });
  }

  void _putIfEmpty(Map<String, String> state, String key, Object? value) {
    if ((state[key] ?? '').trim().isNotEmpty) return;
    final text = value?.toString().trim() ?? '';
    if (text.isNotEmpty) state[key] = text;
  }

  void _normalizeStateFields(Map<String, String> state) {
    for (final key in ['license_plate', 'license', 'km', 'price']) {
      final value = state[key];
      if (value != null && value.isNotEmpty) state[key] = _digitsOnly(value);
    }
    final hand = state['hand'];
    if (hand != null && hand.isNotEmpty) {
      final parsed = _parseHand(hand);
      if (parsed != null) state['hand'] = '$parsed';
    }
    for (final key in ['current_ownership', 'previous_ownership']) {
      final normalized = _normalizeOwnership(state[key]);
      if (normalized != null) state[key] = normalized;
    }
  }

  String? _normalizeOwnership(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    if (text.contains('פרטי')) return 'פרטית';
    if (text.contains('חברה')) return 'חברה';
    if (text.contains('ליסינג')) return 'ליסינג';
    if (text.contains('השכרה')) return 'השכרה';
    if (text.contains('מונית')) return 'מונית';
    return text;
  }

  /// Dispatches a reply to the originating channel:
  /// - If [senderKey] is a P2P Remote Control sender (e.g. 'p2p_remote_user'),
  ///   routes directly to the registered remote chat receiver (WebRTC chat).
  /// - Otherwise routes to WhatsApp via WhatsAppMessageBridgeService.
  static Future<bool> dispatchReplyToSender({
    required String senderKey,
    required String message,
  }) async {
    return WhatsAppTextValidationService.instance._sendReply(senderKey, message);
  }

  Future<bool> _sendReply(String senderKey, String message) {
    if (senderKey.isEmpty || message.trim().isEmpty) {
      return Future<bool>.value(false);
    }
    WhatsAppReplySender? customSender = _customReplySenders[senderKey];
    if (customSender == null) {
      for (final entry in _customReplySenders.entries) {
        if (senderKey.startsWith(entry.key) || entry.key.startsWith(senderKey)) {
          customSender = entry.value;
          break;
        }
      }
    }
    if (customSender == null && senderKey.startsWith('p2p_')) {
      for (final entry in _customReplySenders.entries) {
        if (entry.key.startsWith('p2p_')) {
          customSender = entry.value;
          break;
        }
      }
    }

    final sender = customSender ?? replySender;
    if (sender == null) {
      debugPrint('[WhatsAppValidation] No reply sender registered for $senderKey');
      return Future<bool>.value(false);
    }
    final trimmed = message.trim();
    final formatted = (trimmed.startsWith('🤖') || trimmed.startsWith('⚠️'))
        ? trimmed
        : '🤖 פירסומוטו: $trimmed';
    return sender(
      senderKey: senderKey,
      message: formatted,
    );
  }

  Future<bool> _sendStatus(String senderKey, String message) =>
      _sendReply(senderKey, 'עדכון: ${message.trim()}');

  Future<bool> _launchAutoPublish(Map<String, String> state) async {
    for (final launcher in _customAutoPublishLaunchers) {
      try {
        final handled = await launcher(state);
        if (handled) {
          debugPrint('[WhatsAppValidation] Auto-publish handled by custom launcher');
          return true;
        }
      } catch (e) {
        debugPrint('[WhatsAppValidation] customAutoPublishLauncher error: $e');
      }
    }
    if (autoPublishLauncher != null) {
      return await autoPublishLauncher!(state);
    }
    // Default in-app launcher for internal P2P chat: opens Yad2Screen on main app
    return await P2PAutoPublishLauncher.launch(state);
  }

  void stopAutomation() => _stopAutomation();

  void _stopAutomation() {
    final stopper =
        automationStopper ?? Yad2AccessibilityAutomationService.stopAll;
    stopper();
  }

  /// Handle incoming image message from WhatsApp
  Future<Map<String, String>?> handleIncomingImage({
    required String imageFilePath,
    required String senderKey,
    String? senderName,
    int? timestamp,
  }) {
    return _runForSender(
      senderKey,
      () => _handleIncomingImageUnlocked(
        imageFilePath: imageFilePath,
        senderKey: senderKey,
        senderName: senderName,
        timestamp: timestamp,
      ),
    );
  }

  Future<Map<String, String>?> _handleIncomingImageUnlocked({
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

    final currentState = await loadSenderState(senderKey);

    // Filter out historical messages based on session start timestamp (ignore only if > 5 minutes older)
    final sessionStartStr = currentState['session_start_timestamp'];
    if (sessionStartStr != null && timestamp != null) {
      final sessionStart = int.tryParse(sessionStartStr) ?? 0;
      if (timestamp < sessionStart - 300000) {
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
    final bool isDuplicate =
        existingNames.contains(fileName) || existingPaths.contains(cleanPath);

    const maxAllowedImages = 8;
    if (!isDuplicate && existingPaths.length < maxAllowedImages) {
      existingPaths.add(cleanPath);
    }

    List<String> finalPaths = existingPaths;
    if (finalPaths.length > maxAllowedImages) {
      finalPaths = finalPaths.sublist(finalPaths.length - maxAllowedImages);
    }

    final receivedCount = finalPaths.length;
    final targetExpected =
        (expectedCount > receivedCount) ? expectedCount : receivedCount;

    currentState['image_paths'] = jsonEncode(finalPaths);
    currentState['KEY_IMAGE_PATHS'] = jsonEncode(finalPaths);
    currentState['image_received_count'] = '$receivedCount';
    currentState['KEY_IMAGE_RECEIVED_COUNT'] = '$receivedCount';
    currentState['image_expected_count'] = '$targetExpected';
    currentState['KEY_IMAGE_EXPECTED_COUNT'] = '$targetExpected';

    // Verify whether vehicle details actually exist and are complete
    final initialPlate = currentState['license_plate'] ??
        currentState['license'] ??
        currentState['KEY_LICENSE_PLATE'];
    final initialMissing = _checkMissingKeys(currentState);
    final initialFormVal = await validateFormFields(
      currentState,
      kilometerTestAharon:
          int.tryParse(currentState['kilometer_test_aharon'] ?? ''),
      fetchKilometerWhenMissing: false,
    );
    final initialFullyReady =
        (initialPlate != null && initialPlate.trim().isNotEmpty) &&
        initialFormVal.isValid &&
        initialMissing.isEmpty;

    if (initialFullyReady) {
      currentState['session_status'] = 'ready_to_publish';
      currentState['ready_to_publish'] = 'true';
    } else if (initialPlate != null && initialPlate.trim().isNotEmpty) {
      currentState['session_status'] = 'collecting_details';
      currentState['ready_to_publish'] = 'false';
    } else {
      currentState['session_status'] = 'awaiting_license';
      currentState['ready_to_publish'] = 'false';
    }
    await saveSenderState(senderKey, currentState);

    // Schedule debounced batch confirmation response so all images in a burst
    // are collected before sending a single consolidated confirmation reply.
    _imageDebounceTimers[senderKey]?.cancel();
    _imageDebounceTimers[senderKey] = Timer(const Duration(milliseconds: 1400), () async {
      _imageDebounceTimers.remove(senderKey);
      final latestState = await loadSenderState(senderKey);
      List<String> latestPaths = [];
      final raw = latestState['image_paths'] ?? latestState['KEY_IMAGE_PATHS'];
      if (raw != null && raw.isNotEmpty) {
        try {
          latestPaths = List<String>.from(jsonDecode(raw));
        } catch (_) {}
      }
      final count = latestPaths.length;
      if (count == 0) return;

      latestState['image_received_count'] = '$count';
      latestState['image_expected_count'] = '$count';
      latestState['KEY_IMAGE_EXPECTED_COUNT'] = '$count';

      final latestPlate = latestState['license_plate'] ??
          latestState['license'] ??
          latestState['KEY_LICENSE_PLATE'];
      final latestMissing = _checkMissingKeys(latestState);
      final latestFormVal = await validateFormFields(
        latestState,
        kilometerTestAharon:
            int.tryParse(latestState['kilometer_test_aharon'] ?? ''),
        fetchKilometerWhenMissing: false,
      );
      final isFullyReady =
          (latestPlate != null && latestPlate.trim().isNotEmpty) &&
          latestFormVal.isValid &&
          latestMissing.isEmpty;

      final countHeader = (count == 1)
          ? 'התקבלה תמונה אחת בהצלחה!'
          : 'התקבלו $count תמונות בהצלחה!';

      final String replyMessage;
      if (isFullyReady) {
        latestState['session_status'] = 'ready_to_publish';
        latestState['ready_to_publish'] = 'true';
        replyMessage =
            '$countHeader\n'
            'כל הפרטים והתמונות מוכנים לפרסום ביד2.\n'
            'לפרסום שלח 0\n'
            'לביטול השב ביטול';
      } else if (latestPlate == null || latestPlate.trim().isEmpty) {
        latestState['session_status'] = 'awaiting_license';
        latestState['ready_to_publish'] = 'false';
        replyMessage =
            '$countHeader\n'
            'כדי להתחיל בפרסום הרכב, אנא שלח מספר רישוי (7 או 8 ספרות).';
      } else {
        latestState['session_status'] = 'collecting_details';
        latestState['ready_to_publish'] = 'false';
        latestState['last_requested_fields'] = jsonEncode(latestMissing);
        final detailsPrompt = composeHebrewReply(
          state: latestState,
          formVal: latestFormVal,
          missingKeys: latestMissing,
        );
        replyMessage = '$countHeader\n$detailsPrompt';
      }

      final chatHistory = _parseChatHistory(latestState['chat_history']);
      chatHistory.add({
        'role': 'assistant',
        'text': replyMessage,
        'timestamp': '${DateTime.now().millisecondsSinceEpoch}',
      });
      latestState['chat_history'] = jsonEncode(
        chatHistory.length > 40
            ? chatHistory.sublist(chatHistory.length - 40)
            : chatHistory,
      );

      await saveSenderState(senderKey, latestState);
      await _sendReply(senderKey, replyMessage);
    });

    return currentState;
  }

  bool isSystemNotification(String text) {
    final norm = text.trim().toLowerCase();
    return norm.startsWith('🤖 פירסומוטו:') ||
        norm.startsWith('עדכון:') ||
        norm.startsWith('נקלטה תמונה') ||
        norm.startsWith('התקבלו') ||
        norm.startsWith('ממתין להעלאת') ||
        norm.startsWith('מתחיל פרסום') ||
        norm.startsWith('ממשיך את האוטומציה') ||
        norm.startsWith('הפרסום בוטל') ||
        norm.startsWith('תהליך') ||
        norm.startsWith('האוטומציה') ||
        norm.startsWith('פרטי הרכב') ||
        norm.startsWith('מצאתי את הרכב') ||
        norm.startsWith('מספר הרישוי לא נמצא') ||
        norm.startsWith('ניתן להוסיף פרטים') ||
        norm.startsWith('לא נמצאו') ||
        norm.startsWith('לא זיהיתי') ||
        norm.startsWith('נמצאו שגיאות') ||
        norm.startsWith('חסרים עדיין');
  }

  String composeHebrewReply({
    required Map<String, String> state,
    required FormValidationResult formVal,
    required List<String> missingKeys,
    bool isIrrelevantInput = false,
    bool isFirstTurn = false,
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

    final missingValidationKeys =
        missingKeys
            .map((key) => key == 'license_plate' ? 'license' : key)
            .toSet();
    final invalidFieldErrors =
        formVal.fieldErrors.entries
            .where((entry) => !missingValidationKeys.contains(entry.key))
            .map((entry) => entry.value)
            .toSet()
            .toList();
    final hasErrors = invalidFieldErrors.isNotEmpty;
    final hasMissing = missingKeys.isNotEmpty;

    final isGovNotFound = state['license_not_found_gov'] == 'true';

    if (hasErrors || hasMissing) {
      if (isGovNotFound && state['gov_not_found_acknowledged'] != 'true') {
        final plate = state['license_plate'] ?? state['license'] ?? '';
        replyBuilder.writeln(
          'זה מספר הרישוי שנקלט: $plate.\n'
          'לא נמצאו פרטי רכב במאגר gov.il עבור מספר רישוי זה.\n'
          'האם ברצונך להמשיך בכל זאת בהזנה ידנית, או לשלוח מספר רישוי אחר?\n\n'
          'אנא הזן את כל פרטי הרכב הנדרשים:',
        );
      } else if (isFirstTurn && titleParts.isNotEmpty) {
        replyBuilder.writeln('מצאתי את הרכב: $titleParts\n');
        replyBuilder.writeln('אנא השלם את הפרטים החסרים:');
      } else {
        replyBuilder.writeln('חסרים עדיין הנתונים הבאים:');
      }

      if (isIrrelevantInput) {
        replyBuilder.writeln(
          'ההודעה ששלחת אינה מספקת את הנתונים הדרושים להשלמת מודעת הרכב.\n',
        );
      }

      if (hasErrors) {
        replyBuilder.writeln('נמצאו שגיאות בנתונים:');
        for (final err in invalidFieldErrors) {
          replyBuilder.writeln('• $err');
        }
        replyBuilder.writeln();
      }

      if (hasMissing) {
        for (final key in missingKeys) {
          replyBuilder.writeln('• ${_hebrewFieldLabel(key)}');
        }
        replyBuilder.writeln(
          '\nשלח את הערכים עם שם השדה, או כרשימה לפי הסדר למעלה. אפשר לשלוח ערך אחד או כמה ערכים יחד.',
        );
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
      replyBuilder.writeln('• צבע: ${state['color']}');
      replyBuilder.writeln('• חודש עלייה לכביש: ${state['month']}');
      final gear = state['gear_type'] ?? state['gear'];
      if (gear != null && gear.isNotEmpty) {
        replyBuilder.writeln('• גיר: $gear');
      }
      if (state['hand'] != null && state['hand']!.isNotEmpty) {
        replyBuilder.writeln('• יד: ${state['hand']}');
      }
      final cond = state['vehicle_condition'] ?? state['vehicleCondition'];
      if (cond != null && cond.isNotEmpty) {
        replyBuilder.writeln('• מצב: $cond');
      }
      final fuel = state['fuel_type'] ?? state['fuelType'];
      if (fuel != null && fuel.isNotEmpty) {
        replyBuilder.writeln('• סוג דלק: $fuel');
      }
      final desc = state['description'];
      if (desc != null && desc.isNotEmpty) {
        replyBuilder.writeln('• פרטים נוספים: $desc');
      }

      final rawImgs = state['image_paths'] ?? state['KEY_IMAGE_PATHS'];
      List<String> imgs = [];
      if (rawImgs != null && rawImgs.isNotEmpty) {
        try {
          imgs = List<String>.from(jsonDecode(rawImgs));
        } catch (_) {}
      }
      if (imgs.isNotEmpty) {
        final countText = (imgs.length == 1)
            ? 'תמונה אחת שמורה'
            : '${imgs.length} תמונות שמורות';
        replyBuilder.writeln('\nכל הפרטים ו-$countText מוכנים לפרסום ביד2!');
        replyBuilder.writeln('לפרסום שלח 0');
        replyBuilder.writeln('לביטול השב ביטול');
      } else {
        replyBuilder.writeln('\nהנתונים מוכנים. כמה תמונות תרצה להעלות?');
        replyBuilder.writeln(
          'השב 1 עד 8 עבור מספר התמונות, 0 לפרסום ללא תמונות, או 9 לביטול.',
        );
      }
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
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 20));

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

  /// Parses various date formats returned by Israeli government APIs (e.g. YYYY-MM-DD, DD/MM/YYYY, ISO).
  static DateTime? parseGovDate(dynamic rawDate) {
    if (rawDate == null) return null;
    final str = rawDate.toString().trim();
    if (str.isEmpty) return null;

    final parsed = DateTime.tryParse(str);
    if (parsed != null) return parsed;

    if (str.contains('-')) {
      final parts = str.split('-');
      if (parts.length >= 2) {
        if (parts[0].length == 4) {
          final y = int.tryParse(parts[0]);
          final m = int.tryParse(parts[1]);
          final d = parts.length >= 3 ? int.tryParse(parts[2]) : 1;
          if (y != null && m != null) return DateTime(y, m, d ?? 1);
        } else if (parts.length >= 3 && parts[2].length == 4) {
          final y = int.tryParse(parts[2]);
          final m = int.tryParse(parts[1]);
          final d = int.tryParse(parts[0]);
          if (y != null && m != null) return DateTime(y, m, d ?? 1);
        }
      }
    } else if (str.contains('/')) {
      final parts = str.split('/');
      if (parts.length >= 2) {
        if (parts.last.length == 4) {
          final y = int.tryParse(parts.last);
          final m = int.tryParse(parts[1]);
          final d = int.tryParse(parts[0]);
          if (y != null && m != null) return DateTime(y, m, d ?? 1);
        }
      }
    }
    return null;
  }

  /// Calculates estimated current kilometers from last test kilometers,
  /// test date, production year/month, and elapsed months.
  ///
  /// Logic:
  /// 1. Determines test date (mivchan_acharon_dt, or tokef_dt minus 1 year, or testMonth/testYear).
  /// 2. Determines production date (moed_aliya_lakvish, or shnat_yitzur).
  /// 3. Computes monthly average mileage: rawKm / totalMonthsUpToTest.
  /// 4. Computes months elapsed since test month:
  ///    - If monthsPast > 0: adds avgKmPerMonth * monthsPast.
  ///    - If monthsPast == 0: adds avgKmPerMonth * 0.5.
  ///    - If monthsPast < 0: adds 0.
  static int calculateEstimatedKm({
    required int rawKm,
    dynamic lastTestDate,
    dynamic tokefDt,
    dynamic testMonth,
    dynamic testYear,
    dynamic moedAliya,
    dynamic shnatYitzur,
    dynamic registrationMonth,
    DateTime? now,
  }) {
    // 1. Determine test date
    DateTime? testDate = parseGovDate(lastTestDate);
    if (testDate == null) {
      final tokefDate = parseGovDate(tokefDt);
      if (tokefDate != null) {
        testDate = DateTime(tokefDate.year - 1, tokefDate.month, tokefDate.day);
      }
    }
    if (testDate == null) {
      final tM = int.tryParse(testMonth?.toString() ?? '');
      final tY = int.tryParse(testYear?.toString() ?? '');
      if (tM != null && tY != null) {
        testDate = DateTime(tY - 1, tM, 1);
      }
    }

    // 2. Determine production year and month
    int? prodYear;
    int prodMonth = 1;

    final moedStr = moedAliya?.toString().trim() ?? '';
    if (moedStr.contains('-')) {
      final parts = moedStr.split('-');
      if (parts.isNotEmpty) {
        prodYear = int.tryParse(parts[0]);
        if (parts.length >= 2) {
          prodMonth = int.tryParse(parts[1]) ?? 1;
        }
      }
    }

    if (prodYear == null && shnatYitzur != null) {
      prodYear = int.tryParse(shnatYitzur.toString().trim());
    }

    if (prodMonth == 1 && registrationMonth != null) {
      prodMonth = int.tryParse(registrationMonth.toString().trim()) ?? 1;
    }

    if (testDate == null || prodYear == null || prodYear <= 0) {
      debugPrint(
        '[WhatsAppValidationService] Missing testDate ($testDate) or prodYear ($prodYear). Using raw KM: $rawKm',
      );
      return rawKm;
    }

    final tYear = testDate.year;
    final tMonth = testDate.month;

    int totalMonthsUpToTest = (tYear - prodYear) * 12 + (tMonth - prodMonth);
    if (totalMonthsUpToTest <= 0) {
      totalMonthsUpToTest = 1;
    }

    final double avgKmPerMonth = rawKm / totalMonthsUpToTest;

    final currentDate = now ?? DateTime.now();
    final monthsPast =
        (currentDate.year - tYear) * 12 + (currentDate.month - tMonth);

    double addedKm = 0.0;
    if (monthsPast > 0) {
      addedKm = avgKmPerMonth * monthsPast;
    } else if (monthsPast == 0) {
      addedKm = avgKmPerMonth * 0.5;
    } else {
      addedKm = 0.0;
    }

    final calculatedKm = (rawKm + addedKm).round();

    debugPrint(
      '[WhatsAppValidationService] Estimated KM: '
      'rawKm=$rawKm, testDate=$tYear-$tMonth, prodDate=$prodYear-$prodMonth, '
      'totalMonthsUpToTest=$totalMonthsUpToTest, avgKmPerMonth=${avgKmPerMonth.toStringAsFixed(1)}, '
      'monthsPast=$monthsPast, addedKm=${addedKm.toStringAsFixed(1)}, calculatedKm=$calculatedKm',
    );

    return calculatedKm;
  }

  /// Checks whether vehicle details were attempted and failed/missing from the Ministry of Transportation (MOE / gov.il).
  static bool isGovLookupFailed(Map<String, String> state) {
    if (state['license_not_found_gov'] == 'true') return true;
    final status = state['gov_vehicle_lookup_status'];
    if (status == 'not_found' || status == 'error' || status == 'failed') {
      return true;
    }
    return false;
  }

  // ── 2. Form Fields & Kilometer Validation ─────────────────────────────────

  /// Validate form fields and verify that kilometers (`km`) is strictly greater than `kilometer_test_aharon`.
  Future<FormValidationResult> validateFormFields(
    Map<String, String> fields, {
    int? kilometerTestAharon,
    bool fetchKilometerWhenMissing = false,
  }) async {
    final errors = <String>[];
    final fieldErrors = <String, String>{};

    final license = _digitsOnly(
      fields['license'] ?? fields['license_plate'] ?? '',
    );
    final kmStr = _digitsOnly(fields['km'] ?? '');
    final priceStr = _digitsOnly(fields['price'] ?? '');
    final handStr = fields['hand']?.trim() ?? '';
    final rawYear = fields['year']?.trim() ?? '';
    final yearStr = _digitsOnly(rawYear);
    final color = fields['color']?.trim() ?? '';
    final roadMonth = fields['month']?.trim() ?? '';
    final testMonth = fields['test_month']?.trim() ?? '';
    final testYear = fields['test_year']?.trim() ?? '';
    final currentOwnership =
        (fields['current_ownership'] ?? fields['ownership'] ?? '').trim();
    final previousOwnership = fields['previous_ownership']?.trim() ?? '';
    final condition =
        (fields['vehicle_condition'] ?? fields['vehicleCondition'] ?? '')
            .trim();
    final gear = (fields['gear_type'] ?? fields['gear'] ?? '').trim();

    // License plate check
    if (license.isEmpty) {
      errors.add('מספר רישוי הוא שדה חובה');
      fieldErrors['license'] = 'חסר מספר רישוי';
    } else if (license.length < 7 || license.length > 8) {
      errors.add('מספר רישוי חייב להכיל 7 או 8 ספרות');
      fieldErrors['license'] = 'מספר רישוי לא תקין';
    }

    // MOE Check: If vehicle details were not fetched from MOE, maker, model, fuel_type, and year are required fields
    final isGovFailed = isGovLookupFailed(fields);
    final maker = (fields['maker'] ?? '').trim();
    final model = (fields['model'] ?? '').trim();
    final fuel = (fields['fuel_type'] ?? fields['fuelType'] ?? '').trim();

    if (isGovFailed) {
      if (maker.isEmpty) {
        errors.add('יצרן הוא שדה חובה');
        fieldErrors['maker'] = 'חסר יצרן';
      }
      if (model.isEmpty) {
        errors.add('דגם הוא שדה חובה');
        fieldErrors['model'] = 'חסר דגם';
      }
      if (fuel.isEmpty) {
        errors.add('סוג דלק הוא שדה חובה');
        fieldErrors['fuel_type'] = 'חסר סוג דלק';
      }
      if (rawYear.isEmpty) {
        errors.add('שנת ייצור היא שדה חובה');
        fieldErrors['year'] = 'חסרה שנת ייצור';
      }
    }

    if (fuel.isNotEmpty && _normalizeFuelType(fuel) == null) {
      errors.add('סוג דלק אינו תקין');
      fieldErrors['fuel_type'] = 'סוג דלק לא תקין';
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
      final minHand = AgentConfigService.instance.minHand;
      final maxHand = AgentConfigService.instance.maxHand;
      if (hand == null || hand < minHand || hand > maxHand) {
        errors.add('מספר יד חייב להיות בין $minHand ל-$maxHand');
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
    if (fetchKilometerWhenMissing &&
        kmTestAharon == null &&
        license.length >= 7) {
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

    if (rawYear.isNotEmpty) {
      final year = int.tryParse(yearStr);
      if (yearStr.length != 4 ||
          yearStr != rawYear ||
          year == null ||
          year < 1900 ||
          year > DateTime.now().year + 1) {
        errors.add('שנת הייצור אינה תקינה');
        fieldErrors['year'] = 'שנת ייצור לא תקינה';
      }
    }

    if (color.isNotEmpty && !yad2AllowedColors.contains(color)) {
      errors.add('הצבע "$color" אינו קיים ברשימת הצבעים של יד2');
      fieldErrors['color'] = 'צבע לא תקין ליד2';
    }

    _validateMonthField(
      value: roadMonth,
      fieldKey: 'month',
      label: 'חודש עלייה לכביש',
      errors: errors,
      fieldErrors: fieldErrors,
    );
    _validateMonthField(
      value: testMonth,
      fieldKey: 'test_month',
      label: 'חודש טסט',
      errors: errors,
      fieldErrors: fieldErrors,
    );

    if (testYear.isNotEmpty) {
      final normalizedTestYear = _digitsOnly(testYear);
      final year = int.tryParse(normalizedTestYear);
      if (normalizedTestYear.length != 4 ||
          normalizedTestYear != testYear ||
          year == null ||
          year < 2000 ||
          year > DateTime.now().year + 10) {
        errors.add('שנת הטסט אינה תקינה');
        fieldErrors['test_year'] = 'שנת טסט לא תקינה';
      }
    }

    final allowedOwnerships =
        AgentConfigService.instance.allowedOwnerships.toSet();
    for (final entry
        in {
          'current_ownership': currentOwnership,
          'previous_ownership': previousOwnership,
        }.entries) {
      if (entry.value.isNotEmpty && !allowedOwnerships.contains(entry.value)) {
        errors.add('${_hebrewFieldLabel(entry.key)} אינה תקינה');
        fieldErrors[entry.key] = '${_hebrewFieldLabel(entry.key)} לא תקינה';
      }
    }

    final allowedConditions =
        AgentConfigService.instance.allowedConditions.toSet();
    if (condition.isNotEmpty && !allowedConditions.contains(condition)) {
      errors.add('מצב הרכב אינו תקין');
      fieldErrors['vehicle_condition'] = 'מצב רכב לא תקין';
    }

    if (gear.isNotEmpty && !gear.contains('אוטומט') && !gear.contains('ידני')) {
      errors.add('סוג הגיר אינו תקין');
      fieldErrors['gear_type'] = 'סוג גיר לא תקין';
    }

    return FormValidationResult(
      isValid: errors.isEmpty,
      errors: errors,
      fieldErrors: fieldErrors,
      kilometerTestAharon: kmTestAharon,
    );
  }

  void _validateMonthField({
    required String value,
    required String fieldKey,
    required String label,
    required List<String> errors,
    required Map<String, String> fieldErrors,
  }) {
    if (value.isEmpty) return;
    final month = int.tryParse(value);
    if (!RegExp(r'^\d{1,2}$').hasMatch(value) ||
        month == null ||
        month < 1 ||
        month > 12) {
      errors.add('$label חייב להיות בין 1 ל-12');
      fieldErrors[fieldKey] = '$label לא תקין';
    }
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

    final roadMonthMatch = RegExp(
      r'(?:חודש\s*(?:עלייה|עליה)\s*לכביש|עלייה\s*לכביש|עליה\s*לכביש)[^\d]{0,12}(\d{1,2})',
      caseSensitive: false,
    ).firstMatch(text);
    if (roadMonthMatch != null) {
      _putIfNotEmpty(result, 'month', _normalizeMonth(roadMonthMatch.group(1)));
    }

    final yearMatch = RegExp(
      r'(?:שנת\s*ייצור|שנה|year)\s*[:=\-]?\s*(\d{4})',
      caseSensitive: false,
    ).firstMatch(text);
    _putIfNotEmpty(result, 'year', _normalizeYear(yearMatch?.group(1)));
    _putIfNotEmpty(
      result,
      'maker',
      _extractLabeledValue(text, r'(?:יצרן|תוצרת|maker|make)'),
    );
    _putIfNotEmpty(
      result,
      'model',
      _extractLabeledValue(text, r'(?:דגם|model)'),
    );
    final rawColor = _extractLabeledValue(text, r'(?:צבע|color)');
    if (rawColor != null) {
      _putIfNotEmpty(
        result,
        'color',
        yad2AllowedColors.contains(rawColor)
            ? rawColor
            : _fallbackColorMatch(rawColor, yad2AllowedColors),
      );
    }

    _putIfNotEmpty(result, 'hand', _extractHand(text));
    _putIfNotEmpty(
      result,
      'current_ownership',
      _extractOwnership(
        text,
        r'(?:בעלות\s*נוכחית|בעלים\s*נוכחי|בעלות(?!\s*(?:קודמת|מקורית)))',
      ),
    );
    _putIfNotEmpty(
      result,
      'previous_ownership',
      _extractOwnership(
        text,
        r'(?:בעלות\s*(?:קודמת|מקורית)|בעלים\s*קודמים|בעלים\s*קודם)',
      ),
    );
    _putIfNotEmpty(result, 'km', _extractKm(text));
    _putIfNotEmpty(result, 'price', _extractPrice(text));
    _putIfNotEmpty(result, 'vehicle_condition', _extractVehicleCondition(text));
    _putIfNotEmpty(result, 'description', _extractDescription(text));
    _putIfNotEmpty(result, 'gear_type', _extractGear(text));
    _putIfNotEmpty(result, 'fuel_type', _extractFuelType(text));

    return result;
  }

  /// AI Model integration to refine extraction, determine user intent, and provide conversational WhatsApp guidance.
  Future<AiTurnResult> askAiModelToProcessTurn(
    String rawText,
    Map<String, String> currentFields, {
    List<String>? missingFields,
    List<String>? fieldErrors,
    List<Map<String, String>>? chatHistory,
    Map<String, String>? lastSavedVehicle,
    bool hasActiveSession = true,
  }) async {
    try {
      await AgentConfigService.instance.checkAndUpdateConfigIfNeeded();
      final recentHistory =
          (chatHistory ?? const <Map<String, String>>[])
              .where((entry) => entry['text']?.trim().isNotEmpty ?? false)
              .toList();
      final boundedHistory =
          recentHistory.length > 12
              ? recentHistory.sublist(recentHistory.length - 12)
              : recentHistory;
      final llmFieldContext = <String, String>{};
      for (final key in {
        'license_plate',
        'kilometer_test_aharon',
        ..._extractableAiFields,
      }) {
        final value = currentFields[key]?.trim() ?? '';
        if (value.isNotEmpty) llmFieldContext[key] = value;
      }
      final requestData = {
        'current_message': rawText,
        'has_active_session': hasActiveSession,
        'current_verified_fields': llmFieldContext,
        'missing_fields_in_requested_order': missingFields ?? const <String>[],
        'field_errors': fieldErrors ?? const <String>[],
        'last_saved_vehicle': lastSavedVehicle ?? const <String, String>{},
        'recent_session_history': boundedHistory,
        'allowed_yad2_colors': yad2AllowedColors,
      };

      if (aiTurnProcessor != null) {
        try {
          final mocked = await aiTurnProcessor!(requestData);
          if (mocked != null) return mocked;
        } catch (e) {
          debugPrint('[WhatsAppValidationService] aiTurnProcessor error: $e');
        }
      }

      final apiKey = await _resolveAnthropicApiKey();
      if (apiKey.isEmpty) return const AiTurnResult();

      final systemPrompt = AgentConfigService.instance.systemPrompt;

      final body = jsonEncode({
        'model': aiModel,
        'max_completion_tokens': 512,
        'reasoning_effort': 'low',
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': jsonEncode(requestData)},
        ],
      });

      final response = await http
          .post(
            Uri.parse('https://api.openai.com/v1/chat/completions'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 25));

      if (response.statusCode == 200) {
        final decoded =
            jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;

        final contentText =
            decoded['choices']?[0]?['message']?['content']?.toString().trim() ??
            '';

        if (contentText.isNotEmpty) {
          final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(contentText);

          if (jsonMatch != null) {
            final jsonMap =
                jsonDecode(jsonMatch.group(0)!) as Map<String, dynamic>;

            return _parseAiTurnResponse(jsonMap);
          }
        }
      } else {
        debugPrint(
          '[WhatsAppValidationService] AI extraction HTTP ${response.statusCode}: ${response.body}',
        );
      }
    } catch (e) {
      debugPrint('[WhatsAppValidationService] AI extraction error: $e');
    }

    return const AiTurnResult();
  }

  AiTurnResult _parseAiTurnResponse(Map<String, dynamic> jsonMap) {
    var rawIntent = jsonMap['intent']?.toString().toLowerCase().trim() ?? '';
    final assistantReply = jsonMap['assistant_reply']?.toString().trim();

    Map<String, dynamic> rawFields = {};
    if (jsonMap['extracted_fields'] is Map<String, dynamic>) {
      rawFields = jsonMap['extracted_fields'] as Map<String, dynamic>;
    } else {
      rawFields = Map<String, dynamic>.from(jsonMap);
      rawFields.remove('intent');
      rawFields.remove('assistant_reply');
      rawFields.remove('should_republish');
    }

    final sanitized = _sanitizeAiExtraction(rawFields);
    final shouldRepublish = rawIntent == 'republish_last' ||
        jsonMap['should_republish'] == true ||
        jsonMap['should_republish'] == 'true';

    if (rawIntent.isEmpty) {
      if (shouldRepublish) {
        rawIntent = 'republish_last';
      } else if (sanitized.isNotEmpty) {
        rawIntent = 'update_details';
      } else if (assistantReply != null && assistantReply.isNotEmpty) {
        rawIntent = 'greeting_or_help';
      } else {
        rawIntent = 'unknown';
      }
    }

    return AiTurnResult(
      intent: rawIntent,
      extractedFields: sanitized,
      assistantReply:
          assistantReply?.isNotEmpty == true ? assistantReply : null,
      shouldRepublish: shouldRepublish,
    );
  }

  /// AI Model integration to refine extraction or validate complex unstructured WhatsApp text.
  Future<Map<String, String>> askAiModelToExtractFields(
    String rawText,
    Map<String, String> currentFields, {
    List<String>? missingFields,
    List<Map<String, String>>? chatHistory,
  }) async {
    final result = await askAiModelToProcessTurn(
      rawText,
      currentFields,
      missingFields: missingFields,
      chatHistory: chatHistory,
    );
    return result.extractedFields;
  }

  Future<String> _resolveAnthropicApiKey() async {
    final configured = anthropicApiKey?.trim() ?? '';
    if (configured.isNotEmpty) return configured;
    final fromConfig = AgentConfigService.instance.apiKey?.trim() ?? '';
    if (fromConfig.isNotEmpty) return fromConfig;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('anthropic_api_key')?.trim() ?? '';
      if (saved.isNotEmpty) return saved;
      final openAiSaved = prefs.getString('openai_api_key')?.trim() ?? '';
      if (openAiSaved.isNotEmpty) return openAiSaved;
    } catch (_) {
      // Pure validation can run before Flutter bindings are initialized.
    }
    final env = const String.fromEnvironment(
      'ANTHROPIC_API_KEY',
      defaultValue: '',
    ).trim();
    if (env.isNotEmpty) return env;
    final envOpenAi = const String.fromEnvironment(
      'OPENAI_API_KEY',
      defaultValue: '',
    ).trim();
    if (envOpenAi.isNotEmpty) return envOpenAi;

    return '';
  }

  Future<bool> _hasAiApiKey() async =>
      aiTurnProcessor != null || (await _resolveAnthropicApiKey()).isNotEmpty;

  Map<String, String> _sanitizeAiExtraction(Map<String, dynamic> jsonMap) {
    final result = <String, String>{};
    jsonMap.forEach((rawKey, rawValue) {
      var key = rawKey.trim();
      if (key == 'vehicleCondition') key = 'vehicle_condition';
      if (key == 'ownership') key = 'current_ownership';
      if (key == 'gear') key = 'gear_type';
      if (!_extractableAiFields.contains(key) || rawValue == null) return;

      final value = rawValue.toString().trim();
      if (value.isEmpty || value.toLowerCase() == 'null') return;
      String? normalized;
      switch (key) {
        case 'km':
        case 'price':
          final digits = _digitsOnly(value);
          if ((int.tryParse(digits) ?? 0) > 0) normalized = digits;
          break;
        case 'hand':
          final hand = _parseHand(value);
          if (hand != null && hand >= 1 && hand <= 15) normalized = '$hand';
          break;
        case 'month':
        case 'test_month':
          final month = _normalizeMonth(value);
          if (month.isNotEmpty) normalized = month;
          break;
        case 'year':
        case 'test_year':
          normalized = _normalizeYear(value);
          break;
        case 'color':
          normalized =
              yad2AllowedColors.contains(value)
                  ? value
                  : _fallbackColorMatch(value, yad2AllowedColors);
          break;
        case 'current_ownership':
        case 'previous_ownership':
          normalized = _normalizeOwnership(value);
          break;
        case 'vehicle_condition':
          normalized = _extractVehicleCondition(value);
          break;
        case 'gear_type':
          normalized = _extractGear(value);
          break;
        case 'description':
          normalized = value.substring(
            0,
            value.length > 500 ? 500 : value.length,
          );
          break;
        case 'maker':
        case 'model':
          normalized = value.substring(
            0,
            value.length > 80 ? 80 : value.length,
          );
          break;
        case 'fuel_type':
          normalized = _normalizeFuelType(value) ?? value;
          break;
      }
      if (normalized != null && normalized.trim().isNotEmpty) {
        result[key] = normalized.trim();
      }
    });
    return result;
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
        norm == 'לבטל' ||
        norm == 'בטל' ||
        norm == 'cancel' ||
        norm == 'stop' ||
        norm == 'פרסום' ||
        norm == 'פרסם' ||
        norm == 'publish' ||
        norm == 'המשך מהפרסום הנוכחי' ||
        norm == 'המשך' ||
        norm.contains('המשך מהפרסום') ||
        norm == 'continue') {
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

    // Numeric replies are field answers until all required details are ready;
    // only then can they represent an image count.
    if (_shouldHandleAsCommand(trimmedText, existingState) ||
        _isAutomationRunning(existingState)) {
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

    // Step 1: Positional & Rule-based extraction
    final missingBeforeMessage = _requestedFieldsForTurn(existingState);
    var extracted = _extractPositionalFields(trimmedText, missingBeforeMessage);

    final chatHistory = _parseChatHistory(existingState['chat_history']);
    chatHistory.add({
      'role': 'user',
      'text': trimmedText,
      'timestamp': '${DateTime.now().millisecondsSinceEpoch}',
    });

    // Step 2: Let the configured model review this turn and return only a
    // constrained delta. Existing verified values are never copied back.
    final combinedForAi = Map<String, String>.from(existingState);
    _mergeNonEmpty(combinedForAi, extracted);
    final usedAi = await _hasAiApiKey();
    if (usedAi) {
      final aiExtracted = await askAiModelToExtractFields(
        trimmedText,
        combinedForAi,
        missingFields: _checkMissingKeys(combinedForAi),
        chatHistory: chatHistory,
      );
      _mergeNonEmpty(extracted, aiExtracted);
    }

    // Step 3: Combine with existing state
    final combinedState = Map<String, String>.from(existingState);
    extracted.forEach((k, v) {
      if (v.isNotEmpty) combinedState[k] = v;
    });
    _normalizeStateFields(combinedState);

    // Step 4: Validate form fields & kilometer_test_aharon
    final formVal = await validateFormFields(
      combinedState,
      kilometerTestAharon:
          kilometerTestAharon ??
          int.tryParse(combinedState['kilometer_test_aharon'] ?? ''),
      fetchKilometerWhenMissing: false,
    );

    final missingKeys = _checkMissingKeys(combinedState);
    final isReady = formVal.isValid && missingKeys.isEmpty;

    // Step 5: Compose Hebrew reply
    final replyHebrew = composeHebrewReply(
      state: combinedState,
      formVal: formVal,
      missingKeys: missingKeys,
      isIrrelevantInput: extracted.isEmpty && missingKeys.isNotEmpty,
    );

    return WhatsAppValidationResult(
      isValid: formVal.isValid,
      extractedFields: extracted,
      missingFields: missingKeys,
      validationErrors: formVal.errors,
      replyHebrew: replyHebrew,
      readyToPublish: isReady,
      usedAiModel: usedAi,
      kilometerTestAharon: formVal.kilometerTestAharon,
    );
  }

  // ── Internal extraction helpers ─────────────────────────────────────────

  List<String> _checkMissingKeys(Map<String, String> state) {
    final isGovFailed = isGovLookupFailed(state);
    final requiredKeys = [
      'license_plate',
      'maker',
      'model',
      'year',
      if (isGovFailed) 'fuel_type',
      'hand',
      'price',
      'km',
      'color',
      'month',
      'test_month',
      'test_year',
      'current_ownership',
      'previous_ownership',
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
      case 'current_ownership':
        return 'ownership';
      case 'fuel_type':
        return 'fuelType';
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
      case 'fuel_type':
      case 'fuelType':
        return 'סוג דלק';
      case 'description':
        return 'פרטים נוספים';
      case 'gear_type':
      case 'gear':
        return 'גיר (אוטומטי/ידני)';
      case 'month':
        return 'חודש עלייה לכביש';
      case 'test_month':
        return 'חודש טסט';
      case 'test_year':
        return 'שנת טסט';
      case 'current_ownership':
      case 'ownership':
        return 'בעלות נוכחית';
      case 'previous_ownership':
        return 'בעלות קודמת';
      default:
        return key;
    }
  }

  /// Normalizes transcribed license plate strings:
  /// - Removes dots/periods between number groups (e.g. "52.116.309" or "51.116.39")
  /// - Collapses compound tens and units where speech-to-text separates them
  ///   (e.g. "thirty-nine" -> 39 instead of 30 9 or 309).
  /// - Fixes 2-3-3 pattern (e.g. "52.116.309") into 2-3-2 (7 digits "5211639")
  String normalizeTranscribedPlateText(String text) {
    var s = text.trim();

    // 0. Remove spaces around dots or hyphens between digits (e.g. "52 . 116 . 309" -> "52.116.309")
    s = s.replaceAllMapped(
      RegExp(r'(\d+)\s*([\.\-])\s*(\d+)'),
      (m) => '${m.group(1)}${m.group(2)}${m.group(3)}',
    );

    // 1. Collapse compound tens separated by whitespace, dot, dash, or 'ו'
    // e.g. "30 9", "30.9", "30-9", "30 ו 9" -> "39"
    s = s.replaceAllMapped(
      RegExp(r'(?<!\d)([2-9]0)[\s\.\-]+(?:ו\s*)?([1-9])(?!\d)'),
      (m) => '${m.group(1)![0]}${m.group(2)}',
    );

    // 2. Handle segmented plates like "52.116.309" or "52 116 309" (2-3-3 pattern)
    // In Israel, a plate starting with 2 digits and middle 3 digits is strictly 7 digits (2-3-2).
    // If the 3rd segment is 3 digits of form [2-9]0[1-9] (e.g. 309 for thirty-nine),
    // collapse it to 2 digits (e.g. 309 -> 39).
    s = s.replaceAllMapped(
      RegExp(r'(?<!\d)(\d{2})[\s\.\-]+(\d{3})[\s\.\-]+([2-9])0([1-9])(?!\d)'),
      (m) => '${m.group(1)}${m.group(2)}${m.group(3)}${m.group(4)}',
    );

    // 3. Handle segmented plates like "501.116.39" (3-3-2 pattern where 1st is [2-9]0[1-9])
    s = s.replaceAllMapped(
      RegExp(r'(?<!\d)([2-9])0([1-9])[\s\.\-]+(\d{3})[\s\.\-]+(\d{2})(?!\d)'),
      (m) => '${m.group(1)}${m.group(2)}${m.group(3)}${m.group(4)}',
    );

    // 4. Handle 8-digit segmented plates like "123.405.678" (3-3-3 where middle is [2-9]0[1-9])
    s = s.replaceAllMapped(
      RegExp(r'(?<!\d)(\d{3})[\s\.\-]+([2-9])0([1-9])[\s\.\-]+(\d{3})(?!\d)'),
      (m) => '${m.group(1)}${m.group(2)}${m.group(3)}${m.group(4)}',
    );

    // 5. Remove dots in standard 7-digit segmented plates: "51.116.39" -> "5111639"
    s = s.replaceAllMapped(
      RegExp(r'(?<!\d)(\d{2})\.(\d{3})\.(\d{2})(?!\d)'),
      (m) => '${m.group(1)}${m.group(2)}${m.group(3)}',
    );

    // 6. Remove dots in standard 8-digit segmented plates: "123.45.678" -> "12345678"
    s = s.replaceAllMapped(
      RegExp(r'(?<!\d)(\d{3})\.(\d{2})\.(\d{3})(?!\d)'),
      (m) => '${m.group(1)}${m.group(2)}${m.group(3)}',
    );

    // 7. If the entire string is just digits and dots/spaces/dashes (e.g. "52.116.309" or "51.116.39"),
    // and contains 7 or 8 digits total, return pure digits without dots:
    if (RegExp(r'^[\d\s\.\-]+$').hasMatch(s)) {
      final digits = _digitsOnly(s);
      if (digits.length >= 7 && digits.length <= 8) {
        return digits;
      }
    }

    return s;
  }

  String? _extractLicensePlate(String text) {
    final normalized = normalizeTranscribedPlateText(text);

    final explicit = RegExp(
      r'(?:מספר\s*(?:רכב|רישוי)|לוחית(?:\s*רישוי)?|רישוי|license)[^\d]{0,16}(\d[\d\s\.\-]{5,12}\d)',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (explicit != null) {
      final rawMatch = explicit.group(1) ?? '';
      var digits = _digitsOnly(rawMatch);
      if (digits.length == 8 && RegExp(r'^[1-9]\d[\s\.\-]').hasMatch(rawMatch.trim())) {
        final tail = digits.substring(5);
        if (RegExp(r'^[2-9]0[1-9]$').hasMatch(tail)) {
          digits = '${digits.substring(0, 5)}${tail[0]}${tail[2]}';
        }
      }
      if (digits.length >= 7 && digits.length <= 8) return digits;
    }

    for (final match in RegExp(
      r'(?<!\d)(\d[\d\s\.\-]{5,12}\d)(?!\d)',
    ).allMatches(normalized)) {
      final rawMatch = match.group(1) ?? '';
      var candidate = _digitsOnly(rawMatch);

      // If candidate is 8 digits ending in [2-9]0[1-9] but rawMatch started with 2-digit chunk
      // (e.g. "52116309" from "52.116.309" or "52-116-309"):
      if (candidate.length == 8 && RegExp(r'^[1-9]\d[\s\.\-]').hasMatch(rawMatch.trim())) {
        final tail = candidate.substring(5);
        if (RegExp(r'^[2-9]0[1-9]$').hasMatch(tail)) {
          candidate = '${candidate.substring(0, 5)}${tail[0]}${tail[2]}';
        }
      }

      if (candidate.length < 7 || candidate.length > 8) continue;

      final before =
          normalized
              .substring(match.start > 24 ? match.start - 24 : 0, match.start)
              .toLowerCase();
      final after =
          normalized
              .substring(
                match.end,
                match.end + 12 < normalized.length ? match.end + 12 : normalized.length,
              )
              .toLowerCase();
      final looksLikePriceOrKm =
          RegExp(
            r'(?:מחיר|דורש|מבקש|רוצה|קמ|ק״מ|קילומטראז|שעון|נסע|price|km)\s*[:=\-]?\s*$',
            caseSensitive: false,
          ).hasMatch(before) ||
          RegExp(
            r'^\s*(?:₪|ש״ח|שח|ק״מ|קמ|nis|km)',
            caseSensitive: false,
          ).hasMatch(after);
      if (!looksLikePriceOrKm) return candidate;
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

  String? _extractLabeledValue(String text, String labelPattern) {
    final match = RegExp(
      '$labelPattern\\s*[:=\\-]?\\s*([^,.;\\n]+)',
      caseSensitive: false,
    ).firstMatch(text);
    final value = match?.group(1)?.trim() ?? '';
    if (value.isEmpty) return null;
    return value.substring(0, value.length > 80 ? 80 : value.length);
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
    for (final line in text.split('\n')) {
      final normLine = line.trim();
      if (normLine.isEmpty) continue;

      final labelFirst = RegExp(
        r'''(?:קילומטראז['׳]?|קילומטרים|ק["״]מ|קמ|נסע|שעון|על השעון|מייל(?:ים)?|miles?|km)[^\S\r\n]*[:=\-]?[^\S\r\n]*([\d,.]+)(?:[^\S\r\n]*אלף)?''',
        caseSensitive: false,
      ).firstMatch(normLine);
      final valueFirst = RegExp(
        r'''([\d,.]+)(?:[^\S\r\n]*אלף)?[^\S\r\n]*(?:קילומטראז['׳]?|קילומטרים|ק["״]מ|קמ|נסע|שעון|על השעון|מייל(?:ים)?|miles?|km)''',
        caseSensitive: false,
      ).firstMatch(normLine);

      final match = labelFirst ?? valueFirst;
      if (match != null) {
        final rawNum = match.group(1) ?? '';
        final digits = _digitsOnly(rawNum);
        if (digits.isNotEmpty) {
          int? numVal = int.tryParse(digits);
          if (numVal != null) {
            if (match.group(0)!.contains('אלף') && digits.length <= 3) {
              numVal = numVal * 1000;
            }
            final matchedText = match.group(0)!.toLowerCase();
            if (matchedText.contains('מייל') || matchedText.contains('mile')) {
              numVal = (numVal * 1.60934).round();
            }
            return numVal.toString();
          }
          return digits;
        }
      }
    }
    return null;
  }

  String? _extractPrice(String text) {
    for (final line in text.split('\n')) {
      final normLine = line.trim();
      if (normLine.isEmpty) continue;

      final labeled = RegExp(
        r'(?:מחיר|price|דורש|מבקש|רוצה)[^\S\r\n]*[:=\-]?[^\S\r\n]*([\d,.]+)(?:[^\S\r\n]*אלף)?',
        caseSensitive: false,
      ).firstMatch(normLine);

      final currency = RegExp(
        r'''([\d,.]+)(?:[^\S\r\n]*אלף)?[^\S\r\n]*(?:₪|ש["״]ח|שח['׳]?|שח|nis)''',
        caseSensitive: false,
      ).firstMatch(normLine);

      final match = labeled ?? currency;
      if (match != null) {
        final digits = _digitsOnly(match.group(1) ?? '');
        if (digits.isNotEmpty) {
          if (match.group(0)!.contains('אלף') && digits.length <= 3) {
            final num = int.tryParse(digits);
            return num != null ? (num * 1000).toString() : digits;
          }
          return digits;
        }
      }
    }
    return null;
  }

  String? _extractVehicleCondition(String text) {
    final norm = text.toLowerCase();
    if (norm.contains('כמו חדש')) return 'כמו חדש';
    if (norm.contains('חדש')) return 'חדש';
    if (norm.contains('לא טוב') || norm.contains('גרוע')) return 'גרוע';
    if (norm.contains('מצוין') ||
        norm.contains('מצויין') ||
        norm.contains('מעולה')) {
      return 'מצוין';
    }
    if (norm.contains('טוב מאוד') || norm.contains('טובה מאוד')) {
      return 'טוב מאוד';
    }
    if (norm.contains('סביר')) return 'סביר';
    if (norm.contains('משומש')) return 'משומש';
    if (norm.contains('טוב') || norm.contains('טובה')) return 'טוב';
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

  static String? _normalizeFuelType(String text) {
    final norm = text.trim().toLowerCase();
    if (norm.isEmpty) return null;
    if (norm.contains('בנזין') || norm.contains('gasoline') || norm.contains('petrol')) {
      return 'בנזין';
    }
    if (norm.contains('דיזל') || norm.contains('סולר') || norm.contains('diesel')) {
      return 'דיזל';
    }
    if (norm.contains('חשמל') || norm.contains('electric') || norm == 'ev') {
      return 'חשמל';
    }
    if (norm.contains('היבריד') || norm.contains('hybrid') || norm.contains('פלאג') || norm.contains('בנזין/חשמל') || norm.contains('בנזין וחשמל')) {
      return 'היברידי';
    }
    if (norm.contains('גז') || norm.contains('lpg') || norm.contains('cng')) {
      return 'גז';
    }
    return null;
  }

  String? _extractFuelType(String text) {
    final explicit = RegExp(
      r'(?:סוג\s*דלק|דלק|הנעה|fuel)[^\w\u0590-\u05FF]{0,10}([^\n,;]+)',
      caseSensitive: false,
    ).firstMatch(text);
    if (explicit != null) {
      final val = _normalizeFuelType(explicit.group(1) ?? '');
      if (val != null && val.isNotEmpty) return val;
    }
    return _normalizeFuelType(text);
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

  Map<String, String> _extractPositionalFields(
    String text,
    List<String> missingKeys,
  ) {
    if (text.trim().isEmpty) return {};

    final explicitExtracted = extractFieldsFromText(text);
    if (missingKeys.isEmpty) return explicitExtracted;

    final remainingMissing =
        missingKeys.where((k) {
          final alt = _altKey(k);
          return !explicitExtracted.containsKey(k) &&
              !explicitExtracted.containsKey(alt) &&
              (explicitExtracted[k] == null || explicitExtracted[k]!.isEmpty);
        }).toList();

    List<String> rawTokens =
        text
            .split(RegExp(r'[\r\n]+'))
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();

    if (rawTokens.length == 1 && rawTokens.first.contains(RegExp(r'[,;/]'))) {
      rawTokens =
          rawTokens.first
              .split(RegExp(r'[,;/]+'))
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
    } else if (rawTokens.length == 1 && rawTokens.first.contains(RegExp(r'\s+'))) {
      rawTokens =
          rawTokens.first
              .split(RegExp(r'\s+'))
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
    }

    if (rawTokens.length > remainingMissing.length &&
        !remainingMissing.contains('vehicle_condition') &&
        !explicitExtracted.containsKey('vehicle_condition') &&
        !explicitExtracted.containsKey('vehicleCondition')) {
      remainingMissing.add('vehicle_condition');
    }

    if (remainingMissing.isEmpty) return explicitExtracted;

    final result = Map<String, String>.from(explicitExtracted);

    final unconsumed = <String>[];
    for (final token in rawTokens) {
      final tokenExt = extractFieldsFromText(token);
      if (tokenExt.isEmpty) {
        unconsumed.add(token);
      }
    }

    if (unconsumed.isEmpty) return result;

    if (unconsumed.length == 1) {
      final token = unconsumed.first;
      final digits = _digitsOnly(token);
      final num = int.tryParse(digits);
      if (num != null && num > 0) {
        if (num <= 15 && remainingMissing.contains('hand')) {
          result['hand'] = '$num';
          return result;
        }
        if (num >= 70000 && remainingMissing.contains('km')) {
          result['km'] = digits;
          return result;
        }
        if (remainingMissing.contains('km') &&
            !remainingMissing.contains('price')) {
          result['km'] = digits;
          return result;
        }
        if (remainingMissing.contains('price')) {
          result['price'] = digits;
          return result;
        }
      }
    }

    if (unconsumed.length == remainingMissing.length) {
      for (int i = 0; i < remainingMissing.length; i++) {
        final key = remainingMissing[i];
        final token = unconsumed[i];
        final matchedVal = _tryMatchTokenToKey(token, key);
        if (matchedVal != null) {
          result[key] = matchedVal;
        }
      }
    } else {
      int tokenIdx = 0;
      for (final key in remainingMissing) {
        if (tokenIdx >= unconsumed.length) break;
        final token = unconsumed[tokenIdx];
        final matchedVal = _tryMatchTokenToKey(token, key);
        if (matchedVal != null) {
          result[key] = matchedVal;
          tokenIdx++;
        }
      }
    }

    return result;
  }

  String? _tryMatchTokenToKey(String token, String key) {
    final clean = token.trim();
    if (clean.isEmpty) return null;

    final digits = _digitsOnly(clean);

    switch (key) {
      case 'price':
      case 'km':
        if (digits.isNotEmpty) {
          final num = int.tryParse(digits);
          if (num != null && num > 0) return digits;
        }
        return null;

      case 'hand':
        final parsedHand = _parseHand(clean);
        if (parsedHand != null && parsedHand >= 1 && parsedHand <= 15) {
          return parsedHand.toString();
        }
        return null;

      case 'vehicle_condition':
      case 'vehicleCondition':
        final cond = _extractVehicleCondition(clean);
        if (cond != null) return cond;
        final norm = clean.toLowerCase();
        if (norm == 'good' ||
            norm == 'great' ||
            norm == 'excellent' ||
            norm == 'ok') {
          return 'טוב';
        }
        return null;

      case 'year':
      case 'test_year':
        if (digits.length == 4) {
          final y = int.tryParse(digits);
          if (y != null && y >= 1990 && y <= 2030) return digits;
        }
        return null;

      case 'test_month':
      case 'month':
        if (digits.isNotEmpty) {
          final m = int.tryParse(digits);
          if (m != null && m >= 1 && m <= 12) return m.toString();
        }
        return null;

      case 'color':
        final norm = clean.toLowerCase();
        const validColors = [
          'כחול',
          'לבן',
          'שחור',
          'אדום',
          'אפור',
          'כסף',
          'זהב',
          'ירוק',
          'צהוב',
          'חום',
          'סגול',
          'כתום',
          'בז\'',
          'טורקיז',
          'blue',
          'white',
          'black',
          'red',
          'grey',
          'gray',
          'silver',
          'gold',
        ];
        if (validColors.contains(norm) || validColors.contains(clean)) {
          return yad2AllowedColors.contains(clean)
              ? clean
              : _fallbackColorMatch(clean, yad2AllowedColors);
        }
        return null;

      case 'current_ownership':
      case 'previous_ownership':
      case 'ownership':
        final norm = clean.toLowerCase();
        if (norm.contains('פרטי')) return 'פרטית';
        if (norm.contains('חברה')) return 'חברה';
        if (norm.contains('ליסינג')) return 'ליסינג';
        if (norm.contains('השכרה')) return 'השכרה';
        if (norm.contains('מונית')) return 'מונית';
        return null;

      case 'gear_type':
      case 'gear':
        final gear = _extractGear(clean);
        if (gear != null) return gear;
        return null;

      case 'maker':
      case 'model':
        // Free text is too ambiguous positionally (for example, a greeting
        // could be mistaken for make/model). These fields require a label or
        // the constrained LLM extractor.
        return null;

      default:
        return null;
    }
  }

  List<Map<String, String>> _parseChatHistory(String? jsonStr) {
    if (jsonStr == null || jsonStr.trim().isEmpty) return [];
    try {
      final list = jsonDecode(jsonStr) as List;
      return list.map((item) {
        final map = item as Map<String, dynamic>;
        return map.map((k, v) => MapEntry(k, v?.toString() ?? ''));
      }).toList();
    } catch (_) {
      return [];
    }
  }

  /// Maps a government or user-facing color description to a value accepted
  /// by Yad2. Non-exact values are sent to the configured LLM, with a local
  /// semantic fallback for offline operation.
  Future<String> matchColorToYad2Value(String rawColor) async {
    final color = rawColor.trim();
    if (color.isEmpty) return 'אפור';
    if (yad2AllowedColors.contains(color)) return color;
    return _matchColorWithLlm(color, yad2AllowedColors);
  }

  Future<String> _matchColorWithLlm(
    String rawColor,
    List<String> allowedColors,
  ) async {
    try {
      final apiKey = await _resolveAnthropicApiKey();

      if (apiKey.isEmpty) {
        return _fallbackColorMatch(rawColor, allowedColors);
      }

      final prompt = AgentConfigService.instance.getColorMatchingPrompt(
        rawColor,
        allowedColors,
      );

      final body = jsonEncode({
        'model': aiModel,
        'max_tokens': 50,
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
      });

      final response = await http
          .post(
            Uri.parse('https://api.anthropic.com/v1/messages'),
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': apiKey,
              'anthropic-version': '2023-06-01',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 25));

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

        final cleanResult = contentText.trim().replaceAll(
          RegExp(r'[^\u0590-\u05FF]'),
          '',
        );
        for (final allowed in allowedColors) {
          if (cleanResult == allowed ||
              allowed.contains(cleanResult) ||
              cleanResult.contains(allowed)) {
            return allowed;
          }
        }
      }
    } catch (e) {
      debugPrint('[WhatsAppValidationService] LLM color matching error: $e');
    }

    return _fallbackColorMatch(rawColor, allowedColors);
  }

  String _fallbackColorMatch(String rawColor, List<String> allowedColors) {
    final norm = rawColor.toLowerCase();
    if (norm.contains('כסף') ||
        norm.contains('כסוף') ||
        norm.contains('אפור') ||
        norm.contains('עכבר') ||
        norm.contains('silver') ||
        norm.contains('grey') ||
        norm.contains('gray')) {
      return 'אפור';
    }
    if (norm.contains('זהב') ||
        norm.contains('צהוב') ||
        norm.contains('נחושת')) {
      return 'צהוב';
    }
    if (norm.contains('פנינה') ||
        norm.contains('שנהב') ||
        norm.contains('שמנת') ||
        norm.contains('קרם')) {
      return 'לבן';
    }
    if (norm.contains('תכלת') ||
        norm.contains('כחול') ||
        norm.contains('טורקיז')) {
      return 'כחול';
    }
    if (norm.contains('בורדו') || norm.contains('אדום')) return 'אדום';
    if (norm.contains('חום') || norm.contains('בז')) return 'חום';
    if (norm.contains('ירוק')) return 'ירוק';
    if (norm.contains('כתום')) return 'כתום';
    if (norm.contains('סגול')) return 'סגול';
    if (norm.contains('ורוד')) return 'ורוד';
    if (norm.contains('שחור')) return 'שחור';
    if (norm.contains('white')) return 'לבן';
    if (norm.contains('black')) return 'שחור';
    if (norm.contains('red')) return 'אדום';
    if (norm.contains('blue')) return 'כחול';
    if (norm.contains('green')) return 'ירוק';
    if (allowedColors.contains('אפור')) return 'אפור';
    return allowedColors.isEmpty ? '' : allowedColors.first;
  }
}
