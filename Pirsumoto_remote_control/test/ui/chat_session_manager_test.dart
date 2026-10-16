import 'package:flutter_test/flutter_test.dart';
import 'package:pirsumoto_remote_control/ui/chat_session_manager.dart';

void main() {
  const device = 'android_22bac8946a0115de';
  ChatSession stale(String id) => ChatSession(
    id: id,
    deviceId: device,
    startTimestamp: 123,
    status: ChatSessionStatus.canceled,
    imagePaths: ['local.jpg'],
    expectedImageCount: 1,
  );

  test(
    'three completed requests and one paused replace stale canceled state',
    () {
      final states = ['completed', 'completed', 'completed', 'paused'];
      final sessions = [
        for (var i = 0; i < states.length; i++) stale('chat$i'),
      ];
      expect(
        [
          for (var i = 0; i < states.length; i++)
            ChatSessionManager.effectiveStatus(sessions[i], {
              'state': states[i],
            }),
        ],
        [
          ChatSessionStatus.done,
          ChatSessionStatus.done,
          ChatSessionStatus.done,
          ChatSessionStatus.paused,
        ],
      );
      expect(
        ChatSessionManager.effectiveStatus(stale('draft'), null),
        ChatSessionStatus.canceled,
      );
    },
  );

  test('state is authoritative even when lastMessage says canceled', () {
    for (final state in ['completed', 'paused', 'canceled', 'failed']) {
      final session = ChatSessionManager.sessionFromRequest(device, state, {
        'state': state,
        'lastMessage': 'הפרסום בוטל',
        'vehicleData': {'license_plate': '1234567'},
      }, previous: stale(state));
      expect(session.status, ChatSessionManager.statusFromRequest(state));
      if (state != 'canceled') {
        expect(session.lastMessage, isNot(contains('בוטל')));
      } else {
        expect(session.lastMessage, 'הפרסום בוטל');
      }
    }
  });

  test('mixed Firestore vehicle values do not abort history projection', () {
    final session = ChatSessionManager.sessionFromRequest(device, 'history', {
      'state': 'completed',
      'vehicleData': {
        'license_plate': 1234567,
        'year': 2020,
        'includeYad2': false,
        'color': null,
      },
    }, previous: stale('history'));
    expect(session.status, ChatSessionStatus.done);
    expect(session.licensePlate, '1234567');
    expect(session.vehicleData['includeYad2'], 'false');
    expect(session.vehicleData['color'], '');
    expect(session.startTimestamp, 123);
    expect(session.imagePaths, ['local.jpg']);
    expect(session.expectedImageCount, 1);
  });

  test('missing legacy vehicle data does not hide a paused request', () {
    final previous = stale('paused')..vehicleData = {'maker': 'Toyota'};
    final session = ChatSessionManager.sessionFromRequest(device, 'paused', {
      'state': 'paused',
    }, previous: previous);
    expect(session.status, ChatSessionStatus.paused);
    expect(session.vehicleData['maker'], 'Toyota');
  });
  test(
    'completed edits persist in SQLite JSON and survive same-attempt projection',
    () {
      final edited = stale('edited')
        ..status = ChatSessionStatus.done
        ..draftBaseAttemptId = 'published-attempt'
        ..vehicleData = {
          'license_plate': '1234567',
          'price': '65000',
          'km': '110000',
        };
      final stored = ChatSession.fromJson(edited.toJson());
      final projected = ChatSessionManager.sessionFromRequest(
        device,
        'edited',
        {
          'state': 'completed',
          'attemptId': 'published-attempt',
          'vehicleData': {
            'license_plate': '1234567',
            'price': '70000',
            'km': '100000',
          },
        },
        previous: stored,
      );
      expect(projected.vehicleData['price'], '65000');
      expect(projected.vehicleData['km'], '110000');
      expect(projected.status, ChatSessionStatus.done);
      expect(projected.draftBaseAttemptId, 'published-attempt');
      final queued = ChatSessionManager.sessionFromRequest(device, 'edited', {
        'state': 'queued',
        'attemptId': 'republished-attempt',
        'vehicleData': {
          'license_plate': '1234567',
          'price': '65000',
          'km': '110000',
        },
      }, previous: projected);
      expect(queued.status, ChatSessionStatus.waiting);
      expect(queued.vehicleData['price'], '65000');
      expect(queued.draftBaseAttemptId, isNull);
      final replaced = ChatSessionManager.sessionFromRequest(device, 'edited', {
        'state': 'completed',
        'attemptId': 'other-attempt',
        'vehicleData': {'price': '60000'},
      }, previous: stored);
      expect(replaced.vehicleData['price'], '60000');
      expect(replaced.draftBaseAttemptId, isNull);
    },
  );

  test(
    'editing is allowed after completion and blocked for an active attempt',
    () {
      for (final state in [null, 'completed', 'failed', 'canceled']) {
        expect(ChatSessionManager.canEditPublication(state), isTrue);
      }
      for (final state in [
        'queued',
        'preparing',
        'publishing',
        'paused',
        'stuck',
        'canceling',
      ]) {
        expect(ChatSessionManager.canEditPublication(state), isFalse);
      }
      final ready = stale('ready')
        ..vehicleData = {
          'license_plate': '1234567',
          'maker': 'Toyota',
          'model': 'Corolla',
          'year': '2020',
          'km': '100000',
          'price': '70000',
          'hand': '2',
          'color': 'לבן',
          'fuel_type': 'בנזין',
          'gear_type': 'אוטומטי',
          'current_ownership': 'פרטית',
          'previous_ownership': 'פרטית',
          'month': '5',
          'vehicle_condition': 'טוב',
          'city': 'חיפה',
          'handicapped': 'לא',
          'no_test': 'לא',
        };
      expect(
        ChatSessionManager.canStartPublication(ready, ChatSessionStatus.done),
        isTrue,
      );
      expect(
        ChatSessionManager.canStartPublication(
          ready,
          ChatSessionStatus.running,
        ),
        isFalse,
      );
      ready.vehicleData['price'] = '';
      expect(
        ChatSessionManager.canStartPublication(ready, ChatSessionStatus.done),
        isFalse,
      );
      ready.vehicleData['price'] = '70000';
      ready.imagePaths = [];
      expect(
        ChatSessionManager.canStartPublication(ready, ChatSessionStatus.done),
        isTrue,
      );
    },
  );
}
