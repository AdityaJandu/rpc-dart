# Contributing

Thanks for helping build rpc-dart! This guide covers setup, the development workflow, and the rules that keep the project healthy.

## Setup

```bash
git clone https://github.com/rpc-dart/rpc-dart.git
cd rpc-dart
pnpm install                 # TypeScript workspace
cd packages/dart/trpc_dart && dart pub get && cd -
cd packages/dart/trpc_flutter && flutter pub get && cd -
```

## Development workflow

The project uses strict test-driven development: write the failing test first, watch it fail for the expected reason, implement minimally, then refactor. No production code lands without its test.

```bash
pnpm typecheck               # strict TS across all packages
pnpm build                   # tsc build for all packages
pnpm test                    # vitest suites (core, adapter, generator, e2e)
cd packages/dart/trpc_dart && dart test
cd packages/dart/trpc_flutter && flutter test
```

### Conventions

- **Zero internal jargon**: no planning tags (epic/sprint/phase identifiers) in source, comments, tests, docs, or trackers.
- **Zero raw casts in generated code**: use `RpcJson` decoders with pattern matching; the zero-cast gate test and audit script both enforce this.
- **Deterministic emission**: generated output must be byte-identical for identical contracts; golden tests enforce it.
- **Structured errors**: decode failures must carry field breadcrumb paths, expected and actual types.

### Pull requests

- One logical change per PR; include the failing test you started from.
- Run the full battery (`pnpm test`, Dart suites, analyzers) before requesting review.
- Update `docs/` when behavior changes — documentation is part of the definition of done.
- The release audit (`pnpm run audit:release`) must pass.

See [SECURITY.md](SECURITY.md) for reporting vulnerabilities.
