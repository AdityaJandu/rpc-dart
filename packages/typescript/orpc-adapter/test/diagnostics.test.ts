import { describe, expect, it } from 'vitest';
import { fileURLToPath } from 'node:url';
import { ExtractionFailure } from '@rpc-dart/core';
import { extractContract } from '../src/index.js';

const tsconfigPath = fileURLToPath(
  new URL('../../../../tests/e2e/src/fixture/orpc-diagnostics/tsconfig.json', import.meta.url),
);
const mainTsconfigPath = fileURLToPath(
  new URL('../../../../tests/e2e/src/fixture/orpc/tsconfig.json', import.meta.url),
);

describe('oRPC extraction diagnostics', () => {
  it('rejects event iterator inputs with RPCDART0201 under the error policy', async () => {
    await expect(
      extractContract({ tsconfigPath, entryFile: 'router.ts', exportName: 'badRouter' }),
    ).rejects.toMatchObject({
      name: 'ExtractionFailure',
      diagnostics: [expect.objectContaining({ code: 'RPCDART0201', procedurePath: 'streamInput' })],
    });
  });

  it('drops offending procedures under skip-procedure and keeps healthy ones', async () => {
    const result = await extractContract({
      tsconfigPath,
      entryFile: 'router.ts',
      exportName: 'badRouter',
      policies: { unserializablePolicy: 'skip-procedure' },
    });
    expect(result.ir.procedurePaths).toEqual(['fine']);
    expect(result.diagnostics).toEqual([
      expect.objectContaining({ code: 'RPCDART0201', severity: 'warning', procedurePath: 'streamInput' }),
    ]);
  });

  it('reports RPCDART0102 when the export is not a router', async () => {
    const failure = await extractContract({
      tsconfigPath: mainTsconfigPath,
      entryFile: 'router.ts',
      exportName: 'notARouter',
    }).catch((e: unknown) => e);
    expect(failure).toBeInstanceOf(ExtractionFailure);
    expect((failure as ExtractionFailure).diagnostics[0]!.code).toBe('RPCDART0102');
  });
});