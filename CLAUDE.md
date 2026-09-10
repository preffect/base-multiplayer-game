# Base Multiplayer Game — Claude Code Guidance

> # 🟢 START HERE — is this game defined yet?
>
> **If this game has NOT been defined yet** — it was just scaffolded with `new-game.sh`,
> gameplay is still the placeholder **echo** game, and **`init-game.md` still contains
> `<PLACEHOLDER>` tokens / says "(GENERATED ARTIFACT — skeleton)"** — then your **FIRST
> action in this session, before anything else**, is:
>
> 👉 **Read [`init-game-prompt.md`](./init-game-prompt.md) and follow it.**
>
> It will walk you through interviewing the user about the game they want to build, then
> generating a concrete `init-game.md` build plan. **Do NOT start editing game source files
> yet** — defining the game comes first. This is the expected next step right after
> `./new-game.sh` builds the devcontainer and you open it.
>
> **Once the game IS defined** (`init-game.md` no longer has placeholders / the echo game has
> been replaced), this banner no longer applies — ignore it and use the guidance below.

> **Build environment — work INSIDE the devcontainer.** Assume every command here (and in
> any helper prompt such as `init-game-prompt.md` / `init-game.md`) runs inside the
> devcontainer. Open it from the host with `./dev-container.sh`. **All dependency installs
> (`pnpm install`, `./run.sh --install`) happen in the container — never install on the host.**
> System tools belong in `.devcontainer/Dockerfile`; project deps go in the workspace via pnpm.

## Commands

### Validation (always use `./validate.sh` instead of running tools directly)

```bash
./validate.sh test                    # run all tests (vitest for shared/server, ng test for client)
./validate.sh typecheck               # type check all packages
./validate.sh lint                    # eslint + prettier --check
./validate.sh all                     # run lint, typecheck, test in sequence

# Output filters (work with any command):
./validate.sh test -t20               # show last 20 lines
./validate.sh typecheck -h50          # show first 50 lines
./validate.sh lint -G 'error'         # grep output for pattern
./validate.sh test -- --filter shared # pass extra args to underlying command
```

### Running the dev servers

```bash
./run.sh                # start server (4400) + Angular client (4402)
./run.sh --server-only  # start only the game server
./run.sh --client-only  # start only the Angular dev server
./run.sh --stop         # stop all running processes
./run.sh --status       # check what's running
./run.sh --logs         # tail server and client logs
./run.sh --install      # run pnpm install before starting
```

### Dev container

```bash
./dev-container.sh          # start or attach to container
./dev-container.sh rebuild  # force rebuild (DEVCONTAINER_YES=1 to confirm non-interactively)
./dev-container.sh stop     # stop the container
./dev-container.sh status   # show container status
```

## Project workflow (GitHub issues, board, reviews)

**[`WORKFLOW.md`](./WORKFLOW.md)** is the single source of truth: tickets + labels on GitHub Issues,
stage on the linked Project board, epics as sub-issues, **assignee = waiting on the human**
(`pending` label + `Blocked`), PR required with **reviewers run on every PR and every review
thread resolved before merge**, labels updated as tickets complete. Everything is done via the
API — the human never clicks in GitHub's UI. Helpers: `scripts/project-sync.sh` (run at session
start), `scripts/issue-status.sh <Status> <N...>`, `scripts/pr-threads.sh` (batched review threads), `.github/PULL_REQUEST_TEMPLATE.md` (review checklist).
**[`TEAM.md`](./TEAM.md)** defines the agent roles (`.claude/agents/`, spawned with the Agent tool in
session, or headlessly with `scripts/agent.sh`) and the scripted review loop (`scripts/land-pr.sh`).

## Toolchain inside the devcontainer

Node 24, pnpm 10, Claude Code, `gh` (authenticated via the mounted host `~/.config/gh`), git
(pushes over HTTPS with `gh` as credential helper — no SSH key inside; identity from the host's
gh account unless the container already has one), python3, jq, ripgrep, ImageMagick, ffmpeg, and
Playwright Chromium for the `playwright` MCP (`.mcp.json`), rsvg-convert + DejaVu fonts for SVG
rendering; the template checkout is mounted at `/base-multiplayer-game` so template-first fixes and <!-- KEEP_TEMPLATE_NAME -->
`scripts/sync-from-template.sh` work inside too. A host conversation continues inside with
`scripts/resume-in-container.sh`. Improvements to the container or the
process belong upstream in `base-multiplayer-game` so the next game inherits them. <!-- KEEP_TEMPLATE_NAME -->

## Standards & guidelines

These docs are the enforceable quality bar for any work in this repo. Read and follow them.

