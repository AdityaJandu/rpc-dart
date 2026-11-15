# Monorepo & CI

pnpm/Turborepo setup, watch mode alongside your backend dev server, and GitHub Actions gates that keep generated bindings honest.

← Previous: Riverpod | Next: CLI reference →

## Workspace layout

```text
my-project/
├── apps/
│   ├── backend/          # Fastify + tRPC v11 + Zod
│   └── mobile/           # Flutter app
├── packages/
└── rpc-dart.config.ts    # at the backend workspace root
```

```typescript
import { defineConfig } from 'rpc-dart';

export default defineConfig({
  tsconfig: 'tsconfig.json',
  entry: './src/trpc/router.ts',
  exportName: 'appRouter',
  dart: { outDir: '../mobile/lib/src/api' },
});
```

Multi-target workspaces (admin + mobile consumers) use the `projects` array — see [Installation](../getting-started/installation.md).

## Watch mode

Run the watcher alongside your backend dev server:

```bash
npx rpc-dart watch        # or: npx rpc-dart watch --debounce-ms 500
```

- TypeScript saves trigger extract → hash compare → re-emit only when the contract changed.
- Transient errors while you type never touch disk (last-good output is preserved).
- Add both processes to your `concurrently`/`turbo dev` pipeline:

```json
{
  "scripts": {
    "dev": "concurrently \"tsx watch src/server.ts\" \"rpc-dart watch\""
  }
}
```

## Commit generated bindings

Generated code is deterministic (same router → byte-identical output), so commit `lib/src/api/`. Reviewers see binding diffs in PRs — a rename shows exactly which call sites break.

## GitHub Actions gates

```yaml
name: bindings
on:
  pull_request:
  push:
    branches: [main]
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - run: npm ci
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
      - run: flutter pub get
        working-directory: apps/mobile
      - name: Regenerate and verify no drift
        run: |
          npx rpc-dart generate
          git diff --exit-code -- apps/mobile/lib/src/api || (
            echo "::error::Generated bindings are stale — run rpc-dart generate and commit."
            exit 1
          )
      - name: Analyzer gate
        run: dart analyze --fatal-infos --fatal-warnings .
        working-directory: apps/mobile
```

Alternatively use `rpc-dart check`, which verifies the committed output against a fresh extraction and exits 3 on drift.

## Breaking-change review

```bash
npx rpc-dart diff --baseline ir.snapshot.json --fail-on-breaking
```

Commit `ir.snapshot.json`; the command categorizes changes into breaking and non-breaking (see [CLI reference](../reference/cli.md#diff)) so reviewers can gate mobile compatibility independently of backend tests.

← Previous: Riverpod | Next: CLI reference →
