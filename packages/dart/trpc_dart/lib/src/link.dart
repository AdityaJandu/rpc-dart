import 'dart:async';

import 'codec.dart';
import 'exceptions.dart';
import 'query.dart';

/// The kind of tRPC procedure being executed.
enum RpcProcedureKind {
  /// Query procedure (HTTP GET or query batch).
  query,

  /// Mutation procedure (HTTP POST).
  mutation,

  /// Subscription procedure.
  subscription,
}

/// Per-call request metadata including headers, timeout, cancellation, and idempotency.
class RpcCallContext {
  /// Creates request metadata for a single procedure execution.
  const RpcCallContext({
    this.headers = const {},
    this.timeout,
    this.cancelToken,
    this.idempotencyKey,
    this.retryable = false,
  });

  /// Headers attached to this specific call.
  final Map<String, String> headers;

  /// Optional per-call deadline timeout.
  final Duration? timeout;

  /// Optional token used to cancel the call in-flight.
  final CancelToken? cancelToken;

  /// Stable per-logical-operation key. Presence allows safe mutation retries.
  final String? idempotencyKey;

  /// Explicit opt-in to retry a mutation without an idempotency key.
  final bool retryable;
}

/// Composable cancellation token. Cancelling a completed call is a no-op.
class CancelToken {
  /// Creates an active cancellation token.
  CancelToken();

  final Completer<void> _completer = Completer<void>();

  /// Whether cancellation has been triggered.
  bool get isCancelled => _completer.isCompleted;

  /// Triggers cancellation of operations observing this token.
  void cancel({String? reason}) {
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }

  /// Future that completes when [cancel] is called.
  Future<void> get whenCancelled => _completer.future;
}

/// Raw RPC operation dispatched through the [RpcLinkChain].
class RpcRequest {
  /// Creates an RPC request with procedure [path], [kind], and [input].
  const RpcRequest({
    required this.path,
    required this.kind,
    required this.input,
    this.context,
  });

  /// Dotted procedure path, e.g. `'user.getById'`.
  final String path;

  /// The procedure kind (query, mutation, or subscription).
  final RpcProcedureKind kind;

  /// Pre-transform input data tree from `input.toJson()`.
  final Object? input;

  /// Optional per-call metadata context.
  final RpcCallContext? context;

  /// Returns a copy of this request with the specified header appended or updated.
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

/// One processing step in an [RpcLinkChain]. `next(request)` forwards to downstream links.
abstract class RpcLink {
  /// Whether this link terminates the chain and produces a response without forwarding.
  bool get isTermination => false;

  /// Handles the [request] and calls [next] to continue downstream, or returns a result directly.
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next);
}

/// Continuation callback forwarding a request to the next link in the chain.
typedef RpcLinkNext = Future<Object?> Function(RpcRequest request);

/// Ordered, validated link pipeline requiring exactly one terminating link.
class RpcLinkChain {
  /// Validates and builds a pipeline from an ordered list of [links].
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

  /// Dispatches [request] through the link chain.
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
  /// Creates an RPC client targeting [endpoint] using the provided [links] pipeline.
  RpcClient({
    required this.endpoint,
    this.transformer = RpcTransformer.superjson,
    required List<RpcLink> links,
    this.defaultHeaders = const {},
    RpcQueryCache? cache,
  })  : cache = cache ?? RpcQueryCache(),
        _chain = RpcLinkChain(_withDefaults(links, defaultHeaders));

  static List<RpcLink> _withDefaults(
      List<RpcLink> links, Map<String, String> defaults) {
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

  /// Base URI of the tRPC server endpoint.
  final Uri endpoint;

  /// Transformer matching server configuration (`superjson` or `json`).
  final RpcTransformer transformer;

  /// Default headers attached to every outbound request.
  final Map<String, String> defaultHeaders;

  /// State-agnostic query cache for query deduplication and invalidation.
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
