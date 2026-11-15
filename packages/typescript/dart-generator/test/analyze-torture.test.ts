import { beforeAll, describe, expect, it } from 'vitest';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { extractContract } from '@rpc-dart/trpc-adapter';
import type { ContractIR } from '@rpc-dart/core';
import { emit } from '../src/index.js';

const tortureTsconfig = fileURLToPath(
  new URL('../../../../tests/e2e/src/fixture/torture/tsconfig.json', import.meta.url),
);
const REPO_ROOT = fileURLToPath(new URL('../../../../', import.meta.url));

let ir: ContractIR;
let dartAvailable = false;

beforeAll(async () => {
  const result = await extractContract({
    tsconfigPath: tortureTsconfig,
    entryFile: 'router.ts',
    exportName: 'appRouter',
    protocol: { kind: 'trpc', version: '11', transformer: 'superjson' },
  });
  expect(result.diagnostics).toEqual([]);
  ir = result.ir;
  try {
    execFileSync('dart', ['--version'], { stdio: 'pipe' });
    dartAvailable = true;
  } catch {
    dartAvailable = false;
  }
}, 30000);

describe('analyzer gate: torture models compile against the runtime', () => {
  it('dart analyze --fatal-infos --fatal-warnings reports zero issues', () => {
    if (!dartAvailable) {
      console.warn('dart SDK not on PATH - skipping analyzer gate');
      return;
    }
    const dir = mkdtempSync(path.join(tmpdir(), 'rpc-dart-torture-'));
    try {
      writeFileSync(
        path.join(dir, 'pubspec.yaml'),
        [
          'name: torture_consumer',
          'publish_to: none',
          'environment:',
          '  sdk: ">=3.6.0 <4.0.0"',
          'dependencies:',
          '  trpc_dart:',
          `    path: ${path.join(REPO_ROOT, 'packages/dart/trpc_dart')}`,
          '',
        ].join('\n'),
      );
      mkdirSync(path.join(dir, 'lib'), { recursive: true });
      const { files } = emit(ir);
      for (const [rel, content] of Object.entries(files)) {
        const target = path.join(dir, rel);
        mkdirSync(path.dirname(target), { recursive: true });
        writeFileSync(target, content);
      }
      execFileSync('dart', ['pub', 'get'], { cwd: dir, stdio: 'pipe' });
      const output = execFileSync(
        'dart',
        ['analyze', '--fatal-infos', '--fatal-warnings', '.'],
        { cwd: dir, stdio: 'pipe', encoding: 'utf-8' },
      );
      expect(output).not.toMatch(/error -/);
    } catch (error) {
      const err = error as { stdout?: string; stderr?: string };
      throw new Error(`torture analyzer gate failed:\n${err.stdout ?? ''}\n${err.stderr ?? ''}`);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 120000);
});
