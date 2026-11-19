import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:trpc_dart/trpc_dart.dart';

/// Captures sent requests and replays programmed responses.
class FakeHttpClient extends http.BaseClient {
  final List<http.BaseRequest> sent = [];
  final List<FutureOr<http.StreamedResponse> Function(http.BaseRequest request)>
      _routes = [];

  void route(
      FutureOr<http.StreamedResponse> Function(http.BaseRequest request)
          handler) {
    _routes.add(handler);
  }

  void reply(
    Object? body, {
    int status = 200,
    Map<String, String> headers = const {},
    int? contentLength,
  }) {
    route((_) => streamed(body,
        status: status, headers: headers, contentLength: contentLength));
  }

  static http.StreamedResponse streamed(
    Object? body, {
    int status = 200,
    Map<String, String> headers = const {},
    int? contentLength,
  }) {
    final Stream<List<int>> stream;
    if (body is Stream<List<int>>) {
      stream = body;
    } else if (body is List<int>) {
      stream = Stream<List<int>>.value(body);
    } else if (body is String) {
      stream = Stream<List<int>>.value(utf8.encode(body));
    } else {
      stream = const Stream<List<int>>.empty();
    }
    // Real servers label JSON bodies; the headerless case is binary passthrough.
    final effectiveHeaders = <String, String>{
      if (body is String && !headers.containsKey('content-type'))
        'content-type': 'application/json',
      ...headers,
    };
    return http.StreamedResponse(
      stream,
      status,
      headers: effectiveHeaders,
      contentLength: contentLength,
      request: http.Request('POST', Uri.parse('https://x.dev/rpc')),
    );
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent.add(request);
    // Consume the body like a real client so upload progress streams run.
    await request.finalize().drain<void>();
    if (_routes.isEmpty) {
      throw StateError('no programmed response for ${request.url}');
    }
    return _routes.removeAt(0)(request);
  }
}

RpcRequest req(
  String path, {
  RpcProcedureKind kind = RpcProcedureKind.mutation,
  Object? input,
  RpcCallContext? context,
}) =>
    RpcRequest(path: path, kind: kind, input: input, context: context);

/// Starts consuming the upload body but never responds until released, so a
/// test can observe whether cancellation stops the file stream being read.
class UploadingClient extends http.BaseClient {
  final responseGate = Completer<http.StreamedResponse>();
  StreamSubscription<List<int>>? bodySub;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    bodySub = request.finalize().listen((_) {});
    return responseGate.future;
  }
}

