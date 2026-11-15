import { afterAll, beforeAll, describe, it } from 'vitest';
import { ChildProcess, execFileSync, spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO_ROOT = fileURLToPath(new URL('../../../', import.meta.url));

function dartBin(): string {
  const home = process.env.HOME ?? '';
  const candidates = [
    process.env.DART_BIN,
    'dart',
    `${home}/development/flutter/bin/dart`,
    `${home}/fvm/default/bin/dart`,
  ].filter((c): c is string => typeof c === 'string' && c.length > 0);
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

let child: ChildProcess | null = null;
let port = 0;

beforeAll(async () => {
  const childScript = path.join(REPO_ROOT, 'packages/typescript/trpc-adapter/fixture-server-child.mjs');
  child = spawn('node', [childScript], { stdio: ['ignore', 'pipe', 'pipe'] });
  const ready = new Promise<number>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('fixture server did not report a port')), 15000);
    child!.stdout!.on('data', (chunk) => {
      const match = /FIXTURE_PORT=(\d+)/.exec(String(chunk));
      if (match) {
        clearTimeout(timer);
        resolve(Number(match[1]));
      }
    });
    child!.on('exit', (code) => reject(new Error(`fixture server exited early (${code})`)));
  });
  port = await ready;
  const probe = await fetch(`http://127.0.0.1:${port}/trpc/user.me`);
  if (!probe.ok) throw new Error(`fixture probe failed: ${probe.status}`);
}, 30000);

afterAll(async () => {
  child?.kill('SIGTERM');
});

describe('dart runtime over the live wire', () => {
  it('slice client round trips against the real fixture server', () => {
    try {
      execFileSync(dartBin(), ['test', 'test/slice_client_test.dart'], {
        cwd: path.join(REPO_ROOT, 'packages/dart/trpc_dart'),
        env: { ...process.env, TRPC_FIXTURE_PORT: String(port) },
        stdio: 'pipe',
        encoding: 'utf-8',
      });
    } catch (error) {
      const err = error as { stdout?: string; stderr?: string };
      throw new Error(`dart slice client failed:\n${err.stdout ?? ''}\n${err.stderr ?? ''}`);
    }
  }, 180000);
});
