import 'dart:async';

import 'exceptions.dart';
import 'link.dart';

/// Retry policy: attempts, backoff, and the retryable-error predicate.
class RpcRetryPolicy {
  const RpcRetryPolicy({
    this.maxAttempts = 3,
    this.backoff = const Duration(milliseconds: 200),
    this.maxBackoff = const Duration(seconds: 10),
    this.retryable,
  });

  final int maxAttempts;
  final Duration backoff;
  final Duration maxBackoff;

  /// Overrides the default eligibility rules when provided.
  final bool Function(RpcException error)? retryable;
}

/// Policy-driven retries with a strict mutation-safety rule: queries retry
/// automatically when the error is eligible; mutations NEVER retry unless the
/// call carries an idempotency key or an explicit `retryable: true`
///.
class RetryLink extends RpcLink {
  RetryLink({this.policy = const RpcRetryPolicy(), this.sleep = defaultSleep});

  final RpcRetryPolicy policy;

  /// Injectable delay so tests never actually sleep.
  final Future<void> Function(Duration delay) sleep;

  static Future<void> defaultSleep(Duration delay) => Future<void>.delayed(delay);

  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) async {
    final maxAttempts = policy.maxAttempts < 1 ? 1 : policy.maxAttempts;
    var attempt = 0;
    while (true) {
      attempt += 1;
      try {
        return await next(request);
      } on RpcException catch (error) {
        final canRetry = attempt < maxAttempts && _isRetryable(error, request);
        if (!canRetry) {
          rethrow;
        }
        var delay = policy.backoff * (1 << (attempt - 1));
        if (delay > policy.maxBackoff) {
          delay = policy.maxBackoff;
        }
        await sleep(delay);
      }
    }
  }

  bool _isRetryable(RpcException error, RpcRequest request) {
    final custom = policy.retryable;
    if (custom != null) {
      return custom(error);
    }
    if (request.kind == RpcProcedureKind.mutation) {
      final key = request.context?.idempotencyKey;
      final marked = request.context?.retryable ?? false;
      if ((key == null || key.isEmpty) && !marked) {
        return false;
      }
    }
    if (error is RpcNetworkException || error is RpcTimeoutException) {
      return true;
    }
    const eligible = <String>{
      'TOO_MANY_REQUESTS',
      'SERVICE_UNAVAILABLE',
      'GATEWAY_TIMEOUT',
    };
    return eligible.contains(error.code);
  }
}
