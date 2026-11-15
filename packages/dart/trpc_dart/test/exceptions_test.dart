import 'package:test/test.dart';
import 'package:trpc_dart/trpc_dart.dart';

void main() {
  group('RpcException.fromWire', () {
    test('UNAUTHORIZED error envelope decodes to RpcUnauthorizedException', () {
      final exception = RpcException.fromWire(const {
        'message': 'unauthorized',
        'code': -32001,
        'data': {
          'code': 'UNAUTHORIZED',
          'httpStatus': 401,
          'path': 'user.getById'
        },
      });
      expect(exception, isA<RpcUnauthorizedException>());
      expect(exception.message, 'unauthorized');
      expect(exception.code, 'UNAUTHORIZED');
      expect(exception.httpStatus, 401);
      expect(exception.path, 'user.getById');
    });

    test('BAD_REQUEST carries zod field errors', () {
      final exception = RpcException.fromWire(const {
        'message': 'invalid input',
        'code': -32600,
        'data': {
          'code': 'BAD_REQUEST',
          'httpStatus': 400,
          'path': 'user.update',
          'zodError': {
            'formErrors': <String>[],
            'fieldErrors': {
              'name': <String>['too short']
            },
          },
        },
      });
      expect(exception, isA<RpcBadRequestException>());
      final bad = exception as RpcBadRequestException;
      expect(bad.fieldErrors['name'], <String>['too short']);
    });

    test('NOT_FOUND and INTERNAL_SERVER_ERROR map to their subtypes', () {
      expect(
        RpcException.fromWire(const {
          'message': 'nf',
          'code': -32004,
          'data': {'code': 'NOT_FOUND', 'httpStatus': 404},
        }),
        isA<RpcNotFoundException>(),
      );
      expect(
        RpcException.fromWire(const {
          'message': 'ise',
          'code': -32603,
          'data': {'code': 'INTERNAL_SERVER_ERROR', 'httpStatus': 500},
        }),
        isA<RpcInternalServerException>(),
      );
    });

    test('unknown wire codes still produce a typed RpcException with data', () {
      final exception = RpcException.fromWire(const {
        'message': 'custom',
        'code': -32099,
        'data': {'code': 'SOMETHING_NEW', 'httpStatus': 499},
      });
      expect(exception, isA<RpcException>());
      expect(exception, isNot(isA<RpcUnauthorizedException>()));
      expect(exception.code, 'SOMETHING_NEW');
    });
  });

  group('link chain', () {
    test('rejects multiple termination links', () {
      expect(
        () => RpcLinkChain([
          HttpBatchLink(endpoint: Uri.parse('http://x/trpc')),
          HttpBatchLink(endpoint: Uri.parse('http://x/trpc'))
        ]),
        throwsArgumentError,
      );
    });

    test('custom links compose in order and errors propagate', () async {
      final seen = <String>[];
      RpcRequest? captured;
      final client = RpcClient(
        endpoint: Uri.parse('http://127.0.0.1:1/trpc'),
        transformer: RpcTransformer.superjson,
        links: [
          _TapLink('a', seen, (r) => captured = r),
          _TapLink('b', seen, null),
          HttpBatchLink(endpoint: Uri.parse('http://127.0.0.1:1/trpc')),
        ],
      );
      // Port 1: connection refused -> RpcNetworkException bubbles through links.
      await expectLater(
        client.execute(RpcRequest(
            path: 'user.me', kind: RpcProcedureKind.query, input: null)),
        throwsA(isA<RpcNetworkException>()),
      );
      expect(seen, ['a', 'b']);
      expect(captured, isNotNull);
    });
  });
}

class _TapLink extends RpcLink {
  _TapLink(this.name, this.seen, this.capture);
  final String name;
  final List<String> seen;
  final void Function(RpcRequest)? capture;

  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) {
    seen.add(name);
    capture?.call(request);
    return next(request);
  }
}
