# Upcoming Tasks

Project tracker for shipped milestones and upcoming engineering work. Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Release & registry launch tracker (v0.1.0 – v0.2.0 deployed)

- [x] Create the `@rpc-dart` organization on npmjs.com (granular access token with `Read and write (publish and stage)` + `Bypass 2FA` enabled).
- [x] Save the npm token as `NPM_TOKEN` in GitHub Actions repository secrets and configure OIDC provenance (`--provenance`).
- [x] Create accounts on pub.dev with a verified publisher (or verified email) for both package owners.
- [x] Enable GitHub Actions OIDC automated publishing (`v{{version}}` tag pattern) in `pub.dev/packages/trpc_dart/admin` and `pub.dev/packages/trpc_flutter/admin`.
- [x] Implement `pubspec_overrides.yaml` for local Dart workspace resolution and update `scripts/prepare-publish.mjs` + `scripts/audit-release.mjs` for clean standalone publishing.
- [x] Merge release PRs after CI passes, tag `v0.1.0` through `v0.2.0`, and verify the idempotent release workflow publishes all 6 packages (`rpc-dart`, `@rpc-dart/core`, `@rpc-dart/trpc-adapter`, `@rpc-dart/dart-generator`, `trpc_dart`, `trpc_flutter`).
- [x] Post-release: verify npm provenance on `npmjs.com/package/rpc-dart` and `@rpc-dart/*`, confirm **160 / 160** `pana` / pub.dev scoring and 100% `dart doc` compliance on both Dart packages, and update all package READMEs with absolute GitHub URLs and registry badges.
- [x] Configure active GitHub Repository Rulesets protecting `main` (required `verify` CI check, linear history, auto-delete merged branches) and `refs/tags/v*` release tags.

## Shipped & verified in v0.1.0 – v0.1.4

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

## Shipped & verified in Milestone v0.2.0 — Real-time subscriptions & streaming

- [x] TypeScript subscription extraction: unwrap tRPC v11 async generator (`AsyncGenerator` / `AsyncIterable`), `tracked(id, data)` envelopes, and `observable` outputs into Contract IR
- [x] SSE link (`HttpSubscriptionLink`) compatible with tRPC v11 `httpSubscriptionLink` (connect / data / ping / serialized-error / normal return completion / `lastEventId` resume frames / idle-timeout detection / `retry:` delay hint)
- [x] WebSocket link (`WsSubscriptionLink`) compatible with tRPC v11 `wsLink` (multiplexed `subscription.start` / `subscription.stop` / `reconnect` notifications / dynamic `connectionParams`)
- [x] `SplitLink` (operation-type router link) to route `query` / `mutation` to `HttpBatchLink` and `subscription` to SSE or WebSocket links seamlessly
- [x] Generator emits `.subscribe(input, {options})` returning `Stream<T>` on subscription procedures with zero-cast `RpcJson` decoding
- [x] Auto-reconnect with exponential backoff + jitter, driven by the shared retry policy, while preserving the latest tracked event ID (`lastEventId`) and stopping cleanly on normal server completion
- [x] Auth token refresh on stream reconnect (single-flight via `AuthLink`, then re-subscribe with updated headers/`connectionParams`)
- [x] Flutter reactive stream bridge in `trpc_flutter` (`RpcSubscriptionState<T>` + `RpcSubscriptionController<T>` `ValueListenable` + `RpcQueryCache` invalidation hook on incoming stream events)
- [x] End-to-end showcase in `examples/trpc-fastify` and `examples/flutter-app` (live SSE & WebSocket subscriptions, `tracked()` resume demo, and stream-driven query cache invalidation UI)
- [x] Wire conformance fixtures for both SSE and WebSocket transports against the pinned Fastify example server in `tests/e2e`
- [x] Documentation: subscriptions guide (`docs/guides/subscriptions.md`) with SSE vs WebSocket setup, `tracked()` resume, backpressure, and cancellation recipes

## Shipped & verified in Milestone v0.3.0 — oRPC adapter & binary/multipart transfers

