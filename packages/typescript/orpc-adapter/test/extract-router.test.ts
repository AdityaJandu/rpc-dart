import { describe, expect, it } from 'vitest';
import { fileURLToPath } from 'node:url';
import { extractContract } from '../src/index.js';
import type { DiscriminatedUnionDef, ObjectDef, TypeRef } from '@rpc-dart/core';

const tsconfigPath = fileURLToPath(
  new URL('../../../../tests/e2e/src/fixture/orpc/tsconfig.json', import.meta.url),
);

function ref(type: TypeRef): string {
  if (typeof type === 'object' && type !== null && '$ref' in type) return type.$ref;
  throw new Error(`expected a $ref, got ${JSON.stringify(type)}`);
}

async function extract(exportName: string) {
  const result = await extractContract({ tsconfigPath, entryFile: 'router.ts', exportName });
  expect(result.diagnostics).toEqual([]);
  return result.ir;
}

describe('oRPC implemented router extraction', () => {
  it('extracts implement(contract) routers with contract schemas and error maps', async () => {
    const ir = await extract('appRouter');
    expect(ir.procedurePaths).toEqual([
      'planet.create',
      'planet.find',
      'planet.watch',
      'uploads.avatar',
      'uploads.raw',
      'uploads.stream',
      'valibot.echo',
    ]);
    expect(ir.procedures['planet.find']!.kind).toBe('query');
    const output = ir.types[ref(ir.procedures['planet.find']!.output)] as ObjectDef;
    expect(output.fields.find((f) => f.name === 'discoveredAt')!.type).toBe('Date');
    const error = ir.types[ref(ir.procedures['planet.find']!.error!)] as DiscriminatedUnionDef;
    expect(error.variants.map((v) => v.tag)).toEqual(['BAD_REQUEST', 'NOT_FOUND']);
    expect(ir.procedures['planet.watch']!.kind).toBe('subscription');
    expect(ir.procedures['uploads.raw']!.output).toBe('Bytes');
    expect(ir.procedures['uploads.stream']!.output).toBe('ByteStream');
  });
});

describe('oRPC inferred router extraction', () => {
  it('infers output types from handler return values without .output()', async () => {
    const ir = await extract('inferredRouter');
    const health = ir.types[ref(ir.procedures['health']!.output)] as ObjectDef;
    expect(health.fields.find((f) => f.name === 'ok')!.type).toEqual({ kind: 'literal', value: true });
    expect(health.fields.find((f) => f.name === 'uptime')!.type).toBe('number');
    const now = ir.types[ref(ir.procedures['now']!.output)] as ObjectDef;
    expect(now.fields.find((f) => f.name === 'at')!.type).toBe('Date');
    expect(now.fields.find((f) => f.name === 'big')!.type).toBe('BigInt');
  });

  it('maps GET routes to queries and unwraps inferred async generators', async () => {
    const ir = await extract('inferredRouter');
    expect(ir.procedures['ping']!.kind).toBe('query');
    expect(ir.procedures['ping']!.output).toBe('string');
    expect(ir.procedures['counter']!.kind).toBe('subscription');
    const item = ir.types[ref(ir.procedures['counter']!.output)] as ObjectDef;
    expect(item.fields.find((f) => f.name === 'n')!.type).toBe('number');
  });

  it('resolves lazy routers at probe and type level', async () => {
    const ir = await extract('inferredRouter');
    expect(ir.procedures['nested.ping']!.output).toBe('string');
    expect(ir.tree.kind).toBe('router');
  });

  it('has no error map for plain os procedures', async () => {
    const ir = await extract('inferredRouter');
    expect(ir.procedures['health']!.error).toBeNull();
  });
});