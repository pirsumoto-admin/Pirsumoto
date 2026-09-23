import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:pirsumoto_remote_control/services/chat_notification_service.dart';
import 'package:pirsumoto_remote_control/services/notification_visibility.dart';
import 'package:pirsumoto_remote_control/ui/whatsapp_chat_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'system-rendered background pushes do not initialize Firebase or duplicate alerts',
    () async {
      // No Firebase app/plugins are configured in this test. A notification
      // payload must return before authentication, Firestore or local rendering.
      await publicationPushBackground(
        const RemoteMessage(
          notification: RemoteNotification(title: 'Publication update'),
          data: {
            'ownerUid': 'owner',
            'deviceId': 'device',
            'sessionId': 'request',
          },
        ),
      );
    },
  );

  group('Visible chat notification suppression', () {
    bool visible(
      AppLifecycleState? state, {
      String? activeSession = 'request',
    }) => isNotificationChatVisible(
      lifecycleState: state,
      deviceId: 'device',
      sessionId: 'request',
      activeDeviceId: 'device',
      activeSessionId: activeSession,
    );

    test('only the exact chat in the resumed app suppresses alerts', () {
      expect(visible(AppLifecycleState.resumed), isTrue);
      expect(
        visible(AppLifecycleState.resumed, activeSession: 'other'),
        isFalse,
      );
      expect(visible(AppLifecycleState.resumed, activeSession: null), isFalse);
    });

    test(
      'a chat left open while backgrounded or locked does not suppress alerts',
      () {
        for (final state in [null, ...AppLifecycleState.values]) {
          if (state == AppLifecycleState.resumed) continue;
          expect(visible(state), isFalse, reason: '$state');
        }
      },
    );
  });

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
