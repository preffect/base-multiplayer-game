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
# shellcheck source=lib/identity.sh
source "$repo_root/scripts/lib/identity.sh" # template_list_entries, for the checks of template-files.txt
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
    && grep -qF "mounted at \`/$TEMPLATE_PROJECT\`" "$1/CLAUDE.md"
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
  check "$project: shared default server port" file_has_line "$game/packages/shared/src/constants.ts" "export const DEFAULT_SERVER_PORT = $server_port;"
  check "$project: shared default client port" file_has_line "$game/packages/shared/src/constants.ts" "export const DEFAULT_CLIENT_PORT = $client_port;"
  check "$project: has none of the template's board ids" is_absent "$game/.github/project.env"
  check "$project: run.sh builds this game's shared package" grep -qF "pnpm --filter @$project/shared --if-present build" "$game/run.sh"
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

# --- cases: template-files.txt, the list preffect-dev sync-template reads ----------------------
list_entries() { template_list_entries "$repo_root/template-files.txt"; }
listed() { list_entries | grep -qxF -- "$1"; } # <kind path>
listed_files_exist() {
  local kind path
  while read -r kind path; do
    [[ "$kind" == retired || "$kind" == format || -e "$repo_root/$path" ]] || { echo "$kind $path doesn't exist"; return 1; }
  done < <(list_entries)
}
check "every file template-files.txt names exists" listed_files_exist
for agent in "$repo_root"/.claude/agents/*.md; do
  agent="${agent#"$repo_root/"}"
  check "$agent is owned" listed "owned $agent"
  check "its old role file is retired" listed "retired .claude/roles/$(basename "$agent")"
done
check "the render script is render-for-sync.sh" listed "render scripts/render-for-sync.sh"
check "which is template-only, so retired" listed "retired scripts/render-for-sync.sh"
for extended in validate.sh run.sh vitest.tiers.ts .jscpd.json .mcp.json; do
  check "$extended is shared, because games extend it" listed "shared $extended"
done
check "the after script is docs-index.sh" listed "after scripts/docs-index.sh"

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
check "refuses to run again on that copy" fails "$half_built/presetup.sh" half-built
check "says to start from a fresh copy" says "Start from a fresh copy" "$half_built/presetup.sh" half-built
check "a refused repeat leaves the keep lines alone" keep_lines_survive "$half_built"

# A game given the template's own name passes the name check, so only the keep tags stop a repeat.
same_name="$sandbox/games/same-name"
copy_template "$same_name"
check "a game may take the template's name" in_directory "$same_name" ./presetup.sh "$TEMPLATE_PROJECT"
copy_template "$sandbox/presetup-again"
cp "$sandbox/presetup-again/presetup.sh" "$same_name/presetup.sh"
check "refuses a repeat on that game too" fails "$same_name/presetup.sh" other-name
check "the refusal leaves the keep lines alone" keep_lines_survive "$same_name"

fails_on_install="$sandbox/fails-on-install"
mkdir "$fails_on_install"
printf '#!/usr/bin/env bash\n[[ "$*" != *install* ]] && exit 0\necho "fake pnpm reason"\nexit 1\n' > "$fails_on_install/npx"
chmod +x "$fails_on_install/npx"
failed_install="$sandbox/games/failed-install"
copy_template "$failed_install"
failed_install_rc=0
failed_install_output="$(env PATH="$fails_on_install:$PATH" "$failed_install/presetup.sh" failed-install 2>&1)" || failed_install_rc=$?
half_built_notices="$(grep -c 'half-built' <<<"$failed_install_output" || true)"
check "a failed lockfile step stops presetup.sh" test "$failed_install_rc" -ne 0
check "it shows pnpm's reason" grep -qF "fake pnpm reason" <<<"$failed_install_output"
check "it says the copy is half-built, once ($half_built_notices)" test "$half_built_notices" -eq 1

# A failure in any step after the copy starts changing must print the notice exactly once.
half_built_notices_from() { # <copy> <presetup args...>
  local copy="$1"
  shift
  "$copy/presetup.sh" "$@" 2>&1 | grep -c 'half-built' || true
}
unwritable_docs="$sandbox/games/unwritable-docs"
copy_template "$unwritable_docs"
chmod a-w "$unwritable_docs/docs"
notices="$(half_built_notices_from "$unwritable_docs" unwritable-docs)"
chmod u+w "$unwritable_docs/docs"
check "a failed identity pass says half-built once ($notices)" test "$notices" -eq 1

no_scope="$sandbox/games/no-scope"
copy_template "$no_scope"
sed -i "s|\"@$TEMPLATE_PROJECT/shared\"|\"shared\"|" "$no_scope/packages/shared/package.json"
notices="$(half_built_notices_from "$no_scope" no-scope)"
check "a missing package scope says half-built once ($notices)" test "$notices" -eq 1

for unsafe_retired in .GIT/hooks -rf docs/../.. ; do
  unsafe_copy="$sandbox/games/unsafe-retired-$(echo "$unsafe_retired" | tr -c 'a-zA-Z0-9' '-')"
  copy_template "$unsafe_copy"
  echo "retired $unsafe_retired" >> "$unsafe_copy/template-files.txt"
  check "presetup.sh refuses the retired path '$unsafe_retired'" says "Unsafe retired path '$unsafe_retired'" \
    in_directory "$unsafe_copy" ./presetup.sh unsafe-retired
done

check "the pnpm used for the lockfile is an exact version" grep -qE '^PNPM_PACKAGE=pnpm@[0-9]+[.][0-9]+[.][0-9]+$' "$repo_root/presetup.sh"

# --- cases: new-game.sh -------------------------------------------------------------------------
source_directory="$sandbox/source"
copy_template "$source_directory/$TEMPLATE_PROJECT"
new_game() { "$source_directory/$TEMPLATE_PROJECT/new-game.sh" "$@" --no-start --no-ha-router --no-github; }
# What a template used for development holds, and a new game must not inherit.
copied_template="$source_directory/$TEMPLATE_PROJECT"
mkdir -p "$copied_template/node_modules" "$copied_template/packages/server/node_modules" "$copied_template/.pnpm-store" \
  "$copied_template/packages/shared/dist" "$copied_template/.worktrees/some-branch" "$copied_template/data" \
  "$copied_template/.angular" "$copied_template/.game-logs" "$copied_template/.qa" "$copied_template/coverage"
touch "$copied_template/packages/shared/tsconfig.build.tsbuildinfo" "$copied_template/.env" "$copied_template/.env.local" \
  "$copied_template/CLAUDE.local.md" "$copied_template/.game.pid" "$copied_template/.devcontainer/.build-checksum"
# copy_template leaves out .git, so give this template its own repo and a remote, as a real one has.
fake_remotes="$sandbox/remotes"
template_remote="$fake_remotes/upstream/$TEMPLATE_PROJECT.git"
mkdir -p "$fake_remotes/tester" "$(dirname "$template_remote")"
git init -q --bare -b main "$template_remote"
as_tester() { git -c user.name=test -c user.email=test@example.com "$@"; }
git -C "$copied_template" init -q -b main
# The template's files, committed, so a later sync can fetch them and new-game.sh records this commit.
git -C "$copied_template" add -A
as_tester -C "$copied_template" commit -q -m "template history"
git -C "$copied_template" remote add origin "$template_remote"
git -C "$copied_template" push -q origin main
check "new-game.sh: creates a game" new_game new-base-mp --server-port 4430 --client-port 4432
check_game "$source_directory/new-base-mp" new-base-mp new-base-mp 4430 4432
for left_behind in .git node_modules packages/server/node_modules .pnpm-store packages/shared/dist \
  packages/shared/tsconfig.build.tsbuildinfo .worktrees .env .env.local CLAUDE.local.md data .game.pid .angular \
  .devcontainer/.build-checksum .game-logs .qa coverage; do
  check "new-game.sh: leaves $left_behind behind" is_absent "$source_directory/new-base-mp/$left_behind"
done
check "new-game.sh: keeps .env.example" test -f "$source_directory/new-base-mp/.env.example"

check "new-game.sh: names the template in dev.yaml" file_has_line "$source_directory/new-base-mp/dev.yaml" "template: preffect/$TEMPLATE_PROJECT"
check "new-game.sh: records the template commit it copied" test "$(cat "$source_directory/new-base-mp/.template-commit")" = "$(git -C "$copied_template" rev-parse HEAD)"

# --- cases: preffect-dev sync-template, with this template's list and render and after scripts ---
# The command is in the standard dev image, and preffect-home tests it in general. These check this
# template's side: a sync renders the game's names and ports, formats with the game's own prettier,
# rebuilds the docs index, lists what's left to do by hand until it's done, and keeps a retired folder
# that holds a file the base never had.
synced_game="$source_directory/new-base-mp"
sync_tool="$(command -v preffect-dev || true)"
template_commit() { as_tester -C "$copied_template" commit -q -am "$1"; }
commit_synced_game() { git -C "$synced_game" add -A && as_tester -C "$synced_game" commit -q -m "$1"; }
sync_template() { in_directory "$synced_game" "$sync_tool" sync-template --source "file://$copied_template"; }
# The render script formats with the game's installed prettier and never installs one, so the game gets
# a stand-in for `pnpm install`: a prettier that runs the template's.
give_game_prettier() { # <game directory>
  mkdir -p "$1/node_modules/.bin"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$repo_root/node_modules/.bin/prettier" > "$1/node_modules/.bin/prettier"
  chmod +x "$1/node_modules/.bin/prettier"
}
# Puts a stand-in prettier in a game, for the cases where the game's prettier misbehaves.
give_game_broken_prettier() { # <game directory> <script body>
  printf '#!/bin/sh\n%s\n' "$2" > "$1/node_modules/.bin/prettier"
}
# Commits a change to one of the game's files, runs a check, then puts the file back and commits that.
with_committed_change() { # <file> <sed expression> <check description> <check command...>
  local file="$synced_game/$1" expression="$2" description="$3" held="$sandbox/held-$(basename "$1")"
  shift 3
  cp "$file" "$held"
  sed -i "$expression" "$file"
  commit_synced_game "change $(basename "$file")"
  check "$description" "$@"
  cp "$held" "$file"
  commit_synced_game "restore $(basename "$file")"
}

# Without preffect-dev, in a devcontainer say, these cases can't run, so they're counted as skipped. In the
# standard dev environment, where PREFFECT_DEV is set, preffect-dev must be there, so they fail instead.
skipped=0
cases_in_block() { # <block name>: how many checks it holds, between its marker and the end marker
  awk -v begin="# sync cases: $1" -v end="# sync cases: end" \
    'index($0, begin) == 1 { counting = 1; next } index($0, end) == 1 { counting = 0 } counting && ($1 == "check" || $1 == "with_committed_change")' \
    "${BASH_SOURCE[0]}" | wc -l
}
sync_cases_can_run() { # <block name>
  local reason="" count
  if [[ -z "$sync_tool" ]]; then reason="preffect-dev isn't on PATH"
  elif [[ ! -x "$repo_root/node_modules/.bin/prettier" ]]; then reason="the template's prettier isn't installed"
  else return 0
  fi
  if [[ -n "${PREFFECT_DEV:-}" ]]; then
    check "the $1 sync cases can run in the standard dev environment ($reason)" false
    return 1
  fi
  count="$(cases_in_block "$1")"
  skipped=$((skipped + count))
  echo "skip $count $1 sync cases: $reason"
  return 1
}

# The sync refuses, at fetch, render code whose sources it can't follow, which would stop every game's
# sync. The tool's own check catches that here first. It needs only preffect-dev, not prettier.
if [[ -n "$sync_tool" ]]; then
  check "the sync can follow every source in the render code" "$sync_tool" sync-template --check-render "$repo_root"
  refused_render="$sandbox/refused-render"
  mkdir -p "$refused_render/scripts/lib"
  git -C "$refused_render" init -q
  printf 'format 1\nrender scripts/render-for-sync.sh\n' >"$refused_render/template-files.txt"
  cp "$repo_root/scripts/lib/identity.sh" "$refused_render/scripts/lib/identity.sh"
  sed 's|^source "|[[ -f x ]] \&\& source "|' "$repo_root/scripts/render-for-sync.sh" >"$refused_render/scripts/render-for-sync.sh"
  check "and the check refuses a source it can't follow" \
    says "sources in a way the sync can't follow" fails "$sync_tool" sync-template --check-render "$refused_render"
elif [[ -n "${PREFFECT_DEV:-}" ]]; then
  check "the render code check can run in the standard dev environment (preffect-dev isn't on PATH)" false
else
  skipped=$((skipped + 2))
  echo "skip 2 render code cases: preffect-dev isn't on PATH"
fi

# sync cases: main
if sync_cases_can_run main; then
  git -C "$synced_game" init -q
  commit_synced_game base
  check "sync of a new game says it's in step" says "Already in step" sync_template

  # A template fix in an owned doc, naming the template and its ports, and a change to a shared file.
  printf '\nThe Base Multiplayer Game server listens on 4400.\n' >> "$copied_template/docs/WORKFLOW.md"
  printf '\nA template note.\n' >> "$copied_template/CLAUDE.md"
  template_commit "template fix"
  mkdir -p "$synced_game/ha-router"
  echo stale > "$synced_game/ha-router/left-over.yml"
  commit_synced_game "a retired folder crept back"
  workflow_before_sync="$sandbox/workflow-before-sync"
  cp "$synced_game/docs/WORKFLOW.md" "$workflow_before_sync"
  check "sync stops when the game's prettier isn't installed" fails sync_template
  check "and says where to install it" says "Install them in its dev environment" sync_template
  check "and changed nothing" cmp "$workflow_before_sync" "$synced_game/docs/WORKFLOW.md"
  give_game_prettier "$synced_game"
  pinned_prettier="$(prettier_version "$synced_game")"
  give_game_broken_prettier "$synced_game" 'echo 0.0.1'
  check "sync stops when the game's prettier isn't the lockfile's version" says "but its lockfile pins $pinned_prettier" sync_template
  give_game_broken_prettier "$synced_game" "[ \"\$1\" = --version ] && echo $pinned_prettier && exit 0; exit 2"
  check "sync stops when prettier fails" says "prettier failed on the rendered files" sync_template
  check "and changed nothing" cmp "$workflow_before_sync" "$synced_game/docs/WORKFLOW.md"
  give_game_prettier "$synced_game"
  with_committed_change PORTS.env '/^SLUG=/d' "sync stops when it can't read the game's identity" \
    says "can't read the game's identity" sync_template
  with_committed_change PORTS.env 's/^SERVER_PORT=.*/SERVER_PORT=4999/' "sync stops when PORTS.env and dev.yaml disagree" \
    says "Make them agree first" sync_template
  check "none of those changed the doc" cmp "$workflow_before_sync" "$synced_game/docs/WORKFLOW.md"
  sync_output="$sandbox/sync-output"
  # Exit status 3: the sync worked, and left something to do by hand.
  sync_leaving_hand_work() { local status=0; sync_template >"$sync_output" 2>&1 || status=$?; [[ $status -eq 3 ]]; }
  check "sync succeeds, leaving work by hand" sync_leaving_hand_work
  check "it ran the template's render script" grep -qF "Running scripts/render-for-sync.sh from the template" "$sync_output"
  check "it ran the template's after script" grep -qF "Running scripts/docs-index.sh from the template" "$sync_output"
  check "the fix reaches the game with its name and port" file_has_line "$synced_game/docs/WORKFLOW.md" "The New Base Mp server listens on 4430."
  check "the shared file is listed for a merge by hand" file_has_line "$sync_output" "  CLAUDE.md"
  check "the game's CLAUDE.md is left as it was" fails grep -qF "A template note." "$synced_game/CLAUDE.md"
  check "a retired folder holding a file the base never had is kept" test -f "$synced_game/ha-router/left-over.yml"
  check "and listed" file_has_line "$sync_output" "  ha-router"
  check "sync leaves prettier clean" in_directory "$synced_game" npx --yes "$PRETTIER_PACKAGE" --check .
  check "sync leaves a fresh docs index" docs_index_is_fresh "$synced_game"
  commit_synced_game "sync"
  check "a second sync lists the shared file again" sync_leaving_hand_work
  check "with a merge command" grep -q "git merge-file .* > CLAUDE.md" "$sync_output"
  # What a person does with that list: run the printed merge, and delete the retired folder.
  merge_by_hand() {
    in_directory "$synced_game" bash -c "$(sed -n 's/^    \(git merge-file .* > CLAUDE.md\)$/\1/p' "$sync_output")" \
      && git -C "$synced_game" rm -rq ha-router
  }
  check "the printed merge command merges it" merge_by_hand
  check "the template's note reached the game's CLAUDE.md" grep -qF "A template note." "$synced_game/CLAUDE.md"
  commit_synced_game "merged by hand"
  check "then a sync has nothing left to do" sync_template
  commit_synced_game "recorded"
  check "and the next one is in step" says "Already in step" sync_template
