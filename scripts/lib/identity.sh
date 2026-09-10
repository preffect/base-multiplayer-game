#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# identity.sh — the ONE place that knows how to turn template files into a game's files.
#
# Sourced by presetup.sh (first instantiation) and scripts/sync-from-template.sh (later
# syncs). Rewrites the template identity tokens in the given files:
#   Base Multiplayer Game  -> <Title>          base-multiplayer-game -> <project> # KEEP_TEMPLATE_NAME
#   game-debug             -> <slug>-debug     base-mp               -> <slug> # KEEP_TEMPLATE_NAME
#   4400 / 4402            -> <server-port> / <client-port>   (whole-word, only if changed) # KEEP_TEMPLATE_NAME
# Lines carrying the keep tag keep the literal template values (guidance such as "upstream
# this to base-multiplayer-game"); the tag itself is stripped afterwards. # KEEP_TEMPLATE_NAME
# The tag is always spelled via $IDENTITY_KEEP_TAG here so this file cannot mangle itself.
# Also sourced by dev-container.sh and scripts/agent.sh for the container identity (bottom).
# ---------------------------------------------------------------------------

IDENTITY_KEEP_TAG="KEEP_TEMPLATE_NAME"
IDENTITY_TEMPLATE_TITLE="Base Multiplayer Game" # KEEP_TEMPLATE_NAME
IDENTITY_TEMPLATE_PROJECT="base-multiplayer-game" # KEEP_TEMPLATE_NAME
IDENTITY_TEMPLATE_MCP="game-debug" # KEEP_TEMPLATE_NAME
IDENTITY_TEMPLATE_SLUG="base-mp" # KEEP_TEMPLATE_NAME
IDENTITY_TEMPLATE_SERVER_PORT="4400" # KEEP_TEMPLATE_NAME
IDENTITY_TEMPLATE_CLIENT_PORT="4402" # KEEP_TEMPLATE_NAME

# title_case_from_name my-game -> "My Game"
title_case_from_name() { echo "$1" | sed -E 's/[-_]+/ /g; s/\b(.)/\u\1/g'; }

_identity_escape() { printf '%s' "$1" | sed 's/[&|\\]/\\&/g'; }

# _identity_replace <search> <replacement> <word|any> <file>...
_identity_replace() {
  local search="$1" replacement mode="$3"; replacement="$(_identity_escape "$2")"; shift 3
  (($#)) || return 0
  if [[ "$mode" == word ]]; then sed -i "/${IDENTITY_KEEP_TAG}/! s|\\b${search}\\b|${replacement}|g" "$@"
  else sed -i "/${IDENTITY_KEEP_TAG}/! s|${search}|${replacement}|g" "$@"; fi
}

# render_identity <title> <project> <slug> <server-port> <client-port> <file>...
# Rewrites the files in place and strips the keep tags.
render_identity() {
  local title="$1" project="$2" slug="$3" server_port="$4" client_port="$5"; shift 5
  (($#)) || return 0
  _identity_replace "$IDENTITY_TEMPLATE_TITLE" "$title" any "$@"
  _identity_replace "$IDENTITY_TEMPLATE_PROJECT" "$project" any "$@"
  _identity_replace "$IDENTITY_TEMPLATE_MCP" "${slug}-debug" any "$@"
  _identity_replace "$IDENTITY_TEMPLATE_SLUG" "$slug" any "$@"
  if [[ "$server_port" != "$IDENTITY_TEMPLATE_SERVER_PORT" ]]; then
    _identity_replace "$IDENTITY_TEMPLATE_SERVER_PORT" "$server_port" word "$@"
  fi
  if [[ "$client_port" != "$IDENTITY_TEMPLATE_CLIENT_PORT" ]]; then
    _identity_replace "$IDENTITY_TEMPLATE_CLIENT_PORT" "$client_port" word "$@"
  fi
  sed -i -e "s| *<!-- ${IDENTITY_KEEP_TAG} -->||" -e "s| *# ${IDENTITY_KEEP_TAG}||" "$@"
}

# ---- container identity: the ONE home for what dev-container.sh and scripts/agent.sh assume ----
# The devcontainer runs as this user with the checkout mounted at this path (devcontainer.json
# "remoteUser" / "workspaceFolder"; .devcontainer/Dockerfile ends with `USER root`, so every
# `docker exec` MUST pass `-u "$CONTAINER_USER"` or it runs as root with no gh/claude credentials).
CONTAINER_USER=vscode
CONTAINER_HOME="/home/$CONTAINER_USER"
CONTAINER_WORKSPACE=/workspace
CONTAINER_NAME_SUFFIX=-dev

# Container/image names are derived from the checkout's folder name so a copied project never
# clashes with another one.
project_slug_from_dir() { # <dir>
  basename "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_.-' '-' | sed 's/--*/-/g; s/^-//; s/-$//'
}
container_name_from_dir() { echo "$(project_slug_from_dir "$1")$CONTAINER_NAME_SUFFIX"; } # <dir>


# Files that exist only to CREATE games and must not survive in one. presetup.sh deletes them
# at instantiation; scripts/sync-from-template.sh deletes any that reappear. (init-game-prompt.md
# is not here: a game keeps it until the init step has defined the game, then that step removes it.)
TEMPLATE_ONLY_PATHS=(new-game.sh presetup.sh base-project.md README.game.md ha-router)
