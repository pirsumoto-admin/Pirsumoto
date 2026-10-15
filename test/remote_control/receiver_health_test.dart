import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirsumoto/remote_control/receiver_health.dart';

void main() {
  test('signed-out receiver does not attempt server access', () async {
    final states = <String>[];
    var reads = 0;
    final health = ReceiverHealth(
      isSignedIn: () => false,
      checkServer: () async {
        reads++;
      },
      report: (state) async {
        states.add(state);
      },
    );
    await health.check();
    expect(reads, 0);
    expect(states, ['signed_out']);
  });

  test('server failure is reported and a later check can recover', () async {
    final states = <String>[];
    var offline = true;
    final health = ReceiverHealth(
      isSignedIn: () => true,
      checkServer: () async {
        if (offline) throw StateError('offline');
      },
      report: (state) async {
        states.add(state);
      },
    );
    await health.check();
    offline = false;
    await health.check();
    expect(states, ['error', 'ready']);
  });

  testWidgets('hung server read times out and does not block future checks', (
    tester,
  ) async {
    final states = <String>[];
    var reads = 0;
    final pending = Completer<void>();
    final health = ReceiverHealth(
      isSignedIn: () => true,
      checkServer: () {
        reads++;
        return reads == 1 ? pending.future : Future.value();
      },
      report: (state) async {
        states.add(state);
      },
    );
    final first = health.check();
    await health.check();
    expect(reads, 1);
    await tester.pump(const Duration(seconds: 15));
    await first;
    expect(states, ['error']);
    await health.check();
    expect(states, ['error', 'ready']);
    pending.complete();
  });

  test('disposal suppresses a stale success report', () async {
    final states = <String>[];
    final pending = Completer<void>();
    final health = ReceiverHealth(
      isSignedIn: () => true,
      checkServer: () => pending.future,
      report: (state) async {
        states.add(state);
      },
    );
    final check = health.check();
    health.dispose();
    pending.complete();
    await check;
    await health.check();
    expect(states, isEmpty);
  });

  test('sign-out during a server read never reports ready', () async {
    final states = <String>[];
    final pending = Completer<void>();
    var signedIn = true;
    final health = ReceiverHealth(
      isSignedIn: () => signedIn,
      checkServer: () => pending.future,
      report: (state) async {
        states.add(state);
      },
    );
    final check = health.check();
    signedIn = false;
    pending.complete();
    await check;
    expect(states, ['signed_out']);
  });
}
