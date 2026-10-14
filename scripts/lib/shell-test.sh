#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# shell-test.sh — helpers shared by the shell suites (scripts/*.test.sh).
# Sourced after the suite sets `sandbox` (a mktemp -d directory).
#
#   check <description> <1|0>     prints ok / FAIL and counts failures
#   holds <command...>            echoes 1 when the command succeeds, else 0 (for arithmetic checks)
#   wait_for <command...>         polls the command until it succeeds; non-zero on timeout
#   make_origin                   a bare origin ($origin) and an author clone ($author) with one commit on main
#   merge_to_main <file> <text>   a new commit on origin/main
#   finish_suite <name>           prints the verdict and exits non-zero on any failure
# ---------------------------------------------------------------------------

TEST_WAIT_STEPS_MAX=150
TEST_WAIT_STEP_SECONDS=0.2

failures=0

check() { # <description> <arithmetic-truth: 1 passes, 0 fails>
  if [[ "$2" -ne 0 ]]; then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi
}

holds() { "$@" 2>/dev/null && echo 1 || echo 0; }

wait_for() {
  local step
  for ((step = 0; step < TEST_WAIT_STEPS_MAX; step++)); do
    "$@" 2>/dev/null && return 0
    sleep "$TEST_WAIT_STEP_SECONDS"
  done
  return 1
}

git_as_test() { git -c user.name=test -c user.email=test@example.com "$@"; }

make_origin() {
  origin="$sandbox/origin.git"
  author="$sandbox/author"
  git init -q --bare -b main "$origin"
  git init -q -b main "$author"
  git -C "$author" remote add origin "$origin"
  printf '.game-logs/\n.angular/\nnode_modules/\n' > "$author/.gitignore"
  echo 'lockfileVersion: 1' > "$author/pnpm-lock.yaml"
  echo v1 > "$author/game.txt"
  git -C "$author" add -A
  git_as_test -C "$author" commit -q -m v1
  git -C "$author" push -q -u origin main
}

merge_to_main() { # <file> <content>
  echo "$2" > "$author/$1"
  git -C "$author" add -A
  git_as_test -C "$author" commit -q -m "$1: $2"
  git -C "$author" push -q origin main
}

origin_head() { git -C "$author" rev-parse HEAD; }

finish_suite() { # <suite name>
  if [[ $failures -gt 0 ]]; then
    echo "$1: $failures failure(s)"
    exit 1
  fi
  echo "$1: all cases passed"
}
