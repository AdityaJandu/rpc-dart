import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { selectAdapter, type AdapterChoice } from '../adapter.js';
import { emit } from '@rpc-dart/dart-generator';

export interface GenerateOptions {
  tsconfigPath: string;
  entryFile: string;
  exportName: string;
  /** Generated root, e.g. <consumer>/lib/src/api */
  outDir: string;
  adapter?: AdapterChoice;
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
  const adapter = await selectAdapter(options);
  const { ir, diagnostics } = await adapter.extract(options);

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
  const manifestRel = 'generated.rpc-dart.json';
  // Manifest goes last: code files first, then post-format hashing, so the
  // recorded content hashes match what `check` will see on disk.
  for (const [rel, content] of Object.entries(files)) {
    if (rel === manifestRel) continue;
    const target = path.join(options.outDir, rel);
    mkdirSync(path.dirname(target), { recursive: true });
    const tmp = `${target}.tmp`;
    writeFileSync(tmp, content);
    renameSync(tmp, target);
    written.push(rel);
  }

  // dart-format the emitted tree so generated output is stable under the
  // standard `dart format --set-exit-if-changed` gate. Best-effort: when no
  // Dart SDK is available the raw emitter bytes stay on disk (still
  // self-consistent, since the manifest hashes whatever was written).
  if (dartFormat(written.map((rel) => path.join(options.outDir, rel)))) {
    for (const file of manifestRaw.files) {
      const target = path.join(options.outDir, file.path);
      file.contentSha256 = createHash('sha256').update(readFileSync(target, 'utf-8')).digest('hex');
    }
  }
  const manifestTarget = path.join(options.outDir, manifestRel);
  const manifestTmp = `${manifestTarget}.tmp`;
  writeFileSync(manifestTmp, `${JSON.stringify(manifestRaw, null, 2)}\n`);
  renameSync(manifestTmp, manifestTarget);
  written.push(manifestRel);

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

/** Best-effort `dart format` over the emitted files; true only when it ran and succeeded. */
function dartFormat(targets: string[]): boolean {
  if (targets.length === 0) return false;
  try {
    execFileSync('dart', ['format', ...targets], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}
