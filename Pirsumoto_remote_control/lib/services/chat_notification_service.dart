import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../ui/whatsapp_chat_screen.dart';
import '../ui/chat_session_manager.dart';
import '../database/sqlite_database_helper.dart';
import 'remote_llm_service.dart';

/// Global navigator key to allow notification taps to open the chat screen from anywhere.
final GlobalKey<NavigatorState> remoteControlNavigatorKey =
    GlobalKey<NavigatorState>();

class ChatNotificationService {
  ChatNotificationService._internal();
  static final ChatNotificationService instance =
      ChatNotificationService._internal();

  static const String channelId = 'pirsumoto_chat_notifications';
  static const String channelName = 'הודעות פירסומוטו';
  static const String channelDesc =
      'התראות על הודעות חדשות מהבוט של פירסומוטו';

  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  bool _isInitialized = false;
  final int _serviceStartTime =
      DateTime.now().millisecondsSinceEpoch - 3000;
  final Set<String> _processedMessageIds = <String>{};
  final Map<String, String> _deviceNames = <String, String>{};
  final Map<String, StreamSubscription> _deviceSubscriptions =
      <String, StreamSubscription>{};

  StreamSubscription? _authSub;
  StreamSubscription? _devicesSub;

  /// Initialize local notifications and background Firestore listeners
  Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;

