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
