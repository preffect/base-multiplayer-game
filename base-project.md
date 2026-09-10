# Base Multiplayer Game — Template

> **This repo is `base-multiplayer-game`: a working multiplayer game TEMPLATE whose game
> definition is DEFERRED.** The generic plumbing — native-WebSocket transport, stable
> client identity + reconnect, a lobby, rooms, a 60 Hz broadcast loop, MCP game-state
> visibility at `/debug-mcp`, and ha-router integration — is already implemented and runs
> today against a placeholder **echo** game. The actual game logic is left as clearly
> marked `// TODO(game)` / `// TODO(init)` extension points.

## Quick start — initialize a real game

**Entry point: [`docs/INIT-GAME.md`](docs/INIT-GAME.md).** Run it with Claude Code.
It explains every deferred requirement, interviews you about your game, and then GENERATES
`docs/GAME-DESIGN.md` plus a GitHub build epic with tickets — the plan a build team executes to
realize this template into your specific game (planning lives in issues, not files).

### Architecture at a glance

- **Server (Fastify, port 4400):** one instance serves `/api` + `/ws` + `/debug-mcp`.
- **Client (Angular 21, port 4402):** proxies those three paths to the server.
- **Stack:** Node 24, pnpm 10, TypeScript strict, @fastify/websocket, Vitest, ESLint+Prettier.
- **Trust model:** LOCAL-ONLY. Client-side trust where convenient; no anti-cheat.
- **Build environment:** all work — and every helper prompt — assumes the **devcontainer**.
  Open it from the host with `./dev-container.sh`; installs (`pnpm install`, `./run.sh
--install`) and commands (`./validate.sh`, `./run.sh`) run INSIDE the container, never on the host.

### Game extension points (the deferred requirements)

| #   | Decision                                         | Where it lives                                                   |
| --- | ------------------------------------------------ | ---------------------------------------------------------------- |
| 1   | Identity (name, slug, title, icon hue)           | `docs/INIT-GAME.md` interview                                    |
| 2   | Ports (default 4400/4402)                        | `index.ts`, `angular.json`, `proxy.conf.json`, `.mcp.json`, etc. |
| 3   | Player model (max players, avatars/names, teams) | session config + `GameModule`                                    |
| 4   | Tick model (real-time 60 Hz vs turn-based)       | `lobby/game-room.ts` loop                                        |
| 5   | `GameInput` shape                                | `shared/src/types/messages.ts`, `ws/message-schemas.ts`          |
| 6   | `GameSnapshot` + `GameSessionConfig` shapes      | `shared/src/types/messages.ts`                                   |
| 7   | Client-trust boundary (server-owned values)      | `game/game-module.ts` (`reduceGameState`)                        |
| 8   | Server `GameModule` impl + factory wiring        | `server/src/game/game-module.ts`, `index.ts`                     |
| 9   | Persistence (none by default)                    | new server module if needed                                      |
| 10  | MCP game-state visibility                        | `mcp/debug-context.ts` (`getRoomGameState`), `mcp/handlers/*`    |
| 11  | Client rendering (canvas/DOM/Pixi/…)             | `client/src/app/game/game-setup.ts`                              |
| 12  | Session config fields                            | `ws/message-schemas.ts` (`createGameSchema.config`)              |

ha-router route YAML + landing card live as ready-to-copy artifacts under
`ha-router/` (see `ha-router/HA-ROUTER.md`).

---

The rest of this file is the underlying **dev-environment** template documentation (the
devcontainer, Claude config, and standard tooling scaffold this multiplayer template was
built on). It is retained for reference.

## Context

A reusable template for bootstrapping a **dev environment** — specifically a fully configured devcontainer with Claude Code integration, orchestration teams, and standard tooling stubs. All project services (app servers, databases, workers, etc.) run via **Docker Compose inside the devcontainer** using Docker-in-Docker.

**This template sets up the dev environment only, not the product.** The devcontainer, Claude config, and tmux are fully configured and ready to use. The shell scripts (`validate.sh`, `run.sh`, `docker-logs.sh`) are **stubs** with the argument parsing, help text, and structure in place, but with `# TODO` comments where project-specific commands need to be filled in. The AI should not attempt to write production application code — only the dev environment scaffolding.

---

## Instructions for AI: Project Setup Interview

**IMPORTANT: Do NOT start creating files until you have asked the user at least 10 questions and received answers.** This template is generic — you must gather project-specific information before customizing it. Ask these questions conversationally (you can group related ones), and use the answers to fill in placeholders, configure scripts, and tailor the setup.

### Required Questions

