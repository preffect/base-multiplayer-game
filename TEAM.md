# The agent team

How work on this game is done by a team of AI agents, each running **inside the devcontainer**
as one role, coordinated through GitHub tickets and pull requests (process rules: `WORKFLOW.md`;
quality bar: `ENGINEERING.md`). The human's only job is answering the tickets assigned to them.

## Roles

| Role                | Owns                                                                 | Prompt                              |
| ------------------- | -------------------------------------------------------------------- | ----------------------------------- |
| team-lead           | Planning, tickets, epics, sequencing, running the scripts below      | the interactive session             |
| architect           | Structure, contracts, where constants live, design + code review     | `.claude/roles/architect.md`        |
| engineer            | Implementation with unit + integration tests, review fixes           | `.claude/roles/engineer.md`         |
| game-designer       | GDD, rules, numbers, progression, balance, acceptance scenarios      | `.claude/roles/game-designer.md`    |
| graphics-designer   | Style guide, palette, motion, code-drawn visuals                     | `.claude/roles/graphics-designer.md`|
| ui-designer         | HUD, overlays, onboarding, information design                        | `.claude/roles/ui-designer.md`      |
| audio-designer      | Sound event catalogue, asset manifest, audio hooks                   | `.claude/roles/audio-designer.md`   |
| perf-engineer       | Simulation and render budgets, measurements                          | `.claude/roles/perf-engineer.md`    |
| devops              | Devcontainer, scripts, CI, GitHub plumbing (template first)          | `.claude/roles/devops.md`           |
| code-qa             | PR review against the engineering standards                          | `.claude/roles/code-qa.md`          |
| gameplay-qa         | Rules/balance verification, scenarios, bots, play sessions           | `.claude/roles/gameplay-qa.md`      |
| graphics-qa         | Visual verification with screenshots and frame-time checks           | `.claude/roles/graphics-qa.md`      |

`.claude/roles/_common.md` is prepended to every prompt: ground rules, git/PR mechanics, how to
finish. `.claude/commands/team.md` is the interactive variant (`/team`) for a session opened
inside the container; both use the same role vocabulary.

## Running an agent

```bash
scripts/agent.sh engineer --ticket 42 --branch feat/42-food-ecology "Implement #42 per docs/GDD.md"
scripts/agent.sh code-qa --pr 57 --branch feat/42-food-ecology "Review PR #57"
scripts/agent.sh worktree-remove feat/42-food-ecology
```

- Works from the host (execs into the `<folder>-dev` container) or from inside it.
- `--branch` gives the agent its own git worktree under `.worktrees/`, so several agents run in
  parallel without touching each other's files; the main checkout stays free for running the
  game (`./run.sh`) during QA. Reviewers use the author's branch so they see the real files.
- Every run writes `.qa/agents/<timestamp>-<role>.prompt.md` and `.log` (git-ignored).

## Landing a PR: the review loop

```bash
scripts/land-pr.sh 57 --reviewers "code-qa architect gameplay-qa"
```

1. Each reviewer role reviews in turn and posts one review whose first line is its verdict
   (`<role> verdict: APPROVE` or `REQUEST_CHANGES`) with line-anchored comments.
2. If anyone objects, or any thread (including Copilot's) is unresolved, an engineer run fixes
   and replies on every thread; the objecting roles (and code-qa) re-review and resolve what is
   fixed. Authors never resolve their own threads.
3. When every reviewer's latest verdict is APPROVE and no thread is open, auto-merge is armed
   (squash; the `pr-links-issue` check still has to pass). At most three rounds; otherwise the
   script exits non-zero and the team lead decides.

Which reviewers a PR needs (`WORKFLOW.md` section 6): code-qa always; architect for `shared`,
simulation, networking or any new module boundary; gameplay-qa for rules/balance; graphics-qa
for anything visible. A design-only PR (docs) is reviewed by architect + the relevant domain QA.

## Handoffs and artifacts

| Stage        | Produces                                                        | Consumed by            |
| ------------ | --------------------------------------------------------------- | ---------------------- |
| Design       | `docs/GDD.md`, `docs/TRAITS.md`, `docs/VISUAL-STYLE.md`, `docs/UI.md`, `docs/AUDIO.md` | architect, engineer    |
| Architecture | `docs/ARCHITECTURE.md` (contracts, file plan, test plan)         | engineer, reviewers    |
| Build        | code + tests + docs in one PR, `Closes #N`                       | reviewers              |
| Review       | review threads, verdicts, `qa/evidence/<pr>/` screenshots         | engineer, team lead    |
| Verify       | gameplay scenarios, bot runs, screenshots                        | team lead, next design |

## Definition of Done (per ticket)

`ENGINEERING.md` Definition of Done, plus: the PR closed the ticket, every review thread is
resolved, docs describing the behaviour were updated in the same PR, and (for anything visible or
playable) the PR carries evidence from graphics-qa or gameplay-qa.