fi
# sync cases: end

# A template commit that isn't on origin/main yet: a later sync's fetch of main couldn't find it.
as_tester -C "$copied_template" commit -q --allow-empty -m "not on origin/main yet"
check "new-game.sh: says when it records no base" says "No template commit recorded" \
  new_game unrecorded-base --server-port 4460 --client-port 4462
check "new-game.sh: records none for a commit that isn't on origin/main" is_absent "$source_directory/unrecorded-base/.template-commit"

# scripts/github-setup.sh on that path, against local bare repos: its git steps run for real. It can't
# reach GitHub: gh and setup_project.py, which only talks to GitHub, are fakes, git@github.com:tester/ is
# rewritten (a longer match than any rewrite in the machine's git config), and git may only use local files.
fake_github="$sandbox/fake-github"
mkdir "$fake_github"
# It reads what is piped to it, as the real gh does: exiting first breaks the pipe under pipefail.
cat > "$fake_github/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >> "$FAKE_GH_LOG"
case "$1 $2" in
  "auth status") echo "Token scopes: 'project', 'repo'" ;;
  "api user") echo tester ;;
  "repo view") [[ -d "$FAKE_REMOTES/$3.git" ]] ;;
  "repo create") git init -q --bare -b main "$FAKE_REMOTES/$3.git" ;;
  "issue create") echo "https://github.com/tester/fake/issues/1" ;;
  "api repos/"*) [[ ! -e "$FAKE_REMOTES/rulesets-fail" ]] || { echo "fake ruleset reason" >&2; exit 1; } ;;
  "api graphql") cat >/dev/null; echo '{"data":{"node":{"field":{"options":[]},"items":{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}' ;;
  "issue list") [[ "$*" != *--limit* ]] || echo '[]' ;;
