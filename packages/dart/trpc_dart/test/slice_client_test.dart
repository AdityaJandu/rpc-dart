@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:trpc_dart/trpc_dart.dart';

/// Live wire verification against the Node fixture server. The vitest e2e
/// orchestrator starts the server and provides TRPC_FIXTURE_PORT; without it
/// these tests are skipped so `dart test` stays hermetic.
void main() {
  final port = Platform.environment['TRPC_FIXTURE_PORT'];
  if (port == null || port.isEmpty) {
    print('TRPC_FIXTURE_PORT not set - skipping live slice tests');
    return;
  }

  late RpcClient client;
  setUpAll(() {
    client = RpcClient(
      endpoint: Uri.parse('http://127.0.0.1:$port/trpc'),
      transformer: RpcTransformer.superjson,
      defaultHeaders: const {'authorization': 'Bearer u1'},
      links: [HttpBatchLink(endpoint: Uri.parse('http://127.0.0.1:$port/trpc'))],
    );
  });

  test('query round trip decodes Date/BigInt and the discriminated union', () async {
    final data = await client.execute(
      const RpcRequest(
        path: 'user.getById',
        kind: RpcProcedureKind.query,
        input: {'id': 'u1'},
      ),
    );
    final user = data as Map<String, Object?>;
    expect(user['id'], 'u1');
    expect(user['createdAt'], DateTime.utc(2026, 1, 15, 10));
    expect(user['balance'], BigInt.from(123));
    final payment = user['payment'] as Map<String, Object?>;
    expect(payment['type'], 'card');
    expect(user['sortHint'], 'asc');
  });

  test('concurrent queries batch into one demultiplexed response', () async {
    final results = await Future.wait<Object?>([
      client.execute(const RpcRequest(
        path: 'user.me',
        kind: RpcProcedureKind.query,
        input: null,
      )),
      client.execute(const RpcRequest(
        path: 'posts.list',
        kind: RpcProcedureKind.query,
        input: {'sort': 'asc'},
      )),
    ]);
    final me = results[0] as Map<String, Object?>;
    final posts = results[1] as Map<String, Object?>;
    expect(me['id'], 'u1');
    expect((posts['items'] as List<Object?>).length, 2);
    expect(posts['nextCursor'], isNull);
  });

  test('mutation accepts explicit null and absent optional-nullable fields', () async {
    final withNull = await client.execute(const RpcRequest(
      path: 'user.update',
      kind: RpcProcedureKind.mutation,
      input: {'name': 'Ada', 'nickname': null, 'charCount': 'abcde'},
    ));
    expect((withNull as Map<String, Object?>)['id'], 'u1');

    final withAbsent = await client.execute(const RpcRequest(
      path: 'user.update',
      kind: RpcProcedureKind.mutation,
      input: {'charCount': 'abcde'},
    ));
    expect((withAbsent as Map<String, Object?>)['id'], 'u1');
  });

  test('missing credentials surface as RpcUnauthorizedException', () async {
    final anonymous = RpcClient(
      endpoint: Uri.parse('http://127.0.0.1:$port/trpc'),
      transformer: RpcTransformer.superjson,
      links: [HttpBatchLink(endpoint: Uri.parse('http://127.0.0.1:$port/trpc'))],
    );
    await expectLater(
      anonymous.execute(const RpcRequest(
        path: 'user.getById',
        kind: RpcProcedureKind.query,
        input: {'id': 'u1'},
      )),
      throwsA(isA<RpcUnauthorizedException>()),
    );
  });

  test('cache watch + invalidate refetch through the live wire', () async {
    var calls = 0;
    final ref = client.cache.watch<Map<String, Object?>>(
      const RpcQueryKey(path: ['user']),
      () async {
        calls++;
        final data = await client.execute(const RpcRequest(
          path: 'user.me',
          kind: RpcProcedureKind.query,
          input: null,
        ));
        return data as Map<String, Object?>;
      },
    );

    final dataStates = <Map<String, Object?>>[];
    final sub = ref.stream.listen((state) {
      if (state is RpcAsyncData<Map<String, Object?>>) {
        dataStates.add(state.data);
      }
    });
    await ref.stream.firstWhere((s) => s is RpcAsyncData<Map<String, Object?>>);

    client.cache.invalidate(const RpcQueryKey(path: ['user']));
    await ref.stream
        .firstWhere((s) => s is RpcAsyncData<Map<String, Object?>>);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(calls, 2, reason: 'invalidate refetched the watched query');
    expect(dataStates.length, greaterThanOrEqualTo(2));
    expect(dataStates.last['id'], 'u1');
    await sub.cancel();
  });
}
