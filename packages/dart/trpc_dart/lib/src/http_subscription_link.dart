import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'batch.dart' show unwrapEnvelope;
import 'codec.dart';
import 'codec/rpc_json.dart';
import 'exceptions.dart';
import 'link.dart';
import 'sse_parser.dart';

/// Terminal subscription transport over Server-Sent Events, wire-compatible
/// with tRPC v11's `httpSubscriptionLink` server producer:
///
/// - `GET <endpoint>/<path>?input=<encoded>` with `Accept: text/event-stream`.
/// - Tracks `id:` lines from `tracked(id, data)` events into the subscription
///   ticket and resumes with `Last-Event-ID` (the server also merges it into
///   `input.lastEventId`).
/// - `connected` / `ping` / `restore-id` events and `:` comments are
///   keep-alives; `serialized-error` surfaces as a typed [RpcException];
///   `return` completes the stream cleanly without reconnecting.
/// - Abrupt stream ends are network failures, retried by the chain's
///   reconnect engine.
final class HttpSubscriptionLink extends RpcLink {
  /// Creates an SSE subscription link targeting [endpoint].
  ///
  /// [idleTimeout] aborts and reconnects a stream that goes silent (half-open
  /// dead TCP connection); a per-subscription
  /// [RpcSubscriptionOptions.idleTimeout] overrides it. Null disables idle
  /// detection.
  HttpSubscriptionLink({
    required this.endpoint,
    this.transformer = RpcTransformer.superjson,
    this.idleTimeout,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Server tRPC base endpoint URI.
  final Uri endpoint;

  /// Transformer matching server configuration.
  final RpcTransformer transformer;

  /// Default SSE inactivity deadline before a stalled stream is reconnected.
  final Duration? idleTimeout;

  final http.Client _client;

  @override
  bool get isTermination => true;

  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) {
    throw StateError('subscriptions stream; use invokeStream');
  }

  @override
  Stream<Object?> invokeStream(RpcRequest request, RpcStreamLinkNext next) {
    // Controller-based, not async*: an async* generator defers cancellation
    // until its next event, so a silent server would hang sub.cancel()
    // forever. Here, onCancel aborts the response immediately.
    final ticket = request.subscription;
    final idle = ticket?.options.idleTimeout ?? idleTimeout;
    late final StreamController<Object?> out;
    StreamSubscription<SseFrame>? frames;
    Timer? idleTimer;

    void stopIdleTimer() {
      idleTimer?.cancel();
      idleTimer = null;
    }

    Future<void> abort() async {
      stopIdleTimer();
      await frames?.cancel();
    }

    out = StreamController<Object?>(
      onCancel: abort,
    );

    // A silent stream (half-open dead TCP) never errors on its own; the idle
    // deadline aborts it and surfaces a retryable timeout so the chain's
    // reconnect engine re-subscribes from the latest tracked event id.
    void armIdleTimer() {
      if (idle == null) return;
      idleTimer?.cancel();
      idleTimer = Timer(idle, () {
        unawaited(() async {
          await frames?.cancel();
          frames = null;
          if (!out.isClosed) {
            out.addError(RpcTimeoutException('sse stream idle'));
            await out.close();
          }
        }());
      });
    }

    Future<void> run() async {
      try {
        final url = _buildUrl(request);
        final headers = <String, String>{
          ...?request.context?.headers,
          'accept': 'text/event-stream',
          'cache-control': 'no-cache',
          if (ticket?.lastEventId != null)
            'last-event-id': ticket!.lastEventId!,
        };
        final httpRequest = http.Request('GET', url)..headers.addAll(headers);
        final response = await _client.send(httpRequest);
        if (response.statusCode != 200) {
          throw _statusException(response.statusCode);
        }

        final token = request.context?.cancelToken;
        if (token != null) {
          unawaited(token.whenCancelled.then((_) async {
            await abort();
            if (!out.isClosed) {
              out.addError(RpcCancelledException('cancelled mid-stream'));
              await out.close();
            }
          }));
        }

        armIdleTimer();
        frames = SseParser().parse(response.stream).listen(
          (frame) {
            if (out.isClosed) return;
            // Every frame, comment, or ping proves the connection is alive.
            armIdleTimer();
            if (frame.retry != null) {
              ticket?.retryHint = Duration(milliseconds: frame.retry!);
            }
            if (frame.event == 'return') {
              // Normal server completion: close cleanly, no reconnect.
              stopIdleTimer();
              unawaited(out.close());
              return;
            }
            if (frame.event == 'serialized-error') {
              stopIdleTimer();
              out.addError(_errorFromFrame(frame.data));
              unawaited(out.close());
              return;
            }
            // connected / ping / restore-id and bare comments are keep-alives.
            if (frame.event != null) {
              return;
            }
            if (frame.data.isEmpty) {
              return; // comment-only frame: heartbeat, no payload to decode
            }
            if (frame.id != null && frame.id!.isNotEmpty) {
              ticket?.recordEventId(frame.id!);
            }
            out.add(unwrapEnvelope(RpcJson.parse(frame.data), transformer));
          },
          onError: (Object error, StackTrace stackTrace) {
            stopIdleTimer();
            if (out.isClosed) return;
            out.addError(error, stackTrace);
          },
          onDone: () {
            stopIdleTimer();
            if (out.isClosed) return;
            // Abrupt end without a return event: network failure, retried by
            // the chain's reconnect engine.
            out
              ..addError(
                  RpcNetworkException('sse stream ended without completion'))
              ..close();
          },
        );
      } catch (error, stackTrace) {
        stopIdleTimer();
        out.addError(error, stackTrace);
        await out.close();
      }
    }

    unawaited(run());
    return out.stream;
  }

  /// Closes the underlying HTTP client.
  void close() => _client.close();

  Uri _buildUrl(RpcRequest request) {
    final base = endpoint.toString();
    final root = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final encodedPath = Uri.encodeComponent(request.path)
        .replaceAll('%2E', '.')
        .replaceAll('%2C', ',');
    final query = request.input == null
        ? ''
        : '?input=${Uri.encodeComponent(jsonEncode(_wireInput(request)))}';
    return Uri.parse('$root/$encodedPath$query');
  }

  Object? _wireInput(RpcRequest request) {
    if (request.input == null) return null;
    switch (transformer) {
      case RpcTransformer.superjson:
        return superjsonEncode(request.input);
      case RpcTransformer.json:
        return jsonEncodeTree(request.input);
    }
  }

  RpcException _errorFromFrame(String data) {
    final decoded = unwrapEnvelope(RpcJson.parse(data), transformer);
    if (decoded is Map<String, Object?>) {
      return RpcException.fromWire(decoded);
    }
    return RpcDecodeException('malformed serialized-error frame');
  }

  RpcException _statusException(int status) {
    final message = 'sse request failed with HTTP $status';
    return switch (status) {
      401 => RpcUnauthorizedException(message, httpStatus: status),
      403 => RpcForbiddenException(message, httpStatus: status),
      404 => RpcNotFoundException(message, httpStatus: status),
      429 => RpcTooManyRequestsException(message, httpStatus: status),
      502 => RpcBadGatewayException(message, httpStatus: status),
      503 => RpcServiceUnavailableException(message, httpStatus: status),
      504 => RpcGatewayTimeoutException(message, httpStatus: status),
      _ => RpcException(message,
          code: 'HTTP_$status', httpStatus: status, cause: status),
    };
  }
}