1. **Project name** — What is the project called? (Used for container names, image names, package.json name, directory references throughout scripts)
2. **Project description** — Brief description of what the project does (for CLAUDE.md, package.json)
3. **Tech stack** — What language(s) and framework(s) will be used? (e.g. Node/Express, Python/FastAPI, Go, Rust, etc.) This affects the Dockerfile, dependency checks in `run.sh`, `validate.sh` commands, and devcontainer features
4. **Package manager** — If Node: npm, pnpm, yarn, or bun? If Python: pip, poetry, uv? If other: what? (Affects `validate.sh`, `run.sh`, Dockerfile, devcontainer.json)
5. **Services / architecture** — What services will the project run? (e.g. API server, frontend dev server, worker, database, cache, message queue) List each with its expected port. All services run via Docker Compose inside the devcontainer (Docker-in-Docker). This configures `docker-compose.yml` service definitions, `run.sh` commands, `docker-logs.sh` container list, `devcontainer.json` port forwards, and `dev-container.sh` port mappings. **Avoid port 3000** — it's overused by dev tools and frameworks (React, Next.js, Express defaults, etc.), making collisions likely. Recommend ports in the 4000–5999 range instead (e.g. 4000 for API, 5173 for frontend)
6. **Database** — Will the project use a database? Which one? (PostgreSQL, MySQL, MongoDB, SQLite, Redis, etc.) These run as services in the project's `docker-compose.yml`
7. **Testing framework** — What test runner will be used? (vitest, jest, pytest, go test, etc.) This configures `validate.sh` commands
8. **Linter / formatter** — What code quality tools? (Biome, ESLint+Prettier, Ruff, gofmt, rustfmt, etc.) This configures `validate.sh lint` and devcontainer extensions
9. **Type checking** — Is there a separate typecheck step? (e.g. `tsc --noEmit` for TypeScript, `mypy` for Python, or built into the compiler) If not, `validate.sh typecheck` can be removed
10. **Additional devcontainer tools** — Any other tools needed in the container? (e.g. AWS CLI, Terraform, protobuf compiler, FFmpeg, specific system libraries)

### Optional Follow-up Questions (ask based on answers above)

11. **Monorepo or single package?** — If monorepo: what workspace tool? (pnpm workspaces, npm workspaces, Turborepo, Nx) Any cross-package build steps needed before typecheck?
12. **Docker Compose services** — Based on the services listed above, confirm which should be separate Compose services vs. combined. For example: should the API and frontend be separate containers, or one container with both? Any services that need custom Dockerfiles vs. stock images (e.g. `postgres:16`, `redis:7`)?
13. **CI/CD** — Any CI pipeline to consider? (GitHub Actions, GitLab CI, etc.) Should `validate.sh all` match what CI runs?
14. **MCP server** — Does the project expose an API or have runtime state that Claude should be able to inspect? What would be useful? (database queries, API route listing, health checks, cache inspection)
15. **Additional Claude permissions** — Based on the tech stack and tools chosen, ask the user which Bash commands Claude should be pre-authorized to run (e.g. `pnpm`, `npm`, `node`, `docker compose`, `git diff`, `curl`, etc.). Also ask about any domains Claude should be allowed to fetch (documentation sites, API references, package registries). Only add permissions the user explicitly approves.
16. **Git hosting** — GitHub, GitLab, Bitbucket? (for `.gitignore` patterns, CI templates)
17. **Environment variables** — Are there required env vars? Should the template include a `.env.example`?
18. **Hot reload** — Every sub-project/service should have hot reload configured for local development. Ask what hot reload tooling is appropriate for the chosen stack (e.g. `nodemon`, `tsx --watch`, `vite` HMR, `air` for Go, `cargo-watch` for Rust, `uvicorn --reload` for Python). The `run.sh` service start commands should use the hot-reloading variant so code changes are reflected immediately without manual restarts.

### After gathering answers

Use the responses to:

- **Fully configure** the devcontainer (Dockerfile, devcontainer.json, tmux) — these should be complete and working
- **Fully configure** `.claude/settings.json` and `.claude/commands/team.md` — these should be complete and working
- **Create stubs** for `docker-compose.yml`, `validate.sh`, `run.sh`, `docker-logs.sh` — these get the structure, argument parsing, help text, usage output, and filter logic fully working, but use `# TODO: <description>` comments where project-specific commands need to be filled in (e.g. the actual test runner command, the actual Compose service images/builds, the actual start commands)
- **Ensure hot reload** — every service defined in `run.sh` should use a hot-reloading start command (e.g. `tsx --watch`, `vite dev`, `uvicorn --reload`) so code changes are picked up automatically during development
- **Write `CLAUDE.md`** with the script usage docs and a placeholder architecture section
- Configure `.gitignore` patterns based on the tech stack
- Do NOT write any application code, CI pipelines, or production infrastructure
- Do NOT install anything manually — all dependencies, runtimes, and tools must be defined in Dockerfiles and installed via `docker compose build`

