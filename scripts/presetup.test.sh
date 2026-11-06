#!/usr/bin/env bash
# presetup.test.sh — instantiates scratch copies of this template with awkward names and ports, and
# checks that each result is a working game: names and ports are exactly what was asked for, a frozen
# lockfile-only install passes, dev.yaml and PORTS.env agree, prettier and the docs index are clean,
# and no template-only file survives. Bad input must stop presetup.sh with the copy untouched, a
# repeat on an instantiated copy must be refused, new-game.sh must leave nothing behind when presetup.sh
# refuses, and a sync must leave its files formatted. Template-only: a game has no presetup.sh.
#
#   scripts/presetup.test.sh        # exit 0 when every case passes (needs pnpm and npx)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

TEMPLATE_PROJECT="base-multiplayer-game" # the template's name in the files being rewritten
TEMPLATE_SERVER_PORT=4400
TEMPLATE_CLIENT_PORT=4402
STALE_SERVER_PORT=1111
STALE_CLIENT_PORT=2222
PRETTIER_PACKAGE="prettier@$(sed -n 's/^  prettier@\([0-9.]*\):$/\1/p' "$repo_root/pnpm-lock.yaml" | head -n 1)"

# --- helpers ------------------------------------------------------------------------------------
failures=0
check() { # <description> <command...>: passes when the command exits 0
  local description="$1"
  shift
  if "$@" >"$sandbox/check.log" 2>&1; then
    echo "ok   $description"
  else
    echo "FAIL $description"
    sed 's/^/     /' "$sandbox/check.log"
    failures=$((failures + 1))
  fi
}
fails() { ! "$@"; }
file_has_line() { grep -qxF -- "$2" "$1"; } # <file> <exact line>
file_lacks() { ! grep -qF -- "$2" "$1"; }   # <file> <text>
is_absent() { [[ ! -e "$1" ]]; }
in_directory() { (cd "$1" && shift && "$@"); } # <directory> <command...>
says() { # <text> <command...>: the command's output, pass or fail, holds the text
  local text="$1" output
  shift
  output="$("$@" 2>&1)" || true
  grep -qF -- "$text" <<<"$output"
}
# The lines the keep tags protect: they name the template itself, so a rewrite would break them.
keep_lines_survive() { # <game directory>
  grep -qF "TEMPLATE_MOUNT=/$TEMPLATE_PROJECT" "$1/dev-container.sh" \
    && grep -qF "pwd)/$TEMPLATE_PROJECT\"" "$1/scripts/sync-from-template.sh"
}
lockfile_gate_changes_nothing() { # <game directory>: the ./validate.sh lint step, with the file compared around it
  local before="$sandbox/lockfile-before-gate"
  cp "$1/pnpm-lock.yaml" "$before"
  in_directory "$1" pnpm install --frozen-lockfile --lockfile-only && cmp "$before" "$1/pnpm-lock.yaml"
}
# Regenerates the index and compares: docs-index.sh --check skips itself without node_modules.
docs_index_is_fresh() { # <game directory>
  local before
  before="$(cat "$1/docs/INDEX.md")"
  "$1/scripts/docs-index.sh" >/dev/null
  [[ "$before" == "$(cat "$1/docs/INDEX.md")" ]]
}

copy_template() { # <destination>: the working tree, without what a run or an install generates
  mkdir -p "$1"
  tar -C "$repo_root" --exclude=node_modules --exclude=.git --exclude=dist --exclude=.angular \
    --exclude=.pnpm-store --exclude=.worktrees --exclude=coverage -cf - . | tar -C "$1" -xf -
}

# Checks everything a finished game must satisfy.
check_game() { # <directory> <project> <slug> <server-port> <client-port>
  local game="$1" project="$2" slug="$3" server_port="$4" client_port="$5" package
  check "$project: root package name" file_has_line "$game/package.json" "  \"name\": \"$project\","
  for package in shared server client; do
    check "$project: $package package scope" file_has_line "$game/packages/$package/package.json" \
      "  \"name\": \"@$project/$package\","
  done
  check "$project: no template scope left in the lockfile" file_lacks "$game/pnpm-lock.yaml" "@$TEMPLATE_PROJECT/"
  check "$project: frozen lockfile-only install leaves the lockfile alone" lockfile_gate_changes_nothing "$game"
  check "$project: keep lines still name the template" keep_lines_survive "$game"
  check "$project: dev.yaml names both ports" file_has_line "$game/dev.yaml" \
    "ports: { server: $server_port, client: $client_port }"
  check "$project: PORTS.env server port" file_has_line "$game/PORTS.env" "SERVER_PORT=$server_port"
  check "$project: PORTS.env client port" file_has_line "$game/PORTS.env" "CLIENT_PORT=$client_port"
  check "$project: PORTS.env slug" file_has_line "$game/PORTS.env" "SLUG=$slug"
  check "$project: run.sh server port" file_has_line "$game/run.sh" "SERVER_PORT=\"\${PORT:-$server_port}\""
  check "$project: run.sh client port" file_has_line "$game/run.sh" "CLIENT_PORT=\"\${CLIENT_PORT:-$client_port}\""
  check "$project: dev server port" grep -q "\"port\": $client_port," "$game/packages/client/angular.json"
  check "$project: dev server proxies to the server" grep -q "localhost:$server_port" "$game/packages/client/proxy.conf.json"
  check "$project: MCP server name" grep -q "\"$slug-debug\": {" "$game/.mcp.json"
  check "$project: prettier is clean" in_directory "$game" npx --yes "$PRETTIER_PACKAGE" --check .
  check "$project: docs index is fresh" docs_index_is_fresh "$game"
  check "$project: presetup.sh removed itself" is_absent "$game/presetup.sh"
  check "$project: this test is gone" is_absent "$game/scripts/presetup.test.sh"
}

