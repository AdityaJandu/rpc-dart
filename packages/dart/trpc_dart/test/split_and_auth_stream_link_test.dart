import 'dart:async';

import 'package:test/test.dart';
import 'package:trpc_dart/src/auth_link.dart';
import 'package:trpc_dart/src/codec.dart';
import 'package:trpc_dart/src/exceptions.dart';
import 'package:trpc_dart/src/link.dart';
import 'package:trpc_dart/src/split_link.dart';
import 'package:trpc_dart/src/subscription.dart';

void main() {
  group('SplitLink', () {
    test(
        'routes query/mutation to the unary link and subscriptions to the '
        'stream link', () async {
      final unary = _FakeUnaryLink();
      final stream = _FakeStreamLink();
      final split = SplitLink(unaryLink: unary, subscriptionLink: stream);

      await split.invoke(
        const RpcRequest(
          path: 'user.me',
          kind: RpcProcedureKind.query,
          input: null,
        ),
        _noNext,
      );
      await split.invoke(
        const RpcRequest(
          path: 'user.update',
          kind: RpcProcedureKind.mutation,
          input: null,
        ),
        _noNext,
      );
      await split
          .invokeStream(
            RpcRequest(
              path: 'streams.onTick',
              kind: RpcProcedureKind.subscription,
              input: null,
              subscription:
                  RpcSubscriptionTicket(const RpcSubscriptionOptions()),
            ),
            _noStreamNext,
          )
          .toList();

      expect(unary.paths, ['user.me', 'user.update']);
      expect(stream.paths, ['streams.onTick']);
    });

    test('custom predicate overrides kind-based routing', () async {
      final unary = _FakeUnaryLink();
      final stream = _FakeStreamLink();
      final split = SplitLink(
        unaryLink: unary,
        subscriptionLink: stream,
        predicate: (request) => request.path.contains('premium'),
      );

      await split.invoke(
        const RpcRequest(
          path: 'user.premiumFeed',
          kind: RpcProcedureKind.query,
          input: null,
        ),
        _noNext,
      );
      await split.invoke(
        const RpcRequest(
          path: 'user.me',
          kind: RpcProcedureKind.query,
          input: null,
        ),
        _noNext,
      );

      expect(stream.paths, ['user.premiumFeed']);
      expect(unary.paths, ['user.me']);
    });
  });

  group('AuthLink streaming', () {
    test(
        'single-flight refresh for two simultaneous unauthorized streams, '
        'then both replay with the new token', () async {
      var refreshCalls = 0;
      // getHeaders reads live state; onUnauthorized rotates the token.
      var token = 'old';
      final auth = AuthLink(
        getHeaders: () async => {'authorization': 'Bearer $token'},
        onUnauthorized: () async {
          refreshCalls++;
          token = 'new';
          return {'authorization': 'Bearer new'};
        },
      );
      final transport = _UnauthorizedOnceStreamLink();
      final chain = RpcLinkChain([auth, transport]);

      Future<List<Object?>> openStream() {
        final request = RpcRequest(
          path: 'streams.onActivity',
          kind: RpcProcedureKind.subscription,
          input: null,
          subscription: RpcSubscriptionTicket(const RpcSubscriptionOptions()),
        );
        return chain.invokeStream(request).toList();
      }

      final results = await Future.wait([openStream(), openStream()]);

      expect(refreshCalls, 1);
      expect(results[0], ['replayed']);
      expect(results[1], ['replayed']);
      expect(transport.authHeadersSeen, contains('Bearer new'));
    });

    test('a second unauthorized after replay propagates (no refresh loop)',
        () async {
      var refreshCalls = 0;
      final auth = AuthLink(
        getHeaders: () async => {'authorization': 'Bearer old'},
        onUnauthorized: () async {
          refreshCalls++;
          return {'authorization': 'Bearer new'};
        },
      );
      final transport = _AlwaysUnauthorizedStreamLink();
      final chain = RpcLinkChain([auth, transport]);

      final request = RpcRequest(
        path: 'streams.onActivity',
        kind: RpcProcedureKind.subscription,
        input: null,
        subscription: RpcSubscriptionTicket(const RpcSubscriptionOptions()),
      );

      await expectLater(
        chain.invokeStream(request).toList(),
        throwsA(isA<RpcUnauthorizedException>()),
      );
      expect(refreshCalls, 1);
    });
  });

  group('RpcClient.subscribe', () {
    test('maps stream items through decode and routes through the chain',
        () async {
      final transport = _FakeStreamLink(values: [
        <String, Object?>{'n': 1},
        <String, Object?>{'n': 2},
      ]);
      final client = RpcClient(
        endpoint: Uri.parse('http://localhost:8787/trpc'),
        links: [transport],
        transformer: RpcTransformer.json,
      );

      final stream = client.subscribe<int>(
        path: 'counter.onValue',
        input: null,
        decode: (value) => (value as Map<String, Object?>)['n']! as int,
      );

      expect(await stream.toList(), [1, 2]);
      expect(transport.paths, ['counter.onValue']);
    });
  });

  group('RpcLinkChain reconnect notifications', () {
    test('invokes onReconnect with attempt and error before reconnecting',
        () async {
      final reconnects = <(int, Object?)>[];
      final transport = _DropsOnceStreamLink();
      final chain = RpcLinkChain([transport]);
      final request = RpcRequest(
        path: 'streams.onActivity',
        kind: RpcProcedureKind.subscription,
        input: null,
        subscription: RpcSubscriptionTicket(
          RpcSubscriptionOptions(
            reconnectPolicy: const RpcReconnectPolicy(
              maxAttempts: 5,
              initialDelay: Duration(milliseconds: 1),
            ),
            onReconnect: (attempt, error) => reconnects.add((attempt, error)),
          ),
        ),
      );

      final events = await chain.invokeStream(request).toList();

      expect(events, ['recovered']);
      expect(reconnects, hasLength(1));
      expect(reconnects.single.$1, 1);
      expect(reconnects.single.$2, isA<RpcNetworkException>());
    });
  });

  group('Stream error termination', () {
    test('4xx server errors terminate without a reconnect loop', () async {
      for (final error in <RpcException>[
        RpcBadRequestException('bad', httpStatus: 400),
        RpcUnauthorizedException('nope', httpStatus: 401),
        RpcForbiddenException('denied', httpStatus: 403),
        RpcNotFoundException('missing', httpStatus: 404),
      ]) {
        final transport = _AlwaysFailingStreamLink(error);
        final chain = RpcLinkChain([transport]);
        final request = RpcRequest(
          path: 'streams.onActivity',
          kind: RpcProcedureKind.subscription,
          input: null,
          subscription: RpcSubscriptionTicket(
            const RpcSubscriptionOptions(
              reconnectPolicy: RpcReconnectPolicy(
                maxAttempts: 5,
                initialDelay: Duration(milliseconds: 1),
              ),
            ),
          ),
        );
        await expectLater(
          chain.invokeStream(request).toList(),
          throwsA(same(error)),
        );
        expect(transport.attempts, 1,
            reason: '${error.code} must not reconnect');
      }
    });

    test('5xx server errors reconnect until they succeed', () async {
      final transport = _FailThenSucceedStreamLink(
        RpcBadGatewayException('down', httpStatus: 502),
      );
      final chain = RpcLinkChain([transport]);
      final request = RpcRequest(
        path: 'streams.onActivity',
        kind: RpcProcedureKind.subscription,
        input: null,
        subscription: RpcSubscriptionTicket(
          const RpcSubscriptionOptions(
            reconnectPolicy: RpcReconnectPolicy(
              maxAttempts: 5,
              initialDelay: Duration(milliseconds: 1),
            ),
          ),
        ),
      );
      expect(await chain.invokeStream(request).toList(), ['recovered']);
      expect(transport.attempts, 2);
    });
  });
}

