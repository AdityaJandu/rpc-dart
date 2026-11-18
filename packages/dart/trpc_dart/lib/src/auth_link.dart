import 'dart:async';

import 'exceptions.dart';
import 'link.dart';

/// Attaches dynamic credentials to every request and performs single-flight
/// token refresh on 401:
///
/// - [getHeaders] runs before every dispatch (initial and replay).
/// - Concurrent 401s share exactly one [onUnauthorized] refresh via a
///   [Completer] lock; each failed operation replays at most once with the
///   refreshed credentials.
/// - A second 401 after replay surfaces to the caller: no refresh loops.
class AuthLink extends RpcLink {
  /// Creates an authentication link with credential resolver [getHeaders]
  /// and optional [onUnauthorized] refresh handler.
  AuthLink(
      {required this.getHeaders,
      this.onUnauthorized,
      this.overrideExisting = false});

  /// Resolves the current credential headers (e.g. `authorization`).
  final Future<Map<String, String>> Function() getHeaders;

  /// Refreshes credentials after an UNAUTHORIZED response. Returns the new
  /// headers when it stores them itself; returning null is fine when the
  /// refresh mutated whatever [getHeaders] reads. Throwing marks the refresh
  /// failed and skips the replay.
  final Future<Map<String, String>?> Function()? onUnauthorized;

  /// When true, credential headers replace headers already present on the
  /// request (security-sensitive override); when false (default) they only
  /// fill absent keys, so an explicit per-call header wins.
  final bool overrideExisting;

  Completer<bool>? _refreshLock;

  /// Intercepts the request, attaches credentials, and performs a single refresh on 401.
  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) async {
    final headers = await getHeaders();
    final attached = _attach(request, headers);
    Object? result;
    try {
      result = await next(attached);
      return result;
    } on RpcUnauthorizedException {
      final refreshed = await _refreshOnce();
      if (!refreshed) {
        rethrow;
      }
      final fresh = await getHeaders();
      // Single replay: a second 401 propagates to the caller.
      return next(_attach(request, fresh));
    }
  }

  /// Stream counterpart: same credential attach + single-flight refresh.
  /// The replay re-opens the downstream stream, whose resume point rides the
  /// subscription ticket's latest tracked event id. Controller-based so user
  /// cancellation aborts the downstream immediately.
  @override
  Stream<Object?> invokeStream(RpcRequest request, RpcStreamLinkNext next) {
    late final StreamController<Object?> out;
    StreamSubscription<Object?>? current;
    var replayed = false;
    var cancelled = false;

    Future<void> open() async {
      final headers = await getHeaders();
      if (cancelled) return;
      late final StreamSubscription<Object?> sub;
      sub = next(_attach(request, headers)).listen(
        out.add,
        onError: (Object error, StackTrace stackTrace) async {
          // A superseded attempt's callbacks must not touch the output.
          if (cancelled || out.isClosed || !identical(current, sub)) return;
          if (error is! RpcUnauthorizedException || replayed) {
            out.addError(error, stackTrace);
            await out.close();
            return;
          }
          // Detach before awaiting: the superseded attempt's onDone fires
          // during the refresh and would otherwise close the output.
          current = null;
          final refreshed = await _refreshOnce();
          if (!refreshed || cancelled) {
            out.addError(error, stackTrace);
            await out.close();
            return;
          }
          replayed = true;
          // Single replay: a second 401 propagates to the caller.
          await open();
        },
        onDone: () async {
          if (cancelled || !identical(current, sub)) return;
          await out.close();
        },
      );
      current = sub;
    }

    out = StreamController<Object?>(
      onCancel: () async {
        cancelled = true;
        await current?.cancel();
      },
    );
    unawaited(open());
    return out.stream;
  }

  RpcRequest _attach(RpcRequest request, Map<String, String> headers) {
    var req = request;
    headers.forEach((name, value) {
      final existing = req.context?.headers[name];
      final shouldApply = overrideExisting || existing == null;
      if (shouldApply) {
        req = req.withAddedHeader(name, value);
      }
    });
    return req;
  }

  Future<bool> _refreshOnce() {
    final existing = _refreshLock;
    if (existing != null) {
      return existing.future;
    }
    final completer = Completer<bool>();
    _refreshLock = completer;
    unawaited(() async {
      try {
        await onUnauthorized?.call();
        completer.complete(true);
      } catch (_) {
        completer.complete(false);
      } finally {
        _refreshLock = null;
      }
    }());
    return completer.future;
  }
}
