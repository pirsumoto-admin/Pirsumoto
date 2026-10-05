import 'package:flutter_test/flutter_test.dart';
import 'package:pirsumoto/services/publication_session_deadline.dart';

void main() {
  testWidgets('expires at fifteen minutes and fires once', (tester) async {
    var expired = 0;
    final deadline = PublicationSessionDeadline('first');
    await deadline.start(() async {
      expired++;
    });
    await tester.pump(const Duration(minutes: 14, seconds: 59));
    expect(expired, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(expired, 1);
    await tester.pump(const Duration(minutes: 1));
    expect(expired, 1);
    await deadline.cancel();
  });

  testWidgets('canceling an old session leaves the newer deadline intact', (
    tester,
  ) async {
    var oldExpired = 0, newExpired = 0;
    final old = PublicationSessionDeadline('old');
    await old.start(() async {
      oldExpired++;
    });
    await tester.pump(const Duration(minutes: 10));
    await old.cancel();
    final current = PublicationSessionDeadline('new');
    await current.start(() async {
      newExpired++;
    });
    await old.cancel();
    await tester.pump(const Duration(minutes: 5));
    expect(oldExpired, 0);
    expect(newExpired, 0);
    await tester.pump(const Duration(minutes: 10));
    expect(newExpired, 1);
    await current.cancel();
  });
}
