import 'dart:convert';
import 'dart:io';
import 'package:publication_protocol/publication_protocol.dart';
import 'remote_api.dart';

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

class RemoteValidationService {
  static const cloudFunctionUrl = RemoteApi.url;
  static String normalizeTranscribedText(String text) =>
      VehicleSchema.normalizeSpeech(text);
  static List<String> getMissingFields(Map<String, String> state) {
    final missing = VehicleSchema.missing(state).toList();
    final hasNoTest = state['no_test'] == 'true';
    final hasTestYear = (state['test_year'] ?? '').trim().isNotEmpty;
    final hasTestMonth = (state['test_month'] ?? '').trim().isNotEmpty;
    final hasTestUntil = (state['test_until'] ?? '').trim().isNotEmpty;
    
    if (!hasNoTest && !hasTestUntil && (!hasTestYear || !hasTestMonth)) {
      if (!missing.contains('test_until')) missing.add('test_until');
    }
    return missing;
  }
  static List<String> validateValues(Map<String, String> state) =>
      VehicleSchema.errors(state);

  static Future<String?> transcribeAudio(
    File file, {
    required String deviceId,
  }) async {
    if (await file.length() > 8 * 1024 * 1024)
      throw StateError('ההקלטה ארוכה מדי; נסה הקלטה קצרה יותר');
    final result = await RemoteApi.post(deviceId, {
      'action': 'transcribe_audio',
      'audioBase64': base64Encode(await file.readAsBytes()),
      'mimeType': 'audio/m4a',
      'fileName': 'recording.m4a',
    });
    final text = normalizeTranscribedText(result['text']?.toString() ?? '');
    return text;
  }

  static Future<RemoteValidationResult> processTurn({
    required String deviceId,
    required String incomingText,
    required Map<String, String> currentVehicleData,
    required List<Map<String, String>> chatHistory,
    List<String> currentImagePaths = const [],
  }) async {
    // Transport/authentication failures preserve the draft and are shown to the user.
    // They must never silently turn into a weaker validation path.
    final response = await RemoteApi.post(deviceId, {
      'action': 'process_turn',
      'incomingText': incomingText,
      'currentVehicleData': currentVehicleData,
      'chatHistory': chatHistory
          .skip(chatHistory.length > 10 ? chatHistory.length - 10 : 0)
          .map(
            (m) => {
              'role': m['role'],
              'text': (m['text'] ?? '').substring(
                0,
                (m['text'] ?? '').length.clamp(0, 2000),
              ),
            },
          )
          .toList(),
      'currentImageCount': currentImagePaths.length,
    });
    final vehicle = Map<String, String>.from(
      (response['vehicleData'] as Map).map(
        (k, v) => MapEntry(k.toString(), v.toString()),
      ),
    );
    final missing = VehicleSchema.missing(vehicle),
        errors = VehicleSchema.errors(vehicle);
    final complete = missing.isEmpty && errors.isEmpty;
    return RemoteValidationResult(
      vehicleData: vehicle,
      botReply: response['botReply']?.toString() ?? '',
      allDataFilled: complete,
      isReadyToPublish: complete && currentImagePaths.isNotEmpty,
      missingFields: missing,
      validationErrors: errors,
    );
  }
}
