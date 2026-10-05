import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:publication_protocol/publication_protocol.dart';

/// Derived from live requests, never from a persisted queue counter.
class PublicationQueue {
  final List<String> waiting;
  final int activeCount;

  PublicationQueue(
    Map<String, Map<String, dynamic>> requests, {
    String? priority,
  }) : waiting = _ordered(requests, priority),
       activeCount = requests.values
           .where(
             (r) =>
                 r['archived'] != true &&
                 r['parked'] != true &&
                 PublicationState.occupied.contains(r['state']),
           )
           .length;

  int get waitingCount => waiting.length;

  int? aheadOf(String id) {
    final index = waiting.indexOf(id);
    return index < 0 ? null : activeCount + index;
  }

  String labelFor(String id) {
    final ahead = aheadOf(id);
    if (ahead == null) return 'מסנכרן מצב פרסום';
    return ahead == 0
        ? 'ממתין למכשיר · 0 פרסומים לפניו'
        : 'ממתין בתור · $ahead פרסומים לפניו';
  }

  static List<String> _ordered(
    Map<String, Map<String, dynamic>> requests,
    String? priority,
  ) {
    final entries = requests.entries
        .where(
          (e) => e.value['state'] == 'queued' && e.value['archived'] != true,
        )
        .toList();
    entries.sort((a, b) {
      if (a.key == b.key) return 0;
      if (a.key == priority) return -1;
      if (b.key == priority) return 1;
      final at = a.value['enqueuedAt'], bt = b.value['enqueuedAt'];
      // HTTP enqueue responses may precede the authoritative timestamp snapshot.
      if (at is! Timestamp && bt is Timestamp) return 1;
      if (at is Timestamp && bt is! Timestamp) return -1;
      final order = at is Timestamp && bt is Timestamp ? at.compareTo(bt) : 0;
      return order == 0 ? a.key.compareTo(b.key) : order;
    });
    return entries.map((e) => e.key).toList(growable: false);
  }
}
