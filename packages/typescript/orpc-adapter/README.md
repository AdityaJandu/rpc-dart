# @rpc-dart/orpc-adapter

oRPC extraction adapter for [rpc-dart](https://github.com/AdityaJandu/rpc-dart): turns `@orpc/contract` contract trees (`oc`) and `@orpc/server` routers (`os`, `implement()`) into the shared Contract IR that `@rpc-dart/dart-generator` emits typed Dart/Flutter bindings from.

## What it extracts

- Procedure inputs and outputs from any Standard Schema v1 library (Zod, Valibot, ArkType, oRPC's `type<T>()`), resolved through oRPC's public inference helpers (`InferContractRouterInputs/Outputs`, `InferRouterInputs/Outputs`).
- Handler-inferred output types for procedures without `.output()`.
- `eventIterator` outputs (declared or handler-inferred async generators) as subscription item types.
- `.errors({...})` typed error maps as discriminated unions on `code`, including per-code `data` schemas.
- `.route({ method, path })` metadata (informational: the oRPC RPC wire always routes by slash-delimited procedure path).
- Binary types: `Uint8Array` / `ArrayBuffer` / `Buffer` → `Bytes`, `File` / `Blob` → `File`, `ReadableStream<Uint8Array>` → `ByteStream`.
- Lazy routers (`lazy(() => import(...))`), resolved at probe and type level.

## Usage

```ts
import { extractContract } from '@rpc-dart/orpc-adapter';

const { ir, diagnostics } = await extractContract({
  tsconfigPath: './tsconfig.json',
  entryFile: 'src/router.ts',
  exportName: 'appRouter',
});
```

Most users reach this package through the `rpc-dart` CLI, which auto-detects oRPC exports (`adapter: 'auto'`).

## Design notes

- The adapter has **no `@orpc/*` dependency**: your project supplies oRPC at extraction time, and the runtime probe feature-detects `~orpc` procedure definitions.
- Extraction runs against your own `tsconfig.json` with build/lint-only flags neutralized in an in-memory program; the type harness is overlaid without touching disk. CommonJS, bundler, and NodeNext profiles are covered by tests.
- The type classifier and compiler host are shared with `@rpc-dart/trpc-adapter` via `@rpc-dart/core`.
- Event-iterator **inputs** (client-to-server streaming) are rejected with `RPCDART0201`; policies `warn-dynamic` and `skip-procedure` apply as with tRPC.

## License

MIT