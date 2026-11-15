# @rpc-dart/dart-generator

[![npm version](https://img.shields.io/npm/v/@rpc-dart/dart-generator.svg)](https://www.npmjs.com/package/@rpc-dart/dart-generator)
[![license](https://img.shields.io/npm/l/@rpc-dart/dart-generator.svg)](https://github.com/AdityaJandu/rpc-dart/blob/main/LICENSE)

Deterministic Dart 3 code generator for `rpc-dart`. Consumes the Contract IR and produces type-safe, build-tool-free Dart client bindings.

Part of the [rpc-dart](https://github.com/AdityaJandu/rpc-dart) monorepo.

---

## Output Architecture

Generated Dart code is completely self-contained and compiles without code generators or reflection:

- **Plain Dart 3:** Const constructors, final fields, `copyWith`, structural equality (`operator ==` and `hashCode`), and `fromJson`/`toJson` mappers.
- **Zero raw casts:** All deserialization uses pattern matching and `RpcJson` readers with breadcrumb paths (`UserGetByIdOutput.receipt.authorizedAt`), preventing uncaught `TypeError` crashes.
- **Sealed hierarchies:** Discriminated unions emit sealed base classes and final variants, enabling exhaustive `switch` pattern matching in Dart 3.
- **Procedure clients:** Emits nested router classes matching your tRPC router hierarchy, providing `.query()`, `.mutate()`, `.watch()`, `.safeQuery()`, and `.safeMutate()`.
- **Three-state PATCH models:** Generates `RpcOpt<T>` fields distinguishing absent, explicit null, and updated values.

---

## Installation

```bash
npm install @rpc-dart/dart-generator
# or
pnpm add @rpc-dart/dart-generator
```

---

## Usage

```typescript
import { generateDartBindings } from '@rpc-dart/dart-generator';

const files = generateDartBindings(contract, {
  outDir: './lib/src/api',
});

// files is an array of { path: string, content: string }
```

---

## Links

- [GitHub Repository](https://github.com/AdityaJandu/rpc-dart)
- [CLI Package (rpc-dart)](https://www.npmjs.com/package/rpc-dart)
- [Dart Runtime (trpc_dart)](https://pub.dev/packages/trpc_dart)
- [Issue Tracker](https://github.com/AdityaJandu/rpc-dart/issues)

---

## License

MIT © [Aditya Jandu](https://github.com/AdityaJandu)
