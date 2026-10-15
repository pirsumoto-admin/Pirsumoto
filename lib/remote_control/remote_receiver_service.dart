import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import '../firebase_options.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'firebase_chat_receiver.dart';
import 'remote_session_manager.dart';
import 'remote_signaling.dart';
import 'receiver_health.dart';

class RemoteControlReceiverService {
  static final RemoteControlReceiverService instance =
      RemoteControlReceiverService._internal();

  RemoteControlReceiverService._internal();

  static const String _prefDeviceIdKey = 'remote_control_device_id';
  static const String defaultDeviceId = 'mdm_device_01';

  RemoteSessionManager? _manager;
  RemoteSessionManager? get manager => _manager;

  FirebaseChatReceiver? _firebaseChatReceiver;
  FirebaseChatReceiver? get firebaseChatReceiver => _firebaseChatReceiver;

  String _deviceId = defaultDeviceId;
  String get deviceId => _deviceId;

  Timer? _healthTimer;
  ReceiverHealth? _health;
  Future<void>? _initialization;

  Future<void> _reportHealth(String state) async {
    if (!Platform.isAndroid) return;
    try {
      await const MethodChannel(
        'com.pirsumoto/accessibility',
      ).invokeMethod<void>('reportReceiverHealth', {'state': state});
    } catch (error) {
      debugPrint('[RemoteControlReceiver] Health report failed: $error');
    }
  }

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  /// Initialize and start the remote control receiver idle listener and Firebase chat listener
  Future<void> initialize({
    String? explicitDeviceId,
    VoidCallback? onPauseAutomation,
    VoidCallback? onResumeAutomation,
  }) {
    if (_isInitialized) return Future.value();
    return _initialization ??= _initialize(
      explicitDeviceId: explicitDeviceId,
      onPauseAutomation: onPauseAutomation,
      onResumeAutomation: onResumeAutomation,
    ).whenComplete(() => _initialization = null);
  }

  Future<void> _initialize({
    String? explicitDeviceId,
    VoidCallback? onPauseAutomation,
    VoidCallback? onResumeAutomation,
  }) async {
    await _reportHealth('starting');

    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
      }
      final prefs = await SharedPreferences.getInstance();

      String? androidId;
      if (Platform.isAndroid) {
        try {
          final info = await const MethodChannel(
            'com.pirsumoto/accessibility',
          ).invokeMapMethod<String, dynamic>('getDeviceInfo');
          if (info != null && info['androidId'] != null) {
            final id = info['androidId'] as String;
            if (id.isNotEmpty) androidId = 'android_$id';
          }
        } catch (e) {
          debugPrint('[RemoteControlReceiver] Failed to get androidId: $e');
        }
      }

      _deviceId =
          explicitDeviceId ??
          prefs.getString(_prefDeviceIdKey) ??
          androidId ??
          'android_${List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

      if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(_deviceId)) {
        throw ArgumentError('Invalid device ID');
      }
      await prefs.setString(_prefDeviceIdKey, _deviceId);

      // Start autonomous Firebase chat listener (works 24/7 without WebRTC)
      _firebaseChatReceiver?.dispose();
      _firebaseChatReceiver = FirebaseChatReceiver(deviceId: _deviceId);
      _firebaseChatReceiver!.startListening();

      _manager?.dispose();
      final signaling = RemoteSignalingService(deviceId: _deviceId);
      _manager = RemoteSessionManager(signaling: signaling);

      _manager!.onAutomationPauseRequested = () async {
        debugPrint(
          '[RemoteControlReceiver] Pausing automation for remote human control',
        );
        await FirebaseChatReceiver.pauseForTakeover();
        onPauseAutomation?.call();
      };

      _manager!.onAutomationResumeRequested = () {
        debugPrint(
          '[RemoteControlReceiver] Resuming automation after remote human control',
        );
        FirebaseChatReceiver.resumeAfterTakeover();
      };

      await _manager!.startListening();
      _isInitialized = true;
      _healthTimer?.cancel();
      _health?.dispose();
      _health = ReceiverHealth(
        isSignedIn: () => FirebaseAuth.instance.currentUser != null,
        checkServer: () async {
          await FirebaseFirestore.instance
              .collection('remote_control_sessions')
              .doc(_deviceId)
              .get(const GetOptions(source: Source.server));
        },
        report: _reportHealth,
      );
      _healthTimer = Timer.periodic(const Duration(seconds: 60), (_) {
        unawaited(_health!.check());
      });
      unawaited(_health!.check());
      debugPrint(
        '[RemoteControlReceiver] Initialized receiver and Firebase chat listener for device: $_deviceId',
      );

      // Android starts the foreground host independently in MainActivity. This
      // request is an idempotent fallback, and reports launch failures honestly.
      if (Platform.isAndroid) {
        try {
          final accepted = await const MethodChannel(
            'com.pirsumoto/accessibility',
          ).invokeMethod<bool>('startDaemonService');
          debugPrint(
            '[RemoteControlReceiver] Foreground daemon start accepted: $accepted',
          );
        } catch (e) {
          debugPrint(
            '[RemoteControlReceiver] Error starting daemon service: $e',
          );
        }
      }
    } catch (e) {
      await _reportHealth('error');
      _firebaseChatReceiver?.dispose();
      _firebaseChatReceiver = null;
      _manager?.dispose();
      _manager = null;
      _healthTimer?.cancel();
      _healthTimer = Timer(const Duration(seconds: 10), () {
        unawaited(
          initialize(
            explicitDeviceId: explicitDeviceId,
            onPauseAutomation: onPauseAutomation,
            onResumeAutomation: onResumeAutomation,
          ),
        );
      });
      debugPrint('[RemoteControlReceiver] Failed to initialize: $e');
    }
  }

  /// Update the MDM Device ID
  Future<void> updateDeviceId(String newDeviceId) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(newDeviceId)) {
      throw ArgumentError('Invalid device ID');
    }
    if (newDeviceId == _deviceId) return;
    if (FirebaseChatReceiver.isPublishingActive) {
      throw StateError(
        'Cancel the active publication before changing device ID',
      );
    }
    _healthTimer?.cancel();
    _health?.dispose();
    _deviceId = newDeviceId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefDeviceIdKey, _deviceId);

    // Restart listener with new device ID
    _firebaseChatReceiver?.dispose();
    _firebaseChatReceiver = null;
    await _manager?.terminateSession();
    _manager?.dispose();
    _manager = null;
    _isInitialized = false;
    await initialize(explicitDeviceId: newDeviceId);
  }

  void dispose() {
    _healthTimer?.cancel();
    _health?.dispose();
    unawaited(_reportHealth('error'));
    _firebaseChatReceiver?.dispose();
    _firebaseChatReceiver = null;
    _manager?.dispose();
    _manager = null;
    _isInitialized = false;
  }
}
