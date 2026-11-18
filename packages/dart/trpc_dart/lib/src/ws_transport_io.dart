import 'dart:async';
import 'dart:io' as io;

import 'ws_subscription_link.dart';

/// `dart:io`-backed default WebSocket connector.
Future<RpcWebSocket> defaultWebSocketConnector(
  Uri uri,
  Map<String, String> headers,
) async {
  final socket = await io.WebSocket.connect(
    uri.toString(),
    headers: headers,
  );
  return _IoWebSocket(socket);
}

final class _IoWebSocket implements RpcWebSocket {
  _IoWebSocket(this._socket);

  final io.WebSocket _socket;

  @override
  Stream<Object?> get messages =>
      _socket.map<Object?>((message) => message as Object?);

  @override
  Future<void> send(Object? data) {
    _socket.add(data);
    return Future<void>.value();
  }

  @override
  Future<void> close() => _socket.close();
}
