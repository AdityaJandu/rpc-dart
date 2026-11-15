import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { extractContract, type ExtractPolicies } from '@rpc-dart/trpc-adapter';
import type { GenerateOptions } from './generate.js';

export interface CheckResult {
  ok: boolean;
  problems: string[];
}

const MANIFEST_NAME = 'generated.rpc-dart.json';

/**
 * CI gate: re-extracts the contract, verifies the committed manifest hash and
 * every manifest file's content against disk. Non-destructive.
 */
export async function checkContract(
  options: Omit<GenerateOptions, 'force'>,
  policies?: ExtractPolicies,
): Promise<CheckResult> {
  const problems: string[] = [];
  const { ir } = await extractContract({
    tsconfigPath: options.tsconfigPath,
    entryFile: options.entryFile,
    exportName: options.exportName,
    protocol: { kind: 'trpc', version: '11', transformer: options.transformer ?? 'superjson' },
    policies,
  });

  const manifestPath = path.join(options.outDir, MANIFEST_NAME);
  if (!existsSync(manifestPath)) {
    return { ok: false, problems: ['no generated manifest found - run `rpc-dart generate` first'] };
  }
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf-8')) as {
    irHash: string;
    files: Array<{ path: string; contentSha256: string }>;
  };

  if (manifest.irHash !== ir.hash) {
    problems.push(
      `contract hash mismatch: router changed since last generate (manifest ${manifest.irHash.slice(0, 15)}, current ${ir.hash.slice(0, 15)})`,
    );
  }

  for (const file of manifest.files) {
    const target = path.join(options.outDir, file.path);
    if (!existsSync(target)) {
      problems.push(`missing generated file: ${file.path}`);
      continue;
    }
    const actual = createHash('sha256').update(readFileSync(target, 'utf-8')).digest('hex');
    if (actual !== file.contentSha256) {
      problems.push(`generated file modified on disk: ${file.path}`);
    }
  }

  return { ok: problems.length === 0, problems };
}
