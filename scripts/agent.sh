#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# agent.sh — run ONE role of the agent team headlessly, always INSIDE the devcontainer.
#
#   scripts/agent.sh <role> [options] "<task>"        task may also be "-" to read stdin
#   scripts/agent.sh worktree-remove <branch>
#
# Options:
#   --branch <name>    work in a git worktree for <name> under .worktrees/<name>. An existing
#                      local branch is reused as is (never reset); otherwise the branch is created
#                      from origin/<name> if it exists, else from origin/main. An existing worktree
#                      is fast-forwarded to origin/<name>; a dirty or diverged worktree is an error.
#                      Parallel agents each get their own worktree; the main checkout stays free.
#   --ticket <N>       ticket the task belongs to (repeatable)
#   --pr <N>           pull request the task is about (reviews, fixes)
#   --model <model>    override the Claude model
#   --timeout <secs>   hard stop for the run (default 7200)
#
# Roles are the files in .claude/roles/ minus _common.md (prepended to every prompt).
# From the host the script execs into the running <folder>-dev container as its user
# (scripts/lib/identity.sh); inside the container it runs claude directly.
# Logs: .qa/agents/<timestamp>-<role>[-pr<N>]-<pid>.prompt.md and .log (see TEAM.md).
# ---------------------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/identity.sh" # CONTAINER_USER / CONTAINER_HOME / CONTAINER_WORKSPACE / container_name_from_dir
WORKTREES_DIR=.worktrees
ROLES_DIR=.claude/roles
LOG_DIR=.qa/agents
COMMON_ROLE=_common
DEFAULT_TIMEOUT_SECONDS=7200
# Headless runs have no human to answer permission prompts: the container is the sandbox, so the
# built-in tools plus every MCP server in .mcp.json are pre-approved for the run.
BUILTIN_TOOLS="Bash,Read,Edit,Write,Glob,Grep,WebFetch,WebSearch,Agent,TodoWrite"
CONTAINER_PATH="$CONTAINER_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

usage() { awk 'BEGIN{n=0} /^# -{20,}/{n++; next} n==1{sub(/^# ?/,""); print} n==2{exit}' "${BASH_SOURCE[0]}"; exit 1; }
in_container() { [[ -f /.dockerenv ]]; }

run_in_workdir() { # <workdir-relative> <command...> — inside the container, in that directory
  local workdir="$1"; shift
  if in_container; then (cd "$ROOT/$workdir" && "$@")
  else
    docker exec -i -u "$CONTAINER_USER" -w "$CONTAINER_WORKSPACE/$workdir" \
      -e "HOME=$CONTAINER_HOME" -e "PATH=$CONTAINER_PATH" "$(container_name_from_dir "$ROOT")" "$@"
  fi
}

# Worktrees are created and removed INSIDE the container: git records absolute paths, and the
# repo lives at /workspace there, at a host path here.
worktree_remove() {
  local branch="$1"
  run_in_workdir . git worktree remove --force "$WORKTREES_DIR/$branch" 2>/dev/null || true
  run_in_workdir . git worktree prune
  echo "removed worktree for $branch"
}

branch_exists() { run_in_workdir . git show-ref -q --verify "refs/$1"; } # heads/<b> | remotes/origin/<b>

worktree_create() { # <branch> <path> — reuse a local branch untouched; else track origin/<branch>; else start from origin/main
  local branch="$1" path="$2"
  if branch_exists "heads/$branch"; then run_in_workdir . git worktree add -q "$path" "$branch"
  elif branch_exists "remotes/origin/$branch"; then run_in_workdir . git worktree add -q --track -b "$branch" "$path" "origin/$branch"
  else run_in_workdir . git worktree add -q -b "$branch" "$path" origin/main
  fi
}

