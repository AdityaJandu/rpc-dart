import * as fs from 'node:fs';
import { describe, expect, it } from 'vitest';
import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { generate } from 'rpc-dart';

const REPO_ROOT = fileURLToPath(new URL('../../../', import.meta.url));
const FIXTURE_SRC = path.join(REPO_ROOT, 'tests/e2e/src/fixture/trpc');

function dartBin(): string {
  const home = process.env.HOME ?? '';
  const candidates = [process.env.DART_BIN, 'dart', `${home}/development/flutter/bin/dart`]
    .filter((c): c is string => typeof c === 'string' && c.length > 0);
  for (const candidate of candidates) {
    try {
      execFileSync(candidate, ['--version'], { stdio: 'pipe' });
      return candidate;
    } catch {
      continue;
    }
  }
  throw new Error('dart SDK not found (set DART_BIN)');
}

function runDart(args: string[], cwd: string): { status: number; output: string } {
  try {
    const output = execFileSync(dartBin(), args, { cwd, stdio: 'pipe', encoding: 'utf-8' });
    return { status: 0, output };
  } catch (error) {
    const err = error as { status?: number; stdout?: string; stderr?: string };
    return {
      status: err.status ?? 1,
      output: `${err.stdout ?? ''}\n${err.stderr ?? ''}`,
    };
  }
}

describe('renaming a procedure breaks the consumer at compile time', () => {
  it('removes stale bindings and makes stale call sites fail dart analyze', async () => {
    mkdirSync(path.join(REPO_ROOT, 'tests/e2e/.tmp'), { recursive: true });
    const workspace = (() => { fs.mkdirSync(path.join(REPO_ROOT, 'tests/e2e/.tmp'), { recursive: true }); return mkdtempSync(path.join(REPO_ROOT, 'tests/e2e/.tmp/rename-')); })();
    const fixtureDir = path.join(workspace, 'trpc');
    const consumerDir = path.join(workspace, 'consumer');
    const apiDir = path.join(consumerDir, 'lib', 'src', 'api');

    try {
      // 1. Private copies of the fixture router + a consumer app.
      cpSync(FIXTURE_SRC, fixtureDir, { recursive: true });
      mkdirSync(path.join(consumerDir, 'lib'), { recursive: true });
      const trpcDart = path.join(REPO_ROOT, 'packages/dart/trpc_dart');
      const trpcFlutter = path.join(REPO_ROOT, 'packages/dart/trpc_flutter');
      writeFileSync(
        path.join(consumerDir, 'pubspec.yaml'),
        [
          'name: rename_consumer',
          'publish_to: none',
          'environment:',
          '  sdk: ">=3.6.0 <4.0.0"',
          'dependencies:',
          '  trpc_dart:',
          `    path: ${trpcDart}`,
          '  trpc_flutter:',
          `    path: ${trpcFlutter}`,
          '  flutter:',
          '    sdk: flutter',
          'dependency_overrides:',
          '  trpc_dart:',
          `    path: ${trpcDart}`,
          '',
        ].join('\n'),
      );
      writeFileSync(
        path.join(consumerDir, 'lib', 'main.dart'),
        `
import 'package:trpc_dart/trpc_dart.dart';
import 'src/api/api.dart';

Future<void> main() async {
  final client = RpcClient(
    endpoint: Uri.parse('https://api.example.com/trpc'),
    links: [HttpBatchLink(endpoint: Uri.parse('https://api.example.com/trpc'))],
  );
  final api = Api(client);
  // Stale call sites: reference user.getById three times.
  final user = await api.user.getById.query(const UserGetByIdInput(id: 'u1'));
  print(user.id);
  final ref = api.user.getById.watch(const UserGetByIdInput(id: 'u1'));
  print(ref);
  print(api.user.getById.pathKey);
}
`,
      );

      // 2. Baseline: generate + pub get + clean analyze.
      const options = {
        tsconfigPath: path.join(fixtureDir, 'tsconfig.json'),
        entryFile: 'router.ts',
        exportName: 'appRouter',
        outDir: apiDir,
      };
      const first = await generate(options);
      expect(first.files.length).toBeGreaterThan(0);
      expect(existsSync(path.join(apiDir, 'procedures', 'user_get_by_id.dart'))).toBe(true);
      expect(existsSync(path.join(apiDir, 'api.dart'))).toBe(true);

      execFileSync('flutter', ['pub', 'get'], { cwd: consumerDir, stdio: 'pipe' });
      const baseline = runDart(['analyze', '--fatal-infos', '--fatal-warnings', '.'], consumerDir);
      expect(baseline.status, `baseline analyze failed:\n${baseline.output}`).toBe(0);

      // 3. Unchanged router: regenerate is hash-gated (no writes).
      const unchanged = await generate(options);
      expect(unchanged.wrote).toBe(false);

      // 4. Rename user.getById -> user.fetchById in the backend.
      const routerSource = readFileSync(path.join(fixtureDir, 'router.ts'), 'utf-8');
      writeFileSync(
        path.join(fixtureDir, 'router.ts'),
        routerSource.replace(/getById/g, 'fetchById'),
      );

      // 5. Regenerate: stale file removed, new bindings present.
      const second = await generate(options);
      expect(second.wrote).toBe(true);
      expect(existsSync(path.join(apiDir, 'procedures', 'user_get_by_id.dart'))).toBe(false);
      expect(existsSync(path.join(apiDir, 'procedures', 'user_fetch_by_id.dart'))).toBe(true);

      // 6. The consumer now fails dart analyze at every stale call site.
      const after = runDart(['analyze', '--fatal-infos', '--fatal-warnings', '.'], consumerDir);
      expect(after.status, `expected analyzer errors after rename:\n${after.output}`).not.toBe(0);
      const errorLines = after.output
        .split('\n')
        .filter((line) => line.includes('error -') && line.includes('main.dart'));
      expect(errorLines.length).toBeGreaterThanOrEqual(3);
      expect(after.output).toContain("getById");

      // 7. Deleting the stale call sites restores a clean build (client heals).
      // Healing updates call sites AND synthesized type names (a rename
      // changes both the getter and the generated model classes).
      const healedMain = readFileSync(path.join(consumerDir, 'lib', 'main.dart'), 'utf-8')
        .replace(/getById/g, 'fetchById')
        .replace(/GetById/g, 'FetchById');
      writeFileSync(path.join(consumerDir, 'lib', 'main.dart'), healedMain);
      const healed = runDart(['analyze', '--fatal-infos', '--fatal-warnings', '.'], consumerDir);
      expect(healed.status, `expected clean analyze after healing call sites:\n${healed.output}`).toBe(0);
    } finally {
      if (workspace) rmSync(workspace, { recursive: true, force: true });
    }
  }, 180000);
});
