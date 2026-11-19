/**
 * Protocol-agnostic extraction host: tsconfig neutralization, in-memory
 * harness overlay, and per-alias type resolution shared by every adapter.
 */
import { relative } from 'node:path';
import type * as tsTypes from 'typescript';

export function harnessFileName(): string {
  return '__rpc_dart_harness__.ts';
}

export type HarnessAliasRole = 'in' | 'out' | 'tracked' | 'error' | 'isstream';

export function pathAlias(path: string, role: HarnessAliasRole): string {
  const segments = path.split('.').map((s) => s.replace(/[^A-Za-z0-9_]/g, '_'));
  return ['__p', ...segments, role].join('_');
}

/** './router.ts' -> './router' (bundler-style), or explicit extensions under
 * node16/nodenext resolution, where extensionless relative imports are
 * illegal (TS5097) and the TS-standard specifiers (.js/.mjs/.cjs) resolve to
 * the .ts/.mts/.cts sources with or without allowImportingTsExtensions.
 */
export function entryImportPath(
  tsconfigDir: string,
  entryAbsolute: string,
  resolution?: 'node16' | 'nodenext',
): string {
  const rel = relative(tsconfigDir, entryAbsolute);
  const specifier =
    resolution === undefined
      ? rel.replace(/\.(mts|cts|tsx?)$/, '')
      : rel
          .replace(/\.tsx$/, '.js')
          .replace(/\.mts$/, '.mjs')
          .replace(/\.cts$/, '.cjs')
          .replace(/\.ts$/, '.js');
  return specifier.startsWith('.') ? specifier : `./${specifier}`;
}

export function resolutionKind(
  ts: typeof tsTypes,
  moduleResolution: tsTypes.ModuleResolutionKind | undefined,
): 'node16' | 'nodenext' | undefined {
  if (moduleResolution === ts.ModuleResolutionKind.Node16) return 'node16';
  if (moduleResolution === ts.ModuleResolutionKind.NodeNext) return 'nodenext';
  return undefined;
}

/**
 * Extraction-neutral overrides: the in-memory program exists only to answer
 * type queries on the harness, so build/lint-only flags are neutralized
 * regardless of the user's tsconfig — they would otherwise reject the
 * synthetic harness (rootDir, composite emit rules) or surface lint-only
 * semantic errors (noUnusedLocals/noUnusedParameters, isolatedDeclarations)
 * that have nothing to do with contract extraction.
 */
export function neutralizeOptions(parsed: tsTypes.CompilerOptions): tsTypes.CompilerOptions {
  return {
    ...parsed,
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
}

export function overlayHost(
  ts: typeof tsTypes,
  base: tsTypes.CompilerHost,
  harnessPath: string,
  harnessSource: string,
): tsTypes.CompilerHost {
  const cache = new Map<string, tsTypes.SourceFile>();
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

export function typeFromAlias(
  ts: typeof tsTypes,
  sourceFile: tsTypes.SourceFile,
  checker: tsTypes.TypeChecker,
  name: string,
): tsTypes.Type | undefined {
  for (const statement of sourceFile.statements) {
    if (ts.isTypeAliasDeclaration(statement) && statement.name.text === name) {
      return checker.getTypeFromTypeNode(statement.type);
    }
  }
  return undefined;
}