esac
GH
cat > "$fake_github/python3" <<'PYTHON'
#!/usr/bin/env bash
echo "setup_project ran" >> "$FAKE_GH_LOG"
[[ ! -e "$FAKE_REMOTES/setup-project-fails" ]] || exit 1
printf 'REPO=%s\nPROJECT_OWNER=tester\nPROJECT_NUMBER=1\nPROJECT_ID=fake\nSTATUS_FIELD_ID=fake\n' "$2" > .github/project.env
PYTHON
chmod +x "$fake_github/gh" "$fake_github/python3"
gh_log="$sandbox/gh.log"
: > "$gh_log"
with_fake_github() { # <command...>
  env PATH="$fake_github:$PATH" FAKE_GH_LOG="$gh_log" FAKE_REMOTES="$fake_remotes" GIT_ALLOW_PROTOCOL=file \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$fake_remotes/tester/.insteadOf" GIT_CONFIG_VALUE_0="git@github.com:tester/" \
    GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com \
    "$@"
}
github_setup() { with_fake_github "$1/scripts/github-setup.sh"; } # <game directory>
board_stays_untouched() { ! grep -q "graphql" "$gh_log"; }
template_refs() { git -C "$template_remote" for-each-ref; }
template_refs_before="$(template_refs)"
template_is_unchanged() { [[ "$(template_refs)" == "$template_refs_before" ]]; }

