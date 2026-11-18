import 'ws_subscription_link.dart';

/// Non-web platforms provide a real connector; on unsupported platforms
/// users inject [WsSubscriptionLink.connector] instead.
Future<RpcWebSocket> defaultWebSocketConnector(
  Uri uri,
  Map<String, String> headers,
) async {
  throw UnsupportedError(
    'no default WebSocket transport on this platform; '
    'pass a WsSubscriptionLink.connector',
  );
}
