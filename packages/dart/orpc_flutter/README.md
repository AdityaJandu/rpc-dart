# orpc_flutter

Flutter integration for [oRPC](https://orpc.unnoq.com) clients. Combines the
[`orpc_dart`](https://pub.dev/packages/orpc_dart) runtime with a
protocol-agnostic Flutter bridge: `ValueListenable` over cache-backed queries
for `ValueListenableBuilder`, Riverpod, BLoC, and Provider, plus
`RpcSubscriptionController` for real-time event iterators.

Thin facade over [`trpc_flutter`](https://pub.dev/packages/trpc_flutter); tRPC-only
transports are not re-exported.

## Install

```yaml
dependencies:
  orpc_flutter: ^0.3.0
```

## Usage

```dart
import 'package:orpc_flutter/orpc_flutter.dart';

// Cache-backed query as a ValueListenable (generated procedure).
final listenable = api.planet.find.listenable(const PlanetFindInput(id: 1));

ValueListenableBuilder<RpcAsyncState<PlanetFindOutput>>(
  valueListenable: listenable,
  builder: (context, state, _) => switch (state) {
    RpcAsyncData(:final data) => Text(data.name),
    RpcAsyncLoading() => const CircularProgressIndicator(),
    RpcAsyncError(:final error) => Text('$error'),
  },
);
```

### Real-time subscriptions

```dart
final controller = RpcSubscriptionController<int>(
  streamFactory: ({lastEventId, onReconnect}) => api.streams.ticks.subscribe(
    const StreamsTicksInput(count: 100),
    options: RpcSubscriptionOptions(
      lastEventId: lastEventId,
      onReconnect: onReconnect,
    ),
  ).map((event) => event.tick),
);
controller.start();
```

## Documentation

- [oRPC quickstart](https://github.com/AdityaJandu/rpc-dart/blob/main/docs/guides/orpc-quickstart.md)
- [Full documentation](https://github.com/AdityaJandu/rpc-dart/blob/main/docs/README.md)

## License

[MIT](https://github.com/AdityaJandu/rpc-dart/blob/main/LICENSE)