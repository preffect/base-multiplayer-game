#!/usr/bin/env bash
# validate.sh - Unified validation runner for test, typecheck, and lint
# Usage: ./validate.sh <command> [options] [-- extra-args...]
#
# Commands:
#   test         Run unit tests with coverage thresholds (pnpm -r test)
#   integration  Run the *.integration.test.ts / *.integration.spec.ts tier plus the *.gameplay.test.ts scenarios (pnpm -r test:integration)
#   typecheck    Run type checking (pnpm -r typecheck)
#   lint         Run linting (eslint + prettier --check + disable-directive / TODO audit + docs/INDEX.md freshness)
#   duplication  Run jscpd against .jscpd.json (docs/ENGINEERING.md §3.3)
#   all          Run lint, duplication, typecheck, test in sequence
#
# Options:
#   -tN        Tail N lines of output (e.g. -t20)
#   -hN        Head N lines of output (e.g. -h50)
#   -G PATTERN Grep output for PATTERN
#   --fresh    Ignore the result cache and re-run (a green result is still stamped)
#
# Extra args after -- are passed to the underlying command (and disable the result cache).
#
# Result cache (docs/ENGINEERING.md §1): a green run is stamped under
# $HOME/.cache/<slug>-validate/<tree>.<command> (override the directory with VALIDATE_CACHE_DIR),
# keyed by `git write-tree` of the whole working tree, tracked and untracked, plus the Node major
# version. A repeat call on the same tree prints `cached green from <time> at tree <hash>` and the
# stored log path, applies -t/-h/-G to the stored log, and exits 0. Red is never cached. `all`
# stamps each phase and itself. Shared across worktrees at the same content.
#
# Examples:
#   ./validate.sh test                    # run all tests
#   ./validate.sh typecheck -t20          # typecheck, show last 20 lines
#   ./validate.sh lint -G 'error'         # lint, grep for pattern
#   ./validate.sh test -- --filter shared # test only shared package
#   ./validate.sh all -t30               # run all, tail 30 lines each

TAIL_N=""
HEAD_N=""
GREP_PAT=""
COMMAND=""
EXTRA_ARGS=()
FRESH=0

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    test|integration|typecheck|lint|duplication|all)
      COMMAND="$1"
      shift
      ;;
    -t[0-9]*)
      TAIL_N="${1#-t}"
      shift
      ;;
    -h[0-9]*)
      HEAD_N="${1#-h}"
      shift
      ;;
    -G)
      GREP_PAT="$2"
      shift 2
      ;;
    -G*)
      GREP_PAT="${1#-G}"
      shift
      ;;
    --fresh)
      FRESH=1
      shift
      ;;
    --)
      shift
      EXTRA_ARGS=("$@")
      break
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$COMMAND" ]]; then
  echo "Usage: ./validate.sh <test|integration|typecheck|lint|duplication|all> [-tN] [-hN] [-G pattern] [--fresh] [-- extra-args...]" >&2
  exit 1
fi

apply_filters() {
  local input
  input="$(cat)"

  if [[ -n "$GREP_PAT" ]]; then
    input="$(echo "$input" | grep -E "$GREP_PAT" || true)"
  fi

  if [[ -n "$HEAD_N" ]]; then
    input="$(echo "$input" | head -n "$HEAD_N")"
  fi

  if [[ -n "$TAIL_N" ]]; then
    input="$(echo "$input" | tail -n "$TAIL_N")"
  fi

  echo "$input"
}

# ---------------------------------------------------------------------------
# Result cache (see the header). Only green runs are stamped; a stamp is
# key=value lines: exit, time, log, node, command, tree.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALL_PHASES=(lint duplication typecheck test)
CACHE_DIR=""
TREE_HASH=""
NODE_MAJOR=""
RUN_ONE_OUTPUT=""
ALL_RAW_FILE="" # set by `all`: every phase appends its raw output here for the `all` stamp's log
TEMP_INDEX=""   # the temporary index while cache_tree_hash runs
CACHE_HIT_TIME=""
CACHE_HIT_LOG=""

