import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'codec.dart';
import 'codec/rpc_json.dart';
import 'exceptions.dart';
import 'link.dart';

/// Terminal transport link: coalesces same-tick calls into batched HTTP
/// requests, splits oversized GET batches, and demultiplexes the
/// index-aligned responses.
final class HttpBatchLink extends RpcLink {
  /// Creates a batching transport link targeting [endpoint].
  HttpBatchLink({
    required this.endpoint,
    this.transformer = RpcTransformer.superjson,
    this.maxURLLength = 2083,
    this.maxBatchSize = 10,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Server tRPC base endpoint URI.
  final Uri endpoint;

  /// Transformer matching server configuration.
  final RpcTransformer transformer;

  /// Maximum character length of URL before GET batch is split or converted to POST.
  final int maxURLLength;

  /// Maximum procedure calls batched in a single request.
  final int maxBatchSize;
  final http.Client _client;

  final List<_Pending> _queue = <_Pending>[];
  bool _flushScheduled = false;

  @override
  bool get isTermination => true;

  /// Enqueues the request into the current microtask batch queue and returns its completion future.
  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) {
    final pending = _Pending(request);
    _queue.add(pending);
    _scheduleFlush();
    _wireLifecycle(pending);
    return pending.completer.future;
  }

  /// Mid-flight cancellation and per-call timeouts resolve the caller
  /// immediately and mark the pending response discarded (siblings in the
  /// same batch complete normally).
  void _wireLifecycle(_Pending pending) {
    final token = pending.request.context?.cancelToken;
    if (token != null) {
      unawaited(token.whenCancelled.then((_) {
        if (!pending.completer.isCompleted) {
          pending.discarded = true;
          pending.completer.completeError(
            RpcCancelledException('cancelled mid-flight'),
          );
        }
      }));
    }
    final timeout = pending.request.context?.timeout;
    if (timeout != null) {
      unawaited(Future<void>.delayed(timeout, () {
        if (!pending.completer.isCompleted) {
          pending.discarded = true;
          pending.completer.completeError(
            RpcTimeoutException(
                'operation exceeded the ${timeout.inMilliseconds}ms timeout'),
          );
        }
      }));
    }
  }

  /// Closes the underlying HTTP client.
  void close() {
    _client.close();
  }

  void _scheduleFlush() {
    if (_flushScheduled) return;
    _flushScheduled = true;
    scheduleMicrotask(() {
      _flushScheduled = false;
      unawaited(_flush());
    });
  }

  Future<void> _flush() async {
    final batch = List<_Pending>.of(_queue);
    _queue.clear();

    final live = <_Pending>[];
    for (final pending in batch) {
      if (pending.completer.isCompleted) {
        continue; // cancelled or timed out before dispatch
      }
      if (pending.request.context?.cancelToken?.isCancelled ?? false) {
        pending.discarded = true;
        pending.completer.completeError(
          RpcCancelledException('cancelled before dispatch'),
        );
      } else {
        live.add(pending);
      }
    }
    if (live.isEmpty) return;

    final queries =
        live.where((p) => p.request.kind == RpcProcedureKind.query).toList();
    final mutations =
        live.where((p) => p.request.kind == RpcProcedureKind.mutation).toList();
    final futures = <Future<void>>[
      if (queries.isNotEmpty) _sendGroup(queries, isMutation: false),
      if (mutations.isNotEmpty) _sendGroup(mutations, isMutation: true),
    ];
    await Future.wait(futures);
  }

  Future<void> _sendGroup(List<_Pending> group,
      {required bool isMutation}) async {
    final futures = <Future<void>>[];
    for (var start = 0; start < group.length; start += maxBatchSize) {
      final end = math.min(start + maxBatchSize, group.length);
      futures
          .add(_sendChunk(group.sublist(start, end), isMutation: isMutation));
    }
    await Future.wait(futures);
  }

  Future<void> _sendChunk(List<_Pending> chunk,
      {required bool isMutation}) async {
    try {
      if (!isMutation) {
        await _sendGet(chunk);
      } else {
        await _sendPost(chunk);
      }
    } catch (error, stack) {
      _failChunk(chunk, error, stack);
    }
  }

  Future<void> _sendGet(List<_Pending> chunk) async {
    final url = _buildGetUrl(chunk);
    if (url.length > maxURLLength && chunk.length > 1) {
      // URL-length guard: split into multiple requests (tRPC-native behavior).
      final half = chunk.length ~/ 2;
      await _sendGet(chunk.sublist(0, half));
      await _sendGet(chunk.sublist(half));
      return;
    }
    final response = await _client.get(
      Uri.parse(url),
      headers: _headersFor(chunk.first.request),
    );
    _demux(chunk, response, batched: chunk.length > 1);
  }

  Future<void> _sendPost(List<_Pending> chunk) async {
    final paths = chunk.map((p) => p.request.path).join(',');
    final url = '${_base()}/${_encodePath(paths)}';
    final batched = chunk.length > 1;
    final body =
        batched ? _buildBodyDict(chunk) : _bodyFor(chunk.first.request);
    final response = await _client.post(
      Uri.parse(url),
      headers: <String, String>{
        ..._headersFor(chunk.first.request),
        'content-type': 'application/json',
      },
      body: body,
    );
    _demux(chunk, response, batched: batched);
  }

  String _base() {
    final text = endpoint.toString();
    return text.endsWith('/') ? text.substring(0, text.length - 1) : text;
  }

  String _encodePath(String paths) {
    // Procedure paths contain dots/commas only; dots stay literal.
    return Uri.encodeComponent(paths).replaceAll('%2E', '.');
  }

  String _buildGetUrl(List<_Pending> chunk) {
    final paths = chunk.map((p) => p.request.path).join(',');
    final batched = chunk.length > 1;
    final input =
        batched ? _buildInputDict(chunk) : _inputJsonFor(chunk.first.request);
    final params = <String>[];
    if (batched) params.add('batch=1');
    if (input != null) params.add('input=${Uri.encodeComponent(input)}');
    final query = params.isEmpty ? '' : '?${params.join('&')}';
    return '${_base()}/${_encodePath(paths)}$query';
  }

  String? _inputJsonFor(RpcRequest request) {
    return _wireInput(request) == null ? null : jsonEncode(_wireInput(request));
  }

  String _buildInputDict(List<_Pending> chunk) {
    final dict = <String, Object?>{};
    for (var i = 0; i < chunk.length; i++) {
      final wire = _wireInput(chunk[i].request);
      dict['$i'] = wire == null ? <String, Object?>{} : wire;
    }
    return jsonEncode(dict);
  }

  String _buildBodyDict(List<_Pending> chunk) {
    final dict = <String, Object?>{};
    for (var i = 0; i < chunk.length; i++) {
      final wire = _wireInput(chunk[i].request);
      dict['$i'] = wire == null ? <String, Object?>{} : wire;
    }
    return jsonEncode(dict);
  }

  String _bodyFor(RpcRequest request) {
    return jsonEncode(_wireInput(request) ?? <String, Object?>{});
  }

  /// Runs the pre-transform input tree through the configured transformer.
  Object? _wireInput(RpcRequest request) {
    if (request.input == null) return null;
    switch (transformer) {
      case RpcTransformer.superjson:
        return superjsonEncode(request.input);
      case RpcTransformer.json:
        return jsonEncodeTree(request.input);
    }
  }

  Map<String, String> _headersFor(RpcRequest request) {
    return request.context?.headers ?? const <String, String>{};
  }

  void _demux(List<_Pending> chunk, http.Response response,
      {required bool batched}) {
    final decoded = _parseBody(response.body);
    if (batched) {
      if (decoded is! List<Object?>) {
        throw RpcDecodeException('expected a batch response array');
      }
      if (decoded.length != chunk.length) {
        throw RpcDecodeException(
          'batch response length mismatch: ${decoded.length} vs ${chunk.length}',
        );
      }
      for (var i = 0; i < chunk.length; i++) {
        _completeItem(chunk[i], decoded[i]);
      }
    } else {
      _completeItem(chunk.single, decoded);
    }
  }

  Object? _parseBody(String body) {
    return RpcJson.parse(body);
  }

  void _completeItem(_Pending pending, Object? item) {
    if (pending.discarded || pending.completer.isCompleted) {
      return; // caller already resolved via cancellation or timeout
    }
    try {
      pending.completer.complete(_decodeItem(item));
    } catch (error) {
      pending.completer.completeError(error);
    }
  }

  Object? _decodeItem(Object? item) {
    final map = asStringMap(item);
    if (map == null) {
      throw RpcDecodeException('malformed response item: $item');
    }
    if (map.containsKey('error')) {
      final error = asStringMap(map['error']);
      final inner = error == null ? null : asStringMap(error['json']);
      if (inner == null) {
        throw RpcDecodeException('malformed error envelope');
      }
      throw RpcException.fromWire(inner);
    }
    final result = asStringMap(map['result']);
    if (result == null) {
      throw RpcDecodeException('missing result envelope');
    }
    return unwrapEnvelope(result['data'], transformer);
  }

  void _failChunk(List<_Pending> chunk, Object error, StackTrace stack) {
    for (final pending in chunk) {
      if (error is RpcDecodeException) {
        pending.completer.completeError(error, stack);
      } else {
        pending.completer.completeError(
          RpcNetworkException('transport failure: $error', cause: error),
          stack,
        );
      }
    }
  }
}

Map<String, Object?>? asStringMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  return null;
}

final class _Pending {
  _Pending(this.request);

  final RpcRequest request;
  final Completer<Object?> completer = Completer<Object?>();

  /// True when the caller resolved via cancellation or timeout and the wire
  /// response (when it eventually arrives) must be discarded.
  bool discarded = false;
}

Object? unwrapEnvelope(Object? data, RpcTransformer transformer) {
  switch (transformer) {
    case RpcTransformer.superjson:
      if (data is Map<String, Object?> &&
          data.containsKey('json') &&
          (data.containsKey('meta') || data.length == 1)) {
        return superjsonDecode(data);
      }
      return data;
    case RpcTransformer.json:
      return data;
  }
}
