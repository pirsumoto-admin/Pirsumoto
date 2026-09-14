import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../services/whatsapp_text_validation_service.dart';
import 'remote_protocol.dart';
import 'remote_webrtc_receiver.dart';

class _IncomingMediaAssembly {
  final String mediaId;
  final String messageId;
  final String mediaType;
  final String fileName;
  final String? mimeType;
  final int totalChunks;
  final String? caption;
  final int timestamp;
  final Map<int, String> chunks = {};

  _IncomingMediaAssembly({
    required this.mediaId,
    required this.messageId,
    required this.mediaType,
    required this.fileName,
    this.mimeType,
    required this.totalChunks,
    this.caption,
    required this.timestamp,
  });

  bool get isComplete => chunks.length >= totalChunks;
}

class RemoteChatReceiver {
  static const String _whisperApiKey =
      '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';

  final RemoteWebRtcReceiver webrtc;
  final String deviceId;
  final String controllerId;

  late final String p2pSenderKey;

  final Map<String, _IncomingMediaAssembly> _activeMedia = {};

  RemoteChatReceiver({
    required this.webrtc,
    required this.deviceId,
    required this.controllerId,
  }) {
    p2pSenderKey = 'p2p_${deviceId}_$controllerId';
    _registerReplyHandlers();
  }

  void _registerReplyHandlers() {
    WhatsAppTextValidationService.registerReplySender(
      p2pSenderKey,
      _handleValidationReply,
    );
    WhatsAppTextValidationService.registerAutoPublishLauncher(
      _handleAutoPublishTriggered,
    );
  }

  void dispose() {
    WhatsAppTextValidationService.unregisterReplySender(p2pSenderKey);
    WhatsAppTextValidationService.unregisterAutoPublishLauncher(
      _handleAutoPublishTriggered,
    );
    _activeMedia.clear();
  }

  Future<bool> _handleValidationReply({
    required String senderKey,
    required String message,
  }) async {
    try {
      final replyCommand = RemoteChatReplyMessage(
        id: 'reply_${DateTime.now().millisecondsSinceEpoch}',
        text: message,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );
      webrtc.sendChatReply(replyCommand);
      return true;
    } catch (e) {
      debugPrint('[RemoteChatReceiver] Error sending reply: $e');
      return false;
    }
  }

