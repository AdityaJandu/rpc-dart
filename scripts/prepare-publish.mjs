#!/usr/bin/env node
// Prepares Dart packages for pub.dev publishing:
// - Removes pubspec_overrides.yaml (dart pub publish rejects active dependency_overrides).
// - Ensures sibling packages use hosted ^${VERSION} constraints in pubspec.yaml.
// - Ensures publish_to is absent in every pubspec.
// - Validates version matches release version.
// Use `--restore` after publishing or validation to recreate pubspec_overrides.yaml
// for local monorepo development.
import { existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
// Release version derived from the lockstep source of truth (core package.json)
// so version bumps don't require editing this script.
const VERSION = JSON.parse(
  readFileSync(path.join(ROOT, 'packages/typescript/core/package.json'), 'utf-8'),
).version;

// Per-package dev overrides (path deps used only in the monorepo). trpc_dart is
// the engine and has no sibling overrides.
const PACKAGES = {
  trpc_dart: {},
  trpc_flutter: { trpc_dart: '../trpc_dart' },
  orpc_dart: { trpc_dart: '../trpc_dart' },
  orpc_flutter: {
    orpc_dart: '../orpc_dart',
    trpc_dart: '../trpc_dart',
    trpc_flutter: '../trpc_flutter',
  },
};
const SIBLINGS = Object.keys(PACKAGES);
const restore = process.argv.includes('--restore');

function overridesPath(pkg) {
  return path.join(ROOT, 'packages/dart', pkg, 'pubspec_overrides.yaml');
}

function hostedSiblings(pubspec) {
  let out = pubspec;
  for (const sibling of SIBLINGS) {
    out = out.replace(
      new RegExp(`^(\\s*)${sibling}:\\s*\\n\\s*path:\\s*.*$`, 'm'),
      `$1${sibling}: ^${VERSION}`,
    );
  }
  return out;
}

function prepare(pkg) {
  const pubspecPath = path.join(ROOT, 'packages/dart', pkg, 'pubspec.yaml');
  if (!existsSync(pubspecPath)) throw new Error(`missing ${pubspecPath}`);
  let pubspec = readFileSync(pubspecPath, 'utf-8');

  pubspec = pubspec.replace(/^publish_to:\s*none\s*\n/m, '');
  pubspec = hostedSiblings(pubspec);
  pubspec = pubspec.replace(/^dependency_overrides:\s*\n(?:\s+.*\n)*/m, '');

  const version = /^version:\s*(.+)$/m.exec(pubspec)?.[1]?.trim();
  if (version !== VERSION) {
    throw new Error(`${pkg} version ${version} does not match release ${VERSION}`);
  }

  writeFileSync(pubspecPath, pubspec);

  const overrides = overridesPath(pkg);
  if (existsSync(overrides)) rmSync(overrides);

  console.log(`prepared packages/dart/${pkg} (version ${version}, publish-ready)`);
}

function restoreDev(pkg) {
  const pubspecPath = path.join(ROOT, 'packages/dart', pkg, 'pubspec.yaml');
  let pubspec = readFileSync(pubspecPath, 'utf-8');

  pubspec = pubspec.replace(/^publish_to:\s*none\s*\n/m, '');
  pubspec = hostedSiblings(pubspec);
  writeFileSync(pubspecPath, pubspec);

  const overrides = PACKAGES[pkg];
  const entries = Object.entries(overrides);
  if (entries.length > 0) {
    const content =
      'dependency_overrides:\n' +
      entries.map(([name, rel]) => `  ${name}:\n    path: ${rel}\n`).join('');
    writeFileSync(overridesPath(pkg), content);
  }

  console.log(`restored packages/dart/${pkg} (monorepo dev state)`);
}

const names = Object.keys(PACKAGES);
if (restore) {
  for (const pkg of [...names].reverse()) restoreDev(pkg);
  console.log('restore complete');
} else {
  for (const pkg of names) prepare(pkg);
  console.log('publish preparation complete');
}