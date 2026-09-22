import 'remote_protocol.dart';
import 'remote_webrtc_receiver.dart';

/// WebRTC carries screen control only. Legacy chat packets cannot bypass the
/// durable publication queue or create a second validation/automation session.
class RemoteChatReceiver {
  final RemoteWebRtcReceiver webrtc;
  final String deviceId, controllerId;
  RemoteChatReceiver({
    required this.webrtc,
    required this.deviceId,
    required this.controllerId,
  });
  void dispose() {}
  Future<bool> handleIncomingCommand(RemoteCommand command) async {
    if (command is! RemoteChatTextMessage && command is! RemoteChatMediaChunk)
      return false;
    webrtc.sendChatReply(
      RemoteChatStatusMessage(
        status: 'unsupported',
        text: 'יש להשתמש בצ׳אט המעודכן להגשת בקשת פרסום.',
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    return true;
  }
}
