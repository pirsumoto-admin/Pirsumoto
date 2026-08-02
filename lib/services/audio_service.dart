import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'audio_service.g.dart';

const String _openAiApiKey =
    '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';
const String _openAiChatKey =
    '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';

@riverpod
AudioService audioService(Ref ref) {
  return AudioService();
}

class AudioService {
  final AudioRecorder _audioRecorder = AudioRecorder();

  Future<String?> startRecording() async {
    try {
      final hasPermission = await _audioRecorder.hasPermission();
      debugPrint('[AudioService] startRecording: hasPermission=$hasPermission');
      if (hasPermission) {
        final dir = await getApplicationDocumentsDirectory();
        final path = '${dir.path}/recording.m4a';
        debugPrint('[AudioService] startRecording: saving to $path');

        await _audioRecorder.start(
          const RecordConfig(encoder: AudioEncoder.aacLc),
          path: path,
        );
        debugPrint('[AudioService] startRecording: recorder started OK');
        return path;
      }
      debugPrint(
        '[AudioService] startRecording: MISSING microphone permission — recording not started',
      );
      return null;
    } catch (e, st) {
      debugPrint('[AudioService] startRecording ERROR: $e\n$st');
      return null;
    }
  }

  Future<String?> stopRecording() async {
    try {
      debugPrint('[AudioService] stopRecording: stopping...');
      final path = await _audioRecorder.stop();
      debugPrint('[AudioService] stopRecording: path=$path');
      if (path != null) {
        final file = File(path);
        final exists = await file.exists();
        final size = exists ? await file.length() : -1;
        debugPrint(
          '[AudioService] stopRecording: file exists=$exists size=${size}B',
        );
        if (size <= 0) {
          debugPrint(
            '[AudioService] stopRecording: WARNING — audio file is empty, transcription will likely fail',
          );
        }
      } else {
        debugPrint(
          '[AudioService] stopRecording: WARNING — stop() returned null path',
        );
      }
      return path;
    } catch (e, st) {
      debugPrint('[AudioService] stopRecording ERROR: $e\n$st');
      return null;
    }
  }

  void dispose() {
    _audioRecorder.dispose();
  }

