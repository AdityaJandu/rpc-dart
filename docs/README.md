# rpc-dart Documentation

End-to-end type safety for tRPC v11 and oRPC backends consumed from Dart and Flutter. The `rpc-dart` CLI reads your TypeScript router or oRPC contract and generates plain, build-tool-free Dart bindings; the `trpc_dart` runtime — plus the `orpc_dart` / `orpc_flutter` facades for oRPC — executes them over the real tRPC and oRPC wire protocols with a composable link pipeline and a built-in, state-management-agnostic query cache.

## Architecture at a glance

```text
TypeScript router ──► rpc-dart CLI ──► generated Dart bindings ──► Dart runtime ──► tRPC / oRPC server
                      (Route probe     (lib/src/api/ in      (trpc_dart: HttpBatchLink + SuperJSON
                       ts harness +     your Flutter app,     orpc_dart: OrpcLink + {json, meta}
                       Contract IR +    zero casts,           + RpcJson decoding + query cache
                       SHA-256 hash)    no build_runner)      + composable links)
```

Rename a procedure or change a Zod field on the server: the Dart bindings regenerate incrementally and the analyzer breaks at every stale call site. No route strings, no hand-written models, no `build_runner`.

## Table of contents

| # | Document | What you learn |
|---|---|---|
| 1 | [Installation](getting-started/installation.md) | Prerequisites, npm & pub.dev setup, `rpc-dart init`, config schema |
| 2 | [Quickstart](getting-started/quickstart.md) | A 5-minute end-to-end Fastify + Flutter tutorial |
| 3 | [How it works](concepts/how-it-works.md) | The 5-stage compiler pipeline and runtime engine, in depth |
| 4 | [Type mapping](concepts/type-mapping.md) | Complete TS → Dart mapping, `z.input` vs `z.output`, unions, enums, diagnostics |
| 5 | [Links and auth](concepts/links-and-auth.md) | The `RpcLink` pipeline, single-flight token refresh, retries, logging |
| 6 | [Vanilla Flutter](guides/vanilla-flutter.md) | `setState`, `FutureBuilder`, `ValueListenableBuilder` |
| 7 | [BLoC](guides/bloc.md) | Cubit & Bloc integration with reactive auto-refresh |
| 8 | [Provider](guides/provider.md) | `ChangeNotifier` integration with optimistic updates |
| 9 | [Riverpod](guides/riverpod.md) | `FutureProvider.family` / `AsyncNotifier` patterns |
| 10 | [Subscriptions](guides/subscriptions.md) | SSE & WebSocket streaming, `tracked()` resume, `RpcSubscriptionController` |
| 11 | [oRPC quickstart](guides/orpc-quickstart.md) | oRPC contracts & routers, `OrpcLink`, typed error maps, wire notes |
| 12 | [File & binary transfers](guides/file-transfers.md) | `RpcFile`, multipart uploads, streaming downloads, progress callbacks |
| 13 | [Monorepo & CI](guides/monorepo-and-ci.md) | pnpm/Turborepo setup, watch mode, GitHub Actions gates |
| 14 | [CLI reference](reference/cli.md) | All 7 commands, flags, config schema, exit codes |
| 15 | [Dart runtime API](reference/dart-runtime-api.md) | `RpcClient`, `RpcOpt`, `RpcResult`, `RpcQueryCache`, `RpcJson`, links |
| 16 | [Troubleshooting](reference/troubleshooting.md) | Diagnostic codes, doctor checks, common monorepo fixes |

## Where to start

- New project: [Installation](getting-started/installation.md) → [Quickstart](getting-started/quickstart.md).
- oRPC backend: [oRPC quickstart](guides/orpc-quickstart.md) → [File & binary transfers](guides/file-transfers.md).
- Evaluating: [How it works](concepts/how-it-works.md) → [Type mapping](concepts/type-mapping.md).
- Debugging: [Troubleshooting](reference/troubleshooting.md).

## Roadmap

See [UPCOMING_TASKS.md](../UPCOMING_TASKS.md) for shipped milestones and upcoming work. Shipped: real-time subscriptions & streaming (v0.2.0), and the oRPC adapter, the `orpc_dart` / `orpc_flutter` facades, and binary/multipart transfers (v0.3.0). Up next: developer tooling & ecosystem (v0.4.0).

← [Back to repository root](../README.md) | Next: Installation →
