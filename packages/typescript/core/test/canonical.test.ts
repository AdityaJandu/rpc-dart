import { describe, expect, it } from 'vitest';
import { computeIrHash, stableStringify } from '../src/canonical.js';

describe('canonical serialization', () => {
  it('sorts object keys recursively and emits compact JSON', () => {
    const value = { b: 1, a: { d: ['x', { z: 1, y: 2 }], c: 3 } };
    expect(stableStringify(value)).toBe('{"a":{"c":3,"d":["x",{"y":2,"z":1}]},"b":1}');
  });

  it('is order-insensitive: same logical value, different insertion order, same output', () => {
    const a = { protocol: { transformer: 'superjson' }, types: { 'type-1': { kind: 'unknown' } } };
    const b = { types: { 'type-1': { kind: 'unknown' } }, protocol: { transformer: 'superjson' } };
    expect(stableStringify(a)).toBe(stableStringify(b));
  });

  it('computeIrHash is stable across key order and excludes generator/source/hash', () => {
    const base = {
      irVersion: 1,
      generator: { name: 'rpc-dart', version: '0.1.0' },
      source: { entryFile: 'router.ts' },
      protocol: { kind: 'trpc', version: '11', transformer: 'superjson' },
      tree: { kind: 'router', name: 'appRouter', children: {} },
      procedures: {},
      types: {},
      hash: 'sha256-old',
    };
    const reordered = {
      types: {},
      procedures: {},
      tree: { kind: 'router', name: 'appRouter', children: {} },
      protocol: { transformer: 'superjson', version: '11', kind: 'trpc' },
      source: { entryFile: 'router.ts' },
      generator: { version: '0.1.0', name: 'rpc-dart' },
      irVersion: 1,
      hash: 'sha256-ignored',
    };
    const h1 = computeIrHash(base);
    const h2 = computeIrHash(reordered);
    expect(h1).toBe(h2);
    expect(h1.startsWith('sha256-')).toBe(true);
  });

  it('computeIrHash changes when the contract changes', () => {
    const ir = (procedureInput: unknown) => ({
      protocol: { kind: 'trpc', version: '11', transformer: 'superjson' },
      tree: { kind: 'router', name: 'appRouter', children: {} },
      procedures: { 'user.getById': { path: 'user.getById', input: procedureInput } },
      types: {},
    });
    const a = computeIrHash(ir({ id: 'string' }));
    const b = computeIrHash(ir({ id: 'number' }));
    const c = computeIrHash(ir({ id: 'string' }));
    expect(a).not.toBe(b);
    expect(a).toBe(c);
  });
});
