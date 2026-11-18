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
  const childScript = path.join(
    REPO_ROOT,
    'examples/trpc-fastify/scripts/server-child.mjs',
  );
  child = spawn('node', [childScript], { stdio: ['ignore', 'pipe', 'pipe'] });
  const ready = new Promise<number>((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error('example server did not report a port')),
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
      reject(new Error(`example server exited early (${code}): ${stderrBuf}`)),
    );
  });
  port = await ready;
  const probe = await fetch(`http://127.0.0.1:${port}/trpc/health`);
  if (!probe.ok) throw new Error(`example probe failed: ${probe.status}`);
}, 30000);

afterAll(async () => {
  child?.kill('SIGTERM');
});

describe('dart subscription conformance over the live wire', () => {
  it(
    'SSE ticks, tracked() resume, and multiplexed WebSocket run against the real server',
    () => {
      try {
        execFileSync(dartBin(), ['test', 'test/subscription_wire_test.dart'], {
          cwd: path.join(REPO_ROOT, 'packages/dart/trpc_dart'),
          env: { ...process.env, RPC_EXAMPLE_PORT: String(port) },
          stdio: 'pipe',
          encoding: 'utf-8',
          timeout: 120000,
        });
      } catch (error) {
        const failure = error as { stdout?: string; stderr?: string };
        throw new Error(
          `wire conformance failed:\n${failure.stdout ?? ''}\n${failure.stderr ?? ''}`,
        );
      }
    },
    150000,
  );
});
