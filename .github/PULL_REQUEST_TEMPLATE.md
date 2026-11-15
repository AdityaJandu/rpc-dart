## Summary

One paragraph: what changed and why.

## Test evidence

- [ ] Failing test written first and watched failing (RED)
- [ ] Minimal implementation (GREEN)
- [ ] Refactor pass done (REFACTOR)
- [ ] `pnpm -r typecheck && pnpm -r build && pnpm -r test` green
- [ ] Dart suites + `dart analyze --fatal-infos --fatal-warnings` green
- [ ] `pnpm run audit:release` green

## Docs

- [ ] `docs/` updated when behavior changed
- [ ] Generated-code consumers considered (goldens refreshed via `-u` when emission changed)
