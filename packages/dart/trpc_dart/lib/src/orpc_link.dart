import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'binary.dart';
import 'codec/rpc_json.dart';
import 'exceptions.dart';
import 'link.dart';
import 'orpc/codec.dart';
import 'orpc/multipart.dart';
import 'sse_parser.dart';
import 'subscription.dart';

/// Terminal transport for the oRPC RPC protocol (RPCHandler / RPCLink wire):
/// slash-delimited pathname routing, `{json, meta}` envelopes, indexed
/// multipart file maps, raw file / octet-stream downloads, and SSE
/// event-iterator streaming. Composes with the standard middleware links.
final class OrpcLink extends RpcLink {
  /// Creates an oRPC transport targeting [endpoint] (the handler prefix).
  ///
  /// [idleTimeout] aborts and reconnects an event-iterator stream that goes
  /// silent; a per-subscription [RpcSubscriptionOptions.idleTimeout]
  /// overrides it. Null disables idle detection.
  OrpcLink({
    required this.endpoint,
    this.maxUrlLength = 2083,
    this.idleTimeout,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Server oRPC base endpoint URI (e.g. `https://api.example/rpc`).
  final Uri endpoint;

  /// GET query URLs longer than this fall back to POST (oRPC parity).
  final int maxUrlLength;

  /// Default SSE inactivity deadline before a stalled stream is reconnected.
  final Duration? idleTimeout;

  final http.Client _client;
  static const OrpcCodec _codec = OrpcCodec();

  @override
  bool get isTermination => true;

  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) {
    final token = request.context?.cancelToken;
    if (token?.isCancelled ?? false) {
      return Future<Object?>.error(
        RpcCancelledException(
            token!.reason ?? 'call cancelled before dispatch'),
      );
    }
    return _withLifecycle(request, (abort) => _execute(request, abort));
  }

  @override
  Stream<Object?> invokeStream(RpcRequest request, RpcStreamLinkNext next) {
    final ticket = request.subscription;
    final idle = ticket?.options.idleTimeout ?? idleTimeout;
    late final StreamController<Object?> out;
    StreamSubscription<SseFrame>? frames;
    Timer? idleTimer;
    var disposed = false;

    void stopIdleTimer() {
      idleTimer?.cancel();
      idleTimer = null;
    }

    Future<void> abort() async {
      stopIdleTimer();
      await frames?.cancel();
    }

    out = StreamController<Object?>(onCancel: () {
      disposed = true;
      return abort();
    });

    void armIdleTimer() {
      if (idle == null) return;
      idleTimer?.cancel();
      idleTimer = Timer(idle, () {
        unawaited(() async {
          await frames?.cancel();
          frames = null;
          if (!out.isClosed) {
            out.addError(RpcTimeoutException('orpc event stream idle'));
            await out.close();
          }
        }());
      });
    }

    Future<void> run() async {
      try {
        final serialized = _codec.serialize(request.input);
        final httpRequest = http.Request('POST', _url(request.path))
          ..headers.addAll(<String, String>{
            ...?request.context?.headers,
            'content-type': 'application/json',
            'accept': 'text/event-stream',
            'cache-control': 'no-cache',
            if (ticket?.lastEventId != null)
              'last-event-id': ticket!.lastEventId!,
          })
          ..body = jsonEncode(serialized.envelope());
        final response =
            await _sendStreaming(httpRequest, request.context?.timeout);
        if (disposed) {
          _discardResponse(response);
          return;
        }
        if (response.statusCode != 200) {
          throw await _errorFromResponse(response);
        }

        final token = request.context?.cancelToken;
        if (token != null) {
          unawaited(token.whenCancelled.then((_) async {
            disposed = true;
            await abort();
            if (!out.isClosed) {
              out.addError(RpcCancelledException(
                  token.reason ?? 'cancelled mid-stream'));
              await out.close();
            }
          }));
        }

        armIdleTimer();
        frames = SseParser().parse(response.stream).listen(
          (frame) {
            if (out.isClosed) return;
            armIdleTimer();
            if (frame.retry != null) {
              ticket?.retryHint = Duration(milliseconds: frame.retry!);
            }
            if (frame.event == 'done') {
              stopIdleTimer();
              unawaited(out.close());
              return;
            }
            if (frame.event == 'error') {
              stopIdleTimer();
              out.addError(_errorFromFrame(frame.data));
              unawaited(out.close());
              return;
            }
            if (frame.event != null && frame.event != 'message') {
              return; // unknown named events are keep-alives
            }
            if (frame.data.isEmpty) {
              return; // comment-only heartbeat
            }
            if (frame.id != null && frame.id!.isNotEmpty) {
              ticket?.recordEventId(frame.id!);
            }
            out.add(_decodeEnvelopeText(frame.data));
          },
          onError: (Object error, StackTrace stackTrace) {
            stopIdleTimer();
            if (out.isClosed) return;
            out.addError(error, stackTrace);
          },
          onDone: () {
            stopIdleTimer();
            if (out.isClosed) return;
            out
              ..addError(RpcNetworkException(
                  'orpc event stream ended without completion'))
              ..close();
          },
        );
      } catch (error, stackTrace) {
        stopIdleTimer();
        if (!out.isClosed) {
          out.addError(error, stackTrace);
          await out.close();
        }
      }
    }

    unawaited(run());
    return out.stream;
  }

  /// Closes the underlying HTTP client.
  void close() => _client.close();

  // --- unary ---------------------------------------------------------------

  Future<Object?> _execute(RpcRequest request, Future<void>? abort) async {
    final serialized = _codec.serialize(request.input);
    final url = _url(request.path);
    final headers = <String, String>{...?request.context?.headers};
    final onSend = request.context?.onSendProgress;

    final http.BaseRequest httpRequest;
    if (serialized.hasFiles) {
      final multipart = http.MultipartRequest('POST', url)
        ..headers.addAll(headers)
        ..fields['data'] = serialized.formDataField();
      var total = 0;
      var totalKnown = true;
      for (final blob in serialized.blobs) {
        final length = blob.length;
        if (length == null) {
          totalKnown = false;
        } else {
          total += length;
        }
      }
      var sent = 0;
      for (var i = 0; i < serialized.blobs.length; i++) {
        final blob = serialized.blobs[i];
        var length = blob.length;
        Stream<Uint8List> stream;
        if (length == null) {
          final bytes = await blob.readBytes();
          length = bytes.length;
          stream = Stream<Uint8List>.value(bytes);
        } else {
          stream = blob.openStream();
        }
        if (onSend != null) {
          stream = stream.map((chunk) {
            sent += chunk.length;
            onSend(RpcTransferProgress(sent,
                totalBytes: totalKnown ? total : null));
            return chunk;
          });
        }
        stream = _abortable(stream, abort);
        final http.MediaType? mime;
        if (blob.contentType == null) {
          mime = null;
        } else {
          try {
            mime = http.MediaType.parse(blob.contentType!);
          } on FormatException catch (error) {
            throw RpcDecodeException(
                'invalid file content type "${blob.contentType}"',
                expected: 'MIME type',
                actual: blob.contentType,
                cause: error);
          }
        }
        multipart.files.add(http.MultipartFile(
          '$i',
          stream,
          length,
          filename: blob.filename,
          contentType: mime,
        ));
      }
      httpRequest = multipart;
    } else {
      final body = jsonEncode(serialized.envelope());
      final getQuery = <String, String>{...url.queryParameters, 'data': body};
      final useGet = request.kind == RpcProcedureKind.query &&
          url.replace(queryParameters: getQuery).toString().length <=
              maxUrlLength;
      if (useGet) {
        httpRequest =
            http.Request('GET', url.replace(queryParameters: getQuery))
              ..headers.addAll(headers);
      } else {
        httpRequest = http.Request('POST', url)
          ..headers.addAll(headers)
          ..headers['content-type'] = 'application/json'
          ..body = body;
        if (onSend != null) {
          final byteLength = utf8.encode(body).length;
          onSend(RpcTransferProgress(byteLength, totalBytes: byteLength));
        }
      }
    }

    final response = await _client.send(httpRequest);
    return _decodeResponse(response, request, abort);
  }

  Future<Object?> _decodeResponse(http.StreamedResponse response,
      RpcRequest request, Future<void>? abort) async {
    final status = response.statusCode;
    if (status >= 300 && status < 400) {
      throw RpcException(
        'unexpected redirect response (status $status): OrpcLink does not follow redirects',
        code: 'HTTP_$status',
        httpStatus: status,
      );
    }

    final onReceive = request.context?.onReceiveProgress;
    final total = response.contentLength;
    var received = 0;
    final counted = response.stream.map((chunk) {
      final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      received += bytes.length;
      onReceive?.call(RpcTransferProgress(received, totalBytes: total));
      return bytes;
    });

    if (status >= 400 || status < 200) {
      throw await _errorFromStream(counted, status, abort);
    }

    final contentType = response.headers['content-type'] ?? '';
    if (contentType.startsWith('text/event-stream')) {
      throw RpcDecodeException(
        'unexpected event-stream response for a unary call',
        expected: 'unary response',
        actual: 'text/event-stream',
      );
    }
    if (contentType.startsWith('multipart/form-data')) {
      final bytes = await _collect(counted, abort);
      final boundary = _boundary(contentType);
      if (boundary == null) {
        throw RpcDecodeException('multipart response without boundary');
      }
      final body = parseMultipart(bytes, boundary);
      final data = body.fields['data'];
      if (data == null) {
        throw RpcDecodeException('multipart response missing data field');
      }
      final envelope = RpcJson.asMap(RpcJson.parse(data));
      return _codec.deserialize(envelope, getBlob: (i) {
        if (i >= body.files.length) {
          throw RpcDecodeException('multipart part $i missing');
        }
        final part = body.files[i];
        return RpcFile.bytes(part.filename ?? 'blob', part.bytes,
            contentType: part.contentType);
      });
    }
    final disposition = response.headers['content-disposition'];
    if (disposition != null) {
      final bytes = await _collect(counted, abort);
      final filename = _filenameFromDisposition(disposition) ?? 'blob';
      final mime = contentType.split(';').first.trim();
      return RpcFile.bytes(filename, bytes,
          contentType: mime.isEmpty ? null : mime);
    }
    if (contentType.startsWith('application/json')) {
      final bytes = await _collect(counted, abort);
      final text = utf8.decode(bytes);
      if (text.isEmpty) return null;
      final parsed = RpcJson.parse(text);
      if (parsed is Map<String, Object?> && parsed.containsKey('json')) {
        return _codec.deserialize(parsed);
      }
      return parsed;
    }
    // Binary passthrough: oRPC 1.x sends ReadableStream<Uint8Array> root
    // outputs with no content-type at all; 2.x labels them octet-stream.
    return counted;
  }

  Future<Object?> _withLifecycle(
      RpcRequest request, Future<Object?> Function(Future<void>? abort) run) {
    final token = request.context?.cancelToken;
    final timeout = request.context?.timeout;
    if (token == null && timeout == null) return run(null);
    final completer = Completer<Object?>();
    final abort = Completer<void>();
    Timer? timer;
    void fire(RpcException error) {
      if (!abort.isCompleted) abort.complete();
      if (!completer.isCompleted) completer.completeError(error);
    }

    if (token != null) {
      unawaited(token.whenCancelled.then((_) =>
          fire(RpcCancelledException(token.reason ?? 'cancelled mid-flight'))));
    }
    if (timeout != null) {
      timer = Timer(timeout, () {
        fire(RpcTimeoutException(
            'operation exceeded the ${timeout.inMilliseconds}ms timeout'));
      });
    }
    unawaited(run(abort.future).then(
      (value) {
        timer?.cancel();
        if (!completer.isCompleted) completer.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        timer?.cancel();
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    ));
    return completer.future;
  }

  // --- shared helpers ------------------------------------------------------

  Uri _url(String path) {
    final encoded = path.split('.').map(Uri.encodeComponent).join('/');
    final base = endpoint.path.endsWith('/')
        ? endpoint.path.substring(0, endpoint.path.length - 1)
        : endpoint.path;
    return endpoint.replace(path: '$base/$encoded');
  }

  Object? _decodeEnvelopeText(String text) {
    final parsed = RpcJson.parse(text);
    if (parsed is Map<String, Object?> && parsed.containsKey('json')) {
      return _codec.deserialize(parsed);
    }
    return parsed;
  }

  RpcException _errorFromFrame(String data) {
    final decoded = _decodeEnvelopeText(data);
    if (decoded is Map<String, Object?> &&
        decoded['code'] is String &&
        decoded['message'] is String) {
      return RpcException.fromOrpcWire(decoded);
    }
    return RpcDecodeException('malformed oRPC error event');
  }

  Future<RpcException> _errorFromResponse(http.StreamedResponse response) =>
      _errorFromStream(response.stream, response.statusCode);

  Future<RpcException> _errorFromStream(Stream<List<int>> stream, int status,
      [Future<void>? abort]) async {
    try {
      final bytes = await _collect(stream, abort);
      final text = utf8.decode(bytes, allowMalformed: true);
      final parsed = RpcJson.parse(text);
      if (parsed is Map<String, Object?> && parsed.containsKey('json')) {
        final decoded = _codec.deserialize(parsed);
        if (decoded is Map<String, Object?> &&
            decoded['code'] is String &&
            decoded['message'] is String) {
          return RpcException.fromOrpcWire(decoded);
        }
      }
    } on RpcException {
      // Non-JSON or malformed error body: fall back to the status code.
    }
    return _statusException(status);
  }

  RpcException _statusException(int status) {
    final code = switch (status) {
      400 => 'BAD_REQUEST',
      401 => 'UNAUTHORIZED',
      403 => 'FORBIDDEN',
      404 => 'NOT_FOUND',
      405 => 'METHOD_NOT_SUPPORTED',
      406 => 'NOT_ACCEPTABLE',
      408 => 'TIMEOUT',
      409 => 'CONFLICT',
      412 => 'PRECONDITION_FAILED',
      413 => 'PAYLOAD_TOO_LARGE',
      415 => 'UNSUPPORTED_MEDIA_TYPE',
      422 => 'UNPROCESSABLE_CONTENT',
      429 => 'TOO_MANY_REQUESTS',
      499 => 'CLIENT_CLOSED_REQUEST',
      500 => 'INTERNAL_SERVER_ERROR',
      501 => 'NOT_IMPLEMENTED',
      502 => 'BAD_GATEWAY',
      503 => 'SERVICE_UNAVAILABLE',
      504 => 'GATEWAY_TIMEOUT',
      _ => 'MALFORMED_ORPC_ERROR_RESPONSE',
    };
    return RpcException('oRPC request failed with HTTP $status',
        code: code, httpStatus: status);
  }

  static Future<Uint8List> _collect(Stream<List<int>> stream,
      [Future<void>? abort]) async {
    final builder = BytesBuilder(copy: false);
    final sub = stream.listen(builder.add);
    if (abort != null) unawaited(abort.then((_) => sub.cancel()));
    try {
      await sub.asFuture<void>();
    } finally {
      await sub.cancel();
    }
    return builder.takeBytes();
  }

  /// Terminates an upload body when the call is aborted, so a cancelled
  /// upload stops pulling bytes from the source file stream.
  static Stream<Uint8List> _abortable(
      Stream<Uint8List> stream, Future<void>? abort) {
    if (abort == null) return stream;
    final out = StreamController<Uint8List>();
    final sub =
        stream.listen(out.add, onError: out.addError, onDone: out.close);
    unawaited(abort.then((_) {
      sub.cancel();
      out.close();
    }));
    return out.stream;
  }

  Future<http.StreamedResponse> _sendStreaming(
      http.BaseRequest httpRequest, Duration? timeout) {
    if (timeout == null) return _client.send(httpRequest);
    final gate = Completer<http.StreamedResponse>();
    final timer = Timer(timeout, () {
      if (!gate.isCompleted) {
        gate.completeError(RpcTimeoutException(
            'orpc event stream connect exceeded the ${timeout.inMilliseconds}ms timeout'));
      }
    });
    unawaited(_client.send(httpRequest).then((response) {
      timer.cancel();
      if (gate.isCompleted) {
        _discardResponse(response);
      } else {
        gate.complete(response);
      }
    }, onError: (Object error, StackTrace stackTrace) {
      timer.cancel();
      if (!gate.isCompleted) gate.completeError(error, stackTrace);
    }));
    return gate.future;
  }

  static void _discardResponse(http.StreamedResponse response) {
    unawaited(response.stream.listen(null).cancel());
  }

  static String? _boundary(String contentType) {
    for (final param in contentType.split(';').skip(1)) {
      final trimmed = param.trim();
      if (trimmed.toLowerCase().startsWith('boundary=')) {
        var value = trimmed.substring('boundary='.length);
        if (value.startsWith('"') && value.endsWith('"')) {
          value = value.substring(1, value.length - 1);
        }
        return value;
      }
    }
    return null;
  }

  static String? _filenameFromDisposition(String disposition) {
    final match = RegExp(r'filename="([^"]*)"', caseSensitive: false)
        .firstMatch(disposition);
    return match?.group(1);
  }
}
