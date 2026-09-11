# Base Multiplayer Game

Repo: https://github.com/preffect/base-multiplayer-game — `main` is PR-protected (see `docs/WORKFLOW.md`);
template fixes are reviewed like game fixes, then pulled into games with `scripts/sync-from-template.sh`.

A reusable **multiplayer game template**: a working client/server multiplayer skeleton
(native WebSocket transport, lobby, rooms, a 60 Hz broadcast loop, reconnection/identity,
and MCP game-state visibility) whose actual **game definition is deferred**.

Everything except the game logic ships working today against a placeholder trust-client
"echo" game. The game-specific seams are clearly marked `// TODO(game)` / `// TODO(init)`
extension points, ready to be filled in.

## Create a game from this template

One command on the host does everything up to "define the game":

```bash
./base-multiplayer-game/new-game.sh my-game --title "My Game"   # from /home/preffect/source
```

`new-game.sh` lives in this repo (a thin `new-game.sh` wrapper at `/home/preffect/source` calls it);
games are created as siblings of the template folder.

It copies the template, picks free ports, instantiates (`presetup.sh`), registers the game in the
live **ha-router** (route + landing card, DNS check), builds and starts the **devcontainer**
non-interactively, runs `./validate.sh all` (which builds `packages/shared` — required before the
client can compile) and `./run.sh`, verifies `https://<slug>.preffect-ha.preffect-home.net` through
Traefik, and sets up **GitHub** (repo, labels, milestones, project board + views, groundwork epics,
branch ruleset) via `scripts/github-setup.sh`. Flags: `--no-start`, `--no-ha-router`, `--no-github`,
`--private`. Each step is idempotent and can be re-run on its own (`./dev-container.sh`,
`./scripts/github-setup.sh`, `ha-router/HA-ROUTER.md`).

Then, **inside the devcontainer** (where every agent runs):

```bash
claude "Read docs/INIT-GAME.md and help me initialize my game"   # interview → init-game.md
```

The groundwork epics on GitHub (devcontainer verified, tooling/MCP, team, quality gates, testing
foundations, design, architecture/build plan) are the first work for the agent team; how work is
tracked, reviewed and merged is in **[`docs/WORKFLOW.md`](docs/WORKFLOW.md)**. Building the game then means
executing the build tickets that `docs/INIT-GAME.md` files against the three extension points:

- **shared** — `packages/shared/src/types/messages.ts`: `GameInput` / `GameSnapshot` / `GameSessionConfig`
- **server** — `packages/server/src/game/game-module.ts`: game logic; wire the factory into `index.ts`; expose state via `DebugContext.getRoomGameState`
- **client** — `packages/client/src/app/game/game-setup.ts`: input loop + renderer

This README is the **template's**; `presetup.sh` replaces it in the game copy with
`README.game.md` (the game-facing README), so a game never describes itself as a template.

**Keeping games in sync:** make template-level fixes here first, then run
`./scripts/sync-from-template.sh` inside a game (host) to pull the template-owned files across
with the game's identity re-applied, and land the diff via a PR.

<details><summary>Manual steps (what new-game.sh automates)</summary>

1. `cp -r base-multiplayer-game my-game && cd my-game && ./presetup.sh` _(host)_ <!-- KEEP_TEMPLATE_NAME -->
2. ha-router: `ha-router/HA-ROUTER.md` _(host; per-host DNS record needed)_
3. `DEVCONTAINER_YES=1 ./dev-container.sh` _(host; non-interactive when no TTY)_
4. `./validate.sh all && ./run.sh` _(container; validate first — it builds shared)_
5. `./scripts/github-setup.sh` _(host; needs `gh` with the `project` scope)_

</details>

## What's included (working today)

- **Transport** — native WebSocket, `?clientId=` identity, multi-tab takeover, auto-reconnect.
- **Lobby + rooms** — create/join/start/delete games, late-join, disconnect grace, room teardown.
- **Broadcast loop** — per-room 60 Hz tick; server broadcasts `game_snapshot` to all clients.
- **MCP visibility** — a `/debug-mcp` endpoint (`game-debug`) exposing connections, performance,
  rooms, and game state to Claude Code.
- **Generic message envelope** — client sends `player_input { payload }`; server broadcasts
  `game_snapshot { snapshot }`. `GameInput` / `GameSnapshot` are the only types a game must define.