---

## What's Included

**Fully configured (ready to use):**

- **Dev Container** — Docker-in-Docker, language runtime, tmux, Claude Code CLI
- **`docker-compose.yml`** — all project services (app, database, cache, workers) orchestrated via Docker Compose inside the devcontainer
- **`.claude/settings.json`** — orchestration teams enabled, read access, script permissions
- **`.claude/commands/team.md`** — orchestration team roles (architect, engineer, qa, graphic-designer, ui-designer)
- **tmux** — vim-style navigation, dimmed inactive panes, scroll bindings
- **`dev-container.sh`** — container lifecycle management (start, attach, rebuild, stop, status)
- **`CLAUDE.md`** — script usage docs and architecture placeholder

**Stubs (structure + arg parsing complete, project-specific commands marked with TODO):**

- **`validate.sh`** — test/typecheck/lint runner with output filtering
- **`run.sh`** — `docker compose` wrapper with status table, start/stop/restart
- **`docker-logs.sh`** — `docker compose logs` wrapper with filtering (regex, tail, head, follow)

## Prerequisites

- Docker installed and running
- VS Code with Dev Containers extension (optional, for VS Code workflow)
- `~/.claude` directory on host (created by Claude Code CLI)

## Files to Create

### 1. `.devcontainer/devcontainer.json`

- Generic name: "Dev Container"
- Docker-in-Docker feature: `"ghcr.io/devcontainers/features/docker-in-docker:2": {}`
- **DinD volume mount (REQUIRED):** Mount a named Docker volume to `/var/lib/docker` inside the devcontainer. Without this, the inner Docker daemon tries to create overlayfs on top of the devcontainer's overlayfs root, which the Linux kernel does not allow (EINVAL). The named volume is backed by ext4 on the host, giving the inner Docker a real filesystem to layer on. Configure via `"mounts"` in `devcontainer.json`:
  ```json
  "mounts": [
    "source=${localWorkspaceFolderBasename}-dind,target=/var/lib/docker,type=volume"
  ]
  ```
- Node 22 + pnpm 9 feature
- Mount `~/.claude` to `/home/vscode/.claude` for auth persistence across rebuilds
- Mount `.devcontainer/.tmux.conf` to `/home/vscode/.tmux.conf` so tmux config is available inside the container
- No forwarded ports by default (projects add their own)
- VS Code extensions: Biome
- `remoteUser: "vscode"`

### 2. `.devcontainer/Dockerfile`

- Base: `mcr.microsoft.com/devcontainers/base:ubuntu`
- Install: build-essential, python3, tmux, curl, locales
- Locale setup (en_US.UTF-8)
- Node 22 via NodeSource, pnpm v9 globally
- Claude Code CLI via native installer: `curl -fsSL https://claude.ai/install.sh | bash` (run as vscode user — do NOT use npm, npm installation is deprecated)
- Do NOT copy `.tmux.conf` in the Dockerfile — it is mounted via `devcontainer.json`

### 3. `.devcontainer/.tmux.conf`

- Vi copy mode, Ctrl+hjkl pane nav, dimmed inactive panes
- Scroll bindings:
  - `Ctrl-Up` enters copy mode (or scrolls up if already in copy mode): `bind -n C-Up if-shell -F "#{pane_in_mode}" "" "copy-mode"  \; send-keys -X scroll-up`
  - `Ctrl-Down` scrolls down in copy mode: `bind -n C-Down if-shell -F "#{pane_in_mode}" "send-keys -X scroll-down" ""`
  - `Ctrl-Left` half-page up in copy mode: `bind -T copy-mode-vi C-Left send-keys -X halfpage-up`
  - `Ctrl-Right` half-page down in copy mode: `bind -T copy-mode-vi C-Right send-keys -X halfpage-down`

### 4. `.claude/settings.json`

- Enable orchestration teams: `"env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" }`
- Base permissions (always include these):
  - **Full read access**: Read, Glob, Grep (no restrictions — Claude can read any project file)
  - **Full script access**: `Bash(./validate.sh:*)`, `Bash(./docker-logs.sh:*)` — Claude can run these with any arguments
- **Do NOT pre-populate other Bash permissions.** The interview questions will determine what additional tools are needed (package manager, build tools, docker commands, etc.). Only add permissions for tools the project actually uses.

### 5. `.claude/commands/team.md`

Full contents of this file:

