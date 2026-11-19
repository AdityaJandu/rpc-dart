import { describe, expect, it } from 'vitest';
import { assembleContract } from '../src/assemble.js';
import type { ObjectDef } from '../src/ir.js';

const base = {
  generator: { name: 'rpc-dart', version: '0.0.0-test' },
  protocol: { kind: 'orpc' as const, version: '1', transformer: 'json' as const },
  source: { entryFile: 'router.ts', exportName: 'router', tsconfigFile: 'tsconfig.json', adapterVersion: '0.0.0-test' },
};

const meta = { access: 'public' as const, extra: {} };

describe('assembleContract error passthrough', () => {
  it('interns a provided error def and links it from the procedure record', () => {
    const ir = assembleContract({
      ...base,
      entries: [
        {
          path: 'planet.find',
          kind: 'query',
          input: null,
          output: { kind: 'primitive', name: 'string' },
          error: {
            kind: 'object',
            name: 'PlanetFindError',
            fields: [{ name: 'code', wireName: 'code', type: 'string', optional: false, nullable: false }],
          },
          meta,
        },
      ],
    });
    const record = ir.procedures['planet.find']!;
    expect(record.error).toEqual({ $ref: 'type-1' });
    expect((ir.types['type-1'] as ObjectDef).name).toBe('PlanetFindError');
  });

  it('keeps error null when the entry provides none', () => {
    const ir = assembleContract({
      ...base,
      entries: [{ path: 'ping', kind: 'query', input: null, output: { kind: 'primitive', name: 'string' }, meta }],
    });
    expect(ir.procedures['ping']!.error).toBeNull();
  });
});

describe('assembleContract binary primitives', () => {
  it('collapses Bytes/File/ByteStream outputs to primitive shorthands without registry entries', () => {
    const ir = assembleContract({
      ...base,
      entries: [
        { path: 'a', kind: 'query', input: null, output: { kind: 'primitive', name: 'Bytes' }, meta },
        { path: 'b', kind: 'query', input: null, output: { kind: 'primitive', name: 'File' }, meta },
        { path: 'c', kind: 'query', input: null, output: { kind: 'primitive', name: 'ByteStream' }, meta },
      ],
    });
    expect(ir.procedures['a']!.output).toBe('Bytes');
    expect(ir.procedures['b']!.output).toBe('File');
    expect(ir.procedures['c']!.output).toBe('ByteStream');
    expect(ir.types).toEqual({});
  });
});