import { beforeAll, describe, expect, it } from 'vitest';
import { fileURLToPath } from 'node:url';
import { extractContract } from '@rpc-dart/trpc-adapter';
import type { ContractIR } from '@rpc-dart/core';
import { emit } from '../src/index.js';

const fixtureTsconfig = fileURLToPath(
  new URL('../../../../tests/e2e/src/fixture/subscriptions/tsconfig.json', import.meta.url),
);

let ir: ContractIR;

beforeAll(async () => {
  const result = await extractContract({
    tsconfigPath: fixtureTsconfig,
    entryFile: 'router.ts',
    exportName: 'appRouter',
    protocol: { kind: 'trpc', version: '11', transformer: 'superjson' },
  });
  expect(result.diagnostics).toEqual([]);
  ir = result.ir;
}, 30000);

describe('dart emitter (subscription bindings)', () => {
  it('Test 2.1: no-input subscription emits Stream<T> subscribe({RpcSubscriptionOptions? options})', () => {
    const { files } = emit(ir);
    const src = files['lib/src/api/procedures/streams_on_server_tick.dart'];
    expect(src).toBeDefined();
    expect(src).toContain(
      'Stream<StreamsOnServerTickOutput> subscribe({RpcSubscriptionOptions? options})',
    );
    expect(src).toContain('_client.subscribe<StreamsOnServerTickOutput>(');
    expect(src).toContain(
      'decode: (value) => StreamsOnServerTickOutput.fromJson(RpcJson.asMap(value, path))',
    );
    // Subscriptions stream; they must not surface unary call methods.
    expect(src).not.toContain('mutate(');
    expect(src).not.toContain('query(');
  });

  it('Test 2.2: with-input subscription encodes input and decodes stream items zero-cast', () => {
    const { files } = emit(ir);
    const src = files['lib/src/api/procedures/streams_on_activity.dart'];
    expect(src).toContain(
      'Stream<StreamsOnActivityOutput> subscribe(StreamsOnActivityInput input, {RpcSubscriptionOptions? options})',
    );
    expect(src).toContain('input: input.toJson()');
    expect(src).toContain(
      'decode: (value) => StreamsOnActivityOutput.fromJson(RpcJson.asMap(value, path))',
    );
    expect(src).not.toMatch(/ as /);
  });

  it('primitive stream items decode through RpcJson tearoffs', () => {
    const { files } = emit(ir);
    const src = files['lib/src/api/procedures/counter_on_value.dart'];
    expect(src).toContain('Stream<double> subscribe({RpcSubscriptionOptions? options})');
    expect(src).toContain('decode: RpcJson.asDouble');
    expect(src).not.toMatch(/ as /);
  });

  it('Test 2.3: emission is deterministic for subscription bindings', () => {
    const first = emit(ir).files;
    const second = emit(ir).files;
    expect(second).toEqual(first);
  });
});
