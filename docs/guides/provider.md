# Guide: Provider (ChangeNotifier)

Bridging generated bindings into `ChangeNotifier`s for `package:provider` apps. The built-in cache stream does the fetching and refetching; the notifier just publishes state.

## 1. Notifier over the cache stream

```dart
import 'package:flutter/foundation.dart';
import 'package:trpc_dart/trpc_dart.dart';
import '../api/api.dart';

class UserNotifier extends ChangeNotifier {
  UserNotifier(this._api, this._userId) {
    _sub = _api.user.getById
        .watch(UserGetByIdInput(id: _userId))
        .stream
        .listen((state) {
      _state = state;
      notifyListeners();
    });
  }

  final Api _api;
  final String _userId;
  late final StreamSubscription<RpcAsyncState<UserGetByIdOutput>> _sub;
  RpcAsyncState<UserGetByIdOutput> _state = const RpcAsyncLoading();

  RpcAsyncState<UserGetByIdOutput> get state => _state;

  Future<void> rename(String newName) async {
    final result = await _api.user.update.safeMutate(
      UpdateUserInput(name: RpcPresent(newName)),
    );
    switch (result) {
      case RpcSuccess():
        _api.invalidate(_api.user.pathKey());  // stream fires; notifyListeners happens in the listener
      case RpcFailure(:final error):
        _state = RpcAsyncError(error);
        notifyListeners();
    }
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}
```

Wire it up:

```dart
void main() {
  final client = RpcClient(
    endpoint: Uri.parse('https://api.example.com/trpc'),
    transformer: RpcTransformer.superjson,
    links: RpcLinkChain([AuthLink(tokenProvider: myTokenProvider), HttpBatchLink()]),
  );
  runApp(
    MultiProvider(
      providers: [
        Provider<Api>.value(value: Api(client)),
        ChangeNotifierProxyProvider<Api, UserNotifier>(
          create: (context) => UserNotifier(context.read<Api>(), 'u1'),
          update: (context, api, notifier) => notifier ?? UserNotifier(api, 'u1'),
        ),
      ],
      child: const App(),
    ),
  );
}

class UserView extends StatelessWidget {
  const UserView({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<UserNotifier>().state;
    return switch (state) {
      RpcAsyncLoading() => const CircularProgressIndicator(),
      RpcAsyncError(:final error) => Text('failed: $error'),
      RpcAsyncData(:final data) => Text('${data.id} (${data.nicknameOrNull ?? 'no nickname'})'),
    };
  }
}
```

## 2. Optimistic updates with rollback

`setQueryData` writes the cache directly; value equality makes rollback exact:

```dart
Future<void> renameOptimistic(String newName) async {
  final key = _api.user.getById.queryKey(UserGetByIdInput(id: _userId));
  final current = _api.cache.watchAt<UserGetByIdOutput>(key);   // current cached data, if any
  if (current == null) return _renameViaServer(newName);        // nothing to optimistically patch

  _api.cache.setQueryData(key, current.copyWith(name: newName));
  try {
    await _api.user.update.mutate(UpdateUserInput(name: RpcPresent(newName)));
  } on RpcException {
    _api.cache.setQueryData(key, current);                      // exact rollback
    rethrow;
  }
  _api.invalidate(_api.user.pathKey());
}
```

## 3. Invalidating from outside the notifier

Because invalidation is keyed structurally, any component can trigger a refresh without touching the notifier:

```dart
context.read<Api>().invalidate(context.read<Api>().user.pathKey());
```

The notifier's subscription to `watch(...).stream` picks up the refetch and calls `notifyListeners` — no manual event plumbing between widgets and notifiers.

## 4. Selector-friendly derived state

Expose narrow getters so `Selector` widgets rebuild minimally:

```dart
String? get displayName => switch (_state) {
  RpcAsyncData(:final data) => data.name,
  _ => null,
};
```

## 5. Testing

`ChangeNotifier` tests use the same swap-the-transport trick as every other integration:

```dart
final notifier = UserNotifier(api, 'u1');
await notifier.stream?.firstWhere((s) => s is RpcAsyncData);  // or pump the cache stream directly
expect(notifier.state, isA<RpcAsyncData<UserGetByIdOutput>>());
```

Typed errors (`RpcUnauthorizedException`, `RpcBadRequestException.fieldErrors`) flow into the notifier unchanged, so failure UI is exact.
