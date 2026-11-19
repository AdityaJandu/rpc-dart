# oRPC + Fastify example

oRPC backend showcasing rpc-dart's `@rpc-dart/orpc-adapter` and the binary /
multipart transfer runtime: typed queries with defined errors, multipart file
uploads, root-file and streaming downloads, and resumable event iterators.

## Run

```bash
pnpm install            # from the monorepo root
pnpm --filter @rpc-dart/example-orpc-fastify dev
# oRPC example server listening on http://127.0.0.1:8788/rpc
```

## Regenerate the Flutter bindings

```bash
cd examples/orpc-fastify
node ../../packages/typescript/cli/bin/rpc-dart.js generate
```

Bindings land in `../flutter-app/lib/src/orpc_api`. Run the oRPC showcase:

```bash
cd ../flutter-app
flutter run -t lib/orpc_main.dart
```

The existing tRPC showcase (`flutter run`) is unaffected; both protocols live
side by side in the same app package.

## What to look at

- `src/server.ts` — contract-first router (`oc` + `implement`), `.errors()`
  maps, `eventIterator` with `withEventMeta` resume ids, and the Fastify
  `RPCHandler` mount with the no-op multipart content-type parser.
- `rpc-dart.config.json` — `adapter: "orpc"` (auto-detection also works).
- `../flutter-app/lib/src/orpc_showcase.dart` — upload/download progress,
  streaming downloads, and live ticks over `OrpcLink`.