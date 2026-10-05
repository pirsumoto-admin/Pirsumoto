import 'package:publication_protocol/publication_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
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

  test(
    'manual entry alerts expand text and enable heads-up priority and sound',
    () {
      const body = 'נדרשת הזנה ידנית של פרטי הרכב ביד2 (שליטה מרחוק).';
      final details = ChatNotificationService.detailsForMessage(body);
      expect(
        details.android!.channelId,
        ChatNotificationService.manualInputChannelId,
      );
      expect(details.android!.importance, Importance.max);
      expect(details.android!.priority, Priority.max);
      expect(details.android!.playSound, isTrue);
      expect(details.android!.enableVibration, isTrue);
      expect(
        (details.android!.styleInformation as BigTextStyleInformation).bigText,
        body,
      );
      expect(details.iOS!.presentBanner, isTrue);
      expect(details.iOS!.presentSound, isTrue);
      expect(details.iOS!.sound, 'default');
      expect(details.iOS!.interruptionLevel, InterruptionLevel.active);
    },
  );

  test('routine updates keep the silent channel', () {
    final details = ChatNotificationService.detailsForMessage(
      'האוטומציה הושהתה',
    );
    expect(details.android!.channelId, ChatNotificationService.channelId);
    expect(details.android!.importance, Importance.low);
    expect(details.android!.playSound, isFalse);
    expect(details.iOS!.presentBanner, isFalse);
    expect(details.iOS!.presentSound, isFalse);
  });

  test('outcomes use audible heads-up and iOS banners', () {
    for (final state in ['stuck', 'failed', 'completed']) {
      final details = ChatNotificationService.detailsForMessage(
        'Update',
        state: state,
      );
      expect(
        details.android!.channelId,
        ChatNotificationService.outcomeChannelId,
      );
      expect(details.android!.importance, Importance.max);
      expect(details.android!.priority, Priority.max);
      expect(details.android!.playSound, isTrue);
      expect(details.iOS!.presentBanner, isTrue);
      expect(details.iOS!.presentSound, isTrue);
      expect(details.iOS!.sound, 'default');
      expect(PublicationNotification.needsAttention(state, 'Update'), isTrue);
    }
  });

  test(
    'stale cancellation text never describes an active or successful request',
    () {
      for (final state in [
        'queued',
        'preparing',
        'publishing',
        'paused',
        'stuck',
        'failed',
        'completed',
        'canceling',
      ]) {
        final text = PublicationNotification.textFor(state, 'הפרסום בוטל');
        expect(text, isNot(contains('בוטל')), reason: state);
      }
      expect(
        PublicationNotification.textFor('canceled', 'הפרסום בוטל'),
        'הפרסום בוטל',
      );
      expect(
        PublicationNotification.textFor(
          'completed',
          'הפרסום ביד2 הושלם בהצלחה',
        ),
        'הפרסום ביד2 הושלם בהצלחה',
      );
      expect(
        PublicationNotification.needsAttention('publishing', 'Progress'),
        isFalse,
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
