# Upcoming Tasks

Project tracker for shipped milestones and upcoming engineering work. Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Release & registry launch tracker (v0.1.0 – v0.1.3 deployed)

- [x] Create the `@rpc-dart` organization on npmjs.com (granular access token with `Read and write (publish and stage)` + `Bypass 2FA` enabled).
- [x] Save the npm token as `NPM_TOKEN` in GitHub Actions repository secrets and configure OIDC provenance (`--provenance`).
- [x] Create accounts on pub.dev with a verified publisher (or verified email) for both package owners.
- [x] Enable GitHub Actions OIDC automated publishing (`v{{version}}` tag pattern) in `pub.dev/packages/trpc_dart/admin` and `pub.dev/packages/trpc_flutter/admin`.
- [x] Implement `pubspec_overrides.yaml` for local Dart workspace resolution and update `scripts/prepare-publish.mjs` + `scripts/audit-release.mjs` for clean standalone publishing.
- [x] Merge release PRs after CI passes, tag `v0.1.0` through `v0.1.3`, and verify the idempotent release workflow publishes all 6 packages (`rpc-dart`, `@rpc-dart/core`, `@rpc-dart/trpc-adapter`, `@rpc-dart/dart-generator`, `trpc_dart`, `trpc_flutter`).
- [x] Post-release: verify npm provenance on `npmjs.com/package/rpc-dart` and `@rpc-dart/*`, confirm **160 / 160** `pana` / pub.dev scoring and 100% `dart doc` compliance on both Dart packages, and update all package READMEs with absolute GitHub URLs and registry badges.
- [x] Configure active GitHub Repository Rulesets protecting `main` (required `verify` CI check, linear history, auto-delete merged branches) and `refs/tags/v*` release tags.

## Shipped & verified in v0.1.0 – v0.1.3

- [x] TypeScript extractor: route discovery probe + public-inference ts harness (`inferRouterInputs` / `inferRouterOutputs` per-path aliases)
- [x] Contract IR v1: normalized type registry, canonical JSON serialization, SHA-256 content hash
- [x] Pure-Dart emitter: immutable models, `copyWith` / `==` / `hashCode` / `fromJson` / `toJson`, zero `as` casts, byte-deterministic output
- [x] `RpcOpt<T>` three-state optionality (absent / null / present) with generated PATCH semantics
- [x] Type torture coverage: recursive objects, records, maps, sets, tuples, numeric literal unions, discriminated unions with unknown fallbacks, branded strings
- [x] Structured diagnostics (RPCDART0101–0204) with file/line/column, policies (`error` / `warn-dynamic` per-field / `skip-procedure`)
- [x] `RpcLink` pipeline: `AuthLink` single-flight refresh, `ContextLink` merge precedence + correlation ids, `RetryLink` mutation idempotency guard, `LoggingLink` secret redaction, cancellation + timeouts
- [x] `RpcQueryCache`: structural keys, prefix invalidation, optimistic writes, `ValueListenable` bridge
- [x] All 7 CLI commands (`generate`, `watch`, `check`, `diff`, `clean`, `doctor`, `init`) with zero-config auto-discovery and multi-project support
- [x] Fastify + Flutter end-to-end suite over the real wire (batching, SuperJSON, typed errors, invalidation)
- [x] Zero-cast `RpcJson` decoding with field breadcrumb paths and int → double coercion
- [x] Website-structured documentation suite, comprehensive package-level READMEs, and 7-gate release audit tooling

## Milestone v0.2.0 — Real-time subscriptions & streaming

- [x] TypeScript subscription extraction: unwrap tRPC v11 async generator (`AsyncGenerator` / `AsyncIterable`), `tracked(id, data)` envelopes, and `observable` outputs into Contract IR
- [x] SSE link (`HttpSubscriptionLink`) compatible with tRPC v11 `httpSubscriptionLink` (connect / data / ping / serialized-error / normal return completion / `lastEventId` resume frames)
- [x] WebSocket link (`WsSubscriptionLink`) compatible with tRPC v11 `wsLink` (multiplexed `subscription.start` / `subscription.stop` / `reconnect` notifications / dynamic `connectionParams`)
- [x] `SplitLink` (operation-type router link) to route `query` / `mutation` to `HttpBatchLink` and `subscription` to SSE or WebSocket links seamlessly
- [x] Generator emits `.subscribe(input, {options})` returning `Stream<T>` on subscription procedures with zero-cast `RpcJson` decoding
- [x] Auto-reconnect with exponential backoff + jitter, driven by the shared retry policy, while preserving the latest tracked event ID (`lastEventId`) and stopping cleanly on normal server completion
- [x] Auth token refresh on stream reconnect (single-flight via `AuthLink`, then re-subscribe with updated headers/`connectionParams`)
- [x] Flutter reactive stream bridge in `trpc_flutter` (`RpcSubscriptionState<T>` + `RpcSubscriptionController<T>` `ValueListenable` + `RpcQueryCache` invalidation hook on incoming stream events)
- [x] End-to-end showcase in `examples/trpc-fastify` and `examples/flutter-app` (live SSE & WebSocket subscriptions, `tracked()` resume demo, and stream-driven query cache invalidation UI)
- [x] Wire conformance fixtures for both SSE and WebSocket transports against the pinned Fastify example server in `tests/e2e`
- [x] Documentation: subscriptions guide (`docs/guides/subscriptions.md`) with SSE vs WebSocket setup, `tracked()` resume, backpressure, and cancellation recipes


## Milestone v0.3.0 — oRPC adapter & binary/multipart transfers

- [ ] `@rpc-dart/orpc-adapter`: extract oRPC contract trees into Contract IR
- [ ] Standard Schema interface extraction beside the tRPC inference harness
- [ ] Native RPCLink wire transport in Dart (`{json, meta}` envelopes over pathname routing)
- [ ] Error mapping: `ORPCError` codes → the typed `RpcException` hierarchy
- [ ] Multipart file upload support (Fastify + Dart client conformance fixtures)
- [ ] Binary download/streaming download support with progress events
- [ ] Documentation: oRPC quickstart mirroring the tRPC one

## Milestone v0.4.0 — Developer tooling & ecosystem

- [ ] Flutter DevTools extension: network inspector for batched requests, active subscriptions, query cache tree, invalidation timeline
- [ ] VS Code / Cursor problem matcher wiring for `RPCDART0xxx` diagnostics in the Problems panel
- [ ] Published convenience adapters: `trpc_flutter_bloc`, `trpc_flutter_riverpod` (thin wrappers over the existing guides)
- [ ] Persistent query cache storage interface with pluggable backends
- [ ] `rpc-dart init --template` scaffolds (Fastify / Express / monorepo)
- [ ] Performance benchmark suite: watch-mode latency and cold-generation budgets in CI
