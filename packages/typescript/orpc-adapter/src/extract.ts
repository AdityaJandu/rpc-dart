import { readFileSync } from 'node:fs';
import path from 'node:path';
import * as ts from 'typescript';
import {
  assembleContract,
  type AssembleEntry,
  type ContractIR,
  type FieldDef,
  type ProcedureMeta,
  type RpcDartDiagnostic,
  type TypeDef,
  type TypeRef,
  ExtractionFailure,
  TypeClassificationError,
  TypeClassifier,
  entryImportPath,
  harnessFileName,
  neutralizeOptions,
  overlayHost,
  pascal,
  pathAlias,
  resolutionKind,
  typeFromAlias,
} from '@rpc-dart/core';
import { buildHarness, errorCodeAlias } from './harness.js';
import { probeRouter, type ProbePath } from './probe.js';

export interface ExtractPolicies {
  /** Default: 'error'. 'warn-dynamic' emits unknown + records; 'skip-procedure' drops the procedure. */
  unserializablePolicy?: 'error' | 'warn-dynamic' | 'skip-procedure';
}

export interface ExtractOptions {
  tsconfigPath: string;
  entryFile: string;
  exportName: string;
  protocol?: { kind: 'orpc'; version: string; transformer: 'json' };
  policies?: ExtractPolicies;
}

export interface ExtractResult {
  ir: ContractIR;
  diagnostics: RpcDartDiagnostic[];
}

const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf-8')) as { version: string };
const GENERATOR = { name: 'rpc-dart', version: pkg.version };

export async function extractContract(options: ExtractOptions): Promise<ExtractResult> {
  const tsconfigDir = path.dirname(options.tsconfigPath);
  const entryAbsolute = path.resolve(tsconfigDir, options.entryFile);
  const diagnostics: RpcDartDiagnostic[] = [];

  // 1. Runtime probe: kinds, routes, error codes, sorted paths.
  let probePaths: ProbePath[];
  try {
    probePaths = await probeRouter(entryAbsolute, options.exportName);
  } catch (error) {
    diagnostics.push({
      code: 'RPCDART0102',
      severity: 'error',
      message: (error as Error).message,
      hint: 'export an oRPC contract (oc) or router (os / implement) as a const',
    });
    throw new ExtractionFailure(diagnostics);
  }

  // 2. Program options from the user's own tsconfig.
  const configFile = ts.readConfigFile(options.tsconfigPath, ts.sys.readFile);
  if (configFile.error) {
    diagnostics.push({
      code: 'RPCDART0103',
      severity: 'error',
      message: `tsconfig failed to parse: ${ts.flattenDiagnosticMessageText(configFile.error.messageText, ' ')}`,
      file: options.tsconfigPath,
      hint: 'make sure tsconfig.json is valid JSON with the compiler options your project needs',
    });
    throw new ExtractionFailure(diagnostics);
  }
  const parsed = ts.parseJsonConfigFileContent(configFile.config, ts.sys, tsconfigDir);

  // 3. Virtual harness over oRPC's public inference helpers.
  const resolution = resolutionKind(ts, parsed.options.moduleResolution);
  const mode = probePaths.every((p) => p.contract) ? ('contract' as const) : ('router' as const);
  const errorSpecs = probePaths
    .filter((p) => p.errorCodes.length > 0)
    .map((p) => ({ path: p.path, codes: p.errorCodes }));
  const harnessPath = path.join(tsconfigDir, harnessFileName());
  const harnessSource = buildHarness(
    entryImportPath(tsconfigDir, entryAbsolute, resolution),
    options.exportName,
    probePaths.map((p) => p.path),
    mode,
    errorSpecs,
  );

  // 4. Program under the user's own tsconfig, harness overlaid in memory.
  const extractionOptions = neutralizeOptions(parsed.options);
  const baseHost = ts.createCompilerHost(extractionOptions, true);
  const host = overlayHost(ts, baseHost, harnessPath, harnessSource);
  const program = ts.createProgram({
    rootNames: [harnessPath, ...parsed.fileNames],
    options: extractionOptions,
    host,
  });

  const harnessSf = program.getSourceFile(harnessPath);
  if (!harnessSf) {
    throw new ExtractionFailure([{ code: 'RPCDART0105', severity: 'error', message: 'harness missing from program' }]);
  }
  const programDiagnostics = [...program.getSyntacticDiagnostics(), ...program.getSemanticDiagnostics()];
  if (programDiagnostics.length > 0) {
    for (const d of programDiagnostics.slice(0, 10)) {
      const pos = d.file && d.start !== undefined ? d.file.getLineAndCharacterOfPosition(d.start) : null;
      diagnostics.push({
        code: 'RPCDART0105',
        severity: 'error',
        message: ts.flattenDiagnosticMessageText(d.messageText, ' '),
        file: d.file?.fileName,
        line: pos ? pos.line + 1 : undefined,
        column: pos ? pos.character + 1 : undefined,
        hint: 'fix the TypeScript error; error types silently corrupt generated bindings',
      });
    }
    throw new ExtractionFailure(diagnostics);
  }

  // 5. Resolve per-procedure input/output/error-data through harness aliases.
  const checker = program.getTypeChecker();
  const unserializablePolicy = options.policies?.unserializablePolicy ?? 'error';
  const classifier = new TypeClassifier(
    ts,
    checker,
    unserializablePolicy === 'warn-dynamic' ? 'warn-dynamic' : 'error',
  );

  const entries: AssembleEntry[] = [];
  for (const p of probePaths) {
    classifier.currentProcedure = p.path;
    // Handler-inferred async generators carry no runtime eventIterator
    // marker, so streaming is decided at the type level.
    const streamType = typeFromAlias(ts, harnessSf, checker, pathAlias(p.path, 'isstream'));
    const isStream = streamType !== undefined && checker.typeToString(streamType) === 'true';
    const kind = isStream ? ('subscription' as const) : p.kind === 'subscription' ? ('mutation' as const) : p.kind;
    const inputType = typeFromAlias(ts, harnessSf, checker, pathAlias(p.path, 'in'));
    const outputType = typeFromAlias(ts, harnessSf, checker, pathAlias(p.path, 'out'));
    if (outputType === undefined) {
      diagnostics.push({
        code: 'RPCDART0106',
        severity: 'error',
        message: `no output type resolved for procedure "${p.path}"`,
        procedurePath: p.path,
        hint: 'make sure the procedure returns a value',
      });
      throw new ExtractionFailure(diagnostics);
    }

    let input: TypeDef | null;
    let output: TypeDef;
    let error: TypeDef | null = null;
    try {
      if (p.inputIsEventIterator) {
        throw new TypeClassificationError({
          code: 'RPCDART0201',
          severity: 'error',
          message: `event iterator inputs are not supported at ${p.path}`,
          procedurePath: p.path,
          hint: 'stream from server to client only; move client payloads into the unary input',
        });
      }
      input =
        inputType === undefined || isVoidish(inputType) || isUnknownish(inputType)
          ? null
          : (classifier.classify(inputType, `${pascal(p.path)}Input`) as TypeDef);
      output = classifier.classify(outputType, `${pascal(p.path)}Output`) as TypeDef;
      error = buildErrorDef(p, harnessSf, checker, classifier);
      diagnostics.push(...classifier.collectedDiagnostics);
    } catch (error_) {
      if (!(error_ instanceof TypeClassificationError)) {
        throw error_;
      }
      const diagnostic = error_.diagnostic;
      diagnostics.push(diagnostic);
      if (unserializablePolicy === 'skip-procedure') {
        diagnostic.severity = 'warning';
        continue;
      }
      if (unserializablePolicy === 'warn-dynamic') {
        diagnostic.severity = 'warning';
        input = null;
        output = { kind: 'unknown' };
      } else {
        throw new ExtractionFailure(diagnostics);
      }
    }

    const meta: ProcedureMeta = {
      access: p.meta['access'] === 'authenticated' ? 'authenticated' : 'public',
      extra: {},
    };
    if (p.route.method !== undefined || p.route.path !== undefined) {
      meta.extra['route'] = { ...p.route };
    }
    if (isStream) {
      // RPCHandler always forwards last-event-id; whether the handler replays
      // is server-side, so resume is always offered to the client.
      meta.extra['supportsLastEventId'] = true;
    }
    entries.push({ path: p.path, kind, input, output, error, meta, docs: null });
  }
  classifier.currentProcedure = undefined;

  // 6. Assemble, dedup, name, hash.
  const ir = assembleContract({
    generator: { ...GENERATOR },
    protocol: options.protocol ?? { kind: 'orpc', version: '1', transformer: 'json' },
    source: {
      entryFile: options.entryFile,
      exportName: options.exportName,
      tsconfigFile: options.tsconfigPath,
      adapterVersion: pkg.version,
    },
    entries,
  });

  return { ir, diagnostics };
}

