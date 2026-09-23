import 'package:flutter/widgets.dart';

/// An open chat route can remain mounted while the phone is locked or the app
/// is backgrounded. Only a visible chat should suppress an incoming alert.
bool isNotificationChatVisible({
  required AppLifecycleState? lifecycleState,
  required String deviceId,
  required String? sessionId,
  required String? activeDeviceId,
  required String? activeSessionId,
}) =>
    lifecycleState == AppLifecycleState.resumed &&
    deviceId == activeDeviceId &&
    sessionId != null &&
    sessionId == activeSessionId;
