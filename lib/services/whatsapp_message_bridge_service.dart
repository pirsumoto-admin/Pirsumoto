import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class WhatsAppMessageBridgeService {
  const WhatsAppMessageBridgeService();

  static const instance = WhatsAppMessageBridgeService();

  static const MethodChannel _channel = MethodChannel(
    'com.pirsumoto/whatsapp_bridge',
  );
  static const EventChannel _eventsChannel = EventChannel(
    'com.pirsumoto/whatsapp_bridge/events',
  );

  Stream<WhatsAppBridgeEvent> get events {
    if (!Platform.isAndroid) return const Stream.empty();
    return _eventsChannel.receiveBroadcastStream().map((event) {
      return WhatsAppBridgeEvent.fromMap(Map<dynamic, dynamic>.from(event));
    });
  }

  Future<bool> configure({
    String? backendUrl,
    String? deviceToken,
    bool autoReplyEnabled = true,
    bool watchBusinessWhatsApp = true,
  }) async {
    _assertAndroid();
    final ok = await _channel.invokeMethod<bool>('configure', {
      'backendUrl': backendUrl ?? '',
      'deviceToken': deviceToken ?? '',
      'autoReplyEnabled': autoReplyEnabled,
      'watchBusinessWhatsApp': watchBusinessWhatsApp,
    });
    return ok ?? false;
  }

  Future<bool> start() async {
    _assertAndroid();
    return await _channel.invokeMethod<bool>('start') ?? false;
  }

  Future<bool> stop() async {
    _assertAndroid();
    return await _channel.invokeMethod<bool>('stop') ?? false;
  }

  Future<WhatsAppBridgeStatus> getStatus() async {
    _assertAndroid();
    final raw = await _channel.invokeMapMethod<String, dynamic>('getStatus');
    return WhatsAppBridgeStatus.fromMap(raw ?? const {});
  }

  Future<Map<String, String>> consumePendingAutoPublish() async {
    _assertAndroid();
    final raw = await _channel.invokeMapMethod<String, dynamic>(
      'consumePendingAutoPublish',
    );
    if (raw == null || raw.isEmpty) return const {};
    return raw.map((key, value) => MapEntry(key, value?.toString() ?? ''));
  }

  Future<bool> sendReplyToWhatsApp({
    required String senderKey,
    required String message,
  }) async {
    _assertAndroid();
    return await _channel.invokeMethod<bool>('sendReplyToWhatsApp', {
          'senderKey': senderKey,
          'message': message,
        }) ??
        false;
  }

  Future<bool> openNotificationListenerSettings() async {
    _assertAndroid();
    return await _channel.invokeMethod<bool>(
          'openNotificationListenerSettings',
        ) ??
        false;
  }

  Future<bool> requestRebindNotificationListener() async {
    _assertAndroid();
    return await _channel.invokeMethod<bool>(
          'requestRebindNotificationListener',
        ) ??
        false;
  }

  Future<bool> openAllFilesAccessSettings() async {
    _assertAndroid();
    return await _channel.invokeMethod<bool>('openAllFilesAccessSettings') ??
        false;
  }

  Future<bool> openBatteryOptimizationSettings() async {
    _assertAndroid();
    return await _channel.invokeMethod<bool>(
          'openBatteryOptimizationSettings',
        ) ??
        false;
  }

  Future<bool> openAppNotificationSettings() async {
    _assertAndroid();
    return await _channel.invokeMethod<bool>('openAppNotificationSettings') ??
        false;
  }

  Future<bool> openOverlayPermissionSettings() async {
    _assertAndroid();
    return await _channel.invokeMethod<bool>('openOverlayPermissionSettings') ??
        false;
  }

  Future<bool> openFullScreenIntentSettings() async {
    _assertAndroid();
    return await _channel.invokeMethod<bool>('openFullScreenIntentSettings') ??
        false;
  }

  void _assertAndroid() {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'WhatsApp message bridge is only available on Android.',
      );
    }
  }
}

class WhatsAppBridgeStatus {
  const WhatsAppBridgeStatus({
    required this.configured,
    required this.running,
    required this.backendUrl,
    required this.autoReplyEnabled,
    required this.notificationListenerEnabled,
    required this.notificationListenerConnected,
    required this.allFilesAccessGranted,
    required this.batteryOptimizationIgnored,
    required this.overlayPermissionGranted,
    required this.fullScreenIntentAllowed,
    required this.watchBusinessWhatsApp,
  });

  final bool configured;
  final bool running;
  final String backendUrl;
  final bool autoReplyEnabled;
  final bool notificationListenerEnabled;
  final bool notificationListenerConnected;
  final bool allFilesAccessGranted;
  final bool batteryOptimizationIgnored;
  final bool overlayPermissionGranted;
  final bool fullScreenIntentAllowed;
  final bool watchBusinessWhatsApp;

  factory WhatsAppBridgeStatus.fromMap(Map<dynamic, dynamic> map) {
    return WhatsAppBridgeStatus(
      configured: map['configured'] == true,
      running: map['running'] == true,
      backendUrl: map['backendUrl']?.toString() ?? '',
      autoReplyEnabled: map['autoReplyEnabled'] != false,
      notificationListenerEnabled: map['notificationListenerEnabled'] == true,
      notificationListenerConnected: map['notificationListenerConnected'] == true,
      allFilesAccessGranted: map['allFilesAccessGranted'] == true,
      batteryOptimizationIgnored: map['batteryOptimizationIgnored'] == true,
      overlayPermissionGranted: map['overlayPermissionGranted'] == true,
      fullScreenIntentAllowed: map['fullScreenIntentAllowed'] != false,
      watchBusinessWhatsApp: map['watchBusinessWhatsApp'] != false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'configured': configured,
      'running': running,
      'backendUrl': backendUrl,
      'autoReplyEnabled': autoReplyEnabled,
      'notificationListenerEnabled': notificationListenerEnabled,
      'notificationListenerConnected': notificationListenerConnected,
      'allFilesAccessGranted': allFilesAccessGranted,
      'batteryOptimizationIgnored': batteryOptimizationIgnored,
      'overlayPermissionGranted': overlayPermissionGranted,
      'fullScreenIntentAllowed': fullScreenIntentAllowed,
      'watchBusinessWhatsApp': watchBusinessWhatsApp,
    };
  }
}

class WhatsAppBridgeEvent {
  const WhatsAppBridgeEvent({
    required this.name,
    required this.timestamp,
    required this.data,
  });

  final String name;
  final DateTime timestamp;
  final Map<String, dynamic> data;

  factory WhatsAppBridgeEvent.fromMap(Map<dynamic, dynamic> map) {
    final rawData = map['data'];
    return WhatsAppBridgeEvent(
      name: map['event']?.toString() ?? '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        int.tryParse(map['timestamp']?.toString() ?? '') ??
            DateTime.now().millisecondsSinceEpoch,
      ),
      data:
          rawData is Map
              ? rawData.map((key, value) => MapEntry(key.toString(), value))
              : const {},
    );
  }
}
