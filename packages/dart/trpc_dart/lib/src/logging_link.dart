import 'link.dart';

/// One structured log event: 'request', 'response', or 'error'.
class RpcLogEvent {
  const RpcLogEvent({
    required this.event,
    required this.path,
    required this.kind,
    required this.headers,
    required this.durationMs,
    this.error,
  });

  final String event;
  final String path;
  final String kind;
  final Map<String, String> headers;
  final int durationMs;
  final Object? error;

  @override
  String toString() =>
      'RpcLogEvent($event, path: $path, kind: $kind, durationMs: $durationMs, '
      'headers: $headers, error: $error)';
}

/// Structured request/response/error logging with automatic secret
/// redaction: `authorization`, `cookie`, `set-cookie`, `x-api-key`, and
/// user-configured names are replaced with `[REDACTED]` before any sink runs
///.
class LoggingLink extends RpcLink {
  LoggingLink({
    required this.onEvent,
    this.redactHeaders = const {},
  });

  final void Function(RpcLogEvent event) onEvent;

  /// Additional case-insensitive header names to redact.
  final Set<String> redactHeaders;

  static const Set<String> _alwaysRedacted = <String>{
    'authorization',
    'cookie',
    'set-cookie',
    'x-api-key',
    'x-refresh-token',
  };

  bool _isSecret(String name) {
    final lower = name.toLowerCase();
    return _alwaysRedacted.contains(lower) ||
        redactHeaders.any((candidate) => candidate.toLowerCase() == lower);
  }

  Map<String, String> _redact(Map<String, String>? headers) {
    final out = <String, String>{};
    headers?.forEach((name, value) {
      out[name] = _isSecret(name) ? '[REDACTED]' : value;
    });
    return out;
  }

  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) async {
    final stopwatch = Stopwatch()..start();
    onEvent(RpcLogEvent(
      event: 'request',
      path: request.path,
      kind: request.kind.name,
      headers: _redact(request.context?.headers),
      durationMs: 0,
    ));
    try {
      final result = await next(request);
      stopwatch.stop();
      onEvent(RpcLogEvent(
        event: 'response',
        path: request.path,
        kind: request.kind.name,
        headers: _redact(request.context?.headers),
        durationMs: stopwatch.elapsedMilliseconds,
      ));
      return result;
    } catch (error) {
      stopwatch.stop();
      onEvent(RpcLogEvent(
        event: 'error',
        path: request.path,
        kind: request.kind.name,
        headers: _redact(request.context?.headers),
        durationMs: stopwatch.elapsedMilliseconds,
        error: error,
      ));
      rethrow;
    }
  }
}
