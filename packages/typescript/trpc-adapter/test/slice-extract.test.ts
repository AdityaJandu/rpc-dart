import { describe, expect, it } from 'vitest';
import { fileURLToPath } from 'node:url';
import { extractContract } from '../src/extract.js';
import type { DiscriminatedUnionDef, ObjectDef, TypeRef } from '@rpc-dart/core';

const fixtureTsconfig = fileURLToPath(
  new URL('../../../../tests/e2e/src/fixture/trpc/tsconfig.json', import.meta.url),
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

async function extract() {
  const result = await extractContract({
    tsconfigPath: fixtureTsconfig,
    entryFile: 'router.ts',
    exportName: 'appRouter',
    protocol: { kind: 'trpc', version: '11', transformer: 'superjson' },
  });
  expect(result.diagnostics).toEqual([]);
  return result.ir;
}

describe('slice extraction to Contract IR', () => {
  it('discovers the full procedure set with kinds and meta', async () => {
    const ir = await extract();
    expect(ir.procedurePaths).toEqual(['posts.list', 'user.getById', 'user.me', 'user.update']);
    expect(ir.procedures['posts.list']!.kind).toBe('query');
    expect(ir.procedures['user.getById']!.kind).toBe('query');
    expect(ir.procedures['user.me']!.kind).toBe('query');
    expect(ir.procedures['user.update']!.kind).toBe('mutation');
    expect(ir.procedures['user.me']!.meta.access).toBe('public');
    expect(ir.procedures['user.getById']!.meta.access).toBe('authenticated');
    expect(ir.procedures['user.update']!.meta.access).toBe('authenticated');
  });

  it('wire input uses z.input semantics: transform fields stay wire-shaped', async () => {
    const ir = await extract();
    expect(ir.procedures['user.me']!.input).toBeNull();

    const updateInput = objectOf(ir, ir.procedures['user.update']!.input!);
    expect(updateInput.kind).toBe('object');

    const charCount = updateInput.fields.find((f) => f.name === 'charCount');
    expect(charCount).toBeDefined();
    expect(charCount!.type).toBe('string'); // NOT number: z.input, not z.output
    expect(charCount!.optional).toBe(false);

    const nickname = updateInput.fields.find((f) => f.name === 'nickname');
    expect(nickname!.optional).toBe(true);
    expect(nickname!.nullable).toBe(true);

    const name = updateInput.fields.find((f) => f.name === 'name');
    expect(name!.optional).toBe(true);
    expect(name!.nullable).toBe(false);
  });

  it('output shapes carry Date/BigInt primitives, enum, discriminated union, record', async () => {
    const ir = await extract();
    const output = objectOf(ir, ir.procedures['user.getById']!.output!);
    expect(output.name).toBe('UserGetByIdOutput');

    const byName = Object.fromEntries(output.fields.map((f) => [f.name, f]));
    expect(byName['createdAt']!.type).toBe('Date');
    expect(byName['balance']!.type).toBe('BigInt');
    expect(byName['id']!.type).toBe('string');

    const sortHint = byName['sortHint']!.type;
    expect(ir.types[ref(sortHint)]).toEqual({
      kind: 'enum',
      name: expect.any(String),
      values: ['asc', 'desc'],
    });

    const payment = ir.types[ref(byName['payment']!.type)] as DiscriminatedUnionDef;
    expect(payment.kind).toBe('discriminatedUnion');
    expect(payment.tagField).toBe('type');
    expect(payment.variants.map((v) => v.tag)).toEqual(['card', 'invoice']);
    const card = objectOf(ir, payment.variants[0]!.object);
    expect(card.fields.map((f) => f.name)).toEqual(['last4', 'type']); // IR fields sorted by name
    const tagField = card.fields.find((f) => f.name === 'type');
    expect(tagField!.type).toEqual({ kind: 'literal', value: 'card' });

    const metadata = byName['metadata']!.type;
    expect(metadata).toEqual({
      kind: 'record',
      keyType: 'string',
      valueType: { kind: 'unknown' },
    });
  });

  it('optional/nullable flags match the schemas', async () => {
    const ir = await extract();
    const output = objectOf(ir, ir.procedures['user.getById']!.output!);
    const byName = Object.fromEntries(output.fields.map((f) => [f.name, f]));
    expect(byName['nickname']!.optional).toBe(true);
    expect(byName['nickname']!.nullable).toBe(true);
    expect(byName['address']!.optional).toBe(true);
    expect(byName['address']!.nullable).toBe(false);
    expect(byName['id']!.optional).toBe(false);
    expect(byName['id']!.nullable).toBe(false);

    const postsList = objectOf(ir, ir.procedures['posts.list']!.input!);
    const byName2 = Object.fromEntries(postsList.fields.map((f) => [f.name, f]));
    expect(byName2['cursor']!.optional).toBe(true);
    expect(byName2['sort']!.optional).toBe(false);
  });

  it('shared shapes deduplicate: me/getById/update outputs reference one registry entry', async () => {
    const ir = await extract();
    const meOut = ref(ir.procedures['user.me']!.output!);
    const getByIdOut = ref(ir.procedures['user.getById']!.output!);
    const updateOut = ref(ir.procedures['user.update']!.output!);
    expect(meOut).toBe(getByIdOut);
    expect(getByIdOut).toBe(updateOut);
  });

  it('nested router tree mirrors the backend structure', async () => {
    const ir = await extract();
    expect(ir.tree.kind).toBe('router');
    if (ir.tree.kind !== 'router') return;
    expect(ir.tree.name).toBe('appRouter');
    expect(Object.keys(ir.tree.children).sort()).toEqual(['posts', 'user']);
    const user = ir.tree.children['user']!;
    expect(user.kind).toBe('router');
    if (user.kind !== 'router') return;
    expect(user.name).toBe('userRouter');
  });

  it('is deterministic: two extractions produce the same hash', async () => {
    const a = await extract();
    const b = await extract();
    expect(a.hash).toBe(b.hash);
    expect(a.hash.startsWith('sha256-')).toBe(true);
  });
});
