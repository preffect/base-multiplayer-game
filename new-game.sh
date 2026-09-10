#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# new-game.sh — scaffold a new multiplayer game from the base-multiplayer-game template.
#
# Runs ALL the boilerplate learned from real games (evolution, 2026-09), in order:
#   1. copy the template, pick a FREE host port pair, instantiate (./presetup.sh)
#   2. ha-router: write config/<slug>.yml + landing card into the LIVE ha-router repo
#      (Traefik picks both up without a restart) and check the per-host DNS record
#   3. devcontainer: build + start non-interactively, ./validate.sh all (builds
#      packages/shared, which the client needs), ./run.sh, then verify the public URL
#      through Traefik (UI 200, /api/health via the -api router, /ws upgrade 101)
#   4. GitHub: repo, labels, milestones, project board + views, groundwork epics,
#      branch ruleset (./scripts/github-setup.sh)
#   5. attach to the container if you are on a TTY
#
# Usage:
#   ./new-game.sh <game-name> [--title "Display Title"] [--slug <slug>]
#                 [--server-port N] [--client-port M]
#                 [--no-start] [--no-ha-router] [--no-github] [--private]
#
#   <game-name>   folder + project name; lowercase kebab-case (e.g. space-raiders)
#   --title       display title shown in UI/landing card (default: Title Case of name)
#   --slug        URL slug + host label (default: the game name)
#   --server-port / --client-port   pin ports explicitly (default: auto-pick a free pair)
#   --no-start    stop after instantiation; skip devcontainer, verification, GitHub
#   --no-ha-router  skip the live ha-router edits (route + landing card + DNS check)
#   --no-github   skip GitHub repo/board setup
#   --private     create the GitHub repo private (default public)
#
# Examples:
#   ./new-game.sh space-raiders
#   ./new-game.sh space-raiders --title "Space Raiders" --private
#   ./new-game.sh tag-arena --server-port 4410 --client-port 4412 --no-start
# ---------------------------------------------------------------------------

# This script lives IN the template repo; games are created as siblings of it.
TEMPLATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(dirname "$TEMPLATE")"
HA_ROUTER="$SOURCE_DIR/ha-router"

usage() {
  awk 'BEGIN{n=0} /^# -{20,}/{n++; next} n==1{sub(/^# ?/,""); print} n==2{exit}' "$0"
  exit "${1:-0}"
}

# Host ports already claimed in the live ha-router repo — backend URLs in config/*.yml
# plus traefik.yml entryPoints. The in-container session can't see this repo, so we must
# avoid these pairs at scaffold time. Computed once into HA_PORTS below.
ha_router_claimed_ports() {
  [[ -d "$HA_ROUTER" ]] || return 0
  {
    grep -rhoE 'host\.docker\.internal:[0-9]+' "$HA_ROUTER/config" 2>/dev/null | grep -oE '[0-9]+$'
    grep -oE 'address:[[:space:]]*":[0-9]+"' "$HA_ROUTER/traefik.yml" 2>/dev/null | grep -oE '[0-9]+'
  } | sort -un
}
HA_PORTS="$(ha_router_claimed_ports)"

# True if host port $1 is bound (host listener), published by a docker container, or
# already claimed in the live ha-router config.
host_port_in_use() {
  if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"; then return 0; fi
  if docker ps --format '{{.Ports}}' 2>/dev/null | grep -qE "(^|[^0-9])$1->"; then return 0; fi
  if printf '%s\n' "$HA_PORTS" | grep -qx "$1"; then return 0; fi
  return 1
}

# Echo "server client" (client = server + 2) for the first free pair at/above $1, step 10.
# Capped below 4800 (client port stays < 4800) to match the ha-router slug convention.
find_free_pair() {
  local s c base="${1:-4400}"
  for ((s = base; s <= 4796; s += 10)); do
    c=$((s + 2))
    if ! host_port_in_use "$s" && ! host_port_in_use "$c"; then
      printf '%s %s\n' "$s" "$c"
      return 0
    fi
  done
  return 1
}

NAME=""
NO_START=false
NO_HA_ROUTER=false
NO_GITHUB=false
GITHUB_VISIBILITY=""
TITLE=""
SLUG=""
SERVER_PORT=""
CLIENT_PORT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-start) NO_START=true; shift ;;
    --no-ha-router) NO_HA_ROUTER=true; shift ;;
    --no-github) NO_GITHUB=true; shift ;;
    --private) GITHUB_VISIBILITY="--private"; shift ;;
    --title) TITLE="$2"; shift 2 ;;
    --slug) SLUG="$2"; shift 2 ;;
    --server-port) SERVER_PORT="$2"; shift 2 ;;
    --client-port) CLIENT_PORT="$2"; shift 2 ;;
    -h | --help) usage 0 ;;
    -*) echo "Unknown option: $1" >&2; usage 1 ;;
    *) if [[ -z "$NAME" ]]; then NAME="$1"; else echo "Unexpected argument: $1" >&2; usage 1; fi; shift ;;
  esac
