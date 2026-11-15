import dartGenPkg from '../package.json' with { type: 'json' };
import { beforeAll, describe, expect, it } from 'vitest';
import { fileURLToPath } from 'node:url';
import { extractContract } from '@rpc-dart/trpc-adapter';
import type { ContractIR } from '@rpc-dart/core';
import { emit } from '../src/index.js';

const fixtureTsconfig = fileURLToPath(
  new URL('../../../../tests/e2e/src/fixture/trpc/tsconfig.json', import.meta.url),
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

describe('dart emitter (slice goldens)', () => {
  it('emits the expected file set', () => {
    const { files } = emit(ir);
    const expected = [
      'lib/src/api/api.dart',
      'lib/src/api/routers/user_router.dart',
      'lib/src/api/routers/posts_router.dart',
      'lib/src/api/procedures/user_me.dart',
      'lib/src/api/procedures/user_get_by_id.dart',
      'lib/src/api/procedures/user_update.dart',
      'lib/src/api/procedures/posts_list.dart',
      'lib/src/api/models/user_get_by_id_output.dart',
      'lib/src/api/models/user_get_by_id_input.dart',
      'lib/src/api/models/user_update_input.dart',
      'lib/src/api/models/posts_list_input.dart',
      'lib/src/api/models/posts_list_output.dart',
      'lib/src/api/models/posts_list_output_items_item.dart',
      'lib/src/api/models/user_get_by_id_output_address.dart',
      'lib/src/api/models/user_get_by_id_output_payment.dart',
      'lib/src/api/models/posts_list_input_sort.dart',
      'lib/src/api/generated.rpc-dart.json',
    ];
    expect(Object.keys(files).sort()).toEqual(expected.sort());
  });

  it('generated.rpc-dart.json manifest carries hash, protocol, and file list', () => {
    const { files } = emit(ir);
    const manifest = JSON.parse(files['lib/src/api/generated.rpc-dart.json']!);
    expect(manifest.irHash).toBe(ir.hash);
    expect(manifest.generatorVersion).toBe(dartGenPkg.version);
    expect(manifest.protocol).toEqual({ kind: 'trpc', version: '11', transformer: 'superjson' });
    const listed = (manifest.files as Array<{ path: string }>).map((f) => f.path).sort();
    expect(listed).toEqual(
      Object.keys(files)
        .filter((f) => f !== 'lib/src/api/generated.rpc-dart.json')
        .sort(),
    );
  });

  it('models: UserGetByIdOutput golden (RpcOpt field, Date/BigInt, sealed union, record)', () => {
    const { files } = emit(ir);
    const content = files['lib/src/api/models/user_get_by_id_output.dart'];
    expect(content).toBeDefined();
    expect(content).toMatchSnapshot();
  });

  it('models: UpdateUserInput golden (transform wire input, RpcOpt field)', () => {
    const { files } = emit(ir);
    const content = files['lib/src/api/models/user_update_input.dart'];
    expect(content).toBeDefined();
    expect(content).toMatchSnapshot();
  });

  it('models: SortDir enum with unknown sentinel', () => {
    const { files } = emit(ir);
    const content = files['lib/src/api/models/posts_list_input_sort.dart'];
    expect(content).toBeDefined();
    expect(content).toMatchSnapshot();
  });

  it('models: PaymentResult sealed union with unknown variant', () => {
    const { files } = emit(ir);
    const content = files['lib/src/api/models/user_get_by_id_output_payment.dart'];
    expect(content).toBeDefined();
    expect(content).toMatchSnapshot();
  });

  it('procedures: UserGetByIdProc golden (query, safeQuery, watch, keys)', () => {
    const { files } = emit(ir);
    const content = files['lib/src/api/procedures/user_get_by_id.dart'];
    expect(content).toBeDefined();
    expect(content).toMatchSnapshot();
  });

  it('procedures: UserUpdateProc golden (mutation, safeMutate)', () => {
    const { files } = emit(ir);
    const content = files['lib/src/api/procedures/user_update.dart'];
    expect(content).toBeDefined();
    expect(content).toMatchSnapshot();
  });

  it('api.dart golden (routers, cache, invalidate, onInvalidate)', () => {
    const { files } = emit(ir);
    const content = files['lib/src/api/api.dart'];
    expect(content).toBeDefined();
    expect(content).toMatchSnapshot();
  });

  it('is byte-deterministic: two emissions are identical', () => {
    const a = emit(ir);
    const b = emit(ir);
    expect(a.files).toEqual(b.files);
  });
});