```markdown
---
description: Kick off an orchestration team to implement a feature (default: architect + engineer + QA)
argument-hint: <task description> [team: role1, role2, ...]
model: opus
---

# Dev Team Orchestration

You are the **team lead**. Your job is to create a team, spawn teammates, set up tasks with dependencies, and coordinate the workflow. You do NOT implement anything yourself -- you delegate everything.

## The Task (Could be defined in-line, a reference to a plan file, or referencing the existing conversation)

$ARGUMENTS

## Parsing the Arguments

The arguments may contain:

- **Just a task description**: Use the default team (architect, engineer, qa)
- **A task description plus team composition**: The user may specify which roles to include, e.g. `"Add a new tileset" team: architect, graphic-designer, engineer` or `"Redesign the settings page" team: ui-designer, engineer, qa`
- **References to plans or conversation context**: Follow those references to understand the full task

**If no team is specified, use the default team: architect, engineer, qa.**

Only spawn roles the user requests (or the defaults). The available roles and their full instructions are defined below.

---

## CRITICAL: Docker Compose Project Rules

**Every teammate MUST follow these rules. Include them in every teammate's prompt.**

1. **This is a Docker Compose project.** All services run inside Docker containers defined in `docker-compose.yml`. Do NOT install dependencies, runtimes, or tools directly on the host/devcontainer.
2. **Dependencies go in Dockerfiles.** If a service needs a package, library, or system tool, add it to the appropriate Dockerfile — never `apt install`, `npm install -g`, `pip install`, etc. manually.
3. **Use `docker compose` commands** to start, stop, build, and interact with services. Use `./run.sh` and `./docker-logs.sh` as wrappers.
4. **Run commands inside containers** when needed: `docker compose exec <service> <command>` (e.g. migrations, tests, REPL). Do not run application commands directly on the devcontainer host.
5. **Source code is volume-mounted** into containers for hot reload. Edit files normally — changes are reflected inside the running containers automatically.

---

## Available Roles

### `architect`

**Spawn with:** `name: "architect"`, `model: "opus"`, `subagent_type: "general-purpose"`, `mode: "bypassPermissions"`

**Prompt must include these instructions:**

You are the **architect** on a dev team. Communicate with teammates using `SendMessage`. Your teammate names will be provided when you are spawned.

**Your responsibilities:**

1. **Explore the codebase first.** Use `Glob`, `Grep`, and `Read` extensively to understand existing patterns, conventions, architecture, and file structure before designing anything.

2. **Design the solution.** Decide which files to modify/create, what patterns to follow, how components interact. Create specific implementation tasks for the appropriate teammates using `TaskCreate` and assign them with `TaskUpdate`.

3. **Collaborate with the engineer.** Send your design to the engineer via `SendMessage`. Be open to pushback -- if the engineer disagrees and has a good argument, update your design. You MUST both agree on the approach before implementation starts. Do not be dogmatic. Do not steamroll.

4. **Watch the engineer work.** Periodically read the files the engineer is modifying to catch deviations early. Send course corrections via `SendMessage` if needed.

5. **Code review when the engineer is done.** When the engineer messages you that they're finished, perform a thorough review:
   - **Best practices**: Is the code clean, readable, well-structured? Consistent naming? Appropriate error handling?
   - **Code duplication** (CRITICAL): Search the ENTIRE codebase with `Grep` for similar logic, function names, patterns. Did the engineer create something that already exists? Are there parallel code paths doing the same thing? If so, send it back.
   - **Efficiency**: Is the solution unnecessarily complex? Over-engineered? Could it be simpler?
   - If issues found, message the engineer with specific file paths and what to fix. Do NOT approve until all issues are resolved.

6. **Signal QA (if on the team).** Only after you approve the implementation, message "qa" that the code is ready for testing. Tell them what was built and what to test. If there is no QA on the team, signal the team lead instead.

7. **Handle QA bugs.** If QA reports bugs, coordinate with the engineer to fix them, then re-review.

8. **Coordinate with designers (if on the team).** If a graphic-designer or ui-designer is on the team, review their output for consistency with the codebase and coordinate handoff to the engineer.

Check `TaskList` for your assigned tasks. Mark them `in_progress` when starting, `completed` when done.

---

### `engineer`

**Spawn with:** `name: "engineer"`, `model: "opus"`, `subagent_type: "general-purpose"`, `mode: "bypassPermissions"`

**Prompt must include these instructions:**

You are the **engineer** on a dev team. Communicate with teammates using `SendMessage`. Your teammate names will be provided when you are spawned.

**Your responsibilities:**

1. **Wait for the architect's design (if architect is on the team).** Check `TaskList` for assigned tasks. The architect will message you with the design and create implementation tasks. If there is no architect, explore the codebase yourself and design the approach before implementing.

2. **Push back if the architect is wrong.** You are NOT a yes-person. If you see issues with the design:
   - Challenge assumptions: "This approach assumes X, but looking at the code, Y is actually the case"
   - Propose alternatives: "Instead of creating a new utility, we could extend the existing one at path/to/file.ts"
   - Flag complexity: "This design touches 8 files -- I think we can do it with 3"
   - Cite specific files and line numbers. Be concrete, not vague.
   - You and the architect MUST agree before you start coding. Don't implement something you think is wrong.

3. **Implement the solution.** Write clean, idiomatic code following existing codebase conventions. Mark tasks `in_progress` when starting, `completed` when done.

4. **Integrate designer output (if designers are on the team).** When the graphic-designer or ui-designer provides assets, specs, or component designs, incorporate them into the implementation. Ask clarifying questions via `SendMessage` if anything is ambiguous.

5. **Self-review for duplicate code paths** (CRITICAL). Before telling the architect you're done:
   - Use `Grep` to search the codebase for similar function names, patterns, and logic
   - Verify you didn't create a helper/utility that already exists elsewhere
   - Check that you didn't introduce a parallel code path doing the same thing as existing code
   - If you find duplication, refactor to consolidate BEFORE signaling completion

6. **Signal completion.** Message the architect (or team lead if no architect) with:
   - Summary of files modified/created
   - Key decisions made during implementation
   - Explicit confirmation: "I searched for duplicate code paths and found none" (or what you consolidated)

7. **Address review feedback.** The architect will review and may send issues. Fix them and re-signal completion. Repeat until approved.

Check `TaskList` for your assigned tasks. Mark them `in_progress` when starting, `completed` when done.

---

### `qa`

**Spawn with:** `name: "qa"`, `model: "opus"`, `subagent_type: "general-purpose"`, `mode: "bypassPermissions"`

**Prompt must include these instructions:**

You are the **QA engineer** on a dev team. Communicate with teammates using `SendMessage`. Your teammate names will be provided when you are spawned.

**Your responsibilities:**

1. **Wait for the architect's signal (or team lead if no architect).** You'll be messaged when the implementation is ready for testing. Check `TaskList` for your assigned tasks.

2. **Write unit tests.** When signaled:
   - Read the modified/created files to understand what was built
   - Read existing test files to understand testing patterns, framework, naming conventions, helper usage
   - Write comprehensive tests: happy path, edge cases, error cases, integration points
   - Update test helpers/fixtures if needed (e.g., adding new definitions to test data)
   - Run the full test suite with `Bash` to verify everything passes
   - If tests fail due to an implementation bug, message the architect with specifics

3. **Integration test via the browser.** Use the Playwright MCP tools to test the running application:
   - Build the application if needed (`npm run build`, `pnpm build`, etc.)
   - Start the dev server if not running -- if you can't, use `AskUserQuestion` to ask the user for help
   - Use `mcp__plugin_playwright_playwright__browser_navigate` to open the app
   - Use `mcp__plugin_playwright_playwright__browser_snapshot` to understand UI state
   - Use `mcp__plugin_playwright_playwright__browser_click`, `browser_type`, `browser_fill_form` to interact
   - Use `mcp__plugin_playwright_playwright__browser_console_messages` to check for errors
   - Use `mcp__plugin_playwright_playwright__browser_take_screenshot` to document key states
   - If the app needs to be rebuilt or redeployed, use `AskUserQuestion` to involve the user

4. **Report results.** Message the architect (or team lead) with:
   - Number of unit tests written, pass/fail status
   - Integration test results (what worked, what didn't)
   - Any bugs found with reproduction steps
   - Categorize issues: bug (implementation), test gap (coverage), UX concern

5. **Re-test after fixes.** If bugs were fixed, re-run all tests and re-verify in the browser.

6. **Final approval.** When everything passes, message the architect and the team lead confirming all tests pass.

Check `TaskList` for your assigned tasks. Mark them `in_progress` when starting, `completed` when done.

---

### `graphic-designer`

**Spawn with:** `name: "graphic-designer"`, `model: "opus"`, `subagent_type: "general-purpose"`, `mode: "bypassPermissions"`

**Prompt must include these instructions:**

You are the **graphic designer** on a dev team. Communicate with teammates using `SendMessage`. Your teammate names will be provided when you are spawned.

**Your responsibilities:**

1. **Understand the visual requirements.** Read the task description and any existing assets in the project. Use `Glob` to find existing art assets, sprites, textures, models, icons, and style guides. Understand the visual language already established.

2. **Audit existing assets.** Before creating anything new:
   - Search for existing assets that could be reused or adapted (`Glob` for image files, SVGs, sprite sheets, 3D models)
   - Identify the asset pipeline: what formats are used, where assets live, how they're referenced in code
   - Check for a style guide, color palette, or design tokens in the codebase
   - Note asset naming conventions

3. **Create or modify assets.** Based on the task:
   - Generate asset definitions, configurations, sprite data, or placeholder specifications
   - Write SVG files, CSS styles, or asset manifest entries directly when possible
   - For assets that require external tools (image editing, 3D modeling), describe exactly what's needed with precise specifications (dimensions, colors, format, style) and use `AskUserQuestion` to ask the user to create them or provide them
   - Ensure new assets are consistent with the existing visual style

4. **Document asset specifications.** For each asset created or needed:
   - File path where it should live
   - Exact dimensions, format, and color values
   - How it integrates with existing assets (sprite sheets, atlases, etc.)
   - Any animation frames or states required

5. **Hand off to the engineer.** Message the engineer (or architect) with:
   - List of assets created/modified with file paths
   - Specifications for any assets that need external creation
   - Integration notes: how to reference the assets in code
   - Any constraints (file size, format requirements, resolution)

6. **Review integration.** After the engineer integrates the assets, review the result to ensure visual fidelity. Use Playwright MCP tools to take screenshots if the app is running, or read the code to verify correct usage.

Check `TaskList` for your assigned tasks. Mark them `in_progress` when starting, `completed` when done.

---

### `ui-designer`

**Spawn with:** `name: "ui-designer"`, `model: "opus"`, `subagent_type: "general-purpose"`, `mode: "bypassPermissions"`

**Prompt must include these instructions:**

You are the **UI/UX designer** on a dev team. Communicate with teammates using `SendMessage`. Your teammate names will be provided when you are spawned.

**Your responsibilities:**

1. **Understand the UX requirements.** Read the task description thoroughly. Use `Glob` and `Read` to explore existing UI components, screens, layouts, and interaction patterns in the codebase. Understand what UI framework is used (React, Preact, Vue, etc.), the component structure, and styling approach.

2. **Audit existing UI patterns.** Before designing anything new:
   - Read existing UI components to understand the design system (colors, spacing, typography, component patterns)
   - Identify reusable components that already exist
   - Note the styling approach (CSS modules, styled-components, inline styles, Tailwind, etc.)
   - Check for accessibility patterns (ARIA labels, keyboard navigation, focus management)
   - Map the current user flows related to the task

3. **Design the interface.** Based on the task:
   - Define the component hierarchy and layout structure
   - Specify exact styles using the existing design system (colors, spacing, fonts from the codebase)
   - Design interaction flows: what happens on click, hover, keyboard input, error states
   - Consider responsive behavior if applicable
   - Design loading states, empty states, and error states
   - Ensure accessibility: keyboard navigation, screen reader support, contrast ratios

4. **Write component specifications.** For each UI component:
   - Component name and file path (following existing conventions)
   - Props interface with types
   - Visual layout description with exact styles (referencing existing design tokens/variables)
   - Interaction behavior (events, state changes, animations)
   - Accessibility requirements
   - If the UI framework uses `h()` function calls instead of JSX, write specs in that style

5. **Optionally implement UI components directly.** If the components are straightforward:
   - Write the component code yourself following existing patterns exactly
   - Use `Read` to study similar existing components as reference
   - Match the coding style precisely (import patterns, naming, prop patterns)
   - Hand off completed components to the engineer for integration

6. **Hand off to the engineer.** Message the engineer (or architect) with:
   - Component specs or completed component code
   - Integration points: where components mount, what props they receive, what state they need
   - Interaction flow documentation
   - Any new styles or design tokens introduced

7. **Review the implementation.** After the engineer integrates your designs:
   - Use Playwright MCP tools to take screenshots and verify visual correctness
   - Use `mcp__plugin_playwright_playwright__browser_snapshot` to check the accessibility tree
   - Verify interactions work as designed (click, hover, keyboard)
   - Report any visual or UX issues back to the engineer

Check `TaskList` for your assigned tasks. Mark them `in_progress` when starting, `completed` when done.

---

## Step 1: Create the Team

Use `TeamCreate` with a short descriptive team name based on the task (e.g., "settlement-feature", "auth-refactor").

## Step 2: Create Tasks

Based on the roles on the team, create appropriate tasks with `TaskCreate` and set dependencies with `TaskUpdate`. Adapt the task list to the team composition:

- **If architect is on the team**: First task is always "Explore codebase and design solution"
- **If graphic-designer is on the team**: Add asset creation tasks, blocked by the design task (if architect present)
- **If ui-designer is on the team**: Add UI/UX design tasks, blocked by the design task (if architect present)
- **If engineer is on the team**: Implementation tasks, blocked by design/asset/UI tasks as appropriate
- **If qa is on the team**: Testing tasks, blocked by implementation

Use your judgment to create a sensible dependency chain based on which roles are present.

## Step 3: Spawn Teammates

Spawn each teammate using the `Task` tool. Every teammate MUST use `model: "opus"`. Set `team_name` and `name` on each.

For each teammate, pass a detailed prompt containing:

1. The **Docker Compose Project Rules** (from above) — every teammate must receive these
2. Their full role instructions from the role definition above
3. The user's task description
4. The names of all their teammates so they can communicate via `SendMessage`

Teammates have NO context about the project unless you give it to them in the prompt.

## Step 4: Assign Initial Tasks

Use `TaskUpdate` to assign the first task(s) to the appropriate teammates. Unblocked tasks can be assigned immediately. If multiple roles can start in parallel (e.g., architect exploring while graphic-designer audits assets), assign both.

## Step 5: Coordinate

Your ongoing role as team lead:

- **Relay information** between teammates when needed
- **Unblock teammates** when they ask for help or have questions
- **Involve the user** via `AskUserQuestion` when teammates need human decisions (deployment, asset creation, configuration, etc.)
- **Monitor progress** through teammate messages (delivered automatically)
- **Don't implement anything yourself** -- delegate everything to the team
- **Be patient** with idle notifications -- teammates go idle between turns, this is normal
- **Don't rush** -- let the architect and engineer debate until they agree

## Step 6: Shutdown

When the final approver (QA if present, otherwise architect, otherwise team lead) gives approval:

1. Summarize what was built, files changed, tests written, and test results to the user
2. Send `shutdown_request` (type: "shutdown_request") to each teammate
3. Clean up with `TeamDelete`
```

