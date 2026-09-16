import 'package:flutter_test/flutter_test.dart';
import 'package:pirsumoto_remote_control/ui/whatsapp_chat_screen.dart';

void main() {
  group('Chat Notification & Active Chat State Tests', () {
    test('WhatsAppChatScreen active state tracking', () {
      expect(WhatsAppChatScreen.currentActiveDeviceId, isNull);
      expect(WhatsAppChatScreen.isInsideChatWith('device_123'), isFalse);
      expect(WhatsAppChatScreen.isInsideAnyChat(), isFalse);

      // Simulate entering chat for device_123
      WhatsAppChatScreen.currentActiveDeviceId = 'device_123';
      expect(WhatsAppChatScreen.isInsideChatWith('device_123'), isTrue);
      expect(WhatsAppChatScreen.isInsideChatWith('device_456'), isFalse);
      expect(WhatsAppChatScreen.isInsideAnyChat(), isTrue);

      // Simulate exiting chat
      WhatsAppChatScreen.currentActiveDeviceId = null;
      expect(WhatsAppChatScreen.isInsideChatWith('device_123'), isFalse);
      expect(WhatsAppChatScreen.isInsideAnyChat(), isFalse);
    });
  });
}
