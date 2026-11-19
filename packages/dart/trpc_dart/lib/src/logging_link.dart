import 'dart:async';
import 'dart:typed_data';

import 'binary.dart';
import 'link.dart';

/// Renders a payload as a bounded log-safe string: binary nodes become
/// size summaries (`<RpcFile: a.png, 2048 bytes, image/png>`, `<1024 bytes>`,
/// `<byte stream>`) so megabyte payloads never reach a log sink.
String rpcSummarizePayload(Object? value) {
  if (value is RpcFile) {
    return '<RpcFile: ${value.filename}, ${value.length ?? '?'} bytes, '
        '${value.contentType ?? 'unknown'}>';
  }
  if (value is Uint8List) return '<${value.length} bytes>';
  if (value is Stream) return '<byte stream>';
  if (value is Map<Object?, Object?>) {
    final entries = value.entries
        .map((e) => '${e.key}: ${rpcSummarizePayload(e.value)}')
        .join(', ');
    return '{$entries}';
  }
  if (value is List<Object?>) {
    return '[${value.map(rpcSummarizePayload).join(', ')}]';
  }
  if (value is String && value.length > 2048) {
    return '${value.substring(0, 2048)}…<truncated, ${value.length} chars total>';
  }
  return '$value';
}

/// One structured log event: 'request', 'response', or 'error'.
class RpcLogEvent {
  /// Creates a structured RPC log event.
  const RpcLogEvent({
    required this.event,
    required this.path,
    required this.kind,
    required this.headers,
    required this.durationMs,
    this.error,
    this.payloadSummary,
  });

  /// Event type string: `'request'`, `'response'`, or `'error'`.
  final String event;

  /// Dotted procedure path.
  final String path;

  /// The procedure kind (`'query'`, `'mutation'`, `'subscription'`).
  final String kind;

  /// Sanitized request headers with secrets redacted.
  final Map<String, String> headers;

  /// Operation duration in milliseconds (0 for request start).
  final int durationMs;

  /// Optional error object when event is `'error'`.
  final Object? error;

  /// Bounded payload summary when [LoggingLink.logPayloads] is enabled.
  final String? payloadSummary;

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
  /// Creates a logging link that passes structured events to [onEvent].
  LoggingLink({
    required this.onEvent,
    this.redactHeaders = const {},
    this.logPayloads = false,
  });

  /// Callback invoked on request, response, and error events.
  final void Function(RpcLogEvent event) onEvent;

  /// Additional case-insensitive header names to redact.
  final Set<String> redactHeaders;

  /// Opt-in payload summaries on request/response events; binary nodes are
  /// always reduced to size summaries, never raw bytes.
  final bool logPayloads;

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

  /// Logs request dispatch, timing, and response or error events.
  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) async {
    final stopwatch = Stopwatch()..start();
    onEvent(RpcLogEvent(
      event: 'request',
      path: request.path,
      kind: request.kind.name,
      headers: _redact(request.context?.headers),
      durationMs: 0,
      payloadSummary: logPayloads ? rpcSummarizePayload(request.input) : null,
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
        payloadSummary: logPayloads ? rpcSummarizePayload(result) : null,
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

  /// Stream counterpart: logs `request` on connect, `response` on clean
  /// completion, and `error` on stream failure. Reconnect attempts surface
  /// as fresh request events because the reconnect engine re-runs the chain
  /// per attempt. Controller-based so user cancellation aborts downstream
  /// immediately.
  @override
  Stream<Object?> invokeStream(RpcRequest request, RpcStreamLinkNext next) {
    final stopwatch = Stopwatch()..start();
    onEvent(RpcLogEvent(
      event: 'request',
      path: request.path,
      kind: request.kind.name,
      headers: _redact(request.context?.headers),
      durationMs: 0,
    ));
    late final StreamController<Object?> controller;
    late final StreamSubscription<Object?> downstream;
    var failed = false;
    controller = StreamController<Object?>(
      onCancel: () => downstream.cancel(),
    );
    downstream = next(request).listen(
      controller.add,
      onError: (Object error, StackTrace stackTrace) {
        failed = true;
        stopwatch.stop();
        onEvent(RpcLogEvent(
          event: 'error',
          path: request.path,
          kind: request.kind.name,
          headers: _redact(request.context?.headers),
          durationMs: stopwatch.elapsedMilliseconds,
          error: error,
        ));
        controller.addError(error, stackTrace);
      },
      onDone: () {
        stopwatch.stop();
        if (!failed) {
          onEvent(RpcLogEvent(
            event: 'response',
            path: request.path,
            kind: request.kind.name,
            headers: _redact(request.context?.headers),
            durationMs: stopwatch.elapsedMilliseconds,
          ));
        }
        controller.close();
      },
    );
    return controller.stream;
  }
}
