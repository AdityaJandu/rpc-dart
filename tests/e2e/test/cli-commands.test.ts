import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  checkContract,
  cleanGenerated,
  diffContract,
  doctorChecks,
  generate,
  initWorkspace,
  WatchSession,
} from 'rpc-dart';

const REPO_ROOT = fileURLToPath(new URL('../../../', import.meta.url));
const FIXTURE_SRC = path.join(REPO_ROOT, 'tests/e2e/src/fixture/trpc');

let workspace: string;
let fixtureDir: string;
let outDir: string;

const generateOptions = () => ({
  tsconfigPath: path.join(fixtureDir, 'tsconfig.json'),
  entryFile: 'router.ts',
  exportName: 'appRouter',
  outDir,
});

beforeAll(async () => {
  workspace = mkdtempSync(path.join(REPO_ROOT, 'tests/e2e/.tmp/cli-'));
  fixtureDir = path.join(workspace, 'trpc');
  outDir = path.join(workspace, 'consumer/lib/src/api');
  cpSync(FIXTURE_SRC, fixtureDir, { recursive: true });
  await generate(generateOptions());
}, 30000);

afterAll(() => {
  rmSync(workspace, { recursive: true, force: true });
});

describe('rpc-dart check', () => {
  it('passes when the committed output matches the contract', async () => {
    const result = await checkContract(generateOptions());
    expect(result.ok).toBe(true);
    expect(result.problems).toEqual([]);
  });

  it('detects a mutated generated file', async () => {
    const target = path.join(outDir, 'models/user_get_by_id_input.dart');
    writeFileSync(target, `${readFileSync(target, 'utf-8')}\n// tampered`);
    const result = await checkContract(generateOptions());
    expect(result.ok).toBe(false);
    expect(result.problems.some((p) => p.includes('user_get_by_id_input.dart'))).toBe(true);
    // restore
    await generate({ ...generateOptions(), force: true });
  });

  it('detects a contract change without regeneration', async () => {
    // A resolver string constant is NOT a contract change; a schema type is.
    const schemasPath = path.join(fixtureDir, 'schemas.ts');
    const original = readFileSync(schemasPath, 'utf-8');
    writeFileSync(schemasPath, original.replace('title: z.string(),', 'title: z.string().nullable(),'));
    const result = await checkContract(generateOptions());
    expect(result.ok, `modified: ${result.problems.join('; ')}`).toBe(false);
    expect(
      result.problems.some((p) => p.includes('hash')),
      `problems: ${result.problems.join('; ')}`,
    ).toBe(true);
    writeFileSync(schemasPath, original);
    await generate({ ...generateOptions(), force: true });
    const restored = await checkContract(generateOptions());
    expect(restored.ok, `restored: ${restored.problems.join('; ')}`).toBe(true);
  });
});

describe('rpc-dart diff', () => {
  it('writes a baseline and reports no changes on an identical router', async () => {
    const baselinePath = path.join(workspace, 'ir.snapshot.json');
    const first = await diffContract({ ...generateOptions(), baselinePath, updateBaseline: true });
    expect(first.hasBreaking).toBe(false);
    const second = await diffContract({ ...generateOptions(), baselinePath });
    expect(second.breakingCount).toBe(0);
    expect(second.nonBreakingCount).toBe(0);
  });

  it('categorizes breaking vs non-breaking changes', async () => {
    const baselinePath = path.join(workspace, 'ir.snapshot.json');
    await diffContract({ ...generateOptions(), baselinePath, updateBaseline: true });

    const routerPath = path.join(fixtureDir, 'router.ts');
    const original = readFileSync(routerPath, 'utf-8');
    // breaking: rename user.getById; remove posts.list; non-breaking: add procedure
    const renamed = original
      .replace(/getById/g, 'fetchById')
      .replace(/  list: publicProcedure\.input\(PostsListInputSchema\)\.query\(\(\{ input \}\) => postsList\(input\)\),\n/, '');
    writeFileSync(routerPath, `${renamed}\nexport const extraRouter = t.router({});\n`);
    // add a new procedure (non-breaking) into userRouter
    const withAdded = readFileSync(routerPath, 'utf-8').replace(
      'export const userRouter = t.router({',
      `export const userRouter = t.router({\n  health: publicProcedure.query(() => ({ ok: true })),`,
    );
    writeFileSync(routerPath, withAdded);

    const diff = await diffContract({ ...generateOptions(), baselinePath });
    expect(diff.hasBreaking).toBe(true);
    expect(diff.breakingCount).toBeGreaterThanOrEqual(2);
    expect(diff.entries.some((e) => e.breaking && e.kind === 'procedure-removed')).toBe(true);
    expect(diff.entries.some((e) => e.breaking && e.kind === 'procedure-renamed')).toBe(true);
    expect(diff.entries.some((e) => !e.breaking && e.kind === 'procedure-added')).toBe(true);

    writeFileSync(routerPath, original);
    await generate({ ...generateOptions(), force: true });
  });
});

