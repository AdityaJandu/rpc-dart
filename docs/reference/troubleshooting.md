# Troubleshooting

Diagnostic codes, doctor checks, and the most common monorepo and path-alias fixes.

← Previous: Dart runtime API | Documentation Home →

## Diagnostic codes

| Code | Meaning | Fix |
|---|---|---|
| RPCDART0101 | config invalid / unparseable | check `rpc-dart.config.json` syntax |
| RPCDART0102 | entry export not found / not a router | `export const appRouter = t.router({...})` + `export type AppRouter` |
| RPCDART0103 | tsconfig missing or unparseable | point `--tsconfig`/`tsconfig` at the backend tsconfig |
| RPCDART0104 | tRPC version unknown/unsupported | pin tRPC v11.x |
| RPCDART0105 | harness type-check failure | fix the underlying TypeScript error (error types would silently corrupt bindings) |
| RPCDART0106 | per-procedure type resolution failure | make sure the procedure returns a value |
| RPCDART0107 | Dart outDir missing | create the Flutter package or fix `dart.outDir` |
| RPCDART0108 | runtime probe degraded | router module threw on import; fix side effects or set `probe: off` |
| RPCDART0201 | unserializable type (Function, Symbol, Promise, class instance) | remove from the schema, or set `unserializablePolicy` |
| RPCDART0202 | non-discriminated object union | add a literal tag field (`z.discriminatedUnion`) |
| RPCDART0203 | unmappable key type | use string or enum keys for records/maps |
| RPCDART0204 | unknown-policy collision | align `unknownPolicy` with the schema |

## Doctor checks

Run `rpc-dart doctor` for a pass/warn/fail checklist: Node ≥ 20, tsconfig parse, router export extraction, Dart SDK, Flutter SDK (warn-only), and npm↔pub version alignment.

## Common issues

### Path aliases don't resolve

The CLI type-checks your code with your own tsconfig, including path aliases. If aliases fail: run the CLI from the backend workspace root (where `tsconfig.json` lives), or pass `--tsconfig` explicitly. `baseUrl`/`paths` are honored.

### "Cannot find module" during extraction

The entry file is resolved relative to the tsconfig's directory. In multi-package repos, set `entry` relative to the tsconfig (e.g. `src/trpc/router.ts`) and keep side effects out of the router module — it is imported in-process for metadata probing.

### Flutter analyzer errors in generated code

Generated code compiles clean under `dart analyze --fatal-infos --fatal-warnings` against `trpc_dart`. If it fails after a runtime upgrade, your generated bindings were produced by an older CLI: run `rpc-dart generate --force`.

### 400 errors in tests but curl works

If the test binding (e.g. `flutter test` with widget bindings) intercepts HTTP, spawn the backend as a child process and avoid widget-bound network calls; use plain `test()` with `RpcClient`, as the example app does.

### Query cache holds stale data after mutations

Invalidation is explicit. After a mutation call `api.invalidate(api.user.pathKey)` (or add declarative tags). Optimistic updates use `setQueryData` with rollback.

### Batch request returns 207 with mixed results

That is normal: per-item error envelopes are demultiplexed — failed items complete with typed exceptions, successful items complete normally.

## Still stuck

Search the [issue tracker](https://github.com/AdityaJandu/rpc-dart/issues) or open a new one with the diagnostic output and a minimal router fixture.

← Previous: Dart runtime API | Documentation Home →
