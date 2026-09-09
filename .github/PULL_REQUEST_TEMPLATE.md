Closes #

## What / why

<!-- one paragraph; link the design comment on the issue if the architect reviewed the approach -->

## Validation

```
./validate.sh all   →  paste the summary lines here
```

## Review checklist (author fills in; reviewers verify — see WORKFLOW.md §6)

- [ ] **No magic strings/numbers** — every meaningful literal is a named constant or `data/*.json`
- [ ] **No duplicated real logic** — searched for existing helpers/patterns: <!-- what you searched -->
- [ ] **SOLID / single responsibility**; composition over `switch` towers; clock/random/transport injected
- [ ] **Size limits** — files ≤ 300 lines, functions ≤ 40, complexity ≤ 10, ≤ 4 params
- [ ] **Full descriptive names** — no abbreviations (allow `x`, `y`, `id`); predicate booleans; units in names
- [ ] **Unit tests** for all new logic; **integration test** if crossing a subsystem; **gameplay scenario** if rules/balance changed
- [ ] **Determinism preserved** — no `Math.random` / `Date.now` / `performance.now` in simulation code
- [ ] **Docs in sync** — `README.md` / `CLAUDE.md` / `WORKFLOW.md` (and any doc describing what changed) updated in this PR and consistent with each other; template-level fixes upstreamed to `base-multiplayer-game`
- [ ] Constants / `data/*.json` updated
- [ ] Graphics PRs: before/after screenshots attached (motion capture if animation changed)
- [ ] Gameplay PRs: balance values touched are listed

<!-- Reviewers: findings as line-anchored review comments; author replies on every thread; reviewer resolves. -->
