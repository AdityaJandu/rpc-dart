# example_flutter_app

Full-stack showcase consuming generated `trpc_dart` bindings over the real wire:
query/mutation with PATCH semantics, cursor pagination, typed errors, cache
invalidation, and the built-in `ValueListenable` bridge.

Platform folders (android/ios/linux/macos/web/windows) are committed, so the
app runs out of the box — no `flutter create .` needed.

## Prerequisites

- Flutter SDK (any channel, Dart >= 3.6)
- Node.js >= 23.6 (plain `node` runs the TypeScript server via built-in type
  stripping; on Node 22 use >= 22.18 or add `--experimental-strip-types`)

## Run it

1. Start the tRPC example server (from the repo root):

   ```sh
   cd examples/trpc-fastify
   npm install
   npm run dev
   ```

   The server listens on `http://127.0.0.1:8787/trpc`.

2. Run the Flutter app (in a second terminal):

   ```sh
   cd examples/flutter-app
   flutter pub get
   flutter run
   ```

   The Dart packages resolve via path dependencies into `packages/dart/` —
   always run from inside this repository checkout.

## Auth

The app sends `Authorization: Bearer demo-token` through `AuthLink`. The
example server only recognizes that exact token; `user.me` and `user.update`
are protected, everything else is public.

## Tests

```sh
flutter test
```

`test/showcase_test.dart` runs the suite over the real wire against a spawned
fixture server (mutations with absent-vs-null PATCH semantics, cursor
pagination, unauthorized errors, and the listenable bridge rendering live
states).

## Regenerating bindings

If you change the tRPC routers in `examples/trpc-fastify/src/server.ts`, point
the CLI at the example root (zero-config auto-discovery):

```sh
node ../../packages/typescript/cli/dist/index.js generate
```

Then `flutter pub get` if new output files appear.
