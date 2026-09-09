# init-game.md (GENERATED ARTIFACT — skeleton)

> **This file is a placeholder skeleton.** It is **generated/overwritten** by running
> `init-game-prompt.md` (the init step interviews the user, then writes the concrete,
> build-ready version here). Everything below is a `<PLACEHOLDER>` template with one
> illustrative example so you can see the target artifact. Do NOT execute this skeleton —
> run the init step first to produce the real, filled-in `init-game.md`.

---

## 1. Game Definition

- **Name:** `<GAME_NAME>`
- **Theme / concept:** `<ONE_LINE_CONCEPT>`
- **Slug / host:** `<slug>` → `<slug>.preffect-ha.preffect-home.net`
- **Display title:** `<DISPLAY_TITLE>`
- **Ports:** server `<SERVER_PORT|4400>`, client `<CLIENT_PORT|4402>`
- **Landing-card icon hue:** `<HEX_COLOR>`
- **Player model:** max `<N>` players; `<indexed avatars 0–5 | named characters>`;
  teams/roles: `<NONE | description>`
- **Tick model:** `<real-time fixed-tick @ <HZ>Hz | turn-based, broadcast on <EVENT>>`
- **Win/lose / structure:** `<description>`
- **Late-join:** `<allowed | disallowed>`
- **Persistence:** `<none | what + where>`
- **Trust boundary:** `<pure client-trust | server owns: <list>>`

<details><summary>EXAMPLE (illustrative only — a tiny "Tag" game)</summary>

- **Name:** Tag Arena · **Concept:** 2D top-down tag; "it" chases everyone.
- **Slug:** `tag-arena` → `tag-arena.preffect-ha.preffect-home.net`
- **Display title:** Tag Arena · **Ports:** 4400 / 4402 (no change) · **Hue:** `#a3e635`
- **Players:** max 4, indexed avatars 0–3, no teams.
- **Tick:** real-time, 60 Hz `game_snapshot`.
- **Win/lose:** lowest "time as it" when the 90s round ends. Late-join allowed.
- **Persistence:** none. **Trust:** server owns positions/collisions/who-is-it.

</details>

---

## 2. Shared type edits — `packages/shared/src/types/messages.ts`

Replace the `unknown` / `{ maxPlayers }` TODO hooks:

```ts
// GameInput
export interface GameInput { <FIELDS> }
// GameSnapshot
export interface GameSnapshot { <FIELDS> }
// GameSessionConfig
export interface GameSessionConfig { maxPlayers: number; <EXTRA_FIELDS> }
```

<details><summary>EXAMPLE</summary>

```ts
export interface GameInput {
  moveX: number;
  moveY: number;
} // -1..1
export interface GameSnapshot {
  tick: number;
  players: Record<string, { x: number; y: number; isIt: boolean; avatarIndex: number }>;
  itPlayerId: string | null;
  timeLeftMs: number;
}
export interface GameSessionConfig {
  maxPlayers: number;
  roundMs: number;
}
```

</details>

---

## 3. Server edits

### `packages/server/src/ws/message-schemas.ts`

Replace `playerInputSchema` payload `z.unknown()` and extend `createGameSchema.config`:

```ts
const playerInputSchema = z.object({ type: z.literal('player_input'),
  payload: z.object({ <FIELDS> }) });
// createGameSchema.config:
config: z.object({ maxPlayers: z.number().int().min(1).max(8), <EXTRA_FIELDS> }).passthrough()
```

### `packages/server/src/game/game-module.ts`

Replace `defaultGameModuleFactory` with the real `GameModuleFactory`:

```ts
export const <gameName>ModuleFactory: GameModuleFactory = (args) => {
  // <state>
  return {
    submitInput(pid, payload) { /* <store input> */ },
    reduceGameState() { /* <advance world one tick; compute server-owned values> */ },
    serializeRoomState() { /* return <GameSnapshot> */ },
    addPlayer(pid, avatarIndex, name) { /* ... */ },
    removePlayer(pid) { /* ... */ },
    free() { /* optional cleanup */ },
  };
};
```

### `packages/server/src/index.ts`

