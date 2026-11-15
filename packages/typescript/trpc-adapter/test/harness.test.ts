import { afterAll, describe, expect, it } from 'vitest';
import { fileURLToPath } from 'node:url';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { entryImportPath, buildHarness } from '../src/harness.js';
import { extractContract } from '../src/extract.js';
import type { ObjectDef, TypeRef } from '@rpc-dart/core';

const nodenextFixtureTsconfig = fileURLToPath(
  new URL('../../../../tests/e2e/src/fixture/nodenext/tsconfig.json', import.meta.url),
);

function ref(type: TypeRef): string {
  if (typeof type === 'object' && type !== null && '$ref' in type) {
    return type.$ref;
  }
  throw new Error(`expected a $ref, got ${JSON.stringify(type)}`);
}

function objectOf(ir: { types: Record<string, unknown> }, type: TypeRef): ObjectDef {
  return ir.types[ref(type)] as ObjectDef;
}

describe('harness entry import path', () => {
  const dir = resolve('/proj');

  const cases: ReadonlyArray<{
    resolution: 'node16' | 'nodenext' | undefined;
    entry: string;
    expected: string;
  }> = [
    // Bundler-style: extensionless relative specifiers are legal.
    { resolution: undefined, entry: 'src/server.ts', expected: './src/server' },
    { resolution: undefined, entry: 'src/server.tsx', expected: './src/server' },
    { resolution: undefined, entry: 'src/server.mts', expected: './src/server' },
    { resolution: undefined, entry: 'src/server.cts', expected: './src/server' },
    // Node16/NodeNext: explicit extensions are mandatory (TS5097); the
    // TS-standard .js/.mjs/.cjs specifiers resolve to the .ts sources with or
    // without allowImportingTsExtensions.
    { resolution: 'nodenext', entry: 'src/server.ts', expected: './src/server.js' },
    { resolution: 'nodenext', entry: 'src/server.tsx', expected: './src/server.js' },
    { resolution: 'nodenext', entry: 'src/server.mts', expected: './src/server.mjs' },
    { resolution: 'nodenext', entry: 'src/server.cts', expected: './src/server.cjs' },
    { resolution: 'node16', entry: 'src/server.ts', expected: './src/server.js' },
    { resolution: 'node16', entry: 'src/server.mts', expected: './src/server.mjs' },
    { resolution: 'node16', entry: 'src/server.cts', expected: './src/server.cjs' },
  ];

  for (const c of cases) {
    it(`maps ${c.entry} -> ${c.expected} (resolution: ${c.resolution ?? 'default'})`, () => {
      expect(entryImportPath(dir, resolve(dir, c.entry), c.resolution)).toBe(c.expected);
    });
  }
});

describe('harness source shape', () => {
  it('imports the entry as type-only so verbatimModuleSyntax never sees a value import', () => {
    const source = buildHarness('./router', 'appRouter', ['health']);
    expect(source).toContain('import type { appRouter } from "./router";');
    // The tRPC inference utilities must be type-only too.
    expect(source).toMatch(/import type \{ inferRouterInputs, inferRouterOutputs \}/);
  });
});

describe('extraction under NodeNext tsconfig resolution', () => {
  it('extracts a NodeNext project without TS5097 diagnostics', async () => {
    const result = await extractContract({
      tsconfigPath: nodenextFixtureTsconfig,
      entryFile: 'router.ts',
      exportName: 'appRouter',
      protocol: { kind: 'trpc', version: '11', transformer: 'superjson' },
    });
    expect(result.diagnostics).toEqual([]);
    expect(Object.keys(result.ir.procedures).sort()).toEqual(['greet', 'health']);
  });
});

// --- tsconfig-profile independence -------------------------------------------

/**
 * Synthetic router shared by every profile. It compiles cleanly under strict +
 * exactOptionalPropertyTypes + erasableSyntaxOnly, uses only value imports of
 * value bindings (verbatimModuleSyntax-safe), and deliberately contains a
 * lint-only unused local so Profile E proves the extractor neutralizes
 * noUnusedLocals in its in-memory program.
 */
const profileRouterSource = `import { initTRPC } from '@trpc/server';
import { z } from 'zod';
import superjson from 'superjson';

export interface ProfileContext {
  userId: string | null;
}

const t = initTRPC.context<ProfileContext>().create({ transformer: superjson });

function profileLintProbe(): string {
  const unusedLintOnly = 'flagged only if noUnusedLocals survives extraction';
  return 'probe';
}

export const appRouter = t.router({
  health: t.procedure.query(() => ({ ok: true })),
  greet: t.procedure
    .input(z.object({ name: z.string() }))
    .query(({ input }) => ({ message: \`hello \${input.name}\` })),
});

export type AppRouter = typeof appRouter;
`;

