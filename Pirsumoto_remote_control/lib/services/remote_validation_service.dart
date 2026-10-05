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
  final List<String> governmentConflicts;

  const RemoteValidationResult({
    required this.vehicleData,
    required this.botReply,
    this.isReadyToPublish = false,
    this.allDataFilled = false,
    this.missingFields = const [],
    this.validationErrors = const [],
    this.governmentConflicts = const [],
  });
}

class RemoteValidationService {
  static const cloudFunctionUrl = RemoteApi.url;
  // Number interpretation happens per field on the server. Keep names and
  // the original Hebrew wording intact for review.
  static String normalizeTranscribedText(String text) => text.trim();
  static List<String> getMissingFields(Map<String, String> state) {
    final missing = VehicleSchema.missing(state).toList();
    final hasNoTest = {'true', 'כן', '1'}.contains(state['no_test']);
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

  static Future<Map<String, dynamic>?> transcribeAudio(
    File file, {
    required String deviceId,
    Map<String, String>? currentVehicleData,
  }) async {
    if (await file.length() > 8 * 1024 * 1024) {
      throw StateError('ההקלטה ארוכה מדי; נסה הקלטה קצרה יותר');
    }

    final result = await RemoteApi.post(deviceId, {
      'action': 'transcribe_audio',
      'audioBase64': base64Encode(await file.readAsBytes()),
      'mimeType': 'audio/mp4',
      'fileName': 'recording.m4a',
      'language': 'he',
      if (currentVehicleData != null) 'currentVehicleData': currentVehicleData,
    });
    final text = normalizeTranscribedText(result['text']?.toString() ?? '');
    return {
      'text': text,
      'extracted_fields':
          result['extracted_fields'] as Map<String, dynamic>? ?? {},
      'validation_errors': result['validation_errors'] as List<dynamic>? ?? [],
      'license_plate_candidates':
          result['license_plate_candidates'] as List<dynamic>? ?? [],
      'license_plate_fragments':
          result['license_plate_fragments'] as List<dynamic>? ?? [],
    };
  }

  static Future<RemoteValidationResult> processTurn({
    required String deviceId,
    required String incomingText,
    required Map<String, String> currentVehicleData,
    required List<Map<String, String>> chatHistory,
    List<String> currentImagePaths = const [],
    Map<String, String>? recordedAudioFields,
    String? confirmedAudioPlate,
  }) async {
    // Transport/authentication failures preserve the draft and are shown to the user.
    // They must never silently turn into a weaker validation path.
    final response = await RemoteApi.post(deviceId, {
      'action': recordedAudioFields == null ? 'process_turn' : 'merge_audio',
      if (recordedAudioFields != null) 'recordedFields': recordedAudioFields,
      if (confirmedAudioPlate != null)
        'confirmedLicensePlate': confirmedAudioPlate,
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
      governmentConflicts: [
        for (final conflict in response['governmentConflicts'] as List? ?? [])
          '${vehicleFieldLabels[conflict['field']] ?? conflict['field']}: '
              'בהקלטה ${conflict['approved']}; במשרד התחבורה ${conflict['government']}. '
              'הערך מההקלטה מוצג בטופס לבדיקה.',
      ],
    );
  }
}
