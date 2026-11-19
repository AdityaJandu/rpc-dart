/**
 * Virtual type-harness generation (oRPC-specific).
 * Contract trees resolve through @orpc/contract's public inference helpers,
 * implemented routers through @orpc/server's (which also unwrap lazy
 * routers). Per-path indexed-access aliases force concrete resolution, and
 * defined error maps get one data-schema alias per error code.
 */
import { pathAlias } from '@rpc-dart/core';

export { entryImportPath, harnessFileName, pathAlias } from '@rpc-dart/core';

export type OrpcHarnessMode = 'contract' | 'router';

export interface HarnessErrorSpec {
  path: string;
  codes: string[];
}

export function errorCodeAlias(path: string, code: string): string {
  return `${pathAlias(path, 'error')}_${code.replace(/[^A-Za-z0-9_]/g, '_')}`;
}

export function buildHarness(
  entryImportPath: string,
  exportName: string,
  paths: string[],
  mode: OrpcHarnessMode,
  errorSpecs: HarnessErrorSpec[],
): string {
  const imports =
    mode === 'contract'
      ? `import type { InferContractRouterInputs, InferContractRouterOutputs } from '@orpc/contract';`
      : `import type { InferRouterInputs, InferRouterOutputs } from '@orpc/server';`;
  const inputsHelper = mode === 'contract' ? 'InferContractRouterInputs' : 'InferRouterInputs';
  const outputsHelper = mode === 'contract' ? 'InferContractRouterOutputs' : 'InferRouterOutputs';

  const accessOf = (p: string) =>
    p
      .split('.')
      .map((s) => `[${JSON.stringify(s)}]`)
      .join('');

  const aliases = paths
    .map((p) => {
      const access = accessOf(p);
      return [
        `export type ${pathAlias(p, 'in')} = __rpc_dart_inputs${access};`,
        `export type ${pathAlias(p, 'out')} = __rpc_dart_unwrap_item<__rpc_dart_outputs${access}>;`,
        `export type ${pathAlias(p, 'isstream')} = __rpc_dart_is_stream<__rpc_dart_outputs${access}>;`,
      ].join('\n');
    })
    .join('\n');

  const errorAliases = errorSpecs
    .flatMap((spec) =>
      spec.codes.map(
        (code) =>
          `export type ${errorCodeAlias(spec.path, code)} = __rpc_dart_error_data<NonNullable<__rpc_dart_router${accessOf(spec.path)}['~orpc']['errorMap'][${JSON.stringify(code)}]>>;`,
      ),
    )
    .join('\n');

  return `import type { ${exportName} } from ${JSON.stringify(entryImportPath)};
${imports}

type __rpc_dart_router = typeof ${exportName};
export type __rpc_dart_inputs = ${inputsHelper}<__rpc_dart_router>;
export type __rpc_dart_outputs = ${outputsHelper}<__rpc_dart_router>;

// oRPC event iterators are AsyncIteratorObject/AsyncGenerator outputs. Infer
// the yield from next() rather than AsyncIterable: AsyncGenerator extends
// AsyncIterableIterator<T>, whose self-referential [Symbol.asyncIterator]
// makes AsyncIterable<infer Y> resolve to the generator itself.
type __rpc_dart_unwrap_item<T> = T extends { next(...args: any[]): Promise<IteratorResult<infer Y, any>> } ? Y : T;
type __rpc_dart_is_stream<T> = T extends { next(...args: any[]): Promise<IteratorResult<any, any>> } ? true : false;
// Defined-error data schemas are optional; missing or schema-less entries
// resolve to never so the extractor omits the data field.
type __rpc_dart_error_data<TItem> = TItem extends { data: infer S }
  ? S extends { '~standard': { types?: { output: infer O } } } ? O : never
  : never;

${aliases}
${errorAliases}
`;
}