#!/usr/bin/env bash
set -euo pipefail
print_help() { awk 'BEGIN{n=0} /^# -{20,}/{n++; next} n==1{sub(/^# ?/,""); print} n==2{exit}' "$0"; }

# ---------------------------------------------------------------------------
# presetup.sh — instantiate the base-multiplayer-game TEMPLATE into a project. # KEEP_TEMPLATE_NAME
#
# Run ONCE, on the host, right after copying the template into a new folder and
# BEFORE ./dev-container.sh — so the devcontainer's first `pnpm install` resolves
# the FINAL package scope (@<project>). Formatting the result needs npx or docker, and
# the npm registry the first time.
#
# Rewrites the template's identity tokens in place:
#   base-multiplayer-game / @base-multiplayer-game -> <project> / @<project> # KEEP_TEMPLATE_NAME
#   Base Multiplayer Game (display title)          -> <Title> # KEEP_TEMPLATE_NAME
#   base-mp (slug + client-id storage key)         -> <slug> # KEEP_TEMPLATE_NAME
#   game-debug (MCP server name)                   -> <slug>-debug # KEEP_TEMPLATE_NAME
#   4400 / 4402 (only if you pass new ports)       -> <server-port> / <client-port> # KEEP_TEMPLATE_NAME
#   @base-multiplayer-game/ in pnpm-lock.yaml      -> @<project>/ (nothing else in that file) # KEEP_TEMPLATE_NAME
#
# It then writes PORTS.env and dev.yaml, and runs prettier over the result, because the new
# names change line lengths and table widths. A new game passes `pnpm lint` as it stands.
#
# It does NOT touch container/image/DinD names — dev-container.sh derives those
# from the folder name. It does NOT touch gameplay — that's docs/INIT-GAME.md.
#
# Usage:
#   ./presetup.sh [project-name] [--slug s] [--title "T"] [--server-port n] [--client-port m] [--force]
#
# Defaults: project-name = this folder's name; slug = project-name;
#           title = Title Case of project-name; ports unchanged (4400/4402). # KEEP_TEMPLATE_NAME
# ---------------------------------------------------------------------------

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/identity.sh" # the one identity-render engine (shared with sync-from-template.sh)

PORT_MIN=1024 # dev.yaml's schema allows no lower
PORT_MAX=65535
PORT_MAX_DIGITS=5 # longer input would overflow the shell's arithmetic

# ---- defaults ----
PROJECT="$(basename "$ROOT" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_.-' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"
SLUG=""
TITLE=""
SERVER_PORT="$IDENTITY_TEMPLATE_SERVER_PORT"
CLIENT_PORT="$IDENTITY_TEMPLATE_CLIENT_PORT"
FORCE=false

# ---- args ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug)        SLUG="$2"; shift 2 ;;
    --title)       TITLE="$2"; shift 2 ;;
    --server-port) SERVER_PORT="$2"; shift 2 ;;
    --client-port) CLIENT_PORT="$2"; shift 2 ;;
    --force)       FORCE=true; shift ;;
    -h|--help)     print_help; exit 0 ;;
    -*)            echo "Unknown option: $1" >&2; exit 1 ;;
    *)             PROJECT="$1"; shift ;;
  esac
done

SLUG="${SLUG:-$PROJECT}"
[[ -n "$TITLE" ]] || TITLE="$(title_case_from_name "$PROJECT")"

