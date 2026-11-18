import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:trpc_dart/src/codec.dart';
import 'package:trpc_dart/src/exceptions.dart';
import 'package:trpc_dart/src/link.dart';
import 'package:trpc_dart/src/subscription.dart';
import 'package:trpc_dart/src/ws_subscription_link.dart';

void main() {
  group('WsSubscriptionLink', () {
    late _FakeWebSocketServer server;
    late WsSubscriptionLink link;

    setUp(() {
      server = _FakeWebSocketServer();
      link = WsSubscriptionLink(
        endpoint: Uri.parse('ws://localhost:8788/trpc'),
        connector: server.connector,
      );
    });

    RpcRequest sub(String path, {Map<String, Object?>? input}) {
      return RpcRequest(
        path: path,
        kind: RpcProcedureKind.subscription,
        input: input,
        subscription: RpcSubscriptionTicket(const RpcSubscriptionOptions()),
      );
    }

    test('multiplexes 3 subscriptions over one connection without cross-talk',
        () async {
      final a = await _collect(link.invokeStream(sub('s.a'), _noNext));
      final b = await _collect(link.invokeStream(sub('s.b'), _noNext));
      final c = await _collect(link.invokeStream(sub('s.c'), _noNext));

      await server.connected.future;
      await _pump();
      expect(server.sockets.length, 1); // single shared connection
      expect(server.sockets.single.sent, hasLength(3));

      // Route each started/data frame by id and check isolation.
      final ids = server.startIds();
      expect(ids.length, 3);
      server.sendData(ids[0], {'which': 'a'});
      server.sendData(ids[1], {'which': 'b'});
      server.sendData(ids[2], {'which': 'c'});
      server.sendStopped(ids[0]);
      server.sendStopped(ids[1]);
      server.sendStopped(ids[2]);

      expect(await a.future, [
        <String, Object?>{'which': 'a'}
      ]);
      expect(await b.future, [
        <String, Object?>{'which': 'b'}
      ]);
      expect(await c.future, [
        <String, Object?>{'which': 'c'}
      ]);
    });

    test('cancelling one of three sends subscription.stop and keeps the rest',
        () async {
      final a = await _collect(link.invokeStream(sub('s.a'), _noNext));
      final b = await _collect(link.invokeStream(sub('s.b'), _noNext));
      await _collect(link.invokeStream(sub('s.c'), _noNext));

      await server.connected.future;
      final ids = server.startIds();
      final stopsBefore = server.stopCount();

      await a.cancel();

      expect(server.stopCount(), stopsBefore + 1);
      expect(server.stopIds(), contains(ids[0]));

      server.sendData(ids[1], 'still-alive');
      server.sendStopped(ids[1]);
      server.sendStopped(ids[2]);
      expect(await b.future, ['still-alive']);
    });

    test('server reconnect notification re-subscribes with latest lastEventId',
        () async {
      var connectionParamsCalls = 0;
      final client = RpcClient(
        endpoint: Uri.parse('ws://localhost:8788/trpc'),
        links: [
          WsSubscriptionLink(
            endpoint: Uri.parse('ws://localhost:8788/trpc'),
            connector: server.connector,
          ),
        ],
        transformer: RpcTransformer.json,
      );

      final events = <String>[];
      final done = Completer<void>();
      final subscription = client
          .subscribe<String>(
            path: 'streams.onActivity',
            input: null,
            decode: (value) => value as String,
            options: RpcSubscriptionOptions(
              reconnectPolicy: const RpcReconnectPolicy(
                maxAttempts: 5,
                initialDelay: Duration(milliseconds: 1),
              ),
              onEventId: (id) {},
              connectionParams: () async {
                connectionParamsCalls++;
                return <String, Object?>{'token': 'p$connectionParamsCalls'};
              },
            ),
          )
          .listen(events.add, onDone: done.complete);

      await server.connected.future;
      await _pump();
      final firstId = server.startIds().single;
      server.sendData(firstId, 'one', trackedId: 'evt-1');
      server.sendData(firstId, 'two', trackedId: 'evt-2');
      await _pump();

      // Server asks everyone to reconnect (e.g. before a deploy).
      server.sendReconnect();
      await _pump();

      await server.connected.future;
      final secondId = server.startIds().last;
      // Re-subscribe frame must resume from the latest tracked id.
      final startFrame = server.lastStartFrame!;
      expect(
        (startFrame['params'] as Map<String, Object?>)['lastEventId'],
        'evt-2',
      );
      server.sendData(secondId, 'three', trackedId: 'evt-3');
      server.sendStopped(secondId);

      await done.future;
      await subscription.cancel();
      expect(events, ['one', 'two', 'three']);
      expect(startFrame['method'], 'subscription');
    });

    test('server stopped frame closes the stream without reconnecting',
        () async {
      final events = <Object?>[];
      final done = Completer<void>();
      final subscription = link
          .invokeStream(sub('s.done'), _noNext)
          .listen(events.add, onDone: done.complete);

      await server.connected.future;
      await _pump();
      final id = server.startIds().single;
      server.sendData(id, 'last');
      server.sendStopped(id);

      await done.future;
      expect(events, ['last']);
      // A clean stop must not error or re-subscribe.
      expect(server.stopCount(), 0);
      await subscription.cancel();
    });

    test('socket drop errors active streams so the engine can reconnect',
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
      final a = await _collect(link.invokeStream(request, _noNext));
      await server.connected.future;
      await _pump();
      final id = server.startIds().single;
      server.sendData(id, 'before-drop', trackedId: 't1');
      await _pump();

      await server.sockets.single.closeAbruptly();
      await _pump();

      // The stream errors (retryable), and the ticket kept the event id.
      expect(a.errors, isNotEmpty);
      expect(a.errors.first, isA<RpcNetworkException>());
      expect(ticket.lastEventId, 't1');
      await a.cancel();
    });

    test(
        'unwraps tracked() envelopes but never corrupts a domain {id, data} '
        'object', () async {
      final ticket = RpcSubscriptionTicket(const RpcSubscriptionOptions());
      final request = RpcRequest(
        path: 'streams.domain',
        kind: RpcProcedureKind.subscription,
        input: null,
        subscription: ticket,
      );
      final collected = await _collect(link.invokeStream(request, _noNext));
      await server.connected.future;
      await _pump();
      final id = server.startIds().single;

      // tracked('evt-1', 'payload'): result.id is set, result.data is the
      // {id, data} projection -> emit the inner payload.
      server.sendData(id, 'payload', trackedId: 'evt-1');
      // A normal procedure returning a domain object that happens to have
      // {id, data} fields, WITHOUT tracked(): no result.id, so it must arrive
      // intact and must not be mistaken for a tracked envelope.
      server.sendData(id, <String, Object?>{'id': 'u1', 'data': 'value'});
      server.sendStopped(id);

      expect(await collected.future, [
        'payload',
        <String, Object?>{'id': 'u1', 'data': 'value'},
      ]);
      // Only the tracked event advances the resume point.
      expect(ticket.lastEventId, 'evt-1');
      await collected.cancel();
    });

    test('cancelling the last subscription closes the shared socket', () async {
      final a = await _collect(link.invokeStream(sub('s.a'), _noNext));
      await server.connected.future;
      await _pump();
      expect(server.sockets.single.isOpen, isTrue);

      await a.cancel();
      await _pump();

      expect(server.stopCount(), 1);
      expect(server.sockets.single.closed, isTrue);
    });

    test('close() errors every active stream and tears down the socket',
        () async {
      final a = await _collect(link.invokeStream(sub('s.a'), _noNext));
      final b = await _collect(link.invokeStream(sub('s.b'), _noNext));
      await server.connected.future;
      await _pump();

      link.close();
      await _pump();

      expect(a.errors, isNotEmpty);
      expect(b.errors, isNotEmpty);
      expect(a.errors.first, isA<RpcCancelledException>());
      expect(server.sockets.single.closed, isTrue);
      await a.cancel();
      await b.cancel();
    });
  });
}

