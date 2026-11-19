import { describe, expect, it } from 'vitest';
import { fileURLToPath } from 'node:url';
import { ProbeError, probeRouter } from '../src/index.js';

const entry = fileURLToPath(
  new URL('../../../../tests/e2e/src/fixture/orpc/router.ts', import.meta.url),
);

describe('oRPC route probe', () => {
  it('discovers contract paths with kinds from route method and event iterators', async () => {
    const paths = await probeRouter(entry, 'contractRouter');
    const byPath = new Map(paths.map((p) => [p.path, p]));
    expect([...byPath.keys()].sort()).toEqual([
      'planet.create',
      'planet.find',
      'planet.watch',
      'uploads.avatar',
      'uploads.raw',
      'uploads.stream',
      'valibot.echo',
    ]);
    expect(byPath.get('planet.find')!.kind).toBe('query');
    expect(byPath.get('planet.create')!.kind).toBe('mutation');
    expect(byPath.get('planet.watch')!.kind).toBe('subscription');
    expect(byPath.get('planet.find')!.route).toEqual({ method: 'GET', path: '/planets/{id}' });
    expect(byPath.get('planet.create')!.errorCodes.sort()).toEqual(['CONFLICT', 'RATE_LIMITED']);
  });

  it('unwraps lazy routers during discovery', async () => {
    const paths = await probeRouter(entry, 'inferredRouter');
    expect(paths.map((p) => p.path)).toContain('nested.ping');
  });

  it('rejects exports that are not routers', async () => {
    await expect(probeRouter(entry, 'notARouter')).rejects.toThrow(ProbeError);
    await expect(probeRouter(entry, 'missingExport')).rejects.toThrow(ProbeError);
  });
});