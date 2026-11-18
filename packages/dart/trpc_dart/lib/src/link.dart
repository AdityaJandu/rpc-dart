import 'dart:async';

import 'codec.dart';
import 'exceptions.dart';
import 'query.dart';
import 'subscription.dart';

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
    this.subscription,
  });

  /// Dotted procedure path, e.g. `'user.getById'`.
  final String path;

  /// The procedure kind (query, mutation, or subscription).
  final RpcProcedureKind kind;

  /// Pre-transform input data tree from `input.toJson()`.
  final Object? input;

  /// Optional per-call metadata context.
  final RpcCallContext? context;

  /// Per-subscription mutable state (latest tracked event id, options).
  /// Present only for streaming requests.
  final RpcSubscriptionTicket? subscription;

  /// Returns a copy of this request with the specified header appended or updated.
  RpcRequest withAddedHeader(String name, String value) {
    final base = context?.headers ?? const <String, String>{};
    return RpcRequest(
      path: path,
      kind: kind,
      input: input,
      subscription: subscription,
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

  /// Handles a streaming [request] and calls [next] to continue downstream.
  /// Termination subscription links (SSE / WebSocket) implement this.
  Stream<Object?> invokeStream(RpcRequest request, RpcStreamLinkNext next) {
    return Stream<Object?>.error(
      StateError('${runtimeType} does not support streaming'),
    );
  }
}

/// Continuation callback forwarding a request to the next link in the chain.
typedef RpcLinkNext = Future<Object?> Function(RpcRequest request);

/// Continuation callback forwarding a request to the next link's stream.
typedef RpcStreamLinkNext = Stream<Object?> Function(RpcRequest request);

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

  /// Dispatches a streaming [request] through the link chain.
  ///
  /// When the request carries a subscription ticket, retryable failures
  /// (network drops, 5xx, server-reconnect notifications) re-run the whole
  /// chain after the policy's backoff, so middleware links re-resolve headers
  /// and credentials per attempt. Clean server completions never reconnect.
  ///
  /// Controller-based, not async*: an async* generator defers cancellation
  /// until its next event, which would hang sub.cancel() against a silent
  /// transport.
  Stream<Object?> invokeStream(RpcRequest request) {
    final ticket = request.subscription;
    if (ticket == null) {
      return _runStream(0, request);
    }
    late final StreamController<Object?> out;
    StreamSubscription<Object?>? attempt;
    var cancelled = false;
    var attemptNumber = 0;
    var progressed = false;

    Future<void> start() async {
      progressed = false;
      late final StreamSubscription<Object?> sub;
      sub = _runStream(0, request).listen(
        (value) {
          progressed = true;
          out.add(value);
        },
        onError: (Object error, StackTrace stackTrace) async {
          // A superseded attempt's callbacks must not touch the output.
          if (cancelled || out.isClosed || !identical(attempt, sub)) return;
          if (!isRetryableStreamError(error)) {
            out.addError(error, stackTrace);
            await out.close();
            return;
          }
          // Detach before awaiting: the superseded attempt's onDone fires
          // during backoff and would otherwise close the output.
          attempt = null;
          if (progressed) attemptNumber = 0;
          attemptNumber++;
          if (!ticket.options.reconnectPolicy.shouldRetry(attemptNumber)) {
            out.addError(error, stackTrace);
            await out.close();
            return;
          }
          ticket.options.onReconnect?.call(attemptNumber, error);
          try {
            await _reconnectBackoff(ticket, attemptNumber);
          } on RpcCancelledException catch (cancelError) {
            out.addError(cancelError);
            await out.close();
            return;
          }
          if (!cancelled && !out.isClosed) {
            await start();
          }
        },
        onDone: () async {
          if (cancelled || !identical(attempt, sub)) return;
          await out.close();
        },
      );
      attempt = sub;
    }

    out = StreamController<Object?>(
      onCancel: () async {
        cancelled = true;
        await attempt?.cancel();
      },
    );
    unawaited(start());
    return out.stream;
  }

  Stream<Object?> _runStream(int index, RpcRequest request) {
    final link = _links[index];
    final isLast = index == _links.length - 1;
    if (link.isTermination || isLast) {
      return link.invokeStream(request, _unreachableStream);
    }
    return link.invokeStream(request, (next) => _runStream(index + 1, next));
  }

  Future<void> _reconnectBackoff(RpcSubscriptionTicket ticket, int attempt) {
    var delay = ticket.options.reconnectPolicy.delayFor(attempt);
    // The server's SSE `retry:` hint floors the policy's backoff so the client
    // honors the requested reconnection interval.
    final hint = ticket.retryHint;
    if (hint != null && hint > delay) {
      delay = hint;
    }
    final token = ticket.options.cancelToken;
    if (token == null || token.isCancelled) {
      if (token?.isCancelled ?? false) {
        return Future<void>.error(
          RpcCancelledException('cancelled during reconnect backoff'),
        );
      }
      return Future<void>.delayed(delay);
    }
    return Future.any<void>(<Future<void>>[
      Future<void>.delayed(delay),
      token.whenCancelled.then(
        (_) =>
            throw RpcCancelledException('cancelled during reconnect backoff'),
      ),
    ]);
  }

  Future<Object?> _unreachable(RpcRequest request) {
    throw StateError('termination link must not call next');
  }

  Stream<Object?> _unreachableStream(RpcRequest request) {
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

  /// Opens a subscription stream through the link chain. The returned stream
  /// already handles reconnection; generated code maps items through the
  /// model decoder.
  Stream<Object?> sendStream(RpcRequest request) {
    if (request.context?.cancelToken?.isCancelled ?? false) {
      return Stream<Object?>.error(
        RpcCancelledException('call cancelled before dispatch'),
      );
    }
    return _chain.invokeStream(request);
  }

  /// Opens a decoded subscription stream for [path]. Inputs are encoded by
  /// generated code before reaching this call.
  Stream<T> subscribe<T>({
    required String path,
    required Object? input,
    required T Function(Object?) decode,
    RpcSubscriptionOptions? options,
  }) {
    final ticket = RpcSubscriptionTicket(
      options ?? const RpcSubscriptionOptions(),
    );
    final request = RpcRequest(
      path: path,
      kind: RpcProcedureKind.subscription,
      input: input,
      subscription: ticket,
      context: RpcCallContext(
        headers: ticket.options.headers,
        cancelToken: ticket.options.cancelToken,
      ),
    );
    return sendStream(request).map(decode);
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