instantiate_and_check() { # <project> <slug> <server-port> <client-port> [presetup args...]
  local project="$1" slug="$2" server_port="$3" client_port="$4"
  shift 4
  local game="$sandbox/games/$project"
  copy_template "$game"
  # Stale on purpose: dev.yaml must come from the same variables as PORTS.env, not from the rewrite.
  printf 'ports: { server: %s, client: %s }\n' "$STALE_SERVER_PORT" "$STALE_CLIENT_PORT" > "$game/dev.yaml"
  check "$project: presetup.sh succeeds" in_directory "$game" ./presetup.sh "$project" "$@"
  check_game "$game" "$project" "$slug" "$server_port" "$client_port"
}

# --- cases: names and ports ---------------------------------------------------------------------
# A name that holds another template token must survive the later rewrites.
instantiate_and_check base-mp-arena base-mp-arena "$TEMPLATE_SERVER_PORT" "$TEMPLATE_CLIENT_PORT"
instantiate_and_check game-debug-lab game-debug-lab "$TEMPLATE_SERVER_PORT" "$TEMPLATE_CLIENT_PORT"
instantiate_and_check my-base-mp my-base-mp "$TEMPLATE_SERVER_PORT" "$TEMPLATE_CLIENT_PORT"
# A port that is another template port must not be rewritten twice, in either direction.
instantiate_and_check arena-4402 arena-4402 "$TEMPLATE_CLIENT_PORT" 4404 --server-port "$TEMPLATE_CLIENT_PORT" --client-port 4404
instantiate_and_check swapped-ports swapped-ports "$TEMPLATE_CLIENT_PORT" "$TEMPLATE_SERVER_PORT" \
  --server-port "$TEMPLATE_CLIENT_PORT" --client-port "$TEMPLATE_SERVER_PORT"
# Sed metacharacters in the title, and a project name with every allowed punctuation mark.
instantiate_and_check zeta_9.lab-x zeta 4410 4412 --slug zeta --title 'Zeta & Co | 100%' --server-port 4410 --client-port 4412
check "the title reaches the root package description" grep -q '"description": "Zeta & Co | 100% — ' "$sandbox/games/zeta_9.lab-x/package.json"
instantiate_and_check space-raiders space-raiders 4420 4422 --server-port 4420 --client-port 4422

# --- cases: refused input leaves the copy untouched ---------------------------------------------
refused="$sandbox/refused"
copy_template "$refused"
check_refused() { # <description> <presetup args...>
  local description="$1"
  shift
  check "refuses $description" fails in_directory "$refused" ./presetup.sh refused-game "$@"
  check "untouched after refusing $description" file_has_line "$refused/package.json" "  \"name\": \"$TEMPLATE_PROJECT\","
}
check_refused "a privileged port" --server-port 80
check_refused "a port above the range" --client-port 65536
check_refused "a leading zero" --server-port 04400
check_refused "a non-numeric port" --server-port 44a0
check_refused "a port too long for shell arithmetic" --server-port 99999999999999999999
check_refused "equal ports" --server-port 4410 --client-port 4410
check_refused "a client port equal to the default server port" --client-port "$TEMPLATE_SERVER_PORT"
check_refused "a title that would break a quoted string" --title "Bob's Arena"

mkdir "$sandbox/broken-npx"
printf '#!/usr/bin/env bash\nexit 1\n' > "$sandbox/broken-npx/npx"
chmod +x "$sandbox/broken-npx/npx"
check "refuses when prettier can't run" fails env PATH="$sandbox/broken-npx:$PATH" "$refused/presetup.sh" refused-game
check "untouched when prettier can't run" test -f "$refused/README.game.md"

mv "$refused/pnpm-lock.yaml" "$sandbox/held-lockfile"
check_refused "a missing lockfile"
check "keeps the template-only files when the lockfile is missing" test -f "$refused/README.game.md"

