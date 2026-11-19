import 'package:test/test.dart';
import 'package:trpc_dart/trpc_dart.dart';

void main() {
  group('RpcException.fromOrpcWire', () {
    test('maps a defined NOT_FOUND payload to the typed subclass', () {
      final error = RpcException.fromOrpcWire(<String, Object?>{
        'defined': true,
        'code': 'NOT_FOUND',
        'status': 404,
        'message': 'no planet',
        'data': <String, Object?>{'id': '9'},
      });
      expect(error, isA<RpcNotFoundException>());
      expect(error.code, 'NOT_FOUND');
      expect(error.httpStatus, 404);
      expect(error.message, 'no planet');
      expect(error.defined, isTrue);
      expect(error.data, {'id': '9'});
    });

    test('maps UNAUTHORIZED so AuthLink refresh keys on it', () {
      final error = RpcException.fromOrpcWire(<String, Object?>{
        'defined': false,
        'code': 'UNAUTHORIZED',
        'status': 401,
        'message': 'Unauthorized',
      });
      expect(error, isA<RpcUnauthorizedException>());
      expect(error.defined, isFalse);
    });

    test('preserves custom codes with their declared status', () {
      final error = RpcException.fromOrpcWire(<String, Object?>{
        'defined': true,
        'code': 'RATE_LIMITED',
        'status': 429,
        'message': 'slow down',
        'data': <String, Object?>{'retryAfter': 60},
      });
      expect(error.code, 'RATE_LIMITED');
      expect(error.httpStatus, 429);
      expect(error.defined, isTrue);
      expect(error.data, {'retryAfter': 60});
    });

    test('wraps non-map data payloads under a value key', () {
      final error = RpcException.fromOrpcWire(<String, Object?>{
        'defined': false,
        'code': 'INTERNAL_SERVER_ERROR',
        'status': 500,
        'message': 'boom',
        'data': [1, 2, 3],
      });
      expect(error, isA<RpcInternalServerException>());
      expect(error.data, {
        'value': [1, 2, 3]
      });
    });

    test('covers the full common code table', () {
      const codes = <String, int>{
        'BAD_REQUEST': 400,
        'FORBIDDEN': 403,
        'METHOD_NOT_SUPPORTED': 405,
        'NOT_ACCEPTABLE': 406,
        'TIMEOUT': 408,
        'CONFLICT': 409,
        'PRECONDITION_FAILED': 412,
        'PAYLOAD_TOO_LARGE': 413,
        'UNSUPPORTED_MEDIA_TYPE': 415,
        'UNPROCESSABLE_CONTENT': 422,
        'TOO_MANY_REQUESTS': 429,
        'CLIENT_CLOSED_REQUEST': 499,
        'NOT_IMPLEMENTED': 501,
        'BAD_GATEWAY': 502,
        'SERVICE_UNAVAILABLE': 503,
        'GATEWAY_TIMEOUT': 504,
      };
      codes.forEach((code, status) {
        final error = RpcException.fromOrpcWire(<String, Object?>{
          'defined': false,
          'code': code,
          'status': status,
          'message': code,
        });
        expect(error.code, code);
        expect(error.httpStatus, status);
      });
      expect(
        RpcException.fromOrpcWire(<String, Object?>{
          'defined': false,
          'code': 'TIMEOUT',
          'status': 408,
          'message': 't',
        }),
        isA<RpcTimeoutException>(),
      );
    });
  });
}
