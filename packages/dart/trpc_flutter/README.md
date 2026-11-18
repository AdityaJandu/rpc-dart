# trpc_flutter

[![pub package](https://img.shields.io/pub/v/trpc_flutter.svg)](https://pub.dev/packages/trpc_flutter)
[![pub points](https://img.shields.io/pub/points/trpc_flutter)](https://pub.dev/packages/trpc_flutter/score)
[![license](https://img.shields.io/github/license/AdityaJandu/rpc-dart.svg)](https://github.com/AdityaJandu/rpc-dart/blob/main/LICENSE)
[![GitHub CI](https://github.com/AdityaJandu/rpc-dart/actions/workflows/ci.yml/badge.svg)](https://github.com/AdityaJandu/rpc-dart/actions/workflows/ci.yml)

Flutter integration for [`trpc_dart`](https://pub.dev/packages/trpc_dart). Bridges cache-backed tRPC queries directly to Flutter's native `ValueListenable` interface for declarative UI rendering.

Part of the [rpc-dart](https://github.com/AdityaJandu/rpc-dart) monorepo.

---

## Why trpc_flutter?

- **Native Flutter primitives:** Bridges query caches to `ValueListenable<RpcAsyncState<T>>` without third-party state management dependencies.
- **Works with any UI pattern:** Drop straight into `ValueListenableBuilder`, `ListenableBuilder`, Riverpod, BLoC, Provider, or vanilla `setState`.
- **Automatic cache synchronization:** UI widgets rebuild when data loads, errors occur, or cache invalidations trigger background refetches.
- **Generated procedure ergonomics:** Call `.listenable(input)` directly on generated procedure instances (`api.user.getById.listenable(input)`).

---

## Installation

Add `trpc_flutter` and `trpc_dart` to your `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  trpc_dart: ^0.2.0
  trpc_flutter: ^0.2.0
```

Then run:

```bash
flutter pub get
```

---

## Quickstart

### 1. Configure the client and root API

```dart
import 'package:flutter/material.dart';
import 'package:trpc_dart/trpc_dart.dart';
import 'package:trpc_flutter/trpc_flutter.dart';
import 'api/api.dart'; // generated bindings

final client = RpcClient(
  endpoint: Uri.parse('https://api.example.com/trpc'),
  transformer: RpcTransformer.superjson,
  links: [
    HttpBatchLink(endpoint: Uri.parse('https://api.example.com/trpc')),
  ],
);

final api = Api(client);
```

### 2. Render with ValueListenableBuilder

```dart
class UserProfileWidget extends StatelessWidget {
  const UserProfileWidget({super.key, required this.userId});

  final String userId;

  @override
  Widget build(BuildContext context) {
    // .listenable(input) returns a ValueListenable<RpcAsyncState<User>>
    return ValueListenableBuilder<RpcAsyncState<User>>(
      valueListenable: api.user.getById.listenable(UserGetByIdInput(id: userId)),
      builder: (context, state, _) => switch (state) {
        RpcAsyncLoading() => const Center(child: CircularProgressIndicator()),
        RpcAsyncError(:final error) => Center(child: Text('Error: $error')),
        RpcAsyncData(:final data) => Text('Welcome, ${data.name}!'),
      },
    );
  }
}
```

When mutations call `client.cache.invalidate(...)`, any active `listenable` referencing the affected keys refetches and updates the widget automatically.

---

## State Management Integration

### Riverpod

Wrap the listenable in a `ValueListenableProvider`:

```dart
final userProfileProvider = Provider.family<ValueListenable<RpcAsyncState<User>>, String>(
  (ref, id) => api.user.getById.listenable(UserGetByIdInput(id: id)),
);
```

### BLoC / Cubit

Listen to the query ref's stream in your Cubit:

```dart
class UserCubit extends Cubit<RpcAsyncState<User>> {
  UserCubit(String userId) : super(const RpcAsyncLoading()) {
    _subscription = api.user.getById
        .watch(UserGetByIdInput(id: userId))
        .stream
        .listen(emit);
  }

  late final StreamSubscription<RpcAsyncState<User>> _subscription;

  @override
  Future<void> close() {
    _subscription.cancel();
    return super.close();
  }
}
```

### Provider

Expose `ValueListenable` with `ValueListenableProvider`:

```dart
ValueListenableProvider<RpcAsyncState<User>>.value(
  value: api.user.getById.listenable(UserGetByIdInput(id: userId)),
  child: const UserView(),
);
```

---

## Links

- [Documentation](https://github.com/AdityaJandu/rpc-dart/blob/main/docs/README.md)
- [Dart Runtime (trpc_dart)](https://pub.dev/packages/trpc_dart)
- [CLI Generator (rpc-dart)](https://www.npmjs.com/package/rpc-dart)
- [Flutter Integration Guides](https://github.com/AdityaJandu/rpc-dart/blob/main/docs/guides/vanilla-flutter.md)
- [GitHub Repository](https://github.com/AdityaJandu/rpc-dart)
- [Issue Tracker](https://github.com/AdityaJandu/rpc-dart/issues)

---

## License

MIT © [Aditya Jandu](https://github.com/AdityaJandu)

## Live subscriptions

`RpcSubscriptionController` binds generated `.subscribe()` streams to a
`ValueListenable<RpcSubscriptionState<T>>`, surfaces a `reconnecting` status
across drops, and can auto-invalidate query-cache prefixes as events arrive:

```dart
final controller = RpcSubscriptionController<String>(
  streamFactory: ({lastEventId, onReconnect}) => api.streams.onActivityFeed
      .subscribe(
        StreamsOnActivityFeedInput(
          lastEventId: lastEventId == null ? null : RpcPresent(lastEventId),
        ),
        options: RpcSubscriptionOptions(
          lastEventId: lastEventId,
          onReconnect: onReconnect,
        ),
      )
      .map((event) => event.message),
  keepHistoryCount: 20,
  queryCache: client.cache,
  invalidatePrefixesOnData: [['streams', 'onActivityFeed']],
)..start();
```
