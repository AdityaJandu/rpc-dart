#!/usr/bin/env node
// Prepares the Dart packages for pub.dev publishing: strips `publish_to: none`,
// replaces local path dependencies with hosted version constraints, and removes
// `dependency_overrides`. Run by release.yml before `dart pub publish --force`.
// Use `--restore` after publishing to return the pubspecs to monorepo dev state.
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const VERSION = '0.1.1';
const PACKAGES = ['trpc_dart', 'trpc_flutter'];
const restore = process.argv.includes('--restore');

function prepare(pkg) {
  const pubspecPath = path.join(ROOT, 'packages/dart', pkg, 'pubspec.yaml');
  if (!existsSync(pubspecPath)) throw new Error(`missing ${pubspecPath}`);
  let pubspec = readFileSync(pubspecPath, 'utf-8');

  // 1. Strip the local-only publish blocker.
  pubspec = pubspec.replace(/^publish_to:\s*none\s*\n/m, '');

  // 2. Replace path dependencies on sibling rpc-dart packages with hosted
  //    version constraints.
  pubspec = pubspec.replace(
    /^(\s*)trpc_dart:\s*\n\s*path:\s*.*$/m,
    `$1trpc_dart: ^${VERSION}`,
  );

  // 3. Remove the local dependency_overrides block (pub strips it from the
  //    published archive anyway, but removing it here makes the prepared
  //    pubspec explicitly clean for dry-run validation).
  pubspec = pubspec.replace(/^dependency_overrides:\s*\n(?:\s+.*\n)*/m, '');

  // 4. Verify the version matches the release.
  const version = /^version:\s*(.+)$/m.exec(pubspec)?.[1]?.trim();
  if (version !== VERSION) {
    throw new Error(`${pkg} version ${version} does not match release ${VERSION}`);
  }

  writeFileSync(pubspecPath, pubspec);
  console.log(`prepared packages/dart/${pkg} (version ${version}, publish-ready)`);
}

function restoreDev(pkg) {
  const pubspecPath = path.join(ROOT, 'packages/dart', pkg, 'pubspec.yaml');
  let pubspec = readFileSync(pubspecPath, 'utf-8');

  // 1. Re-add the local-only publish blocker.
  if (!/^publish_to:\s*none\s*$/m.test(pubspec)) {
    pubspec = pubspec.replace(/^version:\s*(.+)$/m, 'version: $1\npublish_to: none');
  }

  // 2. Replace hosted constraints on sibling rpc-dart packages with local
  //    path dependencies for monorepo development.
  pubspec = pubspec.replace(
    /^  trpc_dart: \^\d+\.\d+\.\d+$/m,
    '  trpc_dart:\n    path: ../trpc_dart',
  );

  writeFileSync(pubspecPath, pubspec);
  console.log(`restored packages/dart/${pkg} (monorepo dev state)`);
}

if (restore) {
  for (const pkg of [...PACKAGES].reverse()) restoreDev(pkg);
  console.log('restore complete');
} else {
  for (const pkg of PACKAGES) prepare(pkg);
  console.log('publish preparation complete');
}
