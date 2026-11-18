import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:trpc_dart/src/codec.dart';
import 'package:trpc_dart/src/http_subscription_link.dart';
import 'package:trpc_dart/src/exceptions.dart';
import 'package:trpc_dart/src/link.dart';
import 'package:trpc_dart/src/subscription.dart';

void main() {
  group('HttpSubscriptionLink', () {
    late _FakeSseServer server;
    late HttpSubscriptionLink link;

    setUp(() {
      server = _FakeSseServer();
      link = HttpSubscriptionLink(
        endpoint: Uri.parse('http://localhost:8787/trpc'),
        client: server.client,
      );
    });

    test('streams SuperJSON events (Date, BigInt, Set, Map) decoded cleanly',
        () async {
      server.respondWith(
        (request) => _sseBody([
          'event: connected\ndata: {}\n\n',
          'data: ${jsonEncode(superjsonEncode(<String, Object?>{
                'at': DateTime.utc(2026, 1, 15, 10),
                'balance': BigInt.from(4200),
                'tags': <String>{'a', 'b'},
                'nested': <String, Object?>{'deep': true},
              }))}\n\n',
          'event: return\ndata: \n\n',
        ]),
      );

      final request = RpcRequest(
        path: 'streams.onServerTick',
        kind: RpcProcedureKind.subscription,
        input: null,
      );
      final events = await link.invokeStream(request, _noNext).toList();
      expect(events, hasLength(1));
      final value = events.single as Map<String, Object?>;
      expect(value['at'], DateTime.utc(2026, 1, 15, 10));
      expect(value['balance'], BigInt.from(4200));
      expect(value['tags'], <String>{'a', 'b'});
      expect(value['nested'], <String, Object?>{'deep': true});
    });

    test('GET request carries SSE headers and urlencoded input', () async {
      http.BaseRequest? seen;
      server.respondWith((request) {
        seen = request;
        return _sseBody(['event: return\ndata: \n\n']);
      });

      final request = RpcRequest(
        path: 'streams.onActivity',
        kind: RpcProcedureKind.subscription,
        input: <String, Object?>{'channelId': 'c1'},
      );
      await link.invokeStream(request, _noNext).toList();

      expect(seen, isA<http.Request>());
      final req = seen! as http.Request;
      expect(req.method, 'GET');
      expect(req.url.path, '/trpc/streams.onActivity');
      expect(req.url.queryParameters['input'], isNotNull);
      expect(req.headers['accept'], contains('text/event-stream'));
      expect(req.headers['cache-control'], 'no-cache');
    });

    test('records tracked ids and resumes with Last-Event-ID after a drop',
        () async {
      final ticket = RpcSubscriptionTicket(
        const RpcSubscriptionOptions(
          reconnectPolicy: RpcReconnectPolicy(
            maxAttempts: 5,
            initialDelay: Duration(milliseconds: 1),
          ),
        ),
      );
      final request = RpcRequest(
        path: 'streams.onActivity',
        kind: RpcProcedureKind.subscription,
        input: null,
        subscription: ticket,
      );

      var connections = 0;
      server.respondWith((request) {
        connections++;
        if (connections == 1) {
          return _sseBody([
            'id: 1\ndata: ${jsonEncode(superjsonEncode('one'))}\n\n',
            'id: 2\ndata: ${jsonEncode(superjsonEncode('two'))}\n\n',
            'id: 3\ndata: ${jsonEncode(superjsonEncode('three'))}\n\n',
            // Abrupt close: no `return` event, no stopped frame.
          ], closeAbruptly: true);
        }
        return _sseBody([
          'id: 4\ndata: ${jsonEncode(superjsonEncode('four'))}\n\n',
          'event: return\ndata: \n\n',
        ]);
      });

      // Reconnection is the chain engine's job; drive it end-to-end.
      final chain = RpcLinkChain([link]);
      final events = await chain.invokeStream(request).toList();

      expect(events, ['one', 'two', 'three', 'four']);
      expect(connections, 2);
      expect(server.lastRequest!.headers['last-event-id'], '3');
      expect(ticket.lastEventId, '4');
    });

    test('sends Last-Event-ID on the first connection when options set it',
        () async {
      final ticket = RpcSubscriptionTicket(
        const RpcSubscriptionOptions(lastEventId: '42'),
      );
      final request = RpcRequest(
        path: 'streams.onActivity',
        kind: RpcProcedureKind.subscription,
        input: null,
        subscription: ticket,
      );
      server.respondWith((request) => _sseBody(['event: return\ndata: \n\n']));

      await link.invokeStream(request, _noNext).toList();

      expect(server.lastRequest!.headers['last-event-id'], '42');
    });

    test('invokes onEventId for every tracked id received', () async {
      final ids = <String>[];
      final ticket = RpcSubscriptionTicket(
        RpcSubscriptionOptions(onEventId: ids.add),
      );
      final request = RpcRequest(
        path: 'streams.onActivity',
        kind: RpcProcedureKind.subscription,
        input: null,
        subscription: ticket,
      );
      server.respondWith((request) => _sseBody([
            'id: a\ndata: ${jsonEncode(superjsonEncode('one'))}\n\n',
            'id: b\ndata: ${jsonEncode(superjsonEncode('two'))}\n\n',
            'event: return\ndata: \n\n',
          ]));

      await link.invokeStream(request, _noNext).toList();

      expect(ids, ['a', 'b']);
    });

    test('closes the stream cleanly on a normal return event (no reconnect)',
        () async {
      var connections = 0;
      server.respondWith((request) {
        connections++;
        return _sseBody([
          'data: ${jsonEncode(superjsonEncode('final'))}\n\n',
          'event: return\ndata: \n\n',
        ]);
      });
      final request = RpcRequest(
        path: 'streams.onServerTick',
        kind: RpcProcedureKind.subscription,
        input: null,
      );

      final events = await link.invokeStream(request, _noNext).toList();

      expect(events, ['final']);
      expect(connections, 1);
    });

    test('serialized-error events surface as typed RpcExceptions', () async {
      server.respondWith((request) => _sseBody([
            'event: serialized-error\ndata: ${jsonEncode(superjsonEncode(<String, Object?>{
                  'message': 'nope',
                  'code': -32001,
                  'data': <String, Object?>{
                    'code': 'UNAUTHORIZED',
                    'httpStatus': 401,
                    'path': 'streams.onActivity',
                  },
                }))}\n\n',
          ]));
      final request = RpcRequest(
        path: 'streams.onActivity',
        kind: RpcProcedureKind.subscription,
        input: null,
      );

      await expectLater(
        link.invokeStream(request, _noNext).toList(),
        throwsA(isA<RpcUnauthorizedException>()),
      );
    });

    test('cancelling the subscription aborts the in-flight HTTP stream',
        () async {
      server.respondWith((request) => _sseBody([
            'data: ${jsonEncode(superjsonEncode('first'))}\n\n',
            'data: ${jsonEncode(superjsonEncode('second'))}\n\n',
            'data: ${jsonEncode(superjsonEncode('third'))}\n\n',
          ], holdOpen: true));
      final request = RpcRequest(
        path: 'streams.onServerTick',
        kind: RpcProcedureKind.subscription,
        input: null,
      );

      final sub = link.invokeStream(request, _noNext).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final stopwatch = DateTime.now();
      await sub.cancel();
      final elapsed = DateTime.now().difference(stopwatch);

      expect(elapsed.inMilliseconds, lessThan(1000));
    });

    test('CancelToken cancellation surfaces RpcCancelledException', () async {
      server.respondWith((request) => _sseBody([
            'data: ${jsonEncode(superjsonEncode('first'))}\n\n',
          ], holdOpen: true));
      final token = CancelToken();
      final ticket = RpcSubscriptionTicket(
        const RpcSubscriptionOptions(),
      );
      final request = RpcRequest(
        path: 'streams.onServerTick',
        kind: RpcProcedureKind.subscription,
        input: null,
        subscription: ticket,
        context: RpcCallContext(cancelToken: token),
      );

      final done = link.invokeStream(request, _noNext).toList();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      token.cancel();

      await expectLater(done, throwsA(isA<RpcCancelledException>()));
    });

    test(
        'idle timeout aborts a stalled stream and reconnects with Last-Event-ID',
        () async {
      final ticket = RpcSubscriptionTicket(
        const RpcSubscriptionOptions(
          idleTimeout: Duration(milliseconds: 40),
          reconnectPolicy: RpcReconnectPolicy(
            maxAttempts: 5,
            initialDelay: Duration(milliseconds: 1),
          ),
        ),
      );
      final request = RpcRequest(
        path: 'streams.onActivity',
        kind: RpcProcedureKind.subscription,
        input: null,
        subscription: ticket,
      );

      var connections = 0;
      server.respondWith((request) {
        connections++;
        if (connections == 1) {
          // One tracked frame, then silence: a half-open dead connection.
          return _sseBody([
            'id: 1\ndata: ${jsonEncode(superjsonEncode('one'))}\n\n',
          ], holdOpen: true);
        }
        return _sseBody([
          'id: 2\ndata: ${jsonEncode(superjsonEncode('two'))}\n\n',
          'event: return\ndata: \n\n',
        ]);
      });

      final chain = RpcLinkChain([link]);
      final events = await chain.invokeStream(request).toList();

      expect(events, ['one', 'two']);
      expect(connections, 2);
      expect(server.lastRequest!.headers['last-event-id'], '1');
    }, timeout: const Timeout(Duration(seconds: 5)));

    test(':ping comments keep the stream alive past idleTimeout (no reconnect)',
        () async {
      final ticket = RpcSubscriptionTicket(
        const RpcSubscriptionOptions(
          idleTimeout: Duration(milliseconds: 40),
          reconnectPolicy: RpcReconnectPolicy(
            maxAttempts: 5,
            initialDelay: Duration(milliseconds: 1),
          ),
        ),
      );
      final request = RpcRequest(
        path: 'streams.onActivity',
        kind: RpcProcedureKind.subscription,
        input: null,
        subscription: ticket,
      );

      var connections = 0;
      server.respondWith((request) {
        connections++;
        // Pings every 15ms span ~60ms, longer than the 40ms idle window.
        return _sseScheduled([
          (0, 'id: 1\ndata: ${jsonEncode(superjsonEncode('one'))}\n\n'),
          (15, ':ping\n\n'),
          (15, ':ping\n\n'),
          (15, ':ping\n\n'),
          (15, ':ping\n\n'),
          (0, 'id: 2\ndata: ${jsonEncode(superjsonEncode('two'))}\n\n'),
          (0, 'event: return\ndata: \n\n'),
        ]);
      });

      final chain = RpcLinkChain([link]);
      final events = await chain.invokeStream(request).toList();

      expect(events, ['one', 'two']);
      expect(connections, 1);
    }, timeout: const Timeout(Duration(seconds: 5)));

    test('SSE retry: hint floors the next reconnect delay', () async {
      final ticket = RpcSubscriptionTicket(
        const RpcSubscriptionOptions(
          reconnectPolicy: RpcReconnectPolicy(
            maxAttempts: 5,
            initialDelay: Duration(milliseconds: 1),
            jitterRatio: 0,
          ),
        ),
      );
      final request = RpcRequest(
        path: 'streams.onActivity',
        kind: RpcProcedureKind.subscription,
        input: null,
        subscription: ticket,
      );

      final connectTimes = <DateTime>[];
      var connections = 0;
      server.respondWith((request) {
        connectTimes.add(DateTime.now());
        connections++;
        if (connections == 1) {
          return _sseBody([
            'retry: 120\n\n',
            'id: 1\ndata: ${jsonEncode(superjsonEncode('one'))}\n\n',
          ], closeAbruptly: true);
        }
        return _sseBody([
          'id: 2\ndata: ${jsonEncode(superjsonEncode('two'))}\n\n',
          'event: return\ndata: \n\n',
        ]);
      });

      final chain = RpcLinkChain([link]);
      final events = await chain.invokeStream(request).toList();

      expect(events, ['one', 'two']);
      expect(connections, 2);
      expect(ticket.retryHint, const Duration(milliseconds: 120));
      final gap = connectTimes[1].difference(connectTimes[0]).inMilliseconds;
      expect(gap, greaterThanOrEqualTo(100));
    });
  });
}