- Import and pass the real factory: `new LobbyManager(<gameName>ModuleFactory)`.
- Wire MCP game-state: `registerMcpEndpoint(server, { lobbyManager, connections,
getRoomGameState: (gid) => lobbyManager.getActiveRoom(gid)?.getSnapshot() })`.

### `packages/server/src/ws/message-router.ts`

Add cases only for any NEW client verbs: `<list or "none">`.

### `packages/server/src/mcp/handlers/*`

New game-specific MCP tools: `<list or "none beyond debug_get_game_state">`.

<details><summary>EXAMPLE (Tag Arena GameModule sketch)</summary>

```ts
export const tagModuleFactory: GameModuleFactory = (args) => {
  const pos = new Map<string, { x: number; y: number }>();
  const input = new Map<string, { moveX: number; moveY: number }>();
  let it = args.playerIds[0] ?? null;
  let timeLeftMs = args.config.maxPlayers /* example */ && 90_000;
  for (const p of args.playerIds) pos.set(p, { x: 0, y: 0 });
  return {
    submitInput: (pid, payload) => {
      input.set(pid, payload as any);
    },
    reduceGameState: () => {
      /* integrate input, clamp, check tag collision, set `it` */
    },
    serializeRoomState: () => ({
      tick: 0,
      players: {
        /*...*/
      },
      itPlayerId: it,
      timeLeftMs,
    }),
    addPlayer: (pid) => pos.set(pid, { x: 0, y: 0 }),
    removePlayer: (pid) => {
      pos.delete(pid);
      input.delete(pid);
    },
  };
};
```

</details>

---

## 4. Client edits

### `packages/client/src/app/game/game-setup.ts`

Implement `setupGame({ send, messages$, drainLatestSnapshot })`:

- each tick: `send({ moveX, moveY })` → goes out as `player_input`.
- each frame: `drainLatestSnapshot()` → render `<GameSnapshot>` via `<RENDER_APPROACH>`.

### `packages/client/src/app/app.component.ts`

Host component / lobby UI. Real `create_game` config payload in `createGame()`:
`{ maxPlayers: <N>, <EXTRA_FIELDS> }`. Mount the game view via `setupGame(...)`. UI: `<notes>`.

### `packages/client/src/app/services/multiplayer.service.ts`

Snapshot/state signals to expose: `<list>`; any new lobby/input send methods.

---

## 5. Ports & config

> Ports are pre-selected in `PORTS.env` (`SERVER_PORT`/`CLIENT_PORT`/`SLUG`) — do NOT pick or
> re-verify them. Just confirm they're consistent across the integration files.

`<"No change — values from PORTS.env already baked into all files." | the files fixed to match
PORTS.env: packages/server/src/index.ts, packages/client/angular.json, proxy.conf.json,
.devcontainer/devcontainer.json, dev-container.sh, run.sh, .mcp.json, CLAUDE.md.>`

---

## 6. ha-router integration

> The devcontainer can't reach the live `ha-router` repo — only *prepare* the artifacts here;
> the HOST applies them. End the session by emitting the Step 6 hand-off prompt from `ha-router/HA-ROUTER.md`.

- **`ha-router/<slug>.yml`** (prepared in THIS repo) — from `ha-router/route.template.yml`
  with `<slug>` and ports `<SERVER_PORT>` / `<CLIENT_PORT>` (from `PORTS.env`) filled in.
  The host copies it to the live `ha-router/config/<slug>.yml`.
- **Landing card** — `ha-router/landing-card.html` filled with `<slug>`,
  `<DISPLAY_TITLE>`, and icon hue `<HEX_COLOR>`; the host inserts it into the live
  `ha-router/landing/index.html` inside the Games `<div class="cards">`.
- See `ha-router/HA-ROUTER.md` (boundary note + Step 6 hand-off) for the procedure.

---

## 7. Verification

Run everything INSIDE the devcontainer (open it from the host with `./dev-container.sh`;
all installs happen in the container, never on the host):

1. `pnpm install`
2. `./validate.sh all` (lint + typecheck + test green)
3. `./run.sh` → server `<SERVER_PORT>`, client `<CLIENT_PORT>`
4. Open two browser tabs → room browser → create → join → start.
5. Confirm `player_input` ↔ `game_snapshot` exchange renders correctly.
6. Query `debug_get_game_state` via the `game-debug` MCP server and confirm real state.
