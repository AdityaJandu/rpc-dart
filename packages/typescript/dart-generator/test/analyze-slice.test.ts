import { beforeAll, describe, expect, it } from 'vitest';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { extractContract } from '@rpc-dart/trpc-adapter';
import type { ContractIR } from '@rpc-dart/core';
import { emit } from '../src/index.js';

const fixtureTsconfig = fileURLToPath(
  new URL('../../../../tests/e2e/src/fixture/trpc/tsconfig.json', import.meta.url),
);

const REPO_ROOT = fileURLToPath(new URL('../../../../', import.meta.url));

let ir: ContractIR;
let dartAvailable = false;

beforeAll(async () => {
  const result = await extractContract({
    tsconfigPath: fixtureTsconfig,
    entryFile: 'router.ts',
    exportName: 'appRouter',
    protocol: { kind: 'trpc', version: '11', transformer: 'superjson' },
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
  const dir = mkdtempSync(path.join(tmpdir(), 'rpc-dart-consumer-'));
  const trpcDartPath = path.join(REPO_ROOT, 'packages/dart/trpc_dart');
  const trpcFlutterPath = path.join(REPO_ROOT, 'packages/dart/trpc_flutter');
  writeFileSync(
    path.join(dir, 'pubspec.yaml'),
    [
      'name: slice_consumer',
      'publish_to: none',
      'environment:',
      '  sdk: ">=3.6.0 <4.0.0"',
      'dependencies:',
      '  trpc_dart:',
      `    path: ${trpcDartPath}`,
      '  trpc_flutter:',
      `    path: ${trpcFlutterPath}`,
      '  flutter:',
      '    sdk: flutter',
      'dependency_overrides:',
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
import 'package:trpc_dart/trpc_dart.dart';
import 'package:trpc_flutter/trpc_flutter.dart';
import 'src/api/api.dart';

Future<void> main() async {
  final client = RpcClient(
    endpoint: Uri.parse('https://api.example.com/trpc'),
    transformer: RpcTransformer.superjson,
    links: [HttpBatchLink(endpoint: Uri.parse('https://api.example.com/trpc'))],
  );
  final api = Api(client);

  // One-shot typed call.
  final user = await api.user.getById.query(const UserGetByIdInput(id: 'u1'));
  print(user.id);

  // Result-typed mutation with the three-state field.
  final updated = await api.user.update.safeMutate(
    UserUpdateInput(charCount: 'abcde', nickname: const RpcNull()),
  );
  switch (updated) {
    case RpcSuccess(:final data):
      print(data.nicknameOrNull ?? '-');
    case RpcFailure(:final error):
      print(error);
  }

  // Cache-backed watch + structural keys + invalidation.
  final ref = api.user.getById.watch(const UserGetByIdInput(id: 'u1'));
  ref.stream.listen((state) { print(state.runtimeType); });
  await ref.refetch();
  api.invalidate(api.user.pathKey);
  api.onInvalidate(api.user.getById.pathKey).listen((key) { print(key); });

  // Flutter bridge: ValueListenable over the cache-backed ref.
  final listenable = api.user.getById.listenable(const UserGetByIdInput(id: 'u1'));
  listenable.addListener(() { print(listenable.value.runtimeType); });
}
`,
  );
  return dir;
}

describe('analyzer gate: generated code compiles against the runtime', () => {
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
  }, 120000);
});
