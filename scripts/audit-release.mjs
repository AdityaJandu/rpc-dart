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
  const npm = ['core', 'trpc-adapter', 'dart-generator', 'cli'].map(
    (p) => JSON.parse(readFileSync(path.join(ROOT, 'packages/typescript', p, 'package.json'), 'utf-8')).version,
  );
  const dart = ['trpc_dart', 'trpc_flutter'].map((p) => {
    const pubspec = readFileSync(path.join(ROOT, 'packages/dart', p, 'pubspec.yaml'), 'utf-8');
    return /^version:\s*(.+)$/m.exec(pubspec)?.[1]?.trim();
  });
  const all = [...npm, ...dart];
  if (all.some((v) => v !== all[0])) {
    throw new Error(`versions differ: npm [${npm.join(', ')}] dart [${dart.join(', ')}]`);
  }
  if (all[0] !== '0.1.2') throw new Error(`expected 0.1.2, got ${all[0]}`);
  return `all 6 packages at ${all[0]}`;
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

// 5.5. .pubignore existence + no build/ directories under packages/dart/.
check('dart-packaging', () => {
  for (const pkg of ['trpc_dart', 'trpc_flutter']) {
    const pubignore = path.join(ROOT, 'packages/dart', pkg, '.pubignore');
    if (!existsSync(pubignore)) throw new Error(`missing .pubignore in packages/dart/${pkg}`);
    const content = readFileSync(pubignore, 'utf-8');
    if (!content.includes('build/')) throw new Error(`${pkg}/.pubignore missing build/ exclusion`);
    if (!content.includes('.dart_tool/')) throw new Error(`${pkg}/.pubignore missing .dart_tool/ exclusion`);
  }
  const buildDirs = walk(path.join(ROOT, 'packages/dart'), (f) => path.basename(f) === 'build' && statSync(f).isDirectory());
  if (buildDirs.length > 0) throw new Error(`build/ directories found:\n${buildDirs.join('\n')}`);
  return '.pubignore present in both packages; no build/ directories';
});

// 6. Publish readiness + zero-flag check against the example config.
check('publish-readiness', () => {
  const npm = ['core', 'trpc-adapter', 'dart-generator', 'cli'].map((p) => path.join(ROOT, 'packages/typescript', p));
  const dart = ['trpc_dart', 'trpc_flutter'].map((p) => path.join(ROOT, 'packages/dart', p));
  for (const dir of [...npm, ...dart]) {
    for (const required of ['README.md', 'CHANGELOG.md', 'LICENSE']) {
      if (!existsSync(path.join(dir, required))) {
        throw new Error(`missing ${required} in ${path.relative(ROOT, dir)}`);
      }
    }
  }
  const exampleConfig = path.join(ROOT, 'examples/trpc-fastify/rpc-dart.config.json');
  if (!existsSync(exampleConfig)) throw new Error('missing examples/trpc-fastify/rpc-dart.config.json');
  execSync(`node ${path.relative(path.join(ROOT, 'examples/trpc-fastify'), path.join(ROOT, 'packages/typescript/cli/bin/rpc-dart.js'))} check`, { cwd: path.join(ROOT, 'examples/trpc-fastify'), stdio: 'pipe' });
  return 'manifests complete; zero-flag check passes on the example config';
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
