import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { extractContract } from '@rpc-dart/trpc-adapter';
import { emit } from '@rpc-dart/dart-generator';

export interface GenerateOptions {
  tsconfigPath: string;
  entryFile: string;
  exportName: string;
  /** Generated root, e.g. <consumer>/lib/src/api */
  outDir: string;
  transformer?: 'superjson' | 'json';
  force?: boolean;
  policies?: { unserializablePolicy?: 'error' | 'warn-dynamic' | 'skip-procedure' };
}

export interface GenerateResult {
  files: string[];
  hash: string;
  wrote: boolean;
}

const MANIFEST_NAME = 'generated.rpc-dart.json';

interface ManifestShape {
  irHash: string;
  generatorVersion: string;
  protocol: { kind: string; version: string; transformer: string };
  files: Array<{ path: string; contentSha256: string }>;
  diagnostics?: Array<Record<string, unknown>> | import("@rpc-dart/core").RpcDartDiagnostic[];
  policies?: Record<string, unknown>;
}

/**
 * Full pipeline: extract -> hash gate -> emit -> atomic writes -> manifest ->
 * stale-file cleanup.
 */
export async function generate(options: GenerateOptions): Promise<GenerateResult> {
  const { ir, diagnostics } = await extractContract({
    tsconfigPath: options.tsconfigPath,
    entryFile: options.entryFile,
    exportName: options.exportName,
    protocol: { kind: 'trpc', version: '11', transformer: options.transformer ?? 'superjson' },
    policies: options.policies,
  });

  const manifestPath = path.join(options.outDir, MANIFEST_NAME);
  const previous = existsSync(manifestPath)
    ? (JSON.parse(readFileSync(manifestPath, 'utf-8')) as ManifestShape)
    : null;

  if (previous && previous.irHash === ir.hash && !options.force) {
    return {
      files: previous.files.map((f) => f.path),
      hash: ir.hash,
      wrote: false,
    };
  }

  const emitted = emit(ir);
  // emit() lays out under lib/src/api/; the consumer's outDir IS that root.
  // Manifest paths are normalized too so stale cleanup addresses real files.
  const manifestRaw = JSON.parse(emitted.files['lib/src/api/generated.rpc-dart.json']!) as ManifestShape;
  manifestRaw.files = manifestRaw.files.map((f) => ({
    path: f.path.replace(/^lib\/src\/api\//, ''),
    contentSha256: f.contentSha256,
  }));
  manifestRaw.diagnostics = diagnostics;
  manifestRaw.policies = options.policies ?? { unserializablePolicy: 'error' };
  const files: Record<string, string> = {};
  for (const [rel, content] of Object.entries(emitted.files)) {
    const stripped = rel.replace(/^lib\/src\/api\//, '');
    files[stripped] = rel === 'lib/src/api/generated.rpc-dart.json'
      ? `${JSON.stringify(manifestRaw, null, 2)}\n`
      : content;
  }
  const written: string[] = [];
  for (const [rel, content] of Object.entries(files)) {
    const target = path.join(options.outDir, rel);
    mkdirSync(path.dirname(target), { recursive: true });
    const tmp = `${target}.tmp`;
    writeFileSync(tmp, content);
    renameSync(tmp, target);
    written.push(rel);
  }

  // Stale cleanup: committed files from the previous manifest that the new
  // emission no longer contains (crash-safe: cleanup happens after a
  // successful full write, manifest last).
  if (previous) {
    for (const prevFile of previous.files) {
      if (!(prevFile.path in files)) {
        const stalePath = path.join(options.outDir, prevFile.path);
        if (existsSync(stalePath)) {
          rmLocal(stalePath);
        }
      }
    }
  }

  return { files: written, hash: ir.hash, wrote: true };
}

import { rmSync } from 'node:fs';

function rmLocal(target: string): void {
  rmSync(target);
}
