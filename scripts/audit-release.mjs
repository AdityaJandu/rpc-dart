#!/usr/bin/env node
// Pre-deployment release audit: version lockstep, CLI packaging, zero-cast
// generated code, jargon-free tree, markdown link integrity, and publish
// readiness. Exits non-zero on the first failing check category.
import { execSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const results = [];

function check(name, run) {
  try {
    const detail = run();
    results.push({ name, ok: true, detail: detail ?? 'ok' });
  } catch (error) {
    results.push({ name, ok: false, detail: error.message });
  }
}

function walk(dir, predicate, acc = []) {
  if (!existsSync(dir)) return acc;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name === '.dart_tool' || entry.name === 'dist' || entry.name.startsWith('.')) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, predicate, acc);
    else if (predicate(full)) acc.push(full);
  }
  return acc;
}

// 1. Version lockstep across npm + pub packages.
check('version-lockstep', () => {
  const npm = ['core', 'trpc-adapter', 'orpc-adapter', 'dart-generator', 'cli'].map(
    (p) => JSON.parse(readFileSync(path.join(ROOT, 'packages/typescript', p, 'package.json'), 'utf-8')).version,
  );
  const dart = ['trpc_dart', 'trpc_flutter', 'orpc_dart', 'orpc_flutter'].map((p) => {
    const pubspec = readFileSync(path.join(ROOT, 'packages/dart', p, 'pubspec.yaml'), 'utf-8');
    return /^version:\s*(.+)$/m.exec(pubspec)?.[1]?.trim();
  });
  const all = [...npm, ...dart];
  if (all.some((v) => v !== all[0])) {
    throw new Error(`versions differ: npm [${npm.join(', ')}] dart [${dart.join(', ')}]`);
  }
  if (!/^\d+\.\d+\.\d+$/.test(all[0] ?? '')) throw new Error(`invalid version: ${all[0]}`);
  return `all 9 packages at ${all[0]}`;
});

// 2. CLI binary + shebang + dist artifacts.
check('cli-binary', () => {
  const bin = path.join(ROOT, 'packages/typescript/cli/bin/rpc-dart.js');
  const content = readFileSync(bin, 'utf-8');
  if (!content.startsWith('#!/usr/bin/env node')) throw new Error('missing shebang');
  const mode = statSync(bin).mode & 0o111;
  if (!(mode & 0o1)) throw new Error('bin is not executable');
  for (const artifact of ['dist/index.js', 'dist/commands/generate.js']) {
    if (!existsSync(path.join(ROOT, 'packages/typescript/cli', artifact))) {
      throw new Error(`missing dist artifact: ${artifact} (run pnpm -r build)`);
    }
  }
  return 'shebang + executable + dist present';
});

