# Base Multiplayer Game

> **Status: not yet defined.** This game still runs the placeholder **echo** game. The next step
> is the init interview — open the devcontainer and follow the **START HERE** banner in `CLAUDE.md`.
> Replace this paragraph with the game's own description once `docs/GAME-DESIGN.md` exists.
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
  per-host DNS record required).

## How work happens

- **[`docs/WORKFLOW.md`](docs/WORKFLOW.md)** — GitHub issues, the project board, the waiting-on-human
  rule, PR + review rules, keeping docs in sync. Scripts: `scripts/project-sync.sh`,
  `scripts/issue-status.sh`, `scripts/github-setup.sh`.
- **[`docs/ENGINEERING.md`](docs/ENGINEERING.md)**, **[`docs/ASSET-GENERATION.md`](docs/ASSET-GENERATION.md)**,
  **[`docs/AUDIO-PIPELINE.md`](docs/AUDIO-PIPELINE.md)** — the quality bar every PR is held to.
- **[`docs/INIT-GAME.md`](docs/INIT-GAME.md)** — how the game gets defined: the interview produces
  `docs/GAME-DESIGN.md` and the first build epic with its tickets on GitHub.

## Layout

`packages/shared` (types, constants), `packages/server` (Fastify + WS + MCP), `packages/client`
(Angular). Game extension points are marked `// TODO(game)` / `// TODO(init)`; see `CLAUDE.md`.