cleanup_temp_files() { rm -f "${TEMP_INDEX:+$TEMP_INDEX}" "${TEMP_INDEX:+$TEMP_INDEX.lock}" "${ALL_RAW_FILE:+$ALL_RAW_FILE}"; }
trap cleanup_temp_files EXIT
trap 'cleanup_temp_files; exit 130' INT TERM

# The cache name: SLUG from PORTS.env, else the main checkout's directory name (the same for
# every worktree of the repo), else this directory's name.
cache_slug() {
  local slug
  slug="$(sed -n 's/^SLUG=//p' "$SCRIPT_DIR/PORTS.env" 2>/dev/null | head -n 1)"
  if [[ -z "$slug" ]]; then
    local common_dir
    common_dir="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    [[ -n "$common_dir" ]] && slug="$(basename "$(dirname "$common_dir")")"
  fi
  [[ -n "$slug" ]] || slug="$(basename "$SCRIPT_DIR")"
  echo "$slug"
}

# One hash for the exact working tree, tracked and untracked (ignored files excluded), without
# touching the real index: copy it (so unchanged files are not re-hashed), `git add -A` into the
# copy, `git write-tree`. Empty when this is not a git checkout. The add writes real loose objects
# (a blob per changed file plus the tree) into .git/objects; they are unreachable and harmless,
# and `git gc` prunes them after its default two weeks.
cache_tree_hash() {
  local real_index hash
  real_index="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-path index 2>/dev/null || true)"
  [[ -n "$real_index" ]] || return 0
  TEMP_INDEX="$(mktemp)"
  [[ -f "$real_index" ]] && cp "$real_index" "$TEMP_INDEX"
  hash="$(cd "$SCRIPT_DIR" && GIT_INDEX_FILE="$TEMP_INDEX" git add -A . 2>/dev/null \
    && GIT_INDEX_FILE="$TEMP_INDEX" git write-tree 2>/dev/null || true)"
  rm -f "$TEMP_INDEX" "$TEMP_INDEX.lock"
  TEMP_INDEX=""
  echo "$hash"
}

