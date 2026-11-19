# orpc_dart

Pure Dart runtime for [oRPC](https://orpc.unnoq.com) clients. `orpc_dart` is the
protocol-agnostic face of the [`rpc-dart`](https://github.com/AdityaJandu/rpc-dart)
toolchain: generate typed Dart bindings from an oRPC contract or router with the
`rpc-dart` CLI, then call them through `RpcClient` + `OrpcLink`.

It is a thin facade over the [`trpc_dart`](https://pub.dev/packages/trpc_dart)
engine and re-exports only the oRPC and protocol-agnostic surface. tRPC-only
transports (HTTP batching, SuperJSON, WebSocket) are not re-exported.

## Install

```yaml
dependencies:
  orpc_dart: ^0.3.0
```

For Flutter widgets (`ValueListenable` bridges, subscription controllers), add
[`orpc_flutter`](https://pub.dev/packages/orpc_flutter).

## Usage

```dart
import 'package:orpc_dart/orpc_dart.dart';

final endpoint = Uri.parse('https://api.example.com/rpc');
final client = RpcClient(
  endpoint: endpoint,
  links: [OrpcLink(endpoint: endpoint)],
);

// Generated bindings call client.execute(...) under the hood.
final data = await client.execute(RpcRequest(
  path: 'planet.find',
  kind: RpcProcedureKind.query,
  input: <String, Object?>{'id': 1},
));
```

### Binary transfers

```dart
final uploaded = await client.execute(RpcRequest(
  path: 'uploads.avatar',
  kind: RpcProcedureKind.mutation,
  input: <String, Object?>{
    'file': RpcFile.bytes('a.png', bytes, contentType: 'image/png'),
  },
  context: RpcCallContext(
    onSendProgress: (p) => print(p.fraction),
  ),
));
```

### Typed defined errors

Generated `.errors({...})` unions decode straight from a caught exception:

```dart
try {
  await api.planet.find.query(const PlanetFindInput(id: 999));
} on RpcException catch (e) {
  switch (PlanetFindError.fromException(e)) {
    case PlanetFindErrorNOTFOUND(:final data):
      print(data?.id);
    case null:
      print(e.code); // not a defined error
    default:
      break;
  }
}
```

## Documentation

- [oRPC quickstart](https://github.com/AdityaJandu/rpc-dart/blob/main/docs/guides/orpc-quickstart.md)
- [File transfers](https://github.com/AdityaJandu/rpc-dart/blob/main/docs/guides/file-transfers.md)
- [Full documentation](https://github.com/AdityaJandu/rpc-dart/blob/main/docs/README.md)

## License

[MIT](https://github.com/AdityaJandu/rpc-dart/blob/main/LICENSE)