import 'package:test/test.dart';
import 'package:trpc_dart/trpc_dart.dart';

class OkTransport extends RpcLink {
  @override
  bool get isTermination => true;

  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) async => 'ok';
}

class FailingTransport extends RpcLink {
  @override
  bool get isTermination => true;

  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) async {
    throw RpcNetworkException('boom');
  }
}

void main() {
  group('LoggingLink', () {
    test('emits request and response events with durations', () async {
      final events = <RpcLogEvent>[];
      final client = RpcClient(
        endpoint: Uri.parse('http://localhost/trpc'),
        links: [LoggingLink(onEvent: events.add), OkTransport()],
      );

      await client.execute(const RpcRequest(
        path: 'user.getById',
        kind: RpcProcedureKind.query,
        input: null,
      ));

      expect(events, hasLength(2));
      expect(events[0].event, 'request');
      expect(events[0].path, 'user.getById');
      expect(events[1].event, 'response');
      expect(events[1].durationMs, greaterThanOrEqualTo(0));
    });

    test('emits an error event and rethrows', () async {
      final events = <RpcLogEvent>[];
      final client = RpcClient(
        endpoint: Uri.parse('http://localhost/trpc'),
        links: [LoggingLink(onEvent: events.add), FailingTransport()],
      );

      await expectLater(
        client.execute(const RpcRequest(
          path: 'user.update',
          kind: RpcProcedureKind.mutation,
          input: null,
        )),
        throwsA(isA<RpcNetworkException>()),
      );

      expect(events, hasLength(2));
      expect(events[0].event, 'request');
      expect(events[1].event, 'error');
      expect(events[1].error, isA<RpcNetworkException>());
      expect(events[1].durationMs, greaterThanOrEqualTo(0));
    });

    test('redacts secret headers case-insensitively plus custom names',
        () async {
      final logged = <RpcLogEvent>[];
      final client = RpcClient(
        endpoint: Uri.parse('http://localhost/trpc'),
        links: [
          ContextLink(),
          LoggingLink(onEvent: logged.add, redactHeaders: {'x-internal-token'}),
          OkTransport(),
        ],
      );

      await client.execute(const RpcRequest(
        path: 'user.me',
        kind: RpcProcedureKind.query,
        input: null,
        context: RpcCallContext(headers: <String, String>{
          'Authorization': 'Bearer secret',
          'COOKIE': 'session=abc',
          'x-API-key': 'key123',
          'X-Internal-Token': 'tok',
          'x-org-id': 'org_99',
        }),
      ));

      final headers = logged.first.headers;
      expect(headers['Authorization'], '[REDACTED]');
      expect(headers['COOKIE'], '[REDACTED]');
      expect(headers['x-API-key'], '[REDACTED]');
      expect(headers['X-Internal-Token'], '[REDACTED]');
      expect(headers['x-org-id'], 'org_99');
      expect(headers['x-request-id'], isNotNull);

      // No secret value anywhere in the serialized events.
      final serialized = logged.map((e) => e.toString()).join();
      expect(serialized.contains('secret'), isFalse);
      expect(serialized.contains('key123'), isFalse);
      expect(serialized.contains('session=abc'), isFalse);
    });
  });
}