void main() {
  late FakeHttpClient client;
  late OrpcLink link;

  setUp(() {
    client = FakeHttpClient();
    link = OrpcLink(endpoint: Uri.parse('https://x.dev/rpc'), client: client);
  });

  group('OrpcLink unary JSON', () {
    test('POSTs the {json, meta} envelope to the slash-delimited path',
        () async {
      client.reply('{"json":{"ok":true}}');
      final out = await link.invoke(
        req('planet.create', input: <String, Object?>{'name': 'Earth'}),
        (_) => throw StateError('termination'),
      );
      final sent = client.sent.single;
      expect(sent.method, 'POST');
      expect(sent.url.toString(), 'https://x.dev/rpc/planet/create');
      expect(sent.headers['content-type'], contains('application/json'));
      expect(jsonDecode((sent as http.Request).body), {
        'json': {'name': 'Earth'}
      });
      expect(out, {'ok': true});
    });

    test('queries use GET with ?data= when the URL fits', () async {
      client.reply('{"json":"pong"}');
      await link.invoke(
        req('planet.find',
            kind: RpcProcedureKind.query, input: <String, Object?>{'id': 1}),
        (_) => throw StateError('termination'),
      );
      final sent = client.sent.single;
      expect(sent.method, 'GET');
      expect(sent.url.path, '/rpc/planet/find');
      expect(sent.url.queryParameters['data'], '{"json":{"id":1}}');
    });

    test('long query inputs fall back to POST beyond maxUrlLength', () async {
      client.reply('{"json":null}');
      await link.invoke(
        req('planet.find',
            kind: RpcProcedureKind.query,
            input: <String, Object?>{'q': 'x' * 3000}),
        (_) => throw StateError('termination'),
      );
      expect(client.sent.single.method, 'POST');
    });

    test('restores meta-tagged types in responses', () async {
      client.reply(
          '{"json":{"at":"2022-01-01T00:00:00.000Z","id":"10"},"meta":[[1,"at"],[0,"id"]]}');
      final out = await link.invoke(
        req('planet.find', kind: RpcProcedureKind.query),
        (_) => throw StateError('termination'),
      ) as Map<String, Object?>;
      expect(out['at'], DateTime.utc(2022, 1, 1));
      expect(out['id'], BigInt.from(10));
    });

    test('null input sends an empty envelope', () async {
      client.reply('{"json":null}');
      await link.invoke(req('health'), (_) => throw StateError('termination'));
      final sent = client.sent.single as http.Request;
      expect(sent.body, '{}');
    });

    test('GET preserves existing endpoint query parameters', () async {
      final qLink = OrpcLink(
          endpoint: Uri.parse('https://x.dev/rpc?tenant=acme'), client: client);
      client.reply('{"json":"pong"}');
      await qLink.invoke(
        req('planet.find',
            kind: RpcProcedureKind.query, input: <String, Object?>{'id': 1}),
        (_) => throw StateError('termination'),
      );
      final sent = client.sent.single;
      expect(sent.method, 'GET');
      expect(sent.url.queryParameters['tenant'], 'acme');
      expect(sent.url.queryParameters['data'], '{"json":{"id":1}}');
    });
  });

  group('OrpcLink multipart uploads', () {
    test('sends data field with maps plus indexed file parts', () async {
      client.reply('{"json":{"url":"https://cdn/x"}}');
      final out = await link.invoke(
        req('uploads.avatar', input: <String, Object?>{
          'file': RpcFile.bytes('a.png', Uint8List.fromList([1, 2, 3]),
              contentType: 'image/png'),
        }),
        (_) => throw StateError('termination'),
      );
      final sent = client.sent.single as http.MultipartRequest;
      expect(sent.url.toString(), 'https://x.dev/rpc/uploads/avatar');
      final data = jsonDecode(sent.fields['data']!) as Map<String, Object?>;
      expect(data['maps'], [
        ['file']
      ]);
      expect(data['json'], {
        'file': <String, Object?>{},
      });
      expect(sent.files.length, 1);
      expect(sent.files.single.field, '0');
      expect(sent.files.single.filename, 'a.png');
      expect(sent.files.single.contentType.mimeType, 'image/png');
      expect(out, {'url': 'https://cdn/x'});
    });

    test('reports cumulative send progress with known totals', () async {
      client.reply('{"json":null}');
      final progress = <RpcTransferProgress>[];
      await link.invoke(
        req('uploads.raw',
            input: Uint8List.fromList(List.filled(1000, 7)),
            context: RpcCallContext(onSendProgress: progress.add)),
        (_) => throw StateError('termination'),
      );
      expect(progress, isNotEmpty);
      expect(progress.last.transferredBytes, 1000);
      expect(progress.last.totalBytes, 1000);
      expect(progress.last.fraction, 1.0);
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i].transferredBytes,
            greaterThanOrEqualTo(progress[i - 1].transferredBytes));
      }
    });

    test('wraps an invalid upload MIME type as RpcDecodeException', () async {
      client.reply('{"json":null}');
      await expectLater(
        link.invoke(
          req('uploads.avatar', input: <String, Object?>{
            'file': RpcFile.bytes('a.png', Uint8List.fromList([1]),
                contentType: 'not-a-mime'),
          }),
          (_) => throw StateError('termination'),
        ),
        throwsA(isA<RpcDecodeException>()),
      );
    });
  });

  group('OrpcLink binary downloads', () {
    test('buffers raw file responses with Content-Disposition metadata',
        () async {
      client.reply(
        Uint8List.fromList([1, 2, 3, 4]),
        headers: {
          'content-type': 'image/png',
          'content-disposition': 'attachment; filename="earth.png"',
          'standard-server': 'file',
        },
        contentLength: 4,
      );
      final progress = <RpcTransferProgress>[];
      final out = await link.invoke(
        req('files.download',
            kind: RpcProcedureKind.query,
            context: RpcCallContext(onReceiveProgress: progress.add)),
        (_) => throw StateError('termination'),
      );
      final file = out as RpcFile;
      expect(file.filename, 'earth.png');
      expect(file.contentType, 'image/png');
      expect(await file.readBytes(), Uint8List.fromList([1, 2, 3, 4]));
      expect(progress.last.transferredBytes, 4);
      expect(progress.last.totalBytes, 4);
    });

    test('passes octet-stream responses through as a counted byte stream',
        () async {
      final controller = StreamController<List<int>>();
      client.reply(
        controller.stream,
        headers: {
          'content-type': 'application/octet-stream',
          'standard-server': 'octet-stream',
        },
      );
      final progress = <RpcTransferProgress>[];
      final out = await link.invoke(
        req('files.stream',
            kind: RpcProcedureKind.query,
            context: RpcCallContext(onReceiveProgress: progress.add)),
        (_) => throw StateError('termination'),
      );
      expect(out, isA<Stream<Uint8List>>());
      controller.add([1, 2]);
      controller.add([3]);
      unawaited(controller.close());
      expect(await (out as Stream<Uint8List>).toList(), [
        [1, 2],
        [3]
      ]);
      expect(progress.last.transferredBytes, 3);
    });

    test('parses multipart responses into trees with file parts', () async {
      const boundary = '----rpcdart';
      final body = '--$boundary\r\n'
          'content-disposition: form-data; name="data"\r\n\r\n'
          '{"json":{"name":"Earth","avatar":{}},"maps":[["avatar"]]}\r\n'
          '--$boundary\r\n'
          'content-disposition: form-data; name="0"; filename="a.png"\r\n'
          'content-type: image/png\r\n\r\n'
          'BINARY\r\n'
          '--$boundary--\r\n';
      client.reply(
        body,
        headers: {'content-type': 'multipart/form-data; boundary=$boundary'},
      );
      final out = await link.invoke(
        req('files.bundle', kind: RpcProcedureKind.query),
        (_) => throw StateError('termination'),
      ) as Map<String, Object?>;
      expect(out['name'], 'Earth');
      final avatar = out['avatar'] as RpcFile;
      expect(avatar.filename, 'a.png');
      expect(avatar.contentType, 'image/png');
      expect(await avatar.readBytes(), utf8.encode('BINARY'));
    });

    test('root-file multipart responses (empty-path maps) yield the file',
        () async {
      const boundary = '----rpcdart';
      final body = '--$boundary\r\n'
          'content-disposition: form-data; name="data"\r\n\r\n'
          '{"json":{},"maps":[[]]}\r\n'
          '--$boundary\r\n'
          'content-disposition: form-data; name="0"; filename="earth.png"\r\n'
          'content-type: image/png\r\n\r\n'
          'PNG\r\n'
          '--$boundary--\r\n';
      client.reply(
        body,
        headers: {'content-type': 'multipart/form-data; boundary=$boundary'},
      );
      final out = await link.invoke(
        req('files.download', kind: RpcProcedureKind.query),
        (_) => throw StateError('termination'),
      );
      final file = out as RpcFile;
      expect(file.filename, 'earth.png');
      expect(file.contentType, 'image/png');
      expect(await file.readBytes(), utf8.encode('PNG'));
    });

    test('headerless binary responses pass through as byte streams (1.16.3)',
        () async {
      client.reply(Uint8List.fromList([1, 2, 3]));
      final out = await link.invoke(
        req('files.stream', kind: RpcProcedureKind.query),
        (_) => throw StateError('termination'),
      );
      expect(out, isA<Stream<Uint8List>>());
      expect(await (out as Stream<Uint8List>).toList(), [
        [1, 2, 3]
      ]);
    });
  });

  group('OrpcLink errors', () {
    test('maps ORPCError envelopes to typed exceptions', () async {
      client.reply(
        '{"json":{"defined":true,"code":"NOT_FOUND","status":404,"message":"no planet","data":{"id":"9"}},"meta":[[0,"data","id"]]}',
        status: 404,
        headers: {'content-type': 'application/json'},
      );
      await expectLater(
        link.invoke(req('planet.find'), (_) => throw StateError('termination')),
        throwsA(isA<RpcNotFoundException>()
            .having((e) => e.defined, 'defined', isTrue)
            .having((e) => e.httpStatus, 'httpStatus', 404)
            .having((e) => e.data, 'data', {'id': BigInt.from(9)})),
      );
    });

    test('non-conforming error bodies fall back to status codes', () async {
      client.reply('<html>bad gateway</html>',
          status: 502, headers: {'content-type': 'text/html'});
      await expectLater(
        link.invoke(req('planet.find'), (_) => throw StateError('termination')),
        throwsA(
            isA<RpcException>().having((e) => e.httpStatus, 'httpStatus', 502)),
      );
    });

    test('rejects redirect responses', () async {
      client.reply('', status: 302, headers: {'location': 'https://elsewhere'});
      await expectLater(
        link.invoke(req('planet.find'), (_) => throw StateError('termination')),
        throwsA(isA<RpcException>()),
      );
    });
  });

  group('OrpcLink cancellation and timeout', () {
    test('cancel token aborts in-flight calls with the reason', () async {
      final gate = Completer<void>();
      client.route((_) {
        return gate.future.then((_) => FakeHttpClient.streamed('{"json":1}'));
      });
      final token = CancelToken();
      final future = link.invoke(
        req('slow.op', context: RpcCallContext(cancelToken: token)),
        (_) => throw StateError('termination'),
      );
      token.cancel(reason: 'user left');
      await expectLater(
        future,
        throwsA(isA<RpcCancelledException>()
            .having((e) => e.message, 'message', contains('user left'))),
      );
      gate.complete();
    });

    test('per-call timeout surfaces RpcTimeoutException', () async {
      final gate = Completer<void>();
      client.route((_) {
        return gate.future.then((_) => FakeHttpClient.streamed('{"json":1}'));
      });
      await expectLater(
        link.invoke(
          req('slow.op',
              context:
                  const RpcCallContext(timeout: Duration(milliseconds: 20))),
          (_) => throw StateError('termination'),
        ),
        throwsA(isA<RpcTimeoutException>()),
      );
      gate.complete();
    });
  });

  group('OrpcLink transport abort', () {
    test('cancel cancels the response stream subscription', () async {
      final body = StreamController<List<int>>();
      client.reply(body.stream, headers: {'content-type': 'application/json'});
      final token = CancelToken();
      final future = link.invoke(
        req('slow.op', context: RpcCallContext(cancelToken: token)),
        (_) => throw StateError('termination'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(body.hasListener, isTrue);
      token.cancel(reason: 'stop');
      await expectLater(future, throwsA(isA<RpcCancelledException>()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(body.hasListener, isFalse);
      await body.close();
    });

    test('timeout cancels the response stream subscription', () async {
      final body = StreamController<List<int>>();
      client.reply(body.stream, headers: {'content-type': 'application/json'});
      final future = link.invoke(
        req('slow.op',
            context: const RpcCallContext(timeout: Duration(milliseconds: 20))),
        (_) => throw StateError('termination'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(body.hasListener, isTrue);
      await expectLater(future, throwsA(isA<RpcTimeoutException>()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(body.hasListener, isFalse);
      await body.close();
    });

    test('cancel stops reading the upload file stream', () async {
      final upload = UploadingClient();
      final uLink =
          OrpcLink(endpoint: Uri.parse('https://x.dev/rpc'), client: upload);
      final source = StreamController<Uint8List>();
      final token = CancelToken();
      final future = uLink.invoke(
        req('uploads.big',
            input: <String, Object?>{
              'file': RpcFile.stream('a.bin', source.stream, length: 1 << 20),
            },
            context: RpcCallContext(cancelToken: token)),
        (_) => throw StateError('termination'),
      );
      source.add(Uint8List.fromList([1, 2, 3]));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(source.hasListener, isTrue);
      token.cancel(reason: 'stop');
      await expectLater(future, throwsA(isA<RpcCancelledException>()));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(source.hasListener, isFalse);
      upload.responseGate.complete(FakeHttpClient.streamed('{"json":null}'));
      await source.close();
    });
  });
}
