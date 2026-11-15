import 'dart:async';

import 'codec.dart';
import 'exceptions.dart';
import 'query.dart';

enum RpcProcedureKind { query, mutation, subscription }

/// Per-call request metadata.
class RpcCallContext {
  const RpcCallContext({
    this.headers = const {},
    this.timeout,
    this.cancelToken,
    this.idempotencyKey,
    this.retryable = false,
  });

  final Map<String, String> headers;
  final Duration? timeout;
  final CancelToken? cancelToken;

  /// Stable per-logical-operation key. Presence allows safe mutation retries.
  final String? idempotencyKey;

  /// Explicit opt-in to retry a mutation without an idempotency key.
  final bool retryable;
}

/// Composable cancellation token. Cancelling a completed call is a no-op.
class CancelToken {
  final Completer<void> _completer = Completer<void>();

  bool get isCancelled => _completer.isCompleted;

  void cancel({String? reason}) {
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }

  Future<void> get whenCancelled => _completer.future;
}

class RpcRequest {
  const RpcRequest({
    required this.path,
    required this.kind,
    required this.input,
    this.context,
  });

  final String path;
  final RpcProcedureKind kind;
  final Object? input; // pre-transform tree from input.toJson()
  final RpcCallContext? context;

  RpcRequest withAddedHeader(String name, String value) {
    final base = context?.headers ?? const <String, String>{};
    return RpcRequest(
      path: path,
      kind: kind,
      input: input,
      context: RpcCallContext(
        headers: <String, String>{...base, name: value},
        timeout: context?.timeout,
        cancelToken: context?.cancelToken,
      ),
    );
  }
}

/// One processing step. `next(request)` forwards to the rest of the chain.
abstract class RpcLink {
  bool get isTermination => false;

  Future<Object?> invoke(RpcRequest request, RpcLinkNext next);
}

typedef RpcLinkNext = Future<Object?> Function(RpcRequest request);

/// Ordered, validated link pipeline. Exactly one termination link.
class RpcLinkChain {
  RpcLinkChain(List<RpcLink> links) : _links = List.of(links) {
    if (_links.isEmpty) {
      throw ArgumentError.value(links, 'links', 'must not be empty');
    }
    final terminations = _links.where((l) => l.isTermination).length;
    if (terminations != 1) {
      throw ArgumentError.value(
        links,
        'links',
        'exactly one termination link required (found $terminations)',
      );
    }
  }

  final List<RpcLink> _links;

  Future<Object?> invoke(RpcRequest request) {
    Future<Object?> run(int index, RpcRequest req) {
      final link = _links[index];
      final isLast = index == _links.length - 1;
      if (link.isTermination || isLast) {
        return link.invoke(req, _unreachable);
      }
      return link.invoke(req, (next) => run(index + 1, next));
    }

    return run(0, request);
  }

  Future<Object?> _unreachable(RpcRequest request) {
    throw StateError('termination link must not call next');
  }
}

/// The client configured once at app composition. Safe to share globally.
class RpcClient {
  RpcClient({
    required this.endpoint,
    this.transformer = RpcTransformer.superjson,
    required List<RpcLink> links,
    this.defaultHeaders = const {},
    RpcQueryCache? cache,
  })  : cache = cache ?? RpcQueryCache(),
        _chain = RpcLinkChain(_withDefaults(links, defaultHeaders));

  static List<RpcLink> _withDefaults(List<RpcLink> links, Map<String, String> defaults) {
    final effective = List.of(links);
    if (defaults.isNotEmpty) {
      final terminationIndex = effective.indexWhere((l) => l.isTermination);
      effective.insert(
        terminationIndex == -1 ? effective.length : terminationIndex,
        _ClientDefaultsLink(defaults),
      );
    }
    return effective;
  }

  final Uri endpoint;
  final RpcTransformer transformer;
  final Map<String, String> defaultHeaders;
  final RpcQueryCache cache;
  final RpcLinkChain _chain;

  /// The only transport API generated code calls. Decoding to models happens
  /// in generated `fromJson` after the pipeline produced the transformed tree.
  Future<Object?> execute(RpcRequest request) {
    if (request.context?.cancelToken?.isCancelled ?? false) {
      return Future<Object?>.error(
        RpcCancelledException('call cancelled before dispatch'),
      );
    }
    return _chain.invoke(request);
  }
}

/// Internal link applying client-level default headers as the LOWEST
/// precedence (fills keys nothing else set): per-call context, credentials,
/// and dynamic headers all win over defaults.
final class _ClientDefaultsLink extends RpcLink {
  _ClientDefaultsLink(this.headers);

  final Map<String, String> headers;

  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) {
    var req = request;
    headers.forEach((name, value) {
      if (req.context?.headers.containsKey(name) != true) {
        req = req.withAddedHeader(name, value);
      }
    });
    return next(req);
  }
}
