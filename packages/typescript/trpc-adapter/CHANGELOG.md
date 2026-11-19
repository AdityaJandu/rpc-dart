# Changelog

## 0.3.0

- Binary type extraction: `Uint8Array` / `ArrayBuffer` / `Buffer` map to `Bytes`, `File` / `Blob` to `File`, `ReadableStream<Uint8Array>` to `ByteStream`.
- Type classifier and compiler host moved to `@rpc-dart/core` (shared with `@rpc-dart/orpc-adapter`); behavior unchanged across all five tsconfig profiles.
- `source.adapterVersion` and `generator.version` now report the real package version (previously stale constants).
- Synchronized v0.3.0 lockstep release.


## 0.2.0

- Subscription extraction: unwraps tRPC v11 async generators, `tracked()` envelopes, and observables down to the streamed item type; emits `supportsLastEventId` procedure metadata.
- New subscription extraction fixture coverage across async generator, tracked, observable, and never-yield shapes.

## 0.1.4

- Full `tsconfig.json` independence in type extraction: projects using `moduleResolution: node16` / `nodenext` extract correctly, with the harness emitting explicit `.js` / `.mjs` / `.cjs` entry specifiers (including `.tsx`).
- Build/lint-only compiler options are neutralized during extraction regardless of the user's tsconfig (`noEmit`, `declaration`, `declarationMap`, `composite`, `incremental`, `isolatedDeclarations`, `noUnusedLocals`, `noUnusedParameters`, `rootDir`), so flags like `noUnusedLocals: true` or a `composite`/`rootDir: './src'` build config can no longer fail contract extraction.
- Extraction verified across five backend tsconfig profiles (CommonJS + node10, ESNext + bundler, NodeNext, NodeNext + `verbatimModuleSyntax` + `erasableSyntaxOnly` + `allowImportingTsExtensions`, and composite build flags) via new table-driven tests.

## 0.1.3

- Package README documentation with absolute links for registry viewing.
- Synchronized v0.1.3 lockstep release.

## 0.1.2

- Idempotent OIDC release pipeline and lockstep v0.1.2 package release.

## 0.1.1

- Align repository metadata and packaging rules for automated OIDC publishing.

## 0.1.0

- Initial release.