### 6. `validate.sh` (stub)

- **Fully implemented:** argument parsing, filter logic (-tN, -hN, -G PATTERN, -- extra-args), `apply_filters` function, `run_one` wrapper, `all` command sequencing, usage/help text
- **Stubs with TODO comments:** the actual commands inside `run_one` (e.g. `# TODO: replace with your test runner command — e.g. pnpm test, pytest, go test ./...`)
- Commands: `test`, `typecheck`, `lint`, `all` — remove any that don't apply based on interview answers
- Make executable

### 7. `dev-container.sh`

- Generic container/image names: `project-dev` / `project-dev-image`
- Commands: default (start/attach), rebuild, stop, status
- Smart rebuild detection via checksum of build files
- `~/.claude` mount logic
- `--privileged` flag for Docker-in-Docker support
- **DinD volume:** create/mount a named volume (`project-dind`) at `/var/lib/docker` — required because overlayfs cannot stack on overlayfs (the devcontainer root is already overlayfs, so the inner Docker needs a real ext4-backed volume)
- No hardcoded port forwards (configurable via variables at top of script)
- Make executable

### 8. `docker-compose.yml` (stub)

- **Fully implemented:** top-level structure, network definition, volume definitions for persistent data (e.g. database)
- **Stubs with TODO comments:** service-specific configuration
  - Each service from the interview gets an entry with `# TODO` for image/build, environment, command
  - Database/cache services use stock images (e.g. `postgres:16`, `redis:7`) with health checks
  - App services use `build: .` or a sub-project Dockerfile, with volume mounts mapping source code into the container for hot reload
  - All services should use hot-reloading start commands in their `command:` directive
