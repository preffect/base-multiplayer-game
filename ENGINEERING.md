# Engineering Standards

These are **enforceable rules**, not suggestions. They are written in the imperative and
each is checkable. An AI building a game from this template MUST follow every rule here.
"It compiles" and "it renders" are never sufficient — the gate below is.

> **THE GATE:** `./validate.sh all` (lint + typecheck + test) is the single source of truth
> for whether work is done. No task is complete until it is green. Never commit red.

---

## 1. The Validation Gate (`./validate.sh`)

1. **Always use `./validate.sh`. Never run the underlying tools directly.** Do not reach for
   `pnpm -r test`, `pnpm test`, `pnpm typecheck`, `npx tsc`, `pnpm eslint`, `pnpm prettier`,
   or `pnpm --filter ... exec vitest` as a shortcut. The wrapper:
   - pre-builds `@base-multiplayer-game/shared` before typecheck (`build_shared`) so downstream
     `.d.ts` project references are fresh — running `tsc` directly gives stale/false results;
   - runs **eslint AND prettier `--check` as a pair** — running only eslint silently misses
     formatting failures;
   - is pre-authorized in `.claude/settings.json`, so it never trips a permission prompt.
2. **After ANY task that modifies code, run `./validate.sh all` and make it green before
   considering the work done.** Do not skip this step. Fix every failure before moving on.
   This applies to direct work AND delegated work (teams, agents).
3. **If `./validate.sh` does not support what you need** (a flag, a scope, an output mode, an
   `integration` subcommand), **STOP and extend the script (or prompt the user to)** — never
   route around it with a raw tool invocation.
4. Use the output filters instead of dumping full logs: `-tN` (tail), `-hN` (head),
   `-G PATTERN` (grep), `-- extra-args` (passthrough). Example: `./validate.sh test -G 'fail'`.

```text
./validate.sh test        # all unit tests
./validate.sh typecheck   # type check all packages (rebuilds shared first)
./validate.sh lint        # eslint + prettier --check
./validate.sh all         # lint -> typecheck -> test; prints ALL PASSED / FAILED: <phases>
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

| Tier        | Filename suffix                                   | Run via                     | In `all`?      |
| ----------- | ------------------------------------------------- | --------------------------- | -------------- |
| Unit        | `*.test.ts` (client `*.spec.ts`)                  | `./validate.sh test`        | yes            |
| Integration | `*.integration.test.ts` / `*.integration.spec.ts` | `./validate.sh integration` | **no, opt-in** |

1. **Write a unit test when** the change is a single pure function, class, or module in
   isolation — no cross-subsystem orchestration, runs in <100ms. This is almost everything.
2. **Write an integration test when** the change wires two or more subsystems together and
   the value of the test is proving the wire (e.g. input → reduce → snapshot round-trip;
   lobby → room → broadcast; save → load → replay).
3. **Keep `./validate.sh all` fast (target under ~20s)** so it can run on every save. Do NOT
   dump slow or cross-subsystem setup into a `*.test.ts` to dodge writing an integration
   test — **rename the file to `*.integration.test.ts` instead.**
4. Integration tests are gated by a `RUN_INTEGRATION` env var in each package's
   `vitest.config.ts` (default `include` excludes `*.integration.test.ts`; `RUN_INTEGRATION=1`
   flips to include them with `passWithNoTests: true`). Run them only at the **end of a task
   that may have caused a cross-subsystem regression** — never on every save or pre-commit.
5. **When the game first introduces integration tests, add an `integration` subcommand to
   `./validate.sh`** (set `RUN_INTEGRATION=1`, run `pnpm -r test`) rather than running vitest
   directly. This is the one expected extension of the gate.

### 2.3 What must be covered (template-specific)

- **Shared logic / math / data:** any pure helper, id/branding utilities, config.
- **The reducer (`reduceGameState`) and `submitInput`:** valid input produces a new state +
  expected snapshot; invalid input is rejected/ignored; assert **immutability**
  (`expect(result).not.toBe(prevState)` when state changes).
- **Message handling / envelope validation (`message-schemas.ts`, `message-router.ts`):**
  each verb routes to the right handler; **invalid JSON, invalid schema, and removed/unknown
  message types produce error responses** — the validation itself is under test.
- **Lobby / room / session lifecycle:** create/join/start/delete, late-join, disconnect grace.
- **Architecture invariants as executable tests** (optional but encouraged): a test that
  scans `src` for banned patterns and fails the build if they reappear. Guard the guard
  (`expect(files.length).toBeGreaterThan(N)`) so it can't silently scan nothing.

### 2.4 Determinism

1. **No `Math.random()` in shared / simulation / reducer code.** Use a seeded PRNG so the
   simulation is reproducible and tests can assert exact outputs.
2. Keep the reducer a pure function of `(state, inputs, defs)`; content/config (`GameDefs`,
   `GameSessionConfig`) is a **parameter, never a hidden singleton**.

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
- angular-eslint component rules apply in `packages/client` (selector prefix, etc.).
- Prettier (already configured): 2-space indent, single quotes, trailing commas, semicolons,
  **120-char width**. Lint ignores `dist/`, `node_modules/`, build caches, and prose dirs.

### 3.3 Forbidden escape hatches

- **No `as any`, no `// @ts-ignore`, no `// @ts-expect-error`, no inline `eslint-disable`**
  without a comment on the same or preceding line justifying exactly why and what makes it safe.
- **No magic strings or magic numbers.** Use named constants, `as const` id objects, or
  string-literal union types for any repeated or non-obvious literal — message verbs, ids, and
  modes, AND numeric tunables (tick rates, sizes, thresholds, costs, timeouts, durations). A
  bare `0.92` or `300` sitting in logic is a magic number; give it a named constant.
- **No `console.log` in committed code.** Remove debug logging before validating.

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
6. **Module size & shape.** Keep modules focused — one responsibility each. **~400 lines is a
   review smell, not a hard limit:** crossing it is a signal to check whether the file has taken
   on a second responsibility and should be split along that seam. It is **not** a number to
   game — never delete, inline, or compress working code just to push a line count down. A
   cohesive 450-line module beats five artificially-split fragments. Orchestrators (the room
   loop, the game loop) stay thin — a sequence of calls to focused subsystems, not a place for
   business logic.
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
      `./validate.sh integration`.
- [ ] `./validate.sh all` is green (lint + typecheck + unit tests). No test was skipped,
      `.only`-ed, deleted, or weakened to achieve it.
- [ ] No `any` / `@ts-ignore` / `@ts-expect-error` / inline `eslint-disable` without a
      justifying comment. No new magic strings or magic numbers. No `console.log` left behind.
- [ ] Inbound messages are validated at the boundary; server-owned values are computed in the
      reducer and merged into the snapshot.
- [ ] No module took on a second responsibility (≈400 lines is a smell to check, not a hard cap
      — never compress working code just to hit it); orchestrators stayed thin; no circular
      imports introduced.
- [ ] No `Math.random()` in shared/simulation code.
- [ ] Any visual asset added meets `ASSET-GENERATION.md`'s acceptance criteria.
- [ ] Any audio asset added went through `AUDIO-PIPELINE.md` (`./ai-pipeline.sh check` clean).
- [ ] Every task you agreed to is actually done — nothing silently punted.
