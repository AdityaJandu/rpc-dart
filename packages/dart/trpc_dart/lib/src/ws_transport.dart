/// Platform default WebSocket connector.
///
/// Exports [defaultWebSocketConnector]: a `dart:io` implementation where the
/// IO SDK is available, and a stub that asks for an injected connector
/// elsewhere (e.g. web builds via `package:web`).
library;

export 'ws_transport_stub.dart' if (dart.library.io) 'ws_transport_io.dart';
