import { afterAll, describe, expect, it } from 'vitest';
import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { generate, checkContract, diffContract, initWorkspace } from 'rpc-dart';

const REPO_ROOT = fileURLToPath(new URL('../../../', import.meta.url));
const BIN = path.join(REPO_ROOT, 'packages/typescript/cli/bin/rpc-dart.js');
const ORPC_FIXTURE = path.join(REPO_ROOT, 'tests/e2e/src/fixture/orpc');
const TRPC_FIXTURE = path.join(REPO_ROOT, 'tests/e2e/src/fixture/trpc');
// Scratch workspaces must stay under tests/e2e/.tmp so bare imports
// (@trpc/server, @orpc/*, zod) resolve through the workspace node_modules.
const SCRATCH_ROOT = path.join(REPO_ROOT, 'tests/e2e/.tmp');

const scratchDirs: string[] = [];
afterAll(() => {
  for (const dir of scratchDirs) rmSync(dir, { recursive: true, force: true });
});

function workspace(fixture: string): string {
  mkdirSync(SCRATCH_ROOT, { recursive: true });
  const dir = mkdtempSync(path.join(SCRATCH_ROOT, 'cli-adapter-'));
  scratchDirs.push(dir);
  cpSync(fixture, path.join(dir, 'server'), { recursive: true });
  return dir;
}

interface Manifest {
  protocol: { kind: string };
  files: Array<{ path: string }>;
}

function readManifest(outDir: string): Manifest {
  return JSON.parse(
    readFileSync(path.join(outDir, 'generated.rpc-dart.json'), 'utf-8'),
  ) as Manifest;
}

describe('CLI adapter selection', () => {
  it('auto-detects oRPC contract exports and generates orpc bindings', async () => {
    const dir = workspace(ORPC_FIXTURE);
    const outDir = path.join(dir, 'out');
    const result = await generate({
      tsconfigPath: path.join(dir, 'server/tsconfig.json'),
      entryFile: 'router.ts',
      exportName: 'contractRouter',
      outDir,
    });
    expect(result.wrote).toBe(true);
    const manifest = readManifest(outDir);
    expect(manifest.protocol.kind).toBe('orpc');
    expect(manifest.files.some((f) => f.path.includes('uploads_raw'))).toBe(true);
  }, 60000);

  it('auto-detects implemented oRPC routers', async () => {
    const dir = workspace(ORPC_FIXTURE);
    const outDir = path.join(dir, 'out');
    await generate({
      tsconfigPath: path.join(dir, 'server/tsconfig.json'),
      entryFile: 'router.ts',
      exportName: 'appRouter',
      outDir,
    });
    expect(readManifest(outDir).protocol.kind).toBe('orpc');
  }, 60000);

  it('still auto-detects tRPC routers (regression)', async () => {
    const dir = workspace(TRPC_FIXTURE);
    const outDir = path.join(dir, 'out');
    await generate({
      tsconfigPath: path.join(dir, 'server/tsconfig.json'),
      entryFile: 'router.ts',
      exportName: 'appRouter',
      outDir,
    });
    expect(readManifest(outDir).protocol.kind).toBe('trpc');
  }, 60000);

  it('honors explicit adapter: orpc', async () => {
    const dir = workspace(ORPC_FIXTURE);
    const outDir = path.join(dir, 'out');
    await generate({
      tsconfigPath: path.join(dir, 'server/tsconfig.json'),
      entryFile: 'router.ts',
      exportName: 'contractRouter',
      outDir,
      adapter: 'orpc',
    });
    expect(readManifest(outDir).protocol.kind).toBe('orpc');
  }, 60000);

  it('honors explicit adapter: trpc even for oRPC exports (fails extraction)', async () => {
    const dir = workspace(ORPC_FIXTURE);
    await expect(
      generate({
        tsconfigPath: path.join(dir, 'server/tsconfig.json'),
        entryFile: 'router.ts',
        exportName: 'contractRouter',
        outDir: path.join(dir, 'out'),
        adapter: 'trpc',
      }),
    ).rejects.toThrow();
  }, 60000);

  it('check and diff work over auto-detected oRPC contracts', async () => {
    const dir = workspace(ORPC_FIXTURE);
    const outDir = path.join(dir, 'out');
    const options = {
      tsconfigPath: path.join(dir, 'server/tsconfig.json'),
      entryFile: 'router.ts',
      exportName: 'contractRouter',
      outDir,
    };
    await generate(options);
    const check = await checkContract(options);
    expect(check.ok).toBe(true);
    const diff = await diffContract({
      ...options,
      baselinePath: path.join(dir, 'ir.snapshot.json'),
      updateBaseline: true,
    });
    expect(diff.entries).toEqual([]);
  }, 90000);

  it('accepts --adapter on the real binary', async () => {
    const dir = workspace(ORPC_FIXTURE);
    const outDir = path.join(dir, 'out');
    execFileSync('node', [
      BIN,
      'generate',
      '--tsconfig', path.join(dir, 'server/tsconfig.json'),
      '--entry', 'router.ts',
      '--export', 'contractRouter',
      '--out', outDir,
      '--adapter', 'orpc',
    ], { cwd: dir, stdio: 'pipe' });
    expect(readManifest(outDir).protocol.kind).toBe('orpc');
  }, 60000);

  it('init detects oRPC routers and records the adapter', async () => {
    const dir = workspace(ORPC_FIXTURE);
    writeFileSync(
      path.join(dir, 'pubspec.yaml'),
      'name: consumer\nenvironment:\n  sdk: ">=3.6.0 <4.0.0"\n',
    );
    const result = await initWorkspace(dir);
    expect(result.configPath).toBeDefined();
    const config = readFileSync(result.configPath!, 'utf-8');
    expect(config).toContain('orpc');
    expect(existsSync(result.configPath!)).toBe(true);
  });
});