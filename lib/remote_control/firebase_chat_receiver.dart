import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../services/p2p_auto_publish_launcher.dart';
import '../services/whatsapp_text_validation_service.dart';

class FirebaseChatReceiver {
  final FirebaseFirestore _firestore;
  final String deviceId;

  late final String p2pSenderKey;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _messagesSub;
  final Set<String> _processingMessageIds = {};

  /// Concurrency guard on worker side: only 1 publication at a time
  static bool isPublishingActive = false;

  static String? currentSessionId;
  static String? currentDeviceId;

  static Future<void> reportAutomationStatus({
    required String statusType,
    required String text,
    String? sessionId,
    String? deviceId,
  }) async {
    final targetSessionId = sessionId ?? currentSessionId;
    final targetDeviceId = deviceId ?? currentDeviceId ?? 'mdm_device_01';
    try {
      final docId = 'status_${DateTime.now().millisecondsSinceEpoch}';
      await FirebaseFirestore.instance
          .collection('remote_chats')
          .doc(targetDeviceId)
          .collection('messages')
          .doc(docId)
          .set({
        'id': docId,
        'sessionId': targetSessionId,
        'sender': 'bot',
        'type': 'status',
        'statusType': statusType,
        'text': text,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'createdAt': FieldValue.serverTimestamp(),
      });
      debugPrint('[FirebaseChatReceiver] Automation status sent: $text (session: $targetSessionId)');
    } catch (e) {
      debugPrint('[FirebaseChatReceiver] Error reporting automation status: $e');
    }
  }

