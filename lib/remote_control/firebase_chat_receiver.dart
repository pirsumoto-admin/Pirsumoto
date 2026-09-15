import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../services/whatsapp_text_validation_service.dart';

class FirebaseChatReceiver {
  static const String _whisperApiKey =
      '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';

  final FirebaseFirestore _firestore;
  final String deviceId;

  late final String p2pSenderKey;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _messagesSub;
  final Set<String> _processingMessageIds = {};

  FirebaseChatReceiver({
    FirebaseFirestore? firestore,
    required this.deviceId,
  }) : _firestore = firestore ?? FirebaseFirestore.instance {
    p2pSenderKey = 'p2p_$deviceId';
    _registerReplyHandlers();
  }

  CollectionReference<Map<String, dynamic>> get _messagesCollection =>
      _firestore.collection('remote_chats').doc(deviceId).collection('messages');

  void _registerReplyHandlers() {
    WhatsAppTextValidationService.registerReplySender(
      p2pSenderKey,
      _handleValidationReply,
    );
    WhatsAppTextValidationService.registerAutoPublishLauncher(
      _handleAutoPublishTriggered,
    );
    debugPrint('[FirebaseChatReceiver] Registered reply handlers for $p2pSenderKey');
  }

  /// Start listening for incoming user messages in Firestore
  void startListening() {
    _messagesSub?.cancel();
    debugPrint('[FirebaseChatReceiver] Starting Firestore listener for $deviceId messages');

    _messagesSub = _messagesCollection
        .where('sender', isEqualTo: 'user')
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .listen(
      (snapshot) {
        for (final change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.added ||
              change.type == DocumentChangeType.modified) {
            final doc = change.doc;
            final messageId = doc.id;
            if (!_processingMessageIds.contains(messageId)) {
              _processIncomingMessageDoc(doc);
            }
          }
        }
      },
      onError: (err) {
        debugPrint('[FirebaseChatReceiver] Firestore listener error: $err');
      },
    );
  }

  void dispose() {
    _messagesSub?.cancel();
    _messagesSub = null;
    WhatsAppTextValidationService.unregisterReplySender(p2pSenderKey);
    WhatsAppTextValidationService.unregisterAutoPublishLauncher(
      _handleAutoPublishTriggered,
    );
    _processingMessageIds.clear();
    debugPrint('[FirebaseChatReceiver] Disposed for device $deviceId');
  }

  Future<void> _processIncomingMessageDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    final messageId = doc.id;
    _processingMessageIds.add(messageId);

    try {
      final data = doc.data();
      if (data == null) return;

      // Mark as processing immediately so other listeners don't duplicate
      await doc.reference.update({'status': 'processing'});

      final text = data['text'] as String? ?? '';
      final mediaType = data['mediaType'] as String?;
      final fileName = data['fileName'] as String? ?? 'media_file';
      final caption = data['caption'] as String?;
      final senderName = data['senderName'] as String? ?? 'Remote User';
      final timestamp = data['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch;

      debugPrint(
        '[FirebaseChatReceiver] Processing message $messageId: type=$mediaType, text="$text"',
      );

      if (mediaType == 'audio') {
        await _sendStatusMessage(
          statusType: 'transcribing',
          text: 'מפענח הודעה קולית (Whisper)...',
        );

        final bytes = await _resolveMediaBytes(doc);
        if (bytes == null || bytes.isEmpty) {
          await _sendStatusMessage(
            statusType: 'error',
            text: 'שגיאה בקריאת קובץ השמע',
          );
          return;
        }

        final file = await _saveBytesToMediaFile(
          bytes: bytes,
          fileName: fileName,
          ext: 'm4a',
        );

        await _processIncomingAudio(
          file: file,
          timestamp: timestamp,
          senderName: senderName,
        );
      } else if (mediaType == 'image') {
        await _sendStatusMessage(
          statusType: 'validating',
          text: 'רושם תמונה במערכת...',
        );

        final bytes = await _resolveMediaBytes(doc);
        if (bytes == null || bytes.isEmpty) {
          await _sendStatusMessage(
            statusType: 'error',
            text: 'שגיאה בשמירת התמונה',
          );
          return;
        }

        final file = await _saveBytesToMediaFile(
          bytes: bytes,
          fileName: fileName,
          ext: 'jpg',
        );

        await _processIncomingImage(
          file: file,
          caption: caption,
          timestamp: timestamp,
          senderName: senderName,
        );
      } else if (mediaType == 'video') {
        final bytes = await _resolveMediaBytes(doc);
        if (bytes != null && bytes.isNotEmpty) {
          await _saveBytesToMediaFile(
            bytes: bytes,
            fileName: fileName,
            ext: 'mp4',
          );
          await _sendStatusMessage(
            statusType: 'done',
            text: 'סרטון וידאו התקבל ונשמר בהצלחה ($fileName)',
          );
        }
      } else {
        // Plain text message or reset command
        final trimmed = text.trim();
        final type = data['type'] as String? ?? 'message';
        if (type == 'reset' || trimmed == 'ביטול' || trimmed == 'לבטל') {
          debugPrint('[FirebaseChatReceiver] Resetting sender state for $p2pSenderKey');
          await WhatsAppTextValidationService.instance.clearSenderState(p2pSenderKey);
          await WhatsAppTextValidationService.instance.clearSenderState('p2p_$deviceId');
          await _sendStatusMessage(
            statusType: 'idle',
            text: 'הסשן אופס בהצלחה. שלח מספר רישוי להתחלת פרסום חדש.',
          );
        } else if (trimmed.isNotEmpty) {
          final updatedState = await WhatsAppTextValidationService.instance
              .handleIncomingTextMessage(
            text: trimmed,
            senderKey: p2pSenderKey,
            senderName: senderName,
            timestamp: timestamp,
          );
          debugPrint(
            '[FirebaseChatReceiver] Handled text for $messageId, session_status: ${updatedState?['session_status']}',
          );
        }
      }

      // Mark as processed and delete blob/base64 payload to keep Firestore storage clean
      await doc.reference.update({
        'status': 'processed',
        'processedAt': FieldValue.serverTimestamp(),
        'mediaBlob': FieldValue.delete(),
        'base64Data': FieldValue.delete(),
      });
    } catch (e, st) {
      debugPrint('[FirebaseChatReceiver] Error processing message $messageId: $e\n$st');
      try {
        await doc.reference.update({
          'status': 'error',
          'errorMessage': e.toString(),
        });
      } catch (_) {}
    } finally {
      _processingMessageIds.remove(messageId);
    }
  }

  Future<Uint8List?> _resolveMediaBytes(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    final data = doc.data();
    if (data == null) return null;

    // 1. Check direct native Blob field (no Base64 inflation)
    if (data['mediaBlob'] != null && data['mediaBlob'] is Blob) {
      return (data['mediaBlob'] as Blob).bytes;
    }

    // 2. Check chunks in subcollection (for files > 750KB)
    final totalChunks = data['totalChunks'] as int? ?? 1;
    if (totalChunks > 1) {
      debugPrint('[FirebaseChatReceiver] Fetching $totalChunks chunks for ${doc.id}...');
      final chunksQuery = await doc.reference
          .collection('chunks')
          .orderBy('chunkIndex', descending: false)
          .get();

      if (chunksQuery.docs.length >= totalChunks) {
        final builder = BytesBuilder();
        for (final chunkDoc in chunksQuery.docs) {
          final chunkData = chunkDoc.data();
          if (chunkData['blob'] is Blob) {
            builder.add((chunkData['blob'] as Blob).bytes);
          } else if (chunkData['base64'] is String) {
            builder.add(base64Decode(chunkData['base64'] as String));
          }
        }

        // Clean up chunks subcollection to keep Firestore completely clean
        for (final chunkDoc in chunksQuery.docs) {
          chunkDoc.reference.delete().ignore();
        }

        return builder.toBytes();
      } else {
        debugPrint(
          '[FirebaseChatReceiver] Chunks not all arrived yet: ${chunksQuery.docs.length}/$totalChunks',
        );
        return null;
      }
    }

    // 3. Fallback: Base64 string
    final base64Data = data['base64Data'] as String?;
    if (base64Data != null && base64Data.isNotEmpty) {
      return base64Decode(base64Data);
    }

    // 4. Fallback: mediaUrl
    final mediaUrl = data['mediaUrl'] as String?;
    if (mediaUrl != null && mediaUrl.isNotEmpty) {
      try {
        final resp = await http.get(Uri.parse(mediaUrl)).timeout(const Duration(seconds: 30));
        if (resp.statusCode == 200) {
          return resp.bodyBytes;
        }
      } catch (_) {}
    }

    return null;
  }

  Future<File> _saveBytesToMediaFile({
    required Uint8List bytes,
    required String fileName,
    required String ext,
  }) async {
    final appDir = await getApplicationDocumentsDirectory();
    final mediaDir = Directory('${appDir.path}/p2p_chat_media');
    if (!await mediaDir.exists()) {
      await mediaDir.create(recursive: true);
    }

    final cleanName = fileName.contains('.') ? fileName : '$fileName.$ext';
    final targetPath =
        '${mediaDir.path}/${DateTime.now().millisecondsSinceEpoch}_$cleanName';
    final file = File(targetPath);
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<void> _processIncomingAudio({
    required File file,
    required int timestamp,
    required String senderName,
  }) async {
    String? transcript;
    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('https://api.openai.com/v1/audio/transcriptions'),
      );
      request.headers['Authorization'] = 'Bearer $_whisperApiKey';
      request.fields['model'] = 'whisper-1';
      request.fields['language'] = 'he';
      request.fields['prompt'] =
          'מספר רכב בישראל (7 או 8 ספרות): 51-116-39, 12-345-67, 123-45-678. שלושים ותשע = 39 (ולא 309), חמישים ואחת = 51 (ולא 501). מאזדה, טויוטה, יונדאי, שנת, יד, קילומטראז, מחיר, צבע, פרסום ביד2 ללא נקודות.';
      request.files.add(await http.MultipartFile.fromPath('file', file.path));

      final response = await request.send().timeout(const Duration(seconds: 30));
      final respStr = await response.stream.bytesToString();

      if (response.statusCode == 200) {
        final resData = jsonDecode(respStr) as Map<String, dynamic>;
        transcript = resData['text'] as String?;
      } else {
        debugPrint(
          '[FirebaseChatReceiver] Whisper failed with code ${response.statusCode}: $respStr',
        );
      }
    } catch (e) {
      debugPrint('[FirebaseChatReceiver] Whisper transcription error: $e');
    }

    final rawTranscript = transcript?.trim() ?? '';
    final cleanText = WhatsAppTextValidationService.instance
        .normalizeTranscribedPlateText(rawTranscript);
    final hasLetters = RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(cleanText);

    if (cleanText.isNotEmpty && hasLetters) {
      debugPrint('[FirebaseChatReceiver] Audio transcribed: "$cleanText" (raw: "$rawTranscript")');

      await _sendStatusMessage(
        statusType: 'validating',
        text: 'פוענח קולית: "$cleanText"',
      );

      await WhatsAppTextValidationService.instance.handleIncomingTextMessage(
        text: cleanText,
        senderKey: p2pSenderKey,
        senderName: '$senderName (Voice)',
        timestamp: timestamp,
      );
    } else {
      await _sendStatusMessage(
        statusType: 'error',
        text: 'לא נקלט דיבור ברור בהקלטה. אנא נסו להקליט שוב או לשלוח כטקסט.',
      );
    }
  }

  Future<void> _processIncomingImage({
    required File file,
    String? caption,
    required int timestamp,
    required String senderName,
  }) async {
    try {
      await WhatsAppTextValidationService.instance.handleIncomingImage(
        imageFilePath: file.path,
        senderKey: p2pSenderKey,
        senderName: senderName,
        timestamp: timestamp,
      );

      if (caption != null && caption.trim().isNotEmpty) {
        await WhatsAppTextValidationService.instance.handleIncomingTextMessage(
          text: caption.trim(),
          senderKey: p2pSenderKey,
          senderName: senderName,
          timestamp: timestamp,
        );
      }
    } catch (e) {
      debugPrint('[FirebaseChatReceiver] Error handling image: $e');
      await _sendStatusMessage(
        statusType: 'error',
        text: 'שגיאה ברישום התמונה: $e',
      );
    }
  }

  Future<bool> _handleValidationReply({
    required String senderKey,
    required String message,
  }) async {
    try {
      final docId = 'reply_${DateTime.now().millisecondsSinceEpoch}';
      await _messagesCollection.doc(docId).set({
        'id': docId,
        'sender': 'bot',
        'type': 'reply',
        'text': message,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'createdAt': FieldValue.serverTimestamp(),
      });
      debugPrint('[FirebaseChatReceiver] Bot reply written to Firestore: "$message"');
      return true;
    } catch (e) {
      debugPrint('[FirebaseChatReceiver] Error writing reply to Firestore: $e');
      return false;
    }
  }

  Future<bool> _handleAutoPublishTriggered(
    Map<String, String> vehicleData,
  ) async {
    try {
      await _sendStatusMessage(
        statusType: 'publishing',
        text: 'הפרסום האוטומטי מתחיל כעת! פותח את יד2...',
      );
      return true;
    } catch (e) {
      debugPrint('[FirebaseChatReceiver] Error sending auto-publish status: $e');
      return false;
    }
  }

  Future<void> _sendStatusMessage({
    required String statusType,
    required String text,
  }) async {
    try {
      final docId = 'status_${DateTime.now().millisecondsSinceEpoch}';
      await _messagesCollection.doc(docId).set({
        'id': docId,
        'sender': 'bot',
        'type': 'status',
        'statusType': statusType,
        'text': text,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('[FirebaseChatReceiver] Error writing status to Firestore: $e');
    }
  }
}