describe('rpc-dart clean', () => {
  it('removes only owned files and refuses without a manifest', async () => {
    const decoy = path.join(outDir, 'KEEP_ME.txt');
    writeFileSync(decoy, 'user file');
    expect(existsSync(path.join(outDir, 'api.dart'))).toBe(true);

    const removed = cleanGenerated(outDir);
    expect(removed.removed.length).toBeGreaterThan(0);
    expect(existsSync(path.join(outDir, 'api.dart'))).toBe(false);
    expect(existsSync(path.join(outDir, 'generated.rpc-dart.json'))).toBe(false);
    expect(existsSync(decoy)).toBe(true);

    expect(() => cleanGenerated(outDir)).toThrow(/manifest/);
    await generate({ ...generateOptions(), force: true });
    expect(existsSync(path.join(outDir, 'api.dart'))).toBe(true);
  });
});

describe('rpc-dart watch', () => {
  it('re-emits on semantic changes and skips hash-identical saves', async () => {
    const cycles: Array<{ changed: boolean; durationMs: number }> = [];
    const session = new WatchSession({
      ...generateOptions(),
      debounceMs: 80,
      onCycle: (cycle) => cycles.push(cycle),
    });
    session.start();

    const routerPath = path.join(fixtureDir, 'router.ts');
    const original = readFileSync(routerPath, 'utf-8');

    // Semantic change: procedure rename.
    writeFileSync(routerPath, original.replace(/getById/g, 'fetchById'));
    await waitFor(() => existsSync(path.join(outDir, 'procedures/user_fetch_by_id.dart')), 15000);
    const semanticCycles = cycles.filter((c) => c.changed);
    expect(semanticCycles.length).toBeGreaterThanOrEqual(1);
    expect(semanticCycles.every((c) => c.durationMs > 0)).toBe(true);
    expect(existsSync(path.join(outDir, 'procedures/user_get_by_id.dart'))).toBe(false);

    // Comment-only change: hash identical, no writes.
    const cyclesBefore = cycles.length;
    writeFileSync(routerPath, `${readFileSync(routerPath, 'utf-8')}\n// cosmetic edit\n`);
    await sleep(600);
    const recent = cycles.slice(cyclesBefore);
    expect(recent.every((c) => !c.changed)).toBe(true);

    session.stop();
    writeFileSync(routerPath, original);
    await generate({ ...generateOptions(), force: true });
  }, 40000);
});

describe('rpc-dart doctor', () => {
  it('reports structured checks for a healthy workspace', async () => {
    const checks = await doctorChecks({
      tsconfigPath: path.join(fixtureDir, 'tsconfig.json'),
      entryFile: path.join(fixtureDir, 'router.ts'),
      exportName: 'appRouter',
      dartPackagePath: path.join(REPO_ROOT, 'packages/dart/trpc_dart'),
    });
    const byName = Object.fromEntries(checks.map((c) => [c.name, c]));
    expect(byName['node-version']!.status).toBe('pass');
    expect(byName['tsconfig']!.status).toBe('pass');
    expect(byName['router-export']!.status).toBe('pass');
    expect(byName['dart-sdk']!.status).toBe('pass');
    expect(byName['version-alignment']!.status).toBe('pass');
  });

  it('fails clearly on a missing router export', async () => {
    const checks = await doctorChecks({
      tsconfigPath: path.join(fixtureDir, 'tsconfig.json'),
      entryFile: path.join(fixtureDir, 'router.ts'),
      exportName: 'notTheRouter',
      dartPackagePath: path.join(REPO_ROOT, 'packages/dart/trpc_dart'),
    });
    expect(checks.find((c) => c.name === 'router-export')!.status).toBe('fail');
  });
});

describe('rpc-dart init', () => {
  it('detects tsconfig, router, and Flutter target; writes config once', async () => {
    const ws = path.join(workspace, 'init-ws');
    mkdirSync(path.join(ws, 'src/trpc'), { recursive: true });
    cpSync(path.join(fixtureDir, 'router.ts'), path.join(ws, 'src/trpc/router.ts'));
    cpSync(path.join(fixtureDir, 'schemas.ts'), path.join(ws, 'src/trpc/schemas.ts'));
    writeFileSync(path.join(ws, 'tsconfig.json'), readFileSync(path.join(fixtureDir, 'tsconfig.json'), 'utf-8'));
    // Sibling flutter target
    const flutterDir = path.join(workspace, 'flutter-app');
    mkdirSync(flutterDir, { recursive: true });
    writeFileSync(path.join(flutterDir, 'pubspec.yaml'), 'name: sample_app\n');

    const result = await initWorkspace(ws, { flutterDirs: [flutterDir] });
    expect(existsSync(result.configPath)).toBe(true);
    expect(result.config.entry).toContain('router.ts');
    expect(result.config.exportName).toBe('appRouter');
    expect((result.config.dart as { outDir: string }).outDir).toContain('flutter-app');

    await expect(initWorkspace(ws, { flutterDirs: [flutterDir] })).rejects.toThrow(/already exists/);
  });
});

