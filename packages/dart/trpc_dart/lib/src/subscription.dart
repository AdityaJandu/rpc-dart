import 'dart:async';
import 'dart:math' as math;

import 'exceptions.dart';
import 'link.dart' show CancelToken;

/// Per-subscription configuration: resume point, cancellation, credentials,
/// reconnect behavior, and tracked-event callbacks.
class RpcSubscriptionOptions {
  /// Creates subscription options.
  const RpcSubscriptionOptions({
    this.lastEventId,
    this.cancelToken,
    this.headers = const <String, String>{},
    this.context,
    this.reconnectPolicy = const RpcReconnectPolicy(),
    this.onEventId,
    this.connectionParams,
    this.idleTimeout,
    this.onReconnect,
  });

  /// Initial event id to resume from (replays missed events server-side).
  final String? lastEventId;

  /// Token cancelling the stream and any pending reconnect.
  final CancelToken? cancelToken;

  /// Extra headers attached to the subscription request.
  final Map<String, String> headers;

  /// Arbitrary per-subscription context metadata.
  final Map<String, Object?>? context;

  /// Reconnect behavior on retryable failures; per-subscription override of
  /// the transport link's default.
  final RpcReconnectPolicy reconnectPolicy;

  /// Invoked whenever a tracked event id arrives (latest resume point).
  final void Function(String eventId)? onEventId;

  /// WebSocket connection params, re-resolved on every connect/reconnect and
  /// sent as the server's connectionParams handshake.
  final FutureOr<Map<String, Object?>?> Function()? connectionParams;

  /// SSE inactivity deadline: when no frame, comment, or ping arrives within
  /// this window the stalled stream is aborted and reconnected. Overrides the
  /// transport link's default; null disables idle detection.
  final Duration? idleTimeout;

  /// Invoked when a retryable drop schedules a reconnect attempt (1-based
  /// `attempt`) with the triggering `error`, before the backoff delay. Lets UI
  /// bindings surface a `reconnecting` state while the chain re-subscribes.
  final void Function(int attempt, Object? error)? onReconnect;
}

/// Exponential backoff with jitter for subscription reconnection.
class RpcReconnectPolicy {
  /// Creates a reconnect policy.
  ///
  /// [maxAttempts] caps consecutive failures without progress; [initialDelay]
  /// grows by [backoffMultiplier] up to [maxDelay], dithered by
  /// [jitterRatio] (fraction of the delay, both directions). Pass [random]
  /// for deterministic tests.
  const RpcReconnectPolicy({
    this.maxAttempts = 5,
    this.initialDelay = const Duration(milliseconds: 250),
    this.maxDelay = const Duration(seconds: 30),
    this.backoffMultiplier = 2.0,
    this.jitterRatio = 0.1,
    math.Random? random,
  }) : _random = random;

  /// Maximum consecutive retryable failures before surfacing the error.
  final int maxAttempts;

  /// Delay before the first reconnect.
  final Duration initialDelay;

  /// Upper bound on the computed delay.
  final Duration maxDelay;

  /// Multiplier applied per consecutive attempt.
  final double backoffMultiplier;

  /// Fraction of the delay used as uniform jitter (0 disables).
  final double jitterRatio;

  final math.Random? _random;

  /// Whether a reconnect should be attempted after [attempt] failures
  /// (1-based).
  bool shouldRetry(int attempt) => attempt <= maxAttempts;

  /// Backoff duration before the reconnect following [attempt] failures.
  Duration delayFor(int attempt) {
    final exponential =
        initialDelay.inMilliseconds * math.pow(backoffMultiplier, attempt - 1);
    final capped =
        math.min(exponential.toDouble(), maxDelay.inMilliseconds.toDouble());
    final jitter = jitterRatio <= 0
        ? 0.0
        : capped * jitterRatio * ((_random?.nextDouble() ?? 0.5) * 2 - 1);
    return Duration(milliseconds: (capped + jitter).round());
  }
}

/// Mutable per-subscription state shared across the link chain: the latest
/// tracked event id survives reconnects and auth refreshes, so every
/// re-subscribe resumes exactly where the stream left off.
class RpcSubscriptionTicket {
  /// Creates a ticket carrying [options]; seeds the resume point from
  /// [RpcSubscriptionOptions.lastEventId].
  RpcSubscriptionTicket(this.options) {
    lastEventId = options.lastEventId;
  }

  /// User-provided subscription options.
  final RpcSubscriptionOptions options;

  /// Latest tracked event id received, used to resume after reconnects.
  String? lastEventId;

  /// Server-sent SSE `retry:` hint; floors the next reconnect delay so the
  /// client honors the server's requested reconnection interval.
  Duration? retryHint;

  /// Records a tracked event id and notifies [RpcSubscriptionOptions.onEventId].
  void recordEventId(String eventId) {
    if (eventId.isEmpty) return;
    lastEventId = eventId;
    options.onEventId?.call(eventId);
  }
}

/// Whether the reconnect engine should retry [error]. Client cancellation,
/// clean completions, and 4xx-class failures are terminal; network drops,
/// timeouts, and 5xx responses reconnect.
bool isRetryableStreamError(Object error) {
  if (error is RpcCancelledException) return false;
  if (error is RpcNetworkException || error is RpcTimeoutException) {
    return true;
  }
  if (error is RpcException) {
    return (error.httpStatus ?? 0) >= 500;
  }
  return true;
}
