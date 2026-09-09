#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# presetup.sh — instantiate the base-multiplayer-game TEMPLATE into a project. # KEEP_TEMPLATE_NAME
#
# Run ONCE, on the host, right after copying the template into a new folder and
# BEFORE ./dev-container.sh — so the devcontainer's first `pnpm install` resolves
# the FINAL package scope (@<project>).
#
# Rewrites the template's identity tokens in place:
#   base-multiplayer-game / @base-multiplayer-game -> <project> / @<project> # KEEP_TEMPLATE_NAME
#   Base Multiplayer Game (display title)          -> <Title> # KEEP_TEMPLATE_NAME
#   base-mp (slug + client-id storage key)         -> <slug> # KEEP_TEMPLATE_NAME
#   game-debug (MCP server name)                   -> <slug>-debug # KEEP_TEMPLATE_NAME
#   4400 / 4402 (only if you pass new ports)       -> <server-port> / <client-port>
#
# It does NOT touch container/image/DinD names — dev-container.sh derives those
# from the folder name. It does NOT touch gameplay — that's init-game-prompt.md.
#
# Usage:
#   ./presetup.sh [project-name] [--slug s] [--title "T"] [--server-port n] [--client-port m] [--force]
#
# Defaults: project-name = this folder's name; slug = project-name;
#           title = Title Case of project-name; ports unchanged (4400/4402).
# ---------------------------------------------------------------------------

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$(basename "$0")"
KEEP_TAG="KEEP_TEMPLATE_NAME" # lines carrying this tag keep the literal template name

# ---- defaults ----
PROJECT="$(basename "$ROOT" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_.-' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"
SLUG=""
TITLE=""
SERVER_PORT="4400"
CLIENT_PORT="4402"
FORCE=false

# ---- args ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug)        SLUG="$2"; shift 2 ;;
    --title)       TITLE="$2"; shift 2 ;;
    --server-port) SERVER_PORT="$2"; shift 2 ;;
    --client-port) CLIENT_PORT="$2"; shift 2 ;;
    --force)       FORCE=true; shift ;;
    -h|--help)     sed -n '4,24p' "$0"; exit 0 ;;
    -*)            echo "Unknown option: $1" >&2; exit 1 ;;
    *)             PROJECT="$1"; shift ;;
  esac
done

SLUG="${SLUG:-$PROJECT}"
if [[ -z "$TITLE" ]]; then
  TITLE="$(echo "$PROJECT" | tr '_-' '  ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1')"
fi

# ---- validate ----
name_ok() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; }
name_ok "$PROJECT" || { echo "Invalid project name '$PROJECT' (lowercase letters, digits, - _ .)" >&2; exit 1; }
name_ok "$SLUG"    || { echo "Invalid slug '$SLUG'" >&2; exit 1; }

if [[ "$FORCE" != true ]] && ! grep -q '"name": "base-multiplayer-game"' "$ROOT/package.json" 2>/dev/null; then # KEEP_TEMPLATE_NAME
  echo "This doesn't look like a fresh template (root package.json name is not 'base-multiplayer-game')." # KEEP_TEMPLATE_NAME
  echo "Already instantiated? Re-run with --force to rewrite anyway."
  exit 1
fi

echo "Instantiating template:"
echo "  project : $PROJECT   (package scope @$PROJECT)"
echo "  slug    : $SLUG"
echo "  title   : $TITLE"
echo "  ports   : server $SERVER_PORT / client $CLIENT_PORT"
echo

# Replace literal token $1 with $2 across all text files (skipping build/vendor dirs
# and this script). Pass "word" as $3 to anchor on word boundaries (used for ports).
replace() {
  local search="$1" repl="$2" word="${3:-}" files repl_esc
  repl_esc=$(printf '%s' "$repl" | sed 's/[&|\\]/\\&/g')
  files=$(grep -rIl --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=.angular \
          --exclude-dir=.pnpm-store --exclude-dir=dist --exclude=pnpm-lock.yaml \
          --exclude="$SELF" -F "$search" "$ROOT" 2>/dev/null || true)
  [[ -z "$files" ]] && return 0
  # Lines carrying the keep tag keep the literal template name (e.g. "upstream this to the
  # template" guidance) — the tag itself is stripped at the end of presetup.
  if [[ "$word" == word ]]; then
    printf '%s\n' "$files" | xargs -d '\n' sed -i "/${KEEP_TAG}/! s|\\b${search}\\b|${repl_esc}|g"
  else
    printf '%s\n' "$files" | xargs -d '\n' sed -i "/${KEEP_TAG}/! s|${search}|${repl_esc}|g"
  fi
}

# The template's README describes how to CREATE games; a game gets the game-facing README.
if [[ -f "$ROOT/README.game.md" ]]; then
  mv -f "$ROOT/README.game.md" "$ROOT/README.md"
fi

replace 'Base Multiplayer Game' "$TITLE" # KEEP_TEMPLATE_NAME
replace 'base-multiplayer-game' "$PROJECT" # KEEP_TEMPLATE_NAME
replace 'game-debug' "${SLUG}-debug" # KEEP_TEMPLATE_NAME
replace 'base-mp' "$SLUG" # KEEP_TEMPLATE_NAME
[[ "$SERVER_PORT" != "4400" ]] && replace '4400' "$SERVER_PORT" word
[[ "$CLIENT_PORT" != "4402" ]] && replace '4402' "$CLIENT_PORT" word

# Record the chosen ports + slug so the in-container session reads them instead of
# guessing (it can't see the host or the live ha-router repo). These values are already
# baked into the integration files above; PORTS.env is the machine-readable source of truth.
# Strip the keep tags now that all replacements are done (scripts that mention the tag by
# variable — this one, sync-from-template.sh — are untouched because their lines lack "# tag").
grep -rIl --exclude-dir=node_modules --exclude-dir=.git --exclude="$SELF" "$KEEP_TAG" "$ROOT" 2>/dev/null \
  | xargs -r -d '\n' sed -i -e "s| *<!-- ${KEEP_TAG} -->||" -e "s| *# ${KEEP_TAG}||"

cat > "$ROOT/PORTS.env" <<EOF
# Generated by presetup.sh — DO NOT edit by hand.
# Pre-selected, host-verified ports for this game. The in-container session should
# read these rather than picking ports. They are already applied across the
# integration files (server index.ts, client angular.json/proxy.conf.json,
# .devcontainer/devcontainer.json, dev-container.sh, run.sh, .mcp.json).
SERVER_PORT=$SERVER_PORT
CLIENT_PORT=$CLIENT_PORT
SLUG=$SLUG
TITLE=$TITLE
EOF

echo "Done."
echo
echo "Next:"
echo "  ./dev-container.sh        # build + start the devcontainer (installs deps under @$PROJECT)"
echo "  # then open init-game-prompt.md with Claude Code to define the actual game."