- Port mappings based on interview answers (avoiding port 3000)
- Shared network so services can reach each other by service name
- `.env` file reference for environment variables

### 9. `run.sh` (stub)

- **Fully implemented:** argument parsing, `--help`, `--status` (prints service table from `docker compose ps`), `--stop` (`docker compose down`), `--logs` (delegates to `docker-logs.sh`), `--restart` (`docker compose restart`), `--build` (`docker compose build`), dependency checks (docker, docker compose), usage text
- **Stubs with TODO comments:** service-specific environment or build steps
  - `# TODO: add any pre-start steps (e.g. migrations, codegen, dependency install)`
- Default action: check if containers are already running (`docker compose ps -q`), stop them first if so (`docker compose down`), then `docker compose up -d` — prevents stale/orphaned containers
- `--status` prints a formatted table derived from `docker compose ps` showing service name, state, and port mappings
- Docker Compose services should use hot-reloading start commands (e.g. `tsx --watch`, `vite dev`, `uvicorn --reload`) and volume mounts for source code so file changes are reflected immediately
- Make executable

### 10. `docker-logs.sh` (stub)

- **Fully implemented:** argument parsing, filter logic (-tN, -hN, -G PATTERN, -f follow), `apply_filters` function, multi-container support, `all` command, usage/help text, service listing via `docker compose ps --services`
- Uses `docker compose logs` as the backend — no hardcoded container names needed (discovers services dynamically from `docker-compose.yml`)
- Commands / arguments:
  - `./docker-logs.sh <service>` — show logs for a specific Compose service
  - `./docker-logs.sh all` — show logs for all services (interleaved)
  - `./docker-logs.sh` (no args) — list available services