# ---- validate ----
name_ok() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; }
name_ok "$PROJECT" || { echo "Invalid project name '$PROJECT' (lowercase letters, digits, - _ .)" >&2; exit 1; }
name_ok "$SLUG"    || { echo "Invalid slug '$SLUG'" >&2; exit 1; }
# The title lands inside quoted TypeScript and shell strings.
title_ok() { [[ "$1" != *[\'\"\\\`\$]* ]]; }
title_ok "$TITLE"  || { echo "Invalid title '$TITLE' (no quotes, backticks, backslashes or dollar signs)" >&2; exit 1; }
port_ok() { [[ "$1" =~ ^[1-9][0-9]*$ ]] && ((${#1} <= PORT_MAX_DIGITS && $1 >= PORT_MIN && $1 <= PORT_MAX)); }
port_ok "$SERVER_PORT" || { echo "Invalid server port '$SERVER_PORT' ($PORT_MIN-$PORT_MAX)" >&2; exit 1; }
port_ok "$CLIENT_PORT" || { echo "Invalid client port '$CLIENT_PORT' ($PORT_MIN-$PORT_MAX)" >&2; exit 1; }
[[ "$SERVER_PORT" != "$CLIENT_PORT" ]] || { echo "The server and client ports must differ (both $SERVER_PORT)" >&2; exit 1; }
[[ -f "$ROOT/pnpm-lock.yaml" ]] || { echo "No pnpm-lock.yaml: a game needs the template's lockfile" >&2; exit 1; }

if [[ "$FORCE" != true ]] && ! grep -q '"name": "base-multiplayer-game"' "$ROOT/package.json" 2>/dev/null; then # KEEP_TEMPLATE_NAME
  echo "This doesn't look like a fresh template (root package.json name is not 'base-multiplayer-game')." # KEEP_TEMPLATE_NAME
  echo "Already instantiated? Re-run with --force to rewrite anyway."
  exit 1
fi

# Fetch prettier now, so a host that can't run it stops here with the template untouched.
run_prettier "$ROOT" --version >/dev/null || { echo "Can't run prettier: this needs npx or docker, and the npm registry" >&2; exit 1; }

echo "Instantiating template:"
echo "  project : $PROJECT   (package scope @$PROJECT)"
echo "  slug    : $SLUG"
echo "  title   : $TITLE"
echo "  ports   : server $SERVER_PORT / client $CLIENT_PORT"
echo

# The template's README describes how to CREATE games; a game gets the game-facing README.
if [[ -f "$ROOT/README.game.md" ]]; then
  mv -f "$ROOT/README.game.md" "$ROOT/README.md"
fi

# Template-only files never belong in a game (scripts/sync-from-template.sh removes any that
# reappear; the list lives in scripts/lib/identity.sh so both agree). presetup.sh is in that list
# but goes last, at the bottom of this file, so a run that fails on the way can be repeated.
for template_only in "${TEMPLATE_ONLY_PATHS[@]}"; do
  [[ "$template_only" == presetup.sh ]] || rm -rf "${ROOT:?}/$template_only"
done

# ---- rewrite every file that mentions a template identity token ----
mapfile -t identity_files < <(grep -rIlE --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=.angular \
  --exclude-dir=.pnpm-store --exclude-dir=dist --exclude=pnpm-lock.yaml \
  "${IDENTITY_TEMPLATE_TITLE}|${IDENTITY_TEMPLATE_PROJECT}|${IDENTITY_TEMPLATE_MCP}|${IDENTITY_TEMPLATE_SLUG}|\\b${IDENTITY_TEMPLATE_SERVER_PORT}\\b|\\b${IDENTITY_TEMPLATE_CLIENT_PORT}\\b|${IDENTITY_KEEP_TAG}" \
  "$ROOT" 2>/dev/null || true)
render_identity "$TITLE" "$PROJECT" "$SLUG" "$SERVER_PORT" "$CLIENT_PORT" "${identity_files[@]}"
# The lockfile names the workspace packages, so a frozen install fails until they match. Only those
# change: the whole-word port rewrite above could hit a dependency's version or hash. The scope comes
# from the manifests the identity pass wrote, because those are what the install compares it with.
workspace_scope="$(sed -n 's|^  "name": "\(@[^/]*\)/shared",$|\1|p' "$ROOT/packages/shared/package.json")"
[[ -n "$workspace_scope" ]] || { echo "No package scope in packages/shared/package.json" >&2; exit 1; }
sed -i "s|@${IDENTITY_TEMPLATE_PROJECT}/|${workspace_scope}/|g" "$ROOT/pnpm-lock.yaml"

# The root package description is the game's (set after the identity pass so the template name survives).
sed -i "s|^  \"description\": \".*\",$|  \"description\": \"$(_identity_escape "$TITLE") — multiplayer game built from the base-multiplayer-game template\",|" "$ROOT/package.json" # KEEP_TEMPLATE_NAME

# Record the chosen ports + slug so the in-container session reads them instead of
# guessing (it can't see the host or the live ha-router repo). These values are already
# baked into the integration files above; PORTS.env is the machine-readable source of truth.
cat > "$ROOT/PORTS.env" <<EOF
# Generated by presetup.sh — DO NOT edit by hand.
# Pre-selected, host-verified ports for this game. The in-container session should
# read these rather than picking ports. They are already applied across the
# integration files (server index.ts, client angular.json/proxy.conf.json,
# .devcontainer/devcontainer.json, dev-container.sh, run.sh, .mcp.json, dev.yaml).
SERVER_PORT=$SERVER_PORT
CLIENT_PORT=$CLIENT_PORT
SLUG=$SLUG
TITLE=$TITLE
EOF

# The same two ports for the standard dev environment, which reads this file instead of PORTS.env.
cat > "$ROOT/dev.yaml" <<EOF
# Game server, Angular client.
ports: { server: $SERVER_PORT, client: $CLIENT_PORT }
EOF

# The new names change line lengths and table widths, and the docs index quotes the docs: format
# first, then index what was formatted.
run_prettier "$ROOT" --write --log-level=warn .
"$ROOT/scripts/docs-index.sh" >/dev/null

echo "Done."
echo
echo "Next:"
echo "  ./dev-container.sh        # build + start the devcontainer (installs deps under @$PROJECT)"
echo "  # then open docs/INIT-GAME.md with Claude Code to define the actual game."
rm -f "$ROOT/presetup.sh" # one-shot: a game never carries the instantiation script
