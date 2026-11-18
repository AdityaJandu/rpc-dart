import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trpc_dart/trpc_dart.dart';
import 'package:trpc_flutter/trpc_flutter.dart';

void main() {
  group('RpcSubscriptionController', () {
    test(
        'transitions connecting -> active (bounded history) -> done over a live stream',
        () async {
      final events = StreamController<int>();
      final controller = RpcSubscriptionController<int>(
        streamFactory: ({lastEventId, onReconnect}) => events.stream,
        keepHistoryCount: 2,
      );

      final states = <RpcSubscriptionState<int>>[];
      final listener = () => states.add(controller.value);
      controller.addListener(listener);

      controller.start();
      expect(controller.value.status, RpcSubscriptionStatus.connecting);
      expect(controller.value.isConnecting, isTrue);

      for (final event in [1, 2, 3]) {
        events.add(event);
        await Future<void>.delayed(Duration.zero);
      }

      expect(controller.value.status, RpcSubscriptionStatus.active);
      expect(controller.value.isActive, isTrue);
      expect(controller.value.data, 3);
      expect(controller.value.hasData, isTrue);
      expect(controller.value.history, [2, 3]);
      expect(states.map((s) => s.status),
          containsAllInOrder([RpcSubscriptionStatus.connecting]));

      // Stream closed -> done, without error.
      await events.close();
      await Future<void>.delayed(Duration.zero);
      expect(controller.value.status, RpcSubscriptionStatus.done);
      expect(controller.value.hasError, isFalse);

      controller.removeListener(listener);
      controller.dispose();
    });

    test(
        'transitions connecting -> active -> reconnecting (preserving data & '
        'lastEventId) -> active across a drop/reconnect cycle', () async {
      final events = StreamController<int>();
      void Function(int, Object?)? reconnectHook;
      final controller = RpcSubscriptionController<int>(
        streamFactory: ({lastEventId, onReconnect}) {
          reconnectHook = onReconnect;
          return events.stream;
        },
        keepHistoryCount: 2,
      );

      controller.start();
      expect(controller.value.status, RpcSubscriptionStatus.connecting);

      events.add(1);
      await Future<void>.delayed(Duration.zero);
      expect(controller.value.status, RpcSubscriptionStatus.active);
      expect(controller.value.data, 1);
      controller.trackEventId('evt-1');

      // Simulated drop: the link chain schedules a reconnect attempt.
      reconnectHook!(1, RpcNetworkException('dropped'));
      await Future<void>.delayed(Duration.zero);
      expect(controller.value.status, RpcSubscriptionStatus.reconnecting);
      expect(controller.value.isConnecting, isTrue);
      expect(controller.value.data, 1);
      expect(controller.value.lastEventId, 'evt-1');
      expect(controller.value.history, [1]);

      // The next event after re-subscribing returns to active.
      events.add(2);
      await Future<void>.delayed(Duration.zero);
      expect(controller.value.status, RpcSubscriptionStatus.active);
      expect(controller.value.data, 2);
      expect(controller.value.history, [1, 2]);

      await events.close();
      controller.dispose();
    });

    test('stream errors surface in state and onError hook', () async {
      final events = StreamController<int>();
      final seen = <RpcException?>[];
      final controller = RpcSubscriptionController<int>(
        streamFactory: ({lastEventId, onReconnect}) => events.stream,
        onError: seen.add,
      );

      controller.start();
      await events.addStream(
        Stream<int>.error(RpcUnauthorizedException('nope')),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.value.status, RpcSubscriptionStatus.error);
      expect(controller.value.hasError, isTrue);
      expect(controller.value.error, isA<RpcUnauthorizedException>());
      expect(seen.single, isA<RpcUnauthorizedException>());

      controller.dispose();
    });

    test('tracks event ids and resumes with them on restart', () async {
      String? requestedLastEventId;
      final controller = RpcSubscriptionController<int>(
        streamFactory: ({lastEventId, onReconnect}) {
          requestedLastEventId = lastEventId;
          return const Stream<int>.empty();
        },
      );

      controller.start();
      await Future<void>.delayed(Duration.zero);
      controller.trackEventId('evt-7');

      controller.restart();
      await Future<void>.delayed(Duration.zero);

      expect(controller.value.lastEventId, 'evt-7');
      expect(requestedLastEventId, 'evt-7');
      controller.dispose();
    });

    test('disposal cancels the underlying stream subscription', () async {
      var cancelled = false;
      final controller = StreamController<int>(
        onCancel: () async => cancelled = true,
      );
      final subject = RpcSubscriptionController<int>(
        streamFactory: ({lastEventId, onReconnect}) => controller.stream,
      );

      subject.start();
      await Future<void>.delayed(Duration.zero);
      expect(cancelled, isFalse);

      subject.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(cancelled, isTrue);
    });

    testWidgets('ValueListenableBuilder rebuilds as stream events arrive',
        (tester) async {
      final events = StreamController<int>();
      final controller = RpcSubscriptionController<int>(
        streamFactory: ({lastEventId, onReconnect}) => events.stream,
      );

      await tester.pumpWidget(
        ValueListenableBuilder<RpcSubscriptionState<int>>(
          valueListenable: controller,
          builder: (context, state, _) => Directionality(
            textDirection: TextDirection.ltr,
            child: Text(state.hasData ? 'tick-${state.data}' : 'waiting'),
          ),
        ),
      );
      expect(find.text('waiting'), findsOneWidget);

      controller.start();
      await events.addStream(Stream<int>.fromIterable([5, 6]));
      await tester.pumpAndSettle();

      expect(find.text('tick-6'), findsOneWidget);

      await events.close();
      await tester.pumpAndSettle();
      expect(controller.value.status, RpcSubscriptionStatus.done);

      controller.dispose();
    });

    test('auto-invalidates query cache prefixes on incoming events', () async {
      final cache = RpcQueryCache();
      final invalidated = <RpcQueryKey>[];
      final sub = cache
          .onInvalidate(const RpcQueryKey(path: ['streams']))
          .listen(invalidated.add);
      // Register a dependent query under the invalidated prefix.
      cache.watch<int>(
        const RpcQueryKey(path: ['streams', 'onActivity']),
        () async => 0,
      );

      final events = StreamController<String>();
      final controller = RpcSubscriptionController<String>(
        streamFactory: ({lastEventId, onReconnect}) => events.stream,
        queryCache: cache,
        invalidatePrefixesOnData: [
          const ['streams', 'onActivity'],
        ],
      );

      controller.start();
      await events.addStream(
        Stream<String>.value('activity-event'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(invalidated, hasLength(1));
      expect(invalidated.single.path, ['streams', 'onActivity']);

      await sub.cancel();
      await events.close();
      controller.dispose();
      cache.dispose();
    });
  });
}
