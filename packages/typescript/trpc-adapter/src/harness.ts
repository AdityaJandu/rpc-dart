/**
 * Virtual type-harness generation.
 * The harness imports ONLY the user's router and tRPC's public inference
 * utilities - never private internals. Per-path aliases force indexed-access
 * evaluation so deep conditional/mapped types resolve concretely, and make
 * per-procedure failures point at exactly one line.
 */
export function harnessFileName(): string {
  return '__rpc_dart_harness__.ts';
}

export function pathAlias(path: string, role: 'in' | 'out'): string {
  const segments = path.split('.').map((s) => s.replace(/[^A-Za-z0-9_]/g, '_'));
  return ['__p', ...segments, role].join('_');
}

export function buildHarness(
  entryImportPath: string,
  exportName: string,
  paths: string[],
): string {
  const aliases = paths
    .map((p) => {
      const access = p
        .split('.')
        .map((s) => `[${JSON.stringify(s)}]`)
        .join('');
      return `export type ${pathAlias(p, 'in')} = __rpc_dart_inputs${access};\nexport type ${pathAlias(p, 'out')} = __rpc_dart_outputs${access};`;
    })
    .join('\n');
  return `import type { ${exportName} } from ${JSON.stringify(entryImportPath)};
import type { inferRouterInputs, inferRouterOutputs } from '@trpc/server/unstable-core-do-not-import';

type __rpc_dart_router = typeof ${exportName};
export type __rpc_dart_inputs = inferRouterInputs<__rpc_dart_router>;
export type __rpc_dart_outputs = inferRouterOutputs<__rpc_dart_router>;

${aliases}
`;
}

/** './router.ts' -> './router' (extensionless relative import for the harness). */
export function entryImportPath(tsconfigDir: string, entryAbsolute: string): string {
  const rel = relative(tsconfigDir, entryAbsolute).replace(/\.ts$/, '');
  return rel.startsWith('.') ? rel : `./${rel}`;
}

import { relative } from 'node:path';
