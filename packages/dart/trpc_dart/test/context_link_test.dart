import 'package:test/test.dart';
import 'package:trpc_dart/trpc_dart.dart';

class RecordingTransport extends RpcLink {
  final List<RpcRequest> requests = <RpcRequest>[];

  @override
  bool get isTermination => true;

  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) async {
    requests.add(request);
    return 'ok';
  }
}

void main() {
  group('ContextLink merge precedence', () {
    test('per-call > dynamic > client defaults (auth handled by AuthLink)', () async {
      final transport = RecordingTransport();
      final client = RpcClient(
        endpoint: Uri.parse('http://localhost/trpc'),
        defaultHeaders: {'x-client': 'client', 'x-shared': 'from-client'},
        links: [
          ContextLink(dynamicHeaders: () async => {'x-shared': 'from-dynamic', 'x-dynamic': 'd1'}),
          transport,
        ],
      );

      await client.execute(const RpcRequest(
        path: 'user.me',
        kind: RpcProcedureKind.query,
        input: null,
        context: RpcCallContext(headers: {'x-shared': 'from-call', 'x-call': 'c1'}),
      ));

      final headers = transport.single.context!.headers;
      expect(headers['x-shared'], 'from-call', reason: 'per-call wins');
      expect(headers['x-dynamic'], 'd1');
      expect(headers['x-client'], 'client');
      expect(headers['x-call'], 'c1');
    });

    test('dynamic overrides client defaults when per-call is silent', () async {
      final transport = RecordingTransport();
      final client = RpcClient(
        endpoint: Uri.parse('http://localhost/trpc'),
        defaultHeaders: {'x-client': 'client'},
        links: [
          ContextLink(dynamicHeaders: () async => {'x-client': 'dynamic'}),
          transport,
        ],
      );

      await client.execute(const RpcRequest(
        path: 'user.me',
        kind: RpcProcedureKind.query,
        input: null,
      ));

      expect(transport.single.context!.headers['x-client'], 'dynamic');
    });

    test('per-call wins over client defaults without any dynamic source', () async {
      final transport = RecordingTransport();
      final client = RpcClient(
        endpoint: Uri.parse('http://localhost/trpc'),
        defaultHeaders: {'x-client': 'client'},
        links: [transport],
      );

      await client.execute(const RpcRequest(
        path: 'user.me',
        kind: RpcProcedureKind.query,
        input: null,
        context: RpcCallContext(headers: {'x-client': 'call'}),
      ));

      expect(transport.single.context!.headers['x-client'], 'call');
    });
  });

  group('x-request-id correlation', () {
    test('generated when absent, unique per call', () async {
      final transport = RecordingTransport();
      final client = RpcClient(
        endpoint: Uri.parse('http://localhost/trpc'),
        links: [ContextLink(), transport],
      );

      await client.execute(const RpcRequest(
        path: 'user.me', kind: RpcProcedureKind.query, input: null));
      await client.execute(const RpcRequest(
        path: 'user.me', kind: RpcProcedureKind.query, input: null));

      final a = transport.requests[0].header('x-request-id');
      final b = transport.requests[1].header('x-request-id');
      expect(a, isNotNull);
      expect(b, isNotNull);
      expect(a, isNot(b));
    });

    test('propagated when provided by the caller', () async {
      final transport = RecordingTransport();
      final client = RpcClient(
        endpoint: Uri.parse('http://localhost/trpc'),
        links: [ContextLink(), transport],
      );

      await client.execute(const RpcRequest(
        path: 'user.me',
        kind: RpcProcedureKind.query,
        input: null,
        context: RpcCallContext(headers: {'x-request-id': 'trace-42'}),
      ));

      expect(transport.single.header('x-request-id'), 'trace-42');
    });
  });
}

extension on RecordingTransport {
  RpcRequest get single => requests.single;
}

extension on RpcRequest {
  String? header(String name) => context?.headers[name];
}