- [x] `@rpc-dart/orpc-adapter`: extract oRPC contract trees (`@orpc/contract` `oc`) and implemented routers (`@orpc/server` `os` / `implement()`, including inferred handler return types and event iterators) into Contract IR across all `tsconfig.json` profiles
- [x] Standard Schema (`~standard`) interface extraction (Zod, Valibot, ArkType) + `.errors({...})` typed error map extraction beside the tRPC inference harness
- [x] CLI auto-discovery & configuration support for oRPC alongside tRPC (`generate`, `watch`, `check`, `diff`, `doctor`, `init`) via `adapter: 'trpc' | 'orpc' | 'auto'`
- [x] Native `OrpcLink` (oRPC `RPCLink` wire transport) in `trpc_dart` (`{json, meta}` envelopes over slash-delimited pathname routing, plus SSE event-iterator streaming), pinned and conformance-tested against oRPC 1.16.3 (past the CVE-2026-28794 fix)
- [x] Error mapping: `ORPCError` wire payloads (`code`, `status`, `message`, typed `data`, `defined`) → the typed `RpcException` hierarchy via `RpcException.fromOrpcWire`
- [x] First-class binary & file primitives in Contract IR, `@rpc-dart/dart-generator`, and `trpc_dart` (`RpcFile` / `Uint8List` / `RpcByteStream`) with zero-cast serialization
- [x] Multipart file upload support (oRPC indexed file maps on the standard wire; tRPC binary fields via the SuperJSON `registerCustom` base64 convention) with `onSendProgress` byte-progress callbacks
- [x] Binary download & streaming download support with `onReceiveProgress` (`transferredBytes`, `totalBytes`, `fraction`) callbacks and cancellation
- [x] End-to-end wire conformance fixtures (`tests/e2e`) and example showcase (`examples/orpc-fastify` + `flutter-app` oRPC panel) for oRPC procedures, multipart file uploads, and streamed binary downloads
- [x] Monorepo 9-package release governance: `scripts/audit-release.mjs` and `.github/workflows/release.yml` OIDC publish loop cover all five npm packages (`@rpc-dart/core`, `@rpc-dart/trpc-adapter`, `@rpc-dart/orpc-adapter`, `@rpc-dart/dart-generator`, `rpc-dart`) and four Dart packages (`trpc_dart`, `trpc_flutter`, `orpc_dart`, `orpc_flutter`) at lockstep `0.3.0`
- [x] Documentation: oRPC quickstart (`docs/guides/orpc-quickstart.md`), binary & multipart transfers guide (`docs/guides/file-transfers.md`), and updated package READMEs
- [x] `orpc_dart` facade package: re-exports the protocol-agnostic runtime from `trpc_dart` while hiding tRPC-only transports (HTTP batching, SuperJSON, WebSocket); the generator emits `import 'package:orpc_dart/orpc_dart.dart';` for oRPC contracts and keeps `package:trpc_dart/trpc_dart.dart` for tRPC
- [x] `orpc_flutter` facade package: re-exports `orpc_dart` plus the `trpc_flutter` `ValueListenable` bridge for Flutter oRPC clients
- [x] Typed `.errors()` decoding: generated sealed error unions expose `static XError? fromException(RpcException)` — `null` for non-defined errors, the matching variant (or `Unknown`) for defined errors, and nullable `data` (`T?`) that tolerates missing payloads

## Milestone v0.4.0 — Developer tooling & ecosystem

- [ ] Flutter DevTools extension: network inspector for batched requests, active subscriptions, query cache tree, invalidation timeline
- [ ] VS Code / Cursor problem matcher wiring for `RPCDART0xxx` diagnostics in the Problems panel
- [ ] Published convenience adapters: `trpc_flutter_bloc`, `trpc_flutter_riverpod` (thin wrappers over the existing guides)
- [ ] Persistent query cache storage interface with pluggable backends
- [ ] `rpc-dart init --template` scaffolds (Fastify / Express / monorepo)
- [ ] Performance benchmark suite: watch-mode latency and cold-generation budgets in CI