worktree_fast_forward() { # <path> <branch> — bring an existing worktree up to origin/<branch>; refuse dirty or diverged
  local path="$1" branch="$2"
  branch_exists "remotes/origin/$branch" || return 0
  [[ "$(run_in_workdir "$path" git rev-parse HEAD)" != "$(run_in_workdir . git rev-parse "origin/$branch")" ]] || return 0
  if [[ -n "$(run_in_workdir "$path" git status --porcelain)" ]]; then
    echo "error: $path has uncommitted changes; commit or discard them before it can follow origin/$branch" >&2; exit 1
  fi
  run_in_workdir "$path" git merge -q --ff-only "origin/$branch" \
    || { echo "error: $path has diverged from origin/$branch; reconcile it by hand" >&2; exit 1; }
}

ensure_worktree() { # <branch> -> prints the worktree path relative to ROOT
  local branch="$1" path="$WORKTREES_DIR/$1"
  # A branch checked out in the main tree cannot also be a worktree: work there instead.
  if [[ "$(run_in_workdir . git branch --show-current)" == "$branch" ]]; then echo "."; return 0; fi
  run_in_workdir . git fetch -q origin
  [[ -d "$ROOT/$path" ]] || worktree_create "$branch" "$path"
  worktree_fast_forward "$path" "$branch"
  echo "$path"
}

[[ $# -ge 1 ]] || usage
if [[ "$1" == "worktree-remove" ]]; then worktree_remove "${2:?branch}"; exit 0; fi

role="$1"; shift
role_file="$ROOT/$ROLES_DIR/$role.md"
if [[ "$role" == "$COMMON_ROLE" || ! -f "$role_file" ]]; then
  echo "error: unknown role '$role' (see $ROLES_DIR/)" >&2; exit 1
fi

branch="" tickets=() pr="" model="" timeout_seconds="$DEFAULT_TIMEOUT_SECONDS" task=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) branch="$2"; shift 2 ;;
    --ticket) tickets+=("$2"); shift 2 ;;
    --pr) pr="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    --timeout) timeout_seconds="$2"; shift 2 ;;
    -) task="$(cat)"; shift ;;
    -*) usage ;;
    *) task="$1"; shift ;;
  esac
done
[[ -n "$task" ]] || usage

workdir="."
[[ -z "$branch" ]] || workdir="$(ensure_worktree "$branch")"
# A worktree needs its own node_modules; the pnpm store is shared so this is quick.
if [[ "$workdir" != "." && ! -d "$ROOT/$workdir/node_modules" ]]; then
  run_in_workdir "$workdir" pnpm install --prefer-offline >/dev/null
fi

mkdir -p "$ROOT/$LOG_DIR"
# The pid keeps parallel runs of the same role in the same second from sharing a log.
run_id="$(date +%Y%m%d-%H%M%S)-$role${pr:+-pr$pr}-$$"
prompt_file="$ROOT/$LOG_DIR/$run_id.prompt.md"
log_file="$ROOT/$LOG_DIR/$run_id.log"
{
  cat "$ROOT/$ROLES_DIR/$COMMON_ROLE.md" "$role_file"
  echo; echo "# Your assignment"; echo
  echo "- Working directory: $CONTAINER_WORKSPACE/$workdir${branch:+ (branch \`$branch\`)}"
  [[ ${#tickets[@]} -eq 0 ]] || echo "- Ticket(s): $(printf '#%s ' "${tickets[@]}")"
  [[ -z "$pr" ]] || echo "- Pull request: #$pr"
  echo; echo "## Task"; echo; echo "$task"
} >"$prompt_file"

mcp_tools="$(jq -r '.mcpServers | keys | map("mcp__" + .) | join(",")' "$ROOT/.mcp.json")"
# (--allowedTools and --mcp-config take lists, so a single-value flag follows each of them)
claude_args=(--allowedTools "$BUILTIN_TOOLS,$mcp_tools" --permission-mode acceptEdits
  --mcp-config "$CONTAINER_WORKSPACE/.mcp.json" --output-format text -p)
[[ -z "$model" ]] || claude_args+=(--model "$model")
echo "agent: $role -> $log_file"
run_in_workdir "$workdir" timeout "$timeout_seconds" claude "${claude_args[@]}" <"$prompt_file" 2>&1 \
  | tee "$log_file" | tail -n 40