Stream<Object?> _noStreamNext(RpcRequest request) {
  throw StateError('termination link must not call next');
}

Future<Object?> _noNext(RpcRequest request) {
  throw StateError('termination link must not call next');
}

final class _FakeUnaryLink extends RpcLink {
  final List<String> paths = <String>[];

  @override
  bool get isTermination => true;

  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) async {
    paths.add(request.path);
    return 'unary:${request.path}';
  }
}

final class _FakeStreamLink extends RpcLink {
  _FakeStreamLink({this.values = const []});

  final List<String> paths = <String>[];
  final List<Object?> values;

  @override
  bool get isTermination => true;

  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) {
    paths.add(request.path);
    return Future<Object?>.value('stream-unary:${request.path}');
  }

  @override
  Stream<Object?> invokeStream(RpcRequest request, RpcStreamLinkNext next) {
    paths.add(request.path);
    return Stream<Object?>.fromIterable(values);
  }
}

/// Errors each logical stream with UNAUTHORIZED on the first attempt and
/// serves a replay value once the same ticket comes back around.
final class _UnauthorizedOnceStreamLink extends RpcLink {
  final Set<RpcSubscriptionTicket> _seen = <RpcSubscriptionTicket>{};
  final Completer<void> _bothArrived = Completer<void>();
  var _arrived = 0;
  final List<String?> authHeadersSeen = <String?>[];

