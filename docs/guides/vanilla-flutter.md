# Guide: Vanilla Flutter

Using generated bindings without any state-management package: plain `setState`, `FutureBuilder`, and Flutter's built-in `ValueListenableBuilder`.

Setup assumed from the [README](../../README.md) quickstart:

```dart
final client = RpcClient(
  endpoint: Uri.parse('https://api.example.com/trpc'),
  transformer: RpcTransformer.superjson,
  links: RpcLinkChain([HttpBatchLink()]),
);
final api = Api(client);
```

## 1. One-shot calls with setState

```dart
class UserPage extends StatefulWidget {
  const UserPage({super.key, required this.userId});
  final String userId;

  @override
  State<UserPage> createState() => _UserPageState();
}

class _UserPageState extends State<UserPage> {
  UserGetByIdOutput? _user;
  Object? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final user = await api.user.getById.query(UserGetByIdInput(id: widget.userId));
      if (!mounted) return;
      setState(() => _user = user);
    } on RpcException catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const CircularProgressIndicator();
    if (_error != null) return Text('failed: $_error');
    return Text(_user?.id ?? '-');
  }
}
```

Typed exceptions make error branching direct — no string matching on messages:

```dart
try {
  await api.user.getById.query(const UserGetByIdInput(id: '1'));
} on RpcUnauthorizedException {
  Navigator.pushNamed(context, '/login');
} on RpcBadRequestException catch (e) {
  final fieldErrors = e.fieldErrors;   // Map<String, List<String>> from the server's zod data
}
```

## 2. FutureBuilder with the non-throwing variant

`safeQuery` returns `RpcResult<T>` and never throws, which maps cleanly onto `AsyncSnapshot`-style UI:

```dart
FutureBuilder<RpcResult<UserGetByIdOutput>>(
  future: api.user.getById.safeQuery(UserGetByIdInput(id: widget.userId)),
  builder: (context, snapshot) {
    if (!snapshot.hasData) return const CircularProgressIndicator();
    return switch (snapshot.data!) {
      RpcSuccess(:final data) => Text(data.id),
      RpcFailure(:final error) => Text('failed: ${error.message}'),
    };
  },
);
```

## 3. Reactive UI with ValueListenableBuilder

The built-in cache can own the state. `.listenable(...)` (from `trpc_flutter`) wraps the cache-backed query in a `ValueListenable`; the widget rebuilds whenever the query refetches, errors, or gets invalidated:

```dart
import 'package:trpc_flutter/trpc_flutter.dart';

class UserCard extends StatelessWidget {
  const UserCard({super.key, required this.api, required this.userId});
  final Api api;
  final String userId;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<RpcAsyncState<UserGetByIdOutput>>(
      valueListenable: api.user.getById.listenable(UserGetByIdInput(id: userId)),
      builder: (context, state, _) => switch (state) {
        RpcAsyncLoading() => const CircularProgressIndicator(),
        RpcAsyncError(:final error) => Text('error: $error'),
        RpcAsyncData(:final data) => Text('id: ${data.id}, nickname: ${data.nicknameOrNull}'),
      },
    );
  }
}
```

Behavior details:

- The first listener triggers the fetch; state replays immediately to new listeners.
- Calling `api.invalidate(api.user.pathKey())` after a mutation refetches this query and the listenable updates on its own.
- Explicit refresh: grab the ref once and call `refetch()`:

```dart
final ref = api.user.getById.watch(UserGetByIdInput(id: widget.userId));
await ref.refetch();
```

## 4. Mutations and the three-state optionality

`RpcOpt<T>` distinguishes omitted, explicit null, and present — exactly what PATCH endpoints need:

```dart
await api.user.update.mutate(UpdateUserInput(
  name: RpcPresent('Ada'),          // {"name": "Ada"}
  nickname: const RpcNull(),        // {"nickname": null} — clears it
  // nickname: const RpcAbsent()    // key omitted — server keeps the old value
));

api.invalidate(api.user.pathKey()); // every watched 'user.*' query refetches
```

## 5. Cancellation on navigation

```dart
final _token = CancelToken();

@override
void dispose() {
  _token.cancel(reason: 'left the page');
  super.dispose();
}

// started with the token:
await api.user.getById.query(input, context: RpcCallContext(cancelToken: _token));
```

A cancelled call completes with `RpcCancelledException` and never delivers data to a disposed widget.
