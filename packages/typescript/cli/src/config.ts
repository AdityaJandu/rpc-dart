import { existsSync, readFileSync } from 'node:fs';
import { createJiti } from 'jiti';

export interface RpcDartTarget {
  name?: string;
  /** Path to tsconfig.json, relative to the config file's directory. */
  tsconfig?: string;
  entry: string;
  exportName: string;
  transformer?: 'superjson' | 'json';
  dart?: { outDir: string; packagePath?: string };
  policies?: { unserializablePolicy?: 'error' | 'warn-dynamic' | 'skip-procedure' };
}

export interface RpcDartConfig extends RpcDartTarget {
  /** Multiple generation targets; each gets its own outDir. */
  projects?: RpcDartTarget[];
}

export type RpcDartConfigFile = 'rpc-dart.config.json' | 'rpc-dart.config.ts';

export function defineConfig(config: RpcDartConfig): RpcDartConfig {
  return config;
}

/** Raised when no usable configuration can be discovered. Exit code 2. */
export class ConfigNotFoundError extends Error {
  constructor(readonly searchDir: string) {
    super(
      `no rpc-dart.config.json found in ${searchDir} (or any flags provided).\n` +
        '  Run `npx rpc-dart init` to create one, or pass --config / --tsconfig / --entry / --export / --out.',
    );
    this.name = 'ConfigNotFoundError';
  }
}

export function findConfigFile(searchDir: string, explicit?: string): string | null {
  if (explicit) {
    const resolved = path.resolve(searchDir, explicit);
    return existsSync(resolved) ? resolved : null;
  }
  for (const name of ['rpc-dart.config.json', 'rpc-dart.config.ts']) {
    const candidate = path.join(searchDir, name);
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

export async function loadConfigFileAsync(configPath: string): Promise<RpcDartConfig> {
  if (configPath.endsWith('.json')) {
    return JSON.parse(readFileSync(configPath, 'utf-8')) as RpcDartConfig;
  }
  const jiti = createJiti(configPath, { fsCache: false, moduleCache: false });
  const mod = (await jiti.import(configPath)) as { default?: RpcDartConfig };
  if (!mod.default) {
    throw new Error(`${configPath} must default-export a defineConfig() value`);
  }
  return mod.default;
}

/**
 * Resolves the concrete generation targets from CLI flags + config file.
 * Explicit flags override config values. Supports multi-project configs.
 */
export async function resolveTargets(
  searchDir: string,
  flags: {
    config?: string;
    tsconfig?: string;
    entry?: string;
    exportName?: string;
    out?: string;
    transformer?: string;
  },
): Promise<Array<RpcDartTarget & { tsconfigPath: string }>> {
  const configPath = findConfigFile(searchDir, flags.config);
  let config: RpcDartConfig | null = null;
  if (configPath) {
    config = await loadConfigFileAsync(configPath);
  }

  // Flags-only mode when no config exists. Entry resolves against the
  // tsconfig's directory (matching extraction semantics).
  if (!config) {
    if (flags.tsconfig && flags.entry && flags.exportName && flags.out) {
      const tsconfigPath = path.resolve(searchDir, flags.tsconfig);
      return [
        {
          entry: path.resolve(path.dirname(tsconfigPath), flags.entry),
          exportName: flags.exportName,
          transformer: (flags.transformer as 'superjson' | 'json' | undefined) ?? 'superjson',
          dart: { outDir: flags.out },
          tsconfigPath,
        },
      ];
    }
    throw new ConfigNotFoundError(searchDir);
  }

  const configDir = path.dirname(configPath!);
  const projects = config.projects && config.projects.length > 0 ? config.projects : [config];
  return projects.map((project) => ({
    ...project,
    entry: path.resolve(configDir, flags.entry ?? project.entry),
    exportName: flags.exportName ?? project.exportName,
    transformer:
      (flags.transformer as 'superjson' | 'json' | undefined) ?? project.transformer,
    dart: {
      ...project.dart,
      outDir: flags.out ?? project.dart?.outDir ?? 'lib/src/api',
    },
    policies: project.policies,
    tsconfigPath: path.resolve(
      path.dirname(configPath ?? searchDir),
      flags.tsconfig ?? project.tsconfig ?? 'tsconfig.json',
    ),
  }));
}

import path from 'node:path';