done

[[ -n "$NAME" ]] || { echo "Error: <game-name> is required." >&2; usage 1; }
[[ -d "$TEMPLATE" ]] || { echo "Error: template not found at $TEMPLATE" >&2; exit 1; }

case "$NAME" in
  *[!a-z0-9._-]* | "")
    echo "Error: invalid game name '$NAME' — use lowercase letters, digits, and - _ ." >&2; exit 1 ;;
esac

TARGET="$SOURCE_DIR/$NAME"
[[ -e "$TARGET" ]] && { echo "Error: '$TARGET' already exists — refusing to overwrite." >&2; exit 1; }

# Auto-pick a free port pair unless the user pinned both.
if [[ -z "$SERVER_PORT" && -z "$CLIENT_PORT" ]]; then
  if ! read -r SERVER_PORT CLIENT_PORT < <(find_free_pair 4400); then
    echo "Error: no free port pair found in 4400-4798." >&2; exit 1
  fi
  if [[ "$SERVER_PORT" != "4400" ]]; then
    echo "==> 4400/4402 busy; auto-selected free ports: server $SERVER_PORT / client $CLIENT_PORT"
  fi
fi

# Assemble presetup args.
PRESETUP_ARGS=("$NAME")
[[ -n "$TITLE" ]] && PRESETUP_ARGS+=(--title "$TITLE")
[[ -n "$SLUG" ]] && PRESETUP_ARGS+=(--slug "$SLUG")
[[ -n "$SERVER_PORT" ]] && PRESETUP_ARGS+=(--server-port "$SERVER_PORT")
[[ -n "$CLIENT_PORT" ]] && PRESETUP_ARGS+=(--client-port "$CLIENT_PORT")

echo "==> Copying template  ->  $NAME/"
cp -a "$TEMPLATE" "$TARGET"

echo "==> Instantiating ($NAME)"
(cd "$TARGET" && ./presetup.sh "${PRESETUP_ARGS[@]}")

SLUG_FINAL="$(sed -n 's/^SLUG=//p' "$TARGET/PORTS.env")"
HOST="${SLUG_FINAL}.preffect-ha.preffect-home.net"
TRAEFIK_HOST_IP="192.168.1.180"
TITLE_FINAL="${TITLE:-$(echo "$NAME" | sed -E 's/[-_]+/ /g; s/\b(.)/\u\1/g')}"

# ---------------------------------------------------------------------------
# ha-router integration (host side — the container cannot see the ha-router repo).
# Facts learned the hard way (details: base-multiplayer-game/ha-router/HA-ROUTER.md):
#   * DNS is per-host, NOT wildcard: each <slug> needs its own A record on the UniFi gateway.
#   * /api and /ws routers need priority 100 to beat the catch-all (default priority = rule
#     length); the template route already does this.
#   * The Angular dev server 403s the public host unless it is in allowedHosts (presetup does).
# ---------------------------------------------------------------------------
apply_ha_router() {
  if [[ ! -d "$HA_ROUTER/config" || ! -f "$HA_ROUTER/landing/index.html" ]]; then
    echo "==> ha-router repo not found; skipping"
    return 0
  fi
  local route="$HA_ROUTER/config/${SLUG_FINAL}.yml"
  if [[ ! -f "$route" ]]; then
    echo "==> ha-router: writing config/${SLUG_FINAL}.yml"
    sed -e "s/<slug>/${SLUG_FINAL}/g" -e "s/<server-port>/${SERVER_PORT}/g" -e "s/<client-port>/${CLIENT_PORT}/g" \
      "$TEMPLATE/ha-router/route.template.yml" | grep -vE '^#' | cat -s > "$route"
  fi
  local landing="$HA_ROUTER/landing/index.html"
  if ! grep -q "https://${HOST}" "$landing"; then
    # First icon hue not already used by any card.
    local hue hex rgb
    for hue in "a3e635 163,230,53" "2dd4bf 45,212,191" "f472b6 244,114,182" "facc15 250,204,21" \
               "818cf8 129,140,248" "fb7185 251,113,133" "34d399 52,211,153" "c084fc 192,132,252"; do
      hex="${hue%% *}"; rgb="${hue#* }"
      grep -q "#${hex}" "$landing" || break
    done
    echo "==> ha-router: adding landing card (hue #${hex})"
    python3 "$TEMPLATE/ha-router/insert-landing-card.py" "$landing" "$TITLE_FINAL" "$HOST" "$hex" "$rgb"
  fi
  if getent hosts "$HOST" >/dev/null; then
    echo "==> DNS: ${HOST} resolves"
  else
    cat <<EOF
==> DNS: ${HOST} does NOT resolve. There is no wildcard record — add an A record on the
    UniFi gateway (192.168.1.1):   ${HOST}  ->  ${TRAEFIK_HOST_IP}
    (unifi MCP in the unify-mcp project: plan_dns_record -> apply_dns_record; or the UniFi UI)
    Traefik already has the route; the URL works as soon as the record exists.
EOF
  fi
}