function isVoidish(type: ts.Type): boolean {
  return (type.flags & (ts.TypeFlags.Void | ts.TypeFlags.Undefined | ts.TypeFlags.Never)) !== 0;
}

function isUnknownish(type: ts.Type): boolean {
  return (type.flags & (ts.TypeFlags.Any | ts.TypeFlags.Unknown)) !== 0;
}

function buildErrorDef(
  p: ProbePath,
  harnessSf: ts.SourceFile,
  checker: ts.TypeChecker,
  classifier: TypeClassifier,
): TypeDef | null {
  if (p.errorCodes.length === 0) return null;
  const name = `${pascal(p.path)}Error`;
  const variants = [...p.errorCodes].sort().map((code) => {
    const fields: FieldDef[] = [
      { name: 'code', wireName: 'code', type: { kind: 'literal', value: code }, optional: false, nullable: false },
      { name: 'message', wireName: 'message', type: 'string', optional: false, nullable: false },
      { name: 'defined', wireName: 'defined', type: { kind: 'literal', value: true }, optional: false, nullable: false },
    ];
    const dataType = typeFromAlias(ts, harnessSf, checker, errorCodeAlias(p.path, code));
    if (dataType !== undefined && !isVoidish(dataType)) {
      const data = classifier.classify(dataType, `${name}${pascal(code)}Data`) as TypeRef;
      // Optional so a wire error that omits data (or a non-defined error)
      // decodes to null instead of throwing.
      fields.push({ name: 'data', wireName: 'data', type: data, optional: true, nullable: false });
    }
    const object: TypeDef = { kind: 'object', name: `${name}${pascal(code)}`, fields };
    return { tag: code, object };
  });
  return { kind: 'discriminatedUnion', name, tagField: 'code', variants };
}