cache_init() {
  # Extra args change what runs, so the result is not comparable: no cache for those calls.
  [[ ${#EXTRA_ARGS[@]} -eq 0 ]] || return 0
  TREE_HASH="$(cache_tree_hash)"
  [[ -n "$TREE_HASH" ]] || return 0
  NODE_MAJOR="$(node --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')"
  CACHE_DIR="${VALIDATE_CACHE_DIR:-$HOME/.cache/$(cache_slug)-validate}"
  if ! mkdir -p "$CACHE_DIR/logs" 2>/dev/null || [[ ! -w "$CACHE_DIR/logs" ]]; then
    echo "validate.sh: result cache disabled: cannot write $CACHE_DIR" >&2
    CACHE_DIR=""
  fi
}

cache_stamp_path() { echo "$CACHE_DIR/$TREE_HASH.$1"; }
cache_log_path() { echo "$CACHE_DIR/logs/$TREE_HASH.$1.log"; }
stamp_field() { sed -n "s/^$2=//p" "$1" | head -n 1; }
have_filters() { [[ -n "$GREP_PAT" || -n "$HEAD_N" || -n "$TAIL_N" ]]; }

# Returns 0, with CACHE_HIT_TIME / CACHE_HIT_LOG set, when a green stamp with its log exists for
# this tree, command and Node major; returns 1 otherwise (a stamp whose log is gone is a miss).
cache_hit() {
  local cmd="$1" stamp
  [[ -n "$CACHE_DIR" && $FRESH -eq 0 ]] || return 1
  stamp="$(cache_stamp_path "$cmd")"
  [[ -f "$stamp" ]] || return 1
  [[ "$(stamp_field "$stamp" exit)" == "0" && "$(stamp_field "$stamp" node)" == "$NODE_MAJOR" ]] || return 1
  CACHE_HIT_TIME="$(stamp_field "$stamp" time)"
  CACHE_HIT_LOG="$(stamp_field "$stamp" log)"
  if [[ ! -f "$CACHE_HIT_LOG" ]]; then
    echo "validate.sh: stamp $stamp has no log ($CACHE_HIT_LOG); re-running" >&2
    return 1
  fi
}

# Prints the cached-green lines and, when a filter is set, the filtered stored log.
print_cache_hit() {
  echo "cached green from $CACHE_HIT_TIME at tree $TREE_HASH"
  echo "log: $CACHE_HIT_LOG"
  if have_filters; then
    apply_filters < "$CACHE_HIT_LOG"
  fi
}

# Writes <content> to <path> atomically (per-process temp name + mv), so concurrent runs on one
# tree never expose a half-written file and never race on one temp name.
write_atomically() { # <path> <content>
  printf '%s\n' "$2" > "$1.tmp.$$" && mv "$1.tmp.$$" "$1"
}

# Stamps a green run of <cmd> whose raw output is <output>, unless the run changed the tree.
cache_store() {
  local cmd="$1" output="$2"
  [[ -n "$CACHE_DIR" ]] || return 0
  if [[ "$(cache_tree_hash)" != "$TREE_HASH" ]]; then
    echo "not cached: the run changed the working tree"
    return 0
  fi
  local stamp log stamp_body
  stamp="$(cache_stamp_path "$cmd")"
  log="$(cache_log_path "$cmd")"
  stamp_body="$(printf 'exit=0\ntime=%s\nlog=%s\nnode=%s\ncommand=%s\ntree=%s' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$log" "$NODE_MAJOR" "$cmd" "$TREE_HASH")"
  if ! { write_atomically "$log" "$output" && write_atomically "$stamp" "$stamp_body"; } 2>/dev/null; then
    echo "not cached: cannot write $CACHE_DIR"
  fi
}

append_all_raw() { [[ -z "$ALL_RAW_FILE" ]] || printf '%s\n' "$1" >> "$ALL_RAW_FILE"; }

# Runs <cmd> through the cache: a hit prints the stamp (and feeds the stored phase log to the
# `all` log, so filters on an `all` hit see every phase); a green run is stamped; red never is.
run_cached() {
  local cmd="$1"
  shift
  if cache_hit "$cmd"; then
    print_cache_hit
    append_all_raw "$(cat "$CACHE_HIT_LOG")"
    return 0
  fi
  local rc=0
  run_one "$cmd" "$@" || rc=$?
  append_all_raw "$RUN_ONE_OUTPUT"
  if [[ $rc -eq 0 ]]; then
    cache_store "$cmd" "$RUN_ONE_OUTPUT"
  fi
  return $rc
}

build_shared() {
  # Build shared package so downstream .d.ts references are fresh
  pnpm --filter @base-multiplayer-game/shared build > /dev/null 2>&1 || true
}

# Source files the standards apply to (docs/ENGINEERING.md); tests included.
PACKAGE_SOURCES=(packages/shared/src packages/server/src packages/client/src)
# The paths jscpd scans; its thresholds and ignore list live in .jscpd.json.
DUPLICATION_PATHS=("${PACKAGE_SOURCES[@]}")

# docs/ENGINEERING.md §3.3: an eslint-disable needs a justification on the directive
# (`// eslint-disable-next-line rule -- why`). Prints the count; fails on an unjustified one.
audit_disable_directives() {
  local all unjustified
  all="$(grep -rn --include='*.ts' -E '(//|/\*) *eslint-disable' "${PACKAGE_SOURCES[@]}" 2>/dev/null || true)"
  unjustified="$(echo "$all" | grep -v '^$' | grep -v -- ' -- ' || true)"
  echo "eslint-disable directives: $(echo "$all" | grep -c 'eslint-disable' || true)"
  if [[ -n "$unjustified" ]]; then
    echo "Unjustified eslint-disable (add ' -- <reason>' to the directive):"
    echo "$unjustified"
    return 1
  fi
}

# docs/ENGINEERING.md §3.3: a TODO carries a ticket number; TODO(game)/TODO(init) are the
# template's extension-point markers and are exempt.
audit_todo_markers() {
  local untracked
  untracked="$(grep -rn --include='*.ts' -E '\bTODO\b' "${PACKAGE_SOURCES[@]}" 2>/dev/null \
    | grep -v -E 'TODO\((game|init|#[0-9]+)\)' || true)"
  if [[ -n "$untracked" ]]; then
    echo "TODO without a ticket (use TODO(#N), or TODO(game)/TODO(init) for template seams):"
    echo "$untracked"
    return 1
  fi
}

run_one() {
  local cmd="$1"
  shift
  local output
  local rc=0

  case "$cmd" in
    test)
      if [[ $# -gt 0 ]]; then
        output="$(pnpm -r test "$@" 2>&1)" || rc=$?
      else
        output="$(pnpm -r test 2>&1)" || rc=$?
      fi
      ;;
    integration)
      # Each package's test:integration script selects the *.integration.* tier (docs/ENGINEERING.md §2.2).
      build_shared
      output="$(pnpm -r --if-present test:integration "$@" 2>&1)" || rc=$?
      ;;
    typecheck)
      build_shared
      if [[ $# -gt 0 ]]; then
        output="$(pnpm -r typecheck "$@" 2>&1)" || rc=$?
      else
        output="$(pnpm -r typecheck 2>&1)" || rc=$?
      fi
      ;;
    duplication)
      output="$(pnpm jscpd "${DUPLICATION_PATHS[@]}" "$@" 2>&1)" || rc=$?
      ;;
    lint)
      # Run eslint then prettier check
      local lint_out=""
      local prettier_out=""
      local lint_rc=0
      local prettier_rc=0

      # Each audit is captured on its own: a substitution only reports its last command's status.
      local directive_out=""
      local todo_out=""
      local docs_index_out=""
      local audit_rc=0

      lint_out="$(pnpm eslint . "$@" 2>&1)" || lint_rc=$?
      prettier_out="$(pnpm prettier --check . "$@" 2>&1)" || prettier_rc=$?
      directive_out="$(audit_disable_directives)" || audit_rc=1
      todo_out="$(audit_todo_markers)" || audit_rc=1
      docs_index_out="$(scripts/docs-index.sh --check 2>&1)" || audit_rc=1

      output="${lint_out}"
      local extra
      for extra in "$prettier_out" "$directive_out" "$todo_out" "$docs_index_out"; do
        if [[ -n "$extra" ]]; then
          output="${output}
${extra}"
        fi
      done

      if [[ $lint_rc -ne 0 || $prettier_rc -ne 0 || $audit_rc -ne 0 ]]; then
        rc=1
      fi
      ;;
  esac

  RUN_ONE_OUTPUT="$output"
  echo "$output" | apply_filters
  return $rc
}

cache_init

if [[ "$COMMAND" == "all" ]]; then
  if cache_hit all; then
    print_cache_hit
    echo "ALL PASSED"
    exit 0
  fi
  failed=()
  ALL_RAW_FILE="$(mktemp)"
  for cmd in "${ALL_PHASES[@]}"; do
    echo "=== $cmd ==="
    append_all_raw "=== $cmd ==="
    if ! run_cached "$cmd" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"; then
      failed+=("$cmd")
    fi
    echo ""
    append_all_raw ""
  done
  if [[ ${#failed[@]} -gt 0 ]]; then
    echo "FAILED: ${failed[*]}"
    exit 1
  else
    echo "ALL PASSED"
    append_all_raw "ALL PASSED"
    cache_store all "$(cat "$ALL_RAW_FILE")"
  fi
else
  run_cached "$COMMAND" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
fi