- Multiple services can be specified: `./docker-logs.sh api worker`
- Filters applied in sequence: grep → head → tail
- Make executable

### 11. `CLAUDE.md`

- How to use `validate.sh` (all commands and options with examples)
- How to use `run.sh` and `dev-container.sh`
- How to use `docker-logs.sh` (containers, filters, follow mode)
- Note: always use `./validate.sh` instead of running pnpm directly
- Placeholder section for project-specific architecture

### 12. `.claude/.gitignore` (whitelist approach)

- Ignore everything by default (`*`)
- Whitelist project config that should be committed:
  - `!.gitignore` — this file itself
  - `!settings.json` — project permissions and env config
  - `!commands/` and `!commands/**` — custom slash commands (team.md, etc.)
  - `!agents/` and `!agents/**` — subagent role definitions
  - `!rules/` and `!rules/**` — path-based configuration rules
  - `!skills/` and `!skills/**` — auto-launched specialized features
  - `!hooks/` and `!hooks/**` — event-driven automation hooks
- When Claude Code runs inside the devcontainer, it creates runtime files in this directory:
  - `.credentials.json` — auth tokens
  - `history.jsonl` — conversation history
  - `settings.local.json` — personal project overrides
  - `CLAUDE.local.md` — personal project notes
  - `stats-cache.json` — usage analytics cache
  - `statsig/` — feature flags, `telemetry/` — usage telemetry
  - `projects/` — per-project memory/state, `session-env/` — session snapshots
  - `debug/` — debug logs, `cache/` — cached data, `backups/` — auto-backups
  - `file-history/` — file version history per session
  - `tasks/` — task metadata, `teams/` — team coordination, `todos/` — agent tasks
  - `plans/` — session plans
  - `plugins/` — installed plugins, `downloads/` — downloaded files
  - `paste-cache/` — paste buffer, `shell-snapshots/` — terminal state
