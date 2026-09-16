import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart' as intl;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../signaling/controller_signaling.dart';
import '../webrtc/controller_webrtc_session.dart';
import 'app_theme.dart';
import 'chat_message_bubble.dart';
import 'remote_control_screen.dart';

enum ChatSender { user, bot }

class ChatMessageItem {
  final String id;
  final ChatSender sender;
  final String text;
  final String? mediaType; // 'image', 'audio', 'video'
  final String? localFilePath;
  final String? mediaUrl;
  final String? caption;
  final DateTime timestamp;
  double uploadProgress;
  bool isUploading;
  Duration? audioDuration;

  ChatMessageItem({
    required this.id,
    required this.sender,
    this.text = '',
    this.mediaType,
    this.localFilePath,
    this.mediaUrl,
    this.caption,
    required this.timestamp,
    this.uploadProgress = 1.0,
    this.isUploading = false,
    this.audioDuration,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'sender': sender == ChatSender.user ? 'user' : 'bot',
      'text': text,
      'mediaType': mediaType,
      'localFilePath': localFilePath,
      'mediaUrl': mediaUrl,
      'caption': caption,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'audioDurationMs': audioDuration?.inMilliseconds,
    };
  }

  factory ChatMessageItem.fromJson(Map<String, dynamic> json) {
    return ChatMessageItem(
      id:
          json['id'] as String? ??
          'msg_${DateTime.now().millisecondsSinceEpoch}',
      sender: _readSender(json),
      text: json['text'] as String? ?? '',
      mediaType: json['mediaType'] as String?,
      localFilePath: json['localFilePath'] as String?,
      mediaUrl: json['mediaUrl'] as String?,
      caption: json['caption'] as String?,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        json['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      ),
      uploadProgress: 1.0,
      isUploading: false,
      audioDuration:
          json['audioDurationMs'] != null
              ? Duration(milliseconds: json['audioDurationMs'] as int)
              : null,
    );
  }

  static ChatSender _readSender(Map<String, dynamic> json) {
    // Keep explicit authorship, including user messages quoting the bot.
    if (json['sender'] == 'user') return ChatSender.user;
    if (json['sender'] == 'bot') return ChatSender.bot;
    for (final field in ['isFromUser', 'fromUser']) {
      if (json[field] is bool) {
        return json[field] == true ? ChatSender.user : ChatSender.bot;
      }
    }

    // Recover authorship in older saved messages without sender metadata.
    final text = (json['text'] as String? ?? '').trimLeft();
    if (RegExp(r'^🤖\s*פירסומוטו').hasMatch(text)) return ChatSender.bot;
    final id = json['id'] as String? ?? '';
    if (['msg_', 'img_', 'vid_', 'audio_'].any(id.startsWith)) {
      return ChatSender.user;
    }
    return ChatSender.bot;
  }
}

class WhatsAppChatScreen extends StatefulWidget {
  final String deviceId;
  final String deviceName;
  final ControllerWebRtcSession? session;

  const WhatsAppChatScreen({
    super.key,
    required this.deviceId,
    required this.deviceName,
    this.session,
  });

  @override
  State<WhatsAppChatScreen> createState() => _WhatsAppChatScreenState();
}

class _WhatsAppChatScreenState extends State<WhatsAppChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ImagePicker _picker = ImagePicker();
  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();

  final List<ChatMessageItem> _messages = [];
  StreamSubscription? _firestoreSub;
  StreamSubscription? _replySub;
  StreamSubscription? _playerStateSub;
  StreamSubscription? _playerPositionSub;

  bool _isRecording = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;
  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _deviceStatusStream;

  String? _playingAudioId;
  Duration _currentAudioPosition = Duration.zero;
  Duration _currentAudioDuration = Duration.zero;

  String get _storageKey => 'chat_messages_${widget.deviceId}';

  @override
  void initState() {
    super.initState();
    _deviceStatusStream = FirebaseFirestore.instance
        .collection('remote_control_devices')
        .doc(widget.deviceId)
        .snapshots(includeMetadataChanges: true);
    _listenToSessionEvents();
    _initAudioPlayerListeners();
    _loadMessagesFromPrefs();
  }

