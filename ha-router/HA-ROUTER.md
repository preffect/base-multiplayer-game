# ha-router Integration — base-multiplayer-game

How to expose this template (or a game realized from it) through the central
Traefik reverse proxy at `*.preffect-ha.preffect-home.net`.

> **HOST vs CONTAINER — read this first.** These files are **reference artifacts** that live
> in the game repo. The actual integration edits happen in the SEPARATE `ha-router` repo
> (`/home/preffect/source/ha-router`), which is **NOT mounted in the devcontainer** — the
> in-container AI cannot read or write it. The work therefore splits in two:
>
> - **In-container AI:** *prepare* artifacts in THIS repo only — write a concrete route file
>   `ha-router/<slug>.yml` (filled in from `route.template.yml`) and a filled-in
>   `ha-router/landing-card.html`, using the values from `PORTS.env`. **Never** attempt to
>   touch `/home/preffect/source/ha-router`. When done, emit the hand-off prompt in **Step 6**.
> - **Host AI / user:** apply those prepared artifacts to the live `ha-router` repo (copy the
>   route file into `config/<slug>.yml`, paste the landing card, verify the URL).

> **Automated:** `new-game.sh` performs Steps 3–4 against the live repo on the host (route file
> with priority-100 API/WS routers, landing card via `insert-landing-card.py` with an unused hue),
> checks DNS (Step 2), and verifies Step 5 through Traefik including that `/api` hit the
> `<slug>-api@file` router. This guide remains the reference for doing it by hand.

Deliverables in this folder:
- `route.template.yml` — Traefik route YAML (3 routers: client / api / ws).
- `landing-card.html` — landing-page game-card snippet.
- `HA-ROUTER.md` — this guide.

---

## Architecture recap (single-port model)

Recommended model (matches `super-morris-girls`): **one backend** on the
server port serves `/api` + `/ws` + `/debug-mcp` from a single Fastify
instance. The Angular dev server serves the UI on the client port.

```
                          host.docker.internal
  Browser ──TLS──▶ Traefik ──┬─ /api  ─▶ <server-port>  (Fastify: API)
                             ├─ /ws   ─▶ <server-port>  (Fastify: WebSocket)
                             └─ *     ─▶ <client-port>  (Angular dev server)
```

Three routers, all on `Host(<slug>.preffect-ha.preffect-home.net)`:
- `<slug>-api` — `PathPrefix(/api)`, priority 100 → `<slug>-api` service (server port)
- `<slug>-ws`  — `PathPrefix(/ws)`,  priority 100 → `<slug>-api` service (server port)
- `<slug>`     — catch-all          → `<slug>` service (client port)

Do NOT add a separate WebSocket entrypoint/port (that's the older treebeards
dual-port pattern). `/ws` rides the standard `websecure` entrypoint to the
single backend — simpler and matches the template's single-Fastify design.

---

## Step 1 — Ports are pre-selected on the host (read `PORTS.env`)

> **In-container: do NOT pick ports.** `new-game.sh` already chose a free pair on the HOST —
> verified against host listeners AND the live `ha-router` config (which the container cannot
> see) — and recorded it in **`PORTS.env`** at the repo root:
>
> ```
> SERVER_PORT=<server>
> CLIENT_PORT=<client>
> SLUG=<slug>
> ```
>
> Use those values everywhere. They are already baked into the eight integration files
> (`packages/server/src/index.ts`, `packages/client/angular.json`,
> `packages/client/proxy.conf.json` ×3, `.devcontainer/devcontainer.json`, `dev-container.sh`,
> `run.sh`, `.mcp.json`). Verify those files agree with `PORTS.env`; if any disagree, fix them
> toward `PORTS.env`. Do **not** re-run the live port scan below from inside the container.

<details><summary>(host reference) how the host picks the pair — for context only</summary>

`new-game.sh` lists every host port already claimed in the live `ha-router` repo and avoids
them, capping the pair below 4800 (server even, client = server + 2):

```bash
# every host port currently claimed by ha-router backends + traefik entryPoints:
grep -rhoE 'host\.docker\.internal:[0-9]+' ha-router/config | grep -oE '[0-9]+$' | sort -un
# (also scans traefik.yml entryPoints, e.g. :7778)
```

It also confirms nothing on the host is bound (`ss -ltn`). This already happened before the
container existed — `PORTS.env` is the result. The container has no reason to repeat it.

</details>

---

## Step 2 — Choose a slug and host

- Slug default: **`base-mp`** (the host label and URL slug).
- Host becomes: `https://<slug>.preffect-ha.preffect-home.net`.
- TLS: the cert is wildcard via the Cloudflare DNS-01 resolver
  (`certResolver: cloudflare`), so a new `<slug>` needs **no new cert**.
- DNS: there is **NO wildcard DNS record**. The LAN resolver is the UniFi gateway
  (192.168.1.1) and every `<slug>.preffect-ha.preffect-home.net` has its **own A record
  → 192.168.1.180** (the Traefik host). A new slug therefore **needs a new DNS record**,
  added on the HOST via the `unifi` MCP (`plan_dns_record` → `apply_dns_record`, in the
  `unify-mcp` project) or the UniFi UI. Until it exists the URL will not resolve
  (`getent hosts <slug>.preffect-ha.preffect-home.net` → no answer) even though the
  Traefik route is live.
- Backends are reached over `http://host.docker.internal:<port>` because the
  game runs on the host (dev servers), not inside the Traefik container.

---

## Step 3 — Create the route config

