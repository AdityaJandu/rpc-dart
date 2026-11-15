import { existsSync, readFileSync, rmSync } from 'node:fs';
import path from 'node:path';

export interface CleanResult {
  removed: string[];
}

const MANIFEST_NAME = 'generated.rpc-dart.json';

/** Deletes exactly the files owned by the generator (manifest-listed). */
export function cleanGenerated(outDir: string): CleanResult {
  const manifestPath = path.join(outDir, MANIFEST_NAME);
  if (!existsSync(manifestPath)) {
    throw new Error(`no generated manifest at ${manifestPath} - nothing owned by rpc-dart to clean`);
  }
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf-8')) as {
    files: Array<{ path: string }>;
  };
  const removed: string[] = [];
  for (const file of manifest.files) {
    const target = path.join(outDir, file.path);
    if (existsSync(target)) {
      rmSync(target);
      removed.push(file.path);
    }
  }
  rmSync(manifestPath);
  removed.push(MANIFEST_NAME);
  return { removed };
}
