import path from 'node:path';
import * as ts from 'typescript';
import {
  assembleContract,
  type AssembleEntry,
  type ContractIR,
  type ProcedureMeta,
  type RpcDartDiagnostic,
  type TypeDef,
  ExtractionFailure,
} from '@rpc-dart/core';
import { entryImportPath, buildHarness, harnessFileName, pathAlias } from './harness.js';
import { probeRouter } from './probe.js';
import { pascal, TypeClassificationError, TypeClassifier } from './classify.js';

export interface ExtractPolicies {
  /** Default: 'error'. 'warn-dynamic' emits unknown + records; 'skip-procedure' drops the procedure. */
  unserializablePolicy?: 'error' | 'warn-dynamic' | 'skip-procedure';
}

export interface ExtractOptions {
  tsconfigPath: string;
  entryFile: string;
  exportName: string;
  protocol: { kind: 'trpc' | 'orpc'; version: string; transformer: 'superjson' | 'json' };
  policies?: ExtractPolicies;
}

export interface ExtractResult {
  ir: ContractIR;
  diagnostics: RpcDartDiagnostic[];
}

const GENERATOR = { name: 'rpc-dart', version: '0.2.0' } as const;

export async function extractContract(options: ExtractOptions): Promise<ExtractResult> {
  const tsconfigDir = path.dirname(options.tsconfigPath);
  const entryAbsolute = path.resolve(tsconfigDir, options.entryFile);
  const diagnostics: RpcDartDiagnostic[] = [];

  // 1. Runtime probe: kinds + meta, sorted paths.
  let probePaths;
  try {
    probePaths = await probeRouter(entryAbsolute, options.exportName);
  } catch (error) {
    diagnostics.push({
      code: 'RPCDART0102',
      severity: 'error',
      message: (error as Error).message,
      hint: 'export the router as a const and make sure the module evaluates cleanly',
    });
    throw new ExtractionFailure(diagnostics);
  }

  // 2. Program options from the user's own tsconfig (parsed before the harness
  //    is built so Node16/NodeNext resolution can shape the entry specifier).
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

  // 3. Virtual harness over the public inference utilities, one alias pair per path.
  const resolution =
    parsed.options.moduleResolution === ts.ModuleResolutionKind.Node16
      ? ('node16' as const)
      : parsed.options.moduleResolution === ts.ModuleResolutionKind.NodeNext
        ? ('nodenext' as const)
        : undefined;
  const subscriptionPaths = new Set(
    probePaths.filter((p) => p.kind === 'subscription').map((p) => p.path),
  );
  const harnessPath = path.join(tsconfigDir, harnessFileName());
  const harnessSource = buildHarness(
    entryImportPath(tsconfigDir, entryAbsolute, resolution),
    options.exportName,
    probePaths.map((p) => p.path),
    subscriptionPaths,
  );

  // 4. Program under the user's own tsconfig, harness overlaid in memory.
  //    Extraction-neutral overrides: the in-memory program exists only to
  //    answer type queries on the harness, so build/lint-only flags are
  //    neutralized regardless of the user's tsconfig — they would otherwise
  //    reject the synthetic harness (rootDir, composite emit rules) or surface
  //    lint-only semantic errors (noUnusedLocals/noUnusedParameters,
  //    isolatedDeclarations) that have nothing to do with contract extraction.
  const extractionOptions: ts.CompilerOptions = {
    ...parsed.options,
    noEmit: true,
    declaration: false,
    declarationMap: false,
    composite: false,
    incremental: false,
    isolatedDeclarations: false,
    noUnusedLocals: false,
    noUnusedParameters: false,
    rootDir: undefined,
  };
  const baseHost = ts.createCompilerHost(extractionOptions, true);
  const host = overlayHost(baseHost, harnessPath, harnessSource);
  const program = ts.createProgram({
    rootNames: [harnessPath, ...parsed.fileNames],
    options: extractionOptions,
    host,
  });

  const harnessSf = program.getSourceFile(harnessPath);
  if (!harnessSf) throw new ExtractionFailure([{
    code: 'RPCDART0105',
    severity: 'error',
    message: 'harness missing from program',
  }]);
  const programDiagnostics = [
    ...program.getSyntacticDiagnostics(),
    ...program.getSemanticDiagnostics(),
  ];
  if (programDiagnostics.length > 0) {
    for (const d of programDiagnostics.slice(0, 10)) {
      const file = d.file ? path.basename(d.file.fileName) : undefined;
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
      void file;
    }
    throw new ExtractionFailure(diagnostics);
  }

  // 4. Resolve per-procedure input/output through per-path harness aliases.
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
    const inputType = typeFromAlias(harnessSf, checker, pathAlias(p.path, 'in'));
    const outputType = typeFromAlias(harnessSf, checker, pathAlias(p.path, 'out'));
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
    try {
      input =
        inputType === undefined || isVoidish(inputType)
          ? null
          : (classifier.classify(inputType, `${pascal(p.path)}Input`) as TypeDef);
      output = classifier.classify(outputType, `${pascal(p.path)}Output`) as TypeDef;
      diagnostics.push(...classifier.collectedDiagnostics);
    } catch (error) {
      if (!(error instanceof TypeClassificationError)) {
        throw error;
      }
      const diagnostic = error.diagnostic;
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
    if (p.kind === 'subscription') {
      // `tracked()` yields resolve to a true literal via the harness; without
      // tracked events the client cannot resume, so the flag stays false.
      const trackedType = typeFromAlias(harnessSf, checker, pathAlias(p.path, 'tracked'));
      meta.extra['supportsLastEventId'] =
        trackedType !== undefined && checker.typeToString(trackedType) === 'true';
    }
    entries.push({ path: p.path, kind: p.kind, input, output, meta, docs: null });
  }
  classifier.currentProcedure = undefined;

  // 5. Assemble, dedup, name, hash.
  const ir = assembleContract({
    generator: { ...GENERATOR },
    protocol: options.protocol,
    source: {
      entryFile: options.entryFile,
      exportName: options.exportName,
      tsconfigFile: options.tsconfigPath,
      adapterVersion: '0.1.0',
    },
    entries,
  });

  return { ir, diagnostics };
}

function isVoidish(type: ts.Type): boolean {
  return (
    (type.flags & (ts.TypeFlags.Void | ts.TypeFlags.Undefined | ts.TypeFlags.Never)) !== 0
  );
}

function typeFromAlias(
  sourceFile: ts.SourceFile,
  checker: ts.TypeChecker,
  name: string,
): ts.Type | undefined {
  for (const statement of sourceFile.statements) {
    if (ts.isTypeAliasDeclaration(statement) && statement.name.text === name) {
      return checker.getTypeFromTypeNode(statement.type);
    }
  }
  return undefined;
}

function overlayHost(
  base: ts.CompilerHost,
  harnessPath: string,
  harnessSource: string,
): ts.CompilerHost {
  const cache = new Map<string, ts.SourceFile>();
  return {
    ...base,
    fileExists(name) {
      return name === harnessPath || base.fileExists(name);
    },
    readFile(name) {
      return name === harnessPath ? harnessSource : base.readFile(name);
    },
    getSourceFile(name, languageVersion, onError, shouldCreate) {
      if (name === harnessPath) {
        const cached = cache.get(name);
        if (cached) return cached;
        const sf = ts.createSourceFile(name, harnessSource, languageVersion, true);
        cache.set(name, sf);
        return sf;
      }
      return base.getSourceFile(name, languageVersion, onError, shouldCreate);
    },
  };
}
