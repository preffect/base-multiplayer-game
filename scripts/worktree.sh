#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# worktree.sh — one git worktree per branch under .worktrees/, for parallel agents (TEAM.md).
#
#   scripts/worktree.sh add <branch>      -> prints the worktree path; creates it if missing
#   scripts/worktree.sh remove <branch>
#
# An existing local branch is reused untouched; otherwise the branch tracks origin/<branch> if that
# exists, else starts from origin/main. An existing worktree is fast-forwarded to origin/<branch>;
# a dirty or diverged worktree is an error. A branch checked out in the main tree is used there.
# Run inside the devcontainer (git records absolute paths); scripts/agent.sh wraps this from the host.
# ---------------------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKTREES_DIR=.worktrees
cd "$ROOT"

branch_exists() { git show-ref -q --verify "refs/$1"; } # heads/<b> | remotes/origin/<b>

create() { # <branch> <path>
  if branch_exists "heads/$1"; then git worktree add -q "$2" "$1"
  elif branch_exists "remotes/origin/$1"; then git worktree add -q --track -b "$1" "$2" "origin/$1"
  else git worktree add -q -b "$1" "$2" origin/main
  fi
}

fast_forward() { # <path> <branch>
  branch_exists "remotes/origin/$2" || return 0
  [[ "$(git -C "$1" rev-parse HEAD)" != "$(git rev-parse "origin/$2")" ]] || return 0
  [[ -z "$(git -C "$1" status --porcelain)" ]] || { echo "error: $1 has uncommitted changes" >&2; exit 1; }
  git -C "$1" merge -q --ff-only "origin/$2" || { echo "error: $1 has diverged from origin/$2" >&2; exit 1; }
}

add() { # <branch> -> path relative to ROOT
  local branch="$1" path="$WORKTREES_DIR/$1"
  if [[ "$(git branch --show-current)" == "$branch" ]]; then echo "."; return 0; fi
  git fetch -q origin
  [[ -d "$path" ]] || create "$branch" "$path"
  fast_forward "$path" "$branch"
  echo "$path"
}

remove() { # <branch>
  git worktree remove --force "$WORKTREES_DIR/$1" 2>/dev/null || true
  git worktree prune
  echo "removed worktree for $1"
}

case "${1:-}" in
  add) add "${2:?branch}" ;;
  remove) remove "${2:?branch}" ;;
  *) sed -n '3,12p' "${BASH_SOURCE[0]}"; exit 1 ;;
esac
