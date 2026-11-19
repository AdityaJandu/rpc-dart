import 'package:test/test.dart';
import 'package:trpc_dart/trpc_dart.dart';

void main() {
  group('RpcRequest.withAddedHeader', () {
    test('preserves idempotencyKey, retryable, and progress callbacks', () {
      void onSend(RpcTransferProgress _) {}
      void onReceive(RpcTransferProgress _) {}
      final token = CancelToken();
      final request = RpcRequest(
        path: 'user.update',
        kind: RpcProcedureKind.mutation,
        input: null,
        context: RpcCallContext(
          headers: const {'x-a': '1'},
          timeout: const Duration(seconds: 5),
          cancelToken: token,
          idempotencyKey: 'op-1',
          retryable: true,
          onSendProgress: onSend,
          onReceiveProgress: onReceive,
        ),
      );
      final updated = request.withAddedHeader('x-b', '2');
      expect(updated.context!.headers, {'x-a': '1', 'x-b': '2'});
      expect(updated.context!.idempotencyKey, 'op-1');
      expect(updated.context!.retryable, isTrue);
      expect(updated.context!.timeout, const Duration(seconds: 5));
      expect(updated.context!.cancelToken, same(token));
      expect(updated.context!.onSendProgress, same(onSend));
      expect(updated.context!.onReceiveProgress, same(onReceive));
    });
  });

  group('CancelToken', () {
    test('exposes the cancellation reason', () {
      final token = CancelToken();
      expect(token.reason, isNull);
      token.cancel(reason: 'user navigated away');
      expect(token.isCancelled, isTrue);
      expect(token.reason, 'user navigated away');
    });

    test('keeps the first reason when cancelled twice', () {
      final token = CancelToken();
      token.cancel(reason: 'first');
      token.cancel(reason: 'second');
      expect(token.reason, 'first');
    });
  });
}
