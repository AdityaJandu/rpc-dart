# Changelog

## 0.3.0

- New `adapter: 'trpc' | 'orpc' | 'auto'` target option and `--adapter` flag across `generate`, `watch`, `check`, `diff`, and `doctor`; `auto` (default) probes the export's router shape (`_def` vs `~orpc`) and dispatches to the matching adapter.
- `init` detects oRPC routers (`/contract` / `/server` imports) and records the adapter in the scaffolded config.
- Depends on the new `@rpc-dart/orpc-adapter` package.
- Synchronized v0.3.0 lockstep release.


## 0.2.0

- `generate` / `watch` now emit subscription bindings (`Stream<T> subscribe(...)`) extracted from tRPC v11 async generators, `tracked()` generators, and observables.
- `dart format` stays part of the emit pipeline (introduced in 0.1.4); subscription bindings are format-stable and byte-exact under `check`.
- Generator version bump to v0.2.0 matching monorepo lockstep.

## 0.1.4

- Ships the tsconfig-independent extractor: `generate` / `check` / `watch` / `diff` / `doctor` now work on any backend tsconfig, including `Node16` / `NodeNext` resolution with `verbatimModuleSyntax` and build/lint flags like `noUnusedLocals` or `rootDir` set.
- `generate` (and `watch`) now run `dart format` over the emitted tree when a Dart SDK is available and record post-format content hashes, so generated output is stable under `dart format --set-exit-if-changed` and `rpc-dart check` stays exact on formatted trees. Best-effort: without a Dart SDK the raw emitter bytes are kept, still self-consistent.
- Generator version bump to v0.1.4 matching monorepo lockstep.

## 0.1.3

- Flagship npm README with full CLI command reference and configuration options.
- Generator version bump to v0.1.3 matching monorepo lockstep.

## 0.1.2

- Idempotent OIDC release pipeline and lockstep v0.1.2 package release.

## 0.1.1

- Align repository metadata and packaging rules for automated OIDC publishing.

## 0.1.0

- Initial release.
