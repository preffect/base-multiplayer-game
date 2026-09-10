# Define Your Multiplayer Game

You are running this prompt against a game scaffolded from **`base-multiplayer-game`** — a
working multiplayer TEMPLATE whose game definition is **DEFERRED**. Connect / reconnect /
identity, the lobby, rooms, the 60 Hz broadcast loop, MCP game-state visibility, and ha-router
integration ALL work today against a placeholder **echo** game.

Your job in this session is **NOT to write game code**. It is to:

1. Read this prompt and the wiring notes below so you understand every extension point.
2. **Interview the user** with the focused questions in the "Interview" section.
3. Once every question is answered, **produce two things**: `docs/GAME-DESIGN.md` (what the game IS —
   decisions, numbers, contracts) and the **first build epic with its tickets on GitHub** (what
   gets built first, one ticket per unit of work with exact file paths and interfaces).
   Planning lives in issues, never in a markdown plan.
4. Remove this prompt and the "START HERE" banner (section 8).

> **Build environment — assume you are INSIDE the devcontainer.** This prompt and every
> prompt it generates run inside the devcontainer (`./dev-container.sh` from the host opens
> it). All dependency installs (`pnpm install`, `./run.sh --install`) and all commands
> (`./validate.sh`, `./run.sh`) happen INSIDE the container — never install on the host.
> System tools belong in `.devcontainer/Dockerfile`, project deps in the workspace via pnpm.

---

## Where this fits in the process

`new-game.sh` already: registered the game in ha-router, built the devcontainer, verified the
public URL, and seeded GitHub with the **groundwork epics** (devcontainer verified, tooling/MCP,
team, quality gates, testing foundations, design, architecture/build plan) plus the project board
and branch ruleset. Your output — `docs/GAME-DESIGN.md` and the first build epic — is the work of the
"Game design" and "Architecture and build plan" epics; file game-specific design tickets under
the design epic as the interview reveals them. Follow **`docs/WORKFLOW.md`** for tickets, the board,
the waiting-on-human rule, and the PR/review rules. **Epics scope one phase of groundwork, never
the whole game** — later build phases go in the roadmap issue until the user approves them.

## How the template is wired (READ before interviewing)

- **One Fastify server on port 4400** serves `/api` + `/ws` + `/debug-mcp`. The Angular
  client runs on **4402** and proxies those three paths to 4400 (`packages/client/proxy.conf.json`).
- **Standards (READ and enforce):** `docs/ENGINEERING.md` (the `./validate.sh all` gate, testing,
  TS/lint, architecture, Definition of Done), `docs/ASSET-GENERATION.md` (the code-drawn visual
  quality bar), and `docs/AUDIO-PIPELINE.md` (the opt-in Google-default audio pipeline). Every edit
  the tickets prescribe must comply with these; every ticket body references them.
- **Generic message envelope** lives in `packages/shared/src/types/messages.ts`:
  - Client → Server gameplay verb: `player_input { type:'player_input', payload: GameInput }`.
  - Server → Client gameplay verb: `game_snapshot { type:'game_snapshot', snapshot: GameSnapshot }`.
  - Lobby verbs (`join_lobby`, `update_player_info`, `create_game`, `join_game`,
    `start_game`, `delete_game`, `client_performance`) and lobby responses
    (`lobby_update`, `game_started`, `game_state`, `player_joined`, `player_disconnected`,
    `error`) already work — leave them alone unless the game needs new lobby fields.
  - `GameInput`, `GameSnapshot`, and `GameSessionConfig` are the **only** game-defined
    types. They are currently `unknown` / `{ maxPlayers }` TODO hooks.
- **The ONE server game seam** is `packages/server/src/game/game-module.ts`. It defines the
  `GameModule` interface (`submitInput` / `reduceGameState` / `serializeRoomState` /
  `addPlayer` / `removePlayer` / optional `free`) and a `GameModuleFactory`.
  `defaultGameModuleFactory` is a trust-client **echo** (stores latest input per player,
  echoes `{ players: { [pid]: lastInput } }`). `packages/server/src/index.ts` wires it in.
