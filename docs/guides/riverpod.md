# Guide: Riverpod

Riverpod integration built directly on the runtime's primitives — no code generation, no `riverpod_generator`, no extra adapter package. Two complementary patterns:

1. **Thin `FutureProvider.family`** over `.safeQuery(...)` when you want Riverpod to own caching.
2. **`StreamProvider.family` over `.watch(...)`** when you want the built-in cache to own caching and Riverpod to expose it.

## 0. Client provider

```dart
final clientProvider = Provider<RpcClient>((ref) {
  return RpcClient(
    endpoint: Uri.parse('https://api.example.com/trpc'),
    transformer: RpcTransformer.superjson,
    links: RpcLinkChain([AuthLink(tokenProvider: myTokenProvider), HttpBatchLink()]),
  );
});

final apiProvider = Provider<Api>((ref) => Api(ref.watch(clientProvider)));
```

## 1. FutureProvider.family over safeQuery

```dart
final userProvider = FutureProvider.autoDispose
    .family<UserGetByIdOutput, String>((ref, id) async {
  final api = ref.watch(apiProvider);

  // Auto-refresh: when anything under 'user' is invalidated, re-run this provider.
  final sub = api.onInvalidate(api.user.getById.pathKey).listen((_) => ref.invalidateSelf());
  ref.onDispose(sub.cancel);

  final result = await api.user.getById.safeQuery(UserGetByIdInput(id: id));
  switch (result) {
    case RpcSuccess(:final data):
      return data;
    case RpcFailure(:final error):
      throw error;   // typed RpcException surfaces as AsyncError
  }
});

// Usage:
// ref.watch(userProvider('u1')) -> AsyncValue<UserGetByIdOutput>
```

After a mutation, invalidate the structural key — every watched family instance refetches:

```dart
await ref.read(apiProvider).user.update.mutate(UpdateUserInput(name: RpcPresent('Ada')));
ref.read(apiProvider).invalidate(ref.read(apiProvider).user.pathKey());
ref.invalidate(userProvider('u1'));   // or rely on onInvalidate above
```

## 2. StreamProvider.family over watch (cache as source of truth)

Here the built-in cache keeps its value across widget rebuilds; Riverpod just mirrors it:

```dart
final userStateProvider = StreamProvider.autoDispose
    .family<RpcAsyncState<UserGetByIdOutput>, String>((ref, id) {
  final api = ref.watch(apiProvider);
  return api.user.getById.watch(UserGetByIdInput(id: id)).stream;
});

// Usage — Riverpod's AsyncValue wraps our RpcAsyncState:
// ref.watch(userStateProvider('u1')).when(
//   data: (rpcState) => switch (rpcState) { ... },
//   loading: ..., error: ...,
// );
```

## 3. AsyncNotifier pattern

For notifier-style flows (mutations + state) with Riverpod 3:

```dart
class UserNotifier extends AsyncNotifier<UserGetByIdOutput> {
  late String _userId;

  Future<void> load(String userId) async {
    _userId = userId;
    ref.invalidateSelf();
  }

  @override
  Future<UserGetByIdOutput> build() async {
    final api = ref.watch(apiProvider);
    final sub = api.onInvalidate(api.user.getById.pathKey).listen((_) => ref.invalidateSelf());
    ref.onDispose(sub.cancel);

    final result = await api.user.getById.safeQuery(UserGetByIdInput(id: _userId));
    switch (result) {
      case RpcSuccess(:final data):
        return data;
      case RpcFailure(:final error):
        throw error;
    }
  }

  Future<void> rename(String name) async {
    final api = ref.read(apiProvider);
    state = const AsyncLoading<UserGetByIdOutput>().copyWithPrevious(state);
    final result = await api.user.update.safeMutate(UpdateUserInput(name: RpcPresent(name)));
    switch (result) {
      case RpcSuccess(:final data):
        api.cache.setQueryData(api.user.getById.queryKey(UserGetByIdInput(id: _userId)), data);
        api.invalidate(api.user.getById.pathKey);
      case RpcFailure(:final error):
        state = AsyncError(error, StackTrace.current);
    }
  }
}
```

## 4. Choosing between the two patterns

| Concern | `FutureProvider.family` (pattern 1) | `StreamProvider.family` over watch (pattern 2) |
|---|---|---|
| Cache ownership | Riverpod | built-in `RpcQueryCache` |
| Cross-screen shared state | per-family-instance | shared by key, survives unlisten while stale |
| Invalidation | manual `ref.invalidate` (plus optional `onInvalidate` glue) | automatic: `api.invalidate` refetches and the stream re-emits |
| Optimistic updates | awkward (outside Riverpod's model) | natural via `setQueryData` |

Apps mixing both are fine: pattern 2 for screens with mutations/optimism, pattern 1 for read-only detail pages.

## 5. Notes

- The typed exception hierarchy keeps `AsyncError` exact: `error is RpcUnauthorizedException` is a reliable login-redirect trigger — no message parsing.
- Keep `ref.onDispose` around every `onInvalidate` subscription so family instances clean up.
- `pathKey` prefixes make blunt invalidation trivial: `api.invalidate(api.user.pathKey())` refreshes everything under `user` that any provider is watching.
- Riverpod major upgrades never touch the runtime: the primitives (`safeQuery`, `watch`, `onInvalidate`, `RpcQueryKey`) are framework-free.
