# Installation

Prerequisites, package setup, workspace initialization, and the generation config schema.

← Documentation Home | Next: Quickstart →

## Prerequisites

| Requirement | Version | Why |
|---|---|---|
| Node.js | ≥ 20 | Runs the `rpc-dart` compiler CLI |
| TypeScript | ≥ 5.x | Your backend project uses `tsconfig.json` |
| tRPC | v11.x | The server framework this tool targets |
| Zod | ≥ 3.25 | Input/output schemas (or any Standard-Schema-compatible validator) |
| Dart SDK | ≥ 3.6 | The generated bindings and runtime |
| Flutter | ≥ 3.35 | Optional — only the `trpc_flutter` bridge needs it |

## Backend: install the CLI

```bash
npm install --save-dev rpc-dart     # or: pnpm add -D rpc-dart
npx rpc-dart init                   # detects your setup; writes rpc-dart.config.ts
npx rpc-dart generate               # first generation
npx rpc-dart watch                  # incremental regeneration next to your dev server
```

## Flutter: add the runtime

```yaml
dependencies:
  trpc_dart: ^1.0.0          # pure Dart runtime (web-safe, no Flutter required)
  trpc_flutter: ^1.0.0       # optional: ValueListenable bridge for widget trees
```

## Configuration

`rpc-dart init` writes `rpc-dart.config.ts` (or create `rpc-dart.config.json` by hand — both work with **zero CLI flags**):

```typescript
import { defineConfig } from 'rpc-dart';

export default defineConfig({
  tsconfig: 'tsconfig.json',        // path to your backend tsconfig
  entry: './src/trpc/router.ts',    // module that exports the router
  exportName: 'appRouter',
  transformer: 'superjson',         // must match initTRPC transformer
  dart: {
    outDir: '../mobile/lib/src/api',
  },
  policies: {
    unserializablePolicy: 'error',  // 'warn-dynamic' | 'skip-procedure'
  },
});
```

Multi-target workspaces generate several clients from one config:

```json
{
  "projects": [
    { "entry": "src/admin/router.ts", "exportName": "adminRouter", "dart": { "outDir": "../admin-app/lib/src/api" } },
    { "entry": "src/mobile/router.ts", "exportName": "mobileRouter", "dart": { "outDir": "../mobile/lib/src/api" } }
  ]
}
```

Make sure the router type is exported next to the router itself:

```typescript
const appRouter = t.router({ user: userRouter, posts: postsRouter });
export type AppRouter = typeof appRouter;
export { appRouter };
```

## Verify

```bash
npx rpc-dart doctor    # environment + workspace checklist
npx rpc-dart check     # CI gate: committed Dart matches the router
```

← Documentation Home | Next: Quickstart →
