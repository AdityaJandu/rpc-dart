import { describe, expect, it } from 'vitest';
import { fileURLToPath } from 'node:url';
import { extractContract } from '../src/extract.js';
import type { EnumDef, ObjectDef, TypeRef } from '@rpc-dart/core';

const tortureTsconfig = fileURLToPath(
  new URL('../../../../tests/e2e/src/fixture/torture/tsconfig.json', import.meta.url),
);

function ref(type: TypeRef): string {
  if (typeof type === 'object' && type !== null && '$ref' in type) return type.$ref;
  throw new Error(`expected a $ref, got ${JSON.stringify(type)}`);
}

async function extract() {
  const result = await extractContract({
    tsconfigPath: tortureTsconfig,
    entryFile: 'router.ts',
    exportName: 'appRouter',
    protocol: { kind: 'trpc', version: '11', transformer: 'superjson' },
  });
  expect(result.diagnostics).toEqual([]);
  return result.ir;
}

describe('type-system torture extraction', () => {
  it('resolves recursive object types with a self-reference', async () => {
    const ir = await extract();
    const output = ir.types[ref(ir.procedures['widgets.roundTrip']!.output!)] as ObjectDef;
    const category = ir.types[ref(output.fields.find((f) => f.name === 'category')!.type)] as ObjectDef;
    expect(category.kind).toBe('object');
    const children = category.fields.find((f) => f.name === 'children')!;
    expect((children.type as { kind: string }).kind).toBe('list');
    const element = (children.type as { element: TypeRef }).element;
    expect(ref(element)).toBe(ref(output.fields.find((f) => f.name === 'category')!.type));
  });

  it('maps Record<string, T[]> to an inline record with a list value type', async () => {
    const ir = await extract();
    const output = ir.types[ref(ir.procedures['widgets.roundTrip']!.output!)] as ObjectDef;
    const postsByTag = output.fields.find((f) => f.name === 'postsByTag')!.type as {
      kind: string;
      keyType: TypeRef;
      valueType: TypeRef;
    };
    expect(postsByTag.kind).toBe('record');
    expect(postsByTag.keyType).toBe('string');
    expect((postsByTag.valueType as { kind: string }).kind).toBe('list');
    const post = ir.types[ref((postsByTag.valueType as { element: TypeRef }).element)] as ObjectDef;
    expect(post.fields.map((f) => f.name)).toEqual(['id', 'score', 'title']);
  });

  it('maps enum-keyed records to a concrete object with typed fields', async () => {
    // zod resolves enum-keyed records as mapped types over the union, which
    // the checker presents as regular optional properties - a valid object.
    const ir = await extract();
    const output = ir.types[ref(ir.procedures['widgets.roundTrip']!.output!)] as ObjectDef;
    const tagCounts = ir.types[ref(output.fields.find((f) => f.name === 'tagCounts')!.type)] as ObjectDef;
    expect(tagCounts.kind).toBe('object');
    const byName = Object.fromEntries(tagCounts.fields.map((f) => [f.name, f]));
    expect(byName['asc']!.type).toBe('number');
    expect(byName['asc']!.optional).toBe(true);
  });

  it('maps fixed-length tuples to a tuple def with item types', async () => {
    const ir = await extract();
    const output = ir.types[ref(ir.procedures['widgets.roundTrip']!.output!)] as ObjectDef;
    const origin = output.fields.find((f) => f.name === 'origin')!.type as {
      kind: string;
      items: TypeRef[];
    };
    expect(origin.kind).toBe('tuple');
    expect(origin.items).toEqual(['string', 'number']);
  });

  it('maps Set<string> and Map<string, number> to set/record defs', async () => {
    const ir = await extract();
    const output = ir.types[ref(ir.procedures['widgets.roundTrip']!.output!)] as ObjectDef;
    const uniqueTags = output.fields.find((f) => f.name === 'uniqueTags')!.type as {
      kind: string;
      element: TypeRef;
    };
    expect(uniqueTags.kind).toBe('set');
    expect(uniqueTags.element).toBe('string');

    const attributes = output.fields.find((f) => f.name === 'attributes')!.type as {
      kind: string;
      keyType: TypeRef;
      valueType: TypeRef;
    };
    expect(attributes.kind).toBe('record');
    expect(attributes.keyType).toBe('string');
    expect(attributes.valueType).toBe('number');
  });

  it('maps numeric literal unions to an enum with numeric raw values', async () => {
    const ir = await extract();
    const output = ir.types[ref(ir.procedures['widgets.roundTrip']!.output!)] as ObjectDef;
    const version = ir.types[ref(output.fields.find((f) => f.name === 'version')!.type)] as EnumDef;
    expect(version.kind).toBe('enum');
    expect(version.values).toEqual([1, 2, 3]);
  });

  it('unwraps branded strings to the underlying primitive', async () => {
    const ir = await extract();
    const output = ir.types[ref(ir.procedures['widgets.roundTrip']!.output!)] as ObjectDef;
    const ownerId = output.fields.find((f) => f.name === 'ownerId')!;
    expect(ownerId.type).toBe('string');
  });
});
