import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../database/sqlite_database_helper.dart';
import '../webrtc/controller_webrtc_session.dart';
import 'whatsapp_chat_screen.dart';

enum ChatSessionStatus { draft, waiting, running, done, error }

class ChatSession {
  final String id;
  final String deviceId;
  String licensePlate;
  final int startTimestamp;
  ChatSessionStatus status;
  String? lastMessage;
  Map<String, String> vehicleData;
  List<String> imagePaths;
  int? expectedImageCount;
  bool isReadyToPublish;

  ChatSession({
    required this.id,
    required this.deviceId,
    this.licensePlate = '',
    required this.startTimestamp,
    this.status = ChatSessionStatus.draft,
    this.lastMessage,
    Map<String, String>? vehicleData,
    List<String>? imagePaths,
    this.expectedImageCount,
    this.isReadyToPublish = false,
  })  : vehicleData = vehicleData ?? {},
        imagePaths = imagePaths ?? [];

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'deviceId': deviceId,
      'licensePlate': licensePlate,
      'startTimestamp': startTimestamp,
      'status': status.name,
      'lastMessage': lastMessage,
      'vehicleDataJson': jsonEncode(vehicleData),
      'imagePathsJson': jsonEncode(imagePaths),
      'expectedImageCount': expectedImageCount,
      'isReadyToPublish': isReadyToPublish ? 1 : 0,
    };
  }

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    Map<String, String> vData = {};
    if (json['vehicleDataJson'] is String && (json['vehicleDataJson'] as String).isNotEmpty) {
      try {
        final decoded = jsonDecode(json['vehicleDataJson'] as String);
        if (decoded is Map) {
          vData = decoded.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
        }
      } catch (_) {}
    }

    List<String> imgs = [];
    if (json['imagePathsJson'] is String && (json['imagePathsJson'] as String).isNotEmpty) {
      try {
        final decoded = jsonDecode(json['imagePathsJson'] as String);
        if (decoded is List) {
          imgs = decoded.map((e) => e.toString()).toList();
        }
      } catch (_) {}
    }

    return ChatSession(
      id: json['id'] as String,
      deviceId: json['deviceId'] as String,
      licensePlate: json['licensePlate'] as String? ?? '',
      startTimestamp: json['startTimestamp'] as int,
      status: ChatSessionStatus.values.firstWhere(
        (e) => e.name == (json['status'] as String? ?? 'draft'),
        orElse: () => ChatSessionStatus.draft,
      ),
      lastMessage: json['lastMessage'] as String?,
      vehicleData: vData,
      imagePaths: imgs,
      expectedImageCount: json['expectedImageCount'] as int?,
      isReadyToPublish: json['isReadyToPublish'] == 1 || json['isReadyToPublish'] == true,
    );
  }
}

class ChatSessionManager {
  static Future<List<ChatSession>> getSessions(String deviceId) async {
    return await SqliteDatabaseHelper.instance.getSessions(deviceId);
  }

  static Future<void> saveSession(ChatSession session) async {
    await SqliteDatabaseHelper.instance.insertSession(session);
  }

  static Future<void> deleteSession(String deviceId, String sessionId) async {
    await SqliteDatabaseHelper.instance.deleteSession(sessionId);
  }
  
  static Future<ChatSession?> getNextWaitingSession(String deviceId) async {
    final sessions = await getSessions(deviceId);
    try {
      return sessions.firstWhere((s) => s.status == ChatSessionStatus.waiting);
    } catch (e) {
      return null; // None found
    }
  }

  /// Checks if any session is currently running on the worker. If not, advances the queue to the
  /// next waiting session, updates its status to running, and starts its publication.
  static Future<ChatSession?> advanceQueueAndStartNext(
    String deviceId, {
    ControllerWebRtcSession? session,
  }) async {
    final sessions = await getSessions(deviceId);
    
    // If there is already an active running session, do not start another concurrently.
    final running = sessions.where((s) => s.status == ChatSessionStatus.running).toList();
    if (running.isNotEmpty) {
      debugPrint('[ChatSessionManager] Session ${running.first.id} is already running on worker. Not advancing queue yet.');
      return null;
    }

    final nextSession = await getNextWaitingSession(deviceId);
    if (nextSession == null) {
      debugPrint('[ChatSessionManager] No waiting session in queue for $deviceId.');
      return null;
    }

    debugPrint('[ChatSessionManager] Advancing queue: starting session ${nextSession.id} (${nextSession.licensePlate})');
    nextSession.status = ChatSessionStatus.running;
    nextSession.lastMessage = 'מתחיל פרסום אוטומטי...';
    await saveSession(nextSession);

    // Asynchronously start publication
    unawaited(startPublication(deviceId, nextSession, session: session));

    return nextSession;
  }

  /// Manually starts a specific session
  static Future<void> startSession(String deviceId, String sessionId, {ControllerWebRtcSession? session}) async {
    final s = await SqliteDatabaseHelper.instance.getSession(sessionId);
    if (s != null) {
      s.status = ChatSessionStatus.running;
      s.lastMessage = 'מתחיל פרסום אוטומטי...';
      await saveSession(s);
      unawaited(startPublication(deviceId, s, session: session));
    }
  }

