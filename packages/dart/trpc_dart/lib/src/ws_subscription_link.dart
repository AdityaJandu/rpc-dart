import 'dart:async';
import 'dart:convert';

import 'batch.dart' show unwrapEnvelope;
import 'codec.dart';
import 'codec/rpc_json.dart';
import 'exceptions.dart';
import 'link.dart';
import 'subscription.dart';
import 'ws_transport.dart' as transport;

/// A connected WebSocket peer. Implement this to inject a transport; the
/// default uses `dart:io` where available.
abstract class RpcWebSocket {
  /// Incoming frames: JSON text strings, `PING`/`PONG` keep-alives, or
  /// binary payloads.
  Stream<Object?> get messages;

  /// Sends a frame (JSON strings are encoded by the caller).
  Future<void> send(Object? data);

  /// Closes the socket cleanly.
  Future<void> close();
}

/// Opens a WebSocket connection. Headers ride the HTTP upgrade request.
typedef RpcWebSocketConnector = Future<RpcWebSocket> Function(
  Uri uri,
  Map<String, String> headers,
);

/// Terminal subscription transport multiplexing N concurrent subscriptions
/// over a single shared WebSocket, wire-compatible with tRPC v11's
/// `applyWSSHandler`:
///
/// - start: `{"id", "jsonrpc":"2.0", "method":"subscription",
///   "params":{path, input, lastEventId?}}`
/// - stop: `{"id", "method":"subscription.stop"}` on cancellation
/// - server frames: `started`, `data` (tracked events carry
///   `result.id` + `result.data:{id, data}`), `stopped`, `error`, and the
///   `{id: null, method: "reconnect"}` notification
/// - `connectionParams` handshake when the connector URL carries
///   `connectionParams=1`; params re-resolve on every connect.
///
/// Socket drops and reconnect notifications error every active stream with
/// a retryable failure, letting the chain's reconnect engine re-subscribe
/// each one from its latest tracked event id.
final class WsSubscriptionLink extends RpcLink {
  /// Creates a WebSocket subscription link targeting [endpoint].
  WsSubscriptionLink({
    required this.endpoint,
    this.transformer = RpcTransformer.superjson,
    RpcWebSocketConnector? connector,
  }) : _connector = connector ?? transport.defaultWebSocketConnector;

  /// Server tRPC WebSocket endpoint URI.
  final Uri endpoint;

  /// Transformer matching server configuration.
  final RpcTransformer transformer;

  final RpcWebSocketConnector _connector;

  RpcWebSocket? _socket;
  Future<void>? _connecting;
  StreamSubscription<Object?>? _socketSubscription;
  final Map<int, _ActiveSubscription> _active = <int, _ActiveSubscription>{};
  int _nextId = 0;
  Map<String, Object?>? _connectionParams;

