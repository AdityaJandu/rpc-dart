import 'dart:async';

import 'package:test/test.dart';
import 'package:trpc_dart/trpc_dart.dart';

/// Fake termination link: records requests, replays scripted outcomes.
class FakeTransport extends RpcLink {
  FakeTransport(this.handler);

  final Future<Object?> Function(RpcRequest request, int callIndex) handler;
  final List<RpcRequest> requests = <RpcRequest>[];
  int _calls = 0;

  @override
  bool get isTermination => true;

  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) {
    final index = _calls++;
    requests.add(request);
    return handler(request, index);
  }
}

final _unauthorized = RpcUnauthorizedException('expired token');

void main() {
  group('AuthLink', () {
    test('attaches dynamic headers before dispatch', () async {
      final transport = FakeTransport((request, _) async => 'ok');
      final client = RpcClient(
        endpoint: Uri.parse('http://localhost/trpc'),
        links: [
          AuthLink(getHeaders: () async => {'authorization': 'Bearer t1'}),
          transport,
        ],
      );
      await client.execute(const RpcRequest(
        path: 'user.me',
        kind: RpcProcedureKind.query,
        input: null,
      ));
      expect(transport.single.header('authorization'), 'Bearer t1');
    });

    test(
        'single-flight: 10 concurrent 401s refresh exactly once, all replay once',
        () async {
      var refreshCalls = 0;
      var token = 't1';
      final transport = FakeTransport((request, _) async {
        if (request.header('authorization') == 'Bearer t1') {
          throw _unauthorized;
        }
        return 'ok-${request.header('authorization')}';
      });
      final client = RpcClient(
        endpoint: Uri.parse('http://localhost/trpc'),
        links: [
          AuthLink(
            getHeaders: () async => {'authorization': 'Bearer $token'},
            onUnauthorized: () async {
              refreshCalls++;
              await Future<void>.delayed(const Duration(milliseconds: 20));
              token = 't2';
              return null; // token provider state was mutated instead
            },
          ),
          transport,
        ],
      );

      final results = await Future.wait<Object?>(
        List.generate(
            10,
            (_) => client.execute(const RpcRequest(
                  path: 'user.me',
                  kind: RpcProcedureKind.query,
                  input: null,
                ))),
      );

      expect(refreshCalls, 1, reason: 'single-flight refresh lock');
      expect(results.every((r) => r == 'ok-Bearer t2'), isTrue);
      // Every operation replayed at most once: 10 initial + 10 replays.
      expect(transport.requests.length, 20);
      expect(
          transport.requests
              .where((r) => r.header('authorization') == 'Bearer t1')
              .length,
          10);
      expect(
          transport.requests
              .where((r) => r.header('authorization') == 'Bearer t2')
              .length,
          10);
    });

    test('a second 401 after replay surfaces (no infinite loop)', () async {
      var refreshCalls = 0;
      final transport =
          FakeTransport((request, _) async => throw _unauthorized);
      final client = RpcClient(
        endpoint: Uri.parse('http://localhost/trpc'),
        links: [
          AuthLink(
            getHeaders: () async => {'authorization': 'Bearer t1'},
            onUnauthorized: () async {
              refreshCalls++;
              return null;
            },
          ),
          transport,
        ],
      );

      await expectLater(
        client.execute(const RpcRequest(
          path: 'user.me',
          kind: RpcProcedureKind.query,
          input: null,
        )),
        throwsA(isA<RpcUnauthorizedException>()),
      );
      expect(refreshCalls, 1);
      // initial + one replay only
      expect(transport.requests.length, 2);
    });

    test('refresh failure surfaces the original unauthorized error', () async {
      final transport =
          FakeTransport((request, _) async => throw _unauthorized);
      final client = RpcClient(
        endpoint: Uri.parse('http://localhost/trpc'),
        links: [
          AuthLink(
            getHeaders: () async => {'authorization': 'Bearer t1'},
            onUnauthorized: () async =>
                throw StateError('refresh endpoint down'),
          ),
          transport,
        ],
      );

      await expectLater(
        client.execute(const RpcRequest(
          path: 'user.me',
          kind: RpcProcedureKind.query,
          input: null,
        )),
        throwsA(isA<RpcUnauthorizedException>()),
      );
      expect(transport.requests.length, 1,
          reason: 'no replay without fresh credentials');
    });

    test('overrideExisting replaces per-call headers only when configured',
        () async {
      final transport = FakeTransport((request, _) async => 'ok');
      Future<Object?> run({required bool overrideExisting}) {
        final client = RpcClient(
          endpoint: Uri.parse('http://localhost/trpc'),
          links: [
            AuthLink(
              getHeaders: () async => {'authorization': 'Bearer auth'},
              overrideExisting: overrideExisting,
            ),
            transport,
          ],
        );
        return client.execute(const RpcRequest(
          path: 'user.me',
          kind: RpcProcedureKind.query,
          input: null,
          context:
              RpcCallContext(headers: {'authorization': 'Bearer per-call'}),
        ));
      }

      await run(overrideExisting: false);
      expect(transport.last.header('authorization'), 'Bearer per-call');
      await run(overrideExisting: true);
      expect(transport.last.header('authorization'), 'Bearer auth');
    });
  });
}

extension on FakeTransport {
  RpcRequest get single => requests.single;
  RpcRequest get last => requests.last;
}

extension on RpcRequest {
  String? header(String name) => context?.headers[name];
}
