import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirsumoto/services/automation_webview_session.dart';
import 'package:webview_flutter/webview_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class _Platform extends WebViewPlatform {
  final controllers = <_Controller>[];

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final controller = _Controller(params);
    controllers.add(controller);
    return controller;
  }
}

class _Controller extends PlatformWebViewController {
  _Controller(super.params) : super.implementation();

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Platform platform;
  final sessions = <AutomationWebViewSession>[];

  setUp(() {
    platform = _Platform();
    WebViewPlatform.instance = platform;
  });

  tearDown(() async {
    for (final session in sessions) {
      await session.close();
    }
    sessions.clear();
  });

  Future<AutomationWebViewSession?> open({
    bool auxiliary = false,
    bool Function()? isCurrent,
    Future<void> Function()? stop,
    Future<void> Function()? detach,
    Future<void> Function(WebViewController)? configure,
  }) async {
    final session = await AutomationWebViewSession.open(
      auxiliary: auxiliary,
      isCurrent: isCurrent ?? () => true,
      stop: stop ?? () async {},
      detach: detach ?? () async {},
      configure: configure ?? (_) async {},
    );
    if (session != null) sessions.add(session);
    return session;
  }

  test(
    'replacement waits for automation drain and view removal before creating a controller',
    () async {
      final drained = Completer<void>();
      final detached = Completer<void>();
      final stopping = Completer<void>();
      final detaching = Completer<void>();
      final first = await open(
        stop: () async {
          stopping.complete();
          await drained.future;
        },
        detach: () async {
          detaching.complete();
          await detached.future;
        },
      );
      final next = open();
      await stopping.future;
      expect(platform.controllers, hasLength(1));
      drained.complete();
      await detaching.future;
      expect(platform.controllers, hasLength(1));
      detached.complete();
      final second = await next;
      expect(platform.controllers, hasLength(2));
      expect(second!.controller, isNot(same(first!.controller)));
    },
  );

  test(
    'simultaneous starts serialize teardown and late close cannot close the new owner',
    () async {
      final events = <String>[];
      Future<AutomationWebViewSession?> numbered(int id) => open(
        configure: (_) async => events.add('open $id'),
        stop: () async => events.add('stop $id'),
        detach: () async => events.add('detach $id'),
      );
      final opened = await Future.wait([numbered(1), numbered(2), numbered(3)]);
      expect(events, [
        'open 1',
        'stop 1',
        'detach 1',
        'open 2',
        'stop 2',
        'detach 2',
        'open 3',
      ]);
      await opened.first!.close();
      expect(events.last, 'open 3');
      await opened.last!.close();
      await opened.last!.close();
      expect(events.where((event) => event == 'stop 3'), hasLength(1));
    },
  );

  test('canceled queued startup never creates another WebView', () async {
    final draining = Completer<void>();
    final stopping = Completer<void>();
    await open(
      stop: () async {
        stopping.complete();
        await draining.future;
      },
    );
    var current = true;
    final next = open(isCurrent: () => current);
    await stopping.future;
    current = false;
    draining.complete();
    expect(await next, isNull);
    expect(platform.controllers, hasLength(1));
  });

  test(
    'route disposed during configuration is torn down before a later start',
    () async {
      var current = true;
      final configuring = Completer<void>();
      final configured = Completer<void>();
      final events = <String>[];
      final first = open(
        isCurrent: () => current,
        configure: (_) async {
          configuring.complete();
          await configured.future;
        },
        stop: () async => events.add('stop'),
        detach: () async => events.add('detach'),
      );
      await configuring.future;
      current = false;
      final second = open(configure: (_) async => events.add('next'));
      configured.complete();
      expect(await first, isNull);
      expect(await second, isNotNull);
      expect(events, ['stop', 'detach', 'next']);
    },
  );

  test(
    'failed configuration closes its browser and permits a fresh start',
    () async {
      var closed = false;
      await expectLater(
        open(
          configure: (_) async => throw StateError('load failed'),
          detach: () async => closed = true,
        ),
        throwsStateError,
      );
      expect(closed, isTrue);
      expect(await open(), isNotNull);
      expect(platform.controllers, hasLength(2));
    },
  );
  test(
    'login browsers coexist with automation and close with their owning session',
    () async {
      final events = <String>[];
      final root = await open(stop: () async => events.add('root'));
      final login = await open(
        auxiliary: true,
        detach: () async => events.add('login'),
      );
      expect(events, isEmpty);
      expect(platform.controllers, hasLength(2));
      await root!.close();
      expect(events, ['root', 'login']);
      await open(configure: (_) async => events.add('new'));
      await login!.close();
      expect(events, ['root', 'login', 'new']);
    },
  );

  test('new automation closes a standalone preset-login browser', () async {
    var closed = false;
    await open(auxiliary: true, detach: () async => closed = true);
    await open(configure: (_) async => expect(closed, isTrue));
  });

  test(
    'failed teardown blocks replacement until cleanup can succeed',
    () async {
      var failDrain = true;
      await open(
        stop: () async {
          if (failDrain) throw StateError('phase still running');
        },
      );
      await expectLater(open(), throwsStateError);
      expect(platform.controllers, hasLength(1));
      failDrain = false;
      expect(await open(), isNotNull);
      expect(platform.controllers, hasLength(2));
    },
  );
  test(
    'expired session forces failed drain cleanup and cannot close its successor',
    () async {
      var detached = false;
      final expired = await open(
        stop: () async => throw StateError('stuck phase'),
        detach: () async => detached = true,
      );
      await expired!.expire();
      expect(detached, isTrue);
      var successorClosed = false;
      await open(detach: () async => successorClosed = true);
      await expired.expire();
      expect(successorClosed, isFalse);
    },
  );
}