  @override
  bool get isTermination => true;

  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) {
    throw StateError('subscriptions stream; use invokeStream');
  }

  @override
  Stream<Object?> invokeStream(RpcRequest request, RpcStreamLinkNext next) {
    final ticket = request.subscription;
    if (ticket == null) {
      return Stream<Object?>.error(
        StateError('websocket streams require RpcSubscriptionOptions'),
      );
    }
    final id = _nextId++;
    late final _ActiveSubscription entry;
    entry = _ActiveSubscription(
      id,
      ticket,
      request,
      _wireInputOf(request, transformer),
      onCancel: () => _stop(id),
    );
    _active[id] = entry;
    unawaited(
      _ensureConnected(entry).then((_) {
        if (_active[id] != entry) return; // cancelled while connecting
        _sendStart(entry);
      }).catchError((Object error) {
        if (_active.remove(id) == entry) {
          entry.fail(error);
        }
      }),
    );
    return entry.controller.stream;
  }

  Future<void> _ensureConnected(_ActiveSubscription entry) {
    if (_socket != null) return Future<void>.value();
    // Share the in-flight connection so concurrent starts multiplex one
    // socket instead of racing two.
    _connecting ??= _connect(entry).whenComplete(() => _connecting = null);
    return _connecting!;
  }

  Future<void> _connect(_ActiveSubscription entry) async {
    _connectionParams = await entry.ticket.options.connectionParams?.call();
    final headers = <String, String>{...entry.ticket.options.headers};
    final socket = await _connector(_connectUri(), headers);
    _socket = socket;
    _socketSubscription = socket.messages.listen(
      _handleMessage,
      onError: (Object error) => _failAll(
        RpcNetworkException('websocket error: $error', cause: error),
      ),
      onDone: () => _failAll(RpcNetworkException('websocket closed')),
    );
  }

  Uri _connectUri() {
    final base = endpoint.toString();
    final root = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final params = _connectionParams == null
        ? <String, String>{}
        : <String, String>{'connectionParams': '1'};
    return Uri.parse(root)
        .replace(queryParameters: params.isEmpty ? null : params);
  }

  void _sendStart(_ActiveSubscription entry) {
    _sendFrame(<String, Object?>{
      'id': entry.id,
      'jsonrpc': '2.0',
      'method': 'subscription',
      'params': <String, Object?>{
        'path': entry.request.path,
        if (entry.wireInput != null) 'input': entry.wireInput,
        if (entry.ticket.lastEventId != null)
          'lastEventId': entry.ticket.lastEventId,
      },
    });
  }

  void _handleMessage(Object? message) {
    if (message is List<int>) message = utf8.decode(message);
    if (message is! String) return;
    if (message == 'PING') {
      unawaited(_socket?.send('PONG'));
      return;
    }
    if (message == 'PONG') return;

    final Object? decoded;
    try {
      decoded = RpcJson.parse(message);
    } catch (_) {
      return; // malformed frame: never corrupt subscriber streams
    }
    if (decoded is! Map<String, Object?>) return;

    if (decoded['method'] == 'reconnect') {
      _failAll(RpcNetworkException('server requested reconnect'));
      return;
    }

    final id = decoded['id'];
    if (id is! int) return;
    final entry = _active[id];
    if (entry == null) return;

    if (decoded.containsKey('error')) {
      final error = decoded['error'];
      entry.fail(error is Map<String, Object?>
          ? RpcException.fromWire(error)
          : RpcException('unknown websocket error'));
      _active.remove(id);
      return;
    }

    final result = decoded['result'];
    if (result is! Map<String, Object?>) return;
    switch (result['type']) {
      case 'started':
        break;
      case 'data':
        Object? value = unwrapEnvelope(result['data'], transformer);
        final trackedId = result['id'];
        // tRPC v11 sets result.id ONLY for tracked() events, and then
        // result.data is the {id, data} projection. A plain domain object
        // that happens to have {id, data} fields carries no result.id, so it
        // is emitted intact instead of being mistaken for an envelope.
        if (trackedId is String && trackedId.isNotEmpty) {
          entry.ticket.recordEventId(trackedId);
          if (value is Map<String, Object?> && value.containsKey('data')) {
            value = value['data'];
          }
        }
        entry.controller.add(value);
      case 'stopped':
        _active.remove(id);
        entry.controller.close();
    }
  }

  void _failAll(Object error) {
    final failing = List<_ActiveSubscription>.of(_active.values);
    _active.clear();
    _closeSocket();
    for (final entry in failing) {
      entry.fail(error);
    }
  }

  void _sendFrame(Map<String, Object?> frame) {
    unawaited(_socket?.send(jsonEncode(frame)));
  }

  void _stop(int id) {
    final entry = _active.remove(id);
    if (entry == null) return;
    if (_socket != null) {
      _sendFrame(<String, Object?>{
        'id': id,
        'jsonrpc': '2.0',
        'method': 'subscription.stop',
      });
    }
    if (_active.isEmpty) {
      // Idle disconnect: nothing is listening anymore.
      _closeSocket();
    }
  }

  void _closeSocket() {
    _socketSubscription?.cancel();
    _socketSubscription = null;
    unawaited(_socket?.close());
    _socket = null;
  }

  /// Force-closes the shared connection and errors every active stream.
  void close() {
    _failAll(RpcCancelledException('websocket link closed'));
  }
}

Object? _wireInputOf(RpcRequest request, RpcTransformer transformer) {
  if (request.input == null) {
    // The server deserializes input through the transformer even for
    // no-input procedures: superjson expects an (empty) envelope, matching
    // what tRPC's own wsLink sends.
    switch (transformer) {
      case RpcTransformer.superjson:
        return <String, Object?>{};
      case RpcTransformer.json:
        return null;
    }
  }
  switch (transformer) {
    case RpcTransformer.superjson:
      return superjsonEncode(request.input);
    case RpcTransformer.json:
      return jsonEncodeTree(request.input);
  }
}

final class _ActiveSubscription {
  _ActiveSubscription(
    this.id,
    this.ticket,
    this.request,
    this.wireInput, {
    required void Function() onCancel,
  }) : controller = StreamController<Object?>(onCancel: onCancel);

  final int id;
  final RpcSubscriptionTicket ticket;
  final RpcRequest request;
  final Object? wireInput;
  final StreamController<Object?> controller;

  void fail(Object error) {
    if (!controller.isClosed) {
      controller
        ..addError(error)
        ..close();
    }
  }
}
