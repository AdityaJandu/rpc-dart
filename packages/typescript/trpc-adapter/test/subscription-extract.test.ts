import { describe, expect, it } from 'vitest';
import { fileURLToPath } from 'node:url';
import { extractContract } from '../src/extract.js';
import type { DiscriminatedUnionDef, ObjectDef, PrimitiveDef, TypeRef } from '@rpc-dart/core';

const bundlerTsconfig = fileURLToPath(
  new URL('../../../../tests/e2e/src/fixture/subscriptions/tsconfig.json', import.meta.url),
);
const nodenextTsconfig = fileURLToPath(
  new URL('../../../../tests/e2e/src/fixture/subscriptions/tsconfig.nodenext.json', import.meta.url),
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

// Primitives appear as bare strings ("number") or inline primitive defs.
function primitiveName(type: TypeRef): PrimitiveDef['name'] {
  if (typeof type === 'string') return type as PrimitiveDef['name'];
  const inline = type as { kind?: string; name?: PrimitiveDef['name'] };
  if (inline.kind === 'primitive') return inline.name!;
  throw new Error(`expected a primitive, got ${JSON.stringify(type)}`);
}

async function extract(tsconfigPath: string) {
  const result = await extractContract({
    tsconfigPath,
    entryFile: 'router.ts',
    exportName: 'appRouter',
    protocol: { kind: 'trpc', version: '11', transformer: 'superjson' },
  });
  expect(result.diagnostics).toEqual([]);
  return result.ir;
}

describe('subscription extraction (async generators, tracked(), observable)', () => {
  it('Test 1.1: extracts kind=subscription and unwraps generator yields to the item type', async () => {
    const ir = await extract(bundlerTsconfig);

    for (const path of ir.procedurePaths) {
      expect(ir.procedures[path]!.kind, path).toBe('subscription');
    }

    // Primitive yield: number
    expect(primitiveName(ir.procedures['counter.onValue']!.output)).toBe('number');

    // Nested object yield: { tick: number; serverTime: Date }
    const tick = objectOf(ir, ir.procedures['streams.onServerTick']!.output);
    expect(tick.fields.find((f) => f.name === 'tick')!.type).toBe('number');
    expect(primitiveName(tick.fields.find((f) => f.name === 'serverTime')!.type)).toBe('Date');

    // Discriminated union yield
    const status = ir.types[ref(ir.procedures['streams.onStatusFeed']!.output)] as DiscriminatedUnionDef;
    expect(status.kind).toBe('discriminatedUnion');
    expect(status.variants.length).toBe(2);
  });

  it('Test 1.2: unwraps tracked(id, data) envelopes and flags supportsLastEventId', async () => {
    const ir = await extract(bundlerTsconfig);

    const activity = objectOf(ir, ir.procedures['streams.onActivity']!.output);
    expect(activity.fields.map((f) => f.name).sort()).toEqual(['createdAt', 'messageId', 'text']);
    expect(activity.fields.find((f) => f.name === 'createdAt')).toBeDefined();
    expect(primitiveName(activity.fields.find((f) => f.name === 'createdAt')!.type)).toBe('Date');

    expect(ir.procedures['streams.onActivity']!.meta.extra['supportsLastEventId']).toBe(true);
    // Untracked subscriptions do not advertise resume support.
    expect(ir.procedures['streams.onServerTick']!.meta.extra['supportsLastEventId']).toBe(false);
    // The tracked subscription's input keeps the client-facing lastEventId field.
    const input = objectOf(ir, ir.procedures['streams.onActivity']!.input!);
    expect(input.fields.find((f) => f.name === 'lastEventId')).toBeDefined();
  });

  it('Test 1.3: unwraps observable subscriptions to the emitted payload type', async () => {
    const ir = await extract(bundlerTsconfig);

    const event = objectOf(ir, ir.procedures['streams.onUserEvent']!.output);
    expect(event.fields.map((f) => f.name).sort()).toEqual(['action', 'at', 'userId']);
    expect(ir.procedures['streams.onUserEvent']!.kind).toBe('subscription');
  });

  it('emits a void/never-yield generator cleanly instead of failing', async () => {
    const ir = await extract(bundlerTsconfig);
    expect(primitiveName(ir.procedures['streams.onDrained']!.output)).toBe('never');
  });

  it('Test 1.4: extracts subscriptions under NodeNext tsconfig resolution too', async () => {
    const ir = await extract(nodenextTsconfig);

    expect(ir.procedures['streams.onActivity']!.kind).toBe('subscription');
    const activity = objectOf(ir, ir.procedures['streams.onActivity']!.output);
    expect(activity.fields.find((f) => f.name === 'messageId')).toBeDefined();
    expect(ir.procedures['streams.onActivity']!.meta.extra['supportsLastEventId']).toBe(true);

    const tick = objectOf(ir, ir.procedures['streams.onServerTick']!.output);
    expect(tick.fields.find((f) => f.name === 'tick')!.type).toBe('number');
  });
});
