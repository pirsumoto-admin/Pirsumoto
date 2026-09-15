import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'firebase_chat_receiver.dart';
import 'remote_session_manager.dart';
import 'remote_signaling.dart';

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

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  /// Initialize and start the remote control receiver idle listener and Firebase chat listener
  Future<void> initialize({
    String? explicitDeviceId,
    VoidCallback? onPauseAutomation,
    VoidCallback? onResumeAutomation,
  }) async {
    if (_isInitialized) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      _deviceId = explicitDeviceId ??
          prefs.getString(_prefDeviceIdKey) ??
          defaultDeviceId;

      await prefs.setString(_prefDeviceIdKey, _deviceId);

      // Start autonomous Firebase chat listener (works 24/7 without WebRTC)
      _firebaseChatReceiver?.dispose();
      _firebaseChatReceiver = FirebaseChatReceiver(deviceId: _deviceId);
      _firebaseChatReceiver!.startListening();

      final signaling = RemoteSignalingService(deviceId: _deviceId);
      _manager = RemoteSessionManager(signaling: signaling);

      _manager!.onAutomationPauseRequested = () {
        debugPrint('[RemoteControlReceiver] Pausing automation for remote human control');
        onPauseAutomation?.call();
      };

      _manager!.onAutomationResumeRequested = () {
        debugPrint('[RemoteControlReceiver] Resuming automation after remote human control');
        onResumeAutomation?.call();
      };

      await _manager!.startListening();
      _isInitialized = true;
      debugPrint('[RemoteControlReceiver] Initialized receiver and Firebase chat listener for device: $_deviceId');
    } catch (e) {
      debugPrint('[RemoteControlReceiver] Failed to initialize: $e');
    }
  }

  /// Update the MDM Device ID
  Future<void> updateDeviceId(String newDeviceId) async {
    if (newDeviceId.isEmpty || newDeviceId == _deviceId) return;
    _deviceId = newDeviceId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefDeviceIdKey, _deviceId);

    // Restart listener with new device ID
    _firebaseChatReceiver?.dispose();
    _firebaseChatReceiver = null;
    await _manager?.terminateSession();
    _manager?.dispose();
    _isInitialized = false;
    await initialize();
  }

  void dispose() {
    _firebaseChatReceiver?.dispose();
    _firebaseChatReceiver = null;
    _manager?.dispose();
    _manager = null;
    _isInitialized = false;
  }
}
