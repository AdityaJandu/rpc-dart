import 'dart:async';

import 'package:test/test.dart';
import 'package:trpc_dart/trpc_dart.dart';

void main() {
  group('rpcSummarizePayload', () {
    test('summarizes RpcFile without dumping bytes', () {
      final file = RpcFile.bytes('avatar.png', Uint8List(204800),
          contentType: 'image/png');
      final summary = rpcSummarizePayload(file);
      expect(summary, '<RpcFile: avatar.png, 204800 bytes, image/png>');
    });

    test('summarizes byte buffers and streams', () {
      expect(rpcSummarizePayload(Uint8List(1048576)), '<1048576 bytes>');
      expect(rpcSummarizePayload(const Stream<Uint8List>.empty()),
          '<byte stream>');
    });

    test('recurses through maps and lists keeping summaries bounded', () {
      final summary = rpcSummarizePayload(<String, Object?>{
        'name': 'Earth',
        'avatar': RpcFile.bytes('a.png', Uint8List(1000000)),
        'gallery': [Uint8List(500000)],
      });
      expect(summary, contains('Earth'));
      expect(summary, contains('<RpcFile: a.png, 1000000 bytes'));
      expect(summary, contains('<500000 bytes>'));
      expect(summary.length, lessThan(200));
    });

    test('caps long text payloads instead of dumping them', () {
      final summary = rpcSummarizePayload('x' * 100000);
      expect(summary.length, lessThan(2100));
      expect(summary, contains('100000'));
    });
  });

  group('LoggingLink payload summaries', () {
    test('are opt-in and never contain raw bytes', () async {
      final events = <RpcLogEvent>[];
      final transport = _OkTransport();
      final chain = RpcLinkChain([
        LoggingLink(onEvent: events.add, logPayloads: true),
        transport,
      ]);
      await chain.invoke(RpcRequest(
        path: 'uploads.avatar',
        kind: RpcProcedureKind.mutation,
        input: <String, Object?>{
          'file': RpcFile.bytes('big.png', Uint8List(1000000)),
        },
      ));
      final request = events.firstWhere((e) => e.event == 'request');
      expect(request.payloadSummary, contains('<RpcFile: big.png'));
      expect(request.payloadSummary!.length, lessThan(200));
    });

    test('stay null when logPayloads is off', () async {
      final events = <RpcLogEvent>[];
      final chain = RpcLinkChain([
        LoggingLink(onEvent: events.add),
        _OkTransport(),
      ]);
      await chain.invoke(RpcRequest(
        path: 'x',
        kind: RpcProcedureKind.query,
        input: Uint8List(10),
      ));
      expect(events.first.payloadSummary, isNull);
    });
  });

  group('LoggingLink stream events', () {
    test('does not log a response event after a stream error', () async {
      final events = <RpcLogEvent>[];
      final chain = RpcLinkChain([
        LoggingLink(onEvent: events.add),
        _ErrorStreamTransport(),
      ]);
      final done = Completer<void>();
      chain
          .invokeStream(RpcRequest(
              path: 's', kind: RpcProcedureKind.subscription, input: null))
          .listen((_) {}, onError: (_) {}, onDone: done.complete);
      await done.future.timeout(const Duration(seconds: 2));
      expect(events.any((e) => e.event == 'error'), isTrue);
      expect(events.any((e) => e.event == 'response'), isFalse);
    });
  });
}

final class _OkTransport extends RpcLink {
  @override
  bool get isTermination => true;

  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) async => 'ok';
}

final class _ErrorStreamTransport extends RpcLink {
  @override
  bool get isTermination => true;

  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) async =>
      throw StateError('unary not supported');

  @override
  Stream<Object?> invokeStream(RpcRequest request, RpcStreamLinkNext next) =>
      Stream<Object?>.error(RpcNetworkException('dropped'));
}
