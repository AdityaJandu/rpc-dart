import 'dart:async';

import 'package:test/test.dart';
import 'package:trpc_dart/trpc_dart.dart';

void main() {
  group('RpcJson.asByteStream', () {
    test('passes a Uint8List stream through', () async {
      final stream = Stream<Uint8List>.value(Uint8List.fromList([1]));
      expect(RpcJson.asByteStream(stream), same(stream));
    });

    test('rejects non-stream values with breadcrumb paths', () {
      expect(
        () => RpcJson.asByteStream('nope', r'$.download'),
        throwsA(isA<RpcDecodeException>()
            .having((e) => e.path, 'path', r'$.download')),
      );
    });
  });

  group('RpcCallContext.withProgress', () {
    test('attaches callbacks while preserving every other field', () {
      void onSend(RpcTransferProgress _) {}
      void onReceive(RpcTransferProgress _) {}
      final token = CancelToken();
      final base = RpcCallContext(
        headers: const {'x-a': '1'},
        timeout: const Duration(seconds: 3),
        cancelToken: token,
        idempotencyKey: 'op-2',
        retryable: true,
      );
      final updated = base.withProgress(
          onSendProgress: onSend, onReceiveProgress: onReceive);
      expect(updated.onSendProgress, same(onSend));
      expect(updated.onReceiveProgress, same(onReceive));
      expect(updated.headers, {'x-a': '1'});
      expect(updated.timeout, const Duration(seconds: 3));
      expect(updated.cancelToken, same(token));
      expect(updated.idempotencyKey, 'op-2');
      expect(updated.retryable, isTrue);
    });

    test('keeps existing callbacks when none are provided', () {
      void onSend(RpcTransferProgress _) {}
      final base = RpcCallContext(onSendProgress: onSend);
      expect(base.withProgress().onSendProgress, same(onSend));
    });
  });

  test('barrel re-exports Uint8List for generated code', () {
    expect(Uint8List.fromList([1]), isA<Uint8List>());
  });
}