- **[`ENGINEERING.md`](./ENGINEERING.md)** — coding, architecture, and testing rules. The single
  gate is **`./validate.sh all`** (lint + typecheck + test): no task is done until it is green;
  never run the underlying tools directly; never commit red. All new logic needs unit tests;
  cross-subsystem wiring needs `*.integration.test.ts`. See its **Definition of Done** checklist.
- **[`ASSET-GENERATION.md`](./ASSET-GENERATION.md)** — visual asset quality bar. All visual assets
  are code-drawn (zero bitmaps); every player/monster/item is layered, shaded, palette-disciplined,
  animated, and silhouette-legible. "It renders" is not done — meet the per-asset checklist.
- **[`AUDIO-PIPELINE.md`](./AUDIO-PIPELINE.md)** — the opt-in music + voice + SFX pipeline.
  **Google/Gemini is the default** for both music (Lyria) and voice (Chirp). `./ai-pipeline.sh check`
  is offline; `sync` spends money and never runs unsolicited.

> **The gate:** after any change, `./validate.sh all` must pass, the Definition of Done in
> `ENGINEERING.md` must hold, and any new visual/audio asset must meet its doc's criteria.

## Architecture

Reusable multiplayer game template (client/server, native WebSocket multiplayer, MCP game-state visibility). The generic multiplayer/lobby/room/connection/MCP plumbing is provided and working; the actual game logic is left as clearly-marked extension points (`// TODO(game)` / `// TODO(init)`) to be filled in later by the init step.

### Monorepo Structure

pnpm monorepo with three packages:

- **`packages/shared`** — Shared types, constants, and logic (message envelope, branded ids). Pure TypeScript, no framework dependencies. Used by both server and client. Game-specific `GameInput` / `GameSnapshot` types are TODO hooks.
- **`packages/server`** — Fastify + WebSocket game server. Handles multiplayer coordination (lobby, rooms, the 60Hz broadcast loop) and exposes a debug MCP endpoint at `/debug-mcp`. The single game seam is `src/game/game-module.ts` (`defaultGameModuleFactory` ships a trust-client echo). No persistence by default.
- **`packages/client`** — Angular 21 application. Zoneless by default. Proxies `/api`, `/ws`, and `/debug-mcp` to the server via `proxy.conf.json`. The client game seam is `src/app/game/game-setup.ts`.

### Game extension points (left as TODOs)

- **Shared:** `packages/shared/src/types/messages.ts` — `GameInput`, `GameSnapshot`, `GameSessionConfig`.
- **Server:** `packages/server/src/game/game-module.ts` — `GameModule` impl (`submitInput` / `reduceGameState` / `serializeRoomState` / `add`/`removePlayer`); wire the factory into `src/index.ts`. MCP game-state visibility via `DebugContext.getRoomGameState(gameId)`.
- **Client:** `packages/client/src/app/game/game-setup.ts` — the game loop + renderer.
- **Init:** see `init-game-prompt.md` to interview and generate `init-game.md`.

### Trust model

LOCAL-ONLY play. Client-side trust where convenient — we do NOT care about security or cheating; prefer simplicity over anti-cheat.

### Ports

This game's ports are **pre-selected on the host** by `new-game.sh` (verified free against
both the host and the live `ha-router` config) and recorded in **`PORTS.env`** at the repo
root — read that file for the authoritative `SERVER_PORT` / `CLIENT_PORT`. Do **not** pick or
change ports inside the container; they are already baked into the integration files.

- **`SERVER_PORT`** (template default **4400**) — Game server (Fastify: REST API + WebSocket + debug MCP)
- **`CLIENT_PORT`** (template default **4402**) — Angular dev server (proxies to server)

### Tech Stack

- Node 24 LTS, pnpm 10
- Angular 21 (zoneless, standalone components, vitest)
- Fastify 5 + @fastify/websocket
- TypeScript strict mode
- ESLint (angular-eslint + typescript-eslint) + Prettier
- Vitest for testing

### Style Guide

- ESLint with angular-eslint for Angular-specific rules
- Prettier: 2-space indent, single quotes, trailing commas, semicolons, 120 char width
- TypeScript strict: noUnusedLocals, noUnusedParameters, noUncheckedIndexedAccess, verbatimModuleSyntax
- See **`ENGINEERING.md`** for the full enforceable TS/lint/testing/architecture standards.

### MCP Servers

- **game-debug** — HTTP MCP endpoint on the game server (`http://localhost:4400/debug-mcp`) for inspecting game state (`debug_get_game_state`, `debug_list_games`, `debug_get_room`), player connections (`debug_get_connections`), and performance (`debug_get_performance`)
- **angular** — Angular's built-in MCP server for component introspection and development assistance
- **playwright** — headless Chromium (`@playwright/mcp`, installed in the image) for QA / graphics roles to drive and screenshot the running game; screenshots land in `.qa/screenshots/`
