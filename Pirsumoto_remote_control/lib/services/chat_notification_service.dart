import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../firebase_options.dart';
import '../database/sqlite_database_helper.dart';
import '../ui/chat_session_manager.dart';
import '../ui/whatsapp_chat_screen.dart';
import 'remote_api.dart';

final GlobalKey<NavigatorState> remoteControlNavigatorKey =
    GlobalKey<NavigatorState>();

@pragma('vm:entry-point')
Future<void> publicationPushBackground(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  final user = await FirebaseAuth.instance.authStateChanges().first;
  if (user?.uid != message.data['ownerUid']) return;
  await ChatNotificationService.instance.initializeNotifications();
  await ChatNotificationService.instance.showPush(message.data);
}

class ChatNotificationService {
  ChatNotificationService._internal();
  static final instance = ChatNotificationService._internal();
  static const channelId = 'pirsumoto_chat_notifications';
  static const channelName = 'עדכוני פרסום';
  static const channelDesc = 'מצב בקשות הפרסום';
  final _localNotifications = FlutterLocalNotificationsPlugin();
  StreamSubscription? _authSub, _devicesSub, _tokenSub;
  final Map<String, StreamSubscription> _subscriptions = {};
  final Map<String, String> _states = {};
  final Map<String, String> _deviceNames = {};
  String? _registeredToken;
  Map<String, dynamic>? _pendingNavigation;
  bool _initialized = false;
  bool _notificationsInitialized = false;
  Future<void> initializeNotifications() async {
    if (_notificationsInitialized) return;
    await _localNotifications.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/launcher_icon'),
      ),
      onDidReceiveNotificationResponse: (r) {
        if (r.payload != null)
          _navigate(Map<String, dynamic>.from(jsonDecode(r.payload!) as Map));
      },
    );
    final android = _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        channelId,
        channelName,
        description: channelDesc,
        importance: Importance.high,
      ),
    );
    _notificationsInitialized = true;
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    await initializeNotifications();
    FirebaseMessaging.onBackgroundMessage(publicationPushBackground);
    await FirebaseMessaging.instance.requestPermission();
    final launch = await _localNotifications.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true &&
        launch?.notificationResponse?.payload != null) {
      _pendingNavigation = Map<String, dynamic>.from(
        jsonDecode(launch!.notificationResponse!.payload!) as Map,
      );
    }
    _tokenSub = FirebaseMessaging.instance.onTokenRefresh.listen((_) {
      _registeredToken = null;
      if (_deviceNames.isNotEmpty)
        unawaited(_registerToken(_deviceNames.keys.first));
    });
    String? previousOwner = FirebaseAuth.instance.currentUser?.uid;
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) async {
      if (previousOwner != user?.uid)
        remoteControlNavigatorKey.currentState?.popUntil(
          (route) => route.isFirst,
        );
      previousOwner = user?.uid;
      _devicesSub?.cancel();
      for (final sub in _subscriptions.values) {
        unawaited(sub.cancel());
      }
      _subscriptions.clear();
      _states.clear();
      _deviceNames.clear();
      _registeredToken = null;
      await ChatSessionManager.reset();
      if (user == null) {
        await _localNotifications.cancelAll();
        return;
      }
      _devicesSub = FirebaseFirestore.instance
          .collection('remote_control_devices')
          .where('ownerUid', isEqualTo: user.uid)
          .snapshots()
          .listen((snapshot) {
            if (FirebaseAuth.instance.currentUser?.uid != user.uid) return;
            for (final doc in snapshot.docs) {
              final deviceId = doc.id;
              _deviceNames[deviceId] =
                  doc.data()['modelName']?.toString() ?? deviceId;
              ChatSessionManager.watchDevice(deviceId);
              if (_subscriptions.containsKey(deviceId)) continue;
              var first = true;
              _subscriptions[deviceId] = FirebaseFirestore.instance
                  .collection('remote_chats')
                  .doc(deviceId)
                  .collection('requests')
                  .where('ownerUid', isEqualTo: user.uid)
                  .snapshots()
                  .listen((requests) {
                    if (FirebaseAuth.instance.currentUser?.uid != user.uid)
                      return;
                    for (final change in requests.docChanges) {
                      if (change.type == DocumentChangeType.removed) continue;
                      final request = change.doc;
                      final data = request.data()!,
                          key = '$deviceId/${request.id}';
                      final old = _states[key];
                      _states[key] = data['state'] as String;
                      if (first ||
                          old == data['state'] ||
                          data['state'] == 'queued')
                        continue;
                      if (WhatsAppChatScreen.currentActiveDeviceId ==
                              deviceId &&
                          WhatsAppChatScreen.currentActiveSessionId ==
                              request.id)
                        continue;
                      unawaited(
                        showMessageNotification(
                          deviceId: deviceId,
                          deviceName: _deviceNames[deviceId]!,
                          sessionId: request.id,
                          ownerUid: user.uid,
                          attemptId: data['attemptId'] as String,
                          revision: data['revision'] as int,
                          messageText:
                              data['lastMessage']?.toString() ?? data['state'],
                        ),
                      );
                    }
                    first = false;
                  });
            }
            final ids = snapshot.docs.map((d) => d.id).toSet();
            for (final id in _subscriptions.keys.toList()) {
              if (!ids.contains(id)) {
                _subscriptions.remove(id)?.cancel();
                _deviceNames.remove(id);
              }
            }
            if (snapshot.docs.isNotEmpty)
              unawaited(_registerToken(snapshot.docs.first.id));
          });
      navigatePending();
    });
  }

  Future<void> _registerToken(String deviceId) async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null || token == _registeredToken) return;
      await RemoteApi.post(deviceId, {
        'action': 'register_notifications',
        'token': token,
      });
      _registeredToken = token;
    } catch (e) {
      debugPrint('[Notifications] Registration failed: $e');
    }
  }

  void navigatePending() {
    final pending = _pendingNavigation;
    if (pending != null) _navigate(pending);
  }

  void _navigate(Map<String, dynamic> data) {
    if (data['ownerUid'] != FirebaseAuth.instance.currentUser?.uid) {
      _pendingNavigation = null;
      return;
    }
    final navigator = remoteControlNavigatorKey.currentState;
    if (navigator == null) {
      _pendingNavigation = data;
      return;
    }
    _pendingNavigation = null;
    final deviceId = data['deviceId'] as String?,
        sessionId = data['sessionId'] as String?;
    if (deviceId == null || sessionId == null) return;
    if (WhatsAppChatScreen.currentActiveDeviceId == deviceId &&
        WhatsAppChatScreen.currentActiveSessionId == sessionId)
      return;
    navigator.push(
      MaterialPageRoute(
        builder: (_) => WhatsAppChatScreen(
          deviceId: deviceId,
          deviceName: data['deviceName']?.toString() ?? deviceId,
          sessionId: sessionId,
        ),
      ),
    );
  }

  Future<void> showPush(Map<String, dynamic> data) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null ||
          data['ownerUid'] != uid ||
          data['deviceId'] is! String ||
          data['sessionId'] is! String)
        return;
      // FCM can reorder or redeliver messages. Reconcile against the worker's
      // authoritative request and never display stale payload text.
      final request = await FirebaseFirestore.instance
          .collection('remote_chats')
          .doc(data['deviceId'])
          .collection('requests')
          .doc(data['sessionId'])
          .get(const GetOptions(source: Source.server));
      final current = request.data();
      if (current == null ||
          current['ownerUid'] != uid ||
          current['attemptId'] != data['attemptId'] ||
          current['archived'] == true)
        return;
      await showMessageNotification(
        deviceId: data['deviceId'],
        deviceName: data['deviceId'],
        sessionId: data['sessionId'],
        ownerUid: uid,
        attemptId: current['attemptId'],
        revision: current['revision'],
        messageText: current['lastMessage'] ?? current['state'],
      );
    } catch (e) {
      debugPrint('[Notifications] Unable to reconcile push: $e');
    }
  }

  Future<void> showMessageNotification({
    required String deviceId,
    required String deviceName,
    required String messageText,
    String? sessionId,
    String? ownerUid,
    required String attemptId,
    required int revision,
  }) async {
    if (sessionId == null || ownerUid != FirebaseAuth.instance.currentUser?.uid)
      return;
    if (!await SqliteDatabaseHelper.instance.claimNotification(
      '$deviceId/$sessionId/$attemptId',
      revision,
    ))
      return;
    if (ownerUid != FirebaseAuth.instance.currentUser?.uid) return;
    if (WhatsAppChatScreen.currentActiveDeviceId == deviceId &&
        WhatsAppChatScreen.currentActiveSessionId == sessionId)
      return;
    await _localNotifications.show(
      id: '$deviceId/$sessionId'.hashCode & 0x7fffffff,
      title: deviceName,
      body: messageText,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: channelDesc,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/launcher_icon',
        ),
      ),
      payload: jsonEncode({
        'deviceId': deviceId,
        'deviceName': deviceName,
        'sessionId': sessionId,
        'ownerUid': ownerUid,
      }),
    );
  }

  void dispose() {
    _authSub?.cancel();
    _devicesSub?.cancel();
    _tokenSub?.cancel();
    for (final sub in _subscriptions.values) {
      sub.cancel();
    }
    _subscriptions.clear();
    _initialized = false;
  }
}
