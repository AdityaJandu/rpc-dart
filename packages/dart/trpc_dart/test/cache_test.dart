import 'dart:async';

import 'package:test/test.dart';
import 'package:trpc_dart/trpc_dart.dart';

void main() {
  group('RpcQueryKey', () {
    test('equality is structural (deep input equality included)', () {
      final a = UserInput('u1');
      final b = UserInput('u1');
      final ka = RpcQueryKey(path: const ['user', 'getById'], input: a);
      final kb = RpcQueryKey(path: const ['user', 'getById'], input: b);
      expect(ka, kb);
      expect(ka.hashCode, kb.hashCode);
    });

    test('different path or input => different keys', () {
      final input = UserInput('u1');
      expect(
        RpcQueryKey(path: const ['user', 'getById'], input: input),
        isNot(RpcQueryKey(path: const ['user', 'list'], input: input)),
      );
      expect(
        RpcQueryKey(path: const ['user', 'getById'], input: UserInput('u1')),
        isNot(RpcQueryKey(
            path: const ['user', 'getById'], input: UserInput('u2'))),
      );
    });

    test('prefix matching is segment-based', () {
      const user = RpcQueryKey(path: ['user']);
      const getById = RpcQueryKey(path: ['user', 'getById']);
      const posts = RpcQueryKey(path: ['posts']);
      expect(getById.matchesPrefix(user), isTrue);
      expect(user.matchesPrefix(getById), isFalse);
      expect(posts.matchesPrefix(user), isFalse);
      expect(getById.matchesPrefix(getById), isTrue);
    });
  });

  group('RpcQueryCache', () {
    test('watch fetches immediately and replays state to new listeners',
        () async {
      final cache = RpcQueryCache();
      var fetches = 0;
      final ref =
          cache.watch<UserInput>(RpcQueryKey(path: const ['user']), () async {
        fetches++;
        return UserInput('u$fetches');
      });

      final data =
          await ref.stream.firstWhere((s) => s is RpcAsyncData<UserInput>);
      expect((data as RpcAsyncData<UserInput>).data.id, 'u1');
      expect(ref.state, isA<RpcAsyncData<UserInput>>());
    });

    test('invalidate triggers refetch of active watchers and emits keys',
        () async {
      final cache = RpcQueryCache();
      var fetches = 0;
      final key =
          RpcQueryKey(path: const ['user', 'getById'], input: UserInput('u1'));
      final ref = cache.watch<UserInput>(key, () async {
        fetches++;
        return UserInput('u$fetches');
      });

      final states = <RpcAsyncState<UserInput>>[];
      final sub = ref.stream.listen(states.add);
      await ref.stream.first;

      final invalidated = <RpcQueryKey>[];
      final invalidationSub = cache.onInvalidate().listen(invalidated.add);

      cache.invalidate(const RpcQueryKey(path: ['user']));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(fetches, 2, reason: 'invalidate refetches watched queries');
      expect(invalidated, contains(key));
      expect(states.whereType<RpcAsyncData<UserInput>>().length,
          greaterThanOrEqualTo(2));

      await sub.cancel();
      await invalidationSub.cancel();
    });

    test('prefix invalidation only touches matching entries', () async {
      final cache = RpcQueryCache();
      var userFetches = 0;
      var postsFetches = 0;
      cache.watch<UserInput>(const RpcQueryKey(path: ['user']), () async {
        userFetches++;
        return UserInput('u');
      });
      cache.watch<UserInput>(const RpcQueryKey(path: ['posts']), () async {
        postsFetches++;
        return UserInput('p');
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));

      cache.invalidate(const RpcQueryKey(path: ['posts']));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(userFetches, 1);
      expect(postsFetches, 2);
    });

    test('setQueryData writes through to watchers', () async {
      final cache = RpcQueryCache();
      final key = const RpcQueryKey(path: ['user']);
      final ref = cache.watch<UserInput>(key, () async => UserInput('initial'));
      await ref.stream.first;

      cache.setQueryData<UserInput>(key, UserInput('patched'));
      final next = await ref.stream.firstWhere(
          (s) => s is RpcAsyncData<UserInput> && s.data.id == 'patched');
      expect(next, isA<RpcAsyncData<UserInput>>());
    });

    test('onInvalidate with prefix filters the stream', () async {
      final cache = RpcQueryCache();
      cache.watch<UserInput>(
          const RpcQueryKey(path: ['posts']), () async => UserInput('p'));
      cache.watch<UserInput>(const RpcQueryKey(path: ['user', 'getById']),
          () async => UserInput('u'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final seen = <RpcQueryKey>[];
      final sub = cache
          .onInvalidate(const RpcQueryKey(path: ['user']))
          .listen(seen.add);
      cache.invalidate(const RpcQueryKey(path: ['posts']));
      cache.invalidate(const RpcQueryKey(path: ['user', 'getById']));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();
      expect(seen, hasLength(1));
      expect(seen.single.path, const ['user', 'getById']);
    });

    test('fetch errors surface as RpcAsyncError and do not kill the stream',
        () async {
      final cache = RpcQueryCache();
      var attempts = 0;
      final ref =
          cache.watch<UserInput>(const RpcQueryKey(path: ['user']), () async {
        attempts++;
        if (attempts == 1) throw RpcNetworkException('boom');
        return UserInput('ok');
      });

      final failed =
          await ref.stream.firstWhere((s) => s is RpcAsyncError<UserInput>);
      expect(failed, isA<RpcAsyncError<UserInput>>());

      await ref.refetch();
      final recovered =
          await ref.stream.firstWhere((s) => s is RpcAsyncData<UserInput>);
      expect(recovered, isA<RpcAsyncData<UserInput>>());
    });
  });
}

class UserInput {
  const UserInput(this.id);
  final String id;

  @override
  bool operator ==(Object other) => other is UserInput && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
