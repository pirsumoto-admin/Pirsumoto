import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart' as intl;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../webrtc/controller_webrtc_session.dart';
import 'remote_control_screen.dart';

enum ChatSender { user, bot }

class ChatMessageItem {
  final String id;
  final ChatSender sender;
  final String text;
  final String? mediaType; // 'image', 'audio', 'video'
  final String? localFilePath;
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
      'caption': caption,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'audioDurationMs': audioDuration?.inMilliseconds,
    };
  }

  factory ChatMessageItem.fromJson(Map<String, dynamic> json) {
    return ChatMessageItem(
      id: json['id'] as String? ??
          'msg_${DateTime.now().millisecondsSinceEpoch}',
      sender: json['sender'] == 'user' ? ChatSender.user : ChatSender.bot,
      text: json['text'] as String? ?? '',
      mediaType: json['mediaType'] as String?,
      localFilePath: json['localFilePath'] as String?,
      caption: json['caption'] as String?,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        json['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      ),
      uploadProgress: 1.0,
      isUploading: false,
      audioDuration: json['audioDurationMs'] != null
          ? Duration(milliseconds: json['audioDurationMs'] as int)
          : null,
    );
  }
}

class WhatsAppChatScreen extends StatefulWidget {
  final ControllerWebRtcSession session;
  final String deviceName;

  const WhatsAppChatScreen({
    super.key,
    required this.session,
    required this.deviceName,
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
  StreamSubscription? _replySub;
  StreamSubscription? _statusSub;
  StreamSubscription? _playerStateSub;
  StreamSubscription? _playerPositionSub;

  bool _isRecording = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;
  String? _statusSubtitle;
  Timer? _statusSubtitleTimer;

  String? _playingAudioId;
  Duration _currentAudioPosition = Duration.zero;
  Duration _currentAudioDuration = Duration.zero;

  String get _storageKey {
    final devId = widget.session.signaling.deviceId;
    return 'chat_messages_${devId.isNotEmpty ? devId : "default"}';
  }

  @override
  void initState() {
    super.initState();
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
        final loaded = decoded
            .map((item) =>
                ChatMessageItem.fromJson(item as Map<String, dynamic>))
            .toList();
        if (loaded.isNotEmpty) {
          if (!mounted) return;
          setState(() {
            _messages.clear();
            _messages.addAll(loaded);
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
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1F2C34),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF2A3942)),
        ),
        title: Text(
          'ניקוי היסטוריית צ\'אט',
          style: GoogleFonts.outfit(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          'האם אתה בטוח שברצונך למחוק את כל היסטוריית ההודעות השמורה עבור מכשיר זה?',
          style: GoogleFonts.inter(color: const Color(0xFFD1D7DB)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'ביטול',
              style: GoogleFonts.inter(color: const Color(0xFF8696A0)),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDA3633),
              foregroundColor: Colors.white,
            ),
            child: Text(
              'מחק הכל',
              style: GoogleFonts.inter(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_storageKey);
      } catch (e) {
        debugPrint('[WhatsAppChat] Error clearing prefs: $e');
      }

      if (!mounted) return;
      setState(() {
        _messages.clear();
        _addInitialWelcomeMessage();
      });
      _saveMessagesToPrefs();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'היסטוריית הצ\'אט נמחקה בהצלחה',
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
    _replySub = widget.session.chatReplies.listen((reply) {
      if (!mounted) return;
      setState(() {
        _statusSubtitle = null;
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
    });

    _statusSub = widget.session.chatStatuses.listen((status) {
      if (!mounted) return;
      setState(() {
        _statusSubtitle = status.text;
      });
      _statusSubtitleTimer?.cancel();
      _statusSubtitleTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) {
          setState(() => _statusSubtitle = null);
        }
      });
    });
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
    _replySub?.cancel();
    _statusSub?.cancel();
    _playerStateSub?.cancel();
    _playerPositionSub?.cancel();
    _recordTimer?.cancel();
    _statusSubtitleTimer?.cancel();
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

  void _sendTextMessage([String? presetText]) {
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

    widget.session.sendChatMessage(text, senderName: 'Remote User');
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

    await widget.session.sendChatMediaFile(
      file: file,
      mediaType: 'image',
      onProgress: (progress) {
        if (mounted) {
          setState(() {
            msgItem.uploadProgress = progress;
            if (progress >= 1.0) {
              msgItem.isUploading = false;
              _saveMessagesToPrefs();
            }
          });
        }
      },
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
        // Small delay to let WebRTC data channel buffers flush cleanly
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

      await widget.session.sendChatMediaFile(
        file: file,
        mediaType: 'video',
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              msgItem.uploadProgress = progress;
              if (progress >= 1.0) {
                msgItem.isUploading = false;
                _saveMessagesToPrefs();
              }
            });
          }
        },
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
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000),
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