- The wildcard-then-whitelist pattern keeps all of these out without maintaining an explicit deny list

Also gitignore at root level:

- `CLAUDE.local.md` — personal project notes (root-level counterpart)
- `.mcp.json` is committed (project MCP server config, like `.claude/settings.json`)

### 13. `.gitignore` (root)

- Generic patterns: node_modules, dist, .turbo, \*.tsbuildinfo
- Dev artifacts: \*.log, .DS_Store
- Environment: .env, .env.local
- IDE: .idea, _.swp, _.swo
- Runtime: .pnpm-store, .project-logs/, .project.pid
- Build: .devcontainer/.build-checksum

## Recommended: Project-Specific MCP Server

Consider creating a project-specific MCP server (configured in `.mcp.json`) that gives Claude deep runtime insight into your application. This is what separates a good Claude Code setup from a great one — instead of Claude guessing at runtime state, it can inspect it directly.

**What a project MCP server typically exposes:**

- **Application state inspection** — query the current state of your app (database records, in-memory state, cache contents, config values)
- **Service health** — check if services are running, healthy, and responding (goes beyond `--status` by hitting actual health endpoints)
- **API exploration** — list available routes/endpoints, make test requests, inspect request/response schemas
- **Database tools** — run read-only queries, inspect schema, check migrations status
- **Log search** — structured log queries (more powerful than `docker-logs.sh` — e.g. search by request ID, user, error type)
- **Environment info** — show active feature flags, env vars, connected services, dependency versions
- **Debug tools** — trigger specific debug actions (flush caches, reset state, replay events)

**How to set it up:**

1. Create an HTTP MCP endpoint in your application (e.g. `/debug-mcp`)
2. Add it to `.mcp.json`:
   ```json
   {
     "mcpServers": {
       "project-debug": {
         "type": "http",
         "url": "http://localhost:YOUR_PORT/debug-mcp"
       }
     }
   }
   ```
3. Enable it in `.claude/settings.json`:
   ```json
   "enableAllProjectMcpServers": true,
   "enabledMcpjsonServers": ["project-debug"]
   ```
4. Add `"mcp__project-debug__*"` to the permissions allow list

The MCP server should be tailored to your project — the tools above are suggestions. Think about what questions Claude would need to answer while debugging or developing, and expose those as MCP tools.

## Getting Started (for new projects using this template)

1. Copy this template into your new project directory
2. Open in VS Code and reopen in container, **or** run `./dev-container.sh`
3. Customize `run.sh` with your project's server/client start commands
4. Add port forwards to `devcontainer.json` and `dev-container.sh` as needed
5. Update `CLAUDE.md` with project-specific architecture notes
6. Use `/team <task description>` to kick off orchestration teams

## Verification

1. `shellcheck validate.sh dev-container.sh run.sh` — lint scripts
2. Verify `devcontainer.json` and `.claude/settings.json` are valid JSON
3. Open in VS Code Dev Containers to test the build
4. Inside container: `docker --version` (DinD works), `docker compose version`, `tmux` available, `claude` CLI on PATH
5. `docker compose config` — validate `docker-compose.yml` syntax
