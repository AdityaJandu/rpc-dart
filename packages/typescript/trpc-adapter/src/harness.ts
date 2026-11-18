/**
 * Virtual type-harness generation.
 * The harness imports ONLY the user's router and tRPC's public inference
 * utilities - never private internals. Per-path aliases force indexed-access
 * evaluation so deep conditional/mapped types resolve concretely, and make
 * per-procedure failures point at exactly one line.
 *
 * Subscription procedures get an extra unwrap layer: tRPC v11 subscription
 * outputs are `AsyncGenerator<Y>` / `AsyncIterable<Y>` / `Observable<Y>` and
 * tracked generators wrap each yield in `TrackedEnvelope<T>` ([id, data,
 * symbol]), so the aliases resolve straight to the streamed item type Y.
 */
export function harnessFileName(): string {
  return '__rpc_dart_harness__.ts';
}

export type HarnessAliasRole = 'in' | 'out' | 'tracked';

export function pathAlias(path: string, role: HarnessAliasRole): string {
  const segments = path.split('.').map((s) => s.replace(/[^A-Za-z0-9_]/g, '_'));
  return ['__p', ...segments, role].join('_');
}

export function buildHarness(
  entryImportPath: string,
  exportName: string,
  paths: string[],
  subscriptionPaths: ReadonlySet<string> = new Set(),
): string {
  const aliases = paths
    .map((p) => {
      const access = p
        .split('.')
        .map((s) => `[${JSON.stringify(s)}]`)
        .join('');
      const lines = [`export type ${pathAlias(p, 'in')} = __rpc_dart_inputs${access};`];
      if (subscriptionPaths.has(p)) {
        lines.push(
          `export type ${pathAlias(p, 'out')} = __rpc_dart_unwrap_item<__rpc_dart_outputs${access}>;`,
          `export type ${pathAlias(p, 'tracked')} = __rpc_dart_is_tracked<__rpc_dart_outputs${access}>;`,
        );
      } else {
        lines.push(`export type ${pathAlias(p, 'out')} = __rpc_dart_outputs${access};`);
      }
      return lines.join('\n');
    })
    .join('\n');
  return `import type { ${exportName} } from ${JSON.stringify(entryImportPath)};
import type { inferRouterInputs, inferRouterOutputs } from '@trpc/server/unstable-core-do-not-import';

type __rpc_dart_router = typeof ${exportName};
export type __rpc_dart_inputs = inferRouterInputs<__rpc_dart_router>;
export type __rpc_dart_outputs = inferRouterOutputs<__rpc_dart_router>;

type __rpc_dart_unwrap_item<T> =
  T extends { subscribe(observer: infer O): unknown }
    ? O extends { next(value: infer Y): void } ? __rpc_dart_unwrap_tracked<Y> : never
    : T extends AsyncIterable<infer Y> ? __rpc_dart_unwrap_tracked<Y> : T;
// tRPC v11 hands clients tracked events as either the branded tuple
// TrackedEnvelope<T> = [id, T, symbol] or its TrackedData<T> = { id, data }
// projection; both reduce to the payload T.
type __rpc_dart_unwrap_tracked<Y> =
  Y extends readonly [string, infer D, symbol]
    ? D
    : Y extends { id: string; data: infer D } ? D : Y;
type __rpc_dart_is_tracked<T> =
  T extends AsyncIterable<infer Y>
    ? Y extends readonly [string, unknown, symbol]
      ? true
      : Y extends { id: string; data: unknown } ? true : false
    : false;

${aliases}
`;
}

/** './router.ts' -> './router' (bundler-style), or explicit extensions under
 * node16/nodenext resolution, where extensionless relative imports are
 * illegal (TS5097) and the TS-standard specifiers (.js/.mjs/.cjs) resolve to
 * the .ts/.mts/.cts sources with or without allowImportingTsExtensions.
 */
export function entryImportPath(
  tsconfigDir: string,
  entryAbsolute: string,
  resolution?: 'node16' | 'nodenext',
): string {
  const rel = relative(tsconfigDir, entryAbsolute);
  const specifier =
    resolution === undefined
      ? rel.replace(/\.(mts|cts|tsx?)$/, '')
      : rel
          .replace(/\.tsx$/, '.js')
          .replace(/\.mts$/, '.mjs')
          .replace(/\.cts$/, '.cjs')
          .replace(/\.ts$/, '.js');
  return specifier.startsWith('.') ? specifier : `./${specifier}`;
}

import { relative } from 'node:path';