      await widget.session.sendChatMediaFile(
        file: file,
        mediaType: 'audio',
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              msgItem.uploadProgress = progress;
              if (progress >= 1.0) {
                msgItem.isUploading = false;
                _saveMessagesToPrefs();
              }
            });
          }
        },
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
      backgroundColor: const Color(0xFF1F2C34),
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
                  color: const Color(0xFFE91E63),
                  label: 'מצלמה',
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickImage(ImageSource.camera);
                  },
                ),
                _buildAttachmentTile(
                  icon: Icons.photo_library_rounded,
                  color: const Color(0xFF9C27B0),
                  label: 'גלריה (תמונות)',
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickMultiImage();
                  },
                ),
                _buildAttachmentTile(
                  icon: Icons.videocam_rounded,
                  color: const Color(0xFF00BCD4),
                  label: 'סרטון וידאו',
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickVideo();
                  },
                ),
                _buildAttachmentTile(
                  icon: Icons.directions_car_rounded,
                  color: const Color(0xFF00A884),
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
            backgroundColor: color,
            child: Icon(icon, color: Colors.white, size: 28),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: GoogleFonts.inter(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Future<void> _switchToRemoteControl() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => RemoteControlScreen(
              session: widget.session,
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
      backgroundColor: const Color(0xFF0B141A),
      appBar: _buildAppBar(),
      body: Column(
        children: [
          // P2P Direct Connection Banner
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            color: const Color(0xFF182229),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color:
                        widget.session.isConnected
                            ? const Color(0xFF00A884)
                            : Colors.amber,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.session.isConnected
                        ? 'תקשורת P2P WebRTC ישירה ומאובטחת ללא שרת תיווך'
                        : 'מתחבר ב-WebRTC...',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      color: const Color(0xFF8696A0),
                    ),
                  ),
                ),
                if (widget.session.pingMs > 0)
                  Text(
                    '${widget.session.pingMs}ms',
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      color: const Color(0xFF8696A0),
                    ),
                  ),
              ],
            ),
          ),

          // Messages List
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xFF1F2C34),
      centerTitle: true,
      leadingWidth: 80,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            style: IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              minimumSize: const Size(32, 32),
              padding: EdgeInsets.zero,
            ),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 4),
          const CircleAvatar(
            radius: 18,
            backgroundColor: Color(0xFF00A884),
            child: Icon(Icons.smart_toy_rounded, color: Colors.white, size: 20),
          ),
        ],
      ),
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            'פירסומוטו בוט',
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.outfit(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          Text(
            _statusSubtitle ??
                (widget.session.isConnected
                    ? 'מחובר (P2P WebRTC)'
                    : 'מתחבר...'),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 11,
              color:
                  _statusSubtitle != null
                      ? const Color(0xFF00A884)
                      : const Color(0xFF8696A0),
              fontWeight:
                  _statusSubtitle != null ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'נקה היסטוריית צ\'אט',
          icon: const Icon(
            Icons.delete_sweep_rounded,
            color: Color(0xFFEF4444),
          ),
          onPressed: _clearChatData,
        ),
        IconButton(
          tooltip: 'עבור לשליטה מרחוק במסך',
          icon: const Icon(
            Icons.screen_share_rounded,
            color: Color(0xFF58A6FF),
          ),
          onPressed: _switchToRemoteControl,
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, color: Color(0xFF8696A0)),
          color: const Color(0xFF1F2C34),
          onSelected: (val) {
            if (val == 'clear') {
              _clearChatData();
            } else if (val == 'publish') {
              _sendTextMessage('0');
            } else if (val == 'cancel') {
              _sendTextMessage('ביטול');
            }
          },
          itemBuilder:
              (ctx) => [
                PopupMenuItem(
                  value: 'publish',
                  child: Text(
                    'פרסם ביד2 (0)',
                    style: GoogleFonts.inter(color: Colors.white),
                  ),
                ),
                PopupMenuItem(
                  value: 'cancel',
                  child: Text(
                    'ביטול סשן',
                    style: GoogleFonts.inter(color: Colors.redAccent),
                  ),
                ),
                PopupMenuItem(
                  value: 'clear',
                  child: Text(
                    'נקה הודעות במסך',
                    style: GoogleFonts.inter(color: const Color(0xFF8696A0)),
                  ),
                ),
              ],
        ),
      ],
    );
  }

  Widget _buildMessageBubble(ChatMessageItem message) {
    final isUser = message.sender == ChatSender.user;
    final timeStr = intl.DateFormat('HH:mm').format(message.timestamp);

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: isUser ? const Color(0xFF005C4B) : const Color(0xFF202C33),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isUser ? 14 : 0),
            bottomRight: Radius.circular(isUser ? 0 : 14),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Media Display
            if (message.mediaType == 'image' && message.localFilePath != null)
              _buildImageMessageContent(message),

            if (message.mediaType == 'audio' && message.localFilePath != null)
              _buildAudioMessageContent(message),

            if (message.mediaType == 'video' && message.localFilePath != null)
              _buildVideoMessageContent(message),

            // Text content
            if (message.text.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(
                  top: message.mediaType != null ? 6 : 0,
                ),
                child: Text(
                  message.text,
                  style: GoogleFonts.inter(
                    fontSize: 14.5,
                    color: Colors.white,
                    height: 1.35,
                  ),
                  textDirection: TextDirection.rtl,
                ),
              ),

            // Bot Quick Action Chips (e.g. if ready to publish)
            if (!isUser && _hasActionOptions(message.text))
              _buildQuickActionChips(message.text),

            // Timestamp and Status Checkmarks
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  timeStr,
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    color: const Color(0xFF8696A0),
                  ),
                ),
                if (isUser) ...[
                  const SizedBox(width: 4),
                  if (message.isUploading)
                    const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Colors.white54,
                      ),
                    )
                  else
                    const Icon(
                      Icons.done_all_rounded,
                      size: 14,
                      color: Color(0xFF53BDEB), // WhatsApp blue double tick
                    ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  bool _hasActionOptions(String text) {
    return text.contains('0 לפרסום') ||
        text.contains('לפרסום שלח 0') ||
        text.contains('ביטול') ||
        text.contains('המשך') ||
        text.contains('שליטה מרחוק') ||
        text.contains('Remote Control') ||
        text.contains('התערבות') ||
        text.contains('נתקעה') ||
        text.contains('תמונות') ||
        text.contains('תמונה') ||
        text.contains('להעלות') ||
        text.contains('התקבלו');
  }

  Widget _buildQuickActionChips(String text) {
    final chips = <Widget>[];

    final asksForImages =
        text.contains('תמונות') ||
        text.contains('תמונה') ||
        text.contains('להעלות') ||
        text.contains('התקבלו') ||
        text.contains('נקלטה תמונה');

    if (asksForImages) {
      chips.add(
        ActionChip(
          backgroundColor: const Color(0xFF9C27B0),
          avatar: const Icon(
            Icons.photo_library_rounded,
            size: 14,
            color: Colors.white,
          ),
          label: Text(
            'העלה תמונות (גלריה)',
            style: GoogleFonts.inter(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          onPressed: _pickMultiImage,
        ),
      );
      chips.add(
        ActionChip(
          backgroundColor: const Color(0xFFE91E63),
          avatar: const Icon(
            Icons.camera_alt_rounded,
            size: 14,
            color: Colors.white,
          ),
          label: Text(
            'צלם תמונה',
            style: GoogleFonts.inter(color: Colors.white, fontSize: 11),
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
          backgroundColor: const Color(0xFFD32F2F),
          avatar: const Icon(
            Icons.settings_remote_rounded,
            size: 14,
            color: Colors.white,
          ),
          label: Text(
            'עבור לשליטה מרחוק (Remote Control)',
            style: GoogleFonts.inter(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          onPressed: _switchToRemoteControl,
        ),
      );
    }

    if (text.contains('0') || text.contains('לפרסום')) {
      chips.add(
        ActionChip(
          backgroundColor: const Color(0xFF00A884),
          avatar: const Icon(Icons.publish, size: 14, color: Colors.white),
          label: Text(
            'פרסם עכשיו (0)',
            style: GoogleFonts.inter(
              color: Colors.white,
              fontSize: 11,
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
          backgroundColor: const Color(0xFF21262D),
          label: Text(
            'המשך מהפרסום הנוכחי',
            style: GoogleFonts.inter(color: Colors.white, fontSize: 11),
          ),
          onPressed: () => _sendTextMessage('המשך'),
        ),
      );
    }

    if (text.contains('ביטול')) {
      chips.add(
        ActionChip(
          backgroundColor: const Color(0xFF30363D),
          label: Text(
            'ביטול',
            style: GoogleFonts.inter(color: Colors.redAccent, fontSize: 11),
          ),
          onPressed: () => _sendTextMessage('ביטול'),
        ),
      );
    }

    if (chips.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(spacing: 6, runSpacing: 4, children: chips),
    );
  }

  Widget _buildImageMessageContent(ChatMessageItem message) {
    final file = File(message.localFilePath!);
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Image.file(
            file,
            width: double.infinity,
            height: 200,
            fit: BoxFit.cover,
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
                      color: const Color(0xFF00A884),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'שולח ב-P2P... ${(message.uploadProgress * 100).toInt()}%',
                      style: GoogleFonts.inter(
                        color: Colors.white,
                        fontSize: 11,
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
              color: const Color(0xFF00A884),
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
                  backgroundColor: const Color(0xFF30363D),
                  color: const Color(0xFF00A884),
                  minHeight: 4,
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      durationStr,
                      style: GoogleFonts.inter(
                        fontSize: 10,
                        color: const Color(0xFF8696A0),
                      ),
                    ),
                    if (message.isUploading)
                      Text(
                        'מעלה... ${(message.uploadProgress * 100).toInt()}%',
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          color: const Color(0xFF00A884),
                        ),
                      )
                    else
                      const Icon(Icons.mic, size: 14, color: Color(0xFF8696A0)),
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
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 160,
        width: double.infinity,
        color: const Color(0xFF161B22),
        child: Stack(
          alignment: Alignment.center,
          children: [
            const Icon(Icons.movie_rounded, color: Color(0xFF8B949E), size: 48),
            Container(
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFF00A884),
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
                    'שולח וידאו ב-P2P... ${(message.uploadProgress * 100).toInt()}%',
                    style: GoogleFonts.inter(color: Colors.white, fontSize: 11),
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      color: const Color(0xFF1F2C34),
      child: SafeArea(
        child: Row(
          children: [
            // Attachment Button
            IconButton(
              tooltip: 'קבצים מצורפים',
              icon: const Icon(
                Icons.attach_file_rounded,
                color: Color(0xFF8696A0),
              ),
              onPressed: _showAttachmentMenu,
            ),
            // Direct Multi-Image Gallery Button
            IconButton(
              tooltip: 'העלאת תמונות מהגלריה',
              icon: const Icon(
                Icons.add_photo_alternate_rounded,
                color: Color(0xFF8696A0),
              ),
              onPressed: _pickMultiImage,
            ),

            // Text Input or Recording State
            Expanded(
              child:
                  _isRecording
                      ? Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2A3942),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.redAccent,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              'מקליט הודעה קולית... ${_formatDuration(_recordSeconds)}',
                              style: GoogleFonts.inter(
                                color: Colors.white,
                                fontSize: 13,
                              ),
                            ),
                            const Spacer(),
                            TextButton(
                              onPressed:
                                  () => _stopAndSendRecording(cancel: true),
                              child: Text(
                                'ביטול',
                                style: GoogleFonts.inter(
                                  color: Colors.redAccent,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                      : Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF2A3942),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: TextField(
                          controller: _textController,
                          style: GoogleFonts.inter(
                            color: Colors.white,
                            fontSize: 15,
                          ),
                          textDirection: TextDirection.rtl,
                          maxLines: 4,
                          minLines: 1,
                          decoration: InputDecoration(
                            hintText: 'הקלד/י הודעה...',
                            hintStyle: GoogleFonts.inter(
                              color: const Color(0xFF8696A0),
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
            ),
            const SizedBox(width: 6),

            // Mic or Send Button
            if (_isRecording)
              FloatingActionButton.small(
                backgroundColor: const Color(0xFF00A884),
                foregroundColor: Colors.white,
                elevation: 0,
                onPressed: () => _stopAndSendRecording(cancel: false),
                child: const Icon(Icons.send_rounded, size: 18),
              )
            else if (_textController.text.trim().isNotEmpty)
              FloatingActionButton.small(
                backgroundColor: const Color(0xFF00A884),
                foregroundColor: Colors.white,
                elevation: 0,
                onPressed: () => _sendTextMessage(),
                child: const Icon(Icons.send_rounded, size: 18),
              )
            else
              GestureDetector(
                onLongPressStart: (_) => _startRecording(),
                onLongPressEnd: (_) => _stopAndSendRecording(cancel: false),
                child: FloatingActionButton.small(
                  backgroundColor: const Color(0xFF00A884),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  onPressed: () {
                    // Tap to start/stop
                    if (_isRecording) {
                      _stopAndSendRecording(cancel: false);
                    } else {
                      _startRecording();
                    }
                  },
                  child: const Icon(Icons.mic, size: 20),
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