  Future<void> _loadMessagesFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_storageKey);
      if (jsonStr != null && jsonStr.isNotEmpty) {
        final List<dynamic> decoded = jsonDecode(jsonStr);
        final loaded =
            decoded
                .map(
                  (item) =>
                      ChatMessageItem.fromJson(item as Map<String, dynamic>),
                )
                .where((m) => !m.text.contains('תהליך הפרסום בוטל והסשן נסגר'))
                .toList();
        if (loaded.isNotEmpty) {
          if (!mounted) return;
          setState(() {
            final merged = {
              for (final message in _messages) message.id: message,
              // Saved messages retain local media paths.
              for (final message in loaded) message.id: message,
            };
            _messages.clear();
            _messages.addAll(merged.values);
            _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
          });
          _scrollToBottom();
          return;
        }
      }
    } catch (e) {
      debugPrint('[WhatsAppChat] Error loading messages from prefs: $e');
    }

    // Default: add initial welcome message if empty
    if (_messages.isEmpty && mounted) {
      setState(() {
        _addInitialWelcomeMessage();
      });
      _saveMessagesToPrefs();
    }
  }

  Future<void> _saveMessagesToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = _messages.map((m) => m.toJson()).toList();
      await prefs.setString(_storageKey, jsonEncode(data));
    } catch (e) {
      debugPrint('[WhatsAppChat] Error saving messages to prefs: $e');
    }
  }

  Future<void> _clearChatData() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: AppColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: AppColors.border),
            ),
            title: Text(
              'ניקוי השיחה ואתחול סשן',
              style: GoogleFonts.heebo(
                color: AppColors.onSurface,
                fontWeight: FontWeight.bold,
              ),
            ),
            content: Text(
              'פעולה זו תמחק את כל היסטוריית ההודעות ותאתחל סשן חדש ונקי מול המכשיר.',
              style: GoogleFonts.heebo(color: AppColors.secondary),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(
                  'ביטול',
                  style: GoogleFonts.heebo(color: AppColors.secondary),
                ),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.error,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: Text(
                  'ניקוי ואתחול',
                  style: GoogleFonts.heebo(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
    );

    if (confirm == true) {
      // 1. Immediately reset in-memory state & SharedPreferences
      setState(() {
        _messages.clear();
        _addInitialWelcomeMessage();
      });
      await _saveMessagesToPrefs();

      // 2. Batch-delete all Firestore messages for this device
      try {
        final msgs =
            await FirebaseFirestore.instance
                .collection('remote_chats')
                .doc(widget.deviceId)
                .collection('messages')
                .get();
        if (msgs.docs.isNotEmpty) {
          const chunkSize = 400;
          for (var i = 0; i < msgs.docs.length; i += chunkSize) {
            final batch = FirebaseFirestore.instance.batch();
            final end =
                (i + chunkSize < msgs.docs.length)
                    ? i + chunkSize
                    : msgs.docs.length;
            for (var j = i; j < end; j++) {
              batch.delete(msgs.docs[j].reference);
            }
            await batch.commit();
          }
        }
      } catch (e) {
        debugPrint('[WhatsAppChat] Error clearing Firestore messages: $e');
      }

      // 3. Send reset command to receiver via WebRTC if connected
      if (widget.session?.isConnected == true) {
        try {
          widget.session!.sendReset();
        } catch (_) {}
      }

      // 4. Send reset instruction to Firestore so FirebaseChatReceiver resets
      try {
        final messageId = 'reset_${DateTime.now().millisecondsSinceEpoch}';
        await FirebaseFirestore.instance
            .collection('remote_chats')
            .doc(widget.deviceId)
            .collection('messages')
            .doc(messageId)
            .set({
              'id': messageId,
              'sender': 'user',
              'type': 'reset',
              'text': '',
              'status': 'pending',
              'timestamp': DateTime.now().millisecondsSinceEpoch,
              'createdAt': FieldValue.serverTimestamp(),
            });
      } catch (_) {}

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'היסטוריית הצ\'אט נוקתה והסשן אותחל מחדש',
              style: GoogleFonts.inter(color: Colors.white),
            ),
            backgroundColor: const Color(0xFF1F2C34),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  void _addInitialWelcomeMessage() {
    _messages.add(
      ChatMessageItem(
        id: 'welcome_1',
        sender: ChatSender.bot,
        text:
            'שלום! 👋 אני הבוט של פירסומוטו.\nכדי להתחיל פרסום רכב, שלח מספר רישוי ישראלי (7 או 8 ספרות), או הקלט הודעה קולית עם פרטי הרכב.',
        timestamp: DateTime.now(),
      ),
    );
  }

  void _listenToSessionEvents() {
    // 1. Listen to Firestore messages (persistent cloud channel - works without WebRTC)
    final messagesStream =
        FirebaseFirestore.instance
            .collection('remote_chats')
            .doc(widget.deviceId)
            .collection('messages')
            .orderBy('timestamp', descending: false)
            .snapshots();

    _firestoreSub = messagesStream.listen((snapshot) {
      if (!mounted) return;
      bool hasChanges = false;
      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final data = change.doc.data();
          if (data == null) continue;
          final id = data['id'] as String? ?? change.doc.id;
          final sender = data['sender'] as String? ?? '';
          final type = data['type'] as String? ?? 'message';

          if (type == 'status' || type == 'reset') continue;

          final text = (data['text'] as String? ?? '').trim();
          if (text.contains('תהליך הפרסום בוטל והסשן נסגר')) continue;

          if (sender == 'bot' || sender == 'user') {
            final ts =
                data['timestamp'] as int? ??
                DateTime.now().millisecondsSinceEpoch;
            if (!_messages.any((m) => m.id == id)) {
              if (_messages.length == 1 && _messages.first.id == 'welcome_1') {
                _messages.clear();
              }
              _messages.add(
                ChatMessageItem.fromJson({...data, 'id': id, 'timestamp': ts}),
              );
              hasChanges = true;
            }
          }
        } else if (change.type == DocumentChangeType.removed) {
          final id = change.doc.id;
          if (_messages.any((m) => m.id == id)) {
            _messages.removeWhere((m) => m.id == id);
            hasChanges = true;
          }
        }
      }
      if (hasChanges) {
        if (_messages.isEmpty) {
          _addInitialWelcomeMessage();
        }
        _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        setState(() {});
        _scrollToBottom();
        _saveMessagesToPrefs();
      }
    });

    // 2. If WebRTC session is active, also listen to direct data channel events
    if (widget.session != null) {
      _replySub = widget.session!.chatReplies.listen((reply) {
        if (!mounted) return;
        if (reply.text.trim().contains('תהליך הפרסום בוטל והסשן נסגר')) return;
        if (!_messages.any((m) => m.id == reply.id)) {
          if (_messages.length == 1 && _messages.first.id == 'welcome_1') {
            _messages.clear();
          }
          setState(() {
            _messages.add(
              ChatMessageItem(
                id: reply.id,
                sender: ChatSender.bot,
                text: reply.text,
                timestamp: DateTime.fromMillisecondsSinceEpoch(reply.timestamp),
              ),
            );
          });
          _scrollToBottom();
          _saveMessagesToPrefs();
        }
      });
    }
  }

  void _initAudioPlayerListeners() {
    _playerStateSub = _audioPlayer.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      if (state == PlayerState.completed || state == PlayerState.stopped) {
        setState(() {
          _playingAudioId = null;
          _currentAudioPosition = Duration.zero;
        });
      }
    });

    _playerPositionSub = _audioPlayer.onPositionChanged.listen((pos) {
      if (!mounted) return;
      setState(() {
        _currentAudioPosition = pos;
      });
    });

    _audioPlayer.onDurationChanged.listen((dur) {
      if (!mounted) return;
      setState(() {
        _currentAudioDuration = dur;
      });
    });
  }

  @override
  void dispose() {
    _firestoreSub?.cancel();
    _replySub?.cancel();
    _playerStateSub?.cancel();
    _playerPositionSub?.cancel();
    _recordTimer?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent + 80,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // --- Sending Actions ---

  Future<void> _sendMediaFileToFirebase({
    required File file,
    required String mediaType,
    required ChatMessageItem msgItem,
    String? caption,
  }) async {
    try {
      final bytes = await file.readAsBytes();
      final msgRef = FirebaseFirestore.instance
          .collection('remote_chats')
          .doc(widget.deviceId)
          .collection('messages')
          .doc(msgItem.id);

      const int maxSingleDocSize =
          750 * 1024; // 750 KB safe limit for single doc
      const int chunkSize = 400 * 1024; // 400 KB per chunk document

      if (bytes.length <= maxSingleDocSize) {
        // --- Path 1: Single document with native Blob (0% overhead, raw bytes) ---
        if (mounted) {
          setState(() => msgItem.uploadProgress = 0.6);
        }

        await msgRef.set({
          'id': msgItem.id,
          'sender': 'user',
          'senderName': 'Remote User',
          'text': caption ?? '',
          'mediaType': mediaType,
          'mediaBlob': Blob(bytes),
          'fileName': file.uri.pathSegments.last,
          'caption': caption,
          'type': 'media',
          'status': 'pending',
          'totalChunks': 1,
          'fileSize': bytes.length,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'createdAt': FieldValue.serverTimestamp(),
        });
      } else {
        // --- Path 2: File > 750KB: Use Subcollection Chunks with native Blob ---
        final totalChunks = (bytes.length / chunkSize).ceil();
        debugPrint(
          '[WhatsAppChat] File size ${bytes.length} bytes exceeds 750KB. Uploading in $totalChunks chunks...',
        );

        // Write parent message first with status: uploading_chunks
        await msgRef.set({
          'id': msgItem.id,
          'sender': 'user',
          'senderName': 'Remote User',
          'text': caption ?? '',
          'mediaType': mediaType,
          'fileName': file.uri.pathSegments.last,
          'caption': caption,
          'type': 'media',
          'status': 'uploading_chunks',
          'totalChunks': totalChunks,
          'fileSize': bytes.length,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'createdAt': FieldValue.serverTimestamp(),
        });

        // Write each chunk with its own Blob
        for (int i = 0; i < totalChunks; i++) {
          final start = i * chunkSize;
          final end =
              (start + chunkSize < bytes.length)
                  ? start + chunkSize
                  : bytes.length;
          final chunkBytes = bytes.sublist(start, end);

          await msgRef.collection('chunks').doc('$i').set({
            'chunkIndex': i,
            'totalChunks': totalChunks,
            'blob': Blob(chunkBytes),
            'createdAt': FieldValue.serverTimestamp(),
          });

          if (mounted) {
            setState(() {
              msgItem.uploadProgress = (i + 1) / (totalChunks + 1);
            });
          }
        }

        // Mark parent message as pending now that all chunks are uploaded
        await msgRef.update({'status': 'pending'});
      }

      if (mounted) {
        setState(() {
          msgItem.uploadProgress = 1.0;
          msgItem.isUploading = false;
        });
        _saveMessagesToPrefs();
      }
    } catch (e) {
      debugPrint('[WhatsAppChat] Error sending media: $e');
      if (mounted) {
        setState(() {
          msgItem.isUploading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('שגיאה בשליחת קובץ: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _sendTextMessage([String? presetText]) async {
    final text = (presetText ?? _textController.text).trim();
    if (text.isEmpty) return;

    if (presetText == null) {
      _textController.clear();
    }

    final messageId = 'msg_${DateTime.now().millisecondsSinceEpoch}';
    final userMessage = ChatMessageItem(
      id: messageId,
      sender: ChatSender.user,
      text: text,
      timestamp: DateTime.now(),
    );

    setState(() {
      _messages.add(userMessage);
    });
    _scrollToBottom();
    _saveMessagesToPrefs();

    try {
      await FirebaseFirestore.instance
          .collection('remote_chats')
          .doc(widget.deviceId)
          .collection('messages')
          .doc(messageId)
          .set({
            'id': messageId,
            'sender': 'user',
            'senderName': 'Remote User',
            'text': text,
            'type': 'message',
            'status': 'pending',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'createdAt': FieldValue.serverTimestamp(),
          });
    } catch (e) {
      debugPrint('[WhatsAppChat] Error sending text to Firestore: $e');
    }

    if (widget.session?.isConnected == true) {
      try {
        widget.session!.sendChatMessage(text, senderName: 'Remote User');
      } catch (_) {}
    }
  }

  Future<void> _sendSingleImageFile(File file) async {
    final messageId =
        'img_${DateTime.now().millisecondsSinceEpoch}_${file.hashCode.abs()}';

    final msgItem = ChatMessageItem(
      id: messageId,
      sender: ChatSender.user,
      mediaType: 'image',
      localFilePath: file.path,
      timestamp: DateTime.now(),
      isUploading: true,
      uploadProgress: 0.05,
    );

    setState(() {
      _messages.add(msgItem);
    });
    _scrollToBottom();
    _saveMessagesToPrefs();

    await _sendMediaFileToFirebase(
      file: file,
      mediaType: 'image',
      msgItem: msgItem,
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
        source: source,
        imageQuality: 85,
        maxWidth: 1920,
      );
      if (picked == null) return;
      await _sendSingleImageFile(File(picked.path));
    } catch (e) {
      debugPrint('[WhatsAppChat] Pick image failed: $e');
    }
  }

  Future<void> _pickMultiImage() async {
    try {
      final pickedList = await _picker.pickMultiImage(
        imageQuality: 85,
        maxWidth: 1920,
      );
      if (pickedList.isEmpty) return;

      for (final picked in pickedList) {
        await _sendSingleImageFile(File(picked.path));
        await Future.delayed(const Duration(milliseconds: 120));
      }
    } catch (e) {
      debugPrint('[WhatsAppChat] Pick multi image failed: $e');
    }
  }

  Future<void> _pickVideo() async {
    try {
      final picked = await _picker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 2),
      );
      if (picked == null) return;

      final file = File(picked.path);
      final messageId = 'vid_${DateTime.now().millisecondsSinceEpoch}';

      final msgItem = ChatMessageItem(
        id: messageId,
        sender: ChatSender.user,
        mediaType: 'video',
        localFilePath: file.path,
        timestamp: DateTime.now(),
        isUploading: true,
        uploadProgress: 0.05,
      );

      setState(() {
        _messages.add(msgItem);
      });
      _scrollToBottom();
      _saveMessagesToPrefs();

      await _sendMediaFileToFirebase(
        file: file,
        mediaType: 'video',
        msgItem: msgItem,
      );
    } catch (e) {
      debugPrint('[WhatsAppChat] Pick video failed: $e');
    }
  }

  // --- Voice Recording ---

  Future<void> _startRecording() async {
    try {
      final hasPermission = await _audioRecorder.hasPermission();
      if (!hasPermission) return;

      final tempDir = await getTemporaryDirectory();
      final path =
          '${tempDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';

      await _audioRecorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 32000),
        path: path,
      );

      setState(() {
        _isRecording = true;
        _recordSeconds = 0;
      });

      _recordTimer?.cancel();
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() => _recordSeconds++);
        }
      });
    } catch (e) {
      debugPrint('[WhatsAppChat] Start recording error: $e');
    }
  }

  Future<void> _stopAndSendRecording({bool cancel = false}) async {
    _recordTimer?.cancel();
    _recordTimer = null;

    try {
      final path = await _audioRecorder.stop();
      setState(() => _isRecording = false);

      if (cancel || path == null) {
        if (path != null) {
          final f = File(path);
          if (await f.exists()) await f.delete();
        }
        return;
      }

      final file = File(path);
      if (!await file.exists() || await file.length() < 100) return;

      final messageId = 'audio_${DateTime.now().millisecondsSinceEpoch}';
      final recordedDur = Duration(seconds: _recordSeconds);

      final msgItem = ChatMessageItem(
        id: messageId,
        sender: ChatSender.user,
        mediaType: 'audio',
        localFilePath: file.path,
        timestamp: DateTime.now(),
        isUploading: true,
        uploadProgress: 0.05,
        audioDuration: recordedDur,
      );

      setState(() {
        _messages.add(msgItem);
      });
      _scrollToBottom();
      _saveMessagesToPrefs();

      await _sendMediaFileToFirebase(
        file: file,
        mediaType: 'audio',
        msgItem: msgItem,
      );
    } catch (e) {
      debugPrint('[WhatsAppChat] Stop recording error: $e');
      setState(() => _isRecording = false);
    }
  }

  Future<void> _toggleAudioPlay(ChatMessageItem item) async {
    if (item.localFilePath == null) return;

    if (_playingAudioId == item.id) {
      await _audioPlayer.pause();
      setState(() => _playingAudioId = null);
    } else {
      await _audioPlayer.stop();
      await _audioPlayer.play(DeviceFileSource(item.localFilePath!));
      setState(() {
        _playingAudioId = item.id;
      });
    }
  }

  void _showAttachmentMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Wrap(
              alignment: WrapAlignment.spaceAround,
              spacing: 24,
              runSpacing: 20,
              children: [
                _buildAttachmentTile(
                  icon: Icons.camera_alt_rounded,
                  color: AppColors.primaryAction,
                  label: 'מצלמה',
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickImage(ImageSource.camera);
                  },
                ),
                _buildAttachmentTile(
                  icon: Icons.photo_library_rounded,
                  color: AppColors.primary,
                  label: 'גלריה (תמונות)',
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickMultiImage();
                  },
                ),
                _buildAttachmentTile(
                  icon: Icons.videocam_rounded,
                  color: AppColors.windows,
                  label: 'סרטון וידאו',
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickVideo();
                  },
                ),
                _buildAttachmentTile(
                  icon: Icons.directions_car_rounded,
                  color: AppColors.success,
                  label: 'תבנית רכב',
                  onTap: () {
                    Navigator.pop(ctx);
                    _textController.text =
                        'מאזדה 3 שנת 2020 יד 1 65000 קמ 72000 שח';
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAttachmentTile({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: color.withValues(alpha: 0.15),
            child: Icon(icon, color: color, size: 28),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: GoogleFonts.heebo(
              color: AppColors.onSurface,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _switchToRemoteControl() async {
    ControllerWebRtcSession? session = widget.session;
    if (session == null || !session.isConnected) {
      try {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('מתחבר לשליטה מרחוק במסך (WebRTC)...'),
            duration: Duration(seconds: 2),
            backgroundColor: Color(0xFF1F2C34),
          ),
        );
        final user = FirebaseAuth.instance.currentUser;
        final controllerId =
            user?.displayName ??
            'Controller_${DateTime.now().millisecondsSinceEpoch % 1000}';
        final signaling = ControllerSignalingClient(
          deviceId: widget.deviceId,
          controllerId: controllerId,
        );
        session = ControllerWebRtcSession(
          signaling: signaling,
          sessionType: 'remote_control',
        );
        await session.initRenderer();
        session.connect();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('שגיאה בהתחברות לשליטה מרחוק: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
    }

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => RemoteControlScreen(
              session: session!,
              deviceName: widget.deviceName,
            ),
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.neutral,
      appBar: _buildAppBar(),
      body: Column(
        children: [
          // Date Separator Pill ("היום")
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.surfaceSubtle,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(
              'היום',
              style: GoogleFonts.heebo(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppColors.secondary,
              ),
            ),
          ),

          // Messages List
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final message = _messages[index];
                return _buildMessageBubble(message);
              },
            ),
          ),

          // Bottom Input Bar
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildConnectionStatus() {
    Widget label(String text) => Text(
      text,
      style: GoogleFonts.heebo(
        fontSize: 11.5,
        fontWeight: FontWeight.w500,
        color: AppColors.success,
      ),
    );

    final session = widget.session;
    if (session != null) {
      return ListenableBuilder(
        listenable: session,
        builder:
            (context, _) => label(
              session.isConnected
                  ? 'מחובר'
                  : session.isConnecting
                  ? 'מתחבר'
                  : 'מנותק',
            ),
      );
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _deviceStatusStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return label('מתחבר');
        }
        final device = snapshot.data;
        final status = device?.data()?['status'];
        final connected =
            !snapshot.hasError &&
            device != null &&
            !device.metadata.isFromCache &&
            ['online', 'idle', 'ready', 'connected'].contains(status);
        return label(connected ? 'מחובר' : 'מנותק');
      },
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return PreferredSize(
      preferredSize: const Size.fromHeight(62),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(bottom: BorderSide(color: AppColors.border, width: 1)),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                // 1. Back button with arrow pointing to the LEFT (mirrored direction as requested)
                InkWell(
                  onTap: () => Navigator.of(context).pop(),
                  borderRadius: BorderRadius.circular(20),
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(
                      Icons
                          .arrow_back_ios_new_rounded, // Mirrored to point left
                      color: AppColors.onSurface,
                      size: 20,
                    ),
                  ),
                ),
                const SizedBox(width: 4),

                // 2. Avatar
                CircleAvatar(
                  radius: 19,
                  backgroundColor: AppColors.android.withValues(alpha: 0.12),
                  child: const Icon(
                    Icons.android_rounded,
                    color: AppColors.android,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 10),

                // 3. Title & Connection Status
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.deviceName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.heebo(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppColors.onSurface,
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColors.success,
                            ),
                          ),
                          const SizedBox(width: 5),
                          _buildConnectionStatus(),
                        ],
                      ),
                    ],
                  ),
                ),

                // 4. "שליטה" Button (Monitor icon)
                InkWell(
                  onTap: _switchToRemoteControl,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.screen_share_outlined,
                          color: AppColors.onSurface,
                          size: 22,
                        ),
                        Text(
                          'שליטה',
                          style: GoogleFonts.heebo(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppColors.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),

                // 5. "ניקוי" Button (Trash icon)
                InkWell(
                  onTap: _clearChatData,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.delete_outline_rounded,
                          color: AppColors.onSurface,
                          size: 22,
                        ),
                        Text(
                          'ניקוי',
                          style: GoogleFonts.heebo(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppColors.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessageItem message) {
    final isUser = message.sender == ChatSender.user;
    final timeStr = intl.DateFormat('HH:mm').format(message.timestamp);
    final isAdDraft =
        !isUser &&
        (message.text.contains('המודעה מוכנה') ||
            message.text.contains('טיוטה'));

    return ChatMessageBubble(
      isUser: isUser,
      time: timeStr,
      isUploading: message.isUploading,
      child: Column(
        textDirection: TextDirection.rtl,
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Media Display (Images, Audio, Video)
          if (message.mediaType == 'image' &&
              (message.localFilePath != null || message.mediaUrl != null))
            _buildImageMessageContent(message),

          if (message.mediaType == 'audio' && message.localFilePath != null)
            _buildAudioMessageContent(message),

          if (message.mediaType == 'video' && message.localFilePath != null)
            _buildVideoMessageContent(message),

          // Ad Card Preview (if message is ad ready)
          if (isAdDraft) ...[_buildAdDraftCard(), const SizedBox(height: 6)],

          // Text content
          if (message.text.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(
                top: message.mediaType != null || isAdDraft ? 6 : 2,
                bottom: 2,
              ),
              child: Text(
                message.text,
                textAlign: TextAlign.right,
                textDirection: TextDirection.rtl,
                style: GoogleFonts.heebo(
                  fontSize: 15,
                  color: AppColors.onSurface,
                  height: 1.4,
                ),
              ),
            ),

          // Bot Quick Action Chips
          if (!isUser && _hasActionOptions(message.text))
            _buildQuickActionChips(message.text),
        ],
      ),
    );
  }

  Widget _buildAdDraftCard() {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: AppColors.surfaceSubtle,
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Vehicle Image Preview with live text overlay badge
          Stack(
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Image.asset(
                  'assets/images/login-hero.jpg',
                  fit: BoxFit.cover,
                  errorBuilder:
                      (_, _, _) => Container(
                        color: AppColors.primarySoft,
                        child: const Center(
                          child: Icon(
                            Icons.directions_car_rounded,
                            size: 40,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primaryAction,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'חדש במלאי',
                    style: GoogleFonts.heebo(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'הרכב הבא שלך מחכה',
                  style: GoogleFonts.heebo(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'רכבים איכותיים. אנשים מאושרים יותר.',
                  style: GoogleFonts.heebo(
                    fontSize: 12,
                    color: AppColors.secondary,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(
                      Icons.check_box_rounded,
                      color: AppColors.success,
                      size: 16,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      'הטיוטה נשמרה',
                      style: GoogleFonts.heebo(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.success,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _hasActionOptions(String text) {
    return text.contains('0 לפרסום') ||
        text.contains('לפרסום שלח 0') ||
        text.contains('לפרסום') ||
        text.contains('פרסם עכשיו') ||
        text.contains('מוכנים לפרסום') ||
        text.contains('ביטול') ||
        text.contains('המשך') ||
        text.contains('שליטה מרחוק') ||
        text.contains('Remote Control') ||
        text.contains('התערבות') ||
        text.contains('נתקעה') ||
        text.contains('תמונות') ||
        text.contains('תמונה') ||
        text.contains('להעלות') ||
        text.contains('התקבלו') ||
        text.contains('התקבלה') ||
        text.contains('נקלטה תמונה');
  }

  Widget _buildQuickActionChips(String text) {
    final chips = <Widget>[];

    final asksForImages =
        text.contains('תמונות') ||
        text.contains('תמונה') ||
        text.contains('להעלות') ||
        text.contains('התקבלו') ||
        text.contains('התקבלה') ||
        text.contains('נקלטה תמונה');

    if (asksForImages) {
      chips.add(
        ActionChip(
          backgroundColor: AppColors.primarySoft,
          side: const BorderSide(color: AppColors.primaryAction, width: 0.8),
          avatar: const Icon(
            Icons.photo_library_rounded,
            size: 14,
            color: AppColors.primaryAction,
          ),
          label: Text(
            'העלה תמונות (גלריה)',
            style: GoogleFonts.heebo(
              color: AppColors.primaryAction,
              fontSize: 11.5,
              fontWeight: FontWeight.bold,
            ),
          ),
          onPressed: _pickMultiImage,
        ),
      );
      chips.add(
        ActionChip(
          backgroundColor: AppColors.surface,
          side: const BorderSide(color: AppColors.border),
          avatar: const Icon(
            Icons.camera_alt_rounded,
            size: 14,
            color: AppColors.primaryAction,
          ),
          label: Text(
            'צלם תמונה',
            style: GoogleFonts.heebo(
              color: AppColors.primaryAction,
              fontSize: 11.5,
            ),
          ),
          onPressed: () => _pickImage(ImageSource.camera),
        ),
      );
    }

    if (text.contains('שליטה מרחוק') ||
        text.contains('Remote Control') ||
        text.contains('התערבות') ||
        text.contains('נתקעה')) {
      chips.add(
        ActionChip(
          backgroundColor: AppColors.errorSoft,
          side: BorderSide(color: AppColors.error.withValues(alpha: 0.3)),
          avatar: const Icon(
            Icons.screen_share_rounded,
            size: 14,
            color: AppColors.error,
          ),
          label: Text(
            'עבור לשליטה מרחוק',
            style: GoogleFonts.heebo(
              color: AppColors.error,
              fontSize: 11.5,
              fontWeight: FontWeight.bold,
            ),
          ),
          onPressed: _switchToRemoteControl,
        ),
      );
    }

    if (text.contains('0') ||
        text.contains('לפרסום') ||
        text.contains('מוכנים לפרסום') ||
        text.contains('פרסם עכשיו')) {
      chips.add(
        ActionChip(
          backgroundColor: AppColors.successSoft,
          side: const BorderSide(color: AppColors.success, width: 0.8),
          avatar: const Icon(Icons.publish, size: 14, color: AppColors.success),
          label: Text(
            'פרסם עכשיו (0)',
            style: GoogleFonts.heebo(
              color: AppColors.success,
              fontSize: 11.5,
              fontWeight: FontWeight.bold,
            ),
          ),
          onPressed: () => _sendTextMessage('0'),
        ),
      );
    }

    if (text.contains('המשך')) {
      chips.add(
        ActionChip(
          backgroundColor: AppColors.surfaceSubtle,
          side: const BorderSide(color: AppColors.border),
          label: Text(
            'המשך מהפרסום הנוכחי',
            style: GoogleFonts.heebo(
              color: AppColors.onSurface,
              fontSize: 11.5,
            ),
          ),
          onPressed: () => _sendTextMessage('המשך'),
        ),
      );
    }

    if (text.contains('ביטול')) {
      chips.add(
        ActionChip(
          backgroundColor: AppColors.surfaceSubtle,
          side: const BorderSide(color: AppColors.border),
          label: Text(
            'ביטול',
            style: GoogleFonts.heebo(
              color: AppColors.secondary,
              fontSize: 11.5,
            ),
          ),
          onPressed: () => _sendTextMessage('ביטול'),
        ),
      );
    }

    if (chips.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(spacing: 8, runSpacing: 6, children: chips),
    );
  }

  Widget _buildImageMessageContent(ChatMessageItem message) {
    final hasLocal =
        message.localFilePath != null &&
        File(message.localFilePath!).existsSync();
    final hasUrl = message.mediaUrl != null && message.mediaUrl!.isNotEmpty;

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (hasLocal)
            Image.file(
              File(message.localFilePath!),
              width: double.infinity,
              height: 200,
              fit: BoxFit.cover,
            )
          else if (hasUrl)
            Image.network(
              message.mediaUrl!,
              width: double.infinity,
              height: 200,
              fit: BoxFit.cover,
              errorBuilder:
                  (_, _, _) => Container(
                    color: AppColors.surfaceSubtle,
                    height: 140,
                    child: const Center(
                      child: Icon(
                        Icons.broken_image_rounded,
                        color: AppColors.secondary,
                        size: 36,
                      ),
                    ),
                  ),
            )
          else
            Container(
              color: AppColors.surfaceSubtle,
              height: 140,
              child: const Center(
                child: Icon(
                  Icons.image_rounded,
                  color: AppColors.secondary,
                  size: 36,
                ),
              ),
            ),
          if (message.isUploading)
            Container(
              color: Colors.black45,
              width: double.infinity,
              height: 200,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(
                      value: message.uploadProgress,
                      color: AppColors.primaryAction,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'מעלה... ${(message.uploadProgress * 100).toInt()}%',
                      style: GoogleFonts.heebo(
                        color: Colors.white,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAudioMessageContent(ChatMessageItem message) {
    final isPlaying = _playingAudioId == message.id;
    final dur = message.audioDuration ?? const Duration(seconds: 5);
    final durationStr = intl.DateFormat(
      'm:ss',
    ).format(DateTime(0).add(isPlaying ? _currentAudioPosition : dur));

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              isPlaying
                  ? Icons.pause_circle_filled_rounded
                  : Icons.play_circle_fill_rounded,
              color: AppColors.primaryAction,
              size: 38,
            ),
            onPressed: () => _toggleAudioPlay(message),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                  value:
                      isPlaying && _currentAudioDuration.inMilliseconds > 0
                          ? (_currentAudioPosition.inMilliseconds /
                                  _currentAudioDuration.inMilliseconds)
                              .clamp(0.0, 1.0)
                          : 0.0,
                  backgroundColor: AppColors.border,
                  color: AppColors.primaryAction,
                  minHeight: 4,
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      durationStr,
                      style: GoogleFonts.heebo(
                        fontSize: 11,
                        color: AppColors.secondary,
                      ),
                    ),
                    if (message.isUploading)
                      Text(
                        'מעלה... ${(message.uploadProgress * 100).toInt()}%',
                        style: GoogleFonts.heebo(
                          fontSize: 11,
                          color: AppColors.primaryAction,
                        ),
                      )
                    else
                      const Icon(
                        Icons.mic_none_rounded,
                        size: 14,
                        color: AppColors.secondary,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoMessageContent(ChatMessageItem message) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 160,
        width: double.infinity,
        color: AppColors.surfaceSubtle,
        child: Stack(
          alignment: Alignment.center,
          children: [
            const Icon(
              Icons.movie_rounded,
              color: AppColors.secondary,
              size: 48,
            ),
            Container(
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primaryAction,
              ),
              padding: const EdgeInsets.all(10),
              child: const Icon(
                Icons.play_arrow_rounded,
                color: Colors.white,
                size: 28,
              ),
            ),
            if (message.isUploading)
              Container(
                color: Colors.black54,
                child: Center(
                  child: Text(
                    'שולח וידאו... ${(message.uploadProgress * 100).toInt()}%',
                    style: GoogleFonts.heebo(color: Colors.white, fontSize: 11),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border, width: 1)),
      ),
      child: SafeArea(
        child: Row(
          children: [
            // Physical Right in RTL: Circular Coral Send Button
            Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                padding: EdgeInsets.zero,
                tooltip: 'שלח',
                icon: const Icon(
                  Icons.send_rounded,
                  textDirection: TextDirection.ltr,
                  color: Colors.white,
                  size: 26,
                ),
                onPressed: () {
                  if (_isRecording) {
                    _stopAndSendRecording(cancel: false);
                  } else {
                    _sendTextMessage();
                  }
                },
              ),
            ),
            const SizedBox(width: 8),

            // Center: Text Input or Recording State
            Expanded(
              child:
                  _isRecording
                      ? Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.errorSoft,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: AppColors.error.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.error,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'הקלטת הודעה... ${_formatDuration(_recordSeconds)}',
                              style: GoogleFonts.heebo(
                                color: AppColors.error,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const Spacer(),
                            TextButton(
                              onPressed:
                                  () => _stopAndSendRecording(cancel: true),
                              child: Text(
                                'ביטול',
                                style: GoogleFonts.heebo(
                                  color: AppColors.error,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                      : Container(
                        decoration: BoxDecoration(
                          color: AppColors.surfaceSubtle,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _textController,
                                style: GoogleFonts.heebo(
                                  color: AppColors.onSurface,
                                  fontSize: 15,
                                ),
                                textDirection: TextDirection.rtl,
                                maxLines: 4,
                                minLines: 1,
                                decoration: InputDecoration(
                                  hintText: '...הודעה למכשיר',
                                  hintStyle: GoogleFonts.heebo(
                                    color: AppColors.secondary,
                                    fontSize: 14,
                                  ),
                                  hintTextDirection: TextDirection.rtl,
                                  border: InputBorder.none,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 10,
                                  ),
                                ),
                                onChanged: (text) => setState(() {}),
                                onSubmitted: (_) => _sendTextMessage(),
                              ),
                            ),
                            GestureDetector(
                              onLongPressStart: (_) => _startRecording(),
                              onLongPressEnd:
                                  (_) => _stopAndSendRecording(cancel: false),
                              child: IconButton(
                                tooltip: 'הקלטת הודעה',
                                icon: const Icon(
                                  Icons.mic_none_rounded,
                                  color: AppColors.secondary,
                                  size: 22,
                                ),
                                onPressed: () {
                                  if (_isRecording) {
                                    _stopAndSendRecording(cancel: false);
                                  } else {
                                    _startRecording();
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
            ),
            const SizedBox(width: 8),

            // Physical Left in RTL: Attachment '+' Button in circular container
            Container(
              width: 38,
              height: 38,
              decoration: const BoxDecoration(
                color: AppColors.surfaceSubtle,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                padding: EdgeInsets.zero,
                tooltip: 'קבצים מצורפים',
                icon: const Icon(
                  Icons.add_rounded,
                  color: AppColors.onSurface,
                  size: 24,
                ),
                onPressed: _showAttachmentMenu,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(int totalSeconds) {
    final mins = totalSeconds ~/ 60;
    final secs = totalSeconds % 60;
    return '${mins.toString().padLeft(1, '0')}:${secs.toString().padLeft(2, '0')}';
  }
}