check "new-game.sh: creates a game for GitHub setup" new_game own-repo --server-port 4440 --client-port 4442
own_repo="$source_directory/own-repo"
own_remote="$fake_remotes/tester/own-repo.git"
: > "$gh_log"
check "project-sync.sh: refuses before setup" fails with_fake_github "$own_repo/scripts/project-sync.sh"
check "project-sync.sh: says to run setup" says "run scripts/github-setup.sh first" with_fake_github "$own_repo/scripts/project-sync.sh"
check "issue-status.sh: refuses before setup" fails with_fake_github "$own_repo/scripts/issue-status.sh" Done 1
check "neither touched a board before setup" board_stays_untouched
check "github-setup.sh: succeeds on a game with no repo" github_setup "$own_repo"
check "github-setup.sh: origin is the game's own repo" says "tester/own-repo.git" git -C "$own_repo" remote get-url origin
check "github-setup.sh: main on the game's remote is the scaffold and the board ids" test "$(git -C "$own_remote" rev-list --count main)" -eq 2
check "github-setup.sh: the ids reach main with no PR" says "PROJECT_ID=fake" git -C "$own_remote" show main:.github/project.env
check "github-setup.sh: that commit holds the game" says '"name": "own-repo"' git -C "$own_remote" show main:package.json
check "github-setup.sh: the game has no template history" fails says "template history" git -C "$own_repo" log --all --oneline
check "github-setup.sh: nothing is left uncommitted" test -z "$(git -C "$own_repo" status --porcelain)"
check "github-setup.sh: runs again cleanly" github_setup "$own_repo"
check "github-setup.sh: the template's remote is untouched" template_is_unchanged
check "project-sync.sh: copes with a repo that has no issues" says "added to project:" with_fake_github "$own_repo/scripts/project-sync.sh"
# sync cases: board ids
if sync_cases_can_run "board ids"; then
  give_game_prettier "$own_repo"
  check "a sync keeps a set-up game's board ids" in_directory "$own_repo" "$sync_tool" sync-template --source "file://$copied_template"
  check "those ids are still there" test -f "$own_repo/.github/project.env"