- **The room loop** lives in `packages/server/src/lobby/game-room.ts`. It calls the three
  `GameModule` hooks each tick: `reduceGameState()` → `serializeRoomState()` → broadcast
  `game_snapshot`. All connection / late-join / disconnect-grace / reattach plumbing is
  generic and done — game logic only touches the `GameModule`.
- **Lobby/room lifecycle** lives in `packages/server/src/lobby/lobby-manager.ts` (created
  with a `GameModuleFactory`). `onPlayerInput` forwards to `room.submitInput`.
- **The message validation seam** is `packages/server/src/ws/message-schemas.ts`. The
  `player_input` payload is `z.unknown()` (local-only, we trust the client) and
  `create_game.config` has a `passthrough()` with a `maxPlayers` field — both marked TODO.
  Add new client verbs in `message-router.ts` / `message-schemas.ts` if (and only if) the
  game needs them.
- **MCP game-state seam:** `packages/server/src/mcp/debug-context.ts` exposes an optional
  `getRoomGameState(gameId): unknown`. The MCP tool `debug_get_game_state`
  (`packages/server/src/mcp/handlers/game-state.ts`) returns whatever it yields, or a
  "not wired yet" note. Other MCP tools (`debug_get_connections`, `debug_list_games`,
  `debug_get_room`, `debug_get_performance`, `debug_get_room_performance`) are generic and
  already work. Add game-specific tools as new files under `packages/server/src/mcp/handlers/`.
- **The ONE client game seam** is `packages/client/src/app/game/game-setup.ts`
  (`setupGame({ send, messages$, drainLatestSnapshot })`) — the entire game loop +
  renderer goes here. Supporting client pieces:
  - `packages/client/src/app/services/websocket.service.ts` — WS transport, reconnect,
    outbound queue, `drainLatestSnapshot()` snapshot-coalescing fast path (do not touch).
  - `packages/client/src/app/services/identity.service.ts` — stable `base-mp.clientId`.
  - `packages/client/src/app/services/multiplayer.service.ts` — generic signal state
    (`connected`, `phase`, `playerId`, `gameId`, `playerIds`, `games`, `sessionConfig`,
    `snapshot`) plus the lobby/input send methods; snapshot/config handling is TODO.
  - `packages/client/src/app/app.component.ts` — stub lobby UI (connect / create / join /
    start / delete + snapshot JSON view); the `create_game` config payload (`createGame()`)
    is a TODO. This is the host component where the real game view mounts `setupGame()`.
- **Trust model: LOCAL-ONLY.** Default is to trust the client wholesale; there is no
  anti-cheat. Prefer simplicity. Only the few values the server must own (score, lives,
  win/lose, collisions) get computed in `reduceGameState` and merged into the snapshot.
- **No persistence, no physics engine, no `@fastify/static`.** Add persistence only if the
  game truly needs saved state.
- **ha-router integration is already done** by `new-game.sh` on the host (Traefik route,
  landing card, DNS check); the public URL is in `README.md`. Nothing to prepare here.

---

## DEFERRED REQUIREMENTS you must resolve (the 12-item list)

These are the decisions the template intentionally left open. Your interview must resolve
ALL of them, and `docs/GAME-DESIGN.md` must make each concrete.

1. **Identity** — game name, one-line theme/concept, URL slug, display title, landing-card
   icon hue.
