import { afterAll, describe, expect, it } from 'vitest';
import { fileURLToPath } from 'node:url';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { extractContract } from '../src/index.js';
import type { ObjectDef, TypeRef } from '@rpc-dart/core';

function ref(type: TypeRef): string {
  if (typeof type === 'object' && type !== null && '$ref' in type) return type.$ref;
  throw new Error(`expected a $ref, got ${JSON.stringify(type)}`);
}

function objectOf(ir: { types: Record<string, unknown> }, type: TypeRef): ObjectDef {
  return ir.types[ref(type)] as ObjectDef;
}

/**
 * Synthetic router shared by every profile: strict-safe, verbatimModuleSyntax
 * -safe, and deliberately carrying a lint-only unused local so Profile E
 * proves the extractor neutralizes noUnusedLocals in its in-memory program.
 */
const profileRouterSource = `import { os } from '@orpc/server';
import { z } from 'zod';

function profileLintProbe(): string {
  const unusedLintOnly = 'flagged only if noUnusedLocals survives extraction';
  return 'probe';
}

export const appRouter = os.router({
  health: os.handler(() => ({ ok: true })),
  greet: os.input(z.object({ name: z.string() })).handler(({ input }) => ({ message: \`hello \${input.name}\` })),
  ticks: os.handler(async function* () {
    yield { n: 1 };
  }),
});
`;

interface TsConfigProfile {
  id: string;
  compilerOptions: Record<string, unknown>;
  entry: string;
  include: string[];
}

/**
 * @orpc/* packages are exports-map-only (no main/types fields), so classic
 * node10 resolution cannot see them; the CommonJS profile therefore pairs
 * CommonJS emit with node16 resolution, the realistic CJS backend setup.
 */
const tsConfigProfiles: TsConfigProfile[] = [
  {
    id: 'A-commonjs-node16',
    compilerOptions: {
      strict: true,
      target: 'ES2022',
      lib: ['ES2022'],
      module: 'CommonJS',
      moduleResolution: 'node16',
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

describe('oRPC extraction succeeds across backend tsconfig profiles', () => {
  const scratchDirs: string[] = [];

  afterAll(() => {
    for (const dir of scratchDirs) rmSync(dir, { recursive: true, force: true });
  });

  function writeProfileFixture(profile: TsConfigProfile): { tsconfigPath: string } {
    const scratchRoot = fileURLToPath(new URL('../../../../tests/e2e/.tmp/', import.meta.url));
    mkdirSync(scratchRoot, { recursive: true });
    const dir = mkdtempSync(join(scratchRoot, `orpc-profile-${profile.id}-`));
    scratchDirs.push(dir);

    const routerPath = join(dir, profile.entry);
    mkdirSync(dirname(routerPath), { recursive: true });
    writeFileSync(routerPath, profileRouterSource);
    writeFileSync(
      join(dir, 'tsconfig.json'),
      `${JSON.stringify({ compilerOptions: profile.compilerOptions, include: profile.include }, null, 2)}\n`,
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
      });
      expect(result.diagnostics).toEqual([]);
      expect(Object.keys(result.ir.procedures).sort()).toEqual(['greet', 'health', 'ticks']);

      const greet = result.ir.procedures['greet']!;
      const input = objectOf(result.ir, greet.input!);
      expect(input.fields.find((f) => f.name === 'name')!.type).toBe('string');

      const ticks = result.ir.procedures['ticks']!;
      expect(ticks.kind).toBe('subscription');
      expect(objectOf(result.ir, ticks.output).fields.find((f) => f.name === 'n')!.type).toBe('number');
    });
  }
});