  Future<bool> _handleAutoPublishTriggered(
    Map<String, String> vehicleData,
  ) async {
    try {
      webrtc.sendChatReply(
        RemoteChatStatusMessage(
          status: 'publishing',
          text: 'מתחיל תהליך פרסום אוטומטי ביד2...',
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return true;
    } catch (e) {
      debugPrint('[RemoteChatReceiver] Error sending auto-publish status: $e');
      return false;
    }
  }

  /// Process incoming RemoteCommand if it is a chat command
  Future<bool> handleIncomingCommand(RemoteCommand command) async {
    if (command is RemoteChatTextMessage) {
      await _handleIncomingTextMessage(command);
      return true;
    } else if (command is RemoteChatMediaChunk) {
      await _handleIncomingMediaChunk(command);
      return true;
    }
    return false;
  }

  Future<void> _handleIncomingTextMessage(RemoteChatTextMessage message) async {
    final text = message.text.trim();
    if (text.isEmpty) return;

    debugPrint(
      '[RemoteChatReceiver] Incoming chat text: "$text" from ${message.senderName ?? controllerId}',
    );

    webrtc.sendChatReply(
      RemoteChatStatusMessage(
        status: 'typing',
        text: 'מעבד הודעה...',
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );

    try {
      final updatedState =
          await WhatsAppTextValidationService.instance.handleIncomingTextMessage(
        text: text,
        senderKey: p2pSenderKey,
        senderName: message.senderName ?? 'Remote User',
        timestamp: message.timestamp,
      );

      debugPrint(
        '[RemoteChatReceiver] Handled text, session_status: ${updatedState?['session_status']}',
      );
    } catch (e) {
      debugPrint('[RemoteChatReceiver] Error handling text: $e');
      webrtc.sendChatReply(
        RemoteChatStatusMessage(
          status: 'error',
          text: 'שגיאה בעיבוד ההודעה: $e',
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
  }

  Future<void> _handleIncomingMediaChunk(RemoteChatMediaChunk chunk) async {
    final assembly = _activeMedia.putIfAbsent(
      chunk.mediaId,
      () => _IncomingMediaAssembly(
        mediaId: chunk.mediaId,
        messageId: chunk.messageId,
        mediaType: chunk.mediaType,
        fileName: chunk.fileName,
        mimeType: chunk.mimeType,
        totalChunks: chunk.totalChunks,
        caption: chunk.caption,
        timestamp: chunk.timestamp,
      ),
    );

    assembly.chunks[chunk.chunkIndex] = chunk.data;

    debugPrint(
      '[RemoteChatReceiver] Received chunk ${chunk.chunkIndex + 1}/${chunk.totalChunks} for ${chunk.fileName} (${assembly.mediaType})',
    );

    if (assembly.isComplete) {
      _activeMedia.remove(chunk.mediaId);
      await _processCompletedMedia(assembly);
    }
  }

  Future<void> _processCompletedMedia(_IncomingMediaAssembly assembly) async {
    try {
      webrtc.sendChatReply(
        RemoteChatStatusMessage(
          status: 'validating',
          text: 'מעבד קובץ ${assembly.fileName}...',
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      // Reassemble base64 chunks
      final bytesBuilder = BytesBuilder();
      for (int i = 0; i < assembly.totalChunks; i++) {
        final chunkBase64 = assembly.chunks[i];
        if (chunkBase64 != null && chunkBase64.isNotEmpty) {
          bytesBuilder.add(base64Decode(chunkBase64));
        }
      }
      final fileBytes = bytesBuilder.toBytes();

      // Save to local documents directory
      final appDir = await getApplicationDocumentsDirectory();
      final mediaDir = Directory('${appDir.path}/p2p_chat_media');
      if (!await mediaDir.exists()) {
        await mediaDir.create(recursive: true);
      }

      final ext = assembly.fileName.contains('.')
          ? assembly.fileName.split('.').last
          : (assembly.mediaType == 'audio' ? 'm4a' : 'jpg');
      final targetPath =
          '${mediaDir.path}/${DateTime.now().millisecondsSinceEpoch}_${assembly.mediaId}.$ext';
      final file = File(targetPath);
      await file.writeAsBytes(fileBytes);

      debugPrint(
        '[RemoteChatReceiver] Saved media to: $targetPath (${fileBytes.length} bytes)',
      );

      if (assembly.mediaType == 'audio') {
        await _processAudioFile(file, assembly);
      } else if (assembly.mediaType == 'image') {
        await _processImageFile(file, assembly);
      } else if (assembly.mediaType == 'video') {
        await _processVideoFile(file, assembly);
      }
    } catch (e, st) {
      debugPrint('[RemoteChatReceiver] Error processing media: $e\n$st');
      webrtc.sendChatReply(
        RemoteChatStatusMessage(
          status: 'error',
          text: 'שגיאה בעיבוד הקובץ ${assembly.fileName}: $e',
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
  }

  Future<void> _processAudioFile(
    File file,
    _IncomingMediaAssembly assembly,
  ) async {
    webrtc.sendChatReply(
      RemoteChatStatusMessage(
        status: 'transcribing',
        text: 'מפענח הודעה קולית (Whisper)...',
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );

    String? transcript;
    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('https://api.openai.com/v1/audio/transcriptions'),
      );
      request.headers['Authorization'] = 'Bearer $_whisperApiKey';
      request.fields['model'] = 'gpt-4o-mini-transcribe';
      request.fields['language'] = 'he';
      request.files.add(await http.MultipartFile.fromPath('file', file.path));

      final response = await request.send().timeout(const Duration(seconds: 30));
      final respStr = await response.stream.bytesToString();

      if (response.statusCode == 200) {
        final data = jsonDecode(respStr) as Map<String, dynamic>;
        transcript = data['text'] as String?;
      } else {
        debugPrint(
          '[RemoteChatReceiver] Whisper failed with code ${response.statusCode}: $respStr',
        );
      }
    } catch (e) {
      debugPrint('[RemoteChatReceiver] Whisper transcription error: $e');
    }

    if (transcript != null && transcript.trim().isNotEmpty) {
      final cleanText = transcript.trim();
      debugPrint('[RemoteChatReceiver] Audio transcribed: "$cleanText"');

      webrtc.sendChatReply(
        RemoteChatStatusMessage(
          status: 'validating',
          text: 'פוענח קולית: "$cleanText"',
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      // Feed transcribed text to WhatsApp validation service
      await WhatsAppTextValidationService.instance.handleIncomingTextMessage(
        text: cleanText,
        senderKey: p2pSenderKey,
        senderName: 'Remote User (Voice)',
        timestamp: assembly.timestamp,
      );
    } else {
      webrtc.sendChatReply(
        RemoteChatStatusMessage(
          status: 'error',
          text: 'לא הצלחתי לפענח את ההודעה הקולית. אנא נסו להקליט שוב או לכתוב בטקסט.',
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
  }

  Future<void> _processImageFile(
    File file,
    _IncomingMediaAssembly assembly,
  ) async {
    webrtc.sendChatReply(
      RemoteChatStatusMessage(
        status: 'validating',
        text: 'רושם תמונה במערכת...',
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );

    try {
      await WhatsAppTextValidationService.instance.handleIncomingImage(
        imageFilePath: file.path,
        senderKey: p2pSenderKey,
        senderName: 'Remote User',
        timestamp: assembly.timestamp,
      );

      // If caption was provided with the image, handle it as text
      if (assembly.caption != null && assembly.caption!.trim().isNotEmpty) {
        await WhatsAppTextValidationService.instance.handleIncomingTextMessage(
          text: assembly.caption!.trim(),
          senderKey: p2pSenderKey,
          senderName: 'Remote User',
          timestamp: assembly.timestamp,
        );
      }
    } catch (e) {
      debugPrint('[RemoteChatReceiver] Error handling image: $e');
    }
  }

  Future<void> _processVideoFile(
    File file,
    _IncomingMediaAssembly assembly,
  ) async {
    webrtc.sendChatReply(
      RemoteChatStatusMessage(
        status: 'done',
        text: 'סרטון וידאו התקבל ונשמר בהצלחה (${assembly.fileName})',
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );

    if (assembly.caption != null && assembly.caption!.trim().isNotEmpty) {
      await WhatsAppTextValidationService.instance.handleIncomingTextMessage(
        text: assembly.caption!.trim(),
        senderKey: p2pSenderKey,
        senderName: 'Remote User',
        timestamp: assembly.timestamp,
      );
    }
  }
}
