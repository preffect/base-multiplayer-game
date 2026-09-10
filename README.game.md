# Base Multiplayer Game

> **Status: not yet defined.** This game still runs the placeholder **echo** game. The next step
> is the init interview — open the devcontainer and follow the **START HERE** banner in `CLAUDE.md`.
> Replace this paragraph with the game's own description once `init-game.md` exists.
> Scaffolded from the `base-multiplayer-game` template; template-level fixes go upstream there. <!-- KEEP_TEMPLATE_NAME -->

Multiplayer client/server game: Angular client, Fastify + WebSocket server, a 60 Hz snapshot
loop, lobby/rooms/reconnect, and a debug MCP endpoint for agents. Details in
[`CLAUDE.md`](./CLAUDE.md).

## Run it

Everything runs **inside the devcontainer**; ports come from `PORTS.env`.

```bash
./dev-container.sh          # host: build/start + attach (DEVCONTAINER_YES=1 for non-interactive)
./validate.sh all           # container: lint + typecheck + test — builds packages/shared first
./run.sh                    # container: server + client (see PORTS.env for the ports)
```

- Local: `http://localhost:<CLIENT_PORT>` — public: `https://base-mp.preffect-ha.preffect-home.net`
  (Traefik route + landing card in the ha-router repo, applied by the template's `new-game.sh`;
  per-host DNS record required — see `ha-router/HA-ROUTER.md` in `base-multiplayer-game`). <!-- KEEP_TEMPLATE_NAME -->

## How work happens

- **[`WORKFLOW.md`](./WORKFLOW.md)** — GitHub issues, the project board, the waiting-on-human
  rule, PR + review rules, keeping docs in sync. Scripts: `scripts/project-sync.sh`,
  `scripts/issue-status.sh`, `scripts/github-setup.sh`.
- **[`ENGINEERING.md`](./ENGINEERING.md)**, **[`ASSET-GENERATION.md`](./ASSET-GENERATION.md)**,
  **[`AUDIO-PIPELINE.md`](./AUDIO-PIPELINE.md)** — the quality bar every PR is held to.
- **[`init-game-prompt.md`](./init-game-prompt.md)** → `init-game.md` — how the game gets defined.

## Layout

`packages/shared` (types, constants), `packages/server` (Fastify + WS + MCP), `packages/client`
(Angular). Game extension points are marked `// TODO(game)` / `// TODO(init)`; see `CLAUDE.md`.
