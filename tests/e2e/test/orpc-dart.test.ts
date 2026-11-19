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
  const childScript = path.join(REPO_ROOT, 'tests/e2e/src/orpc-server-child.mjs');
  child = spawn('node', [childScript], { stdio: ['ignore', 'pipe', 'pipe'] });
  const ready = new Promise<number>((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error('oRPC fixture server did not report a port')),
      15000,
    );
    child!.stdout!.on('data', (chunk) => {
      const match = /FIXTURE_PORT=(\d+)/.exec(String(chunk));
      if (match) {
        clearTimeout(timer);
        resolve(Number(match[1]));
      }
    });
    let stderrBuf = '';
    child!.stderr?.on('data', (d) => {
      stderrBuf += String(d);
    });
    child!.on('exit', (code) =>
      reject(new Error(`oRPC fixture server exited early (${code}): ${stderrBuf}`)),
    );
  });
  port = await ready;
  const probe = await fetch(
    `http://127.0.0.1:${port}/rpc/planet/find?data=${encodeURIComponent(JSON.stringify({ json: { id: 1 } }))}`,
  );
  if (!probe.ok) throw new Error(`oRPC fixture probe failed: ${probe.status}`);
}, 30000);

afterAll(async () => {
  child?.kill('SIGTERM');
});

describe('dart oRPC runtime over the live wire', () => {
  it('OrpcLink conformance suite passes against the real RPCHandler', () => {
    try {
      execFileSync(dartBin(), ['test', 'test/orpc_wire_test.dart'], {
        cwd: path.join(REPO_ROOT, 'packages/dart/trpc_dart'),
        env: { ...process.env, ORPC_FIXTURE_PORT: String(port) },
        stdio: 'pipe',
        encoding: 'utf-8',
      });
    } catch (error) {
      const err = error as { stdout?: string; stderr?: string };
      throw new Error(
        `dart oRPC wire suite failed:\n${err.stdout ?? ''}\n${err.stderr ?? ''}`,
      );
    }
  }, 180000);
});