describe('zero-config CLI experience', () => {
  const BIN = path.join(REPO_ROOT, 'packages/typescript/cli/bin/rpc-dart.js');

  function runCli(args: string[], cwd: string) {
    try {
      const output = execFileSync('node', [BIN, ...args], { cwd, stdio: 'pipe', encoding: 'utf-8' });
      return { status: 0, output };
    } catch (error) {
      const err = error as { status?: number; stdout?: string; stderr?: string };
      return { status: err.status ?? 1, output: `${err.stdout ?? ''}\n${err.stderr ?? ''}` };
    }
  }

  it('generate with zero flags uses rpc-dart.config.json', async () => {
    const ws = mkdtempSync(path.join(REPO_ROOT, 'tests/e2e/.tmp/zerocfg-'));
    cpSync(FIXTURE_SRC, path.join(ws, 'trpc'), { recursive: true });
    mkdirSync(path.join(ws, 'out'), { recursive: true });
    writeFileSync(
      path.join(ws, 'rpc-dart.config.json'),
      JSON.stringify({
        tsconfig: 'trpc/tsconfig.json',
        entry: 'trpc/router.ts',
        exportName: 'appRouter',
        dart: { outDir: 'out' },
      }),
    );
    const result = runCli(['generate'], ws);
    expect(result.status, result.output).toBe(0);
    expect(existsSync(path.join(ws, 'out', 'api.dart'))).toBe(true);
    rmSync(ws, { recursive: true, force: true });
  });

  it('flags override config values', async () => {
    const ws = mkdtempSync(path.join(REPO_ROOT, 'tests/e2e/.tmp/zerocfg2-'));
    cpSync(FIXTURE_SRC, path.join(ws, 'trpc'), { recursive: true });
    writeFileSync(
      path.join(ws, 'rpc-dart.config.json'),
      JSON.stringify({
        tsconfig: 'trpc/tsconfig.json',
        entry: 'trpc/router.ts',
        exportName: 'appRouter',
        dart: { outDir: 'out-default' },
      }),
    );
    const result = runCli(['generate', '--out', 'out-override'], ws);
    expect(result.status, result.output).toBe(0);
    expect(existsSync(path.join(ws, 'out-override', 'api.dart'))).toBe(true);
    expect(existsSync(path.join(ws, 'out-default', 'api.dart'))).toBe(false);
    rmSync(ws, { recursive: true, force: true });
  });

  it('multi-project config generates every target', async () => {
    const ws = mkdtempSync(path.join(REPO_ROOT, 'tests/e2e/.tmp/zerocfg3-'));
    cpSync(FIXTURE_SRC, path.join(ws, 'trpc'), { recursive: true });
    writeFileSync(
      path.join(ws, 'rpc-dart.config.json'),
      JSON.stringify({
        projects: [
          { tsconfig: 'trpc/tsconfig.json', entry: 'trpc/router.ts', exportName: 'appRouter', dart: { outDir: 'out-a' } },
          { tsconfig: 'trpc/tsconfig.json', entry: 'trpc/router.ts', exportName: 'appRouter', dart: { outDir: 'out-b' } },
        ],
      }),
    );
    const result = runCli(['generate'], ws);
    expect(result.status, result.output).toBe(0);
    expect(existsSync(path.join(ws, 'out-a', 'api.dart'))).toBe(true);
    expect(existsSync(path.join(ws, 'out-b', 'api.dart'))).toBe(true);
    rmSync(ws, { recursive: true, force: true });
  });

  it('no config + no flags prints an actionable hint and exits 2', () => {
    const ws = mkdtempSync(path.join(REPO_ROOT, 'tests/e2e/.tmp/zerocfg4-'));
    const result = runCli(['generate'], ws);
    expect(result.status).toBe(2);
    expect(result.output).toContain('rpc-dart init');
    rmSync(ws, { recursive: true, force: true });
  });
});

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitFor(predicate: () => boolean, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await sleep(100);
  }
  throw new Error('waitFor timed out');
}

void execFileSync;
