# Engineering Standards

These are **enforceable rules**, not suggestions. They are written in the imperative and
each is checkable. An AI building a game from this template MUST follow every rule here.
"It compiles" and "it renders" are never sufficient — the gate below is.

> **THE GATE:** `./validate.sh all` (lint + duplication + typecheck + test) is the single source
> of truth for whether work is done. No task is complete until it is green. Never commit red.

---

## 1. The Validation Gate (`./validate.sh`)

1. **Always use `./validate.sh`. Never run the underlying tools directly.** Do not reach for
   `pnpm -r test`, `pnpm test`, `pnpm typecheck`, `npx tsc`, `pnpm eslint`, `pnpm prettier`,
   or `pnpm --filter ... exec vitest` as a shortcut. The wrapper:
   - pre-builds `@base-multiplayer-game/shared` before typecheck (`build_shared`) so downstream
     `.d.ts` project references are fresh — running `tsc` directly gives stale/false results;
   - runs **eslint AND prettier `--check` as a pair** — running only eslint silently misses
     formatting failures — then audits the source for `eslint-disable` directives without a
     `-- reason` and for `TODO`s without a ticket (§3.3), printing the directive count, and
     checks that `docs/INDEX.md` is fresh (`scripts/docs-index.sh --check`);
   - runs **`jscpd`** (`duplication`) against `.jscpd.json`: ≥ 5 duplicated lines / 50 tokens
     anywhere in `packages/*/src` outside tests, test builders, fakes and scenario tables fails
     (§3.3); import blocks are ignored; the offending file pairs are printed with line ranges;
   - runs the unit tier **with coverage thresholds** (§2.5), so a drop below a package's floor
     fails `test`;
   - **caches green results by content** (#75): a green run is stamped under
     `$HOME/.cache/<slug>-validate/<tree>.<command>` (fields: `exit`, ISO `time`, `log` path,
     `node` major, `command`, `tree`; the raw log under `logs/`), keyed by `git write-tree` of the
     whole working tree — tracked and untracked, via a temporary index — plus the Node major
     version. **"Same tree" includes untracked files**: a worktree at the author's commit misses
     the author's stamp when either side has any untracked, non-ignored file. A repeat call on the
     same tree prints `cached green from <time> at tree <hash>` and the stored log path and exits
     0 in well under a second; the filters apply to the stored log. Red is never cached, `all`
     stamps each phase and itself, `--fresh` bypasses the stamp, and `-- extra-args` calls are
     never cached. The stamp names the tree a reviewer cites (`docs/TEAM.md` review loop). Nothing
     prunes the stamps: `rm -rf ~/.cache/<slug>-validate` clears them, and so does a container
     rebuild (`~/.cache` is not a mount). A CI run, where a game adds one, passes `--fresh` (or
     sets `VALIDATE_CACHE_DIR` to a scratch directory) so it never trusts a stamp;
   - is pre-authorized in `.claude/settings.json`, so it never trips a permission prompt.
2. **After ANY task that modifies code, run `./validate.sh all` and make it green before
   considering the work done.** Do not skip this step. Fix every failure before moving on.
   This applies to direct work AND delegated work (teams, agents).
3. **If `./validate.sh` does not support what you need** (a flag, a scope, an output mode),
   **STOP and extend the script (or prompt the user to)** — never route around it with a raw
   tool invocation.
4. Use the output filters instead of dumping full logs: `-tN` (tail), `-hN` (head),
   `-G PATTERN` (grep), `-- extra-args` (passthrough). Example: `./validate.sh test -G 'fail'`.
   `--fresh` re-runs regardless of the result cache.

```text
./validate.sh test         # unit tier with coverage thresholds
./validate.sh integration  # *.integration.test.ts / *.integration.spec.ts tier (opt-in)
./validate.sh typecheck    # type check all packages (rebuilds shared first)
./validate.sh lint         # eslint + prettier --check + disable-directive / TODO audit + docs/INDEX.md freshness
./validate.sh duplication  # jscpd (.jscpd.json)
./validate.sh all          # lint -> duplication -> typecheck -> test; prints ALL PASSED / FAILED: <phases>
./validate.sh all --fresh  # same, ignoring the result cache (a green run is still stamped)
```

---

## 2. Testing Standards

### 2.1 Every change is tested

1. **All new logic must have unit tests.** When you add or modify any non-trivial logic
   (functions, classes, reducers, state machines, message handlers, math, generation),
   extract it into **pure, testable functions** and write tests covering the **happy path,
   edge cases, and error cases**.
2. The lever that makes this possible: **pull logic out of orchestrators/loops into pure
   functions** so it can be tested without a server, socket, or browser. A state transition
   should be expressible as `transition(state, input) -> { nextState, effects }`. **This is
   about testability, not banning OOP** — see §4.5: use classes for stateful things; just keep
   the decision logic in pure, callable functions/methods.
3. **Tests live co-located** with the code they test: `*.test.ts` next to the module under
   `packages/*/src` (Angular client uses `*.spec.ts`). Keep the test beside its subject.

### 2.2 Unit vs integration split

| Tier        | Filename suffix                                                                    | Run via                     | In `all`?      |
| ----------- | ---------------------------------------------------------------------------------- | --------------------------- | -------------- |
| Unit        | `*.test.ts` (client `*.spec.ts`)                                                   | `./validate.sh test`        | yes            |
| Integration | `*.integration.test.ts` / `*.integration.spec.ts`                                  | `./validate.sh integration` | **no, opt-in** |
| Gameplay    | `*.gameplay.test.ts` (scenario tables that step a real game module for many ticks) | `./validate.sh integration` | **no, opt-in** |

1. **Write a unit test when** the change is a single pure function, class, or module in
   isolation — no cross-subsystem orchestration, runs in <100ms. This is almost everything.
2. **Write an integration test when** the change wires two or more subsystems together and
   the value of the test is proving the wire (e.g. input → reduce → snapshot round-trip;
   lobby → room → broadcast; save → load → replay).
3. **Keep `./validate.sh all` fast (target under ~20s)** so it can run on every save. Do NOT
   dump slow or cross-subsystem setup into a `*.test.ts` to dodge writing an integration
   test — **rename the file to `*.integration.test.ts` instead.**
4. Integration tests are selected by each package's `test:integration` script
   (`RUN_INTEGRATION=1` for vitest via the shared `vitest.tiers.ts`; the client's
   `test-integration` target behind `test-integration.sh`, which skips the run when no
   `*.integration.spec.ts` exists because the Angular builder fails on an empty include): the
   default `include` excludes `*.integration.*`, the integration run includes only them, with
   `passWithNoTests` so a package without any still passes. Run them only at the **end of a task that may have caused a cross-subsystem
   regression** — never on every save or pre-commit.
5. `./validate.sh integration` is that run (`pnpm -r --if-present test:integration`); never
   invoke vitest or `ng test` directly. The same run executes the gameplay scenarios
   (`*.gameplay.test.ts`): they step a real module for thousands of ticks, which is
   integration-tier cost even though nothing crosses a socket.

### 2.3 What must be covered (template-specific)

- **Shared logic / math / data:** any pure helper, id/branding utilities, config.
- **The reducer (`reduceGameState`) and `submitInput`:** valid input produces the expected
  state + snapshot; invalid input is rejected/ignored. For reducers that return new state (lobby
  and room descriptors, the client store) assert **immutability**
  (`expect(result).not.toBe(prevState)` when state changes). A game simulation that mutates its
  world state in place by design (say so in the game's architecture doc) asserts values and
  state hashes in its tests, never object identity.
- **Message handling / envelope validation (`message-schemas.ts`, `message-router.ts`):**
  each verb routes to the right handler; **invalid JSON, invalid schema, and removed/unknown
  message types produce error responses** — the validation itself is under test.
- **Lobby / room / session lifecycle:** create/join/start/delete, late-join, disconnect grace.
- **The debug MCP tools:** the shared result builders (`mcp/tool-result.ts`, `mcp/active-room.ts`)
  are unit-tested; a game's own tools are invoked directly in a unit test and their JSON
  asserted; the `/debug-mcp` mount itself is an integration test.
- **Architecture invariants as executable tests** (optional but encouraged): a test that
  scans `src` for banned patterns and fails the build if they reappear. Guard the guard
  (`expect(files.length).toBeGreaterThan(N)`) so it can't silently scan nothing.

### 2.4 Determinism

1. **No `Math.random()` in shared / simulation / reducer code.** Use a seeded PRNG so the
   simulation is reproducible and tests can assert exact outputs.
2. Keep the reducer a pure function of `(state, inputs, defs)`; content/config (`GameDefs`,
   `GameSessionConfig`) is a **parameter, never a hidden singleton**.

---

### 2.5 Coverage floors

Each package declares the coverage it achieves today — `COVERAGE_THRESHOLDS` in
`packages/*/vitest.config.ts`, `coverageThresholds` in `packages/client/angular.json` — and
`./validate.sh test` fails when a run drops below it. Floors only move up: raise them when a
PR lifts coverage, never lower them to land one. Coverage excludes tests, barrels and the test
doubles under `src/testing/` (`vitest.tiers.ts`).

---

## 3. TypeScript & Lint Strictness

### 3.1 Required tsconfig flags (already set in `tsconfig.base.json`)

```jsonc
"strict": true,
"noUncheckedIndexedAccess": true,
"noUnusedLocals": true,
"noUnusedParameters": true,
"verbatimModuleSyntax": true,
"isolatedModules": true,
"forceConsistentCasingInFileNames": true,
"module": "ESNext", "moduleResolution": "bundler", "target": "ES2022"
```

Do not weaken these. Per-package `composite`/`declaration`/`declarationMap` stay on for
project references.

### 3.2 Lint / format rules

- `@typescript-eslint/no-unused-vars: 'error'` with `argsIgnorePattern: '^_'`. A leading `_`
  means "intentionally unused" — it is **not** a license to leave a stub instead of real code.
- `@typescript-eslint/no-explicit-any` is a warning; treat it as a rule. **No `any`** — use
  `unknown` plus a type guard / Zod parse at the boundary, then a narrow type inward.
- The §3.3 and §4 rules belong in lint (`eslint.config.js`; `eslint-plugin-sonarjs` and
  `eslint-plugin-unicorn` ship as devDependencies for it): `no-magic-numbers`, the size
  limits, `id-length` + `unicorn/name-replacements` with the game's allow-list,
  `@typescript-eslint/naming-convention` (predicate booleans need type information, so
  `packages/*/src` is linted with `projectService`), `sonarjs` complexity / duplication, the
  determinism bans, `no-console`, `unicorn/filename-case`.
- angular-eslint component rules apply in `packages/client` (selector prefix, etc.).
- Prettier (already configured): 2-space indent, single quotes, trailing commas, semicolons,
  **120-char width**. Lint ignores `dist/`, `node_modules/`, build caches, and prose dirs.

### 3.3 Forbidden escape hatches

- **No `as any`, no `// @ts-ignore`, no `// @ts-expect-error`, no inline `eslint-disable`**
  without a justification. For `eslint-disable` the justification goes on the directive itself
  (`// eslint-disable-next-line rule -- why this is safe`); `./validate.sh lint` counts the
  directives and fails on one without a `-- reason`.
- **No magic strings or magic numbers.** Use named constants, `as const` id objects, or
  string-literal union types for any repeated or non-obvious literal — message verbs, ids, and
  modes, AND numeric tunables (tick rates, sizes, thresholds, costs, timeouts, durations). A
  bare `0.92` or `300` sitting in logic is a magic number; give it a named constant.
- **No `console.log` in committed code.** Remove debug logging before validating.
- **No duplicated logic.** Five or more identical lines (50 tokens) in two places is a clone;
  extract the helper. `./validate.sh duplication` enforces it outside tests and test doubles.
- **A `TODO` carries a ticket:** `TODO(#N)`. `TODO(game)` / `TODO(init)` mark the template's
  extension points and are the only exceptions; `./validate.sh lint` fails on any other `TODO`.

---

## 4. Architecture Conventions (enforce on every change)

1. **`packages/shared` stays pure** — zero side effects, no framework/DOM/Node-only APIs, no
   imports from `server` or `client`. It is the only code both sides may import. Shared types
   live here.
2. **Server authority for the values that must be owned.** The trust model is LOCAL-ONLY, so
   the client may compute most things for responsiveness — but any value the server must own
   (score, lives, win/lose, collisions, spawns) is computed in `reduceGameState` and merged
   into the snapshot. The client renders snapshots; it never invents authoritative state.
3. **Validate at the boundary.** Every inbound WebSocket message is parsed/validated in
   `message-schemas.ts` (Zod) before any handler trusts it. When the game defines a real
   `GameInput`, replace the `z.unknown()` payload with a real schema. Trust internal code;
   never trust external input.
4. **One code path per operation.** If an action can be triggered from the UI, a key, or MCP,
   all paths call the same function. No duplicated logic — extract the shared path.
5. **Pure core, IO edge.** Reducers/state machines are pure functions communicating through
   explicit parameters and return values. State flows down (as args), results flow up (as
   returns); modules do not reach up to mutate parent state. **This is not a ban on OOP** —
   classes are encouraged for genuinely stateful, encapsulated things (the WS connection, a
   render container, entity instances). The rule is that _decision logic_ (how state changes)
   lives in pure, testable functions/methods, not buried in IO or the render loop. Prefer
   composition over deep inheritance, but inheritance is fine for a real "is-a" relationship.
6. **Module size & shape.** Keep modules focused — one responsibility each. Sizes: 300 lines
   per file, 40 per function, complexity 10, 4 parameters, nesting 3 (design target ≈ 250
   lines per file), lint-enforced where
   `eslint.config.js` enables the caps and reviewed by hand otherwise; a template-owned file
   over a cap carries a documented exemption. Split
   along a responsibility seam — never delete, inline, or compress working code just to push a
   line count down. Orchestrators (the room loop, the game loop) stay thin — a sequence of calls
   to focused subsystems, not a place for business logic.
7. **No circular dependencies.** Imports form a DAG; shared types go in a common module both
   sides import.
8. **Diagrams are ASCII only**, inside a plain code block, ≤~70 columns, one concept each. No
   Mermaid (the CLI cannot render it).

---

## 5. Forbidden Shortcuts / Anti-Patterns (reject on sight)

1. Running raw tools (`pnpm test`, `npx tsc`, `pnpm eslint`, `pnpm --filter ... exec vitest`)
   instead of `./validate.sh`.
2. Declaring work done without `./validate.sh all` green. Committing red. Moving on with
   failures.
3. `.skip`-ing, `.only`-ing, deleting, or weakening a test to get a green run. (Deleting an
   architecture-guard test is exactly the regression those guards exist to catch.)
4. Dumping slow / cross-subsystem setup into a `*.test.ts` to avoid an `*.integration.test.ts`
   — rename the file instead.
5. `as any` / `any` / `@ts-ignore` / `@ts-expect-error` / inline `eslint-disable` without a
   justifying comment. Reaching for `unknown`-less casts at boundaries.
6. The client inventing authoritative state, or computing server-owned values locally and not
   reconciling with the snapshot.
7. Unvalidated message handling — trusting a WS payload without parsing it through the schema.
8. Config defaults/fallbacks silently papering over missing required config. Throw on missing
   required config instead of guessing.
9. `Math.random()` in shared/simulation code.
10. Magic strings or magic numbers — duplicated/unexplained literals instead of named constants
    or `as const` id objects.
11. God files / fat orchestrators — **multi-responsibility** modules or business logic in the
    main loop (the smell is mixed responsibilities, not the raw line count), and circular
    imports.
12. Routing around `validate.sh` / `run.sh` when they misbehave — fix the script or prompt the
    user to extend it.
13. `console.log` left in committed code.
14. Deferring agreed-upon work to a vague "follow-up" without asking. Once you agreed to do it,
    do it.

---

## 6. Definition of Done (checklist — ALL must hold)

- [ ] New/changed logic is extracted into pure functions and has unit tests covering happy
      path, edge cases, and error cases.
- [ ] Cross-subsystem wiring (if any) has a `*.integration.test.ts` and it passes via
      `./validate.sh integration`; coverage floors (§2.5) did not go down.
- [ ] `./validate.sh all` is green (lint + duplication + typecheck + unit tests). No test was skipped,
      `.only`-ed, deleted, or weakened to achieve it.
- [ ] No `any` / `@ts-ignore` / `@ts-expect-error` / inline `eslint-disable` without a
      justifying comment. No new magic strings or magic numbers. No `console.log` left behind.
- [ ] Inbound messages are validated at the boundary; server-owned values are computed in the
      reducer and merged into the snapshot.
- [ ] No module took on a second responsibility; sizes within §4.6 (split along a seam, never
      compress working code); orchestrators stayed thin; no circular imports introduced.
- [ ] §3.3 holds: no magic values, no duplicated logic, full descriptive names, every `TODO`
      ticketed; the game's own standards docs (code standards, determinism, architecture), where
      it has them, hold too.
- [ ] No `Math.random()` in shared/simulation code.
- [ ] Any visual asset added meets `docs/ASSET-GENERATION.md`'s acceptance criteria.
- [ ] Any audio asset added went through `docs/AUDIO-PIPELINE.md` (`./ai-pipeline.sh check` clean).
- [ ] Every task you agreed to is actually done — nothing silently punted.
