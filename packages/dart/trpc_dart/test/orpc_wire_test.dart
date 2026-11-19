@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:trpc_dart/trpc_dart.dart';

/// Live oRPC wire verification against the Fastify RPCHandler fixture. The
/// vitest e2e orchestrator starts the server and provides ORPC_FIXTURE_PORT;
/// without it these tests are skipped so `dart test` stays hermetic.
void main() {
  final port = Platform.environment['ORPC_FIXTURE_PORT'];
  if (port == null || port.isEmpty) {
    print('ORPC_FIXTURE_PORT not set - skipping live oRPC tests');
    return;
  }

  final endpoint = Uri.parse('http://127.0.0.1:$port/rpc');
  late RpcClient client;

  setUpAll(() {
    client = RpcClient(
      endpoint: endpoint,
      links: [OrpcLink(endpoint: endpoint)],
    );
  });

  test('mutation round trip restores Date and BigInt via numeric meta tags',
      () async {
    final data = await client.execute(RpcRequest(
      path: 'planet.create',
      kind: RpcProcedureKind.mutation,
      input: <String, Object?>{'name': 'Mars'},
    ));
    final json = RpcJson.asMap(data);
    expect(RpcJson.asString(json['name']), 'Mars');
    expect(RpcJson.asDateTime(json['discoveredAt']), DateTime.utc(2026, 1, 1));
    expect(RpcJson.asBigInt(json['mass']), BigInt.from(1));
  });

  test('query uses GET ?data= and decodes the planet', () async {
    final data = await client.execute(RpcRequest(
      path: 'planet.find',
      kind: RpcProcedureKind.query,
      input: <String, Object?>{'id': 1},
    ));
    final json = RpcJson.asMap(data);
    expect(RpcJson.asString(json['name']), 'Earth');
    expect(RpcJson.asBigInt(json['mass']), BigInt.from(5972));
  });

  test('defined errors surface as typed exceptions with data', () async {
    await expectLater(
      client.execute(RpcRequest(
        path: 'planet.find',
        kind: RpcProcedureKind.query,
        input: <String, Object?>{'id': 999},
      )),
      throwsA(isA<RpcNotFoundException>()
          .having((e) => e.defined, 'defined', isTrue)
          .having((e) => e.httpStatus, 'httpStatus', 404)
          .having((e) => e.data?['id'], 'data.id', 999)),
    );
  });

  test('multipart upload reports send progress and round-trips the file',
      () async {
    final bytes = Uint8List.fromList(List.filled(1024 * 1024, 7));
    final progress = <RpcTransferProgress>[];
    final data = await client.execute(RpcRequest(
      path: 'uploads.avatar',
      kind: RpcProcedureKind.mutation,
      input: <String, Object?>{
        'file': RpcFile.bytes('big.png', bytes, contentType: 'image/png'),
        'note': 'live',
      },
      context: RpcCallContext(onSendProgress: progress.add),
    ));
    final json = RpcJson.asMap(data);
    expect(RpcJson.asString(json['name']), 'big.png');
    expect(RpcJson.asInt(json['size']), bytes.length);
    expect(RpcJson.asString(json['note']), 'live');
    expect(progress, isNotEmpty);
    expect(progress.last.transferredBytes, bytes.length);
    for (var i = 1; i < progress.length; i++) {
      expect(progress[i].transferredBytes,
          greaterThanOrEqualTo(progress[i - 1].transferredBytes));
    }
  });

  test('root File download arrives via multipart and reports receive progress',
      () async {
    final progress = <RpcTransferProgress>[];
    final data = await client.execute(RpcRequest(
      path: 'files.download',
      kind: RpcProcedureKind.query,
      input: null,
      context: RpcCallContext(onReceiveProgress: progress.add),
    ));
    final file = RpcJson.asFile(data);
    expect(file.filename, 'earth.png');
    expect(file.contentType, 'image/png');
    expect(await file.readBytes(), Uint8List.fromList([10, 20, 30, 40]));
    expect(progress.last.transferredBytes, greaterThan(0));
  });

  test('ReadableStream download passes through as a byte stream', () async {
    final data = await client.execute(RpcRequest(
      path: 'files.stream',
      kind: RpcProcedureKind.query,
      input: null,
    ));
    final stream = RpcJson.asByteStream(data);
    final chunks = await stream.toList();
    expect(chunks.expand((c) => c).toList(), [1, 2, 3]);
  });

  test('nested-file outputs decode from multipart responses', () async {
    final data = await client.execute(RpcRequest(
      path: 'files.bundle',
      kind: RpcProcedureKind.query,
      input: null,
    ));
    final json = RpcJson.asMap(data);
    expect(RpcJson.asString(json['name']), 'Earth');
    final avatar = RpcJson.asFile(json['avatar']);
    expect(avatar.filename, 'a.png');
    expect(await avatar.readBytes(), Uint8List.fromList([9]));
  });

  test('event iterator streams message frames and tracks resume ids', () async {
    final ids = <String>[];
    final events = <Map<String, Object?>>[];
    final sub = client
        .subscribe<Map<String, Object?>>(
          path: 'streams.ticks',
          input: <String, Object?>{'count': 3},
          decode: RpcJson.asMap,
          options: RpcSubscriptionOptions(onEventId: ids.add),
        )
        .listen(events.add);
    await sub.asFuture<void>().timeout(const Duration(seconds: 10));
    expect(events.length, 3);
    expect(RpcJson.asInt(events[0]['tick']), 0);
    expect(RpcJson.asDateTime(events[2]['at']), DateTime.utc(2026, 1, 1));
    expect(ids, ['0', '1', '2']);
  });

  test('event iterator resumes from lastEventId without duplicates', () async {
    final events = <Map<String, Object?>>[];
    final sub = client
        .subscribe<Map<String, Object?>>(
          path: 'streams.ticks',
          input: <String, Object?>{'count': 3},
          decode: RpcJson.asMap,
          options: const RpcSubscriptionOptions(lastEventId: '1'),
        )
        .listen(events.add);
    await sub.asFuture<void>().timeout(const Duration(seconds: 10));
    expect(events.length, 1);
    expect(RpcJson.asInt(events.single['tick']), 2);
  });

  test('AuthLink refreshes once over OrpcLink on defined UNAUTHORIZED',
      () async {
    var refreshes = 0;
    var token = 'Bearer stale';
    final authed = RpcClient(
      endpoint: endpoint,
      links: [
        AuthLink(
          getHeaders: () async => {'authorization': token},
          onUnauthorized: () async {
            refreshes++;
            token = 'Bearer u1';
            return null;
          },
        ),
        OrpcLink(endpoint: endpoint),
      ],
    );
    final data = await authed.execute(const RpcRequest(
      path: 'secure.me',
      kind: RpcProcedureKind.mutation,
      input: null,
    ));
    expect(RpcJson.asMap(data)['id'], 'u1');
    expect(refreshes, 1);
  });

  test('cancel token aborts a live event stream', () async {
    final token = CancelToken();
    final errors = <Object>[];
    final done = Completer<void>();
    final sub = client
        .subscribe<Map<String, Object?>>(
          path: 'streams.ticks',
          input: <String, Object?>{'count': 1000},
          decode: RpcJson.asMap,
          options: RpcSubscriptionOptions(cancelToken: token),
        )
        .listen((_) {}, onError: errors.add, onDone: done.complete);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    token.cancel(reason: 'test stop');
    await done.future.timeout(const Duration(seconds: 10));
    await sub.cancel();
    expect(errors.whereType<RpcCancelledException>(), isNotEmpty);
  });
}
