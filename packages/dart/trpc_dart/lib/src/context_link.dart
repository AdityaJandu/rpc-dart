import 'dart:async';

import 'link.dart';

/// Merges dynamic (per-app) headers under per-call context headers, and
/// maintains `x-request-id` correlation: generated when absent, propagated
/// when provided, and stable across retries (the same request object flows
/// through the retry loop).
///
/// Precedence (lowest to highest): client defaults (applied by an internal
/// defaults link just before the transport) -> ContextLink dynamic headers
/// -> AuthLink credentials -> per-call [RpcCallContext.headers].
class ContextLink extends RpcLink {
  /// Creates a context link with dynamic header provider and correlation toggle.
  ContextLink({this.dynamicHeaders, this.correlate = true});

  /// Resolves app-level headers for every request. These fill keys that are
  /// not already set by per-call context or credentials.
  final Future<Map<String, String>> Function()? dynamicHeaders;

  /// Whether to generate and attach an `x-request-id` header if none is present.
  final bool correlate;

  int _counter = 0;

  /// Applies dynamic headers and request ID correlation before invoking the next link.
  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) async {
    var req = request;
    final dynamic = await dynamicHeaders?.call() ?? const <String, String>{};
    dynamic.forEach((name, value) {
      if (req.context?.headers.containsKey(name) != true) {
        req = req.withAddedHeader(name, value);
      }
    });
    if (correlate && req.context?.headers['x-request-id'] == null) {
      req = req.withAddedHeader('x-request-id', _nextRequestId());
    }
    return next(req);
  }

  /// Stream counterpart: re-runs per connect attempt because the reconnect
  /// engine re-invokes the whole chain, giving every attempt a fresh
  /// correlation id and current dynamic headers.
  @override
  Stream<Object?> invokeStream(
      RpcRequest request, RpcStreamLinkNext next) async* {
    var req = request;
    final dynamic = await dynamicHeaders?.call() ?? const <String, String>{};
    dynamic.forEach((name, value) {
      if (req.context?.headers.containsKey(name) != true) {
        req = req.withAddedHeader(name, value);
      }
    });
    if (correlate && req.context?.headers['x-request-id'] == null) {
      req = req.withAddedHeader('x-request-id', _nextRequestId());
    }
    yield* next(req);
  }

  String _nextRequestId() {
    _counter += 1;
    return 'req-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-$_counter';
  }
}
