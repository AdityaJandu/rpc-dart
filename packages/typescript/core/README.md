# @rpc-dart/core

[![npm version](https://img.shields.io/npm/v/@rpc-dart/core.svg)](https://www.npmjs.com/package/@rpc-dart/core)
[![license](https://img.shields.io/npm/l/@rpc-dart/core.svg)](https://github.com/AdityaJandu/rpc-dart/blob/main/LICENSE)

Core Contract Intermediate Representation (IR), canonical serialization, and compiler diagnostics for `rpc-dart`.

Part of the [rpc-dart](https://github.com/AdityaJandu/rpc-dart) monorepo.

---

## Role

`@rpc-dart/core` decouples backend schema extraction from target code generation:

1. **Contract IR schemas:** Strongly-typed definitions for routers, procedures (queries, mutations, subscriptions), models, fields, enums, discriminated unions, and primitive types.
2. **Canonical serialization:** Deterministic JSON serialization with key sorting, so identical contracts produce identical output independent of property insertion order.
3. **Semantic IR hashing:** `computeIrHash` calculates a SHA-256 hash over semantic structure, skipping generator metadata and comments, powering change detection in watch mode and CI audits.
4. **Structured diagnostics:** Diagnostic error and warning models (`RpcDartDiagnostic`, `DiagnosticCode`) carrying procedure paths, line numbers, and actionable remediation tips.

---

## Installation

```bash
npm install @rpc-dart/core
# or
pnpm add @rpc-dart/core
```

---

## Primary Exports

```typescript
import {
  type ContractIR,
  type ProcedureRecord,
  type TypeDef,
  type TypeRef,
  stableStringify,
  computeIrHash,
  type RpcDartDiagnostic,
  DiagnosticCode,
} from '@rpc-dart/core';
```

---

## Links

- [GitHub Repository](https://github.com/AdityaJandu/rpc-dart)
- [CLI Package (rpc-dart)](https://www.npmjs.com/package/rpc-dart)
- [Issue Tracker](https://github.com/AdityaJandu/rpc-dart/issues)

---

## License

MIT © [Aditya Jandu](https://github.com/AdityaJandu)