fi
# sync cases: end

kept_origin="$source_directory/kept-origin"
copy_template "$kept_origin"
git -C "$kept_origin" init -q -b main
git -C "$kept_origin" remote add origin "$template_remote"
: > "$gh_log"
check "github-setup.sh: refuses a copy with the template's origin" fails github_setup "$kept_origin"
check "github-setup.sh: says why" says "delete its .git" github_setup "$kept_origin"
check "github-setup.sh: and how to name a different repo" says "pass --repo <owner/name of that origin>" github_setup "$kept_origin"
check "github-setup.sh: creates no repo for it" fails grep -q "repo create" "$gh_log"
check "github-setup.sh: pushes nothing to the template" template_is_unchanged

# A game made before these fixes: the template's origin and the template's ids, under the game's name.
sed -i 's|^REPO=.*|REPO=tester/old-game|' "$kept_origin/.github/project.env"
: > "$gh_log"
check "project-sync.sh: refuses when origin isn't the repo project.env names" fails with_fake_github "$kept_origin/scripts/project-sync.sh"
check "project-sync.sh: says which repo" says "origin isn't tester/old-game" with_fake_github "$kept_origin/scripts/project-sync.sh"
check "issue-status.sh: refuses too" fails with_fake_github "$kept_origin/scripts/issue-status.sh" Done 1
check "neither touched a board" board_stays_untouched

