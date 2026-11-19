import { beforeAll, describe, expect, it } from 'vitest';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { extractContract } from '@rpc-dart/orpc-adapter';
import type { ContractIR } from '@rpc-dart/core';
import { emit } from '../src/index.js';

const fixtureTsconfig = fileURLToPath(
  new URL('../../../../tests/e2e/src/fixture/orpc/tsconfig.json', import.meta.url),
);
const REPO_ROOT = fileURLToPath(new URL('../../../../', import.meta.url));

let ir: ContractIR;
let dartAvailable = false;

beforeAll(async () => {
  const result = await extractContract({
    tsconfigPath: fixtureTsconfig,
    entryFile: 'router.ts',
    exportName: 'contractRouter',
  });
  expect(result.diagnostics).toEqual([]);
  ir = result.ir;
  try {
    execFileSync('dart', ['--version'], { stdio: 'pipe' });
    dartAvailable = true;
  } catch {
    dartAvailable = false;
  }
}, 30000);

function createConsumer(): string {
  const dir = mkdtempSync(path.join(tmpdir(), 'rpc-dart-orpc-consumer-'));
  const trpcDartPath = path.join(REPO_ROOT, 'packages/dart/trpc_dart');
  const trpcFlutterPath = path.join(REPO_ROOT, 'packages/dart/trpc_flutter');
  const orpcDartPath = path.join(REPO_ROOT, 'packages/dart/orpc_dart');
  writeFileSync(
    path.join(dir, 'pubspec.yaml'),
    [
      'name: orpc_consumer',
      'publish_to: none',
      'environment:',
      '  sdk: ">=3.6.0 <4.0.0"',
      'dependencies:',
      '  orpc_dart:',
      `    path: ${orpcDartPath}`,
      '  trpc_dart:',
      `    path: ${trpcDartPath}`,
      '  trpc_flutter:',
      `    path: ${trpcFlutterPath}`,
      '  flutter:',
      '    sdk: flutter',
      'dependency_overrides:',
      '  orpc_dart:',
      `    path: ${orpcDartPath}`,
      '  trpc_dart:',
      `    path: ${trpcDartPath}`,
      '',
    ].join('\n'),
  );
  mkdirSync(path.join(dir, 'lib', 'src', 'api'), { recursive: true });
  const { files } = emit(ir);
  for (const [rel, content] of Object.entries(files)) {
    const target = path.join(dir, rel);
    mkdirSync(path.dirname(target), { recursive: true });
    writeFileSync(target, content);
  }
  writeFileSync(
    path.join(dir, 'lib', 'main.dart'),
    `
import 'package:orpc_dart/orpc_dart.dart';
import 'src/api/api.dart';

Future<void> main() async {
  final endpoint = Uri.parse('https://api.example.com/rpc');
  final client = RpcClient(
    endpoint: endpoint,
    links: [
      ContextLink(),
      RetryLink(),
      LoggingLink(onEvent: (event) { print(event.event); }),
      OrpcLink(endpoint: endpoint),
    ],
  );
  final api = Api(client);

  // Typed query with progress hooks.
  final planet = await api.planet.find.query(
    const PlanetFindInput(id: 1),
    onReceiveProgress: (progress) { print(progress.fraction); },
  );
  print(planet.discoveredAt);

  // Multipart upload with send progress.
  final uploaded = await api.uploads.avatar.mutate(
    UploadsAvatarInput(
      file: RpcFile.bytes('a.png', Uint8List.fromList([1, 2]), contentType: 'image/png'),
      thumb: RpcFile.bytes('t.png', Uint8List.fromList([3])),
    ),
    onSendProgress: (progress) { print(progress.transferredBytes); },
  );
  print(uploaded.url);

  // Root binary input/output.
  final echoed = await api.uploads.raw.mutate(Uint8List.fromList([9]));
  print(echoed.length);

  // Streaming download.
  await for (final chunk in api.uploads.stream.query()) {
    print(chunk.length);
  }

  // Event iterator subscription (input shape dedups against PlanetFindInput).
  final sub = api.planet.watch
      .subscribe(const PlanetFindInput(id: 1))
      .listen((event) { print(event.tick); });
  await sub.cancel();

  // Typed error models from .errors() maps, decoded from a live RpcException.
  try {
    await api.planet.find.query(const PlanetFindInput(id: 999));
  } on RpcException catch (e) {
    final error = PlanetFindError.fromException(e);
    switch (error) {
      case PlanetFindErrorNOTFOUND(:final data):
        print(data?.id);
      case PlanetFindErrorBADREQUEST(:final data):
        print(data);
      case null:
        print(e.code);
      default:
        print(error);
    }
  }

  // Result-typed call.
  final result = await api.planet.create.safeMutate(const PlanetCreateInput(name: 'X'));
  switch (result) {
    case RpcSuccess(:final data):
      print(data.name);
    case RpcFailure(:final error):
      print(error.code);
  }
}
`,
  );
  writeFileSync(
    path.join(dir, 'lib', 'bridge_check.dart'),
    `
import 'package:orpc_dart/orpc_dart.dart';
import 'src/api/api.dart';

void main() {
  final objectData = RpcException.fromOrpcWire(<String, Object?>{
    'defined': true, 'code': 'NOT_FOUND', 'status': 404, 'message': 'no planet',
    'data': <String, Object?>{'id': 9},
  });
  final d1 = PlanetFindError.fromException(objectData);
  if (d1 is! PlanetFindErrorNOTFOUND) throw StateError('expected NOT_FOUND');
  if (d1.data?.id != 9) throw StateError('expected id 9');

  final scalarData = RpcException.fromOrpcWire(<String, Object?>{
    'defined': true, 'code': 'BAD_REQUEST', 'status': 400, 'message': 'bad id',
    'data': 'oops',
  });
  final d2 = PlanetFindError.fromException(scalarData);
  if (d2 is! PlanetFindErrorBADREQUEST) throw StateError('expected BAD_REQUEST');
  if (d2.data != 'oops') throw StateError('expected scalar oops');

  final missingData = RpcException.fromOrpcWire(<String, Object?>{
    'defined': true, 'code': 'RATE_LIMITED', 'status': 429, 'message': 'slow down',
  });
  final d3 = PlanetCreateError.fromException(missingData);
  if (d3 is! PlanetCreateErrorRATELIMITED) throw StateError('expected RATE_LIMITED');

  if (PlanetFindError.fromException(RpcException('network', code: 'NETWORK')) != null) {
    throw StateError('expected null for non-defined error');
  }

  final unknown = RpcException.fromOrpcWire(<String, Object?>{
    'defined': true, 'code': 'WEIRD', 'status': 500, 'message': 'huh',
  });
  if (PlanetFindError.fromException(unknown) is! PlanetFindErrorUnknown) {
    throw StateError('expected Unknown variant');
  }

  print('BRIDGE_OK');
}
`,
  );
  return dir;
}

