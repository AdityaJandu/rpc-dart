#!/usr/bin/env node
import path from 'node:path';
import {
  checkContract,
  cleanGenerated,
  ConfigNotFoundError,
  diffContract,
  doctorChecks,
  generate,
  initWorkspace,
  resolveTargets,
  WatchSession,
} from '../dist/index.js';

const args = process.argv.slice(2);
const command = args[0];

function flag(name) {
  const index = args.indexOf(`--${name}`);
  if (index === -1) return undefined;
  return args[index + 1];
}

function hasFlag(name) {
  return args.includes(`--${name}`);
}

function flagsObject() {
  return {
    config: flag('config'),
    tsconfig: flag('tsconfig'),
    entry: flag('entry'),
    exportName: flag('export'),
    out: flag('out'),
    transformer: flag('transformer'),
    adapter: flag('adapter'),
  };
}

function policiesFrom(target) {
  return target.policies ?? { unserializablePolicy: 'error' };
}

async function main() {
  const cwd = process.cwd();
  const configsDir = cwd;

  switch (command) {
    case 'generate': {
      const targets = await resolveTargets(configsDir, flagsObject());
      for (const target of targets) {
        const result = await generate({
          tsconfigPath: target.tsconfigPath,
          entryFile: target.entry,
          exportName: target.exportName,
          outDir: path.resolve(cwd, target.dart?.outDir ?? 'lib/src/api'),
          adapter: target.adapter,
          transformer: target.transformer,
          policies: policiesFrom(target),
          force: hasFlag('force'),
        });
        const label = target.name ? ` [${target.name}]` : '';
        console.log(
          result.wrote
            ? `wrote${label} ${result.files.length} files (contract ${result.hash.slice(0, 15)})`
            : `contract unchanged${label}, no writes (${result.hash.slice(0, 15)})`,
        );
      }
      return;
    }
    case 'watch': {
      const targets = await resolveTargets(configsDir, flagsObject());
      for (const target of targets) {
        const session = new WatchSession({
          tsconfigPath: target.tsconfigPath,
          entryFile: target.entry,
          exportName: target.exportName,
          outDir: path.resolve(cwd, target.dart?.outDir ?? 'lib/src/api'),
          adapter: target.adapter,
          transformer: target.transformer,
          policies: policiesFrom(target),
          debounceMs: Number(flag('debounce-ms') ?? 300),
          onCycle: (cycle) =>
            console.log(
              cycle.changed
                ? `[watch] re-emitted ${cycle.written} files in ${cycle.durationMs}ms (${cycle.hash.slice(0, 15)})`
                : `[watch] contract unchanged in ${cycle.durationMs}ms`,
            ),
          onError: (error) => console.error(`[watch] transient error: ${error.message}`),
        });
        session.start();
      }
      console.log('[watch] started - press Ctrl+C to stop');
      return;
    }
    case 'check': {
      const targets = await resolveTargets(configsDir, flagsObject());
      let drift = false;
      for (const target of targets) {
        const result = await checkContract({
          tsconfigPath: target.tsconfigPath,
          entryFile: target.entry,
          exportName: target.exportName,
          outDir: path.resolve(cwd, target.dart?.outDir ?? 'lib/src/api'),
          adapter: target.adapter,
          transformer: target.transformer,
          policies: policiesFrom(target),
        });
        if (result.ok) {
          console.log('check: generated bindings are up to date');
        } else {
          drift = true;
          console.error('check: drift detected');
          for (const problem of result.problems) {
            console.error(`  - ${problem}`);
          }
        }
      }
      if (drift) process.exitCode = 3;
      return;
    }
    case 'diff': {
      const targets = await resolveTargets(configsDir, flagsObject());
      for (const target of targets) {
        const result = await diffContract({
          tsconfigPath: target.tsconfigPath,
          entryFile: target.entry,
          exportName: target.exportName,
          adapter: target.adapter,
          transformer: target.transformer,
          baselinePath: path.resolve(cwd, flag('baseline') ?? 'ir.snapshot.json'),
          updateBaseline: hasFlag('update-baseline'),
        });
        for (const entry of result.entries) {
          console.log(`${entry.breaking ? 'BREAKING' : 'ok      '}  ${entry.kind}  ${entry.path}  ${entry.detail}`);
        }
        console.log(`diff: ${result.breakingCount} breaking, ${result.nonBreakingCount} non-breaking`);
        if (result.hasBreaking && hasFlag('fail-on-breaking')) {
          process.exitCode = 4;
        }
      }
      return;
    }
    case 'clean': {
      const targets = await resolveTargets(configsDir, flagsObject());
      for (const target of targets) {
        const result = cleanGenerated(path.resolve(cwd, target.dart?.outDir ?? 'lib/src/api'));
        console.log(`clean: removed ${result.removed.length} owned files`);
      }
      return;
    }
    case 'doctor': {
      const targets = await resolveTargets(configsDir, flagsObject());
      for (const target of targets) {
        const label = target.name ? `[${target.name}] ` : '';
        const checks = await doctorChecks({
          tsconfigPath: target.tsconfigPath,
          entryFile: target.entry,
          exportName: target.exportName,
          adapter: target.adapter,
          dartPackagePath: flag('dart-package')
            ? path.resolve(cwd, flag('dart-package'))
            : target.dart?.packagePath
              ? path.resolve(cwd, target.dart.packagePath)
              : undefined,
        });
        let failing = false;
        for (const check of checks) {
          console.log(`${check.status.toUpperCase().padEnd(5)} ${label}${check.name}: ${check.detail}`);
          if (check.status === 'fail') failing = true;
        }
        if (failing) process.exitCode = 5;
      }
      return;
    }
    case 'init': {
      const result = await initWorkspace(cwd, { flutterDirs: [] });
      console.log(`init: wrote ${result.configPath}`);
      console.log(`  entry: ${result.config.entry}`);
      console.log(`  exportName: ${result.config.exportName}`);
      console.log(`  dart.outDir: ${result.config.dart.outDir}`);
      return;
    }
    default:
      console.error(`rpc-dart: unknown command "${command ?? ''}"`);
      console.error('commands: generate | watch | check | diff | clean | doctor | init');
      process.exitCode = 2;
  }
}

main().catch((error) => {
  if (error instanceof ConfigNotFoundError) {
    console.error(`rpc-dart: ${error.message}`);
    process.exitCode = 2;
  } else {
    console.error(`rpc-dart: ${error.message}`);
    process.exitCode = 1;
  }
});
