import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirsumoto_remote_control/models/publication_queue.dart';

Map<String, dynamic> job(String state, {int time = 1, bool archived = false}) =>
    {
      'state': state,
      'archived': archived,
      'enqueuedAt': Timestamp.fromMillisecondsSinceEpoch(time),
    };

void main() {
  test('empty queue is zero and first car has zero publications ahead', () {
    final queue = PublicationQueue({});
    expect(queue.waitingCount, 0);
    expect(queue.activeCount, 0);
    expect(queue.aheadOf('new'), isNull);
    final first = PublicationQueue({'new': job('queued')});
    expect(first.waitingCount, 1);
    expect(first.aheadOf('new'), 0);
    expect(first.labelFor('new'), 'ממתין למכשיר · 0 פרסומים לפניו');
  });

  test('deleted and terminal jobs never become phantom predecessors', () {
    final requests = {
      'deleted': job('queued', archived: true),
      'completed': job('completed'),
      'canceled': job('canceled'),
      'failed': job('failed'),
      'draft': job('draft'),
    };
    expect(PublicationQueue(requests, priority: 'deleted').waitingCount, 0);
    requests['new'] = job('queued', time: 10);
    final queue = PublicationQueue(requests, priority: 'deleted');
    expect(queue.waitingCount, 1);
    expect(queue.aheadOf('new'), 0);
  });

  test('real active job counts until cancellation is acknowledged', () {
    final requests = {'active': job('canceling'), 'next': job('queued')};
    expect(PublicationQueue(requests).aheadOf('next'), 1);
    requests['active'] = job('canceled');
    expect(PublicationQueue(requests).aheadOf('next'), 0);
    requests.remove('next');
    expect(PublicationQueue(requests).waitingCount, 0);
  });

  test('priority and FIFO count actual predecessors without counting self', () {
    final queue = PublicationQueue({
      'active': job('paused'),
      'a': job('queued', time: 1),
      'b': job('queued', time: 2),
      'c': job('queued', time: 3),
    }, priority: 'c');
    expect(queue.waiting, ['c', 'a', 'b']);
    expect(queue.aheadOf('c'), 1);
    expect(queue.aheadOf('a'), 2);
    expect(queue.aheadOf('b'), 3);
  });
  test('a parked paused car does not block the queue or count as an active predecessor', () {
    final queue = PublicationQueue({
      'parked': {'state':'paused', 'parked':true},
      'next': {'state':'queued', 'enqueuedAt':Timestamp.fromMillisecondsSinceEpoch(1)},
    });
    expect(queue.activeCount, 0);
    expect(queue.aheadOf('next'), 0);
  });

}
