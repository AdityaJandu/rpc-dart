import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:trpc_dart/trpc_dart.dart';

void main() {
  group('cancellation inside HttpBatchLink', () {
    test('cancel before dispatch removes the operation without aborting siblings',
        () async {
      final served = <Uri>[];
      final client = RpcClient(
        endpoint: Uri.parse('http://localhost/trpc'),
        transformer: RpcTransformer.superjson,
        links: [
          HttpBatchLink(
            endpoint: Uri.parse('http://localhost/trpc'),
            client: MockClient((request) async {
              served.add(request.url);
              return http.Response(
                '{"result":{"data":{"json":{"id":"u1"}}}}',
                200,
              );
            }),
          ),
        ],
      );

      final token = CancelToken();
      final cancelled = client.execute(RpcRequest(
        path: 'user.getById',
        kind: RpcProcedureKind.query,
        input: const {'id': 'u1'},
        context: RpcCallContext(cancelToken: token),
      ));
      final sibling = client.execute(const RpcRequest(
        path: 'user.me',
        kind: RpcProcedureKind.query,
        input: null,
      ));
      token.cancel(reason: 'navigated away');

      await expectLater(cancelled, throwsA(isA<RpcCancelledException>()));
      final result = await sibling;
      expect(result, isA<Map<String, Object?>>());
      // Only the sibling reached the wire: the cancelled op was removed
      // before dispatch, so the batch contained a single operation.
      expect(served, hasLength(1));
      expect(served.single.path, '/trpc/user.me');
    });

    test('cancel mid-flight resolves the caller immediately; siblings complete',
        () async {
      final gate = Completer<void>();
      final client = RpcClient(
        endpoint: Uri.parse('http://localhost/trpc'),
        transformer: RpcTransformer.superjson,
        links: [
          HttpBatchLink(
            endpoint: Uri.parse('http://localhost/trpc'),
            client: MockClient((request) async {
              // All three operations share one batch; transport is slow.
              await gate.future;
              return http.Response(
                '['
                '{"result":{"data":{"json":{"id":"u1"}}}},'
                '{"result":{"data":{"json":{"id":"u2"}}}},'
                '{"result":{"data":{"json":{"items":[],"nextCursor":null}}}}'
                ']',
                200,
              );
            }),
          ),
        ],
      );

      final token = CancelToken();
      final inFlight = client.execute(RpcRequest(
        path: 'user.getById',
        kind: RpcProcedureKind.query,
        input: const {'id': 'u1'},
        context: RpcCallContext(cancelToken: token),
      ));
      final sibling = client.execute(const RpcRequest(
        path: 'user.me',
        kind: RpcProcedureKind.query,
        input: null,
      ));
      final untouched = client.execute(const RpcRequest(
        path: 'posts.list',
        kind: RpcProcedureKind.query,
        input: {'sort': 'asc'},
      ));

      // Let the batch dispatch first, then cancel one caller mid-flight.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      token.cancel(reason: 'left the screen');

      await expectLater(inFlight, throwsA(isA<RpcCancelledException>()));
      gate.complete();
      final me = await sibling;
      expect((me as Map<String, Object?>)['id'], 'u2');
      final posts = await untouched;
      expect(posts, isA<Map<String, Object?>>());
    });
  });

  group('timeouts', () {
    test('timeout resolves the caller with RpcTimeoutException', () async {
      final client = RpcClient(
        endpoint: Uri.parse('http://localhost/trpc'),
        transformer: RpcTransformer.superjson,
        links: [
          ContextLink(),
          HttpBatchLink(
            endpoint: Uri.parse('http://localhost/trpc'),
            client: MockClient((request) async {
              await Future<void>.delayed(const Duration(milliseconds: 400));
              return http.Response(
                '{"result":{"data":{"json":{"id":"u1"}}}}',
                200,
              );
            }),
          ),
        ],
      );

      final started = DateTime.now();
      await expectLater(
        client.execute(const RpcRequest(
          path: 'user.me',
          kind: RpcProcedureKind.query,
          input: null,
          context: RpcCallContext(timeout: Duration(milliseconds: 50)),
        )),
        throwsA(isA<RpcTimeoutException>()),
      );
      expect(
        DateTime.now().difference(started).inMilliseconds,
        lessThan(350),
        reason: 'timeout resolves promptly, not after the transport finishes',
      );
    });
  });
}
