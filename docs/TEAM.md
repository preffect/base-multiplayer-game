# The agent team

How work on this game is done by a team of AI agents, each running **inside the devcontainer**
as one role, coordinated through GitHub tickets and pull requests (process rules: `docs/WORKFLOW.md`;
quality bar: `docs/ENGINEERING.md`). The human's only job is answering the tickets assigned to them.

## Roles

| Role              | Owns                                                                  | Prompt                                |
| ----------------- | --------------------------------------------------------------------- | ------------------------------------- |
| team-lead         | Planning, tickets, epics, sequencing, running the scripts below       | the interactive session               |
| architect         | Structure, contracts, where constants live, design + code review      | `.claude/agents/architect.md`         |
| engineer          | Implementation with unit + integration tests, review fixes            | `.claude/agents/engineer.md`          |
| game-designer     | Game design document, rules, numbers, progression, balance, scenarios | `.claude/agents/game-designer.md`     |
| graphics-designer | Style guide, palette, motion, code-drawn visuals                      | `.claude/agents/graphics-designer.md` |
| ui-designer       | HUD, overlays, onboarding, information design                         | `.claude/agents/ui-designer.md`       |
| audio-designer    | Sound event catalogue, asset manifest, audio hooks                    | `.claude/agents/audio-designer.md`    |
| perf-engineer     | Simulation and render budgets, measurements                           | `.claude/agents/perf-engineer.md`     |
| devops            | Devcontainer, scripts, CI, GitHub plumbing (template first)           | `.claude/agents/devops.md`            |
| code-qa           | PR review against the engineering standards                           | `.claude/agents/code-qa.md`           |
| gameplay-qa       | Rules/balance verification, scenarios, bots, play sessions            | `.claude/agents/gameplay-qa.md`       |
| graphics-qa       | Visual verification with screenshots, baselines, frame-time checks    | `.claude/agents/graphics-qa.md`       |

`.claude/roles/_common.md` is prepended to every prompt: ground rules, git/PR mechanics, how to
finish. `.claude/commands/team.md` is the interactive variant (`/team`) for a session opened
inside the container: it spawns the same role files as teammates of one session (messages instead
of GitHub threads) and uses no role vocabulary of its own.

## Running an agent

The roles are Claude Code agent definitions in `.claude/agents/<role>.md`, so **inside the
devcontainer the team lead spawns them with the Agent tool** (`subagent_type: "<role>"`), where
they show up in the interface with live progress and can be messaged while running. Give each one
its assignment (ticket, branch, working directory) in the prompt; the definition already tells it
to read `.claude/roles/_common.md` (the shared ground rules) first.

```bash
scripts/worktree.sh add feat/42-food-ecology      # a branch of its own for a parallel agent
scripts/worktree.sh remove feat/42-food-ecology
```

Outside the container (a host session, cron, CI) the same definitions run headlessly:

```bash
scripts/agent.sh engineer --ticket 42 --branch feat/42-food-ecology "Implement #42 per docs/GAME-DESIGN.md"
scripts/agent.sh code-qa --pr 57 --branch feat/42-food-ecology "Review PR #57"
```

- `scripts/agent.sh` execs into the `<folder>-dev` container as its user (`scripts/lib/identity.sh`)
  and logs to `.qa/agents/<timestamp>-<role>[-pr<N>]-<pid>.prompt.md` / `.log` (git-ignored).
- A worktree per branch (`.worktrees/<branch>`, `scripts/worktree.sh`) lets several agents run in
  parallel without touching each other's files; the main checkout stays free for running the game
  (`./run.sh`) during QA. An existing local branch is reused untouched; an existing worktree is
  fast-forwarded to `origin/<branch>` so reviewers see what the author pushed (dirty or diverged
  stops the run).
- **At most three agents at once.** They share one GitHub account and one 4-core container.
  GitHub's GraphQL budget is 5,000 points an hour (a query's cost grows with the nested lists it
  asks for) plus ~80 content-creating calls a minute, so every helper fetches only what it needs
  and writes in one request (`scripts/pr-threads.sh`, `scripts/issue-status.sh`, `scripts/project-sync.sh`).

## Landing a PR: the review loop

In session (Agent tool): spawn each reviewer role with the PR in its prompt, read
`scripts/pr-threads.sh state <PR>` (one 1-point query: latest verdict per role + unresolved
threads), spawn an engineer for the fixes, re-spawn the objecting reviewers, then
`gh pr merge --squash --auto`. Headless, the same loop is scripted:

```bash
scripts/land-pr.sh 57 --reviewers "architect gameplay-qa"    # code-qa is always added
```

1. Each reviewer role reviews in turn and posts one review whose first line is its verdict
   (`<role> verdict: APPROVE` or `REQUEST_CHANGES`) with line-anchored comments.
2. If anyone objects, or any thread (including Copilot's) is unresolved, an engineer run fixes,
   replies on every thread and merges `origin/main` into the branch (no rebase: it would mark every
   thread outdated); the objecting roles (and code-qa while any thread is open) re-review and
   resolve what is fixed. Authors never resolve their own threads.
3. When every reviewer's latest verdict is APPROVE and no thread is open, auto-merge is armed
   (squash; the `pr-links-issue` check still has to pass). At most three rounds; a reviewer or
   engineer run that fails is reported and counts as a round; otherwise the script exits non-zero
   with the PR state and the team lead decides.

**Who reviews what** (this table is the home of the rule; `docs/WORKFLOW.md` section 6 points here):

| PR touches                                                           | Reviewers                 |
| -------------------------------------------------------------------- | ------------------------- |
| anything                                                             | code-qa                   |
| `packages/shared`, the simulation, networking, a new module boundary | + architect               |
| rules, balance values, progression                                   | + gameplay-qa             |
| anything visible                                                     | + graphics-qa             |
| design-only (docs)                                                   | architect + the domain QA |

**The design gate.** Architect and engineer must agree before coding. In the headless flow that
agreement is a PR: the architect run lands the ticket's section of `docs/ARCHITECTURE.md` through
`land-pr.sh` before `scripts/agent.sh engineer --ticket N` starts, and the engineer run follows it
(disagreement = fix the doc in the same PR and say so, per its role, never silent deviation).

## Handoffs and artifacts

| Stage        | Produces                                                                                                                                                         | Consumed by            |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- |
| Design       | `docs/GAME-DESIGN.md`, `docs/TRAITS.md`, `docs/VISUAL-STYLE.md`, `docs/UI.md`, `docs/AUDIO.md`; balance values as constants in `packages/shared/src/constants/*` | architect, engineer    |
| Architecture | `docs/ARCHITECTURE.md` (contracts, file plan, test plan)                                                                                                         | engineer, reviewers    |
| Build        | code + tests + docs in one PR, `Closes #N`                                                                                                                       | reviewers              |
| Review       | review threads, verdicts, `qa/evidence/<pr>/` screenshots, updated `qa/baselines/` (graphics-qa only)                                                            | engineer, team lead    |
| Verify       | gameplay scenarios, bot runs, screenshots diffed against `qa/baselines/`                                                                                         | team lead, next design |

These names supersede the ones in ticket #18: balance lives with the other constants (`data/` is
git-ignored runtime state, so `data/balance.json` cannot be a reviewed artifact), and the design
document is `docs/GAME-DESIGN.md` as the design tickets name it.

## Definition of Done (per ticket)

`docs/ENGINEERING.md` Definition of Done, plus: the PR closed the ticket, every review thread is
resolved, docs describing the behaviour were updated in the same PR, and (for anything visible or
playable) the PR carries evidence from graphics-qa or gameplay-qa.
