import { describe, expect, it } from 'vitest';
import { resolve } from 'node:path';
import { entryImportPath } from '../src/harness.js';

describe('harness entry import path', () => {
  const dir = resolve('/proj');

  it('strips the extension for bundler-style resolution', () => {
    expect(entryImportPath(dir, resolve(dir, 'src/server.ts'))).toBe('./src/server');
  });

  it('emits an explicit .js extension under node16/nodenext resolution', () => {
    // NodeNext rejects extensionless relative imports (TS5097); the TS-standard
    // '.js' specifier resolves to the .ts source with or without
    // allowImportingTsExtensions.
    expect(entryImportPath(dir, resolve(dir, 'src/server.ts'), 'nodenext')).toBe('./src/server.js');
    expect(entryImportPath(dir, resolve(dir, 'src/server.ts'), 'node16')).toBe('./src/server.js');
  });
});

describe('extraction under NodeNext tsconfig resolution', () => {
  it('extracts a NodeNext project without TS5097 diagnostics', async () => {
    const { extractContract } = await import('../src/extract.js');
    const { fileURLToPath } = await import('node:url');
    const tsconfig = fileURLToPath(
      new URL('../../../../tests/e2e/src/fixture/nodenext/tsconfig.json', import.meta.url),
    );
    const result = await extractContract({
      tsconfigPath: tsconfig,
      entryFile: 'router.ts',
      exportName: 'appRouter',
      protocol: { kind: 'trpc', version: '11', transformer: 'superjson' },
    });
    expect(result.diagnostics).toEqual([]);
    expect(Object.keys(result.ir.procedures).sort()).toEqual(['greet', 'health']);
  });
});
