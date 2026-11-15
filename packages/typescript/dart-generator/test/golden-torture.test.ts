import { beforeAll, describe, expect, it } from 'vitest';
import { fileURLToPath } from 'node:url';
import { extractContract } from '@rpc-dart/trpc-adapter';
import type { ContractIR } from '@rpc-dart/core';
import { emit } from '../src/index.js';

const tortureTsconfig = fileURLToPath(
  new URL('../../../../tests/e2e/src/fixture/torture/tsconfig.json', import.meta.url),
);

let ir: ContractIR;

beforeAll(async () => {
  const result = await extractContract({
    tsconfigPath: tortureTsconfig,
    entryFile: 'router.ts',
    exportName: 'appRouter',
    protocol: { kind: 'trpc', version: '11', transformer: 'superjson' },
  });
  expect(result.diagnostics).toEqual([]);
  ir = result.ir;
}, 30000);

describe('dart emitter (torture goldens)', () => {
  it('emits files for every torture model without crashing', () => {
    const { files } = emit(ir);
    expect(Object.keys(files).length).toBeGreaterThan(4);
    expect(files['lib/src/api/models/widgets_round_trip_input_category.dart']).toBeDefined();
    expect(files['lib/src/api/models/widgets_round_trip_input_version.dart']).toBeDefined();
    expect(files['lib/src/api/models/widgets_round_trip_input.dart']).toBeDefined();
  });

  it('numeric literal union emits an enum with numeric raw values', () => {
    const { files } = emit(ir);
    const content = files['lib/src/api/models/widgets_round_trip_input_version.dart'];
    expect(content).toBeDefined();
    expect(content).toContain('final num raw;');
    expect(content).toContain('static WidgetsRoundTripInputVersion fromJson(num raw)');
    expect(content).toContain('value_1(1),');
  });

  it('tuple fields emit Dart positional records with decode helpers', () => {
    const { files } = emit(ir);
    const content = files['lib/src/api/models/widgets_round_trip_input.dart'];
    expect(content).toBeDefined();
    expect(content).toContain('final (String, double) origin;');
    expect(content).toContain('RpcJson.tupleItems');
    expect(content).toContain("RpcJson.asString.call(parts[0], '$path[0]')");
  });

  it('recursive models self-reference in the same file', () => {
    const { files } = emit(ir);
    const content = files['lib/src/api/models/widgets_round_trip_input_category.dart'];
    expect(content).toContain('final List<WidgetsRoundTripInputCategory> children;');
  });

  it('set and map fields decode/encode via annotations', () => {
    const { files } = emit(ir);
    const content = files['lib/src/api/models/widgets_round_trip_input.dart'];
    expect(content).toContain('Set<String> uniqueTags');
    expect(content).toContain('RpcJson.asSet');
    expect(content).toContain('Map<String, double> attributes');
    expect(content).toContain('uniqueTags.toList()');
  });

  it('is byte-deterministic', () => {
    expect(emit(ir).files).toEqual(emit(ir).files);
  });
});
