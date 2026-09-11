# Workflow — GitHub issues, project board, reviews

The single source of truth for **how work is tracked and merged** in a game built from this
template. `CLAUDE.md`, `docs/INIT-GAME.md`, the seeded GitHub issues, and every agent role
prompt point here instead of restating these rules. Everything below is done through the
GitHub API (`gh`, GraphQL) by scripts or agents — **the human never has to click in GitHub's UI.**

## 1. Where things live

| What                                | Where                                                                                        |
| ----------------------------------- | -------------------------------------------------------------------------------------------- |
| Tickets, labels, milestones         | The game's GitHub repo, **Issues** tab                                                       |
| Stage of each ticket (the board)    | The GitHub **Project** linked to the repo (shows under the repo's **Projects** tab)          |
| Epic → ticket hierarchy             | Native **sub-issues** (epics show a progress bar; closing a child updates the parent)        |
| "Waiting on me" list for the human  | `https://github.com/issues/assigned` — anything **assigned to the human** is waiting on them |
| Project identifiers used by scripts | `.github/project.env` (written by `scripts/github-setup.sh`)                                 |

GitHub stores Projects under the user/org, not inside the repo; the project is _linked_ to the
repo so it appears in the repo's Projects tab and only holds this repo's issues.

Repo-level "saved issue views" are **not API-editable** — do not use them; the Project views
cover the same need.

## 2. Labels (category), Status (stage), assignee (ball in court)

- **Labels say what and who.** `area:*` (devcontainer, tooling-mcp, team, quality, testing,
  design, architecture, gameplay, graphics, networking, ui, audio, qa, docs), `role:*` (the
  agent role that owns it), `priority:p0|p1|p2`, `epic`, `roadmap`, `needs-decision`, `pending`.
- **Project Status says where it is.** `Backlog → Ready → In progress → In review → Done`,
  plus `Blocked`. Status is the _only_ stage field — no `status:*` labels.
- **Assignee means "waiting on a human".** Agents are not GitHub users, so the assignee field
  is reserved: assign the human when, and only when, a ticket needs their decision, credential,
  or approval.

**Waiting-on-human rule.** When an agent needs the human it (1) adds `pending`, (2) assigns
the human, (3) sets Status `Blocked`, (4) states the exact question in a comment. `@mention` the
human only when the question blocks active work. When the human answers, the agent removes the
label, unassigns, records the decision in a comment, and moves Status back.

**Label hygiene.** Update labels as you go: remove `pending` / `needs-decision` the moment a
decision is applied; close the ticket when it is done; never leave a closed ticket carrying
`pending`. The sync script (below) keeps Status consistent, not labels.

## 3. Milestones and epics

- Planning/groundwork phase only: **`M0 Setup`** (devcontainer, tooling/MCP, team, quality
  gates, testing foundations) and **`M1 Design`** (design docs, architecture, build plan).
  Later build phases live in a single `roadmap` issue until the human approves them; they then
  become their own epics. **Epics scope one phase of groundwork, never the whole game.**
- Epics carry the `epic` label and own their tickets as sub-issues. Every ticket body starts
  with `**Epic:** #N`.
- **One subsystem per ticket.** A ticket names one subsystem, and its PR is readable in one
  sitting: about 40 files at most, tests included. A title that lists several subsystems
  ("world, ecology, movement, growth, …") is an epic, not a ticket: give it the `epic` label and
  split it into sub-issues before anyone starts. The lead checks size before spawning and splits
  first; a build agent that finds its ticket bigger than this stops and reports instead of
  building. Why: one 175-file ticket cost three review rounds, two agents lost at the usage limit
  and several usage windows; five 40-file tickets would have landed one at a time.

## 4. Keeping the board in sync (no UI workflows)

The Project's UI-only automations (auto-add, auto-close) are replaced by
`scripts/project-sync.sh`, which is idempotent and safe to run any time:

1. every issue is on the project (new ones get `Backlog` / `Blocked` / `Done` as they are added);
2. closed → `Done`; open + `pending` → `Blocked`; `Blocked` without `pending` → `Backlog`;
3. items in `Ready` / `In progress` / `In review` are never touched.

The team lead runs it at the start of every session and after closing issues. Agents move a
ticket between stages with `gh project item-edit` (ids in `.github/project.env`).

## 5. Branch and PR rules

**Every piece of work starts as a ticket — no exceptions, including template and tooling work.**
Create the issue first (or pick one up), work on a branch named after it, and put `Closes #N` in
the PR body. Work on a different repository gets its own Project and its own tickets there
(`scripts/github-setup.sh --no-seed` for repos that are not games); never track one repo's work
in another repo's board.

Applied as a **ruleset** on the default branch by `scripts/github-setup.sh`:

- a pull request is required — no direct pushes, no force pushes, no branch deletion;
- **the `pr-links-issue` status check must pass** — `.github/workflows/pr-links-issue.yml` fails
  any PR whose body has no `Closes #N` / `Fixes #N` / `Resolves #N`, so a PR without a ticket
  cannot be merged (this is the hard enforcement of the rule above);
- **every review thread must be resolved before merge**;
- stale approvals are dismissed on new commits;
- the `validate` (CI) and `code-review` (reviewer agent) checks are added **only once those
  checks exist** — requiring a check that never reports blocks every merge.

All agents act as the human's GitHub account (mounted `~/.config/gh`; git pushes over HTTPS
with `gh` as the credential helper, set up by `.devcontainer/post-create.sh`), so GitHub cannot
enforce "reviewer ≠ author". Reviews are therefore procedural (below) plus the `code-review`
status.

