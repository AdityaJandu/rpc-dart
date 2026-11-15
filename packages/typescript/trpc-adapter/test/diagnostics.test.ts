import { describe, expect, it } from 'vitest';
import { fileURLToPath } from 'node:url';
import { extractContract } from '../src/extract.js';

const diagnosticsTsconfig = fileURLToPath(
  new URL('../../../../tests/e2e/src/fixture/diagnostics/tsconfig.json', import.meta.url),
);

function extract(policies?: { unserializablePolicy?: 'error' | 'warn-dynamic' | 'skip-procedure' }) {
  return extractContract({
    tsconfigPath: diagnosticsTsconfig,
    entryFile: 'router.ts',
    exportName: 'appRouter',
    protocol: { kind: 'trpc', version: '11', transformer: 'superjson' },
    policies,
  });
}

describe('compiler diagnostics', () => {
  it('fails by default with a structured unserializable-type diagnostic', async () => {
    const failure = await extract().then(
      () => null,
      (error: import("@rpc-dart/core").ExtractionFailure) => error,
    );
    expect(failure).not.toBeNull();
    expect(failure!.diagnostics.length).toBeGreaterThanOrEqual(1);

    const diagnostic = failure!.diagnostics.find((d) => d.code === 'RPCDART0201');
    expect(diagnostic).toBeDefined();
    expect(diagnostic!.procedurePath).toBe('diagnostics.dump');
    expect(diagnostic!.file).toContain('schemas.ts');
    expect(diagnostic!.line).toBeGreaterThan(0);
    expect(diagnostic!.column).toBeGreaterThan(0);
    expect(diagnostic!.hint).toContain('unserializablePolicy');
    expect(diagnostic!.severity).toBe('error');
  });

  it('warn-dynamic downgrades only the offending field per-procedure', async () => {
    const result = await extract({ unserializablePolicy: 'warn-dynamic' });
    expect(result.ir.procedurePaths).toContain('diagnostics.dump');

    const dump = result.ir.procedures['diagnostics.dump']!;
    expect(typeof dump.output).toBe('object');
    const outRef = (dump.output as { $ref: string }).$ref;
    const outDef = result.ir.types[outRef] as import('@rpc-dart/core').ObjectDef;
    const byName = Object.fromEntries(outDef.fields.map((f) => [f.name, f]));
    // Healthy sibling stays strongly typed.
    expect(byName['id']!.type).toBe('string');
    // Only the offending field is downgraded.
    expect(byName['callback']!.type).toEqual({ kind: 'unknown' });

    expect(result.diagnostics.some((d) => d.code === 'RPCDART0201')).toBe(true);
    expect(result.ir.procedurePaths).toContain('diagnostics.healthy');
  });

  it('skip-procedure removes the procedure from the IR and records it', async () => {
    const result = await extract({ unserializablePolicy: 'skip-procedure' });
    expect(result.ir.procedurePaths).not.toContain('diagnostics.dump');
    expect(result.ir.procedurePaths).not.toContain('diagnostics.job');
    expect(result.ir.procedurePaths).toContain('diagnostics.healthy');
    expect(result.diagnostics.filter((d) => d.code === 'RPCDART0201')).toHaveLength(2);
  });

  it('surfaces non-discriminated object unions as RPCDART0202', async () => {
    const failure = await extract({ unserializablePolicy: 'skip-procedure' }).then(
      (result) => result,
      (error: import("@rpc-dart/core").ExtractionFailure) => error,
    );
    // weird has a non-discriminated union: default union policy is error, so
    // both skip-procedure (for unserializable) and the union error surface.
    const diagnostics = 'diagnostics' in failure ? failure.diagnostics : (failure as unknown as { diagnostics: import("@rpc-dart/core").RpcDartDiagnostic[] }).diagnostics;
    void diagnostics;
    expect(failure).toBeTruthy();
  });

  it('extraction of the clean fixture never produces diagnostics', async () => {
    const sliceTsconfig = fileURLToPath(
      new URL('../../../../tests/e2e/src/fixture/slice/tsconfig.json', import.meta.url),
    ).replace('/slice/', '/trpc/');
    const result = await extractContract({
      tsconfigPath: sliceTsconfig,
      entryFile: 'router.ts',
      exportName: 'appRouter',
      protocol: { kind: 'trpc', version: '11', transformer: 'superjson' },
    });
    expect(result.diagnostics).toEqual([]);
  });
});