  /// Starts publication for a session: uploads images, packages the complete vehicle metadata,
  /// and sends the direct 'publish_vehicle' command to the worker phone.
  static Future<void> startPublication(
    String deviceId,
    ChatSession chatSession, {
    ControllerWebRtcSession? session,
  }) async {
    try {
      debugPrint('[ChatSessionManager] Starting publication for session: ${chatSession.id}, plate: ${chatSession.licensePlate}');
      
      final messages = await SqliteDatabaseHelper.instance.getMessages(chatSession.id);
      final userMessages = messages.where((m) => m.sender == ChatSender.user).toList();

      // Collect image file paths from both session object and SQLite messages
      final imagePathsSet = <String>{};
      imagePathsSet.addAll(chatSession.imagePaths);
      for (final m in userMessages) {
        if (m.mediaType == 'image' && m.localFilePath != null && m.localFilePath!.isNotEmpty) {
          imagePathsSet.add(m.localFilePath!);
        }
      }

      final uploadedImageIds = <String>[];

      // 1. Upload images from local disk to Firestore
      for (final imgPath in imagePathsSet) {
        final file = File(imgPath);
        if (file.existsSync()) {
          try {
            final bytes = await file.readAsBytes();
            final imgDocId = 'pub_img_${DateTime.now().millisecondsSinceEpoch}_${file.hashCode.abs()}';
            uploadedImageIds.add(imgDocId);
            
            const int maxSingleDocSize = 750 * 1024;
            const int chunkSize = 400 * 1024;

            final msgRef = FirebaseFirestore.instance
                .collection('remote_chats')
                .doc(deviceId)
                .collection('messages')
                .doc(imgDocId);

            if (bytes.length <= maxSingleDocSize) {
              await msgRef.set({
                'id': imgDocId,
                'sessionId': chatSession.id,
                'sender': 'user',
                'senderName': 'Remote User',
                'mediaType': 'image',
                'fileName': file.uri.pathSegments.isNotEmpty ? file.uri.pathSegments.last : 'image.jpg',
                'type': 'media',
                'status': 'pending',
                'mediaBlob': Blob(bytes),
                'totalChunks': 1,
                'fileSize': bytes.length,
                'timestamp': DateTime.now().millisecondsSinceEpoch,
                'createdAt': FieldValue.serverTimestamp(),
              });
            } else {
              final totalChunks = (bytes.length / chunkSize).ceil();
              await msgRef.set({
                'id': imgDocId,
                'sessionId': chatSession.id,
                'sender': 'user',
                'senderName': 'Remote User',
                'mediaType': 'image',
                'fileName': file.uri.pathSegments.isNotEmpty ? file.uri.pathSegments.last : 'image.jpg',
                'type': 'media',
                'status': 'uploading_chunks',
                'totalChunks': totalChunks,
                'fileSize': bytes.length,
                'timestamp': DateTime.now().millisecondsSinceEpoch,
                'createdAt': FieldValue.serverTimestamp(),
              });

              for (int i = 0; i < totalChunks; i++) {
                final start = i * chunkSize;
                final end = (start + chunkSize < bytes.length) ? start + chunkSize : bytes.length;
                final chunkBytes = bytes.sublist(start, end);
                await msgRef.collection('chunks').doc('$i').set({
                  'chunkIndex': i,
                  'totalChunks': totalChunks,
                  'blob': Blob(chunkBytes),
                  'createdAt': FieldValue.serverTimestamp(),
                });
              }
              await msgRef.update({'status': 'pending'});
            }
            await Future.delayed(const Duration(milliseconds: 300));
          } catch (e) {
            debugPrint('[ChatSessionManager] Error uploading publication image: $e');
          }
        }
      }

      // 2. Prepare full vehicle metadata map
      final vehicleMap = Map<String, String>.from(chatSession.vehicleData);
      if (chatSession.licensePlate.isNotEmpty) {
        vehicleMap['license_plate'] = chatSession.licensePlate;
        vehicleMap['license'] = chatSession.licensePlate;
      }
      vehicleMap['session_id'] = chatSession.id;
      vehicleMap['image_expected_count'] = '${uploadedImageIds.length}';
      vehicleMap['image_received_count'] = '${uploadedImageIds.length}';

      // 3. Send direct publish_vehicle command to the worker
      final pubCmdId = 'pub_cmd_${DateTime.now().millisecondsSinceEpoch}';
      await FirebaseFirestore.instance
          .collection('remote_chats')
          .doc(deviceId)
          .collection('messages')
          .doc(pubCmdId)
          .set({
            'id': pubCmdId,
            'sessionId': chatSession.id,
            'sender': 'user',
            'senderName': 'Remote User',
            'type': 'publish_vehicle',
            'status': 'pending',
            'vehicleData': vehicleMap,
            'imageDocIds': uploadedImageIds,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'createdAt': FieldValue.serverTimestamp(),
          });

      // Also send WebRTC action if active
      if (session?.isConnected == true) {
        try {
          session?.sendChatMessage('publish_vehicle:${jsonEncode(vehicleMap)}', senderName: 'Remote User');
        } catch (_) {}
      }

      chatSession.status = ChatSessionStatus.running;
      chatSession.lastMessage = 'תהליך פרסום נשלח למכשיר העובד';
      await saveSession(chatSession);
    } catch (e) {
      debugPrint('[ChatSessionManager] Error starting publication for session: $e');
    }
  }
}