## 6. Review process (every PR)

1. **Design review** (architect) before code: approach, file plan, interfaces, where constants
   and config live, test plan.
2. **Code review** against the checklist in `.github/PULL_REQUEST_TEMPLATE.md`. Findings are
   **line-anchored PR review comments**; reviewers request changes rather than fixing silently.
3. **Domain review** where the change is playable or visible (with screenshots for visuals).
   Which roles review which PR is the table in `docs/TEAM.md`.
4. The author fixes, **replies on every thread** saying what changed, and the reviewer resolves
   after verifying. The author never resolves their own threads.
5. Merge only with `./validate.sh all` output in the PR, all threads resolved, all checks green.
   The author never merges their own PR when a reviewer role exists.

**Docs stay in sync.** Any PR that changes behaviour, scripts, tooling, or process updates the
docs that describe it in the same PR — `README.md`, `CLAUDE.md`, `docs/WORKFLOW.md`, `docs/ENGINEERING.md`,
`.devcontainer/*` comments — and keeps them consistent with each other
(one fact, one home; the others link to it). A reviewer rejects a PR whose docs drift. Fixes that
belong to the template are upstreamed to `base-multiplayer-game` so the next game inherits them. <!-- KEEP_TEMPLATE_NAME -->

The reviewer table and the scripted review loop that runs these steps with the agent team
(`scripts/land-pr.sh`) are in `docs/TEAM.md`.

Branch names: `feat/<issue>-<slug>` / `fix/<issue>-<slug>`; PR body contains `Closes #N`.
Graphics PRs attach before/after screenshots; gameplay PRs list the balance values touched.

## 7. Scripts

| Script                           | Runs on   | Purpose                                                                                                                                                                                    |
| -------------------------------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `scripts/github-setup.sh`        | host      | Create/push the repo, labels, milestones, Project + views, ruleset, seed groundwork epics.                                                                                                 |
| `scripts/project-sync.sh`        | host/cont | Reconcile issues ↔ board (section 4).                                                                                                                                                      |
| `scripts/issue-status.sh`        | host/cont | `issue-status.sh <Status> <N> [N...]` — move tickets to a Status in two API calls.                                                                                                         |
| `scripts/pr-threads.sh`          | host/cont | `pr-threads.sh list\|unresolved\|state <PR>`; `reply <PR> actions.json` — read, summarise, and answer/resolve review threads in one request each.                                          |
| `scripts/agent.sh`               | host/cont | `agent.sh <role> [--ticket N] [--branch B] "<task>"` — run one team role headlessly inside the devcontainer (`docs/TEAM.md`).                                                              |
| `scripts/worktree.sh`            | host/cont | `worktree.sh add\|remove <branch>` — one git worktree per branch under `.worktrees/` for parallel agents (`docs/TEAM.md`).                                                                 |
| `scripts/land-pr.sh`             | host/cont | `land-pr.sh <PR> [--reviewers "roles"]` — reviewer roles review, engineer fixes, re-review, then auto-merge (`docs/TEAM.md`).                                                              |
| `scripts/resume-in-container.sh` | host/cont | Copy a Claude Code transcript under the other side's project key so `claude --resume <id>` continues the same conversation inside the devcontainer (or back on the host).                  |
| `scripts/sync-from-template.sh`  | host/cont | Pull template-owned files (scripts, devcontainer, process docs) from `base-multiplayer-game` into this game, re-applying its identity; land the diff via a PR. <!-- KEEP_TEMPLATE_NAME --> |

`gh` needs the `repo` and `project` scopes (`gh auth refresh -h github.com -s project,read:project`).