- **Dev tooling** — DinD devcontainer with `gh` (host auth mounted), ripgrep, ImageMagick, ffmpeg and Playwright
  Chromium; `run.sh`, `validate.sh`, ESLint + Prettier, Vitest.
- **Project tooling** — `scripts/github-setup.sh` (repo, board, groundwork epics, ruleset),
  `scripts/project-sync.sh`, `scripts/issue-status.sh`; process in `docs/WORKFLOW.md`.

## Standards

This template ships three enforceable standards docs — read them before (and while) building:

- **[`docs/ENGINEERING.md`](docs/ENGINEERING.md)** — coding, architecture, and testing rules. The single
  gate is `./validate.sh all`; includes a Definition of Done checklist.
- **[`docs/ASSET-GENERATION.md`](docs/ASSET-GENERATION.md)** — the code-drawn visual asset quality bar
  (layered, shaded, animated, legible) with a per-asset checklist.
- **[`docs/AUDIO-PIPELINE.md`](docs/AUDIO-PIPELINE.md)** — the opt-in music + voice + SFX pipeline with
  Google/Gemini as the default for both music and voice.

## Tech stack

- Node 24 LTS, pnpm 10
- TypeScript (strict)
- Fastify 5 + `@fastify/websocket` (server)
- Angular 21 (zoneless, standalone components) (client)
- `@modelcontextprotocol/sdk` for the debug MCP endpoint
- ESLint (angular-eslint + typescript-eslint) + Prettier, Vitest

## Monorepo layout

```
packages/shared   — message envelope, branded ids, game-defined type hooks (GameInput / GameSnapshot)
packages/server   — Fastify + WS server: lobby, rooms, 60Hz loop, /debug-mcp; game seam = src/game/game-module.ts
packages/client   — Angular client: WS service, identity, room browser; game seam = src/app/game/game-setup.ts
```

## Ports

- **4400** — game server (Fastify: REST API `/api` + WebSocket `/ws` + debug MCP `/debug-mcp`, single instance)
- **4402** — Angular dev server (proxies `/api`, `/ws`, `/debug-mcp` to the server)

## How to run

> **Run everything inside the devcontainer.** Open it from the host with `./dev-container.sh`,
> then run the commands below **inside** the container. All installs happen in the container —
> never `pnpm install` on the host. System tools belong in `.devcontainer/Dockerfile`.

```bash
pnpm install            # install workspace dependencies (inside the devcontainer)

./run.sh                # start server (4400) + Angular client (4402)
./run.sh --server-only  # start only the game server
./run.sh --client-only  # start only the Angular dev server
./run.sh --stop         # stop all running processes
./run.sh --status       # check what's running
./run.sh --logs         # tail server and client logs
```

Then open two browser tabs at the client to exercise the lobby → create → join → start →
`player_input` ↔ `game_snapshot` flow against the placeholder echo game.

### Validation

```bash
./validate.sh all       # lint + duplication + typecheck + test across all packages
./validate.sh test      # tests only
./validate.sh typecheck # type check only
./validate.sh lint      # eslint + prettier --check
```

### Dev container

```bash
./dev-container.sh          # start or attach to the DinD devcontainer
./dev-container.sh rebuild  # force rebuild
./dev-container.sh stop     # stop the container
```

## MCP visibility (`/debug-mcp`)

The server exposes an HTTP MCP endpoint (`game-debug`) at `http://localhost:4400/debug-mcp`
(configured in `.mcp.json`). Claude Code can inspect live state via tools such as:

- `debug_get_connections` — active WebSocket connections
- `debug_get_performance` / `debug_get_room_performance` — tick timing / broadcast telemetry
- `debug_list_games` / `debug_get_room` — lobby and room membership
- `debug_get_game_state` — the full game-state blob (wired up by your game via
  `DebugContext.getRoomGameState(gameId)`)

## ha-router integration

This template targets the local `ha-router` Traefik reverse proxy. Ready-to-copy integration
artifacts live under `ha-router/` (`route.template.yml` and `landing-card.html`);
see **`ha-router/HA-ROUTER.md`** for how to wire the game into ha-router (route config, host slug,
landing-page card). Final slug, ports, and icon hue are chosen during the init step.

## Trust model

**LOCAL-ONLY play.** Client-side trust where convenient — we do not care about security or
cheating. Prefer simplicity over anti-cheat.