Stream<Object?> _noNext(RpcRequest request) {
  throw StateError('termination link must not call next');
}

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 5));

class _Collected {
  _Collected(this.stream)
      : done = Completer<void>(),
        events = <Object?>[],
        errors = <Object?>[] {
    subscription = stream.listen(
      events.add,
      onError: errors.add,
      onDone: done.complete,
    );
  }

  final Stream<Object?> stream;
  late final StreamSubscription<Object?> subscription;
  final Completer<void> done;
  final List<Object?> events;
  final List<Object?> errors;

  Future<void> cancel() => subscription.cancel();
  Future<List<Object?>> get future => done.future.then((_) => events);
}

Future<_Collected> _collect(Stream<Object?> stream) async {
  final collected = _Collected(stream);
  await _pump();
  return collected;
}

class _FakeWebSocketServer {
  final List<_FakeWebSocket> sockets = <_FakeWebSocket>[];
  final Completer<void> connected = Completer<void>();

  Future<RpcWebSocket> connector(Uri uri, Map<String, String> headers) async {
    final socket = _FakeWebSocket(this);
    sockets.add(socket);
    if (!connected.isCompleted) connected.complete();
    return socket;
  }

  List<int> startIds() {
    final ids = <int>[];
    for (final socket in sockets) {
      for (final frame in socket.sent) {
        if (frame is Map<String, Object?> &&
            frame['method'] == 'subscription') {
          ids.add(frame['id']! as int);
        }
      }
    }
    return ids;
  }

