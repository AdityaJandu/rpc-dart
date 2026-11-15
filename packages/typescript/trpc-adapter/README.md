# @rpc-dart/trpc-adapter

[![npm version](https://img.shields.io/npm/v/@rpc-dart/trpc-adapter.svg)](https://www.npmjs.com/package/@rpc-dart/trpc-adapter)
[![license](https://img.shields.io/npm/l/@rpc-dart/trpc-adapter.svg)](https://github.com/AdityaJandu/rpc-dart/blob/main/LICENSE)

tRPC v11 router extraction adapter for `rpc-dart`. Inspects router definitions with the TypeScript compiler API and produces a normalized Contract IR.

Part of the [rpc-dart](https://github.com/AdityaJandu/rpc-dart) monorepo.

---

## Capabilities

- **Compiler-level inspection:** Uses `ts.TypeChecker` to inspect procedure inputs, outputs, and return types directly from TypeScript AST nodes without requiring a running server.
- **Input vs. output fidelity:** Differentiates `z.input` (wire format accepted from the client) from `z.output` (wire format returned by the procedure), accurately handling Zod `.transform()`, `.default()`, and `.coerce()`.
- **Three-state PATCH detection:** Identifies fields that are both optional and nullable, tagging them in the IR for three-state `RpcOpt<T>` handling.
- **Enums and unions:** Extracts string/numeric enums and maps discriminated unions with explicit discriminator keys into sealed type hierarchies.

---

## Installation

```bash
npm install @rpc-dart/trpc-adapter
# or
pnpm add @rpc-dart/trpc-adapter
```

---

## Usage

```typescript
import { extractTrpcContract } from '@rpc-dart/trpc-adapter';

const { contract, diagnostics } = await extractTrpcContract({
  entry: './src/trpc/router.ts',
  exportName: 'appRouter',
  transformer: 'superjson',
  unknownPolicy: 'fail',
});
```

---

## Links

- [GitHub Repository](https://github.com/AdityaJandu/rpc-dart)
- [CLI Package (rpc-dart)](https://www.npmjs.com/package/rpc-dart)
- [Issue Tracker](https://github.com/AdityaJandu/rpc-dart/issues)

---

## License

MIT © [Aditya Jandu](https://github.com/AdityaJandu)