// 3. Zero raw `as` casts in generated Dart.
check('zero-cast-generated', () => {
  const dirs = [
    path.join(ROOT, 'examples/flutter-app/lib/src/api'),
    path.join(ROOT, 'examples/flutter-app/lib/src/orpc_api'),
    path.join(ROOT, 'packages/typescript/dart-generator/test/golden'),
  ];
  const offenders = [];
  for (const dir of dirs) {
    for (const file of walk(dir, (f) => f.endsWith('.dart'))) {
      const content = readFileSync(file, 'utf-8');
      const match = /(?:\s|\()as\s+[A-Za-z_]/.exec(content);
      if (match) offenders.push(`${path.relative(ROOT, file)}: ...${content.slice(Math.max(0, match.index - 40), match.index + 40)}...`);
    }
  }
  if (offenders.length > 0) throw new Error(`raw casts in generated Dart:\n${offenders.join('\n')}`);
  return 'generated Dart is zero-cast';
});

// 4. Zero internal planning jargon anywhere public.
check('zero-jargon', () => {
  const patterns = [/ADR-\d/, /Phase \d/, /\bT\d+\.\d+/, /docs\/architecture/];
  const offenders = [];
  const scanTargets = [
    ...walk(path.join(ROOT, 'packages'), (f) => /\.(ts|dart|mjs|yaml|json|md)$/.test(f)),
    ...walk(path.join(ROOT, 'examples'), (f) => /\.(ts|dart|mjs|yaml|json|md)$/.test(f)),
    ...walk(path.join(ROOT, 'docs'), (f) => f.endsWith('.md')),
    path.join(ROOT, 'README.md'),
    path.join(ROOT, 'UPCOMING_TASKS.md'),
    path.join(ROOT, 'CONTRIBUTING.md'),
  ];
  for (const file of scanTargets) {
    if (!existsSync(file)) continue;
    const lines = readFileSync(file, 'utf-8').split('\n');
    lines.forEach((line, index) => {
      if (patterns.some((p) => p.test(line))) {
        offenders.push(`${path.relative(ROOT, file)}:${index + 1}`);
      }
    });
  }
  if (offenders.length > 0) throw new Error(`internal jargon found:\n${offenders.join('\n')}`);
  return 'tree is jargon-free';
});

// 5. Markdown link integrity.
check('markdown-links', () => {
  const files = [
    path.join(ROOT, 'README.md'),
    path.join(ROOT, 'UPCOMING_TASKS.md'),
    path.join(ROOT, 'CONTRIBUTING.md'),
    ...walk(path.join(ROOT, 'docs'), (f) => f.endsWith('.md')),
    ...['core', 'trpc-adapter', 'orpc-adapter', 'dart-generator', 'cli'].map(
      (p) => path.join(ROOT, 'packages/typescript', p, 'README.md'),
    ),
    ...['trpc_dart', 'trpc_flutter', 'orpc_dart', 'orpc_flutter'].map(
      (p) => path.join(ROOT, 'packages/dart', p, 'README.md'),
    ),
  ];
  const dead = [];
  const linkPattern = /\[[^\]]*\]\(([^)]+)\)/g;
  for (const file of files) {
    if (!existsSync(file)) continue;
    const content = readFileSync(file, 'utf-8');
    for (const match of content.matchAll(linkPattern)) {
      const target = match[1];
      if (/^(https?:|#|mailto:)/.test(target)) continue;
      const resolved = path.resolve(path.dirname(file), target.split('#')[0]);
      if (!existsSync(resolved)) {
        dead.push(`${path.relative(ROOT, file)} -> ${target}`);
      }
    }
  }
  if (dead.length > 0) throw new Error(`dead links:\n${dead.join('\n')}`);
  return 'all relative links resolve';
});

// 5.5. .pubignore existence + pubspec_overrides architecture + no build/ directories.
check('dart-packaging', () => {
  const dartPackages = {
    trpc_dart: { hosted: [] },
    trpc_flutter: { hosted: ['trpc_dart'] },
    orpc_dart: { hosted: ['trpc_dart'] },
    orpc_flutter: { hosted: ['orpc_dart', 'trpc_flutter'] },
  };
  for (const [pkg, { hosted }] of Object.entries(dartPackages)) {
    const dir = path.join(ROOT, 'packages/dart', pkg);
    const pubignore = path.join(dir, '.pubignore');
    if (!existsSync(pubignore)) throw new Error(`missing .pubignore in packages/dart/${pkg}`);
    const ignoreContent = readFileSync(pubignore, 'utf-8');
    if (!ignoreContent.includes('build/')) throw new Error(`${pkg}/.pubignore missing build/ exclusion`);
    if (!ignoreContent.includes('.dart_tool/')) throw new Error(`${pkg}/.pubignore missing .dart_tool/ exclusion`);

    const pubspec = readFileSync(path.join(dir, 'pubspec.yaml'), 'utf-8');
    if (/publish_to:\s*none/.test(pubspec)) {
      throw new Error(`${pkg}/pubspec.yaml must not contain publish_to: none`);
    }
    const version = /^version:\s*(.+)$/m.exec(pubspec)?.[1]?.trim();
    for (const sibling of hosted) {
      const re = new RegExp(`${sibling}:\\s*\\^${version.replaceAll('.', '\\.')}\\b`);
      if (!re.test(pubspec)) {
        throw new Error(`${pkg}/pubspec.yaml must declare hosted constraint ${sibling}: ^${version}`);
      }
    }
    if (hosted.length > 0) {
      if (!ignoreContent.includes('pubspec_overrides.yaml')) {
        throw new Error(`${pkg}/.pubignore missing pubspec_overrides.yaml exclusion`);
      }
      if (!existsSync(path.join(dir, 'pubspec_overrides.yaml'))) {
        throw new Error(`missing packages/dart/${pkg}/pubspec_overrides.yaml`);
      }
    }
  }

  const buildDirs = walk(path.join(ROOT, 'packages/dart'), (f) => path.basename(f) === 'build' && statSync(f).isDirectory());
  if (buildDirs.length > 0) throw new Error(`build/ directories found:\n${buildDirs.join('\n')}`);

  // Validate prepare-publish and restore is a pure round-trip
  const beforeStatus = execSync('git status --porcelain packages/dart', { cwd: ROOT, encoding: 'utf-8' });
  execSync('node scripts/prepare-publish.mjs', { cwd: ROOT, stdio: 'pipe' });
  execSync('node scripts/prepare-publish.mjs --restore', { cwd: ROOT, stdio: 'pipe' });
  const afterStatus = execSync('git status --porcelain packages/dart', { cwd: ROOT, encoding: 'utf-8' });
  if (beforeStatus !== afterStatus) {
    throw new Error(`prepare-publish + restore altered git state in packages/dart:\nBefore:\n${beforeStatus}\nAfter:\n${afterStatus}`);
  }

  return 'pubspec_overrides architecture verified for 4 packages; clean prepare/restore cycle; no build/ directories';
});

// 6. Publish readiness + zero-flag check against both example configs.
check('publish-readiness', () => {
  const npm = ['core', 'trpc-adapter', 'orpc-adapter', 'dart-generator', 'cli'].map((p) => path.join(ROOT, 'packages/typescript', p));
  const dart = ['trpc_dart', 'trpc_flutter', 'orpc_dart', 'orpc_flutter'].map((p) => path.join(ROOT, 'packages/dart', p));
  for (const dir of [...npm, ...dart]) {
    for (const required of ['README.md', 'CHANGELOG.md', 'LICENSE']) {
      if (!existsSync(path.join(dir, required))) {
        throw new Error(`missing ${required} in ${path.relative(ROOT, dir)}`);
      }
    }
  }
  const cliBin = path.join(ROOT, 'packages/typescript/cli/bin/rpc-dart.js');
  for (const example of ['examples/trpc-fastify', 'examples/orpc-fastify']) {
    const cwd = path.join(ROOT, example);
    if (!existsSync(path.join(cwd, 'rpc-dart.config.json'))) {
      throw new Error(`missing ${example}/rpc-dart.config.json`);
    }
    execSync(`node ${path.relative(cwd, cliBin)} check`, { cwd, stdio: 'pipe' });
  }
  return 'manifests complete; zero-flag check passes on trpc-fastify and orpc-fastify';
});

// Report.
let failed = false;
console.log('=== Release Audit ===');
for (const result of results) {
  console.log(`${result.ok ? 'PASS' : 'FAIL'}  ${result.name}: ${result.detail.split('\n')[0]}`);
  if (!result.ok) {
    console.log(result.detail);
    failed = true;
  }
}
if (failed) {
  console.log('=== AUDIT FAILED ===');
  process.exit(1);
}
console.log('=== AUDIT PASSED ===');
