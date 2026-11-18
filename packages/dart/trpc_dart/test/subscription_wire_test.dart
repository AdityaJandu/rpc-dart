// Wire conformance tests against the real Fastify example server
// (SSE + WebSocket subscriptions). Driven by tests/e2e/test/subscription-wire.test.ts
// via RPC_EXAMPLE_PORT; skipped when the variable is absent.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:trpc_dart/trpc_dart.dart';

void main() {
  final portText = Platform.environment['RPC_EXAMPLE_PORT'];
  if (portText == null) {
    return; // not driven by the e2e harness
  }
  final port = int.parse(portText);
  final httpEndpoint = Uri.parse('http://127.0.0.1:$port/trpc');
  final wsEndpoint = Uri.parse('ws://127.0.0.1:$port/trpc');
  const authHeaders = {'authorization': 'Bearer demo-token'};

  /// One shared WebSocket connection counter + sent-frame log.
  var socketCount = 0;
  final sentFrames = <Map<String, Object?>>[];

  RpcClient sseClient() => RpcClient(
        endpoint: httpEndpoint,
        links: [
          SplitLink(
            unaryLink: HttpBatchLink(endpoint: httpEndpoint),
            subscriptionLink: HttpSubscriptionLink(endpoint: httpEndpoint),
          ),
        ],
      );

  RpcClient wsClient() => RpcClient(
        endpoint: httpEndpoint,
        links: [
          SplitLink(
            unaryLink: HttpBatchLink(endpoint: httpEndpoint),
            subscriptionLink: WsSubscriptionLink(
              endpoint: wsEndpoint,
              transformer: RpcTransformer.superjson,
              connector: (uri, headers) async {
                socketCount++;
                final socket =
                    await WebSocket.connect(uri.toString(), headers: headers);
                return _LoggingWebSocket(socket, sentFrames);
              },
            ),
          ),
        ],
      );

  /// Pushes an activity event and returns its server-assigned id.
  Future<String> pushActivity(String message) async {
    final response = await http.post(
      httpEndpoint.replace(path: '${httpEndpoint.path}/streams.pushActivity'),
      headers: {
        ...authHeaders,
        'content-type': 'application/json',
      },
      body: jsonEncode(superjsonEncode(<String, Object?>{'message': message})),
    );
    expect(response.statusCode, 200);
    final body = jsonDecode(response.body) as Map<String, Object?>;
    final data = body['result']! as Map<String, Object?>;
    final envelope = data['data']! as Map<String, Object?>;
    final event = envelope.containsKey('json')
        ? envelope['json']! as Map<String, Object?>
        : envelope;
    return event['id']! as String;
  }

  test(
      '5.1: real SSE subscription streams DateTime + BigInt in order and cancels cleanly',
      () async {
    final client = sseClient();

    final ticks = await client
        .subscribe<Map<String, Object?>>(
          path: 'streams.onServerTick',
          input: null,
          decode: (value) => value! as Map<String, Object?>,
        )
        .take(3)
        .toList();

    expect(ticks, hasLength(3));
    expect(ticks[0]['timestamp'], isA<DateTime>());
    expect(ticks[0]['memoryBytes'], isA<BigInt>());
    final tickOf = (Map<String, Object?> t) => (t['tick'] as num).toInt();
    expect(tickOf(ticks[1]), greaterThan(tickOf(ticks[0])));
    expect(tickOf(ticks[2]), greaterThan(tickOf(ticks[1])));

    // Clean cancellation: the stream closes promptly after cancel.
    final sub = client
        .subscribe<Map<String, Object?>>(
          path: 'streams.onServerTick',
          input: null,
          decode: (value) => value! as Map<String, Object?>,
        )
        .listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final start = DateTime.now();
    await sub.cancel();
    expect(
      DateTime.now().difference(start).inMilliseconds,
      lessThan(2000),
    );
  });

  test(
      '5.2: real SSE tracked() resume replays missed events without duplicates',
      () async {
    final client = sseClient();
    final marker = DateTime.now().microsecondsSinceEpoch.toString();

    await pushActivity('before-subscribe-$marker');
    final seed2Id = await pushActivity('seed-2-$marker');
    final seed3Id = await pushActivity('seed-3-$marker');

    String messageOf(Object? event) =>
        (event! as Map<String, Object?>)['message']! as String;
    final firstIds = <String>[];
    final firstMessages = <String>[];
    final firstSub = client
        .subscribe<String>(
          path: 'streams.onActivityFeed',
          input: <String, Object?>{'lastEventId': null, 'limit': 2},
          decode: messageOf,
          options: RpcSubscriptionOptions(onEventId: firstIds.add),
        )
        .listen(firstMessages.add);

    // Replay (limit 2) should deliver the two most recent seeded events.
    await Future<void>.delayed(const Duration(seconds: 2));
    await firstSub.cancel();

    expect(firstIds, [seed2Id, seed3Id],
        reason: 'limit 2 replays the newest two events');
    expect(firstMessages.join('|'), contains('seed-3-$marker'));

    // Disconnect, push more activity, then resume from the last seen id.
    await pushActivity('after-reconnect-$marker');

    final resumedIds = <String>[];
    final resumedMessages = <String>[];
    final resumedSub = client
        .subscribe<String>(
          path: 'streams.onActivityFeed',
          input: null,
          decode: messageOf,
          options: RpcSubscriptionOptions(
            lastEventId: seed3Id,
            onEventId: resumedIds.add,
          ),
        )
        .listen(resumedMessages.add);

    await Future<void>.delayed(const Duration(seconds: 2));
    await resumedSub.cancel();

    expect(resumedIds, isNotEmpty);
    expect(resumedIds, isNot(contains(seed2Id)));
    expect(resumedMessages.join('|'), contains('after-reconnect-$marker'));
  });

  test(
      '5.3: real WebSocket multiplexes two streams over one socket and stops cleanly',
      () async {
    final client = wsClient();
    final tickEvents = <int>[];
    final activityEvents = <String>[];
    final activityDone = Completer<void>();
    final tickDone = Completer<void>();

    final tickSub = client
        .subscribe<Map<String, Object?>>(
      path: 'streams.onServerTick',
      input: null,
      decode: (value) => value! as Map<String, Object?>,
    )
        .listen((event) {
      tickEvents.add((event['tick'] as num).toInt());
      if (tickEvents.length >= 2 && !tickDone.isCompleted) {
        tickDone.complete();
      }
    });

    final activitySub = client
        .subscribe<String>(
          path: 'streams.onActivityFeed',
          input: <String, Object?>{'lastEventId': null},
          decode: (value) =>
              (value! as Map<String, Object?>)['message']! as String,
        )
        .listen(activityEvents.add, onDone: activityDone.complete);

    // Let both subscriptions start over the single socket.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(socketCount, 1,
        reason: 'both subscriptions multiplex one WebSocket connection');

    // A mutation pushes a live activity event to the WS stream.
    await pushActivity('live-over-ws-${DateTime.now().microsecondsSinceEpoch}');
    await tickDone.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(activityEvents, isNotEmpty,
        reason: 'activity feed received the pushed event over WebSocket');

    // Cancelling both sends subscription.stop frames.
    await tickSub.cancel();
    await activitySub.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final stopFrames = sentFrames
        .where((frame) => frame['method'] == 'subscription.stop')
        .toList();
    expect(stopFrames, hasLength(2));
    final startedFrames =
        sentFrames.where((frame) => frame['method'] == 'subscription').toList();
    expect(startedFrames, hasLength(2));
  });
}

class _LoggingWebSocket implements RpcWebSocket {
  _LoggingWebSocket(this._socket, this.sent);

  final WebSocket _socket;
  final List<Map<String, Object?>> sent;

  @override
  Stream<Object?> get messages =>
      _socket.map<Object?>((message) => message as Object?);

  @override
  Future<void> send(Object? data) {
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, Object?>) sent.add(decoded);
      } catch (_) {
        // keep-alive text frames are not JSON
      }
    }
    _socket.add(data);
    return Future<void>.value();
  }

  @override
  Future<void> close() => _socket.close();
}
