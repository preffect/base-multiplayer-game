#!/usr/bin/env bash
# render-for-sync.sh — the template's render script for `preffect-dev sync-template`.
#
#   scripts/render-for-sync.sh -- <folder> <path>...
#
# The sync runs it from a checkout of the template's commit, never from a game, with the game's root in
# PREFFECT_SYNC_ROOT. It renders the staged template files under <folder> with the game's identity, then
# formats them as `pnpm lint` would in the game: the game's prettier config, with the prettier the game has
# installed at its lockfile's version. It never installs anything. Template-only, so a game never has it.
set -euo pipefail

# The checkout's own identity.sh, which still holds the template's names: a game's copy has been renamed.
# shellcheck source=lib/identity.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/identity.sh"

GAME_NAME_PATTERN='^[a-z0-9][a-z0-9._-]*$'
# The game's identity, read by read_game_identity.
GAME_PROJECT="" GAME_SLUG="" GAME_TITLE="" GAME_SERVER_PORT="" GAME_CLIENT_PORT=""

# Ports come from dev.yaml, the standard. PORTS.env still holds the slug and title, and must agree on ports.
read_game_identity() { # <root>
  local root="$1" ports_env="$1/PORTS.env" kind env_port
  GAME_PROJECT="$(sed -n 's/^  "name": "\(.*\)",$/\1/p' "$root/package.json" 2>/dev/null | head -n 1)"
  GAME_SERVER_PORT="$(dev_yaml_port "$root/dev.yaml" server)"
  GAME_CLIENT_PORT="$(dev_yaml_port "$root/dev.yaml" client)"
  GAME_SLUG="$(ports_env_value "$ports_env" SLUG)"
  GAME_TITLE="$(ports_env_value "$ports_env" TITLE)"
  [[ -n "$GAME_TITLE" ]] || GAME_TITLE="$(title_case_from_name "$GAME_PROJECT")"
  if [[ -z "$GAME_PROJECT" || -z "$GAME_SLUG" || -z "$GAME_SERVER_PORT" || -z "$GAME_CLIENT_PORT" ]]; then
    echo "error: can't read the game's identity: its name from package.json, its server and client ports from" \
      "dev.yaml, and its slug from PORTS.env" >&2
    return 1
  fi
  # The same rule presetup.sh holds names to, so a name with quotes or a stray character never gets written.
  if [[ ! "$GAME_PROJECT" =~ $GAME_NAME_PATTERN || ! "$GAME_SLUG" =~ $GAME_NAME_PATTERN ]]; then
    echo "error: the game's name '$GAME_PROJECT' or slug '$GAME_SLUG' isn't lowercase letters, digits and - _ ." >&2
    return 1
  fi
  if [[ "$GAME_TITLE" == *[\'\"\\\`\$]* ]]; then
    echo "error: the game's title in PORTS.env has a quote, backtick, backslash or dollar sign" >&2
    return 1
  fi
  for kind in SERVER CLIENT; do
    env_port="$(ports_env_value "$ports_env" "${kind}_PORT")"
    local dev_port_variable="GAME_${kind}_PORT"
    if [[ -n "$env_port" && "$env_port" != "${!dev_port_variable}" ]]; then
      echo "error: PORTS.env says ${kind}_PORT=$env_port, but dev.yaml says ${!dev_port_variable}. Make them agree first" >&2
      return 1
    fi
  done
}

# The game's own prettier, at the version its lockfile pins, so the result matches its `pnpm lint`.
game_prettier() { # <root>: prints the path
  local prettier="$1/node_modules/.bin/prettier" pinned installed
  if [[ ! -x "$prettier" ]]; then
    echo "error: the game's dependencies aren't installed. Install them in its dev environment, the devcontainer" \
      "or a dev pod, then sync again" >&2
    return 1
  fi
  pinned="$(prettier_version "$1")" || return 1
  if ! installed="$("$prettier" --version 2>/dev/null)"; then
    echo "error: the game's prettier won't start. It needs Node, so sync inside the game's dev environment," \
      "the devcontainer or a dev pod" >&2
    return 1
  fi
  if [[ "$installed" != "$pinned" ]]; then
    echo "error: the game has prettier $installed installed, but its lockfile pins $pinned. Reinstall in its dev environment" >&2
    return 1
  fi
  echo "$prettier"
}

format_staged() { # <root> <folder> <path>...
  local root="$1" folder="$2" prettier config
  shift 2
  prettier="$(game_prettier "$root")" || return 1
  # A config file staged here is the template's newer one, so it wins over the game's.
  for config in "${PRETTIER_CONFIG_FILES[@]}"; do
    if [[ -f "$root/$config" && ! -e "$folder/$config" ]]; then cp "$root/$config" "$folder/$config"; fi
  done
  [[ -f "$folder/.prettierrc" ]] || { echo "error: the game has no .prettierrc to format with" >&2; return 1; }
  (cd "$folder" && "$prettier" --config "$folder/.prettierrc" --write --ignore-unknown --log-level=warn -- "$@") \
    || { echo "error: prettier failed on the rendered files" >&2; return 1; }
}

main() {
  local root="${PREFFECT_SYNC_ROOT:?run this through preffect-dev sync-template}" folder path files=()
  [[ "${1:-}" != -- ]] || shift
  folder="${1:?a folder of staged files}"
  shift
  read_game_identity "$root"
  for path; do files+=("$folder/$path"); done
  render_identity "$GAME_TITLE" "$GAME_PROJECT" "$GAME_SLUG" "$GAME_SERVER_PORT" "$GAME_CLIENT_PORT" "${files[@]}"
  format_staged "$root" "$folder" "$@"
}

main "$@"