# --- cases: an instantiated copy can't be instantiated again ------------------------------------
fails_to_format="$sandbox/fails-to-format"
mkdir "$fails_to_format"
printf '#!/usr/bin/env bash\n[[ "$*" != *--write* ]]\n' > "$fails_to_format/npx"
chmod +x "$fails_to_format/npx"
half_built="$sandbox/games/half-built"
copy_template "$half_built"
check "says the copy is half-built when formatting fails" says "start from a fresh copy" \
  env PATH="$fails_to_format:$PATH" "$half_built/presetup.sh" half-built
check "a failed run leaves presetup.sh, so the copy is visibly unfinished" test -f "$half_built/presetup.sh"
check "refuses --force on a copy that lost its keep tags" fails "$half_built/presetup.sh" half-built --force
check "says to start from a fresh copy" says "Start from a fresh copy" "$half_built/presetup.sh" half-built --force
check "a refused --force leaves the keep lines alone" keep_lines_survive "$half_built"

renamed="$sandbox/games/renamed-template"
copy_template "$renamed"
sed -i "s/^  \"name\": \"$TEMPLATE_PROJECT\",$/  \"name\": \"renamed-copy\",/" "$renamed/package.json"
check "--force still works on a copy that has its keep tags" in_directory "$renamed" ./presetup.sh renamed-template --force
check "--force leaves the keep lines alone" keep_lines_survive "$renamed"

# --- cases: new-game.sh -------------------------------------------------------------------------
source_directory="$sandbox/source"
copy_template "$source_directory/$TEMPLATE_PROJECT"
new_game() { "$source_directory/$TEMPLATE_PROJECT/new-game.sh" "$@" --no-start --no-ha-router --no-github; }
# What a template used for development holds, and a new game must not inherit.
mkdir -p "$source_directory/$TEMPLATE_PROJECT/node_modules" "$source_directory/$TEMPLATE_PROJECT/packages/server/node_modules" \
  "$source_directory/$TEMPLATE_PROJECT/.pnpm-store"
check "new-game.sh: creates a game" new_game new-base-mp --server-port 4430 --client-port 4432
check_game "$source_directory/new-base-mp" new-base-mp new-base-mp 4430 4432
check "new-game.sh: leaves root node_modules behind" is_absent "$source_directory/new-base-mp/node_modules"
check "new-game.sh: leaves package node_modules behind" is_absent "$source_directory/new-base-mp/packages/server/node_modules"
check "new-game.sh: leaves the pnpm store behind" is_absent "$source_directory/new-base-mp/.pnpm-store"

# A sync re-renders docs at the template's width, and this game has no node_modules to fix that with.
synced_game="$source_directory/new-base-mp"
sync_template() { "$synced_game/scripts/sync-from-template.sh" --template "$source_directory/$TEMPLATE_PROJECT"; }
workflow_before_sync="$sandbox/workflow-before-sync"
cp "$synced_game/docs/WORKFLOW.md" "$workflow_before_sync"
check "sync stops before copying when prettier can't run" fails env PATH="$sandbox/broken-npx:$PATH" "$synced_game/scripts/sync-from-template.sh" --template "$source_directory/$TEMPLATE_PROJECT"
check "sync copied nothing when prettier can't run" cmp "$workflow_before_sync" "$synced_game/docs/WORKFLOW.md"
check "sync says why when formatting fails" says "sync again" env PATH="$fails_to_format:$PATH" "$synced_game/scripts/sync-from-template.sh" --template "$source_directory/$TEMPLATE_PROJECT"
check "sync succeeds without node_modules" sync_template
check "sync leaves prettier clean" in_directory "$synced_game" npx --yes "$PRETTIER_PACKAGE" --check .
check "sync leaves a fresh docs index" docs_index_is_fresh "$synced_game"

# A template-owned file that matches the template but is unformatted, as an earlier sync could leave it.
sed -i 's/"minLines": 5/"minLines":   5/' "$source_directory/$TEMPLATE_PROJECT/.jscpd.json" "$synced_game/.jscpd.json"
check "sync repairs a file it had no reason to copy" says "$(basename "$synced_game/.jscpd.json")" sync_template
check "the repaired file is clean" in_directory "$synced_game" npx --yes "$PRETTIER_PACKAGE" --check .jscpd.json
sed -i 's/"minLines":   5/"minLines": 5/' "$source_directory/$TEMPLATE_PROJECT/.jscpd.json"

mv "$synced_game/pnpm-lock.yaml" "$sandbox/held-game-lockfile"
check "sync without a lockfile says to install" says "no pnpm-lock.yaml in $synced_game: run pnpm install first" sync_template
check "sync without a lockfile shows no raw sed error" fails says "can't read" sync_template
check "sync without a lockfile stops" fails sync_template
mv "$sandbox/held-game-lockfile" "$synced_game/pnpm-lock.yaml"

check "new-game.sh: stops on a bad port" fails new_game bad-port --server-port 80 --client-port 4432
check "new-game.sh: removes the copy after a refusal" is_absent "$source_directory/bad-port"

if [[ $failures -gt 0 ]]; then
  echo "presetup.test.sh: $failures failure(s)"
  exit 1
fi
echo "presetup.test.sh: all cases passed"
