# rpc-dart

[![npm version](https://img.shields.io/npm/v/rpc-dart.svg)](https://www.npmjs.com/package/rpc-dart)
[![license](https://img.shields.io/npm/l/rpc-dart.svg)](https://github.com/AdityaJandu/rpc-dart/blob/main/LICENSE)
[![GitHub CI](https://github.com/AdityaJandu/rpc-dart/actions/workflows/ci.yml/badge.svg)](https://github.com/AdityaJandu/rpc-dart/actions/workflows/ci.yml)

CLI that reads your TypeScript [tRPC](https://trpc.io) v11 router and generates type-safe, build-tool-free Dart 3 bindings for Flutter and Dart clients.

Rename a procedure or edit a Zod schema on the backend: run generation, and the Dart analyzer immediately flags every outdated call site.

Part of the [rpc-dart](https://github.com/AdityaJandu/rpc-dart) monorepo.

---

## Why rpc-dart?

- **Zero Dart build runners:** Generates plain Dart 3 classes with const constructors, `copyWith`, structural equality, and JSON serialization. You never run `build_runner`, `freezed`, or `json_serializable`.
- **Direct compiler extraction:** Inspects your router with the TypeScript compiler API (`ts.TypeChecker`), preserving Zod transforms, defaults, discriminated unions, and three-state PATCH optionals (`RpcOpt<T>`).
- **Complete tRPC v11 wire protocol:** Pairs with the [`trpc_dart`](https://pub.dev/packages/trpc_dart) runtime for HTTP batching, SuperJSON decoding (`Date`, `BigInt`, `NaN`), and structured exceptions.

---

## Installation

```bash
# In your backend project:
npm install --save-dev rpc-dart
# or
pnpm add -D rpc-dart
# or
yarn add -D rpc-dart
```

---

## Quickstart

### 1. Initialize configuration

Run the interactive setup in your backend directory:

```bash
npx rpc-dart init
```

This scans your workspace for router exports, `tsconfig.json`, and Flutter projects, then writes `rpc-dart.config.ts`:

```typescript
import { defineConfig } from 'rpc-dart';

export default defineConfig({
  entry: './src/trpc/router.ts',
  exportName: 'appRouter',
  transformer: 'superjson',
  dart: {
    outDir: '../mobile/lib/src/api',
  },
});
```

### 2. Export your router type

Ensure your server exports both the router value and its type:

```typescript
// src/trpc/router.ts
import { initTRPC } from '@trpc/server';
import superjson from 'superjson';

const t = initTRPC.create({ transformer: superjson });

export const appRouter = t.router({
  user: userRouter,
  posts: postsRouter,
});

export type AppRouter = typeof appRouter;
```

### 3. Generate bindings

```bash
# One-time generation:
npx rpc-dart generate

# Or watch mode during backend development:
npx rpc-dart watch
```

---

## CLI Commands

| Command | Description |
|---|---|
| `rpc-dart init` | Interactive project setup; generates `rpc-dart.config.ts`. |
| `rpc-dart generate` | Extracts the router contract and writes Dart bindings into `outDir`. |
| `rpc-dart watch` | Watches backend router files and regenerates Dart on changes. |
| `rpc-dart check` | Verifies committed Dart files match the backend router in CI. |
| `rpc-dart diff` | Compares current router contract against a baseline to highlight breaking changes. |
| `rpc-dart clean` | Safely deletes generated files tracked in `.rpc-dart-manifest.json`. |
| `rpc-dart doctor` | Diagnoses configuration, compiler, and environment issues. |

---

## Configuration Reference

`rpc-dart.config.ts` options:

```typescript
import { defineConfig } from 'rpc-dart';

export default defineConfig({
  // Path to the TypeScript file exporting the router
  entry: './src/server/router.ts',

  // Name of the exported router constant (default: 'appRouter')
  exportName: 'appRouter',

  // Transformer matching initTRPC ({ transformer })
  // Options: 'superjson' | 'json'
  transformer: 'superjson',

  // Dart output settings
  dart: {
    // Directory where generated Dart files will be written
    outDir: '../client/lib/src/api',
  },

  // Policy for non-discriminated or unknown types
  // Options: 'fail' (default) | 'warn-dynamic' | 'skip-procedure'
  unknownPolicy: 'fail',
});
```

---

## Dart Runtime Setup

In your Flutter or Dart project, add [`trpc_dart`](https://pub.dev/packages/trpc_dart):

```yaml
dependencies:
  trpc_dart: ^0.2.0
```

Initialize the client with the generated `Api` class:

```dart
import 'package:trpc_dart/trpc_dart.dart';
import 'api/api.dart'; // generated directory

final client = RpcClient(
  endpoint: Uri.parse('https://api.example.com/trpc'),
  transformer: RpcTransformer.superjson,
  links: [
    HttpBatchLink(endpoint: Uri.parse('https://api.example.com/trpc')),
  ],
);

final api = Api(client);

Future<void> main() async {
  final user = await api.user.getById.query(UserGetByIdInput(id: 'u1'));
  print(user.name);
}
```

---

## Links

- [Documentation](https://github.com/AdityaJandu/rpc-dart/blob/main/docs/README.md)
- [Quickstart Guide](https://github.com/AdityaJandu/rpc-dart/blob/main/docs/getting-started/quickstart.md)
- [Dart Runtime (trpc_dart)](https://pub.dev/packages/trpc_dart)
- [Flutter Bridge (trpc_flutter)](https://pub.dev/packages/trpc_flutter)
- [GitHub Repository](https://github.com/AdityaJandu/rpc-dart)
- [Issue Tracker](https://github.com/AdityaJandu/rpc-dart/issues)

---

## License

MIT © [Aditya Jandu](https://github.com/AdityaJandu)