# ---------------------------------------------------------------------------
# Devcontainer: build/start without a TTY, make the skeleton green, start the servers.
# ./validate.sh all MUST run before ./run.sh on a fresh copy: it builds packages/shared/dist,
# without which the Angular client fails to compile ("Cannot find module '@<game>/shared'").
# ---------------------------------------------------------------------------
start_devcontainer() {
  echo "==> Building + starting devcontainer (non-interactive)"
  (cd "$TARGET" && DEVCONTAINER_YES=1 ./dev-container.sh </dev/null)
  local container="${NAME}-dev"
  echo "==> validate.sh all (builds shared) + run.sh"
  docker exec -u vscode -w /workspace "$container" \
    sh -lc './validate.sh all -t3 && ./run.sh >/dev/null 2>&1; sleep 25; ./run.sh --status | tail -2'
}

verify_public_url() {
  echo "==> Verifying https://${HOST} through Traefik"
  # Without the per-host DNS record, resolve the host to this machine so Traefik routing is
  # still proven; the DNS step above already told the user what to add.
  local resolve=()
  getent hosts "$HOST" >/dev/null || resolve=(--resolve "${HOST}:443:127.0.0.1")
  local ui api ws
  ui="$(curl -sk "${resolve[@]}" -o /dev/null -w '%{http_code}' --max-time 30 "https://${HOST}/" || true)"
  api="$(curl -sk "${resolve[@]}" --max-time 10 "https://${HOST}/api/health" || true)"
  ws="$(curl -sk "${resolve[@]}" -o /dev/null -w '%{http_code}' --max-time 10 --http1.1 \
        -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
        -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "https://${HOST}/ws" || true)"
  printf '    UI %s | /api/health %s | /ws %s\n' "$ui" "$api" "$ws"
  # Prove /api hit the -api router, not the catch-all via the Angular proxy.
  if docker ps --format '{{.Names}}' | grep -qx ha-router; then
    if docker logs --tail 200 ha-router 2>&1 | grep "${SLUG_FINAL}" | grep '/api/health' | tail -1 | grep -q "${SLUG_FINAL}-api@file"; then
      echo "    /api served by ${SLUG_FINAL}-api@file (correct router)"
    else
      echo "    WARNING: /api/health not seen on ${SLUG_FINAL}-api@file — check priority in ha-router/config/${SLUG_FINAL}.yml"
    fi
  fi
  if [[ "$ui" == "200" && "$api" == '{"status":"ok"}' && "$ws" == "101" ]]; then
    echo "    OK"
  else
    echo "    NOT fully verified (servers still starting?) — re-check manually"
  fi
}

$NO_HA_ROUTER || apply_ha_router

if $NO_START; then
  cat <<EOF

Done. Next:
  cd $TARGET
  ./dev-container.sh        # build + start the devcontainer
  # inside it:  ./validate.sh all  &&  ./run.sh      (validate first — it builds packages/shared)
  ./scripts/github-setup.sh # repo, board, groundwork epics, branch ruleset (host)
EOF
  exit 0
fi

start_devcontainer
$NO_HA_ROUTER || verify_public_url

if ! $NO_GITHUB; then
  echo "==> GitHub setup"
  # shellcheck disable=SC2086
  (cd "$TARGET" && ./scripts/github-setup.sh --title "$TITLE_FINAL" $GITHUB_VISIBILITY) \
    || echo "==> GitHub setup failed or skipped — re-run later:  cd $TARGET && ./scripts/github-setup.sh"
fi

cat <<EOF

==> $NAME is ready.
    Local   http://localhost:${CLIENT_PORT}        Public  https://${HOST}
    Next: open the devcontainer and run the init interview (CLAUDE.md "START HERE"):
      cd $TARGET && ./dev-container.sh
      claude "Read init-game-prompt.md and help me initialize my game"
    Process rules for the agent team: $TARGET/WORKFLOW.md
EOF
if [[ -t 0 && -t 1 ]]; then
  cd "$TARGET" && exec ./dev-container.sh
fi