describe('analyzer gate: generated oRPC bindings compile against the runtime', () => {
  it('dart analyze --fatal-infos --fatal-warnings reports zero issues', () => {
    if (!dartAvailable) {
      console.warn('dart SDK not on PATH - skipping analyzer gate');
      return;
    }
    const dir = createConsumer();
    try {
      execFileSync('flutter', ['pub', 'get'], { cwd: dir, stdio: 'pipe' });
      const output = execFileSync(
        'dart',
        ['analyze', '--fatal-infos', '--fatal-warnings', '.'],
        { cwd: dir, stdio: 'pipe', encoding: 'utf-8' },
      );
      expect(output).not.toMatch(/error -/);
      expect(output).not.toMatch(/warning -/);
    } catch (error) {
      const err = error as { stdout?: string; stderr?: string; message?: string };
      const detail = `${err.stdout ?? ''}\n${err.stderr ?? ''}\n${err.message ?? ''}`;
      const generatedMain = readFileSync(path.join(dir, 'lib/main.dart'), 'utf-8').slice(0, 200);
      throw new Error(`analyzer gate failed:\n${detail}\n--- main.dart head:\n${generatedMain}`);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 180000);

  it('fromException decodes object, scalar, missing, and unknown data at runtime', () => {
    if (!dartAvailable) {
      console.warn('dart SDK not on PATH - skipping bridge runtime gate');
      return;
    }
    const dir = createConsumer();
    try {
      execFileSync('flutter', ['pub', 'get'], { cwd: dir, stdio: 'pipe' });
      const output = execFileSync('dart', ['run', 'lib/bridge_check.dart'], {
        cwd: dir,
        stdio: 'pipe',
        encoding: 'utf-8',
      });
      expect(output).toContain('BRIDGE_OK');
    } catch (error) {
      const err = error as { stdout?: string; stderr?: string; message?: string };
      throw new Error(`bridge runtime gate failed:\n${err.stdout ?? ''}\n${err.stderr ?? ''}\n${err.message ?? ''}`);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 180000);
});