2. **Ports** — **already chosen for you; do NOT pick or re-verify them.** `new-game.sh`
   selected a free pair on the host (checked against the live `ha-router` config the container
   can't see) and recorded it in **`PORTS.env`** (`SERVER_PORT`/`CLIENT_PORT`/`SLUG`) — read
   that file and use those values. They're already baked into the eight integration files;
   just confirm those files agree with `PORTS.env`. Use the slug + ports to _prepare_ the
   ha-router route YAML + landing card (see Identity for the icon hue).
3. **Player model** — max players; avatars (indexed 0–5) vs named characters; teams/roles.
4. **Tick model** — real-time fixed-tick (keep 60 Hz `game_snapshot`) vs turn-based
   (lower / event-driven broadcast).
5. **`GameInput` shape** — what a player sends each tick/turn
   (`message-schemas.ts` payload schema + `messages.ts GameInput`).
6. **`GameSnapshot` + `GameSessionConfig` shapes** — what clients render each tick, and
   the per-session create-time config (`messages.ts`, `createGameSchema.config`).
7. **Client-trust boundary** — default = trust client wholesale (local-only). Identify any
   server-authoritative values computed in `reduceGameState` and merged into the snapshot.
8. **Server `GameModule` impl** — `submitInput` / `reduceGameState` / `serializeRoomState`
   / `add`/`removePlayer` (`game-module.ts`), and wire the real factory into `index.ts`.
9. **Persistence** — none by default; specify what + where only if the game needs it.
10. **MCP game-state visibility** — implement `getRoomGameState(gameId)` and wire it into
    the `DebugContext` in `index.ts`; optionally add game-specific MCP tools.
11. **Client rendering** — the `game/game-setup.ts` loop + renderer (canvas/DOM/Pixi/etc.),
    and the `app.component.ts` `create_game` config payload.
12. **Session config fields** — the `createGameSchema.config` TODO (beyond `maxPlayers`).

---

## Interview — ASK THESE QUESTIONS (group sensibly; do NOT generate until answered)

Ask conversationally; you may group related questions. Do not proceed to generation until
every item below has an answer (mark any "use the default" answers explicitly).

**A. Identity & hosting**

1. Game name, one-line theme/concept, URL slug, and display title?
2. Ports: do NOT ask the user — they're pre-selected in `PORTS.env` (`SERVER_PORT`/`CLIENT_PORT`/`SLUG`);
   read them. Just confirm the slug from `PORTS.env` for the ha-router host
   `<slug>.preffect-ha.preffect-home.net`. The only thing to ask here is the landing-card icon
   hue (hex, e.g. lime `#a3e635`).

**B. Players & session** 3. Player model: max players? Indexed avatars (0–5) or named characters? Any teams/roles? 4. What lives in the per-game session CONFIG at create time, beyond `maxPlayers`
(seed, mode, map, difficulty, round count)? 5. Win/lose / round / level structure? Is late-join allowed (the template supports it)?

**C. Tick & networking** 6. Real-time (fixed-tick) or turn-based? If real-time, is 60 Hz right or should the
broadcast be slower? If turn-based, what event triggers a broadcast? 7. What is a player's INPUT each tick/turn? (exact fields → `GameInput`) 8. What is the SHARED GAME STATE clients render each tick? (exact fields → `GameSnapshot`)

**D. Authority & persistence** 9. Authority: anything the SERVER must own (score, lives, win/lose, collisions, spawn)?
Or pure client-trust? (Default: trust the client wholesale.) 10. Persistence: must any state survive a restart? If so, what and where?

**E. Rendering & MCP** 11. Rendering approach: HTML canvas/2D, plain DOM, Pixi, Three.js, text? Any existing
assets or art direction? 12. MCP: which game-state details should Claude be able to inspect via
`debug_get_game_state`? Any extra game-specific MCP tools (entities, tiles, scores)?

---

## After answers — PRODUCE `docs/GAME-DESIGN.md` and the first build epic

**`docs/GAME-DESIGN.md`** holds sections 1, 5 and 6 below plus every rule and number the interview
settled (constants named as they will appear in `packages/shared/src/constants/*`). It states
decisions, not tasks.

**The first build epic** (`gh issue create`, labels from `docs/WORKFLOW.md` §2, milestone
"M2 First playable"; link tickets as sub-issues with ONE batched `addSubIssue` GraphQL request)
scopes only the first playable slice. One ticket per unit of work, in this order, each carrying
the exact file paths, interfaces and acceptance criteria from sections 2–4 and 7:

1. shared contract (section 2) · 2. server module (section 3) · 3. client (section 4) ·
2. game-specific MCP tools · 5. verification (section 7). Later phases go in the roadmap issue.

Use exact file paths and real code blocks in ticket bodies (no open questions, no
`<PLACEHOLDERS>`). A build team executes the tickets verbatim, one PR each.

### 1. Game Definition

Name, theme, slug, display title, ports, icon hue, player model, tick model, win/lose,
late-join policy, persistence decision, trust boundary.

### 2. Shared type edits — `packages/shared/src/types/messages.ts`

Exact `GameInput` interface, exact `GameSnapshot` interface, exact `GameSessionConfig`
fields (replacing the `unknown` / `{ maxPlayers }` TODO hooks). Add constants to
`packages/shared/src/index.ts` if needed.

### 3. Server edits

- `packages/server/src/ws/message-schemas.ts` — replace `playerInputSchema` payload
  `z.unknown()` with the real input schema; add fields to `createGameSchema.config`.
- `packages/server/src/ws/message-router.ts` — add new client message cases only if needed.
- `packages/server/src/game/game-module.ts` — full `GameModule` impl + factory (the game
  tick logic), replacing `defaultGameModuleFactory`.
- `packages/server/src/index.ts` — import the real factory; wire `getRoomGameState` into
  the MCP `DebugContext`.
- `packages/server/src/mcp/handlers/*` — any new game-specific MCP tools.
- `packages/server/src/lobby/game-room.ts` / `lobby-manager.ts` — only if the game needs
  hooks beyond the existing seams (usually untouched).

### 4. Client edits

- `packages/client/src/app/game/game-setup.ts` — implement `setupGame({ send, messages$,
drainLatestSnapshot, host? })`: an input loop calling `send(gameInput)` (wraps
  `player_input`) + a `drainLatestSnapshot()` render loop + renderer for the chosen approach.
- `packages/client/src/app/services/multiplayer.service.ts` — snapshot/state signals and any
  new lobby/input send methods.
- `packages/client/src/app/app.component.ts` — real `create_game` config payload
  (`createGame()`), lobby UI, and mounting the game view via `setupGame`.

### 5. Ports & config

The ports come from `PORTS.env` (`SERVER_PORT`/`CLIENT_PORT`/`SLUG`) — do NOT change them.
Verify they are consistent across `packages/server/src/index.ts`,
`packages/client/angular.json`, `packages/client/proxy.conf.json`,
`.devcontainer/devcontainer.json`, `dev-container.sh`, `run.sh`, `.mcp.json`, `CLAUDE.md`
(they should already match, baked in by `presetup.sh`; state "no change" if so, otherwise fix
toward `PORTS.env`).

### 6. Public URL

Already routed by `new-game.sh` (host): `https://<slug>.preffect-ha.preffect-home.net` with the
slug from `PORTS.env`. Only record it in `docs/GAME-DESIGN.md`; do not create route files here.

### 7. Verification

Run everything INSIDE the devcontainer (open it from the host with `./dev-container.sh`):
`pnpm install`; `./validate.sh all`; `./run.sh`; open two browser tabs on the client port;
confirm the lobby → create → join → start → snapshot flow; send `player_input` and observe
`game_snapshot`; query `debug_get_game_state` via the `game-debug` MCP server.

Additionally, every build ticket MUST instruct the build team to:

- treat **`docs/ENGINEERING.md`** as binding: extract game logic into pure functions with unit tests
  (happy/edge/error), add `*.integration.test.ts` for input→reduce→snapshot and lobby→room→
  broadcast wiring, validate every new WS verb in `message-schemas.ts`, and make
  **`./validate.sh all` green** with the **Definition of Done** satisfied before declaring done;
- meet **`docs/ASSET-GENERATION.md`**'s per-asset checklist for every visual asset in
  `game-setup.ts` (layered, shaded, palette-named, animated, silhouette-legible — no flat
  rectangles);
- if the game has audio, stand up **`docs/AUDIO-PIPELINE.md`** (`ai-pipeline.sh` + `tools/` + the
  `.env.example` keys, Google/Gemini default) and leave `./ai-pipeline.sh check` clean — never
  running `sync` unsolicited.

---

Do not write any template source code in this session — only interview, write `docs/GAME-DESIGN.md`,
file the epic and tickets, and clean up.

### 8. Cleanup — the game is now defined

As the last action of this session, remove the scaffolding that only made sense before the
game existed, in the same PR as `docs/GAME-DESIGN.md`:

- delete `docs/INIT-GAME.md` (this file);
- delete the "START HERE — is this game defined yet?" banner at the top of `CLAUDE.md` and
  replace the Architecture paragraph's "extension points to be filled in" wording with a
  sentence about this game;
- replace the "Status: not yet defined" banner in `README.md` with the game's one-line
  description and its public URL;
- make sure `package.json`'s root `description` names this game.

Nothing else in the repo refers to this prompt; `scripts/sync-from-template.sh` never brings it back.
