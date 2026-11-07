#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# identity.sh — the ONE place that knows how to turn template files into a game's files.
#
# Sourced by presetup.sh (first instantiation) and scripts/sync-from-template.sh (later
# syncs), which also share run_prettier. Rewrites the template identity tokens in the given files:
#   Base Multiplayer Game  -> <Title>          base-multiplayer-game -> <project> # KEEP_TEMPLATE_NAME
#   game-debug             -> <slug>-debug     base-mp               -> <slug> # KEEP_TEMPLATE_NAME
#   4400 / 4402            -> <server-port> / <client-port>   (whole-word) # KEEP_TEMPLATE_NAME
# Lines carrying the keep tag keep the literal template values (guidance such as "upstream
# this to base-multiplayer-game"); the tag itself is stripped afterwards. # KEEP_TEMPLATE_NAME
# The tag is always spelled via $IDENTITY_KEEP_TAG here so this file cannot mangle itself.
# Also sourced by dev-container.sh, scripts/agent.sh, scripts/github-setup.sh and
# scripts/resume-in-container.sh for the container identity and title helper.
# ---------------------------------------------------------------------------

IDENTITY_KEEP_TAG="KEEP_TEMPLATE_NAME"
IDENTITY_TEMPLATE_TITLE="Base Multiplayer Game" # KEEP_TEMPLATE_NAME
IDENTITY_TEMPLATE_PROJECT="base-multiplayer-game" # KEEP_TEMPLATE_NAME
IDENTITY_TEMPLATE_MCP="game-debug" # KEEP_TEMPLATE_NAME
IDENTITY_TEMPLATE_SLUG="base-mp" # KEEP_TEMPLATE_NAME
IDENTITY_TEMPLATE_SERVER_PORT="4400" # KEEP_TEMPLATE_NAME
IDENTITY_TEMPLATE_CLIENT_PORT="4402" # KEEP_TEMPLATE_NAME
IDENTITY_PLACEHOLDER_MARK=$'\x01' # a control byte, so no text file holds it
FORMATTER_DOCKER_IMAGE=node:24-slim # the Node major of package.json's engines

# title_case_from_name my-game -> "My Game"
title_case_from_name() { echo "$1" | sed -E 's/[-_]+/ /g; s/\b(.)/\u\1/g'; }

_identity_escape() { printf '%s' "$1" | sed 's/[&|\\]/\\&/g'; }

# render_identity <title> <project> <slug> <server-port> <client-port> <file>...
# Rewrites the files in place and strips the keep tags. Every token becomes a placeholder before any
# placeholder becomes its value, so no value is rewritten by a later token: a project named
# base-mp-arena keeps its name, and ports may swap. Both stages run on a line inside one sed, so a # KEEP_TEMPLATE_NAME
# placeholder is never written to a file. Ports match whole words; the other tokens match anywhere.
render_identity() {
  local title="$1" project="$2" slug="$3" server_port="$4" client_port="$5"; shift 5
  (($#)) || return 0
  local tokens=("\\b${IDENTITY_TEMPLATE_SERVER_PORT}\\b" "\\b${IDENTITY_TEMPLATE_CLIENT_PORT}\\b" "$IDENTITY_TEMPLATE_TITLE"
    "$IDENTITY_TEMPLATE_PROJECT" "$IDENTITY_TEMPLATE_MCP" "$IDENTITY_TEMPLATE_SLUG")
  local values=("$server_port" "$client_port" "$title" "$project" "${slug}-debug" "$slug")
  local to_placeholders=() to_values=() index placeholder
  for index in "${!tokens[@]}"; do
    placeholder="${IDENTITY_PLACEHOLDER_MARK}${index}${IDENTITY_PLACEHOLDER_MARK}"
    to_placeholders+=(-e "s|${tokens[index]}|${placeholder}|g")
    to_values+=(-e "s|${placeholder}|$(_identity_escape "${values[index]}")|g")
  done
  sed -i -e "/${IDENTITY_KEEP_TAG}/!{" "${to_placeholders[@]}" "${to_values[@]}" -e '}' \
    -e "s| *<!-- ${IDENTITY_KEEP_TAG} -->||" -e "s| *# ${IDENTITY_KEEP_TAG}||" "$@"
}

# run_npx <root> <package> <args...>
# An npm package's CLI, run in <root>: through npx, or docker when Node lives only in the devcontainer.
run_npx() {
  local root="$1" package="$2"; shift 2
  if command -v npx >/dev/null; then
    (cd "$root" && npx --yes "$package" "$@")
  else
    docker run --rm --user "$(id -u):$(id -g)" --env HOME=/tmp --volume "$root:/workspace" --workdir /workspace \
      "$FORMATTER_DOCKER_IMAGE" npx --yes "$package" "$@"
  fi
}

# run_prettier <root> <prettier args...>
# The prettier version <root>'s lockfile pins, so it agrees with `pnpm lint` there, with or without
# node_modules. Prints why it couldn't run, so callers only need to stop.
run_prettier() {
  local root="$1" version; shift
  [[ -f "$root/pnpm-lock.yaml" ]] || { echo "error: no pnpm-lock.yaml in $root: run pnpm install first" >&2; return 1; }
  version="$(sed -n 's/^  prettier@\([0-9.]*\):$/\1/p' "$root/pnpm-lock.yaml" | head -n 1)"
  [[ -n "$version" ]] || { echo "error: no prettier in $root/pnpm-lock.yaml: run pnpm install first" >&2; return 1; }
  run_npx "$root" "prettier@$version" "$@" || { echo "error: prettier failed" >&2; return 1; }
}

# origin_is_repo <root> <owner/name>: true when the checkout's origin is that GitHub repo.
origin_is_repo() {
  local url; url="$(git -C "$1" remote get-url origin)" || return 1
  url="${url%/}"; url="${url%.git}"
  [[ "$url" == */"$2" || "$url" == *:"$2" ]]
}

# require_board_repo <root> <owner/name>: stops a script that writes to a project board when the
# checkout isn't the repo .github/project.env names, because the ids in that file may be another repo's.
require_board_repo() {
  origin_is_repo "$1" "$2" && return 0
  echo "error: origin isn't $2, the repo .github/project.env names. Run scripts/github-setup.sh first." >&2
  exit 1
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

# True inside a dev environment: the devcontainer has /.dockerenv, and a standard dev pod has no
# such file but its image sets PREFFECT_DEV.
in_container() { [[ -f /.dockerenv || -n "${PREFFECT_DEV:-}" ]]; }


# Files that exist only to CREATE games and must not survive in one. presetup.sh deletes them
# at instantiation; scripts/sync-from-template.sh deletes any that reappear. (docs/INIT-GAME.md
# is not here: a game keeps it until the init step has defined the game, then that step removes it.)
TEMPLATE_ONLY_PATHS=(new-game.sh presetup.sh scripts/presetup.test.sh base-project.md README.game.md ha-router
  ENGINEERING.md ASSET-GENERATION.md AUDIO-PIPELINE.md WORKFLOW.md TEAM.md init-game.md) # last row: legacy root locations, now docs/