Stream<Object?> _noNext(RpcRequest request) {
  throw StateError('termination link must not call next');
}

typedef SseHandler = Future<Stream<List<int>>> Function(
    http.BaseRequest request);

class _FakeSseServer {
  final List<http.BaseRequest> requests = <http.BaseRequest>[];
  SseHandler? _handler;
  late final _FakeHttpClient client = _FakeHttpClient(this);

  http.BaseRequest? get lastRequest => requests.isEmpty ? null : requests.last;

  void respondWith(SseHandler handler) => _handler = handler;
}

class _FakeHttpClient extends http.BaseClient {
  _FakeHttpClient(this.server);

  final _FakeSseServer server;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    server.requests.add(request);
    return http.StreamedResponse(
      await server._handler!(request),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }
}

// Controller-based: an async* generator held open by a never-completing
// await defers subscription cancellation indefinitely, which would hang the
// cancellation tests. A never-closed controller cancels immediately.
Future<Stream<List<int>>> _sseBody(
  List<String> frames, {
  bool closeAbruptly = false,
  bool holdOpen = false,
}) async {
  final controller = StreamController<List<int>>();
  unawaited(() async {
    for (final frame in frames) {
      controller.add(utf8.encode(frame));
      await Future<void>.delayed(const Duration(milliseconds: 1));
      if (controller.isClosed) return;
    }
    if (!holdOpen) await controller.close();
    // holdOpen leaves the controller open; closeAbruptly vs default differ
    // only in whether an `event: return` frame preceded.
  }());
  return controller.stream;
}

// Emits each frame after its inter-frame delay (ms), then closes. Used to
// space heartbeats across an idle window.
Future<Stream<List<int>>> _sseScheduled(List<(int, String)> timed) async {
  final controller = StreamController<List<int>>();
  unawaited(() async {
    for (final (delayMs, frame) in timed) {
      if (delayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: delayMs));
      }
      if (controller.isClosed) return;
      controller.add(utf8.encode(frame));
    }
    await controller.close();
  }());
  return controller.stream;
}
