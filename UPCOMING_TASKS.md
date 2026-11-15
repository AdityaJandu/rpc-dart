# Upcoming Tasks

Project tracker for shipped milestones and upcoming engineering work. Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Release & registry launch tracker (v0.1.0 deployment)

- [ ] Create the `@rpc-dart` organization on npmjs.com ( granular access token with `Read and write (publish and stage)` + `Bypass 2FA` enabled).
- [ ] Save the npm token as `NPM_TOKEN` in GitHub Actions repository secrets.
- [ ] Create accounts on pub.dev with a verified publisher (or verified email) for both package owners.
- [ ] Enable GitHub Actions OIDC automated publishing (`v{{version}}` tag pattern) in `pub.dev/packages/trpc_dart/admin` and `pub.dev/packages/trpc_flutter/admin`.
- [ ] Run `node scripts/prepare-publish.mjs` to strip local-only markers and set hosted constraints, then publish `trpc_dart` followed by `trpc_flutter` to register both on pub.dev (or let the tag-triggered workflow handle it).
- [ ] Merge the `release/v0.1.0` PR after the CI workflow passes, tag `v0.1.0`, and verify the release workflow publishes all 6 packages.
- [ ] Post-release: verify npm provenance on `npmjs.com/package/@rpc-dart/cli`, confirm pub.dev scoring on both packages, and update the README badges.

## Shipped & verified in v0.1.0

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
- [x] Website-structured documentation suite and release audit tooling

## Milestone v0.2.0 — Real-time subscriptions & streaming

- [ ] SSE link compatible with tRPC v11 `httpSubscriptionLink` (connect / data / ping / resume frames)
- [ ] WebSocket link compatible with tRPC v11 `wsLink` (subscription.start / stop / reconnect notifications)
- [ ] Generator emits `.subscribe(input)` returning `Stream<T>` on subscription procedures
- [ ] Auto-reconnect with exponential backoff + jitter, driven by the shared retry policy
- [ ] Auth token refresh on stream reconnect (single-flight, then re-subscribe)
- [ ] Wire conformance fixtures for both transports against the pinned example server
- [ ] Documentation: subscriptions guide with backpressure and cancellation recipes

## Milestone v0.3.0 — oRPC adapter & binary/multipart transfers

- [ ] `@rpc-dart/orpc-adapter`: extract oRPC contract trees into Contract IR
- [ ] Standard Schema interface extraction beside the tRPC inference harness
- [ ] Native RPCLink wire transport in Dart (`{json, meta}` envelopes over pathname routing)
- [ ] Error mapping: `ORPCError` codes → the typed `RpcException` hierarchy
- [ ] Multipart file upload support (Fastify + Dart client conformance fixtures)
- [ ] Binary download/streaming download support with progress events
- [ ] Documentation: oRPC quickstart mirroring the tRPC one

## Milestone v0.4.0 — Developer tooling & ecosystem

- [ ] Flutter DevTools extension: network inspector for batched requests, query cache tree, invalidation timeline
- [ ] VS Code / Cursor problem matcher wiring for `RPCDART0xxx` diagnostics in the Problems panel
- [ ] Published convenience adapters: `trpc_flutter_bloc`, `trpc_flutter_riverpod` (thin wrappers over the existing guides)
- [ ] Persistent query cache storage interface with pluggable backends
- [ ] `rpc-dart init --template` scaffolds (Fastify / Express / monorepo)
- [ ] Performance benchmark suite: watch-mode latency and cold-generation budgets in CI
