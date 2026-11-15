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
  ContextLink({this.dynamicHeaders, this.correlate = true});

  /// Resolves app-level headers for every request. These fill keys that are
  /// not already set by per-call context or credentials.
  final Future<Map<String, String>> Function()? dynamicHeaders;

  final bool correlate;

  int _counter = 0;

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

  String _nextRequestId() {
    _counter += 1;
    return 'req-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-$_counter';
  }
}
