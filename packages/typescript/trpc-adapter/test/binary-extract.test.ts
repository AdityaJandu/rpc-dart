import { describe, expect, it } from 'vitest';
import { fileURLToPath } from 'node:url';
import { extractContract } from '../src/extract.js';
import type { ObjectDef } from '@rpc-dart/core';

const binaryTsconfig = fileURLToPath(
  new URL('../../../../tests/e2e/src/fixture/binary/tsconfig.json', import.meta.url),
);

async function extract() {
  const result = await extractContract({
    tsconfigPath: binaryTsconfig,
    entryFile: 'router.ts',
    exportName: 'appRouter',
    protocol: { kind: 'trpc', version: '11', transformer: 'superjson' },
  });
  expect(result.diagnostics).toEqual([]);
  return result.ir;
}

describe('binary type extraction', () => {
  it('maps Uint8Array, ArrayBuffer and Buffer outputs to the Bytes primitive', async () => {
    const ir = await extract();
    expect(ir.procedures['bytes.fromUint8Array']!.output).toBe('Bytes');
    expect(ir.procedures['bytes.fromArrayBuffer']!.output).toBe('Bytes');
    expect(ir.procedures['bytes.fromBuffer']!.output).toBe('Bytes');
  });

  it('maps File and Blob outputs to the File primitive', async () => {
    const ir = await extract();
    expect(ir.procedures['files.fromFile']!.output).toBe('File');
    expect(ir.procedures['files.fromBlob']!.output).toBe('File');
  });

  it('maps ReadableStream<Uint8Array> outputs to the ByteStream primitive', async () => {
    const ir = await extract();
    expect(ir.procedures['streams.download']!.output).toBe('ByteStream');
  });

  it('classifies binary input fields inside object schemas', async () => {
    const ir = await extract();
    const input = ir.procedures['files.upload']!.input;
    expect(typeof input).toBe('object');
    const def = ir.types[(input as { $ref: string }).$ref] as ObjectDef;
    expect(def.fields.find((f) => f.name === 'avatar')!.type).toBe('File');
    expect(def.fields.find((f) => f.name === 'payload')!.type).toBe('Bytes');
  });
});