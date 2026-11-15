import 'package:test/test.dart';
import 'package:trpc_dart/trpc_dart.dart';

/// Counts attempts per path and scripts failures before success.
class ScriptedTransport extends RpcLink {
  ScriptedTransport({this.failure, this.failTimes = 0});

  /// The error to throw for the first [failTimes] attempts of every path.
  final RpcException? failure;
  final int failTimes;
  final Map<String, int> attempts = <String, int>{};
  final List<Duration> delays = <Duration>[];
  final List<RpcRequest> requests = <RpcRequest>[];

  @override
  bool get isTermination => true;

  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) async {
    requests.add(request);
    final count = (attempts[request.path] ?? 0) + 1;
    attempts[request.path] = count;
    final failure = this.failure;
    if (failure != null && count <= failTimes) {
      throw failure;
    }
    return 'ok-$count';
  }
}

RpcClient clientWith(
  ScriptedTransport transport, {
  RpcRetryPolicy policy = const RpcRetryPolicy(),
}) {
  return RpcClient(
    endpoint: Uri.parse('http://localhost/trpc'),
    links: [
      RetryLink(policy: policy, sleep: (delay) async => transport.delays.add(delay)),
      transport,
    ],
  );
}

void main() {
  group('RetryLink: queries', () {
    test('retries network failures with exponential backoff then succeeds', () async {
      final transport = ScriptedTransport(
        failure: RpcNetworkException('socket dropped'),
        failTimes: 2,
      );
      final client = clientWith(
        transport,
        policy: const RpcRetryPolicy(maxAttempts: 3, backoff: Duration(milliseconds: 100)),
      );

      final result = await client.execute(const RpcRequest(
        path: 'user.getById',
        kind: RpcProcedureKind.query,
        input: {'id': 'u1'},
      ));

      expect(result, 'ok-3');
      expect(transport.attempts['user.getById'], 3);
      expect(transport.delays, [
        const Duration(milliseconds: 100),
        const Duration(milliseconds: 200),
      ]);
    });

    test('retries rate limiting and transient server errors', () async {
      final cases = <String, RpcException>{
        'a.ratelimit': RpcTooManyRequestsException('slow down'),
        'b.unavailable': RpcServiceUnavailableException('down'),
        'c.gateway': RpcGatewayTimeoutException('gateway'),
        'd.timeout': RpcTimeoutException('timed out'),
      };
      for (final entry in cases.entries) {
        final transport = ScriptedTransport(failure: entry.value, failTimes: 1);
        final client = clientWith(transport, policy: const RpcRetryPolicy(maxAttempts: 2));
        final result = await client.execute(RpcRequest(
          path: entry.key,
          kind: RpcProcedureKind.query,
          input: null,
        ));
        expect(result, 'ok-2', reason: '${entry.key} should be retryable');
        expect(transport.attempts[entry.key], 2);
      }
    });

    test('rethrows after max attempts', () async {
      final transport = ScriptedTransport(
        failure: RpcNetworkException('socket dropped'),
        failTimes: 99,
      );
      final client = clientWith(transport, policy: const RpcRetryPolicy(maxAttempts: 3));

      await expectLater(
        client.execute(const RpcRequest(
          path: 'user.getById',
          kind: RpcProcedureKind.query,
          input: null,
        )),
        throwsA(isA<RpcNetworkException>()),
      );
      expect(transport.attempts['user.getById'], 3);
    });

    test('never retries permanent 4xx errors', () async {
      final transport = ScriptedTransport(
        failure: RpcBadRequestException('nope'),
        failTimes: 99,
      );
      final client = clientWith(transport, policy: const RpcRetryPolicy(maxAttempts: 3));

      await expectLater(
        client.execute(const RpcRequest(
          path: 'user.getById',
          kind: RpcProcedureKind.query,
          input: null,
        )),
        throwsA(isA<RpcBadRequestException>()),
      );
      expect(transport.attempts['user.getById'], 1);
      expect(transport.delays, isEmpty);
    });

    test('honors a custom retryable predicate', () async {
      final transport = ScriptedTransport(failure: RpcNotFoundException('gone'), failTimes: 1);
      final client = RpcClient(
        endpoint: Uri.parse('http://localhost/trpc'),
        links: [
          RetryLink(
            policy: RpcRetryPolicy(
              maxAttempts: 2,
              retryable: (error) => error.code == 'NOT_FOUND',
            ),
            sleep: (delay) async => transport.delays.add(delay),
          ),
          transport,
        ],
      );

      final result = await client.execute(const RpcRequest(
        path: 'user.getById',
        kind: RpcProcedureKind.query,
        input: null,
      ));
      expect(result, 'ok-2');
    });
  });

  group('RetryLink: mutation safety', () {
    test('mutations never retry without an idempotency key', () async {
      final transport = ScriptedTransport(
        failure: RpcNetworkException('socket dropped'),
        failTimes: 2,
      );
      final client = clientWith(transport, policy: const RpcRetryPolicy(maxAttempts: 3));

      await expectLater(
        client.execute(const RpcRequest(
          path: 'user.update',
          kind: RpcProcedureKind.mutation,
          input: {'name': 'Ada'},
        )),
        throwsA(isA<RpcNetworkException>()),
      );
      expect(transport.attempts['user.update'], 1);
      expect(transport.delays, isEmpty);
    });

    test('mutations retry when an idempotency key is provided', () async {
      final transport = ScriptedTransport(
        failure: RpcNetworkException('socket dropped'),
        failTimes: 1,
      );
      final client = clientWith(transport, policy: const RpcRetryPolicy(maxAttempts: 3));

      final result = await client.execute(const RpcRequest(
        path: 'user.update',
        kind: RpcProcedureKind.mutation,
        input: {'name': 'Ada'},
        context: RpcCallContext(idempotencyKey: 'op-1'),
      ));
      expect(result, 'ok-2');
      expect(transport.attempts['user.update'], 2);
    });

    test('mutations retry when explicitly marked retryable', () async {
      final transport = ScriptedTransport(
        failure: RpcNetworkException('socket dropped'),
        failTimes: 1,
      );
      final client = clientWith(transport, policy: const RpcRetryPolicy(maxAttempts: 2));

      final result = await client.execute(const RpcRequest(
        path: 'user.update',
        kind: RpcProcedureKind.mutation,
        input: {'name': 'Ada'},
        context: RpcCallContext(retryable: true),
      ));
      expect(result, 'ok-2');
    });
  });

  group('RetryLink: correlation', () {
    test('retries reuse the same x-request-id', () async {
      final transport = ScriptedTransport(
        failure: RpcNetworkException('socket dropped'),
        failTimes: 1,
      );
      final client = RpcClient(
        endpoint: Uri.parse('http://localhost/trpc'),
        links: [
          ContextLink(),
          RetryLink(policy: const RpcRetryPolicy(maxAttempts: 2)),
          transport,
        ],
      );
      await client.execute(const RpcRequest(
        path: 'user.getById',
        kind: RpcProcedureKind.query,
        input: null,
      ));
      final ids = transport.requests
          .map((r) => r.context?.headers['x-request-id'])
          .toList();
      expect(ids.length, 2);
      expect(ids.first, isNotNull);
      expect(ids.toSet().length, 1, reason: 'one logical operation, one correlation id');
    });
  });
}