  FirebaseChatReceiver({
    FirebaseFirestore? firestore,
    required this.deviceId,
  }) : _firestore = firestore ?? FirebaseFirestore.instance {
    currentDeviceId = deviceId;
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
      final sessionId = data['sessionId'] as String?;
      final type = data['type'] as String? ?? 'message';

      final sessionKey = sessionId != null && sessionId.isNotEmpty 
          ? '${p2pSenderKey}_$sessionId' 
          : p2pSenderKey;

      debugPrint(
        '[FirebaseChatReceiver] Processing message $messageId: type=$type, mediaType=$mediaType, text="$text"',
      );

      // 1. Direct publish command from Remote Control ("The Brain")
      if (type == 'publish_vehicle') {
        currentSessionId = sessionId;
        currentDeviceId = deviceId;
        await _handleDirectPublishVehicle(doc, sessionId);
      } else if (mediaType == 'audio') {
        // Save media file if present without triggering legacy validation greetings
        final bytes = await _resolveMediaBytes(doc);
        if (bytes != null && bytes.isNotEmpty) {
          await _saveBytesToMediaFile(
            bytes: bytes,
            fileName: fileName,
            ext: 'm4a',
          );
        }
      } else if (mediaType == 'image') {
        // Save image locally so it is ready for publication without triggering validation greeting loops
        final bytes = await _resolveMediaBytes(doc);
        if (bytes != null && bytes.isNotEmpty) {
          await _saveBytesToMediaFile(
            bytes: bytes,
            fileName: fileName,
            ext: 'jpg',
          );
        }
      } else if (mediaType == 'video') {
        final bytes = await _resolveMediaBytes(doc);
        if (bytes != null && bytes.isNotEmpty) {
          await _saveBytesToMediaFile(
            bytes: bytes,
            fileName: fileName,
            ext: 'mp4',
          );
        }
      } else {
        // Plain text message or reset command
        final trimmed = text.trim();
        if (type == 'delete_session') {
          debugPrint('[FirebaseChatReceiver] Deleting session state for $sessionKey');
          isPublishingActive = false;
          WhatsAppTextValidationService.instance.stopAutomation();
          await WhatsAppTextValidationService.instance.clearSenderState(sessionKey);
          await WhatsAppTextValidationService.instance.clearLastVehicle(sessionKey);
        } else if (type == 'reset' || trimmed == 'ביטול' || trimmed == 'לבטל') {
          debugPrint('[FirebaseChatReceiver] Resetting sender state for $sessionKey');
          isPublishingActive = false;
          WhatsAppTextValidationService.instance.stopAutomation();
          await WhatsAppTextValidationService.instance.clearSenderState(sessionKey);
          await WhatsAppTextValidationService.instance.clearSenderState(p2pSenderKey);
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

  Future<void> _handleDirectPublishVehicle(
    DocumentSnapshot<Map<String, dynamic>> doc,
    String? sessionId,
  ) async {
    final data = doc.data();
    if (data == null) return;

    if (isPublishingActive) {
      debugPrint('[FirebaseChatReceiver] Rejecting publish: worker already busy');
      await _sendStatusMessage(
        statusType: 'busy',
        text: 'המכשיר כרגע מבצע פרסום אחר ביד2. הבקשה נדחתה כדי למנוע התנגשות.',
        sessionId: sessionId,
      );
      return;
    }

    isPublishingActive = true;
    try {
      final rawVehicleData = data['vehicleData'] as Map<String, dynamic>? ?? {};
      final vehicleData = rawVehicleData.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
      final imageDocIds = (data['imageDocIds'] as List?)?.map((e) => e.toString()).toList() ?? [];

      final plate = vehicleData['license_plate'] ?? vehicleData['license'] ?? 'ללא לוחית';
      final carTitle = [vehicleData['maker'] ?? '', vehicleData['model'] ?? '', vehicleData['year'] ?? '']
          .where((s) => s.isNotEmpty)
          .join(' ');

      await _sendStatusMessage(
        statusType: 'publishing',
        text: 'מתחיל פרסום ביד2 עבור $carTitle (רישוי $plate)...',
        sessionId: sessionId,
      );

      // Download / fetch uploaded images from Firestore if doc IDs are provided
      final localImagePaths = <String>[];
      for (final docId in imageDocIds) {
        try {
          final imgDoc = await _messagesCollection.doc(docId).get();
          if (imgDoc.exists) {
            final bytes = await _resolveMediaBytes(imgDoc);
            if (bytes != null && bytes.isNotEmpty) {
              final fileName = imgDoc.data()?['fileName'] as String? ?? 'img_$docId.jpg';
              final file = await _saveBytesToMediaFile(bytes: bytes, fileName: fileName, ext: 'jpg');
              localImagePaths.add(file.path);
            }
          }
        } catch (e) {
          debugPrint('[FirebaseChatReceiver] Error resolving publication image doc $docId: $e');
        }
      }

      if (localImagePaths.isNotEmpty) {
        vehicleData['image_paths'] = jsonEncode(localImagePaths);
        vehicleData['KEY_IMAGE_PATHS'] = jsonEncode(localImagePaths);
      }

      debugPrint('[FirebaseChatReceiver] Launching Yad2 publication with ${localImagePaths.length} images for $plate');
      final launched = await P2PAutoPublishLauncher.launch(vehicleData);

      if (launched) {
        await _sendStatusMessage(
          statusType: 'step',
          text: 'אוטומציית יד2 נפתחה בהצלחה וממלאת את הטופס...',
          sessionId: sessionId,
        );
      } else {
        await _sendStatusMessage(
          statusType: 'error',
          text: 'שגיאה בפתיחת מסך הפרסום של יד2.',
          sessionId: sessionId,
        );
        isPublishingActive = false;
      }
    } catch (e, st) {
      debugPrint('[FirebaseChatReceiver] Exception during direct publish: $e\n$st');
      await _sendStatusMessage(
        statusType: 'error',
        text: 'שגיאה לא צפויה בעת הרצת הפרסום: $e',
        sessionId: sessionId,
      );
      isPublishingActive = false;
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



  Future<bool> _handleValidationReply({
    required String senderKey,
    required String message,
  }) async {
    try {
      String? sessionId;
      if (senderKey.startsWith('${p2pSenderKey}_')) {
        sessionId = senderKey.substring(p2pSenderKey.length + 1);
      }

      final docId = 'reply_${DateTime.now().millisecondsSinceEpoch}';
      await _messagesCollection.doc(docId).set({
        'id': docId,
        'sessionId': sessionId,
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
      return false;
    } catch (e) {
      debugPrint('[FirebaseChatReceiver] Error sending auto-publish status: $e');
      return false;
    }
  }

  Future<void> _sendStatusMessage({
    required String statusType,
    required String text,
    String? sessionId,
  }) async {
    try {
      final docId = 'status_${DateTime.now().millisecondsSinceEpoch}';
      await _messagesCollection.doc(docId).set({
        'id': docId,
        'sessionId': sessionId,
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
