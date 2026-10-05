import 'package:path/path.dart' as p;
import '../services/publication_image.dart';
import '../models/chat_message.dart';
export '../models/chat_message.dart';
import 'dart:convert';
import 'package:publication_protocol/publication_protocol.dart';
import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
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
import 'audio_plate_dialog.dart';
import '../services/audio_vehicle_form.dart';
import 'chat_message_bubble.dart';
import 'remote_control_screen.dart';
import 'chat_sessions_list_screen.dart';
import 'chat_session_manager.dart';
import '../database/sqlite_database_helper.dart';
import '../services/remote_validation_service.dart';
import '../services/vehicle_data_service.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../services/agent_config_service.dart';

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
  // Move the same editable form to the latest bot bubble after a correction.
  GlobalKey<_MissingFieldsInlineFormState> _missingFieldsFormKey = GlobalKey();

  final List<ChatMessageItem> _messages = [];
  StreamSubscription? _firestoreSub;
  StreamSubscription? _replySub;
  StreamSubscription? _playerStateSub;
  StreamSubscription? _playerPositionSub;

  bool _isRecording = false;
  bool _recordingBusy = false;
  bool _isTranscribing = false;
  bool _fetchingGovernment = false;
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

  bool get _canEditPublication =>
      ChatSessionManager.canEditPublication(_publicationState);
  bool _savingFields = false;

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
          RemoteValidationService.getMissingFields(saved.vehicleData).isEmpty &&
          RemoteValidationService.validateValues(saved.vehicleData).isEmpty &&
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
    _scrollToBottom();
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
    if (_publicationState != null ||
        _submitting ||
        _pendingTurns > 0 ||
        _recordingBusy) {
      _showError('לא ניתן לנקות שיחה במהלך פרסום או עיבוד');
      return;
    }
    for (final m in _messages) {
      if (m.localFilePath != null) {
        try {
          final f = File(m.localFilePath!);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
    await SqliteDatabaseHelper.instance.deleteMessages(_sessionId);
    await SqliteDatabaseHelper.instance.deleteSession(_sessionId);
    if (!mounted) return;
    setState(() {
      _messages.clear();
      _savedMessages.clear();
      _allDataFilled = false;
      _currentLicensePlate = '';
      _vehicleData = {};
      _missingFieldsFormKey = GlobalKey();
      _formSaveFeedback = null;
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
      String? resumePhase;
      final request = ChatSessionManager.request(widget.deviceId, _sessionId);
      if (command == 'resume' && request?['parked'] != true) {
        final choices = List<Map<String, dynamic>>.from(
          (request?['resumeOptions'] as List? ?? []).map(
            (v) => Map<String, dynamic>.from(v as Map),
          ),
        );
        if (choices.isNotEmpty) {
          if (!mounted) return;
          resumePhase = await showDialog<String>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('מאיזה שלב להמשיך?'),
              content: SizedBox(
                width: double.maxFinite,
                child: ListView(
                  shrinkWrap: true,
                  children: choices
                      .map(
                        (choice) => ListTile(
                          title: Text(choice['label'] as String),
                          onTap: () => Navigator.of(
                            dialogContext,
                          ).pop(choice['name'] as String),
                        ),
                      )
                      .toList(),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('השאר מושהה'),
                ),
              ],
            ),
          );
          if (resumePhase == null || !mounted) return;
        }
      }
      await ChatSessionManager.control(
        widget.deviceId,
        _sessionId,
        command,
        resumePhase: resumePhase,
      );
    } catch (e) {
      _showError('$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _onPublishTapped() async {
    if (_submitting || _savingFields || !_canEditPublication) return;
    setState(() => _submitting = true);
    try {
      await _turns;
      if (!_sameAccount || !mounted) return;
      final saved = await SqliteDatabaseHelper.instance.getSession(_sessionId);
      if (saved == null) throw StateError('יש להשלים את פרטי הרכב');

      if (saved.vehicleData.containsKey('color')) {
        final rawColor = saved.vehicleData['color']!;
        final allowedColors = AgentConfigService.instance.allowedColors;
        String matchedColor = '';
        if (allowedColors.contains(rawColor)) {
          matchedColor = rawColor;
        } else {
          final colorPart = rawColor.split(' ').first.trim();
          if (allowedColors.contains(colorPart)) {
            matchedColor = colorPart;
          } else {
            matchedColor = await _matchColorWithLlm(rawColor, allowedColors);
          }
        }
        if (matchedColor.isNotEmpty && matchedColor != rawColor) {
          saved.vehicleData['color'] = matchedColor;
          await ChatSessionManager.saveSession(saved);
        }
      }

      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null && uid.isNotEmpty) {
        try {
          final userDoc = await FirebaseFirestore.instance
              .collection('users')
              .doc(uid)
              .get();
          final settings = userDoc.data()?['settings'] as Map<String, dynamic>?;
          if (settings != null && settings.containsKey('includeYad2')) {
            final bool incYad2 = settings['includeYad2'] ?? true;
            saved.vehicleData['includeYad2'] = incYad2 ? 'true' : 'false';
          }
        } catch (_) {}
      }

      await ChatSessionManager.startPublication(widget.deviceId, saved);
      await _refreshSession();
    } catch (e) {
      _showError('$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<String> _matchColorWithLlm(
    String rawColor,
    List<String> allowedColors,
  ) async {
    try {
      await AgentConfigService.instance.checkAndUpdateConfigIfNeeded();
      final prefs = await SharedPreferences.getInstance();
      final apiKey =
          prefs.getString('anthropic_api_key') ??
          const String.fromEnvironment('ANTHROPIC_API_KEY', defaultValue: '');

      if (apiKey.isEmpty) {
        return _fallbackColorMatch(rawColor, allowedColors);
      }

      final prompt = AgentConfigService.defaultColorMatchingPromptTemplate
          .replaceAll('{raw_color}', rawColor)
          .replaceAll('{allowed_colors}', allowedColors.join(', '));

      final body = jsonEncode({
        'model': 'gpt-5.6-luna',
        'max_completion_tokens': 512,
        'reasoning_effort': 'low',
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
      });

      final response = await http.post(
        Uri.parse('https://api.openai.com/v1/chat/completions'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: body,
      );

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final contentText =
            (decoded['content'] as List?)
                ?.whereType<Map>()
                .where((c) => c['type'] == 'text')
                .map((c) => c['text'] as String)
                .join(' ')
                .trim() ??
            '';

        final cleanResult = contentText.trim().replaceAll(
          RegExp(r'[^\u0590-\u05FF]'),
          '',
        );
        for (final allowed in allowedColors) {
          if (cleanResult == allowed ||
              allowed.contains(cleanResult) ||
              cleanResult.contains(allowed)) {
            return allowed;
          }
        }
      }
    } catch (e) {
      debugPrint('[WhatsAppChat] LLM color matching error: $e');
    }

    return _fallbackColorMatch(rawColor, allowedColors);
  }

  String _fallbackColorMatch(String rawColor, List<String> allowedColors) {
    final norm = rawColor.toLowerCase();
    if (norm.contains('כסף') ||
        norm.contains('אפור') ||
        norm.contains('עכבר')) {
      return 'אפור';
    }
    if (norm.contains('זהב') ||
        norm.contains('צהוב') ||
        norm.contains('נחושת')) {
      return 'צהוב';
    }
    if (norm.contains('פנינה') ||
        norm.contains('שנהב') ||
        norm.contains('שמנת') ||
        norm.contains('קרם')) {
      return 'לבן';
    }
    if (norm.contains('תכלת') ||
        norm.contains('כחול') ||
        norm.contains('טורקיז')) {
      return 'כחול';
    }
    if (norm.contains('בורדו') || norm.contains('אדום')) return 'אדום';
    if (norm.contains('חום') || norm.contains('בז')) return 'חום';
    if (norm.contains('ירוק')) return 'ירוק';
    if (norm.contains('כתום')) return 'כתום';
    if (norm.contains('סגול')) return 'סגול';
    if (norm.contains('ורוד')) return 'ורוד';
    if (norm.contains('שחור')) return 'שחור';

    // Also try substring matching backwards (e.g., if allowed is "כסוף" and rawColor is "כסף")
    for (final allowed in allowedColors) {
      if (allowed.contains(norm)) return allowed;
    }

    return rawColor;
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
    if (!_canEditPublication || _submitting) {
      _showError('הבקשה הוגשה. לשינוי הפרטים יש לבטל ולפתוח בקשה חדשה.');
      return;
    }
    _queueTextTurn(text);
  }

  void _queueTextTurn(
    String text, {
    Map<String, String>? recordedAudioFields,
    String? confirmedAudioPlate,
  }) {
    if (!mounted || !_sameAccount) return;
    if (!_canEditPublication || _submitting) {
      _showError('הבקשה הוגשה. לשינוי הפרטים יש לבטל ולפתוח בקשה חדשה.');
      return;
    }
    final recorded = recordedAudioFields == null
        ? null
        : Map<String, String>.unmodifiable(recordedAudioFields);
    _pendingTurns++;
    setState(() {});
    _turns = _turns
        .then(
          (_) => _processTextTurn(
            text,
            recordedAudioFields: recorded,
            confirmedAudioPlate: confirmedAudioPlate,
          ),
        )
        .catchError((Object e) => _showError('$e'))
        .whenComplete(() {
          _pendingTurns--;
          if (mounted) setState(() => _fetchingGovernment = false);
        });
  }

  Future<void> _processTextTurn(
    String text, {
    Map<String, String>? recordedAudioFields,
    String? confirmedAudioPlate,
  }) async {
    if (!mounted || !_sameAccount || !_canEditPublication) return;
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

    if (recordedAudioFields != null &&
        (currentVehicleData['license_plate'] != confirmedAudioPlate ||
            currentVehicleData['govIl'] != 'true')) {
      setState(() {
        _fetchingGovernment = true;
        _messages.add(
          ChatMessageItem(
            id: 'gov_status_${DateTime.now().microsecondsSinceEpoch}',
            sender: ChatSender.bot,
            text: 'מאחזר נתוני רכב מ־gov.il…',
            timestamp: DateTime.now(),
          ),
        );
      });
      _scrollToBottom();
      _saveMessagesToPrefs();
    }

    // The authenticated backend extracts fields and looks up the vehicle.
    final result = await RemoteValidationService.processTurn(
      deviceId: widget.deviceId,
      incomingText: text,
      currentVehicleData: currentVehicleData,
      chatHistory: historyList,
      currentImagePaths: currentImagePaths,
      recordedAudioFields: recordedAudioFields,
      confirmedAudioPlate: confirmedAudioPlate,
    );

    if (!mounted || !_sameAccount) return;
    if ((currentVehicleData['license_plate'] ?? '').isNotEmpty &&
        currentVehicleData['license_plate'] !=
            result.vehicleData['license_plate']) {
      currentImagePaths = [];
      _missingFieldsFormKey = GlobalKey();
    }
    if (result.vehicleData['license_plate'] != null) {
      _currentLicensePlate = result.vehicleData['license_plate']!;
    }

    final plate = _currentLicensePlate.isNotEmpty
        ? _currentLicensePlate
        : (result.vehicleData['license_plate'] ?? '');

    // Merge vehicle data with gov.il sources if needed
    final reviewAudioData =
        recordedAudioFields != null ||
        (currentVehicleData.containsKey('audio_form_fields') &&
            currentVehicleData['license_plate'] ==
                result.vehicleData['license_plate']);
    final mergedVehicleData = <String, String>{
      if (reviewAudioData && currentVehicleData['license_plate'] == plate)
        ...currentVehicleData,
      ...result.vehicleData,
    };
    final needsGovernmentEnrichment =
        recordedAudioFields == null ||
        currentVehicleData['license_plate'] != plate ||
        currentVehicleData['govIl'] != 'true';
    if (plate.isNotEmpty && needsGovernmentEnrichment) {
      try {
        final govInfo = await VehicleDataService.fetchVehicleData(plate);
        if (govInfo != null && govInfo.isNotEmpty) {
          if (recordedAudioFields != null) {
            AudioVehicleForm.enrichGovernment(mergedVehicleData, govInfo);
          } else {
            mergedVehicleData['govIl'] = 'true';
            for (final entry in govInfo.entries) {
              final key = entry.key;
              final val = entry.value?.toString().trim() ?? '';
              if (val.isNotEmpty && (mergedVehicleData[key] ?? '').isEmpty) {
                mergedVehicleData[key] = val;
              }
            }
          }
        } else if (mergedVehicleData['govIl'] != 'true') {
          mergedVehicleData['govIl'] = 'false';
        }
      } catch (e) {
        if (mergedVehicleData['govIl'] != 'true') {
          mergedVehicleData['govIl'] = 'false';
        }
        debugPrint('[WhatsAppChat] Error fetching gov.il data in turn: $e');
      }
    } else if (plate.isEmpty) {
      mergedVehicleData['govIl'] = 'false';
    }

    if (reviewAudioData) {
      mergedVehicleData.addAll(
        AudioVehicleForm.markForReview(mergedVehicleData),
      );
    }
    final missing = RemoteValidationService.getMissingFields(mergedVehicleData);

    if (mergedVehicleData['initial_missing_fields'] == null) {
      mergedVehicleData['initial_missing_fields'] = missing.join(',');
    }

    final allErrors = RemoteValidationService.validateValues(mergedVehicleData);
    final errors = _getFilteredErrors(allErrors, mergedVehicleData, missing);
    final isComplete = missing.isEmpty && allErrors.isEmpty;

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
                ? '✅ כל פרטי הרכב מלאים ומאומתים!\nלחץ על כפתור הפרסום להתחלת הפרסום ביד2.'
                : '📷 אנא צרף לפחות תמונה אחת של הרכב כדי להתחיל בפרסום.');
      final errorLines = errors.map((e) => '⚠️ $e').toList();
      finalBotReply = [
        if (summary.isNotEmpty) summary,
        ...result.governmentConflicts,
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

  List<String> _getFilteredErrors(
    List<String> allErrors,
    Map<String, String> data,
    List<String> missing,
  ) {
    final formFields = List<String>.from(missing);
    if (!formFields.contains('km')) formFields.add('km');
    if (!formFields.contains('hand')) formFields.add('hand');
    if (!formFields.contains('previous_ownership')) {
      formFields.add('previous_ownership');
    }
    if (data['force_show_current_ownership'] == 'true' &&
        !formFields.contains('current_ownership')) {
      formFields.add('current_ownership');
    }

    final labelsToFilter = formFields
        .map((f) => vehicleFieldLabels[f] ?? f)
        .toSet();

    return allErrors.where((err) {
      for (final label in labelsToFilter) {
        if (err.startsWith(label)) return false;
      }
      return true;
    }).toList();
  }

  String? _formSaveFeedback;

  Future<void> _saveMissingFields(Map<String, String> updatedValues) async {
    if (!_canEditPublication || _submitting || !_sameAccount || _savingFields) {
      throw StateError('לא ניתן לערוך בקשה במהלך פרסום');
    }
    setState(() => _savingFields = true);
    try {
      await _persistVehicleFields(updatedValues);
    } finally {
      if (mounted) setState(() => _savingFields = false);
    }
  }

  Future<void> _persistVehicleFields(Map<String, String> updatedValues) async {
    final merged = Map<String, String>.from(_vehicleData);
    for (final entry in updatedValues.entries) {
      final key = entry.key;
      var val = entry.value.trim();
      if (val.isEmpty && key != 'highlights') continue;
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

    if (merged.containsKey('test_until')) {
      final tu = merged['test_until'];
      if (tu != null && tu.contains('/')) {
        final parts = tu.split('/');
        if (parts.length == 2) {
          merged['test_month'] = int.tryParse(parts[0])?.toString() ?? parts[0];
          merged['test_year'] = parts[1];
        }
      } else if (tu == null || tu.isEmpty || tu == 'null') {
        merged.remove('test_month');
        merged.remove('test_year');
      }
    }

    if (updatedValues.containsKey('govIl')) {
      merged['govIl'] = updatedValues['govIl']!;
    } else if (!merged.containsKey('govIl') ||
        merged['govIl'] == null ||
        merged['govIl']!.isEmpty) {
      merged['govIl'] = 'false';
    }

    if (merged['license_plate'] != null &&
        merged['license_plate']!.isNotEmpty) {
      _currentLicensePlate = merged['license_plate']!;
    }

    if (merged['initial_missing_fields'] == null) {
      final missingNow = RemoteValidationService.getMissingFields(merged);
      merged['initial_missing_fields'] = [
        ...missingNow,
        ...updatedValues.keys,
      ].join(',');
    }

    final missing = RemoteValidationService.getMissingFields(merged);
    final allErrors = RemoteValidationService.validateValues(merged);
    final errors = _getFilteredErrors(allErrors, merged, missing);
    final isComplete = missing.isEmpty && allErrors.isEmpty;

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
            '✅ כל פרטי הרכב הושלמו ומאומתים!\nלחץ על כפתור הפרסום להתחלת הפרסום ביד2.';
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
      mediaType: !isComplete ? 'missing_fields_form' : null,
      timestamp: DateTime.now(),
    );

    if (mounted) {
      setState(() {
        _messages.add(botMsg);
        _formSaveFeedback = '✅ הפרטים נשמרו';
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
    if (!_canEditPublication || _submitting) {
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
    if (!mounted || !_sameAccount || !_canEditPublication) return;
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

  Future<File> _prepareImage(String path) async {
    final directory = Directory(
      p.join(
        (await getApplicationDocumentsDirectory()).path,
        'p2p_chat_media_local',
      ),
    );
    await directory.create(recursive: true);
    return preparePublicationImage(File(path), directory);
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
        source: source,
        imageQuality: 85,
        maxWidth: 1920,
      );
      if (picked == null) return;
      final permFile = await _prepareImage(picked.path);
      await _sendSingleImageFile(permFile);
    } catch (e) {
      _showError('לא ניתן לצרף את התמונה: $e');
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
        final permFile = await _prepareImage(picked.path);
        await _sendSingleImageFile(permFile);
        await Future.delayed(const Duration(milliseconds: 120));
      }
    } catch (e) {
      _showError('לא ניתן לצרף את התמונות: $e');
    }
  }

  /// Delete a single image message, cleaning up local storage, SQLite database,
  /// backend Firestore and Firebase Storage, and updating the session imagePaths
  /// and readiness state so it is never published to the main Pirsumoto app.
  Future<void> _deleteImageMessage(ChatMessageItem message) async {
    if (!_canEditPublication || _submitting) {
      _showError('לא ניתן למחוק תמונות במהלך פרסום או עיבוד');
      return;
    }

    try {
      // 1. Delete local file from storage
      if (message.localFilePath != null) {
        try {
          final file = File(message.localFilePath!);
          if (await file.exists()) {
            await file.delete();
          }
        } catch (e) {
          debugPrint('[WhatsAppChat] Error deleting local image file: $e');
        }
      }

      // 2. Delete message from local SQLite DB
      await SqliteDatabaseHelper.instance.deleteMessage(_sessionId, message.id);
      _savedMessages.remove(message.id);

      // 3. Delete message doc from Firestore
      try {
        await FirebaseFirestore.instance
            .collection('remote_chats')
            .doc(widget.deviceId)
            .collection('messages')
            .doc(message.id)
            .delete();
      } catch (e) {
        debugPrint('[WhatsAppChat] Error deleting Firestore message: $e');
      }

      // 4. Delete from Firebase Storage if a remote media URL exists
      if (message.mediaUrl != null && message.mediaUrl!.isNotEmpty) {
        try {
          final ref = FirebaseStorage.instance.refFromURL(message.mediaUrl!);
          await ref.delete();
        } catch (e) {
          debugPrint('[WhatsAppChat] Error deleting from FirebaseStorage: $e');
        }
      }

      // 5. Clean up any uploaded publication attempt media for this session if present
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        try {
          final storageRef = FirebaseStorage.instance.ref(
            'publication_media/$uid/${widget.deviceId}/$_sessionId',
          );
          final listResult = await storageRef.listAll();
          for (final item in listResult.items) {
            await item.delete();
          }
          for (final prefix in listResult.prefixes) {
            final subList = await prefix.listAll();
            for (final item in subList.items) {
              await item.delete();
            }
          }
        } catch (_) {}
      }

      // 6. Remove from in-memory messages list
      setState(() {
        _messages.removeWhere((m) => m.id == message.id);
      });

      // 7. Update session image paths and readiness
      final session = await SqliteDatabaseHelper.instance.getSession(
        _sessionId,
      );
      final currentImgs = List<String>.from(session?.imagePaths ?? []);
      if (message.localFilePath != null) {
        currentImgs.remove(message.localFilePath);
        final fileName = message.localFilePath!.split('/').last;
        currentImgs.removeWhere((p) => p.endsWith(fileName));
      }
      if (message.mediaUrl != null) {
        currentImgs.remove(message.mediaUrl);
      }

      final vehicleData = session?.vehicleData ?? _vehicleData;
      final hasPlate =
          (_currentLicensePlate.isNotEmpty) ||
          ((vehicleData['license_plate'] ?? '').isNotEmpty);
      final missing = RemoteValidationService.getMissingFields(vehicleData);
      final errors = RemoteValidationService.validateValues(vehicleData);
      final isNowReady =
          hasPlate &&
          missing.isEmpty &&
          errors.isEmpty &&
          currentImgs.isNotEmpty;

      _allDataFilled = isNowReady;

      final updatedSession = ChatSession(
        id: _sessionId,
        deviceId: widget.deviceId,
        licensePlate: _currentLicensePlate.isNotEmpty
            ? _currentLicensePlate
            : (session?.licensePlate ?? ''),
        startTimestamp:
            session?.startTimestamp ?? DateTime.now().millisecondsSinceEpoch,
        status: session?.status ?? ChatSessionStatus.draft,
        lastMessage: isNowReady
            ? 'מוכן לפרסום'
            : (currentImgs.isNotEmpty
                  ? '📷 תמונה (${currentImgs.length})'
                  : 'הוסרה תמונה'),
        vehicleData: vehicleData,
        imagePaths: currentImgs,
        isReadyToPublish: isNowReady,
      );
      await ChatSessionManager.saveSession(updatedSession);
      await _refreshSession();
      await _saveMessagesToPrefs();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              currentImgs.isNotEmpty
                  ? 'התמונה נמחקה (נותרו ${currentImgs.length} תמונות)'
                  : 'התמונה נמחקה. יש לצרף לפחות תמונה אחת כדי לפרסם.',
              textDirection: TextDirection.rtl,
            ),
            duration: const Duration(seconds: 2),
            backgroundColor: AppColors.surface,
          ),
        );
      }
    } catch (e) {
      debugPrint('[WhatsAppChat] Error deleting image: $e');
      _showError('שגיאה במחיקת התמונה: $e');
    }
  }

  /// Batch delete multiple selected image paths
  Future<void> _deleteSelectedImages(List<String> pathsToDelete) async {
    if (!_canEditPublication || _submitting) {
      _showError('לא ניתן למחוק תמונות במהלך פרסום או עיבוד');
      return;
    }
    if (pathsToDelete.isEmpty) return;

    try {
      final pathsSet = pathsToDelete.toSet();
      final messagesToDelete = _messages.where((m) {
        if (m.mediaType != 'image') return false;
        if (m.localFilePath != null && pathsSet.contains(m.localFilePath)) {
          return true;
        }
        if (m.mediaUrl != null && pathsSet.contains(m.mediaUrl)) return true;
        if (m.localFilePath != null) {
          final fn = m.localFilePath!.split('/').last;
          if (pathsToDelete.any((p) => p.endsWith(fn))) return true;
        }
        return false;
      }).toList();

      for (final msg in messagesToDelete) {
        if (msg.localFilePath != null) {
          try {
            final f = File(msg.localFilePath!);
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
        await SqliteDatabaseHelper.instance.deleteMessage(_sessionId, msg.id);
        _savedMessages.remove(msg.id);
        try {
          await FirebaseFirestore.instance
              .collection('remote_chats')
              .doc(widget.deviceId)
              .collection('messages')
              .doc(msg.id)
              .delete();
        } catch (_) {}
        if (msg.mediaUrl != null && msg.mediaUrl!.isNotEmpty) {
          try {
            final ref = FirebaseStorage.instance.refFromURL(msg.mediaUrl!);
            await ref.delete();
          } catch (_) {}
        }
      }

      // Directly delete any file in pathsToDelete that wasn't bound to an in-memory message
      for (final path in pathsToDelete) {
        try {
          final f = File(path);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }

      final idsToDelete = messagesToDelete.map((m) => m.id).toSet();
      setState(() {
        _messages.removeWhere((m) => idsToDelete.contains(m.id));
      });

      final session = await SqliteDatabaseHelper.instance.getSession(
        _sessionId,
      );
      final currentImgs = List<String>.from(session?.imagePaths ?? []);
      currentImgs.removeWhere(
        (p) =>
            pathsSet.contains(p) ||
            pathsToDelete.any((d) => p.endsWith(d.split('/').last)),
      );

      final vehicleData = session?.vehicleData ?? _vehicleData;
      final hasPlate =
          (_currentLicensePlate.isNotEmpty) ||
          ((vehicleData['license_plate'] ?? '').isNotEmpty);
      final missing = RemoteValidationService.getMissingFields(vehicleData);
      final errors = RemoteValidationService.validateValues(vehicleData);
      final isNowReady =
          hasPlate &&
          missing.isEmpty &&
          errors.isEmpty &&
          currentImgs.isNotEmpty;

      _allDataFilled = isNowReady;

      final updatedSession = ChatSession(
        id: _sessionId,
        deviceId: widget.deviceId,
        licensePlate: _currentLicensePlate.isNotEmpty
            ? _currentLicensePlate
            : (session?.licensePlate ?? ''),
        startTimestamp:
            session?.startTimestamp ?? DateTime.now().millisecondsSinceEpoch,
        status: session?.status ?? ChatSessionStatus.draft,
        lastMessage: isNowReady
            ? 'מוכן לפרסום'
            : (currentImgs.isNotEmpty
                  ? '📷 תמונה (${currentImgs.length})'
                  : 'הוסרו תמונות'),
        vehicleData: vehicleData,
        imagePaths: currentImgs,
        isReadyToPublish: isNowReady,
      );
      await ChatSessionManager.saveSession(updatedSession);
      await _refreshSession();
      await _saveMessagesToPrefs();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'נמחקו ${pathsToDelete.length} תמונות בהצלחה',
              textDirection: TextDirection.rtl,
            ),
            duration: const Duration(seconds: 2),
            backgroundColor: AppColors.surface,
          ),
        );
      }
    } catch (e) {
      debugPrint('[WhatsAppChat] Error batch deleting images: $e');
      _showError('שגיאה במחיקת תמונות: $e');
    }
  }

  void _confirmAndDeleteImage(ChatMessageItem message) {
    if (!_canEditPublication || _submitting) {
      _showError('לא ניתן למחוק תמונות במהלך פרסום');
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              const Icon(Icons.delete_outline_rounded, color: AppColors.error),
              const SizedBox(width: 8),
              Text(
                'מחיקת תמונה',
                style: GoogleFonts.heebo(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: Text(
            'האם למחוק תמונה זו?\nהתמונה תוסר מפרסום הרכב, תימחק מהמכשיר ומהשרת, ולא תישלח לפרסום.',
            style: GoogleFonts.heebo(fontSize: 14, color: AppColors.onSurface),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(
                'ביטול',
                style: GoogleFonts.heebo(color: AppColors.secondary),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () {
                Navigator.pop(ctx);
                _deleteImageMessage(message);
              },
              child: Text(
                'מחק תמונה',
                style: GoogleFonts.heebo(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showFullScreenImagePreview(ChatMessageItem message) {
    final hasLocal =
        message.localFilePath != null &&
        File(message.localFilePath!).existsSync();
    final hasUrl = message.mediaUrl != null && message.mediaUrl!.isNotEmpty;

    ImageProvider? imageProvider;
    if (hasLocal) {
      imageProvider = FileImage(File(message.localFilePath!));
    } else if (hasUrl) {
      imageProvider = NetworkImage(message.mediaUrl!);
    }

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 4.0,
                child: imageProvider != null
                    ? Image(image: imageProvider, fit: BoxFit.contain)
                    : const Icon(
                        Icons.broken_image_rounded,
                        color: Colors.white54,
                        size: 64,
                      ),
              ),
            ),
            // Top Action Bar
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.close_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                    if (_canEditPublication && !_submitting)
                      IconButton(
                        tooltip: 'מחק תמונה',
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          color: Colors.white,
                          size: 28,
                        ),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _confirmAndDeleteImage(message);
                        },
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showManageImagesSheet() async {
    final session = await SqliteDatabaseHelper.instance.getSession(_sessionId);
    final imgs = List<String>.from(session?.imagePaths ?? []);
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        final selected = <String>{};
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final imageMessages = _messages
                .where((m) => m.mediaType == 'image')
                .toList();
            // Combine paths from session and messages
            final allPaths = <String>[];
            for (final p in imgs) {
              if (!allPaths.contains(p)) allPaths.add(p);
            }
            for (final m in imageMessages) {
              if (m.localFilePath != null &&
                  !allPaths.contains(m.localFilePath)) {
                allPaths.add(m.localFilePath!);
              }
            }

            return SafeArea(
              child: Directionality(
                textDirection: TextDirection.rtl,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Header
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.photo_library_rounded,
                                color: AppColors.primaryAction,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'תמונות הרכב (${allPaths.length})',
                                style: GoogleFonts.heebo(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.onSurface,
                                ),
                              ),
                            ],
                          ),
                          IconButton(
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => Navigator.pop(sheetContext),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'בחר תמונות להסרה או לחץ על פח האשפה למחיקה מיידית.',
                        style: GoogleFonts.heebo(
                          fontSize: 12.5,
                          color: AppColors.secondary,
                        ),
                      ),
                      const SizedBox(height: 12),

                      if (allPaths.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 32),
                          child: Center(
                            child: Column(
                              children: [
                                const Icon(
                                  Icons.add_photo_alternate_rounded,
                                  size: 48,
                                  color: AppColors.secondary,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'אין תמונות מצורפות לרכב זה',
                                  style: GoogleFonts.heebo(
                                    fontSize: 14,
                                    color: AppColors.secondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      else
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight:
                                MediaQuery.of(context).size.height * 0.45,
                          ),
                          child: GridView.builder(
                            shrinkWrap: true,
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 3,
                                  crossAxisSpacing: 8,
                                  mainAxisSpacing: 8,
                                  childAspectRatio: 1.0,
                                ),
                            itemCount: allPaths.length,
                            itemBuilder: (context, i) {
                              final path = allPaths[i];
                              final isSelected = selected.contains(path);
                              final file = File(path);
                              final fileExists = file.existsSync();

                              return GestureDetector(
                                onTap: () {
                                  setSheetState(() {
                                    if (isSelected) {
                                      selected.remove(path);
                                    } else {
                                      selected.add(path);
                                    }
                                  });
                                },
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(10),
                                      child: fileExists
                                          ? Image.file(file, fit: BoxFit.cover)
                                          : (path.startsWith('http')
                                                ? Image.network(
                                                    path,
                                                    fit: BoxFit.cover,
                                                  )
                                                : Container(
                                                    color:
                                                        AppColors.surfaceSubtle,
                                                    child: const Icon(
                                                      Icons
                                                          .broken_image_rounded,
                                                    ),
                                                  )),
                                    ),
                                    if (isSelected)
                                      Container(
                                        decoration: BoxDecoration(
                                          color: AppColors.primary.withValues(
                                            alpha: 0.4,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                          border: Border.all(
                                            color: AppColors.primary,
                                            width: 2.5,
                                          ),
                                        ),
                                      ),
                                    // Selection checkbox indicator
                                    Positioned(
                                      top: 4,
                                      right: 4,
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: isSelected
                                              ? AppColors.primary
                                              : Colors.black45,
                                          shape: BoxShape.circle,
                                        ),
                                        padding: const EdgeInsets.all(2),
                                        child: Icon(
                                          isSelected
                                              ? Icons.check
                                              : Icons.circle_outlined,
                                          size: 16,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                    // Single delete icon
                                    if (_canEditPublication && !_submitting)
                                      Positioned(
                                        bottom: 4,
                                        left: 4,
                                        child: GestureDetector(
                                          onTap: () {
                                            Navigator.pop(sheetContext);
                                            final matchingMsg = _messages
                                                .firstWhere(
                                                  (m) =>
                                                      m.localFilePath == path ||
                                                      m.mediaUrl == path,
                                                  orElse: () => ChatMessageItem(
                                                    id: 'tmp_${DateTime.now().microsecondsSinceEpoch}',
                                                    sender: ChatSender.user,
                                                    localFilePath: path,
                                                    timestamp: DateTime.now(),
                                                  ),
                                                );
                                            _confirmAndDeleteImage(matchingMsg);
                                          },
                                          child: Container(
                                            decoration: const BoxDecoration(
                                              color: Colors.black54,
                                              shape: BoxShape.circle,
                                            ),
                                            padding: const EdgeInsets.all(4),
                                            child: const Icon(
                                              Icons.delete_outline_rounded,
                                              size: 16,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),

                      const SizedBox(height: 14),

                      // Action buttons
                      Row(
                        children: [
                          if (selected.isNotEmpty &&
                              _canEditPublication &&
                              !_submitting) ...[
                            Expanded(
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.error,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 10,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                icon: const Icon(
                                  Icons.delete_sweep_rounded,
                                  size: 18,
                                ),
                                label: Text(
                                  'מחק נבחרות (${selected.length})',
                                  style: GoogleFonts.heebo(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                onPressed: () {
                                  Navigator.pop(sheetContext);
                                  _deleteSelectedImages(selected.toList());
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Expanded(
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              icon: const Icon(
                                Icons.add_photo_alternate_rounded,
                                size: 18,
                              ),
                              label: Text(
                                'הוסף תמונות',
                                style: GoogleFonts.heebo(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              onPressed: () {
                                Navigator.pop(sheetContext);
                                _showAttachmentMenu();
                              },
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
    if (_recordingBusy || _isRecording || !_canEditPublication) return;
    _recordingBusy = true;
    try {
      final hasPermission = await _audioRecorder.hasPermission();
      if (!hasPermission) {
        _showError('יש לאפשר גישה למיקרופון בהגדרות המכשיר כדי להקליט.');
        return;
      }

      final tempDir = await getTemporaryDirectory();
      final path =
          '${tempDir.path}/voice_${DateTime.now().microsecondsSinceEpoch}.m4a';

      await _audioRecorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 32000),
        path: path,
      );

      if (!mounted) {
        await _audioRecorder.cancel();
        return;
      }
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
      _showError('לא ניתן להתחיל הקלטה: $e');
    } finally {
      _recordingBusy = false;
    }
  }

  Future<void> _stopAndSendRecording({bool cancel = false}) async {
    if (_recordingBusy || !_isRecording) return;
    _recordingBusy = true;
    _recordTimer?.cancel();
    _recordTimer = null;

    try {
      final path = await _audioRecorder.stop();
      if (mounted) setState(() => _isRecording = false);

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
        _isTranscribing = true;
      });
      _scrollToBottom();
      _saveMessagesToPrefs();

      // Transcribe on the authenticated backend, then review before applying.
      final transcriptionResult = await RemoteValidationService.transcribeAudio(
        permFile,
        deviceId: widget.deviceId,
        currentVehicleData: _vehicleData,
      );
      if (!mounted || !_sameAccount) return;
      setState(() => _isTranscribing = false);

      final transcribedText = transcriptionResult?['text'] as String?;
      final extractedFields =
          transcriptionResult?['extracted_fields'] as Map<String, dynamic>? ??
          {};
      final plateCandidates =
          [
                ...(transcriptionResult?['license_plate_candidates']
                        as List<dynamic>? ??
                    []),
                ...(transcriptionResult?['license_plate_fragments']
                        as List<dynamic>? ??
                    []),
              ]
              .whereType<String>()
              .map((plate) => plate.replaceAll(RegExp(r'\D'), ''))
              .where((plate) => plate.isNotEmpty)
              .toSet()
              .toList();

      if (transcribedText != null && transcribedText.isNotEmpty) {
        final fields = <String, String>{
          for (final entry in extractedFields.entries)
            if (entry.value != null) entry.key: entry.value.toString(),
        };
        // A preceding recording may still be fetching its confirmed vehicle.
        await _turns;
        if (!mounted || !_sameAccount) return;
        final currentPlate = _vehicleData['license_plate'] ?? '';
        var confirmedPlate = currentPlate;
        if (plateCandidates.length > 1 ||
            (plateCandidates.isNotEmpty &&
                plateCandidates.singleOrNull != currentPlate) ||
            !_vehicleData.containsKey('audio_form_fields') ||
            AudioVehicleForm.needsPlateConfirmation(
              fields['license_plate'],
              currentPlate,
            )) {
          final plate = await showDialog<String>(
            context: context,
            barrierDismissible: false,
            builder: (_) => AudioPlateDialog(
              plate: plateCandidates.length > 1
                  ? ''
                  : plateCandidates.firstOrNull ??
                        fields['license_plate'] ??
                        currentPlate,
              candidates: plateCandidates,
            ),
          );
          if (!mounted || !_sameAccount || plate == null) return;
          confirmedPlate = plate;
        }
        _queueTextTurn(
          transcribedText,
          recordedAudioFields: fields,
          confirmedAudioPlate: confirmedPlate,
        );
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
      _showError('עיבוד ההקלטה נכשל: $e');
      if (mounted) setState(() => _isRecording = false);
    } finally {
      _recordingBusy = false;
      if (mounted) setState(() => _isTranscribing = false);
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
          ownsSession: !identical(session, widget.session),
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
                final isLastBotMessage =
                    index ==
                    _messages.lastIndexWhere(
                      (m) =>
                          m.sender == ChatSender.bot &&
                          !m.id.startsWith('gov_status_'),
                    );
                return _buildMessageBubble(
                  message,
                  isLastMessage: isLast,
                  isLastBotMessage: isLastBotMessage,
                );
              },
            ),
          ),

          if (_isTranscribing || _fetchingGovernment)
            AudioProcessingIndicator(fetchingGovernment: _fetchingGovernment),

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
    bool isLastBotMessage = false,
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
        message.mediaType == 'missing_fields_form' ||
        message.text.contains(
          'להשלמת פרטי הרכב — אנא מלא את השדות בטופס שלמטה',
        );

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
          if ((showMissingFieldsForm || _vehicleData.isNotEmpty) &&
              isLastBotMessage) ...[
            const SizedBox(height: 8),
            AbsorbPointer(
              absorbing: !_canEditPublication,
              child: MissingFieldsInlineForm(
                key: _missingFieldsFormKey,
                missingFields: missingFields,
                currentData: _vehicleData,
                onSave: _saveMissingFields,
                feedback: _formSaveFeedback,
                enabled: _canEditPublication,
                editAll: _publicationState != null,
              ),
            ),
          ],

          // Bot Quick Action Chips
          if (!isUser && isLastBotMessage && _canEditPublication)
            _buildQuickActionChips(message.text),
          if (!isUser && isLastBotMessage) _buildGlobalActionChips(),
        ],
      ),
    );
  }

  Widget _buildAdDraftCard() => Card(
    child: ExpansionTile(
      title: Text('פרטי הרכב — ${_vehicleData['license_plate'] ?? ''}'),
      children: [
        for (final key in _vehicleData.keys.where(
          (k) => k != 'initial_missing_fields',
        ))
          if ((_vehicleData[key] ?? '').isNotEmpty &&
              _vehicleData[key] != 'null')
            ListTile(
              dense: true,
              title: Text(vehicleFieldLabels[key] ?? key),
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

                        // 5. היסטוריית בעלויות
                        buildSectionCard(
                          title: 'היסטוריית בעלויות',
                          icon: Icons.history_edu_rounded,
                          children: [
                            buildInfoRow(
                              'יד (סה"כ)',
                              displayData['hand'],
                              icon: Icons.format_list_numbered_rounded,
                            ),
                            buildInfoRow(
                              'בעלות קודמת',
                              displayData['previous_ownership'],
                              icon: Icons.person_add_alt_1_rounded,
                            ),
                            Builder(
                              builder: (context) {
                                List<dynamic> history = [];
                                try {
                                  if (displayData['history_records'] != null) {
                                    history = jsonDecode(
                                      displayData['history_records']!,
                                    );
                                  }
                                } catch (_) {}
                                if (history.isEmpty)
                                  return const SizedBox.shrink();
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Divider(
                                      height: 16,
                                      color: AppColors.border,
                                    ),
                                    ...history.map((r) {
                                      final dt =
                                          r['baalut_dt']?.toString() ?? '';
                                      final baalut =
                                          r['baalut']?.toString() ?? '';
                                      String formattedDt = dt;
                                      if (dt.length == 6) {
                                        formattedDt =
                                            '${dt.substring(4, 6)}/${dt.substring(0, 4)}';
                                      }
                                      return buildInfoRow(
                                        'תאריך: $formattedDt',
                                        baalut,
                                        icon: Icons.history_rounded,
                                      );
                                    }).toList(),
                                  ],
                                );
                              },
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
                              onPressed: () {
                                if (sheetContext.mounted) {
                                  Navigator.pop(sheetContext);
                                }
                              },
                              icon: const Icon(Icons.close_rounded, size: 18),
                              label: Text(
                                'סגור',
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
    final busy =
        _submitting || _savingFields || _pendingTurns > 0 || _recordingBusy;
    final actions = <Widget>[];
    if (busy && !_isTranscribing && !_fetchingGovernment)
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
    if (state == 'queued')
      actions.add(
        Text(ChatSessionManager.queueLabel(widget.deviceId, _sessionId)),
      );
    if (state == 'preparing' || state == 'publishing')
      action('הפסק', () => _control('pause'));
    if (state == 'paused' || state == 'stuck') {
      action('שליטה מרחוק', () => _switchToRemoteControl());
      action('המשך לאחר בדיקה', () => _control('resume'));
      final parked =
          ChatSessionManager.request(widget.deviceId, _sessionId)?['parked'] ==
          true;
      if (!parked) action('השאר מושהה והמשך בתור', () => _control('park'));
      if (parked)
        actions.add(
          const Text(
            'מושהה מחוץ לתור. המשך יחזיר לתור ויתחיל מחדש באתר שלא הושלם; יש לבדוק קודם שלא פורסם.',
          ),
        );
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
    if (!_canEditPublication || _submitting) return const SizedBox.shrink();
    final imageCount = _messages.where((m) => m.mediaType == 'image').length;
    final busy = _savingFields || _pendingTurns > 0 || _recordingBusy;
    return Wrap(
      spacing: 8,
      children: [
        ActionChip(
          label: const Text('העלה תמונות (גלריה)'),
          onPressed: busy ? null : _pickMultiImage,
        ),
        ActionChip(
          label: const Text('צלם תמונה'),
          onPressed: busy ? null : () => _pickImage(ImageSource.camera),
        ),
        if (imageCount > 0)
          ActionChip(
            avatar: const Icon(Icons.photo_library_outlined, size: 16),
            label: Text('ניהול תמונות ($imageCount)'),
            onPressed: busy ? null : _showManageImagesSheet,
          ),
        if ((_vehicleData['license_plate'] ?? '').isNotEmpty ||
            _currentLicensePlate.isNotEmpty) ...[
          ActionChip(
            label: Text(
              _publicationState == 'completed' ? 'פרסם שוב' : 'פרסם עכשיו',
            ),
            backgroundColor: _publicationState == 'completed'
                ? AppColors.warningSoft
                : null,
            onPressed: !busy && _allDataFilled ? _onPublishTapped : null,
          ),
          if (_publicationState == null)
            ActionChip(
              label: const Text('ביטול'),
              onPressed: busy ? null : _clearChatData,
            ),
        ],
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
      child: GestureDetector(
        onTap: () => _showFullScreenImagePreview(message),
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
            // Delete button overlay
            if (_canEditPublication && !_submitting)
              Positioned(
                top: 8,
                left: 8,
                child: Material(
                  color: Colors.black54,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => _confirmAndDeleteImage(message),
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(
                        Icons.delete_outline_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                ),
              ),
            // Zoom indicator
            Positioned(
              bottom: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.zoom_in_rounded, size: 14, color: Colors.white),
                    SizedBox(width: 3),
                    Text(
                      'הגדל',
                      style: TextStyle(color: Colors.white, fontSize: 10),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
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

class AudioProcessingIndicator extends StatelessWidget {
  final bool fetchingGovernment;

  const AudioProcessingIndicator({super.key, required this.fetchingGovernment});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: Row(
      textDirection: TextDirection.rtl,
      children: [
        const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            fetchingGovernment
                ? 'מאחזר נתוני רכב מ־gov.il…'
                : 'מתמלל את ההקלטה ומזהה את פרטי הרכב…',
            textDirection: TextDirection.rtl,
          ),
        ),
      ],
    ),
  );
}

class MissingFieldsInlineForm extends StatefulWidget {
  final String? feedback;
  final bool editAll;
  final bool enabled;
  final List<String> missingFields;
  final Map<String, String> currentData;
  final Future<void> Function(Map<String, String> updatedValues) onSave;

  const MissingFieldsInlineForm({
    super.key,
    this.feedback,
    this.editAll = false,
    this.enabled = true,
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
  bool _noTest = false;
  String? _saveFeedback;

  @override
  void initState() {
    super.initState();
    _initFields();
  }

  @override
  void didUpdateWidget(covariant MissingFieldsInlineForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    for (final field in _fieldsToShow) {
      if (field == 'test_until') continue;
      if (oldWidget.currentData[field] == widget.currentData[field]) continue;
      final value = widget.currentData[field] ?? '';
      if (field == 'clean_title') {
        _dropdownValues[field] = {'כן', 'true', '1'}.contains(value)
            ? 'כן'
            : 'לא';
      } else if (_isDropdownField(field)) {
        _dropdownValues[field] = value;
      } else {
        _controllers[field]?.text = value;
      }
    }
    if (oldWidget.currentData['test_month'] !=
            widget.currentData['test_month'] ||
        oldWidget.currentData['test_year'] != widget.currentData['test_year'] ||
        oldWidget.currentData['test_until'] !=
            widget.currentData['test_until']) {
      final month = widget.currentData['test_month'] ?? '';
      final year = widget.currentData['test_year'] ?? '';
      _controllers['test_until']?.text =
          widget.currentData['test_until'] ??
          (month.isNotEmpty && year.isNotEmpty
              ? '${month.padLeft(2, '0')}/$year'
              : '');
    }
    _initFields();
  }

  List<String> get _fieldsToShow {
    List<String> fields = [];
    if (widget.currentData['initial_missing_fields'] != null &&
        widget.currentData['initial_missing_fields']!.isNotEmpty) {
      fields = widget.currentData['initial_missing_fields']!.split(',');
    }

    final manuallyFillable = [
      'license_plate',
      'maker',
      'trim',
      'model',
      'year',
      'fuel_type',
      'gear_type',
      'month',
      'price',
      'km',
      'hand',
      'previous_ownership',
      'current_ownership',
      'color',
      'test_year',
      'test_month',
      'engine_capacity',
      'phone',
      'city',
      'area',
      'contact_name',
      'vehicle_condition',
      'description',
    ];

    final bool isGovIl = widget.currentData['govIl'] == 'true';

    final Set<String> combined = Set.from(fields);
    // Include all explicitly requested missing fields
    combined.addAll(widget.missingFields);
    combined.addAll(
      (widget.currentData['audio_form_fields'] ?? '')
          .split(',')
          .where((field) => field.isNotEmpty),
    );

    // If NOT govIl, include any field that already has a value, so the user can edit it if needed.
    if (!isGovIl || widget.editAll) {
      for (final f in manuallyFillable) {
        final val = widget.currentData[f];
        if (val != null && val.isNotEmpty && val != 'null') {
          combined.add(f);
        }
      }
    }

    fields = combined.toList();

    if (!fields.contains('km')) {
      fields.add('km');
    }
    if (!fields.contains('previous_ownership')) {
      fields.add('previous_ownership');
    }
    if (widget.currentData['force_show_current_ownership'] == 'true' &&
        !fields.contains('current_ownership')) {
      fields.add('current_ownership');
    }
    final bool hasTestDate =
        (widget.currentData['test_year'] ?? '').isNotEmpty &&
        (widget.currentData['test_month'] ?? '').isNotEmpty;
    if (!isGovIl || !hasTestDate || widget.editAll) {
      if (!fields.contains('test_until')) fields.add('test_until');
      fields.remove('test_year');
      fields.remove('test_month');
    }
    fields.remove('clean_title');
    fields.remove('highlights');
    fields.addAll(['clean_title', 'highlights']);
    return fields;
  }

  void _initFields() {
    for (final field in _fieldsToShow) {
      if (field == 'clean_title') {
        _dropdownValues[field] ??=
            {'כן', 'true', '1'}.contains(widget.currentData[field])
            ? 'כן'
            : 'לא';
        continue;
      }
      var existingVal = (widget.currentData[field] ?? '').trim();
      if (field == 'km' &&
          (existingVal.isEmpty || existingVal == '0') &&
          !widget.currentData.containsKey('audio_form_fields')) {
        final estKm =
            (widget.currentData['estimatedKm'] ??
                    widget.currentData['kilometer_test_aharon'] ??
                    '')
                .trim();
        if (estKm.isNotEmpty && estKm != '0') {
          existingVal = estKm;
        }
      }
      if (field == 'previous_ownership' && existingVal.isEmpty) {
        final prev =
            (widget.currentData['ownershipHistory'] ??
                    widget.currentData['prev_ownership'] ??
                    widget.currentData['previousOwnership'] ??
                    '')
                .trim();
        if (prev.isNotEmpty) {
          existingVal = prev;
        }
      }

      if (field == 'test_until') {
        _noTest = {'true', 'כן', '1'}.contains(widget.currentData['no_test']);
        if (existingVal.isEmpty) {
          final tm = widget.currentData['test_month'];
          final ty = widget.currentData['test_year'];
          if (tm != null &&
              tm.isNotEmpty &&
              ty != null &&
              ty.isNotEmpty &&
              ty != 'null' &&
              tm != 'null') {
            existingVal = '${tm.padLeft(2, '0')}/$ty';
          }
        }
        if (!_controllers.containsKey(field)) {
          final c = TextEditingController(text: existingVal);
          c.addListener(() {
            if (mounted) setState(() {});
          });
          _controllers[field] = c;
        }
        continue;
      }
      if (_isDropdownField(field)) {
        final options = _getFieldOptions(field);
        if (options.contains(existingVal)) {
          if (_dropdownValues[field] == null ||
              _dropdownValues[field]!.isEmpty) {
            _dropdownValues[field] = existingVal;
          }
        } else if (existingVal == 'פרטי' && options.contains('פרטית')) {
          if (_dropdownValues[field] == null ||
              _dropdownValues[field]!.isEmpty) {
            _dropdownValues[field] = 'פרטית';
          }
        } else if (existingVal == 'פרטית' && options.contains('פרטי')) {
          if (_dropdownValues[field] == null ||
              _dropdownValues[field]!.isEmpty) {
            _dropdownValues[field] = 'פרטי';
          }
        } else if (existingVal.isNotEmpty) {
          // If the current saved value isn't in the predefined options, we still want to keep it.
          if (_dropdownValues[field] == null ||
              _dropdownValues[field]!.isEmpty) {
            _dropdownValues[field] = existingVal;
          }
        }
      } else {
        if (!_controllers.containsKey(field)) {
          final c = TextEditingController(text: existingVal);
          c.addListener(() {
            if (mounted) setState(() {});
          });
          _controllers[field] = c;
        } else {
          if (field == 'highlights') continue;
          if ((_controllers[field]!.text.trim().isEmpty ||
                  _controllers[field]!.text.trim() == '0') &&
              existingVal.isNotEmpty &&
              existingVal != '0') {
            _controllers[field]!.text = existingVal;
          }
        }
      }
    }
  }

  bool _isFieldFilled(String field) {
    if (field == 'test_until') {
      return _noTest || (_controllers['test_until']?.text.isNotEmpty ?? false);
    }
    if (_isDropdownField(field)) {
      final val = _dropdownValues[field]?.trim();
      if (val == null || val.isEmpty || val == 'בחר...' || val == '0') {
        return false;
      }
      return true;
    } else {
      final val = _controllers[field]?.text.trim() ?? '';
      if (val.isEmpty || (val == '0' && field != 'km') || val == 'הזן...') {
        return false;
      }
      final digitsOnly = val.replaceAll(RegExp(r'[^\d]'), '');
      if (digitsOnly.isNotEmpty) {
        final n = int.tryParse(digitsOnly);
        if (n != null && n == 0 && field != 'km') return false;
      }
      return true;
    }
  }

  bool get _canSave {
    if (!widget.enabled) return false;
    if (_isSaving) return false;
    if (_fieldsToShow.isEmpty) return false;
    for (final field in _fieldsToShow) {
      if (!{'clean_title', 'highlights'}.contains(field) &&
          (!_isFieldFilled(field) ||
              AudioVehicleForm.error(
                    field,
                    _isDropdownField(field)
                        ? (_dropdownValues[field] ?? '')
                        : (_controllers[field]?.text.trim() ?? ''),
                  ) !=
                  null)) {
        return false;
      }
    }
    return true;
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  bool _isDropdownField(String field) {
    if (field == 'clean_title') return false;
    if (vehicleEnums.containsKey(field)) return true;
    if (field == 'month' ||
        field == 'test_month' ||
        field == 'hand' ||
        field == 'year') {
      return true;
    }
    return false;
  }

  List<String> _getFieldOptions(String field) {
    if (vehicleEnums.containsKey(field)) {
      if (field == 'gear_type' || field == 'gear') {
        return vehicleEnums[field]!
            .where((e) => e == 'שידור ידני' || e == 'הילוכים אוטומטיים')
            .toList();
      }
      return vehicleEnums[field]!;
    }
    if (field == 'month' || field == 'test_month') {
      return List.generate(12, (i) => '${i + 1}');
    }
    if (field == 'hand') {
      return List.generate(10, (i) => '${i + 1}');
    }
    if (field == 'year') {
      final currentYear = DateTime.now().year;
      return List.generate(
        currentYear + 1 - 2005 + 1,
        (i) => '${currentYear + 1 - i}',
      );
    }
    return [];
  }

  String _getFieldLabel(String field) {
    return vehicleFieldLabels[field] ?? field;
  }

  Future<void> _handleSave() async {
    if (!_canSave || _isSaving) return;
    setState(() {
      _isSaving = true;
      _saveFeedback = null;
    });
    try {
      final updated = <String, String>{};
      // Always send no_test (independent of govIl / test_until visibility).
      // _noTest is only initialised when the test_until row exists, so when
      // that row is hidden keep the value we already have.
      final bool noTestValue = _fieldsToShow.contains('test_until')
          ? _noTest
          : {'true', 'כן', '1'}.contains(widget.currentData['no_test']);
      updated['no_test'] = noTestValue ? 'true' : 'false';
      final bool isGovIl = widget.currentData['govIl'] == 'true';
      updated['govIl'] = isGovIl ? 'true' : 'false';
      for (final field in _fieldsToShow) {
        if (field == 'clean_title') {
          updated[field] = _dropdownValues[field] ?? 'לא';
          continue;
        }
        if (field == 'test_until' && _noTest) {
          updated[field] = '';
          continue;
        }
        if (_isDropdownField(field)) {
          final val = _dropdownValues[field]?.trim();
          if (val != null && val.isNotEmpty) {
            updated[field] = val;
          }
        } else {
          final val = _controllers[field]?.text.trim() ?? '';
          if (val.isNotEmpty || field == 'highlights') {
            updated[field] = val;
          }
        }
      }
      if (updated.isNotEmpty) {
        await widget.onSave(updated);
        if (mounted) setState(() => _saveFeedback = '✅ הפרטים נשמרו');
      }
    } catch (e) {
      if (mounted) setState(() => _saveFeedback = 'שמירת הפרטים נכשלה: $e');
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_fieldsToShow.isEmpty) return const SizedBox.shrink();

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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.editAll
                          ? 'עריכת פרטי הרכב:'
                          : 'להשלמת פרטי רכב חסרים:',
                      textDirection: TextDirection.rtl,
                      style: GoogleFonts.heebo(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: AppColors.onSurface,
                      ),
                    ),
                    if (widget.currentData['govIl'] == 'false' ||
                        (widget.currentData['govIl'] != 'true' &&
                            (widget.currentData['maker'] ?? '').isEmpty))
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'מכיון שלא נמצא מידע על הרכב במשרד התחבורה, מיד לאחר תחילת הפרסום תתבקש להשלים את פרטי היצרן ותת-הדגם מתוך ממשק יד2',
                          textDirection: TextDirection.rtl,
                          style: GoogleFonts.heebo(
                            fontSize: 12,
                            color: AppColors.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(height: 1, color: AppColors.border),
          const SizedBox(height: 10),

          // Fields list
          ..._fieldsToShow
              .where((field) => !{'clean_title', 'highlights'}.contains(field))
              .map((field) => _buildFieldRow(field)),
          const Divider(key: ValueKey('optional_vehicle_data_divider')),
          Text(
            'פרטים נוספים (לא חובה)',
            textDirection: TextDirection.rtl,
            style: GoogleFonts.heebo(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Directionality(
            textDirection: TextDirection.rtl,
            child: Material(
              color: Colors.transparent,
              child: CheckboxListTile(
                key: const ValueKey('clean_title_checkbox'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(_getFieldLabel('clean_title')),
                value: _dropdownValues['clean_title'] == 'כן',
                onChanged: _isSaving
                    ? null
                    : (checked) {
                        setState(
                          () => _dropdownValues['clean_title'] = checked == true
                              ? 'כן'
                              : 'לא',
                        );
                      },
              ),
            ),
          ),
          _buildFieldRow('highlights'),

          const SizedBox(height: 12),

          if ((_saveFeedback ?? widget.feedback) != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _saveFeedback ?? widget.feedback!,
                textDirection: TextDirection.rtl,
              ),
            ),
          // Submit Button
          SizedBox(
            width: double.infinity,
            height: 42,
            child: ElevatedButton.icon(
              onPressed: _canSave ? _handleSave : null,
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
                disabledBackgroundColor: AppColors.primaryAction.withValues(
                  alpha: 0.38,
                ),
                foregroundColor: Colors.white,
                disabledForegroundColor: Colors.white.withValues(alpha: 0.6),
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
    if (field == 'test_until') return _buildTestUntilRow();

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

  Widget _buildTestUntilRow() {
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
            Expanded(
              flex: 3,
              child: Text(
                'טסט עד',
                textDirection: TextDirection.rtl,
                style: GoogleFonts.heebo(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.onSurface,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 4,
              child: GestureDetector(
                onTap: _noTest
                    ? null
                    : () async {
                        final date = await showDatePicker(
                          context: context,
                          initialDate: DateTime.now(),
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2050),
                        );
                        if (date != null) {
                          setState(() {
                            if (!_controllers.containsKey('test_until')) {
                              _controllers['test_until'] =
                                  TextEditingController();
                            }
                            _controllers['test_until']!.text =
                                "${date.month.toString().padLeft(2, '0')}/${date.year}";
                          });
                        }
                      },
                child: Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: _noTest
                        ? AppColors.surfaceSubtle.withOpacity(0.5)
                        : AppColors.surfaceSubtle,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppColors.border),
                  ),
                  alignment: Alignment.centerRight,
                  child: Text(
                    _controllers['test_until']?.text.isNotEmpty == true
                        ? _controllers['test_until']!.text
                        : 'בחר תאריך',
                    style: GoogleFonts.heebo(
                      fontSize: 13,
                      color: _noTest
                          ? AppColors.secondary
                          : AppColors.onSurface,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 3,
              child: InkWell(
                onTap: () {
                  setState(() {
                    _noTest = !_noTest;
                    if (_noTest) {
                      _controllers['test_until']?.text = '';
                    }
                  });
                },
                borderRadius: BorderRadius.circular(6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      height: 20,
                      width: 20,
                      child: Checkbox(
                        value: _noTest,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                        onChanged: (val) {
                          setState(() {
                            _noTest = val ?? false;
                            if (_noTest) {
                              _controllers['test_until']?.text = '';
                            }
                          });
                        },
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'ללא טסט',
                      style: GoogleFonts.heebo(
                        fontSize: 11,
                        color: AppColors.onSurface,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDropdownInput(String field) {
    final options = List<String>.from(_getFieldOptions(field));
    final currentVal = _dropdownValues[field];
    if (currentVal != null &&
        currentVal.isNotEmpty &&
        !options.contains(currentVal)) {
      options.add(currentVal);
    }

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
    final value = controller?.text.trim() ?? '';
    final error = value.isEmpty ? null : AudioVehicleForm.error(field, value);
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
      height: field == 'highlights' || error != null ? null : 38,
      decoration: BoxDecoration(
        color: AppColors.surfaceSubtle,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border),
      ),
      child: TextField(
        key: ValueKey('missing_field_$field'),
        controller: controller,
        minLines: field == 'highlights' ? 2 : 1,
        maxLines: field == 'highlights' ? 4 : 1,
        onChanged: (_) => setState(() {}),
        textDirection: isNumeric ? TextDirection.ltr : TextDirection.rtl,
        textAlign: isNumeric ? TextAlign.center : TextAlign.right,
        keyboardType: isNumeric
            ? TextInputType.number
            : field == 'highlights'
            ? TextInputType.multiline
            : TextInputType.text,
        style: GoogleFonts.heebo(
          fontSize: 13,
          color: AppColors.onSurface,
          fontWeight: isNumeric ? FontWeight.w600 : FontWeight.normal,
        ),
        decoration: InputDecoration(
          errorText: error,
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
