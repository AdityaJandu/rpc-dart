import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { extractContract } from '@rpc-dart/trpc-adapter';

export interface DoctorCheck {
  name: string;
  status: 'pass' | 'warn' | 'fail';
  detail: string;
}

export interface DoctorOptions {
  tsconfigPath?: string;
  entryFile?: string;
  exportName?: string;
  /** Path to a Dart package whose pubspec version should match the CLI's. */
  dartPackagePath?: string;
}

/** Environment + workspace checklist. */
export async function doctorChecks(options: DoctorOptions = {}): Promise<DoctorCheck[]> {
  const checks: DoctorCheck[] = [];

  const nodeMajor = Number(process.versions.node.split('.')[0]);
  checks.push({
    name: 'node-version',
    status: nodeMajor >= 20 ? 'pass' : 'fail',
    detail: `node ${process.versions.node} (requires >= 20)`,
  });

  if (options.tsconfigPath) {
    checks.push({
      name: 'tsconfig',
      status: existsSync(options.tsconfigPath) ? 'pass' : 'fail',
      detail: options.tsconfigPath,
    });
  } else {
    checks.push({ name: 'tsconfig', status: 'warn', detail: 'no tsconfig path provided' });
  }

  if (options.entryFile && options.exportName) {
    try {
      await extractContract({
        tsconfigPath: options.tsconfigPath ?? '',
        entryFile: options.entryFile,
        exportName: options.exportName,
        protocol: { kind: 'trpc', version: '11', transformer: 'superjson' },
      });
      checks.push({ name: 'router-export', status: 'pass', detail: `${options.exportName} extracted` });
    } catch (error) {
      checks.push({
        name: 'router-export',
        status: 'fail',
        detail: (error as Error).message.slice(0, 200),
      });
    }
  } else {
    checks.push({ name: 'router-export', status: 'warn', detail: 'no router configured yet (run rpc-dart init)' });
  }

  let dartBin: string | null = null;
  for (const candidate of [process.env.DART_BIN, 'dart', `${process.env.HOME}/development/flutter/bin/dart`]) {
    if (!candidate) continue;
    try {
      execFileSync(candidate, ['--version'], { stdio: 'pipe' });
      dartBin = candidate;
      break;
    } catch {
      continue;
    }
  }
  checks.push({
    name: 'dart-sdk',
    status: dartBin ? 'pass' : 'fail',
    detail: dartBin ?? 'dart not found on PATH (set DART_BIN)',
  });

  try {
    execFileSync('flutter', ['--version', '--machine'], { stdio: 'pipe' });
    checks.push({ name: 'flutter-sdk', status: 'pass', detail: 'flutter available' });
  } catch {
    checks.push({ name: 'flutter-sdk', status: 'warn', detail: 'flutter not available (optional for server-only use)' });
  }

  if (options.dartPackagePath) {
    const pubspecPath = `${options.dartPackagePath}/pubspec.yaml`;
    try {
      const pubspec = readFileSync(pubspecPath, 'utf-8');
      const dartVersion = /^version:\s*(.+)$/m.exec(pubspec)?.[1]?.trim();
      const cliPackage = JSON.parse(
        readFileSync(new URL('../../package.json', import.meta.url), 'utf-8'),
      ) as { version?: string };
      const cliVersion = cliPackage.version ?? 'unknown';
      checks.push({
        name: 'version-alignment',
        status: dartVersion === cliVersion ? 'pass' : 'warn',
        detail: `rpc-dart ${cliVersion} vs runtime ${dartVersion ?? 'unknown'}`,
      });
    } catch (error) {
      checks.push({
        name: 'version-alignment',
        status: 'warn',
        detail: `could not read pubspec: ${(error as Error).message.slice(0, 120)}`,
      });
    }
  } else {
    checks.push({ name: 'version-alignment', status: 'warn', detail: 'no dart package path provided' });
  }

  return checks;
}
