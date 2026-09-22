import 'dart:io';
import 'worker_backend.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'audio_service.g.dart';

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
      final file = File(audioPath);
      if (await file.length() > 8 * 1024 * 1024)
        throw StateError('Audio too large');
      final audio = await WorkerBackend.post({
        'action': 'transcribe_audio',
        'audioBase64': base64Encode(await file.readAsBytes()),
        'fileName': 'audio.m4a',
        'mimeType': 'audio/m4a',
      });
      final response = await WorkerBackend.post({
        'action': 'process_turn',
        'incomingText': audio['text'],
        'currentVehicleData': {},
        'chatHistory': [],
        'currentImageCount': 0,
      });
      final vehicle = Map<String, dynamic>.from(response['vehicleData'] as Map);
      return {
        ...vehicle,
        'license': vehicle['license_plate'],
        'kilometers': vehicle['km'],
      };
    } catch (e) {
      debugPrint('[AudioService] $e');
      return null;
    }
  }
}
