/**
 * Virtual type-harness generation (tRPC-specific).
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
import { pathAlias } from '@rpc-dart/core';

export { entryImportPath, harnessFileName, pathAlias, type HarnessAliasRole } from '@rpc-dart/core';

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