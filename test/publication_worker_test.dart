import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirsumoto/remote_control/firebase_chat_receiver.dart';
import 'package:publication_protocol/publication_protocol.dart';

class _InterruptibleFirestore extends FakeFirebaseFirestore {
  bool failTransactions = false;

  @override
  Future<T> runTransaction<T>(
    TransactionHandler<T> transactionHandler, {
    Duration timeout = const Duration(seconds: 30),
    int maxAttempts = 5,
  }) {
    if (failTransactions) return Future.error(StateError('Connection lost'));
    return super.runTransaction(
      transactionHandler,
      timeout: timeout,
      maxAttempts: maxAttempts,
    );
  }
}

const vehicle = <String, String>{
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _InterruptibleFirestore db;
  late StreamController<String?> owners;
  late FirebaseChatReceiver worker;
  late Directory temp;
  late List<PublicationIdentity> launches;
  late Future<void> Function() stop, pause;
  late int resumes;
  late List<String> activity;
  late List<String> shutdownStates;
  late Future<DownloadedAttachment> Function(String) download;
  late Future<Map<String, dynamic>?> Function(String) claim;
  final bytes = Uint8List.fromList([1, 2, 3, 4]);
  DocumentReference<Map<String, dynamic>> request(String id) =>
      db.doc('remote_chats/device/requests/$id');
  Future<void> enqueue(String id, int time, {String? checksum}) =>
      request(id).set({
        'ownerUid': 'owner',
        'deviceId': 'device',
        'requestId': id,
        'sessionId': id,
        'attemptId': 'attempt_$id',
        'state': 'queued',
        'revision': 1,
        'vehicleData': vehicle,
        'platforms': ['yad2', 'facebook'],
        'completedPlatforms': [],
        'enqueuedAt': Timestamp.fromMillisecondsSinceEpoch(time),
        'attachments': [
          {
            'path': 'publication_media/owner/device/$id/attempt_$id/0',
            'size': bytes.length,
            'sha256': checksum ?? sha256.convert(bytes).toString(),
            'generation': '1',
          },
        ],
      });
  // Fake the backend boundary; production queue selection is tested in Node.
  Future<Map<String, dynamic>?> claimNext(String runId) async {
    final device = db.doc('remote_chats/device');
    if ((await device.get()).data()?['activeRequestId'] != null) return null;
    final queued =
        await db
            .collection('remote_chats/device/requests')
            .where('ownerUid', isEqualTo: 'owner')
            .where('state', isEqualTo: 'queued')
            .orderBy('enqueuedAt')
            .get();
    if (queued.docs.isEmpty) return null;
    final priorityRef = db.doc('remote_publication_queues/device');
    final priority = (await priorityRef.get()).data()?['nextRequestId'];
    var selected = queued.docs.first;
    for (final doc in queued.docs) {
      if (doc.id == priority) selected = doc;
    }
    await device.set({
      'activeRequestId': selected.id,
      'workerRunId': runId,
      'leaseUntil': Timestamp.fromDate(
        DateTime.now().add(const Duration(seconds: 60)),
      ),
    });
    await selected.reference.update({
      'state': 'preparing',
      'workerRunId': runId,
      'revision': (selected.data()['revision'] as int) + 1,
    });
    if (priority == selected.id)
      await priorityRef.update({'nextRequestId': null});
    return (await selected.reference.get()).data();
  }

  Future<void> settle() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await worker.poll();
  }

  // Wait for event-driven behavior without manually polling the worker.
  Future<void> waitFor(bool Function() ready, {int seconds = 2}) async {
    final deadline = DateTime.now().add(Duration(seconds: seconds));
    while (!ready()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Worker did not reach expected state');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  setUp(() async {
    db = _InterruptibleFirestore();
    owners = StreamController<String?>.broadcast(sync: true);
    temp = await Directory.systemTemp.createTemp('publication_test');
    launches = [];
    stop = () async {};
    pause = () async {};
    resumes = 0;
    activity = [];
    shutdownStates = [];
    download = (_) async => DownloadedAttachment(bytes, '1');
    claim = claimNext;
    await db.doc('remote_control_devices/device').set({'ownerUid': 'owner'});
    worker = FirebaseChatReceiver(
      firestore: db,
      claimNext: (runId) => claim(runId),
      onActivity: (event) => activity.add(event),
      deviceId: 'device',
      ownerChanges: owners.stream,
      mediaDirectory: () async => temp,
      downloadAttachment: (path) => download(path),
      launch: (data, id) async {
        launches.add(id);
        FirebaseChatReceiver.bindControls(
          id,
          id,
          pause: () => pause(),
          resume: () {
            resumes++;
          },
          stop: () => stop(),
          shutdown: (state) {
            shutdownStates.add(state);
            return stop();
          },
        );
        return true;
      },
    );
    worker.startListening();
    owners.add('owner');
  });
  tearDown(() async {
    worker.dispose();
    await owners.close();
    await temp.delete(recursive: true);
  });

  test(
    'idle enqueue and completed publication advance without polling',
    () async {
      await settle();
      activity.clear();
      await enqueue('a', 1);
      await waitFor(() => launches.length == 1);
      expect(activity, contains('queue_available'));
      await enqueue('b', 2);
      final id = launches.first;
      await FirebaseChatReceiver.reportAutomationStatus(
        identity: id,
        statusType: 'platform_completed',
        platform: 'yad2',
        text: 'Yad2 done',
      );
      expect(launches.length, 1);
      await FirebaseChatReceiver.reportAutomationStatus(
        identity: id,
        statusType: 'platform_completed',
        platform: 'facebook',
        text: 'Done',
      );
      await waitFor(() => launches.length == 2);
      expect(launches.map((id) => id.requestId), ['a', 'b']);
    },
  );

  test('cancel drains the engine before event-driven handoff', () async {
    await enqueue('a', 1);
    await waitFor(() => launches.length == 1);
    await enqueue('b', 2);
    final entered = Completer<void>(), drained = Completer<void>();
    stop = () {
      entered.complete();
      return drained.future;
    };
    await request('a').update({
      'state': 'canceling',
      'control': {
        'id': 'cancel',
        'command': 'cancel',
        'attemptId': 'attempt_a',
      },
    });
    await entered.future.timeout(const Duration(seconds: 2));
    expect(launches.length, 1);
    drained.complete();
    await waitFor(() => launches.length == 2);
    expect((await request('a').get()).data()?['state'], 'canceled');
  });

  test(
    'idle listener is detached on sign-out and restored on sign-in',
    () async {
      await settle();
      owners.add(null);
      activity.clear();
      await enqueue('a', 1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(launches, isEmpty);
      expect(activity, isEmpty);
      owners.add('owner');
      await waitFor(() => launches.length == 1);
    },
  );

  test('slow reconciliation coalesces repeated requests', () async {
    await settle();
    final entered = Completer<void>(), release = Completer<void>();
    var calls = 0;
    claim = (_) async {
      calls++;
      if (calls == 1) {
        entered.complete();
        await release.future;
      }
      return null;
    };
    final first = worker.poll();
    await entered.future;
    final repeated = List.generate(100, (_) => worker.poll());
    release.complete();
    await Future.wait([first, ...repeated]);
    expect(calls, 2, reason: 'Only one follow-up pass is needed');
  });

  test(
    'active heartbeat renews the lease without full reconciliation',
    () async {
      await enqueue('a', 1);
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final before =
          (await db.doc('remote_chats/device').get()).data()?['leaseUntil']
              as Timestamp;
      activity.clear();
      await waitFor(() => activity.contains('heartbeat'), seconds: 12);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final after =
          (await db.doc('remote_chats/device').get()).data()?['leaseUntil']
              as Timestamp;
      expect(after.compareTo(before), greaterThan(0));
      expect(activity, isNot(contains('tick')));
      expect(activity, isNot(contains('claim')));
      expect(launches.length, 1);
    },
  );

  test('failed claim retries without another Firestore change', () async {
    await settle();
    var calls = 0;
    claim = (runId) async {
      calls++;
      if (calls == 1) throw StateError('temporary connection failure');
      return claimNext(runId);
    };
    await enqueue('a', 1);
    await waitFor(() => launches.length == 1, seconds: 12);
    expect(calls, 2);
    expect(launches.single.requestId, 'a');
  });

  test(
    'failed completion report is retried before advancing the queue',
    () async {
      await enqueue('a', 1);
      await settle();
      await enqueue('b', 2);
      final id = launches.first;
      await FirebaseChatReceiver.reportAutomationStatus(
        identity: id,
        statusType: 'platform_completed',
        platform: 'yad2',
        text: 'Yad2 done',
      );
      db.failTransactions = true;
      await FirebaseChatReceiver.reportAutomationStatus(
        identity: id,
        statusType: 'platform_completed',
        platform: 'facebook',
        text: 'Done',
      );
      expect((await request('a').get()).data()?['state'], 'publishing');
      expect(launches.length, 1);
      db.failTransactions = false;
      await waitFor(() => launches.length == 2, seconds: 12);
      expect((await request('a').get()).data()?['state'], 'completed');
      expect(launches.map((id) => id.requestId), ['a', 'b']);
    },
  );

  test(
    'FIFO queue stays reserved through Yad2 and pause, releases after Facebook',
    () async {
      await enqueue('a', 1);
      await enqueue('b', 2);
      await settle();
      expect(launches.map((e) => e.requestId), ['a']);
      await FirebaseChatReceiver.reportAutomationStatus(
        identity: launches.first,
        statusType: 'platform_completed',
        platform: 'yad2',
        text: 'Yad2 complete',
      );
      await settle();
      expect((await request('a').get()).data()!['state'], 'publishing');
      expect(launches.length, 1);
      await FirebaseChatReceiver.reportAutomationStatus(
        identity: launches.first,
        statusType: 'paused',
        text: 'Paused',
      );
      await settle();
      expect(launches.length, 1);
      await FirebaseChatReceiver.reportAutomationStatus(
        identity: launches.first,
        statusType: 'publishing',
        text: 'Resumed',
      );
      await FirebaseChatReceiver.reportAutomationStatus(
        identity: launches.first,
        statusType: 'platform_completed',
        platform: 'facebook',
        text: 'Done',
      );
      await settle();
      expect((await request('a').get()).data()!['state'], 'completed');
      expect(launches.map((e) => e.requestId), ['a', 'b']);
    },
  );
  test('leftover cancel control cannot stop a publishing request', () async {
    await enqueue('a', 1);
    await settle();
    var stops = 0;
    stop = () async {
      stops++;
    };
    await request('a').update({
      'control': {
        'id': 'old-cancel',
        'command': 'cancel',
        'attemptId': 'attempt_a',
      },
    });
    await settle();
    expect(stops, 0);
    expect((await request('a').get()).data()!['state'], 'publishing');
    await FirebaseChatReceiver.reportAutomationStatus(
      identity: launches.first,
      statusType: 'canceled',
      text: 'הפרסום בוטל',
    );
    expect((await request('a').get()).data()!['state'], 'publishing');
  });

  for (final terminalState in ['completed', 'failed']) {
    test(
      'external $terminalState cleanup never labels shutdown as canceled',
      () async {
        await enqueue('a', 1);
        await enqueue('b', 2);
        await settle();
        await request('a').update({'state': terminalState});
        await waitFor(() => launches.length == 2);
        expect(shutdownStates, [terminalState]);
        expect((await request('a').get()).data()!['state'], terminalState);
        final messages =
            await db.collection('remote_chats/device/messages').get();
        expect(
          messages.docs.any((doc) => doc.data()['statusType'] == 'canceled'),
          isFalse,
        );
      },
    );
  }

  test(
    'cancel waits for engine shutdown before acknowledging or starting next request',
    () async {
      await enqueue('a', 1);
      await enqueue('b', 2);
      await settle();
      final stopped = Completer<void>(), entered = Completer<void>();
      stop = () {
        if (!entered.isCompleted) entered.complete();
        return stopped.future;
      };
      await request('a').update({
        'state': 'canceling',
        'control': {
          'id': 'cancel1',
          'command': 'cancel',
          'attemptId': 'attempt_a',
        },
      });
      await entered.future.timeout(const Duration(seconds: 2));
      expect((await request('a').get()).data()!['state'], 'canceling');
      expect(launches.length, 1);
      stopped.complete();
      await settle();
      expect((await request('a').get()).data()!['state'], 'canceled');
      expect(launches.map((e) => e.requestId), ['a', 'b']);
    },
  );
  test(
    'external terminal state waits for engine drain before releasing the slot',
    () async {
      await enqueue('a', 1);
      await enqueue('b', 2);
      await settle();
      final entered = Completer<void>(), drained = Completer<void>();
      stop = () {
        if (!entered.isCompleted) entered.complete();
        return drained.future;
      };
      await request('a').update({'state': 'canceled'});
      await entered.future.timeout(const Duration(seconds: 2));
      expect(
        (await db.doc('remote_chats/device').get()).data()?['activeRequestId'],
        'a',
      );
      expect(launches.map((id) => id.requestId), ['a']);
      drained.complete();
      await settle();
      expect(launches.map((id) => id.requestId), ['a', 'b']);
    },
  );

  test(
    'deleting the previous canceled car leaves no reservation before adding a new car',
    () async {
      await enqueue('a', 1);
      await settle();
      await request('a').update({
        'state': 'canceling',
        'control': {
          'id': 'cancel_a',
          'command': 'cancel',
          'attemptId': 'attempt_a',
        },
      });
      await settle();
      expect((await request('a').get()).data()?['state'], 'canceled');
      await request('a').delete();
      await settle();
      final empty = (await db.doc('remote_chats/device').get()).data()!;
      expect(empty['activeRequestId'], isNull);
      expect(empty['workerRunId'], isNull);
      expect(empty['leaseUntil'], isNull);
      await enqueue('new', 2);
      await settle();
      expect(launches.map((id) => id.requestId), ['a', 'new']);
      expect((await request('new').get()).data()?['state'], 'publishing');
    },
  );

  test(
    'missing old request is reconciled before dispatching a new car',
    () async {
      await settle();
      await db.doc('remote_chats/device').set({
        'activeRequestId': 'deleted',
        'workerRunId': 'old_process',
        'leaseUntil': Timestamp.fromMillisecondsSinceEpoch(1),
      });
      await enqueue('new', 1);
      await settle();
      expect(launches.map((id) => id.requestId), ['new']);
      expect(
        (await db.doc('remote_chats/device').get()).data()?['activeRequestId'],
        'new',
      );
    },
  );

  test(
    'stale callbacks and stale controls cannot mutate the active request',
    () async {
      await enqueue('a', 1);
      await settle();
      await FirebaseChatReceiver.reportAutomationStatus(
        identity: const PublicationIdentity('device', 'a', 'old_attempt'),
        statusType: 'platform_completed',
        platform: 'facebook',
        text: 'late',
      );
      await request('a').update({
        'control': {
          'id': 'bad',
          'command': 'cancel',
          'attemptId': 'old_attempt',
        },
      });
      await settle();
      expect((await request('a').get()).data()!['state'], 'publishing');
      expect(
        (await db.doc('remote_chats/device').get()).data()!['activeRequestId'],
        'a',
      );
    },
  );
  test(
    'restart recovers uncertain job as stuck and never republishes automatically',
    () async {
      worker.dispose();
      await owners.close();
      owners = StreamController<String?>.broadcast(sync: true);
      await enqueue('a', 1);
      await enqueue('b', 2);
      await request(
        'a',
      ).update({'state': 'publishing', 'workerRunId': 'dead_process'});
      await db.doc('remote_chats/device').set({
        'activeRequestId': 'a',
        'workerRunId': 'dead_process',
        'leaseUntil': Timestamp.fromMillisecondsSinceEpoch(1),
      });
      worker = FirebaseChatReceiver(
        firestore: db,
        claimNext: claimNext,
        onActivity: (event) => activity.add(event),
        deviceId: 'device',
        ownerChanges: owners.stream,
        mediaDirectory: () async => temp,
        downloadAttachment: (_) async => DownloadedAttachment(bytes, '1'),
        launch: (data, id) async {
          launches.add(id);
          return true;
        },
      );
      worker.startListening();
      owners.add('owner');
      await settle();
      expect((await request('a').get()).data()!['state'], 'stuck');
      expect(launches, isEmpty);
      await request('a').update({
        'control': {
          'id': 'resume',
          'command': 'resume',
          'attemptId': 'attempt_a',
        },
      });
      await settle();
      expect((await request('a').get()).data()!['state'], 'stuck');
      expect(launches, isEmpty);
    },
  );
  test(
    'corrupt attachment fails preparation before any platform launches',
    () async {
      await enqueue('a', 1, checksum: '0' * 64);
      await settle();
      expect((await request('a').get()).data()!['state'], 'failed');
      expect(launches, isEmpty);
      expect(
        (await db.doc('remote_chats/device').get()).data()!['activeRequestId'],
        isNull,
      );
    },
  );
  test(
    'fresh reservation owned by another worker prevents a second claim',
    () async {
      await enqueue('a', 1);
      await enqueue('b', 2);
      await request(
        'a',
      ).update({'state': 'publishing', 'workerRunId': 'other'});
      await db.doc('remote_chats/device').set({
        'activeRequestId': 'a',
        'workerRunId': 'other',
        'leaseUntil': Timestamp.fromDate(
          DateTime.now().add(const Duration(minutes: 1)),
        ),
      });
      await settle();
      expect(launches, isEmpty);
      expect((await request('b').get()).data()!['state'], 'queued');
    },
  );
  test(
    'pause waits for engine drain and a newer cancellation supersedes its acknowledgment',
    () async {
      await enqueue('a', 1);
      await enqueue('b', 2);
      await settle();
      final drained = Completer<void>(), entered = Completer<void>();
      pause = () {
        if (!entered.isCompleted) entered.complete();
        return drained.future;
      };
      await request('a').update({
        'control': {
          'id': 'pause1',
          'command': 'pause',
          'attemptId': 'attempt_a',
        },
      });
      await entered.future.timeout(const Duration(seconds: 2));
      expect((await request('a').get()).data()!['state'], 'publishing');
      await request('a').update({
        'state': 'canceling',
        'control': {
          'id': 'cancel2',
          'command': 'cancel',
          'attemptId': 'attempt_a',
        },
      });
      drained.complete();
      await settle();
      final data = (await request('a').get()).data()!;
      expect(data['state'], 'canceled');
      expect(data['appliedControlId'], 'cancel2');
      expect(launches.map((e) => e.requestId), ['a', 'b']);
    },
  );
  test('duplicate resume delivery resumes one engine only once', () async {
    await enqueue('a', 1);
    await settle();
    await request('a').update({
      'control': {'id': 'pause1', 'command': 'pause', 'attemptId': 'attempt_a'},
    });
    await settle();
    await request('a').update({
      'control': {
        'id': 'resume1',
        'command': 'resume',
        'attemptId': 'attempt_a',
      },
    });
    await settle();
    await worker.poll();
    await worker.poll();
    expect(resumes, 1);
    expect((await request('a').get()).data()!['state'], 'publishing');
  });
  test(
    'priority selects the next car without preempting the active one',
    () async {
      await enqueue('a', 1);
      await settle();
      await enqueue('b', 2);
      await enqueue('c', 3);
      await db.doc('remote_publication_queues/device').set({
        'nextRequestId': 'c',
      });
      await request('a').update({
        'state': 'canceling',
        'control': {
          'id': 'cancel1',
          'command': 'cancel',
          'attemptId': 'attempt_a',
        },
      });
      await settle();
      expect(launches.map((e) => e.requestId), ['a', 'c']);
      expect((await request('b').get()).data()!['state'], 'queued');
    },
  );
  test(
    'sign-out fences callbacks and does not start another queued car',
    () async {
      await enqueue('a', 1);
      await enqueue('b', 2);
      await settle();
      final id = launches.first;
      owners.add(null);
      expect(FirebaseChatReceiver.isCurrent(id), false);
      await FirebaseChatReceiver.reportAutomationStatus(
        identity: id,
        statusType: 'failed',
        text: 'late',
      );
      await settle();
      expect((await request('a').get()).data()!['state'], 'publishing');
      expect(launches.length, 1);
    },
  );

  test(
    'pause during preparation holds the prepared car until explicit resume',
    () async {
      final entered = Completer<void>(), ready = Completer<void>();
      download = (_) async {
        entered.complete();
        await ready.future;
        return DownloadedAttachment(bytes, '1');
      };
      await enqueue('a', 1);
      unawaited(worker.poll());
      await entered.future.timeout(const Duration(seconds: 2));
      await request('a').update({
        'control': {
          'id': 'pause1',
          'command': 'pause',
          'attemptId': 'attempt_a',
        },
      });
      ready.complete();
      await settle();
      expect((await request('a').get()).data()!['state'], 'paused');
      expect(launches, isEmpty);
      await request('a').update({
        'control': {
          'id': 'resume1',
          'command': 'resume',
          'attemptId': 'attempt_a',
        },
      });
      await settle();
      expect(launches.map((e) => e.requestId), ['a']);
      expect((await request('a').get()).data()!['state'], 'publishing');
    },
  );
  test(
    'draft, image metadata, priority and queued car changes cause zero worker callbacks',
    () async {
      var pauses = 0, stops = 0;
      pause = () async {
        pauses++;
      };
      stop = () async {
        stops++;
      };
      await enqueue('a', 1);
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      activity.clear();
      await db.doc('remote_validation_limits/owner_device_chat').set({
        'count': 20,
      });
      await db.doc('remote_chats/device/messages/new_draft').set({
        'sessionId': 'b',
        'type': 'text',
        'text': 'new car',
      });
      await request('draft').set({'ownerUid': 'owner', 'state': 'draft'});
      await enqueue('b', 2);
      await request('b').update({
        'attachments': [
          {'path': 'new_image', 'size': 1234},
        ],
      });
      await db.doc('remote_publication_queues/device').set({
        'nextRequestId': 'b',
      });
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(
        activity,
        isEmpty,
        reason: 'Unrelated writes must not deliver snapshots, ticks, or claims',
      );
      await worker.poll();
      expect(activity.where((event) => event == 'claim'), isEmpty);
      expect(launches.map((e) => e.requestId), ['a']);
      expect(pauses, 0);
      expect(stops, 0);
      expect(resumes, 0);
      expect((await request('a').get()).data()!['state'], 'publishing');
    },
  );

  test(
    'remote disconnect always leaves publication paused until explicit resume',
    () async {
      await enqueue('a', 1);
      await settle();
      await FirebaseChatReceiver.pauseForTakeover();
      expect((await request('a').get()).data()!['state'], 'paused');
      FirebaseChatReceiver.resumeAfterTakeover();
      await settle();
      expect(resumes, 0);
      await FirebaseChatReceiver.setLocalPaused(launches.first, true);
      await FirebaseChatReceiver.pauseForTakeover();
      FirebaseChatReceiver.resumeAfterTakeover();
      await settle();
      expect(resumes, 0);
      expect((await request('a').get()).data()!['state'], 'paused');
    },
  );
  test(
    'park drains current browser and advances queue without canceling paused request',
    () async {
      await enqueue('a', 1);
      await enqueue('b', 2);
      await settle();
      final id = launches.first;
      await FirebaseChatReceiver.setLocalPaused(id, true);
      final drained = Completer<void>();
      stop = () => drained.future;
      await request('a').update({
        'control': {
          'id': 'park-a',
          'command': 'park',
          'attemptId': id.attemptId,
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(launches.length, 1);
      expect((await request('a').get()).data()!['parked'], isNot(true));
      drained.complete();
      await waitFor(() => launches.length == 2);
      final parked = (await request('a').get()).data()!;
      expect(parked['state'], 'paused');
      expect(shutdownStates, ['paused']);
      expect(parked['parked'], true);
      expect(parked['attachments'], isNotEmpty);
      expect(launches.last.requestId, 'b');
    },
  );
}
