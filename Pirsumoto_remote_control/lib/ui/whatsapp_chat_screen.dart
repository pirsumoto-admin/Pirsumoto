import '../models/chat_message.dart';
export '../models/chat_message.dart';
import 'dart:convert';
import 'package:publication_protocol/publication_protocol.dart';
import 'dart:async';
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
import '../signaling/controller_signaling.dart';
import '../webrtc/controller_webrtc_session.dart';
import 'app_theme.dart';
import 'chat_message_bubble.dart';
import 'remote_control_screen.dart';
import 'chat_sessions_list_screen.dart';
import 'chat_session_manager.dart';
import '../database/sqlite_database_helper.dart';
import '../services/remote_validation_service.dart';
import '../services/vehicle_data_service.dart';

class WhatsAppChatScreen extends StatefulWidget {
  final String deviceId;
  final String deviceName;
  final ControllerWebRtcSession? session;
  final String? sessionId;

  static String? currentActiveDeviceId;
  static String? currentActiveSessionId;

  static bool isInsideChatWith(String deviceId) =>
      currentActiveDeviceId != null && currentActiveDeviceId == deviceId;

  static bool isInsideAnyChat() => currentActiveDeviceId != null;

  const WhatsAppChatScreen({
    super.key,
    required this.deviceId,
    required this.deviceName,
    this.session,
    this.sessionId,
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

  late final String _sessionId;
  String _currentLicensePlate = '';
  bool _allDataFilled = false;
  ChatSessionStatus? _localStatus;
  Map<String, String> _vehicleData = {};
  late final String? _accountUid;
  bool get _sameAccount =>
      FirebaseAuth.instance.currentUser?.uid == _accountUid;
  bool _submitting = false;
  int _pendingTurns = 0;
  Future<void> _turns = Future.value();
  StreamSubscription? _requestChanges;
  final Map<String, String> _savedMessages = {};
  String? get _publicationState =>
      (ChatSessionManager.request(widget.deviceId, _sessionId)?['state']
          as String?) ??
      switch (_localStatus) {
        ChatSessionStatus.done => 'completed',
        ChatSessionStatus.canceled => 'canceled',
        ChatSessionStatus.failed => 'failed',
        _ => null,
      };

  @override
  void initState() {
    super.initState();
    _accountUid = FirebaseAuth.instance.currentUser?.uid;
    final isNewSession = widget.sessionId == null;
    _sessionId =
        widget.sessionId ??
        FirebaseFirestore.instance.collection('_ids').doc().id;
    ChatSessionManager.watchDevice(widget.deviceId);
    _requestChanges = ChatSessionManager.changes
        .where((d) => d == widget.deviceId)
        .listen((_) => _refreshSession());
    WhatsAppChatScreen.currentActiveDeviceId = widget.deviceId;
    WhatsAppChatScreen.currentActiveSessionId = _sessionId;
    _deviceStatusStream = FirebaseFirestore.instance
        .collection('remote_control_devices')
        .doc(widget.deviceId)
        .snapshots(includeMetadataChanges: true);

    if (isNewSession) {
      _initNewSession();
    } else {
      _initExistingSession();
    }
    _initAudioPlayerListeners();
  }

  Future<void> _refreshSession() async {
    final saved = await SqliteDatabaseHelper.instance.getSession(_sessionId);
    if (!mounted || !_sameAccount) return;
    setState(() {
      _allDataFilled =
          saved != null &&
          VehicleSchema.isComplete(saved.vehicleData) &&
          saved.imagePaths.isNotEmpty;
      _localStatus = saved?.status;
      _vehicleData = saved?.vehicleData ?? {};
      _currentLicensePlate = saved?.licensePlate ?? '';
      final request = ChatSessionManager.request(widget.deviceId, _sessionId);
      final text = request?['lastMessage']?.toString() ?? '';
      if (request != null && text.isNotEmpty) {
        final id = '${request['attemptId']}_${request['revision']}';
        if (!_messages.any((m) => m.id == id) &&
            (_messages.isEmpty || _messages.last.text != text)) {
          final timestamp = request['updatedAt'];
          _messages.add(
            ChatMessageItem(
              id: id,
              sender: ChatSender.bot,
              text: text,
              timestamp: timestamp is Timestamp
                  ? timestamp.toDate()
                  : DateTime.now(),
            ),
          );
          _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        }
      }
    });
    unawaited(_saveMessagesToPrefs());
  }

  Future<void> _initExistingSession() async {
    await _loadMessagesFromPrefs();
    await _refreshSession();
    _listenToSessionEvents();
  }

  Future<void> _initNewSession() async {
    await _loadMessagesFromPrefs();
    _listenToSessionEvents();
  }

  Future<void> _loadMessagesFromPrefs() async {
    try {
      final loaded = await SqliteDatabaseHelper.instance.getMessages(
        _sessionId,
      );
      if (loaded.isNotEmpty) {
        if (!mounted) return;
        setState(() {
          final merged = {
            for (final message in _messages) message.id: message,
            for (final message in loaded) message.id: message,
          };
          _messages.clear();
          _messages.addAll(merged.values);
          _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        });
        _scrollToBottom();
        return;
      }
    } catch (e) {
      debugPrint('[WhatsAppChat] Error loading messages from DB: $e');
    }

    // Default: add initial welcome message if empty
    if (_messages.isEmpty && mounted) {
      setState(() {
        _addInitialWelcomeMessage();
      });
      _saveMessagesToPrefs();
    }
  }

  Future<void> _loadOlderMessages() async {
    if (_messages.isEmpty) return;
    final before = _messages.first.timestamp.millisecondsSinceEpoch;
    try {
      final older = await SqliteDatabaseHelper.instance.getMessages(
        _sessionId,
        beforeTimestamp: before,
      );
      final remote = await FirebaseFirestore.instance
          .collection('remote_chats')
          .doc(widget.deviceId)
          .collection('messages')
          .where('sessionId', isEqualTo: _sessionId)
          .orderBy('timestamp', descending: true)
          .startAfter([before])
          .limit(100)
          .get();
      for (final doc in remote.docs) {
        if (doc.data()['sender'] == 'bot' && doc.data()['type'] == 'status')
          older.add(ChatMessageItem.fromJson({...doc.data(), 'id': doc.id}));
      }
      if (!mounted || !_sameAccount) return;
      if (older.isEmpty) {
        _showError('אין הודעות קודמות');
        return;
      }
      final ids = _messages.map((m) => m.id).toSet();
      setState(() {
        _messages.addAll(older.where((m) => ids.add(m.id)));
        _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      });
      await _saveMessagesToPrefs();
    } catch (e) {
      _showError('טעינת ההיסטוריה נכשלה: $e');
    }
  }

  Future<void> _saveMessagesToPrefs() async {
    if (!_sameAccount) return;
    for (final msg in List<ChatMessageItem>.of(_messages)) {
      if (!_sameAccount) return;
      final encoded = jsonEncode(msg.toJson());
      if (_savedMessages[msg.id] == encoded) continue;
      await SqliteDatabaseHelper.instance.insertMessage(
        _sessionId,
        widget.deviceId,
        msg,
      );
      _savedMessages[msg.id] = encoded;
    }
  }

  Future<void> _clearChatData() async {
    if (_publicationState != null || _submitting || _pendingTurns > 0) {
      _showError('לא ניתן לנקות שיחה במהלך פרסום או עיבוד');
      return;
    }
    await SqliteDatabaseHelper.instance.deleteMessages(_sessionId);
    await SqliteDatabaseHelper.instance.deleteSession(_sessionId);
    if (!mounted) return;
    setState(() {
      _messages.clear();
      _savedMessages.clear();
      _allDataFilled = false;
      _currentLicensePlate = '';
      _addInitialWelcomeMessage();
    });
    await _saveMessagesToPrefs();
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
    _firestoreSub?.cancel();
    _firestoreSub = FirebaseFirestore.instance
        .collection('remote_chats')
        .doc(widget.deviceId)
        .collection('messages')
        .where('sessionId', isEqualTo: _sessionId)
        .orderBy('timestamp', descending: true)
        .limit(100)
        .snapshots()
        .listen(
          (snapshot) {
            if (!mounted) return;
            for (final doc in snapshot.docs) {
              final data = doc.data();
              if (data['sender'] != 'bot' || data['type'] != 'status') continue;
              if (_messages.any((m) => m.id == doc.id)) continue;
              _messages.add(ChatMessageItem.fromJson({...data, 'id': doc.id}));
            }
            _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
            setState(() {});
            _scrollToBottom();
            unawaited(_saveMessagesToPrefs());
          },
          onError: (Object error) {
            if (mounted) _showError('לא ניתן לסנכרן הודעות: $error');
          },
        );
  }

  void _showError(String text) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _control(String command) async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      await _turns;
      if (!_sameAccount) return;
      await ChatSessionManager.control(widget.deviceId, _sessionId, command);
    } catch (e) {
      _showError('$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _onPublishTapped() async {
    if (_submitting || _publicationState != null) return;
    setState(() => _submitting = true);
    try {
      await _turns;
      if (!_sameAccount || !mounted) return;
      final saved = await SqliteDatabaseHelper.instance.getSession(_sessionId);
      if (saved == null) throw StateError('יש להשלים את פרטי הרכב');
      await ChatSessionManager.startPublication(widget.deviceId, saved);
      await _refreshSession();
    } catch (e) {
      _showError('$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
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
    if (WhatsAppChatScreen.currentActiveDeviceId == widget.deviceId &&
        WhatsAppChatScreen.currentActiveSessionId == _sessionId) {
      WhatsAppChatScreen.currentActiveDeviceId = null;
      WhatsAppChatScreen.currentActiveSessionId = null;
    }
    _requestChanges?.cancel();
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

  void _sendTextMessage([String? presetText]) {
    final text = (presetText ?? _textController.text).trim();
    if (text.isEmpty) return;
    if (presetText == null) _textController.clear();
    if (text == 'ביטול' || text == 'לבטל') {
      unawaited(_control('cancel'));
      return;
    }
    if (text == 'הפסק') {
      unawaited(_control('pause'));
      return;
    }
    if (text == 'המשך') {
      unawaited(_control('resume'));
      return;
    }
    if ({'פרסם', 'פרסום', 'פרסם עכשיו'}.contains(text)) {
      unawaited(_onPublishTapped());
      return;
    }
    if (_publicationState != null || _submitting) {
      _showError('הבקשה הוגשה. לשינוי הפרטים יש לבטל ולפתוח בקשה חדשה.');
      return;
    }
    _pendingTurns++;
    setState(() {});
    _turns = _turns
        .then((_) => _processTextTurn(text))
        .catchError((Object e) => _showError('$e'))
        .whenComplete(() {
          _pendingTurns--;
          if (mounted) setState(() {});
        });
  }

  Future<void> _processTextTurn(String text) async {
    if (!mounted || !_sameAccount || _publicationState != null) return;
    // Serialize turns so a slow response cannot overwrite a newer correction.
    final userMessage = ChatMessageItem(
      id: 'msg_${DateTime.now().microsecondsSinceEpoch}',
      sender: ChatSender.user,
      text: text,
      timestamp: DateTime.now(),
    );

    setState(() {
      _messages.add(userMessage);
    });
    _scrollToBottom();
    _saveMessagesToPrefs();

    final session = await SqliteDatabaseHelper.instance.getSession(_sessionId);
    final currentVehicleData = session?.vehicleData ?? {};
    var currentImagePaths = session?.imagePaths ?? [];

    final historyList = _messages
        .where((m) => m.id != userMessage.id && m.text.trim().isNotEmpty)
        .map(
          (m) => {
            'role': m.sender == ChatSender.user ? 'user' : 'assistant',
            'text': m.text,
          },
        )
        .toList();

    // The authenticated backend extracts fields and looks up the vehicle.
    final result = await RemoteValidationService.processTurn(
      deviceId: widget.deviceId,
      incomingText: text,
      currentVehicleData: currentVehicleData,
      chatHistory: historyList,
      currentImagePaths: currentImagePaths,
    );

    if (!mounted || !_sameAccount) return;
    if ((currentVehicleData['license_plate'] ?? '').isNotEmpty &&
        currentVehicleData['license_plate'] !=
            result.vehicleData['license_plate'])
      currentImagePaths = [];
    if (result.vehicleData['license_plate'] != null) {
      _currentLicensePlate = result.vehicleData['license_plate']!;
    }

    final plate = _currentLicensePlate.isNotEmpty
        ? _currentLicensePlate
        : (result.vehicleData['license_plate'] ?? '');

    // Merge vehicle data with gov.il sources if needed
    final mergedVehicleData = Map<String, String>.from(result.vehicleData);
    if (plate.isNotEmpty) {
      try {
        final govInfo = await VehicleDataService.fetchVehicleData(plate);
        if (govInfo != null) {
          for (final entry in govInfo.entries) {
            final key = entry.key;
            final val = entry.value?.toString().trim() ?? '';
            if (val.isNotEmpty &&
                (mergedVehicleData[key] == null ||
                    mergedVehicleData[key]!.isEmpty)) {
              mergedVehicleData[key] = val;
            }
          }
        }
      } catch (e) {
        debugPrint('[WhatsAppChat] Error fetching gov.il data in turn: $e');
      }
    }

    final missing = RemoteValidationService.getMissingFields(mergedVehicleData);
    final errors = RemoteValidationService.validateValues(mergedVehicleData);
    final isComplete = missing.isEmpty && errors.isEmpty;

    if (isComplete && currentImagePaths.isNotEmpty) {
      _allDataFilled = true;
    } else {
      _allDataFilled = false;
    }

    String finalBotReply = result.botReply;
    if (plate.isNotEmpty) {
      final summary =
          'נקלט רכב $plate: ${[mergedVehicleData['maker'], mergedVehicleData['model'], mergedVehicleData['year']].where((s) => s != null && s.isNotEmpty).join(' ')}';
      final guidance = missing.isNotEmpty
          ? 'להשלמת פרטי הרכב — אנא מלא את השדות בטופס שלמטה:'
          : (currentImagePaths.isNotEmpty
                ? '✅ כל פרטי הרכב מלאים ומאומתים!\nלחץ על "פרסם עכשיו" להתחלת הפרסום ביד2.'
                : '📷 אנא צרף לפחות תמונה אחת של הרכב כדי להתחיל בפרסום.');
      final errorLines = errors.map((e) => '⚠️ $e').toList();
      finalBotReply = [
        if (summary.isNotEmpty) summary,
        ...errorLines,
        guidance,
      ].join('\n\n');
    }

    final botReplyMsg = ChatMessageItem(
      id: 'bot_${DateTime.now().microsecondsSinceEpoch}',
      sender: ChatSender.bot,
      text: finalBotReply,
      timestamp: DateTime.now(),
    );

    if (mounted) {
      setState(() {
        _messages.add(botReplyMsg);
      });
      _scrollToBottom();
    }
    _saveMessagesToPrefs();

    // Update SQLite session state
    final updatedSession = ChatSession(
      id: _sessionId,
      deviceId: widget.deviceId,
      licensePlate: plate.isNotEmpty ? plate : (session?.licensePlate ?? ''),
      startTimestamp:
          session?.startTimestamp ?? DateTime.now().millisecondsSinceEpoch,
      status: session?.status ?? ChatSessionStatus.draft,
      lastMessage: result.botReply.split('\n').first,
      vehicleData: mergedVehicleData,
      imagePaths: currentImagePaths,
      isReadyToPublish: isComplete && currentImagePaths.isNotEmpty,
    );
    await ChatSessionManager.saveSession(updatedSession);
    await _refreshSession();
  }

  Future<void> _saveMissingFields(Map<String, String> updatedValues) async {
    final merged = Map<String, String>.from(_vehicleData);
    for (final entry in updatedValues.entries) {
      final key = entry.key;
      var val = entry.value.trim();
      if (val.isEmpty) continue;
      if (key == 'price' ||
          key == 'km' ||
          key == 'hand' ||
          key == 'month' ||
          key == 'year' ||
          key == 'test_month' ||
          key == 'test_year') {
        val = val.replaceAll(RegExp(r'[^\d]'), '');
      }
      if (key == 'current_ownership' || key == 'previous_ownership') {
        if (val == 'פרטי') val = 'פרטית';
      }
      merged[key] = val;
    }

    if (merged['license_plate'] != null &&
        merged['license_plate']!.isNotEmpty) {
      _currentLicensePlate = merged['license_plate']!;
    }

    final missing = RemoteValidationService.getMissingFields(merged);
    final errors = RemoteValidationService.validateValues(merged);
    final isComplete = missing.isEmpty && errors.isEmpty;

    final session = await SqliteDatabaseHelper.instance.getSession(_sessionId);
    final currentImagePaths = List<String>.from(session?.imagePaths ?? []);

    final updatedSession = ChatSession(
      id: _sessionId,
      deviceId: widget.deviceId,
      licensePlate: _currentLicensePlate.isNotEmpty
          ? _currentLicensePlate
          : (session?.licensePlate ?? ''),
      startTimestamp:
          session?.startTimestamp ?? DateTime.now().millisecondsSinceEpoch,
      status: session?.status ?? ChatSessionStatus.draft,
      lastMessage: isComplete ? 'פרטי הרכב הושלמו' : 'עודכנו פרטים',
      vehicleData: merged,
      imagePaths: currentImagePaths,
      isReadyToPublish: isComplete && currentImagePaths.isNotEmpty,
    );

    await ChatSessionManager.saveSession(updatedSession);

    setState(() {
      _vehicleData = merged;
      _allDataFilled = isComplete && currentImagePaths.isNotEmpty;
    });

    String botReply;
    if (isComplete) {
      if (currentImagePaths.isNotEmpty) {
        botReply =
            '✅ כל פרטי הרכב הושלמו ומאומתים!\nלחץ על "פרסם עכשיו" להתחלת הפרסום ביד2.';
      } else {
        botReply =
            '✅ כל פרטי הרכב הושלמו ומאומתים!\n📷 אנא צרף לפחות תמונה אחת של הרכב כדי להתחיל בפרסום.';
      }
    } else {
      final errorLines = errors.map((e) => '⚠️ $e').toList();
      botReply = [
        '📝 עודכנו פרטי הרכב. נותרו ${missing.length} שדות להשלמה.',
        ...errorLines,
        'להשלמת פרטי הרכב — אנא מלא את השדות בטופס שלמטה:',
      ].join('\n\n');
    }

    final botMsg = ChatMessageItem(
      id: 'bot_${DateTime.now().microsecondsSinceEpoch}',
      sender: ChatSender.bot,
      text: botReply,
      timestamp: DateTime.now(),
    );

    if (mounted) {
      setState(() {
        _messages.add(botMsg);
      });
      _scrollToBottom();
    }
    await _saveMessagesToPrefs();
    await _refreshSession();
  }

  Future<void> _persistSessionUpdate(String lastMessage) async {
    try {
      final existing = await SqliteDatabaseHelper.instance.getSession(
        _sessionId,
      );
      final status = existing?.status ?? ChatSessionStatus.draft;
      final plate = _currentLicensePlate.isNotEmpty
          ? _currentLicensePlate
          : (existing?.licensePlate ?? '');
      await ChatSessionManager.saveSession(
        ChatSession(
          id: _sessionId,
          deviceId: widget.deviceId,
          licensePlate: plate,
          startTimestamp:
              existing?.startTimestamp ?? DateTime.now().millisecondsSinceEpoch,
          status: status,
          lastMessage: lastMessage,
          vehicleData: existing?.vehicleData ?? {},
          imagePaths: existing?.imagePaths ?? [],
          isReadyToPublish: existing?.isReadyToPublish ?? false,
        ),
      );
    } catch (e) {
      debugPrint('[WhatsAppChat] Error persisting session update: $e');
    }
  }

  Future<void> _sendSingleImageFile(File file) {
    if (_publicationState != null || _submitting) {
      _showError('לא ניתן לשנות תמונות לאחר ההגשה');
      return Future.value();
    }
    _pendingTurns++;
    _turns = _turns
        .then((_) => _persistImage(file))
        .catchError((Object e) => _showError('$e'))
        .whenComplete(() {
          _pendingTurns--;
          if (mounted) setState(() {});
        });
    return _turns;
  }

  Future<void> _persistImage(File file) async {
    if (!mounted || !_sameAccount || _publicationState != null) return;
    final messageId =
        'img_${DateTime.now().microsecondsSinceEpoch}_${file.hashCode.abs()}';

    final msgItem = ChatMessageItem(
      id: messageId,
      sender: ChatSender.user,
      mediaType: 'image',
      localFilePath: file.path,
      timestamp: DateTime.now(),
      isUploading: false,
      uploadProgress: 1.0,
    );

    setState(() {
      _messages.add(msgItem);
    });
    _scrollToBottom();
    _saveMessagesToPrefs();

    final session = await SqliteDatabaseHelper.instance.getSession(_sessionId);
    if (!mounted || !_sameAccount) return;
    final imgs = List<String>.from(session?.imagePaths ?? []);
    if (!imgs.contains(file.path)) {
      imgs.add(file.path);
    }

    final vehicleData = session?.vehicleData ?? {};
    final hasPlate =
        (vehicleData['license_plate'] ?? '').isNotEmpty ||
        _currentLicensePlate.isNotEmpty;
    final missing = RemoteValidationService.getMissingFields(vehicleData);
    final errors = RemoteValidationService.validateValues(vehicleData);
    final isNowReady =
        hasPlate && missing.isEmpty && errors.isEmpty && imgs.isNotEmpty;

    if (isNowReady) {
      _allDataFilled = true;
    }

    final updatedSession = ChatSession(
      id: _sessionId,
      deviceId: widget.deviceId,
      licensePlate: _currentLicensePlate.isNotEmpty
          ? _currentLicensePlate
          : (session?.licensePlate ?? ''),
      startTimestamp:
          session?.startTimestamp ?? DateTime.now().millisecondsSinceEpoch,
      status: session?.status ?? ChatSessionStatus.draft,
      lastMessage: isNowReady ? 'מוכן לפרסום' : '📷 תמונה (${imgs.length})',
      vehicleData: vehicleData,
      imagePaths: imgs,
      isReadyToPublish: isNowReady,
    );
    await ChatSessionManager.saveSession(updatedSession);

    if (isNowReady) {
      final confirmId = 'bot_${DateTime.now().microsecondsSinceEpoch}';
      final confirmMsg = ChatMessageItem(
        id: confirmId,
        sender: ChatSender.bot,
        text:
            '📷 נקלטה תמונה בהצלחה (${imgs.length})!\n✅ כל פרטי הרכב מלאים ומאומתים.\nלחץ על "פרסם עכשיו" כדי להתחיל בפרסום ביד2.',
        timestamp: DateTime.now(),
      );
      if (!mounted) return;
      setState(() {
        _messages.add(confirmMsg);
      });
      _scrollToBottom();
      _saveMessagesToPrefs();
    }
  }

  Future<File> _saveToPermanentStorage(File file) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final mediaDir = Directory('${appDir.path}/p2p_chat_media_local');
      if (!await mediaDir.exists()) {
        await mediaDir.create(recursive: true);
      }
      final fileName = file.uri.pathSegments.last;
      final targetPath =
          '${mediaDir.path}/${DateTime.now().microsecondsSinceEpoch}_$fileName';
      return await file.copy(targetPath);
    } catch (e) {
      debugPrint('[WhatsAppChat] Error saving to permanent storage: $e');
      return file; // Fallback to original
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
        source: source,
        imageQuality: 85,
        maxWidth: 1920,
      );
      if (picked == null) return;
      final permFile = await _saveToPermanentStorage(File(picked.path));
      await _sendSingleImageFile(permFile);
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
        final permFile = await _saveToPermanentStorage(File(picked.path));
        await _sendSingleImageFile(permFile);
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

      final file = await _saveToPermanentStorage(File(picked.path));
      final messageId = 'vid_${DateTime.now().microsecondsSinceEpoch}';

      final msgItem = ChatMessageItem(
        id: messageId,
        sender: ChatSender.user,
        mediaType: 'video',
        localFilePath: file.path,
        timestamp: DateTime.now(),
        isUploading: false,
        uploadProgress: 1.0,
      );

      setState(() {
        _messages.add(msgItem);
      });
      _scrollToBottom();
      _saveMessagesToPrefs();
      _persistSessionUpdate('🎥 וידאו');
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
          '${tempDir.path}/voice_${DateTime.now().microsecondsSinceEpoch}.m4a';

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

      final permFile = await _saveToPermanentStorage(file);

      final messageId = 'audio_${DateTime.now().microsecondsSinceEpoch}';
      final recordedDur = Duration(seconds: _recordSeconds);

      final msgItem = ChatMessageItem(
        id: messageId,
        sender: ChatSender.user,
        mediaType: 'audio',
        localFilePath: permFile.path,
        timestamp: DateTime.now(),
        isUploading: false,
        audioDuration: recordedDur,
      );

      setState(() {
        _messages.add(msgItem);
      });
      _scrollToBottom();
      _saveMessagesToPrefs();

      // Transcribe locally via Whisper on controller phone!
      final transcribedText = await RemoteValidationService.transcribeAudio(
        permFile,
        deviceId: widget.deviceId,
      );
      if (transcribedText != null && transcribedText.isNotEmpty) {
        _sendTextMessage(transcribedText);
      } else {
        final errorMsg = ChatMessageItem(
          id: 'bot_${DateTime.now().microsecondsSinceEpoch}',
          sender: ChatSender.bot,
          text: 'לא נקלט דיבור ברור בהקלטה. אנא נסה להקליט שוב או לשלוח כטקסט.',
          timestamp: DateTime.now(),
        );
        setState(() {
          _messages.add(errorMsg);
        });
        _scrollToBottom();
        _saveMessagesToPrefs();
      }
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
        builder: (_) => RemoteControlScreen(
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

          if (_messages.length >= 100)
            TextButton(
              onPressed: _loadOlderMessages,
              child: const Text('טען הודעות קודמות'),
            ),
          // Messages List
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final message = _messages[index];
                final isLast = index == _messages.length - 1;
                return _buildMessageBubble(message, isLastMessage: isLast);
              },
            ),
          ),

          // Global Action Chips (Publish, Pause, Quit)
          _buildGlobalActionChips(),

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
        builder: (context, _) => label(
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

                // 2. "שיחות" Button
                InkWell(
                  onTap: () {
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ChatSessionsListScreen(
                          deviceId: widget.deviceId,
                          deviceName: widget.deviceName,
                          session: widget.session,
                        ),
                      ),
                    );
                  },
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
                          Icons.queue_rounded,
                          color: AppColors.android,
                          size: 22,
                        ),
                        Text(
                          'שיחות',
                          style: GoogleFonts.heebo(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppColors.android,
                          ),
                        ),
                      ],
                    ),
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

  Widget _buildMessageBubble(
    ChatMessageItem message, {
    bool isLastMessage = false,
  }) {
    final isUser = message.sender == ChatSender.user;
    final timeStr = intl.DateFormat('HH:mm').format(message.timestamp);
    final isAdDraft =
        !isUser &&
        (message.text.contains('המודעה מוכנה') ||
            message.text.contains('טיוטה'));
    final missingFields = !isUser
        ? RemoteValidationService.getMissingFields(_vehicleData)
        : <String>[];
    final hasPlate =
        (_vehicleData['license_plate'] ?? '').isNotEmpty ||
        _currentLicensePlate.isNotEmpty;
    final showMissingFieldsForm =
        !isUser &&
        isLastMessage &&
        hasPlate &&
        missingFields.isNotEmpty &&
        _publicationState == null;

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
              child: SelectableText(
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

          // Inline Missing Fields Form
          if (showMissingFieldsForm) ...[
            const SizedBox(height: 8),
            MissingFieldsInlineForm(
              missingFields: missingFields,
              currentData: _vehicleData,
              onSave: _saveMissingFields,
            ),
          ],

          // Bot Quick Action Chips
          if (!isUser && isLastMessage && _publicationState == null)
            _buildQuickActionChips(message.text),
        ],
      ),
    );
  }

  Widget _buildAdDraftCard() => Card(
    child: ExpansionTile(
      title: Text('פרטי הרכב — ${_vehicleData['license_plate'] ?? ''}'),
      children: [
        for (final key in vehicleFieldLabels.keys)
          if ((_vehicleData[key] ?? '').isNotEmpty)
            ListTile(
              dense: true,
              title: Text(vehicleFieldLabels[key]!),
              trailing: Text(_vehicleData[key]!),
            ),
      ],
    ),
  );

  String _formatLicensePlate(String plate) {
    final clean = plate.replaceAll(RegExp(r'\D'), '');
    if (clean.length == 7) {
      return '${clean.substring(0, 2)}-${clean.substring(2, 5)}-${clean.substring(5, 7)}';
    } else if (clean.length == 8) {
      return '${clean.substring(0, 3)}-${clean.substring(3, 5)}-${clean.substring(5, 8)}';
    }
    return plate.isNotEmpty ? plate : '—';
  }

  void _showAggregatedGovVehicleDetails([String? plateToLookup]) {
    final plate =
        (plateToLookup != null && plateToLookup.isNotEmpty
                ? plateToLookup
                : (_currentLicensePlate.isNotEmpty
                      ? _currentLicensePlate
                      : (_vehicleData['license_plate'] ?? '')))
            .trim();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        bool isLoading = false;
        Map<String, String> displayData = Map<String, String>.from(
          _vehicleData,
        );

        return StatefulBuilder(
          builder: (context, setSheetState) {
            Future<void> fetchFreshData() async {
              if (plate.isEmpty) return;
              setSheetState(() => isLoading = true);
              try {
                final govInfo = await VehicleDataService.fetchVehicleData(
                  plate,
                );
                if (govInfo != null) {
                  for (final entry in govInfo.entries) {
                    final val = entry.value?.toString().trim() ?? '';
                    if (val.isNotEmpty) {
                      displayData[entry.key] = val;
                    }
                  }
                }
              } catch (e) {
                debugPrint('[WhatsAppChat] Error refreshing gov data: $e');
              } finally {
                if (sheetContext.mounted) {
                  setSheetState(() => isLoading = false);
                }
              }
            }

            Widget buildInfoRow(String label, String? value, {IconData? icon}) {
              final val = (value ?? '').trim();
              if (val.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                child: Row(
                  textDirection: TextDirection.rtl,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      textDirection: TextDirection.rtl,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (icon != null) ...[
                          Icon(icon, size: 16, color: AppColors.secondary),
                          const SizedBox(width: 6),
                        ],
                        Text(
                          label,
                          style: GoogleFonts.heebo(
                            fontSize: 13,
                            color: AppColors.secondary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    Flexible(
                      child: Text(
                        val,
                        textAlign: TextAlign.left,
                        style: GoogleFonts.heebo(
                          fontSize: 13.5,
                          color: AppColors.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }

            Widget buildSectionCard({
              required String title,
              required IconData icon,
              required List<Widget> children,
            }) {
              final visibleChildren = children.where((w) {
                if (w is SizedBox) {
                  return w.height != 0 && w.width != 0;
                }
                return true;
              }).toList();
              if (visibleChildren.isEmpty) return const SizedBox.shrink();

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: AppColors.surfaceSubtle,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.border),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        textDirection: TextDirection.rtl,
                        children: [
                          Icon(icon, size: 18, color: AppColors.primary),
                          const SizedBox(width: 8),
                          Text(
                            title,
                            style: GoogleFonts.heebo(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primary,
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 14, thickness: 0.8),
                      ...visibleChildren,
                    ],
                  ),
                ),
              );
            }

            return SafeArea(
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.85,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Drag handle
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: AppColors.border,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),

                      // Header with Plate Banner
                      Row(
                        textDirection: TextDirection.rtl,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'הצגת פרטי רכב ממאגרי הממשלה',
                                style: GoogleFonts.heebo(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.onSurface,
                                ),
                              ),
                              Text(
                                'נתונים מרוכזים ממאגרי data.gov.il',
                                style: GoogleFonts.heebo(
                                  fontSize: 12,
                                  color: AppColors.secondary,
                                ),
                              ),
                            ],
                          ),
                          // Yellow Israeli License Plate badge
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFD500),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: Colors.black,
                                width: 1.5,
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  color: Colors.black12,
                                  blurRadius: 3,
                                  offset: Offset(0, 1),
                                ),
                              ],
                            ),
                            child: Text(
                              _formatLicensePlate(plate),
                              style: GoogleFonts.heebo(
                                fontSize: 14,
                                fontWeight: FontWeight.w900,
                                color: Colors.black,
                                letterSpacing: 1.0,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),

                      if (isLoading)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(
                            child: Column(
                              children: [
                                CircularProgressIndicator(),
                                SizedBox(height: 10),
                                Text('שולף נתוני רכב משרתי הממשלה...'),
                              ],
                            ),
                          ),
                        )
                      else ...[
                        // 1. פרטי רכב כלליים (מאגר 053)
                        buildSectionCard(
                          title: 'פרטי רכב כלליים (מאגר רכב פעיל)',
                          icon: Icons.directions_car_rounded,
                          children: [
                            buildInfoRow(
                              'יצרן',
                              displayData['maker'],
                              icon: Icons.branding_watermark_rounded,
                            ),
                            buildInfoRow(
                              'דגם',
                              displayData['model'],
                              icon: Icons.model_training_rounded,
                            ),
                            buildInfoRow(
                              'שנת ייצור',
                              displayData['year'],
                              icon: Icons.calendar_today_rounded,
                            ),
                            buildInfoRow(
                              'צבע',
                              displayData['color'],
                              icon: Icons.palette_rounded,
                            ),
                            buildInfoRow(
                              'סוג דלק',
                              displayData['fuel_type'] ??
                                  displayData['fuelType'],
                              icon: Icons.local_gas_station_rounded,
                            ),
                            buildInfoRow(
                              'בעלות נוכחית',
                              displayData['current_ownership'] ??
                                  displayData['ownership'],
                              icon: Icons.person_outline_rounded,
                            ),
                          ],
                        ),

                        // 2. תיבת הילוכים ומפרט (מאגר 142)
                        buildSectionCard(
                          title: 'תיבת הילוכים (מאגר דגמי רכב)',
                          icon: Icons.settings_rounded,
                          children: [
                            buildInfoRow(
                              'תיבת הילוכים',
                              displayData['gear_type'] ?? displayData['gear'],
                              icon: Icons.swap_horiz_rounded,
                            ),
                          ],
                        ),

                        // 3. רישוי וטסט (מאגר 053)
                        buildSectionCard(
                          title: 'רישוי וטסט (מאגר רכב פעיל)',
                          icon: Icons.verified_rounded,
                          children: [
                            buildInfoRow(
                              'חודש עלייה לכביש',
                              displayData['month'] ??
                                  displayData['registrationMonth'],
                              icon: Icons.event_available_rounded,
                            ),
                            buildInfoRow(
                              'תוקף טסט',
                              displayData['testExpiry'] ??
                                  displayData['tokef_dt'],
                              icon: Icons.fact_check_rounded,
                            ),
                            buildInfoRow(
                              'תאריך טסט אחרון',
                              displayData['lastTestDate'],
                              icon: Icons.history_rounded,
                            ),
                          ],
                        ),

                        // 4. קילומטראז' (מאגר 560)
                        buildSectionCard(
                          title: "קילומטראז' (מאגר היסטוריית טסטים)",
                          icon: Icons.speed_rounded,
                          children: [
                            buildInfoRow(
                              'ק"מ בטסט אחרון',
                              displayData['kilometer_test_aharon'],
                              icon: Icons.history_edu_rounded,
                            ),
                            buildInfoRow(
                              'ק"מ משוער עדכני',
                              displayData['estimatedKm'] ?? displayData['km'],
                              icon: Icons.trending_up_rounded,
                            ),
                          ],
                        ),
                      ],

                      const SizedBox(height: 10),

                      // Action Buttons
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: isLoading ? null : fetchFreshData,
                              icon: const Icon(Icons.refresh_rounded, size: 18),
                              label: Text(
                                'רענן מ-gov.il',
                                style: GoogleFonts.heebo(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () async {
                                setState(() {
                                  _vehicleData.addAll(displayData);
                                  if (displayData['license_plate']
                                          ?.isNotEmpty ==
                                      true) {
                                    _currentLicensePlate =
                                        displayData['license_plate']!;
                                  }
                                });
                                await _persistSessionUpdate(
                                  'עודכנו פרטי רכב מ-gov.il',
                                );
                                if (sheetContext.mounted) {
                                  Navigator.pop(sheetContext);
                                }
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'פרטי הרכב עודכנו בהצלחה בטיוטת השיחה',
                                      ),
                                      backgroundColor: AppColors.success,
                                    ),
                                  );
                                }
                              },
                              icon: const Icon(Icons.check_rounded, size: 18),
                              label: Text(
                                'החל נתונים בשיחה',
                                style: GoogleFonts.heebo(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildGlobalActionChips() {
    final state = _publicationState;
    final busy = _submitting || _pendingTurns > 0;
    final actions = <Widget>[];
    if (busy)
      actions.add(
        const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    void action(String label, VoidCallback callback) => actions.add(
      ActionChip(label: Text(label), onPressed: busy ? null : callback),
    );
    final plate = _currentLicensePlate.isNotEmpty
        ? _currentLicensePlate
        : (_vehicleData['license_plate'] ?? '');
    if (plate.isNotEmpty || _vehicleData.isNotEmpty)
      action('הצגת פרטי רכב', () => _showAggregatedGovVehicleDetails(plate));
    if (state == null && _allDataFilled)
      action('פרסם עכשיו', () => _onPublishTapped());
    if (state == 'queued')
      actions.add(
        Text(ChatSessionManager.queueLabel(widget.deviceId, _sessionId)),
      );
    if (state == 'preparing' || state == 'publishing')
      action('הפסק', () => _control('pause'));
    if (state == 'paused' || state == 'stuck') {
      action('שליטה מרחוק', () => _switchToRemoteControl());
      action('המשך לאחר בדיקה', () => _control('resume'));
    }
    if (state != null &&
        !PublicationState.terminal.contains(state) &&
        state != 'canceling')
      action('סיום / ביטול', () => _control('cancel'));
    if (state == 'canceling')
      actions.add(const Text('ממתין לאישור ביטול מהמכשיר…'));
    if (state == 'completed')
      actions.add(const Text('✅ הפרסום הושלם ביד2 ובפייסבוק'));
    if (state == 'canceled') actions.add(const Text('הפרסום בוטל'));
    if (state == 'failed')
      actions.add(const Text('הפרסום נכשל — יש לבדוק את פרטי הבקשה'));
    if (actions.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Wrap(spacing: 10, runSpacing: 8, children: actions),
    );
  }

  Widget _buildQuickActionChips(String text) {
    if (_publicationState != null || _submitting)
      return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      children: [
        ActionChip(
          label: const Text('העלה תמונות (גלריה)'),
          onPressed: _pickMultiImage,
        ),
        ActionChip(
          label: const Text('צלם תמונה'),
          onPressed: () => _pickImage(ImageSource.camera),
        ),
      ],
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
              errorBuilder: (_, _, _) => Container(
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
                  value: isPlaying && _currentAudioDuration.inMilliseconds > 0
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
              child: _isRecording
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
                            onPressed: () =>
                                _stopAndSendRecording(cancel: true),
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
                            onLongPressEnd: (_) =>
                                _stopAndSendRecording(cancel: false),
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

class MissingFieldsInlineForm extends StatefulWidget {
  final List<String> missingFields;
  final Map<String, String> currentData;
  final Future<void> Function(Map<String, String> updatedValues) onSave;

  const MissingFieldsInlineForm({
    super.key,
    required this.missingFields,
    required this.currentData,
    required this.onSave,
  });

  @override
  State<MissingFieldsInlineForm> createState() =>
      _MissingFieldsInlineFormState();
}

class _MissingFieldsInlineFormState extends State<MissingFieldsInlineForm> {
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, String?> _dropdownValues = {};
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _initFields();
  }

  @override
  void didUpdateWidget(covariant MissingFieldsInlineForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.missingFields != widget.missingFields ||
        oldWidget.currentData != widget.currentData) {
      _initFields();
    }
  }

  void _initFields() {
    for (final field in widget.missingFields) {
      final existingVal = widget.currentData[field] ?? '';
      if (_isDropdownField(field)) {
        final options = _getFieldOptions(field);
        if (options.contains(existingVal)) {
          _dropdownValues[field] = existingVal;
        } else {
          _dropdownValues[field] = null;
        }
      } else {
        if (!_controllers.containsKey(field)) {
          _controllers[field] = TextEditingController(text: existingVal);
        } else {
          _controllers[field]!.text = existingVal;
        }
      }
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  bool _isDropdownField(String field) {
    if (vehicleEnums.containsKey(field)) return true;
    if (field == 'month' || field == 'test_month' || field == 'hand') {
      return true;
    }
    return false;
  }

  List<String> _getFieldOptions(String field) {
    if (vehicleEnums.containsKey(field)) {
      return vehicleEnums[field]!;
    }
    if (field == 'month' || field == 'test_month') {
      return List.generate(12, (i) => '${i + 1}');
    }
    if (field == 'hand') {
      return List.generate(10, (i) => '${i + 1}');
    }
    return [];
  }

  String _getFieldLabel(String field) {
    return vehicleFieldLabels[field] ?? field;
  }

  Future<void> _handleSave() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      final updated = <String, String>{};
      for (final field in widget.missingFields) {
        if (_isDropdownField(field)) {
          final val = _dropdownValues[field];
          if (val != null && val.isNotEmpty) {
            updated[field] = val;
          }
        } else {
          final val = _controllers[field]?.text.trim() ?? '';
          if (val.isNotEmpty) {
            updated[field] = val;
          }
        }
      }
      await widget.onSave(updated);
    } catch (e) {
      debugPrint('[MissingFieldsInlineForm] Error saving fields: $e');
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.missingFields.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.neutral,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.35),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header / Title
          Row(
            textDirection: TextDirection.rtl,
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.edit_document,
                  color: AppColors.primaryAction,
                  size: 18,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'להשלמת פרטי הרכב:',
                  textDirection: TextDirection.rtl,
                  style: GoogleFonts.heebo(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: AppColors.onSurface,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${widget.missingFields.length} חסרים',
                  textDirection: TextDirection.rtl,
                  style: GoogleFonts.heebo(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryAction,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(height: 1, color: AppColors.border),
          const SizedBox(height: 10),

          // Fields list
          ...widget.missingFields.map((field) => _buildFieldRow(field)),

          const SizedBox(height: 12),

          // Submit Button
          SizedBox(
            width: double.infinity,
            height: 42,
            child: ElevatedButton.icon(
              onPressed: _isSaving ? null : _handleSave,
              icon: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(
                      Icons.check_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
              label: Text(
                _isSaving ? 'שומר פרטים...' : 'שמור פרטים',
                style: GoogleFonts.heebo(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryAction,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFieldRow(String field) {
    final label = _getFieldLabel(field);
    final isDropdown = _isDropdownField(field);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Row(
          children: [
            // 1. Missing Field Name on the Right (First child in RTL)
            Expanded(
              flex: 4,
              child: Text(
                label,
                textDirection: TextDirection.rtl,
                style: GoogleFonts.heebo(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.onSurface,
                ),
              ),
            ),
            const SizedBox(width: 8),

            // 2. Input Field on the Left (Second child in RTL - physically to the left of field name!)
            Expanded(
              flex: 6,
              child: isDropdown
                  ? _buildDropdownInput(field)
                  : _buildTextInput(field),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDropdownInput(String field) {
    final options = _getFieldOptions(field);
    final currentVal = _dropdownValues[field];

    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceSubtle,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: options.contains(currentVal) ? currentVal : null,
          hint: Text(
            'בחר...',
            textDirection: TextDirection.rtl,
            style: GoogleFonts.heebo(
              fontSize: 12.5,
              color: AppColors.secondary,
            ),
          ),
          isExpanded: true,
          isDense: true,
          icon: const Icon(
            Icons.arrow_drop_down,
            color: AppColors.secondary,
            size: 20,
          ),
          items: options.map((opt) {
            return DropdownMenuItem<String>(
              value: opt,
              child: Text(
                opt,
                textDirection: TextDirection.rtl,
                style: GoogleFonts.heebo(
                  fontSize: 13,
                  color: AppColors.onSurface,
                ),
              ),
            );
          }).toList(),
          onChanged: (val) {
            setState(() {
              _dropdownValues[field] = val;
            });
          },
        ),
      ),
    );
  }

  Widget _buildTextInput(String field) {
    final controller = _controllers[field];
    final isNumeric =
        field == 'price' ||
        field == 'km' ||
        field == 'year' ||
        field == 'hand' ||
        field == 'month' ||
        field == 'test_year' ||
        field == 'test_month';

    String? suffix;
    if (field == 'price') suffix = '₪';
    if (field == 'km') suffix = 'ק״מ';

    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: AppColors.surfaceSubtle,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border),
      ),
      child: TextField(
        controller: controller,
        textDirection: isNumeric ? TextDirection.ltr : TextDirection.rtl,
        textAlign: isNumeric ? TextAlign.center : TextAlign.right,
        keyboardType: isNumeric ? TextInputType.number : TextInputType.text,
        style: GoogleFonts.heebo(
          fontSize: 13,
          color: AppColors.onSurface,
          fontWeight: isNumeric ? FontWeight.w600 : FontWeight.normal,
        ),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 9,
          ),
          border: InputBorder.none,
          hintText: isNumeric ? '0' : 'הזן...',
          hintStyle: GoogleFonts.heebo(
            fontSize: 12,
            color: AppColors.secondary,
          ),
          suffixText: suffix,
          suffixStyle: GoogleFonts.heebo(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: AppColors.primaryAction,
          ),
        ),
      ),
    );
  }
}
