#!/usr/bin/env node
// Prepares Dart packages for pub.dev publishing:
// - Removes pubspec_overrides.yaml (dart pub publish rejects active dependency_overrides).
// - Ensures trpc_dart: ^${VERSION} is set in packages/dart/trpc_flutter/pubspec.yaml.
// - Ensures publish_to is absent in both pubspecs.
// - Validates version matches release version.
// Use `--restore` after publishing or validation to recreate pubspec_overrides.yaml
// for local monorepo development.
import { existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const VERSION = '0.1.3';
const PACKAGES = ['trpc_dart', 'trpc_flutter'];
const restore = process.argv.includes('--restore');

const FLUTTER_OVERRIDES_PATH = path.join(
  ROOT,
  'packages/dart/trpc_flutter/pubspec_overrides.yaml',
);

function prepare(pkg) {
  const pubspecPath = path.join(ROOT, 'packages/dart', pkg, 'pubspec.yaml');
  if (!existsSync(pubspecPath)) throw new Error(`missing ${pubspecPath}`);
  let pubspec = readFileSync(pubspecPath, 'utf-8');

  // 1. Ensure publish_to: none is absent so repository provenance passes.
  pubspec = pubspec.replace(/^publish_to:\s*none\s*\n/m, '');

  // 2. Ensure hosted version constraint is used on sibling packages.
  pubspec = pubspec.replace(
    /^(\s*)trpc_dart:\s*\n\s*path:\s*.*$/m,
    `$1trpc_dart: ^${VERSION}`,
  );

  // 3. Remove inline dependency_overrides if any exist.
  pubspec = pubspec.replace(/^dependency_overrides:\s*\n(?:\s+.*\n)*/m, '');

  // 4. Verify version matches release.
  const version = /^version:\s*(.+)$/m.exec(pubspec)?.[1]?.trim();
  if (version !== VERSION) {
    throw new Error(`${pkg} version ${version} does not match release ${VERSION}`);
  }

  writeFileSync(pubspecPath, pubspec);

  // 5. Remove pubspec_overrides.yaml (pub publish rejects packages with overrides).
  if (existsSync(FLUTTER_OVERRIDES_PATH)) {
    rmSync(FLUTTER_OVERRIDES_PATH);
  }

  console.log(`prepared packages/dart/${pkg} (version ${version}, publish-ready)`);
}

function restoreDev(pkg) {
  const pubspecPath = path.join(ROOT, 'packages/dart', pkg, 'pubspec.yaml');
  let pubspec = readFileSync(pubspecPath, 'utf-8');

  // 1. Ensure publish_to: none is never present in committed manifests.
  pubspec = pubspec.replace(/^publish_to:\s*none\s*\n/m, '');

  // 2. Ensure hosted constraint stays clean in pubspec.yaml.
  pubspec = pubspec.replace(
    /^(\s*)trpc_dart:\s*\n\s*path:\s*.*$/m,
    `$1trpc_dart: ^${VERSION}`,
  );

  writeFileSync(pubspecPath, pubspec);

  // 3. Recreate pubspec_overrides.yaml for local development.
  const overridesContent = `dependency_overrides:\n  trpc_dart:\n    path: ../trpc_dart\n`;
  writeFileSync(FLUTTER_OVERRIDES_PATH, overridesContent);

  console.log(`restored packages/dart/${pkg} (monorepo dev state)`);
}

if (restore) {
  for (const pkg of [...PACKAGES].reverse()) restoreDev(pkg);
  console.log('restore complete');
} else {
  for (const pkg of PACKAGES) prepare(pkg);
  console.log('publish preparation complete');
}
