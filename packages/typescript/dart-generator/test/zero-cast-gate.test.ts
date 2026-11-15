import { beforeAll, describe, expect, it } from 'vitest';
import { fileURLToPath } from 'node:url';
import { extractContract } from '@rpc-dart/trpc-adapter';
import { emit } from '../src/index.js';

const sliceTsconfig = fileURLToPath(
  new URL('../../../../tests/e2e/src/fixture/trpc/tsconfig.json', import.meta.url),
);
const tortureTsconfig = fileURLToPath(
  new URL('../../../../tests/e2e/src/fixture/torture/tsconfig.json', import.meta.url),
);

let sliceFiles: Record<string, string> = {};
let tortureFiles: Record<string, string> = {};

beforeAll(async () => {
  const slice = await extractContract({
    tsconfigPath: sliceTsconfig,
    entryFile: 'router.ts',
    exportName: 'appRouter',
    protocol: { kind: 'trpc', version: '11', transformer: 'superjson' },
  });
  sliceFiles = emit(slice.ir).files;

  const torture = await extractContract({
    tsconfigPath: tortureTsconfig,
    entryFile: 'router.ts',
    exportName: 'appRouter',
    protocol: { kind: 'trpc', version: '11', transformer: 'superjson' },
  });
  tortureFiles = emit(torture.ir).files;
}, 60000);

describe('zero-cast gate: generated Dart contains no raw `as` casts', () => {
  for (const [label, files] of [
    ['slice fixture', () => sliceFiles],
    ['torture fixture', () => tortureFiles],
  ] as const) {
    it(label, () => {
      const offenders: string[] = [];
      for (const [path, content] of Object.entries(files())) {
        const match = /(?:\s|\()as\s+[A-Za-z_]/.exec(content);
        if (match) {
          const line = content.slice(0, match.index ?? 0).split('\n').length;
          offenders.push(`${path}:${line} ...${content.slice((match.index ?? 0) - 40, (match.index ?? 0) + 40)}...`);
        }
      }
      expect(offenders, `raw casts found:\n${offenders.join('\n')}`).toEqual([]);
    });
  }
});