  Future<Map<String, dynamic>?> processAudio(String audioPath) async {
    try {
      debugPrint('[AudioService] processAudio: start — path=$audioPath');

      // 1. Send to Whisper
      debugPrint('[AudioService] processAudio: sending to Whisper...');
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('https://api.openai.com/v1/audio/transcriptions'),
      );
      request.headers['Authorization'] = 'Bearer $_openAiApiKey';
      request.fields['model'] = 'gpt-4o-mini-transcribe';
      request.fields['language'] = 'he';
      request.files.add(await http.MultipartFile.fromPath('file', audioPath));

      final response = await request.send();
      debugPrint(
        '[AudioService] processAudio: Whisper response status=${response.statusCode}',
      );

      final respStr = await response.stream.bytesToString();
      debugPrint('[AudioService] processAudio: Whisper raw response=$respStr');

      if (response.statusCode != 200) {
        debugPrint(
          '[AudioService] processAudio: Whisper FAILED — status=${response.statusCode} body=$respStr',
        );
        throw Exception('Whisper failed: ${response.statusCode}');
      }

      final textData = jsonDecode(respStr);
      final transcript = textData['text'] as String;
      debugPrint('[AudioService] processAudio: transcript="$transcript"');

      // 2. Extract fields using GPT-4-turbo
      return await _convertResponseTextToFields(transcript);
    } catch (e, st) {
      debugPrint('[AudioService] processAudio ERROR: $e\n$st');
      return null;
    }
  }

  Future<Map<String, dynamic>?> _convertResponseTextToFields(
    String text,
  ) async {
    try {
      debugPrint(
        '[AudioService] _convertResponseTextToFields: sending to GPT-4-turbo, text="$text"',
      );
      final res = await http.post(
        Uri.parse('https://api.openai.com/v1/chat/completions'),
        headers: {
          'Authorization': 'Bearer $_openAiChatKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          "model": "gpt-4-turbo",
          "messages": [
            {
              "role": "system",
              "content":
                  "Extract structured car details from the Hebrew transcript and return a JSON response. Ensure all fields are included, even if values are missing, return null.",
            },
            {"role": "user", "content": text},
          ],
          "functions": [
            {
              "name": "extract_car_details",
              "description":
                  "Extract car details including registration number, mileage, and ownership from a Hebrew transcript.",
              "parameters": {
                "type": "object",
                "properties": {
                  "license": {
                    "type": "string",
                    "description":
                        "מספר רישוי (7-8 ספרות). יכול להופיע בתור 'מספר רכב', 'רישיון' או 'מספר'.",
                  },
                  "month": {
                    "type": "string",
                    "description":
                        "חודש עליה לכביש. חייב להיות מספר כטקסט בין '1' ל-'12'.",
                  },
                  "test": {
                    "type": "string",
                    "description": "תוקף טסט. חובה להחזיר במבנה 'MM,YYYY' לדוגמה '6,2025' או '12,2024'.",
                  },
                  "hand": {
                    "type": "string",
                    "enum": [
                      "יד ראשונה",
                      "יד שנייה",
                      "יד שלישית",
                      "יד רביעית",
                      "יד חמישית",
                      "יד שישית",
                      "יד שביעית",
                      "יד שמינית",
                      "יד תשיעית",
                      "יד עשירית"
                    ],
                    "description":
                        "מספר היד של הרכב. חייב להיות אחד מהערכים המוגדרים.",
                  },
                  "ownership": {
                    "type": "string",
                    "enum": [
                      "פרטית",
                      "חברה",
                      "השכרה",
                      "ליסינג",
                      "מונית",
                      "לימוד נהיגה",
                      "ייבוא אישי",
                      "ייבוא מקביל",
                      "ממשלתי",
                      "או״ם",
                      "השכרה / החכר"
                    ],
                    "description":
                        "סוג בעלות נוכחי. חייב להיות אחד מהערכים המוגדרים.",
                  },
                  "prevOwnership": {
                    "type": "string",
                    "enum": [
                      "פרטית",
                      "חברה",
                      "השכרה",
                      "ליסינג",
                      "מונית",
                      "לימוד נהיגה",
                      "ייבוא אישי",
                      "ייבוא מקביל",
                      "ממשלתי",
                      "או״ם",
                      "השכרה / החכר"
                    ],
                    "description":
                        "סוג בעלות קודמת. רק עבור כלי רכב יד שניה ומעלה.",
                  },
                  "km": {
                    "type": "integer",
                    "description": "כמות הקילומטרים ברכב (בין 1 ל-1,000,000).",
                  },
                  "price": {
                    "type": "integer",
                    "description": "המחיר של הרכב (בין 1,000 ל-1,000,000).",
                  },
                  "handicapped": {
                    "type": "string",
                    "enum": ["כן", "לא"],
                    "description":
                        "אם מופיע המונח 'מותאם לנכים' החזר 'כן', אחרת החזר 'לא'.",
                  },
                  "description": {
                    "type": "string",
                    "description":
                        "תיאור כללי של הרכב, לדוגמה: 'גוף נקי', 'ללא תאונות'.",
                  },
                },
              },
            },
          ],
          "function_call": {"name": "extract_car_details"},
        }),
      );

      debugPrint(
        '[AudioService] _convertResponseTextToFields: GPT response status=${res.statusCode}',
      );
      debugPrint(
        '[AudioService] _convertResponseTextToFields: GPT raw response=${res.body}',
      );

      if (res.statusCode != 200) {
        debugPrint(
          '[AudioService] _convertResponseTextToFields: GPT FAILED — status=${res.statusCode}',
        );
        throw Exception('GPT failed: ${res.statusCode}');
      }

      final data = jsonDecode(res.body);
      final argsStr =
          data['choices'][0]['message']['function_call']['arguments'];
      debugPrint(
        '[AudioService] _convertResponseTextToFields: extracted args=$argsStr',
      );
      final result = jsonDecode(argsStr);
      debugPrint(
        '[AudioService] _convertResponseTextToFields: final result=$result',
      );
      return result;
    } catch (e, st) {
      debugPrint('[AudioService] _convertResponseTextToFields ERROR: $e\n$st');
      return null;
    }
  }
}
