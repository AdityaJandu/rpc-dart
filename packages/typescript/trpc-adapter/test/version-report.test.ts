import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { extractContract } from '../src/extract.js';

const pkg = JSON.parse(
  readFileSync(fileURLToPath(new URL('../package.json', import.meta.url)), 'utf-8'),
) as { version: string };

const tsconfigPath = fileURLToPath(
  new URL('../../../../tests/e2e/src/fixture/trpc/tsconfig.json', import.meta.url),
);

describe('adapter version reporting', () => {
  it('reports the package version in source.adapterVersion and generator.version', async () => {
    const { ir } = await extractContract({
      tsconfigPath,
      entryFile: 'router.ts',
      exportName: 'appRouter',
      protocol: { kind: 'trpc', version: '11', transformer: 'superjson' },
    });
    expect(ir.source.adapterVersion).toBe(pkg.version);
    expect(ir.generator.version).toBe(pkg.version);
  });
});