    try {
      const androidInit =
          AndroidInitializationSettings('@mipmap/launcher_icon');
      const initSettings = InitializationSettings(
        android: androidInit,
      );

      await _localNotifications.initialize(
        settings: initSettings,
        onDidReceiveNotificationResponse: _onNotificationTapped,
      );

      final androidImpl = _localNotifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      if (androidImpl != null) {
        // Create high importance notification channel
        const channel = AndroidNotificationChannel(
          channelId,
          channelName,
          description: channelDesc,
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
          showBadge: true,
        );
        await androidImpl.createNotificationChannel(channel);

        // Request runtime permission on Android 13+
        await androidImpl.requestNotificationsPermission();
      }

      // Check if launched by tapping a notification
      final launchDetails =
          await _localNotifications.getNotificationAppLaunchDetails();
      if (launchDetails != null &&
          launchDetails.didNotificationLaunchApp &&
          launchDetails.notificationResponse != null) {
        _onNotificationTapped(launchDetails.notificationResponse!);
      }

      _startAuthAndDeviceListeners();
      debugPrint('[ChatNotificationService] Successfully initialized');
    } catch (e, st) {
      debugPrint('[ChatNotificationService] Initialization error: $e\n$st');
    }
  }

  /// Handles user tapping on a notification
  void _onNotificationTapped(NotificationResponse response) {
    final payload = response.payload;
    debugPrint('[ChatNotificationService] Notification tapped with payload: $payload');
    if (payload == null || payload.isEmpty) return;

    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      final deviceId = data['deviceId'] as String?;
      final deviceName =
          data['deviceName'] as String? ?? 'מכשיר ($deviceId)';

      if (deviceId != null && deviceId.isNotEmpty) {
        _navigateToChat(deviceId: deviceId, deviceName: deviceName);
      }
    } catch (e) {
      debugPrint('[ChatNotificationService] Error parsing payload: $e');
    }
  }

  /// Navigates to WhatsAppChatScreen if not already viewing it
  void _navigateToChat({
    required String deviceId,
    required String deviceName,
  }) {
    // If user is already on the chat screen for this device, don't duplicate
    if (WhatsAppChatScreen.isInsideChatWith(deviceId)) {
      return;
    }

    final navState = remoteControlNavigatorKey.currentState;
    if (navState != null) {
      navState.push(
        MaterialPageRoute(
          builder: (_) => WhatsAppChatScreen(
            deviceId: deviceId,
            deviceName: deviceName,
          ),
        ),
      );
    } else {
      // Schedule navigation once navigator is ready
      WidgetsBinding.instance.addPostFrameCallback((_) {
        remoteControlNavigatorKey.currentState?.push(
          MaterialPageRoute(
            builder: (_) => WhatsAppChatScreen(
              deviceId: deviceId,
              deviceName: deviceName,
            ),
          ),
        );
      });
    }
  }

  /// Listens to authentication state and registers device message listeners
  void _startAuthAndDeviceListeners() {
    _authSub?.cancel();
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user != null) {
        _subscribeToUserDevices(user.uid);
      } else {
        _clearAllDeviceListeners();
      }
    });
  }

  void _subscribeToUserDevices(String uid) {
    _devicesSub?.cancel();
    // Listen to all devices where ownerUid is the current user (or general accessible devices)
    _devicesSub = FirebaseFirestore.instance
        .collection('remote_control_devices')
        .snapshots()
        .listen((snapshot) {
      final activeDeviceIds = <String>{};

      for (final doc in snapshot.docs) {
        final data = doc.data();
        final ownerUid = data['ownerUid'] as String?;
        // Match user's owned devices or fallback
        if (ownerUid != null && ownerUid.isNotEmpty && ownerUid != uid) {
          continue;
        }

        final deviceId = data['deviceId'] as String? ?? doc.id;
        final modelName = data['modelName'] as String? ?? 'מכשיר ($deviceId)';
        activeDeviceIds.add(deviceId);
        _deviceNames[deviceId] = modelName;

        if (!_deviceSubscriptions.containsKey(deviceId)) {
          _listenToDeviceMessages(deviceId);
        }
      }

      // Cleanup subscriptions for deleted devices
      final removed = _deviceSubscriptions.keys
          .where((id) => !activeDeviceIds.contains(id))
          .toList();
      for (final id in removed) {
        _deviceSubscriptions[id]?.cancel();
        _deviceSubscriptions.remove(id);
        _deviceNames.remove(id);
      }
    }, onError: (e) {
      debugPrint('[ChatNotificationService] Error listening to devices: $e');
    });
  }

  void _listenToDeviceMessages(String deviceId) {
    debugPrint('[ChatNotificationService] Starting message listener for device: $deviceId');

    final sub = FirebaseFirestore.instance
        .collection('remote_chats')
        .doc(deviceId)
        .collection('messages')
        .snapshots()
        .listen((snapshot) {
      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added) {
          _processIncomingDoc(deviceId, change.doc);
        }
      }
    }, onError: (e) {
      debugPrint('[ChatNotificationService] Message listener error for $deviceId: $e');
    });

    _deviceSubscriptions[deviceId] = sub;
  }

  Future<void> _processIncomingDoc(
    String deviceId,
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    final data = doc.data();
    if (data == null) return;

    final id = data['id'] as String? ?? doc.id;
    if (_processedMessageIds.contains(id)) return;
    _processedMessageIds.add(id);

    final timestamp = data['timestamp'] as int? ?? 0;
    // Don't notify for messages created before this app session started
    if (timestamp < _serviceStartTime) return;

    final sender = data['sender'] as String? ?? '';
    final type = data['type'] as String? ?? 'message';

    // Only notify for actual messages sent by the bot
    if (sender != 'bot') return;
    if (type == 'status' || type == 'reset') return;

    final text = (data['text'] as String? ?? '').trim();
    if (text.isEmpty) return;
    if (text.contains('תהליך הפרסום בוטל והסשן נסגר')) return;

    // Check if publication completed while outside chat screen
    if (RemoteLlmService.checkIfPublicationDone(text)) {
      final sessionId = data['sessionId'] as String?;
      if (sessionId != null && sessionId.isNotEmpty) {
        final session = await SqliteDatabaseHelper.instance.getSession(sessionId);
        if (session != null && session.status != ChatSessionStatus.done) {
          session.status = ChatSessionStatus.done;
          await ChatSessionManager.saveSession(session);
        }
      }
      await ChatSessionManager.advanceQueueAndStartNext(deviceId);
    }

    // Check if the user is currently inside the WhatsAppChatScreen for this device
    if (WhatsAppChatScreen.isInsideChatWith(deviceId)) {
      debugPrint(
        '[ChatNotificationService] User is currently inside WhatsAppChatScreen with $deviceId. Skipping notification.',
      );
      return;
    }

    // User is NOT inside the chat screen -> trigger local notification!
    final deviceName = _deviceNames[deviceId] ?? 'מכשיר ($deviceId)';
    await showMessageNotification(
      deviceId: deviceId,
      deviceName: deviceName,
      messageText: text,
    );
  }

  /// Shows a WhatsApp-like high-priority local notification
  Future<void> showMessageNotification({
    required String deviceId,
    required String deviceName,
    required String messageText,
  }) async {
    try {
      final notificationId =
          (deviceId.hashCode ^ DateTime.now().millisecondsSinceEpoch) & 0x7FFFFFFF;

      final title = '💬 $deviceName';

      final androidDetails = AndroidNotificationDetails(
        channelId,
        channelName,
        channelDescription: channelDesc,
        importance: Importance.max,
        priority: Priority.high,
        ticker: 'הודעה חדשה מפירסומוטו',
        styleInformation: BigTextStyleInformation(
          messageText,
          contentTitle: title,
          summaryText: 'פירסומוטו',
        ),
        icon: '@mipmap/launcher_icon',
        color: const Color(0xFF10B981), // Emerald accent
        playSound: true,
        enableVibration: true,
      );

      final notificationDetails =
          NotificationDetails(android: androidDetails);

      final payload = jsonEncode({
        'deviceId': deviceId,
        'deviceName': deviceName,
      });

      await _localNotifications.show(
        id: notificationId,
        title: title,
        body: messageText,
        notificationDetails: notificationDetails,
        payload: payload,
      );

      debugPrint(
        '[ChatNotificationService] Shown local notification for $deviceId: "$messageText"',
      );
    } catch (e) {
      debugPrint('[ChatNotificationService] Error showing notification: $e');
    }
  }

  void _clearAllDeviceListeners() {
    for (final sub in _deviceSubscriptions.values) {
      sub.cancel();
    }
    _deviceSubscriptions.clear();
    _deviceNames.clear();
    _devicesSub?.cancel();
    _devicesSub = null;
  }

  void dispose() {
    _authSub?.cancel();
    _clearAllDeviceListeners();
  }
}