# A repo that already has a main: this copy's unrelated files must not be committed over it.
check "new-game.sh: creates a game for a taken name" new_game taken-name --server-port 4450 --client-port 4452
taken_name="$source_directory/taken-name"
taken_remote="$fake_remotes/tester/taken-name.git"
git init -q --bare -b main "$taken_remote"
someone_else="$sandbox/someone-else"
git init -q -b main "$someone_else"
as_tester -C "$someone_else" commit -q --allow-empty -m "someone else's work"
git -C "$someone_else" push -q "$taken_remote" main
taken_main_before="$(git -C "$taken_remote" rev-parse main)"
: > "$gh_log"
check "github-setup.sh: refuses a repo that already has main" fails github_setup "$taken_name"
check "github-setup.sh: says main already exists" says "already has a main branch" github_setup "$taken_name"
check "github-setup.sh: stops before setup_project.py" fails grep -q "setup_project ran" "$gh_log"
check "github-setup.sh: commits nothing over it" fails git -C "$taken_name" rev-parse --verify -q HEAD
check "github-setup.sh: leaves that main alone" test "$(git -C "$taken_remote" rev-parse main)" == "$taken_main_before"

# A refused push of the first ids: the commit exists, so a re-run must still push it.
check "new-game.sh: creates a game for a refused push" new_game refused-push --server-port 4460 --client-port 4462
refused_push="$source_directory/refused-push"
refused_remote="$fake_remotes/tester/refused-push.git"
refuse_flag="$sandbox/refuse-board-ids"
git init -q --bare -b main "$refused_remote"
cat > "$refused_remote/hooks/pre-receive" <<HOOK
#!/usr/bin/env bash
[[ -e "$refuse_flag" ]] || exit 0
while read -r _ new _; do git cat-file -e "\$new:.github/project.env" 2>/dev/null && exit 1; done
exit 0
HOOK
chmod +x "$refused_remote/hooks/pre-receive"
touch "$refuse_flag"
check "github-setup.sh: stops when the first ids are refused" fails github_setup "$refused_push"
rm "$refuse_flag"
check "github-setup.sh: a re-run after that succeeds" github_setup "$refused_push"
check "github-setup.sh: and the ids reach main" says "PROJECT_ID=fake" git -C "$refused_remote" show main:.github/project.env