  @override
  bool get isTermination => true;

  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) {
    throw StateError('use invokeStream');
  }

  @override
  Stream<Object?> invokeStream(RpcRequest request, RpcStreamLinkNext next) {
    authHeadersSeen.add(request.context?.headers['authorization']);
    final ticket = request.subscription!;
    if (_seen.contains(ticket)) {
      return Stream<Object?>.value('replayed');
    }
    _seen.add(ticket);
    return () async* {
      // Both streams 401 in the same turn so their refreshes contend for the
      // single-flight lock (the unary AuthLink semantics).
      _arrived++;
      if (_arrived == 2) _bothArrived.complete();
      await _bothArrived.future;
      throw RpcUnauthorizedException('expired token');
    }();
  }
}

final class _AlwaysUnauthorizedStreamLink extends RpcLink {
  @override
  bool get isTermination => true;

  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) {
    throw StateError('use invokeStream');
  }

  @override
  Stream<Object?> invokeStream(RpcRequest request, RpcStreamLinkNext next) {
    return () async* {
      throw RpcUnauthorizedException('expired token');
    }();
  }
}

/// Drops the first attempt with a retryable network error, then serves a
/// value once the same ticket reconnects.
final class _DropsOnceStreamLink extends RpcLink {
  final Set<RpcSubscriptionTicket> _seen = <RpcSubscriptionTicket>{};

  @override
  bool get isTermination => true;

  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) {
    throw StateError('use invokeStream');
  }

  @override
  Stream<Object?> invokeStream(RpcRequest request, RpcStreamLinkNext next) {
    final ticket = request.subscription!;
    if (_seen.contains(ticket)) {
      return Stream<Object?>.value('recovered');
    }
    _seen.add(ticket);
    return Stream<Object?>.error(RpcNetworkException('dropped'));
  }
}

/// Always errors with [error]; counts attempts to prove reconnect behavior.
final class _AlwaysFailingStreamLink extends RpcLink {
  _AlwaysFailingStreamLink(this.error);

  final RpcException error;
  int attempts = 0;

  @override
  bool get isTermination => true;

  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) {
    throw StateError('use invokeStream');
  }

  @override
  Stream<Object?> invokeStream(RpcRequest request, RpcStreamLinkNext next) {
    attempts++;
    return Stream<Object?>.error(error);
  }
}

/// Errors with [error] on the first attempt, then serves a value.
final class _FailThenSucceedStreamLink extends RpcLink {
  _FailThenSucceedStreamLink(this.error);

  final RpcException error;
  int attempts = 0;

  @override
  bool get isTermination => true;

  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) {
    throw StateError('use invokeStream');
  }

  @override
  Stream<Object?> invokeStream(RpcRequest request, RpcStreamLinkNext next) {
    attempts++;
    if (attempts == 1) {
      return Stream<Object?>.error(error);
    }
    return Stream<Object?>.value('recovered');
  }
}
