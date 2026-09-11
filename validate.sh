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
#
# Extra args after -- are passed to the underlying command.
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
  echo "Usage: ./validate.sh <test|integration|typecheck|lint|duplication|all> [-tN] [-hN] [-G pattern] [-- extra-args...]" >&2
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
  all="$(grep -rn --include='*.ts' 'eslint-disable' "${PACKAGE_SOURCES[@]}" 2>/dev/null || true)"
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

  echo "$output" | apply_filters
  return $rc
}

if [[ "$COMMAND" == "all" ]]; then
  failed=()
  for cmd in lint duplication typecheck test; do
    echo "=== $cmd ==="
    if ! run_one "$cmd" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"; then
      failed+=("$cmd")
    fi
    echo ""
  done
  if [[ ${#failed[@]} -gt 0 ]]; then
    echo "FAILED: ${failed[*]}"
    exit 1
  else
    echo "ALL PASSED"
  fi
else
  run_one "$COMMAND" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
fi
