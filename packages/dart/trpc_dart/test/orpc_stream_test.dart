import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:trpc_dart/trpc_dart.dart';

import 'orpc_link_test.dart' show FakeHttpClient;

RpcRequest streamReq(
  String path, {
  Object? input,
  RpcSubscriptionTicket? ticket,
  RpcCallContext? context,
}) =>
    RpcRequest(
      path: path,
      kind: RpcProcedureKind.subscription,
      input: input,
      subscription: ticket,
      context: context,
    );

String sseFrame(String event, Object? data, {String? id}) {
  final buffer = StringBuffer();
  if (id != null) buffer.writeln('id: $id');
  buffer.writeln('event: $event');
  buffer.writeln('data: ${jsonEncode(data)}');
  buffer.writeln();
  return buffer.toString();
}

void main() {
  late FakeHttpClient client;
  late OrpcLink link;

  setUp(() {
    client = FakeHttpClient();
    link = OrpcLink(endpoint: Uri.parse('https://x.dev/rpc'), client: client);
  });

  group('OrpcLink event iterator streaming', () {
    test('decodes message frames and completes cleanly on done', () async {
      final controller = StreamController<List<int>>();
      client.reply(controller.stream,
          headers: {'content-type': 'text/event-stream'});
      final ticket = RpcSubscriptionTicket(const RpcSubscriptionOptions());
      final events = <Object?>[];
      final done = Completer<void>();
      late StreamSubscription<Object?> sub;
      sub = link
          .invokeStream(streamReq('planet.watch', ticket: ticket),
              (_) => throw StateError('termination'))
          .listen(
            events.add,
            onError: done.completeError,
            onDone: done.complete,
          );
      controller.add(utf8.encode(': keepalive\n\n'));
      controller.add(utf8.encode(sseFrame(
          'message',
          {
            'json': {'tick': 1, 'at': '2022-01-01T00:00:00.000Z'},
            'meta': [
              [1, 'at']
            ],
          },
          id: 'evt-1')));
      controller.add(utf8.encode(sseFrame('done', null)));
      await done.future.timeout(const Duration(seconds: 5));
      await sub.cancel();
      expect(events.length, 1);
      final item = events.single! as Map<String, Object?>;
      expect(item['tick'], 1);
      expect(item['at'], DateTime.utc(2022, 1, 1));
      expect(ticket.lastEventId, 'evt-1');
      final sent = client.sent.single;
      expect(sent.method, 'POST');
      expect(sent.url.path, '/rpc/planet/watch');
      expect(sent.headers['accept'], 'text/event-stream');
    });

    test('sends last-event-id from the ticket on resume', () async {
      client.reply(const Stream<List<int>>.empty(),
          headers: {'content-type': 'text/event-stream'});
      final ticket = RpcSubscriptionTicket(
          const RpcSubscriptionOptions(lastEventId: 'evt-9'));
      final stream = link.invokeStream(
          streamReq('planet.watch', ticket: ticket),
          (_) => throw StateError('termination'));
      await stream.drain<void>().catchError((Object _) {});
      expect(client.sent.single.headers['last-event-id'], 'evt-9');
    });

    test('error frames surface typed exceptions and close the stream',
        () async {
      final controller = StreamController<List<int>>();
      client.reply(controller.stream,
          headers: {'content-type': 'text/event-stream'});
      final errors = <Object>[];
      final done = Completer<void>();
      link
          .invokeStream(
              streamReq('planet.watch'), (_) => throw StateError('termination'))
          .listen(
        (_) {},
        onError: (Object e) {
          errors.add(e);
        },
        onDone: done.complete,
      );
      controller.add(utf8.encode(sseFrame('error', {
        'json': {
          'defined': true,
          'code': 'NOT_FOUND',
          'status': 404,
          'message': 'gone',
        },
      })));
      await done.future.timeout(const Duration(seconds: 5));
      expect(errors.single, isA<RpcNotFoundException>());
    });

    test('abrupt stream end without done is a retryable network failure',
        () async {
      final controller = StreamController<List<int>>();
      client.reply(controller.stream,
          headers: {'content-type': 'text/event-stream'});
      final errors = <Object>[];
      final done = Completer<void>();
      link
          .invokeStream(
              streamReq('planet.watch'), (_) => throw StateError('termination'))
          .listen((_) {}, onError: errors.add, onDone: done.complete);
      unawaited(controller.close());
      await done.future.timeout(const Duration(seconds: 5));
      expect(errors.single, isA<RpcNetworkException>());
      expect(isRetryableStreamError(errors.single), isTrue);
    });

    test('non-200 responses parse the ORPCError body', () async {
      client.reply(
        '{"json":{"defined":false,"code":"UNAUTHORIZED","status":401,"message":"Unauthorized"}}',
        status: 401,
        headers: {'content-type': 'application/json'},
      );
      await expectLater(
        link
            .invokeStream(streamReq('planet.watch'),
                (_) => throw StateError('termination'))
            .drain<void>(),
        throwsA(isA<RpcUnauthorizedException>()),
      );
    });

    test('cancel token aborts mid-stream', () async {
      final controller = StreamController<List<int>>();
      client.reply(controller.stream,
          headers: {'content-type': 'text/event-stream'});
      final token = CancelToken();
      final errors = <Object>[];
      final done = Completer<void>();
      final sub = link
          .invokeStream(
              streamReq('planet.watch',
                  context: RpcCallContext(cancelToken: token)),
              (_) => throw StateError('termination'))
          .listen((_) {}, onError: errors.add, onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      token.cancel(reason: 'stop');
      await done.future.timeout(const Duration(seconds: 5));
      await sub.cancel();
      expect(errors.single, isA<RpcCancelledException>());
    });

    test('idleTimeout aborts a silent stream and reconnects via the chain',
        () async {
      final silent = StreamController<List<int>>();
      client
          .reply(silent.stream, headers: {'content-type': 'text/event-stream'});
      final active = StreamController<List<int>>();
      client
          .reply(active.stream, headers: {'content-type': 'text/event-stream'});
      final idleLink = OrpcLink(
          endpoint: Uri.parse('https://x.dev/rpc'),
          client: client,
          idleTimeout: const Duration(milliseconds: 40));
      var reconnects = 0;
      final ticket = RpcSubscriptionTicket(RpcSubscriptionOptions(
        idleTimeout: const Duration(milliseconds: 40),
        reconnectPolicy: const RpcReconnectPolicy(
            initialDelay: Duration(milliseconds: 1),
            backoffMultiplier: 1,
            jitterRatio: 0),
        onReconnect: (attempt, error) {
          reconnects++;
        },
      ));
      final chain = RpcLinkChain([idleLink]);
      final events = <Object?>[];
      final done = Completer<void>();
      final sub = chain
          .invokeStream(streamReq('planet.watch', ticket: ticket))
          .listen(events.add,
              onError: done.completeError, onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      active.add(utf8.encode(sseFrame(
          'message',
          {
            'json': {'tick': 1}
          },
          id: 'e1')));
      active.add(utf8.encode(sseFrame('done', null)));
      await done.future.timeout(const Duration(seconds: 5));
      await sub.cancel();
      await silent.close();
      expect(reconnects, 1);
      expect(client.sent.length, 2);
      expect(events.length, 1);
      expect((events.single! as Map<String, Object?>)['tick'], 1);
    });
  });

  group('middleware composition over OrpcLink', () {
    test('AuthLink refreshes once on 401 and replays the call', () async {
      var calls = 0;
      client.route((request) {
        calls++;
        if (request.headers['authorization'] == 'Bearer fresh') {
          return FakeHttpClient.streamed('{"json":{"ok":true}}');
        }
        return FakeHttpClient.streamed(
          '{"json":{"defined":false,"code":"UNAUTHORIZED","status":401,"message":"expired"}}',
          status: 401,
          headers: {'content-type': 'application/json'},
        );
      });
      client.route((request) {
        calls++;
        if (request.headers['authorization'] != 'Bearer fresh') {
          return FakeHttpClient.streamed(
            '{"json":{"defined":false,"code":"UNAUTHORIZED","status":401,"message":"expired"}}',
            status: 401,
            headers: {'content-type': 'application/json'},
          );
        }
        return FakeHttpClient.streamed('{"json":{"ok":true}}');
      });
      var refreshes = 0;
      var token = 'Bearer stale';
      final chain = RpcLinkChain([
        AuthLink(
          getHeaders: () async => {'authorization': token},
          onUnauthorized: () async {
            refreshes++;
            token = 'Bearer fresh';
            return null;
          },
        ),
        link,
      ]);
      final out = await chain.invoke(RpcRequest(
          path: 'secure.op', kind: RpcProcedureKind.mutation, input: null));
      expect(out, {'ok': true});
      expect(refreshes, 1);
      expect(calls, 2);
    });

    test('RetryLink retries 503 responses over OrpcLink', () async {
      var calls = 0;
      http.StreamedResponse unavailable() {
        calls++;
        return FakeHttpClient.streamed(
          '{"json":{"defined":false,"code":"SERVICE_UNAVAILABLE","status":503,"message":"down"}}',
          status: 503,
          headers: {'content-type': 'application/json'},
        );
      }

      client.route((_) => unavailable());
      client.route((_) => unavailable());
      client.route((_) {
        calls++;
        return FakeHttpClient.streamed('{"json":"up"}');
      });
      final chain = RpcLinkChain([
        RetryLink(
          policy: const RpcRetryPolicy(backoff: Duration(milliseconds: 1)),
        ),
        link,
      ]);
      final out = await chain.invoke(RpcRequest(
          path: 'flaky.op', kind: RpcProcedureKind.query, input: null));
      expect(out, 'up');
      expect(calls, 3);
    });
  });
}
