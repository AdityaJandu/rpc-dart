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

describe('oRPC contract extraction', () => {
  it('marks the protocol as orpc and discovers every procedure path', async () => {
    const ir = await extract('contractRouter');
    expect(ir.protocol.kind).toBe('orpc');
    expect(ir.procedurePaths).toEqual([
      'planet.create',
      'planet.find',
      'planet.watch',
      'uploads.avatar',
      'uploads.raw',
      'uploads.stream',
      'valibot.echo',
    ]);
  });

  it('maps GET routes to queries, default routes to mutations, event iterators to subscriptions', async () => {
    const ir = await extract('contractRouter');
    expect(ir.procedures['planet.find']!.kind).toBe('query');
    expect(ir.procedures['planet.create']!.kind).toBe('mutation');
    expect(ir.procedures['planet.watch']!.kind).toBe('subscription');
    expect(ir.procedures['planet.find']!.meta.extra['route']).toEqual({ method: 'GET', path: '/planets/{id}' });
  });

  it('resolves zod input and output schemas including Date fields', async () => {
    const ir = await extract('contractRouter');
    const output = ir.types[ref(ir.procedures['planet.find']!.output)] as ObjectDef;
    expect(output.fields.map((f) => f.name)).toEqual(['discoveredAt', 'id', 'name']);
    expect(output.fields.find((f) => f.name === 'discoveredAt')!.type).toBe('Date');
    const input = ir.types[ref(ir.procedures['planet.find']!.input!)] as ObjectDef;
    expect(input.fields.find((f) => f.name === 'id')!.type).toBe('number');
  });

  it('extracts typed error maps as discriminated unions on code', async () => {
    const ir = await extract('contractRouter');
    const error = ir.types[ref(ir.procedures['planet.find']!.error!)] as DiscriminatedUnionDef;
    expect(error.kind).toBe('discriminatedUnion');
    expect(error.tagField).toBe('code');
    expect(error.variants.map((v) => v.tag)).toEqual(['BAD_REQUEST', 'NOT_FOUND']);
    const variant = ir.types[ref(error.variants.find((v) => v.tag === 'NOT_FOUND')!.object)] as ObjectDef;
    expect(variant.fields.find((f) => f.name === 'code')!.type).toEqual({ kind: 'literal', value: 'NOT_FOUND' });
    expect(variant.fields.find((f) => f.name === 'message')!.type).toBe('string');
    const dataField = variant.fields.find((f) => f.name === 'data')!;
    expect(dataField.optional).toBe(true);
    const data = ir.types[ref(dataField.type)] as ObjectDef;
    expect(data.fields.find((f) => f.name === 'id')!.type).toBe('number');
    const scalar = ir.types[ref(error.variants.find((v) => v.tag === 'BAD_REQUEST')!.object)] as ObjectDef;
    expect(scalar.fields.find((f) => f.name === 'data')!.type).toBe('string');
  });

  it('keeps schema-less defined errors and multiple codes sorted', async () => {
    const ir = await extract('contractRouter');
    const error = ir.types[ref(ir.procedures['planet.create']!.error!)] as DiscriminatedUnionDef;
    expect(error.variants.map((v) => v.tag)).toEqual(['CONFLICT', 'RATE_LIMITED']);
    const rateLimited = ir.types[ref(error.variants[1]!.object)] as ObjectDef;
    expect(rateLimited.fields.some((f) => f.name === 'data')).toBe(false);
  });

  it('leaves error null when no errors are defined', async () => {
    const ir = await extract('contractRouter');
    expect(ir.procedures['uploads.raw']!.error).toBeNull();
  });

  it('unwraps event iterator outputs to the streamed item type with resume support', async () => {
    const ir = await extract('contractRouter');
    const item = ir.types[ref(ir.procedures['planet.watch']!.output)] as ObjectDef;
    expect(item.fields.find((f) => f.name === 'tick')!.type).toBe('number');
    expect(item.fields.find((f) => f.name === 'at')!.type).toBe('Date');
    expect(ir.procedures['planet.watch']!.meta.extra['supportsLastEventId']).toBe(true);
  });

  it('extracts Valibot Standard Schema inputs and outputs', async () => {
    const ir = await extract('contractRouter');
    const input = ir.types[ref(ir.procedures['valibot.echo']!.input!)] as ObjectDef;
    const tag = input.fields.find((f) => f.name === 'tag')!;
    expect(tag.type).toBe('string');
    expect(tag.optional).toBe(true);
    const output = ir.types[ref(ir.procedures['valibot.echo']!.output)] as ObjectDef;
    expect(output.fields.find((f) => f.name === 'doubled')!.type).toBe('number');
  });

  it('maps binary schema types to Bytes/File/ByteStream primitives', async () => {
    const ir = await extract('contractRouter');
    const avatarInput = ir.types[ref(ir.procedures['uploads.avatar']!.input!)] as ObjectDef;
    expect(avatarInput.fields.find((f) => f.name === 'file')!.type).toBe('File');
    expect(avatarInput.fields.find((f) => f.name === 'thumb')!.type).toBe('File');
    expect(ir.procedures['uploads.raw']!.input).toBe('Bytes');
    expect(ir.procedures['uploads.raw']!.output).toBe('Bytes');
    expect(ir.procedures['uploads.stream']!.output).toBe('ByteStream');
    expect(ir.procedures['uploads.stream']!.input).toBeNull();
  });
});