interface TsConfigProfile {
  id: string;
  compilerOptions: Record<string, unknown>;
  entry: string;
  include: string[];
}

/**
 * Every profile is a realistic backend tsconfig. skipLibCheck is set where a
 * real project would set it: @trpc/server's own declaration files reference
 * its optional `ws` peer, so lib-level checking is a packaging property of
 * @trpc/server, not something the extraction harness should depend on.
 */
const tsConfigProfiles: TsConfigProfile[] = [
  {
    id: 'A-commonjs-node10',
    compilerOptions: {
      strict: true,
      target: 'ES2022',
      lib: ['ES2022'],
      module: 'CommonJS',
      moduleResolution: 'node',
      skipLibCheck: true,
    },
    entry: 'router.ts',
    include: ['*.ts'],
  },
  {
    id: 'B-esnext-bundler',
    compilerOptions: {
      strict: true,
      target: 'ESNext',
      module: 'ESNext',
      moduleResolution: 'bundler',
      skipLibCheck: true,
      noEmit: true,
    },
    entry: 'router.ts',
    include: ['*.ts'],
  },
  {
    id: 'C-nodenext-no-ts-extensions',
    compilerOptions: {
      strict: true,
      target: 'ESNext',
      module: 'NodeNext',
      moduleResolution: 'NodeNext',
      skipLibCheck: true,
      noEmit: true,
    },
    entry: 'router.ts',
    include: ['*.ts'],
  },
  {
    id: 'D-nodenext-strict-flags',
    compilerOptions: {
      strict: true,
      target: 'ESNext',
      module: 'NodeNext',
      moduleResolution: 'NodeNext',
      allowImportingTsExtensions: true,
      verbatimModuleSyntax: true,
      erasableSyntaxOnly: true,
      skipLibCheck: true,
      noEmit: true,
    },
    entry: 'router.ts',
    include: ['*.ts'],
  },
  {
    id: 'E-composite-build-flags',
    compilerOptions: {
      strict: true,
      target: 'ESNext',
      module: 'ESNext',
      moduleResolution: 'bundler',
      rootDir: './src',
      composite: true,
      exactOptionalPropertyTypes: true,
      noUnusedLocals: true,
      skipLibCheck: true,
      noEmit: true,
    },
    entry: 'src/router.ts',
    include: ['src/**/*.ts'],
  },
];

describe('extraction succeeds across backend tsconfig profiles', () => {
  const scratchDirs: string[] = [];

  afterAll(() => {
    for (const dir of scratchDirs) rmSync(dir, { recursive: true, force: true });
  });

  function writeProfileFixture(profile: TsConfigProfile): { tsconfigPath: string } {
    // Fixtures must live under tests/e2e/ so bare imports (@trpc/server, zod,
    // superjson) resolve through the workspace node_modules chain, and inside
    // tests/e2e/.tmp/ which the repo gitignores. mkdtemp's parent must exist.
    const scratchRoot = fileURLToPath(
      new URL('../../../../tests/e2e/.tmp/', import.meta.url),
    );
    mkdirSync(scratchRoot, { recursive: true });
    const dir = mkdtempSync(join(scratchRoot, `tsprofile-${profile.id}-`));
    scratchDirs.push(dir);

    const routerPath = join(dir, profile.entry);
    mkdirSync(dirname(routerPath), { recursive: true });
    writeFileSync(routerPath, profileRouterSource);
    writeFileSync(
      join(dir, 'tsconfig.json'),
      `${JSON.stringify(
        { compilerOptions: profile.compilerOptions, include: profile.include },
        null,
        2,
      )}\n`,
    );
    return { tsconfigPath: join(dir, 'tsconfig.json') };
  }

  for (const profile of tsConfigProfiles) {
    it(`extracts profile ${profile.id}`, async () => {
      const { tsconfigPath } = writeProfileFixture(profile);
      const result = await extractContract({
        tsconfigPath,
        entryFile: profile.entry,
        exportName: 'appRouter',
        protocol: { kind: 'trpc', version: '11', transformer: 'superjson' },
      });
      expect(result.diagnostics).toEqual([]);
      expect(Object.keys(result.ir.procedures).sort()).toEqual(['greet', 'health']);

      const greet = result.ir.procedures['greet']!;
      const input = objectOf(result.ir, greet.input!);
      expect(input.fields.find((f) => f.name === 'name')!.type).toBe('string');
    });
  }
});
