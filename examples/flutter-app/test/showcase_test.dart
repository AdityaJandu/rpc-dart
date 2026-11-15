import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trpc_dart/trpc_dart.dart';
import 'package:trpc_flutter/trpc_flutter.dart';

import 'package:example_flutter_app/src/api/api.dart';

/// Full-stack test: boots the example Fastify server as a child process and
/// exercises the generated bindings over the real wire.

void main() {
  late Process server;
  late int port;
  late Api api;

  setUpAll(() async {
    final script = Directory.current.uri
        .resolve('../trpc-fastify/scripts/server-child.mjs');
    server = await Process.start('node', [script.toFilePath()],
        workingDirectory:
            Directory.current.uri.resolve('../trpc-fastify').toFilePath());
    final ready = Completer<int>();
    server.stdout
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final match = RegExp(r'FIXTURE_PORT=(\d+)').firstMatch(line);
      if (match != null && !ready.isCompleted) {
        ready.complete(int.parse(match.group(1)!));
      }
    });
    port = await ready.future.timeout(const Duration(seconds: 20));

    api = Api(
      RpcClient(
        endpoint: Uri.parse('http://127.0.0.1:$port/trpc'),
        transformer: RpcTransformer.superjson,
        defaultHeaders: const {'authorization': 'Bearer demo-token'},
        links: [
          ContextLink(dynamicHeaders: () async => {'x-test': '1'}),
          HttpBatchLink(endpoint: Uri.parse('http://127.0.0.1:$port/trpc')),
        ],
      ),
    );
  });

  tearDownAll(() {
    server.kill();
  });

  test('health query', () async {
    final health = await api.health.query();
    expect(health.ok, isTrue);
  });

  test('typed user query decodes Date/BigInt/discriminated union', () async {
    final user = await api.user.me.query();
    expect(user.id, 'u1');
    expect(user.createdAt, DateTime.utc(2026, 1, 15, 10));
    expect(user.balance, BigInt.from(4200));
    expect(user.receipt, isA<UserGetByIdOutputReceiptCard>());
    expect((user.receipt as UserGetByIdOutputReceiptCard).last4, '4242');
  });

  test('mutation with PATCH semantics (absent vs null)', () async {
    final updated = await api.user.update.mutate(
      const UserUpdateInput(promoCode: 'demo', nickname: RpcNull()),
    );
    expect(updated.id, 'u1');

    final absent = await api.user.update.mutate(
      const UserUpdateInput(promoCode: 'demo'),
    );
    expect(absent.id, 'u1');
  });

  test('cursor pagination across pages', () async {
    final page1 = await api.posts.list
        .query(const PostsListInput(sort: PostsListInputSort.asc));
    expect(page1.items, hasLength(2));
    expect(page1.nextCursor, isNotNull);

    final page2 = await api.posts.list.query(
      PostsListInput(sort: PostsListInputSort.asc, cursor: page1.nextCursor),
    );
    expect(page2.items, hasLength(1));
    expect(page2.nextCursor, isNull);
  });

  test('unauthorized call surfaces RpcUnauthorizedException', () async {
    final anonymous = Api(
      RpcClient(
        endpoint: Uri.parse('http://127.0.0.1:$port/trpc'),
        transformer: RpcTransformer.superjson,
        links: [
          HttpBatchLink(endpoint: Uri.parse('http://127.0.0.1:$port/trpc'))
        ],
      ),
    );
    await expectLater(
        anonymous.user.me.query(), throwsA(isA<RpcUnauthorizedException>()));
  });

  test('showcase listenable bridge renders live states over the wire',
      () async {
    // The showcase composition root (main.dart) wires the same links; here we
    // verify the reactive contract: the listenable mirrors cache states and
    // the widget tree consumes it through ValueListenableBuilder.
    final ref = api.user.me.watch();
    final listenable = ref.listenable;
    final states = <RpcAsyncState<UserGetByIdOutput>>[];
    listenable.addListener(() => states.add(listenable.value));

    final first = await ref.stream
        .firstWhere((s) => s is RpcAsyncData<UserGetByIdOutput>);
    expect(
      (first as RpcAsyncData<UserGetByIdOutput>).data.name,
      'Aditya',
    );
    expect(states.whereType<RpcAsyncData<UserGetByIdOutput>>().last.data.name,
        'Aditya');
  });
}