  Map<String, Object?>? get lastStartFrame {
    for (final socket in sockets.reversed) {
      for (final frame in socket.sent.reversed) {
        if (frame is Map<String, Object?> &&
            frame['method'] == 'subscription') {
          return frame;
        }
      }
    }
    return null;
  }

  int stopCount() => sockets.fold<int>(
      0,
      (total, socket) =>
          total +
          socket.sent
              .where((frame) =>
                  frame is Map<String, Object?> &&
                  frame['method'] == 'subscription.stop')
              .length);

  List<Object?> stopIds() {
    final ids = <Object?>[];
    for (final socket in sockets) {
      for (final frame in socket.sent) {
        if (frame is Map<String, Object?> &&
            frame['method'] == 'subscription.stop') {
          ids.add(frame['id']);
        }
      }
    }
    return ids;
  }

  void sendData(int id, Object? data, {String? trackedId}) {
    final payload = <String, Object?>{
      'id': id,
      'jsonrpc': '2.0',
      'result': <String, Object?>{
        'type': 'data',
        if (trackedId != null) 'id': trackedId,
        'data': trackedId == null
            ? data
            : <String, Object?>{'id': trackedId, 'data': data},
      },
    };
    for (final socket in sockets.where((s) => s.isOpen)) {
      socket.emit(payload);
    }
  }

  void sendStopped(int id) {
    for (final socket in sockets.where((s) => s.isOpen)) {
      socket.emit(<String, Object?>{
        'id': id,
        'jsonrpc': '2.0',
        'result': <String, Object?>{'type': 'stopped'},
      });
    }
  }

  void sendReconnect() {
    for (final socket in sockets.where((s) => s.isOpen)) {
      socket.emit(<String, Object?>{'id': null, 'method': 'reconnect'});
    }
  }
}

class _FakeWebSocket implements RpcWebSocket {
  _FakeWebSocket(this.server);

  final _FakeWebSocketServer server;
  final StreamController<Object?> _incoming =
      StreamController<Object?>.broadcast();
  final List<Object?> sent = <Object?>[];
  bool closed = false;

  bool get isOpen => !closed && !_incoming.isClosed;

  @override
  Stream<Object?> get messages => _incoming.stream;

  void emit(Object? frame) {
    _incoming.add(jsonEncode(frame));
  }

  Future<void> closeAbruptly() async {
    _incoming.addError(RpcNetworkException('socket dropped'));
    await _incoming.close();
  }

  @override
  Future<void> close() async {
    closed = true;
    await _incoming.close();
  }

  @override
  Future<void> send(Object? data) async {
    sent.add(data is String ? jsonDecode(data) : data);
  }
}