> **In-container:** you can't reach the live ha-router repo. Instead, write a *filled-in copy*
> of `route.template.yml` to `ha-router/<slug>.yml` in THIS repo (placeholders replaced from
> `PORTS.env`). The HOST then copies it into `ha-router/config/<slug>.yml` per below.

1. Copy `route.template.yml` (this folder) to the ha-router repo:
   `ha-router/config/<slug>.yml`  (e.g. `ha-router/config/base-mp.yml`).
2. Replace placeholders in the copy:
   - `<slug>`        → your slug (e.g. `base-mp`)
   - `<server-port>` → your server port (e.g. `4400`)
   - `<client-port>` → your client port (e.g. `4402`)
3. Save. Traefik's file provider runs with `watch: true`, so it picks the file
   up **automatically — no restart needed**. (Per ha-router/CLAUDE.md: "Create
   a new YAML file in config/ … Traefik picks it up automatically.")

Optional extras (left commented in the template):
- `<slug>-mcp` router (`PathPrefix(/debug-mcp)`) — only if you want the MCP
  debug endpoint reachable remotely. Normally MCP is used over localhost, so
  leave it off.
- HTTP/2 WebSocket fix — if `/ws` fails to upgrade behind TLS, pin TLS to
  HTTP/1.1 by adding `options: <slug>-no-h2@file` to each router's `tls:` block
  and appending the `tls.options.<slug>-no-h2` block (mirrors `solar-drift.yml`).
  Only do this if WS actually breaks.

---

## Step 4 — Add the landing-page card

> **In-container:** fill in the placeholders in THIS repo's `ha-router/landing-card.html`
> (display name, `<slug>`, icon hue). The HOST pastes the finished card into the live
> `ha-router/landing/index.html` per below — the container cannot edit that file.

1. Open `ha-router/landing/index.html`.
2. Find the Games section: the `<!-- Games -->` comment, then
   `<div class="cards">` (opens around **line 292**).
3. Paste the `<a class="card"> … </a>` block from `landing-card.html` (this
   folder) as a **sibling** of the existing game cards, inside that
   `<div class="cards">`.
4. Replace placeholders: `<display-name>`, `<slug>`, the icon RGB
   (`<r>,<g>,<b>`) + matching hex (`<#hex>`), and the inner `<icon-svg>`.

Pick an **unused** icon hue. Hues already taken by Games cards:
- Treebeard's Revenge `#22c55e` (34,197,94)
- Solar Drift `#38bdf8` (56,189,248)
- Empires `#ef4444` (239,68,68)
- Constructors `#fb923c` (251,146,60)
- Super Morris Girls `#ec4899` (236,72,153)

Suggested free hue for this template: **lime `#a3e635` (163,230,53)**.
`landing-card.html` includes a fully filled-in lime example you can paste
directly if you keep the `base-mp` slug and "Base Multiplayer Game" name.

The landing page is static HTML served by Traefik; the edit is live on next
page load (no build/restart).

---

## Step 5 — Verify

1. Start the game locally: `./run.sh` (server on `<server-port>`, client on
   `<client-port>`).
2. Browse to `https://<slug>.preffect-ha.preffect-home.net` — the Angular UI
   (room browser) should load over TLS.
3. Confirm `/api` works: `https://<slug>.preffect-ha.preffect-home.net/api/health`
   → `{"status":"ok"}`.
4. Confirm `/ws` upgrades: open two tabs, create/join/start a game, and watch
   `player_input` ↔ `game_snapshot` flow (the echo `GameModule`). If the WS
   handshake fails, apply the HTTP/2 fix from Step 3.
5. Confirm the landing card appears in the Games section and links to the host.

---

## Step 6 — Hand off to the host AI (REQUIRED — do this last)

You (the in-container AI) **cannot apply** the ha-router changes — that repo isn't mounted.
So once the artifacts are prepared (`ha-router/<slug>.yml` and the filled-in
`ha-router/landing-card.html`), finish the session by **printing the prompt below for the user
to paste to the HOST AI** (the one running in `/home/preffect/source`). Substitute the real
values from `PORTS.env` first, then print it verbatim:

```text
Finish the ha-router integration for the game "<slug>" (repo: /home/preffect/source/<slug>).
Everything is already prepared inside that repo — apply it to the live ha-router repo at
/home/preffect/source/ha-router:

1. Copy the prepared route config /home/preffect/source/<slug>/ha-router/<slug>.yml
   (filled in: slug <slug>, server port <server-port>, client port <client-port>)
   to /home/preffect/source/ha-router/config/<slug>.yml.
   Traefik's file provider (watch:true) picks it up automatically — no restart.
2. Paste the card from /home/preffect/source/<slug>/ha-router/landing-card.html into
   /home/preffect/source/ha-router/landing/index.html, inside the `<!-- Games -->`
   `<div class="cards">` block. Use an icon hue not already used by another card.
3. Verify https://<slug>.preffect-ha.preffect-home.net loads the UI, /api/health returns
   {"status":"ok"}, and /ws upgrades (create/join/start a game in two tabs).

Report back the live URL when done.
```

The user passes that prompt to the host AI, which performs Steps 3–5 against the live repo.

---

## Reference

- Real ha-router configs live in `ha-router/config/*.yml`. The single-port
  model here mirrors `super-morris-girls.yml`. `solar-drift.yml` shows the
  optional HTTP/1.1 TLS-options pin; `treebeards-revenge.yml` shows the older
  dual-port model — do NOT copy that one.
- ha-router operations: `./run.sh {start|stop|status|logs}` in the ha-router
  repo. Adding a route never needs a restart (file provider watch).
