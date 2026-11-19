import path from 'node:path';
import { createJiti } from 'jiti';
import { extractContract as extractTrpc } from '@rpc-dart/trpc-adapter';
import { extractContract as extractOrpc } from '@rpc-dart/orpc-adapter';
import type { ContractIR, RpcDartDiagnostic } from '@rpc-dart/core';

export type AdapterChoice = 'trpc' | 'orpc' | 'auto';

export interface AdapterExtractResult {
  ir: ContractIR;
  diagnostics: RpcDartDiagnostic[];
}

export interface AdapterExtractOptions {
  tsconfigPath: string;
  entryFile: string;
  exportName: string;
  transformer?: 'superjson' | 'json';
  policies?: { unserializablePolicy?: 'error' | 'warn-dynamic' | 'skip-procedure' };
}

export interface Adapter {
  kind: 'trpc' | 'orpc';
  extract(options: AdapterExtractOptions): Promise<AdapterExtractResult>;
}

function trpcAdapter(transformer?: 'superjson' | 'json'): Adapter {
  return {
    kind: 'trpc',
    extract: (options) =>
      extractTrpc({
        tsconfigPath: options.tsconfigPath,
        entryFile: options.entryFile,
        exportName: options.exportName,
        protocol: { kind: 'trpc', version: '11', transformer: transformer ?? 'superjson' },
        policies: options.policies,
      }),
  };
}

const orpcAdapter: Adapter = {
  kind: 'orpc',
  extract: (options) =>
    extractOrpc({
      tsconfigPath: options.tsconfigPath,
      entryFile: options.entryFile,
      exportName: options.exportName,
      policies: options.policies,
    }),
};

/** Resolves the extraction adapter; 'auto' probes the export's runtime shape. */
export async function selectAdapter(
  options: AdapterExtractOptions & { adapter?: AdapterChoice },
): Promise<Adapter> {
  const choice = options.adapter ?? 'auto';
  if (choice === 'trpc') return trpcAdapter(options.transformer);
  if (choice === 'orpc') return orpcAdapter;
  const kind = await detectAdapterKind(options);
  return kind === 'orpc' ? orpcAdapter : trpcAdapter(options.transformer);
}

async function detectAdapterKind(
  options: AdapterExtractOptions,
): Promise<'trpc' | 'orpc'> {
  const entryAbsolute = path.resolve(
    path.dirname(options.tsconfigPath),
    options.entryFile,
  );
  const jiti = createJiti(entryAbsolute, { fsCache: false, moduleCache: false });
  const mod = (await jiti.import(entryAbsolute)) as Record<string, unknown>;
  const found = scan(mod[options.exportName], 0);
  if (!found) {
    throw new Error(
      `cannot auto-detect adapter for export "${options.exportName}": ` +
        'no tRPC (_def) or oRPC (~orpc) router shape found; set adapter explicitly',
    );
  }
  return found;
}

function scan(node: unknown, depth: number): 'trpc' | 'orpc' | null {
  if (depth > 6 || typeof node !== 'object' || node === null) return null;
  const obj = node as Record<string, unknown>;
  if ('~orpc' in obj) return 'orpc';
  if (
    Object.getOwnPropertySymbols(obj).some(
      (s) => s.description === 'ORPC_LAZY_SYMBOL',
    )
  ) {
    return 'orpc';
  }
  const def = obj['_def'];
  if (def && typeof def === 'object' && ('procedures' in def || 'record' in def)) {
    return 'trpc';
  }
  for (const value of Object.values(obj)) {
    const found = scan(value, depth + 1);
    if (found) return found;
  }
  return null;
}