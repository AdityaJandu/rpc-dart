import { beforeAll, describe, expect, it } from 'vitest';
import { fileURLToPath } from 'node:url';
import { extractContract as extractOrpc } from '@rpc-dart/orpc-adapter';
import { extractContract as extractTrpc } from '@rpc-dart/trpc-adapter';
import type { ContractIR } from '@rpc-dart/core';
import { emit } from '../src/index.js';

const orpcTsconfig = fileURLToPath(
  new URL('../../../../tests/e2e/src/fixture/orpc/tsconfig.json', import.meta.url),
);
const binaryTsconfig = fileURLToPath(
  new URL('../../../../tests/e2e/src/fixture/binary/tsconfig.json', import.meta.url),
);

let orpcIr: ContractIR;
let trpcBinaryIr: ContractIR;

beforeAll(async () => {
  const orpc = await extractOrpc({
    tsconfigPath: orpcTsconfig,
    entryFile: 'router.ts',
    exportName: 'contractRouter',
  });
  expect(orpc.diagnostics).toEqual([]);
  orpcIr = orpc.ir;
  const trpc = await extractTrpc({
    tsconfigPath: binaryTsconfig,
    entryFile: 'router.ts',
    exportName: 'appRouter',
    protocol: { kind: 'trpc', version: '11', transformer: 'superjson' },
  });
  expect(trpc.diagnostics).toEqual([]);
  trpcBinaryIr = trpc.ir;
}, 60000);

const ZERO_CAST = /(?:\s|\()as\s+[A-Za-z_]/;

describe('binary emission (oRPC)', () => {
  it('emits root Bytes inputs and outputs without casts', () => {
    const { files } = emit(orpcIr);
    const proc = files['lib/src/api/procedures/uploads_raw.dart']!;
    expect(proc).toContain('Future<Uint8List> mutate(Uint8List input');
    expect(proc).toContain('input: input,');
    expect(proc).toContain('RpcJson.asBytes(data, path)');
    expect(proc).not.toMatch(ZERO_CAST);
  });

  it('emits ByteStream outputs as streaming methods', () => {
    const { files } = emit(orpcIr);
    const proc = files['lib/src/api/procedures/uploads_stream.dart']!;
    expect(proc).toContain('RpcByteStream query(');
    expect(proc).toContain('RpcJson.asByteStream(data, path)');
    expect(proc).not.toContain('Future<RpcByteStream>');
    expect(proc).not.toMatch(ZERO_CAST);
  });

  it('emits RpcFile model fields with zero-cast decoders', () => {
    const { files } = emit(orpcIr);
    const model = files['lib/src/api/models/uploads_avatar_input.dart']!;
    expect(model).toContain('final RpcFile file;');
    expect(model).toContain('final RpcFile thumb;');
    expect(model).toContain('RpcJson.asFile');
    expect(model).toContain('"file": file,');
    expect(model).not.toMatch(ZERO_CAST);
  });

  it('emits typed error models from .errors() maps', () => {
    const { files } = emit(orpcIr);
    const errorModel = Object.entries(files).find(
      ([p, c]) => p.startsWith('lib/src/api/models/') && c.includes('sealed class PlanetFindError'),
    );
    expect(errorModel).toBeDefined();
    const content = errorModel![1];
    expect(content).toContain('PlanetFindErrorNOTFOUND');
    expect(content).toContain('switch (json["code"])');
    // The {id: number} error data structurally dedups against the find input.
    expect(content).toContain("import 'planet_find_input.dart';");
    expect(files['lib/src/api/models/planet_find_input.dart']).toContain('final double id;');
  });

  it('adds optional progress callbacks to unary methods', () => {
    const { files } = emit(orpcIr);
    const proc = files['lib/src/api/procedures/planet_find.dart']!;
    expect(proc).toContain('RpcProgressCallback? onSendProgress');
    expect(proc).toContain('RpcProgressCallback? onReceiveProgress');
    expect(proc).toContain('withProgress(');
  });

  it('documents protocol-aware client construction', () => {
    const { files } = emit(orpcIr);
    expect(files['lib/src/api/api.dart']).toContain('OrpcLink');
    const trpcFiles = emit(trpcBinaryIr).files;
    expect(trpcFiles['lib/src/api/api.dart']).toContain('HttpBatchLink');
  });

  it('keeps every emitted file zero-cast', () => {
    for (const content of Object.values(emit(orpcIr).files)) {
      expect(content).not.toMatch(ZERO_CAST);
    }
  });
});

describe('binary emission (tRPC superjson convention)', () => {
  it('emits File and Bytes unary outputs with checked decoders', () => {
    const { files } = emit(trpcBinaryIr);
    const file = files['lib/src/api/procedures/files_from_file.dart']!;
    expect(file).toContain('Future<RpcFile> query(');
    expect(file).toContain('RpcJson.asFile(data, path)');
    const bytes = files['lib/src/api/procedures/bytes_from_uint8_array.dart']!;
    expect(bytes).toContain('Future<Uint8List> query(');
    expect(bytes).toContain('RpcJson.asBytes(data, path)');
  });

  it('emits binary input model fields', () => {
    const { files } = emit(trpcBinaryIr);
    const model = files['lib/src/api/models/files_upload_input.dart']!;
    expect(model).toContain('final RpcFile avatar;');
    expect(model).toContain('final Uint8List payload;');
    expect(model).toContain('RpcJson.asBytes');
    expect(model).not.toMatch(ZERO_CAST);
  });

  it('uses deep equality for byte fields', () => {
    const { files } = emit(trpcBinaryIr);
    const model = files['lib/src/api/models/files_upload_input.dart']!;
    expect(model).toContain('rpcDeepEquals(payload, other.payload)');
  });
});