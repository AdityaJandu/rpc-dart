import 'dart:async';

import 'link.dart';

/// Operation-type router: unary calls (query / mutation) go to [unaryLink]
/// (e.g. [HttpBatchLink]), subscriptions go to [subscriptionLink] (SSE or
/// WebSocket). A custom [predicate] overrides kind-based routing: returning
/// true routes the request to the subscription link.
final class SplitLink extends RpcLink {
  /// Creates a split link over [unaryLink] and [subscriptionLink].
  SplitLink({
    required this.unaryLink,
    required this.subscriptionLink,
    this.predicate,
  });

  /// Termination transport for unary procedures.
  final RpcLink unaryLink;

  /// Termination transport for subscriptions.
  final RpcLink subscriptionLink;

  /// Optional routing override; true sends the request to
  /// [subscriptionLink], false or null falls back to kind-based routing.
  final bool Function(RpcRequest request)? predicate;

  @override
  bool get isTermination =>
      unaryLink.isTermination || subscriptionLink.isTermination;

  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) {
    if (predicate?.call(request) ??
        request.kind == RpcProcedureKind.subscription) {
      return subscriptionLink.invoke(request, next);
    }
    return unaryLink.invoke(request, next);
  }

  @override
  Stream<Object?> invokeStream(RpcRequest request, RpcStreamLinkNext next) {
    return subscriptionLink.invokeStream(request, next);
  }
}