# Something staged between runs must not ride along with the ids.
check "new-game.sh: creates a game for a staged file" new_game staged-file --server-port 4470 --client-port 4472
staged_file="$source_directory/staged-file"
staged_remote="$fake_remotes/tester/staged-file.git"
touch "$fake_remotes/setup-project-fails"
check "github-setup.sh: stops when setup_project.py fails" fails github_setup "$staged_file"
rm "$fake_remotes/setup-project-fails"
touch "$staged_file/staged-by-someone.txt"
git -C "$staged_file" add staged-by-someone.txt
check "github-setup.sh: succeeds with a file staged" github_setup "$staged_file"
check "github-setup.sh: the ids reach main with a file staged" says "PROJECT_ID=fake" git -C "$staged_remote" show main:.github/project.env
check "github-setup.sh: the staged file isn't pushed" fails git -C "$staged_remote" cat-file -e main:staged-by-someone.txt
check "github-setup.sh: it stays staged" says "staged-by-someone.txt" git -C "$staged_file" diff --cached --name-only

touch "$fake_remotes/rulesets-fail"
check "github-setup.sh: a failed ruleset lookup stops it" fails github_setup "$staged_file"
check "github-setup.sh: and says why" says "fake ruleset reason" github_setup "$staged_file"
rm "$fake_remotes/rulesets-fail"

# origin_is_repo, across the forms an origin URL takes.
url_checkout="$sandbox/url-checkout"
git init -q "$url_checkout"
git -C "$url_checkout" remote add origin placeholder
origin_is_repo_without_origin() {
  local no_origin="$sandbox/no-origin"
  git init -q "$no_origin"
  # shellcheck disable=SC1091
  (source "$repo_root/scripts/lib/identity.sh" && origin_is_repo "$no_origin" tester/game)
}
origin_matches() { # <origin url> <owner/name>
  git -C "$url_checkout" remote set-url origin "$1"
  # shellcheck disable=SC1091
  (source "$repo_root/scripts/lib/identity.sh" && origin_is_repo "$url_checkout" "$2")
}
for matching_url in git@github.com:tester/game.git git@github.com:tester/game https://github.com/tester/game.git \
  https://github.com/tester/game https://github.com/tester/game/ ssh://git@github.com/tester/game.git; do
  check "origin_is_repo: $matching_url" origin_matches "$matching_url" tester/game
done
check "origin_is_repo: a dot in the name is only a dot" fails origin_matches https://github.com/tester/axb.git tester/a.b
check "origin_is_repo: a dotted name matches itself" origin_matches https://github.com/tester/a.b.git tester/a.b
check "origin_is_repo: a longer repo name" fails origin_matches https://github.com/tester/game-two.git tester/game
check "origin_is_repo: a longer owner name" fails origin_matches git@github.com:other-tester/game.git tester/game
check "origin_is_repo: no origin" fails origin_is_repo_without_origin

check "new-game.sh: says when a game has no repo" says "no git repo until you run scripts/github-setup.sh" "$source_directory/$TEMPLATE_PROJECT/new-game.sh" --help
check "new-game.sh: stops on a bad port" fails new_game bad-port --server-port 80 --client-port 4432
check "new-game.sh: removes the copy after a refusal" is_absent "$source_directory/bad-port"

if [[ $failures -gt 0 ]]; then
  echo "presetup.test.sh: $failures failure(s), $skipped cases skipped"
  exit 1
fi
echo "presetup.test.sh: all cases passed, $skipped cases skipped"
