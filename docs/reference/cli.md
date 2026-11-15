# CLI reference

All 7 commands, every flag, the config schema, and exit codes.

← Previous: Monorepo & CI | Next: Dart runtime API →

## Commands

### generate

Extracts the router and writes Dart bindings. Hash-gated: writes only when the contract changed, deletes stale files via the manifest.

```bash
rpc-dart generate                    # zero flags: uses rpc-dart.config.json (or .ts)
rpc-dart generate --out ../mobile/lib/src/api   # flags override config values
rpc-dart generate --force            # rewrite even when the hash is unchanged
```

### watch

Incremental mode: file saves trigger extract → hash compare → re-emit only on change. Transient TypeScript errors never touch disk.

```bash
rpc-dart watch [--debounce-ms 300]
```

### check

Non-destructive CI gate. Re-extracts the contract, compares the manifest hash and per-file content hashes against disk. Exit `3` on drift.

```bash
rpc-dart check
```

### diff

Compares the current contract against a committed IR snapshot and categorizes changes.

```bash
rpc-dart diff --baseline ir.snapshot.json                  # compare
rpc-dart diff --baseline ir.snapshot.json --update-baseline  # write snapshot
rpc-dart diff … --fail-on-breaking                          # exit 4 on breaking changes
```

Breaking: procedure removed / renamed / kind changed, required input field added, input or output type changed, output nullability changed. Non-breaking: procedure added, optional input field added, input field removed, output field added.

### clean

Deletes exactly the files listed in the manifest — never globs. Refuses (exit 1) when no manifest exists.

### doctor

Environment + workspace checklist: Node version, tsconfig resolution, router export extraction, Dart/Flutter SDK presence, npm↔pub version alignment. Exit `5` when any check fails.

### init

Detects tsconfig, router files (`initTRPC` scan), and sibling/child Flutter targets; writes `rpc-dart.config.ts`. Refuses to overwrite.

## Flags

| Flag | Applies to | Meaning |
|---|---|---|
| `--config <path>` | all | Explicit config file (`.json` or `.ts`); default: auto-discovery in cwd |
| `--tsconfig <path>` | generate/watch/check/diff | Overrides `tsconfig` from config |
| `--entry <file>` | generate/watch/check/diff | Overrides `entry` |
| `--export <name>` | generate/watch/check/diff | Overrides `exportName` |
| `--out <dir>` | generate/watch/check/clean | Overrides `dart.outDir` |
| `--baseline <path>` | diff | Snapshot path (default `ir.snapshot.json`) |
| `--update-baseline` | diff | Write the current contract as the new baseline |
| `--fail-on-breaking` | diff | Exit 4 when breaking changes exist |
| `--force` | generate | Rewrite files even when the hash is unchanged |
| `--debounce-ms <n>` | watch | Coalescing window (default 300) |

## Config schema (`rpc-dart.config.json`)

| Field | Type | Default | Meaning |
|---|---|---|---|
| `tsconfig` | string | `"tsconfig.json"` | Backend tsconfig path (relative to the config file) |
| `entry` | string | required | Module exporting the router |
| `exportName` | string | required | Exported router const name |
| `transformer` | `"superjson"` \| `"json"` | `"superjson"` | Must match the server's initTRPC transformer |
| `dart.outDir` | string | required | Generated bindings root |
| `dart.packagePath` | string? | — | Flutter package dir (used by doctor) |
| `policies.unserializablePolicy` | `"error"` \| `"warn-dynamic"` \| `"skip-procedure"` | `"error"` | Escape hatch for unserializable types |
| `projects` | array | — | Multi-target generation; each entry is a full target |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Generic failure (extraction diagnostic at error level) |
| 2 | Configuration error — no config found / unknown command (message suggests `rpc-dart init`) |
| 3 | `check` drift |
| 4 | `diff --fail-on-breaking` with breaking changes |
| 5 | `doctor` failing checks |

← Previous: Monorepo & CI | Next: Dart runtime API →
