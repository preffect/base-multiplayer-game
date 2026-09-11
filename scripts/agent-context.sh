#!/usr/bin/env bash
# agent-context.sh — exact live context size of this session or a named subagent (docs/TEAM.md).
#
#   scripts/agent-context.sh                 # the calling session (newest transcript of this project, or CLAUDE_SESSION_ID)
#   scripts/agent-context.sh <agent-name>    # a subagent of that session, by the exact name it was spawned with
#   scripts/agent-context.sh --session <id> [agent-name]
#
# Prints one line:  live=<tokens> peak=<tokens> turns=<n> compacted=<yes|no> file=<path>
# "live" is input + cache_read + cache_creation of the latest assistant message with usage, which is what the
# model saw on its last call (matches /context within a few percent and resets after a compaction).
# "turns" counts distinct assistant messages (the transcript writes one line per content block).
# Transcripts live under ~/.claude/projects/<key>/ where <key> is the session's cwd with every non-alphanumeric
# character replaced by "-"; this script resolves the MAIN worktree root, so a headless session started inside
# a worktree (scripts/agent.sh) lives under the worktree's key and is not found here.
# Exit 2 when no transcript is found. Needs jq.
set -euo pipefail

session="${CLAUDE_SESSION_ID:-}"
if [[ "${1:-}" == "--session" ]]; then session="${2:?session id}"; shift 2; fi
agent="${1:-}"

root="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}' || true)"
[[ -n "$root" ]] || root="$(pwd -P)"
project_key="$(printf %s "$root" | sed 's/[^A-Za-z0-9]/-/g')"
project_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$project_key"
[[ -d "$project_dir" ]] || { echo "error: no transcripts under $project_dir" >&2; exit 2; }

if [[ -z "$session" ]]; then
  file="$(ls -t "$project_dir"/*.jsonl 2>/dev/null | head -1 || true)"
  [[ -n "$file" ]] || { echo "error: no session transcript in $project_dir" >&2; exit 2; }
  session="$(basename "$file" .jsonl)"
fi
if [[ -n "$agent" ]]; then
  # Transcript names are agent-a<name>-<16 hex>.jsonl; anchor the id so "foo" does not match "foo-r2".
  file="$(ls -t "$project_dir/$session/subagents/"agent-*"$agent"-????????????????.jsonl 2>/dev/null | head -1 || true)"
  [[ -n "$file" ]] || { echo "error: no transcript for agent '$agent' under session $session" >&2; exit 2; }
else
  file="$project_dir/$session.jsonl"
  [[ -f "$file" ]] || { echo "error: no transcript $file" >&2; exit 2; }
fi

jq -rs --arg file "$file" '
  [ .[] | select(.type == "assistant" and .message.usage != null)
    | { id: (.message.id // ""), ctx: (.message.usage | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)) } ]
  | reduce .[] as $e ({ seen: {}, ctx: [] };
      if $e.id != "" and .seen[$e.id] then . else .seen[$e.id] = true | .ctx += [$e.ctx] end)
  | .ctx as $ctx
  | ([ $ctx[] | select(. > 0) ] | last // 0) as $live
  | "live=\($live) peak=\($ctx | max // 0) turns=\($ctx | length)"
' "$file" | tr -d '\n'
compacted="$(jq -rs 'if any(.[]; .isCompactSummary == true or .subtype == "compact_boundary") then "yes" else "no" end' "$file")"
printf ' compacted=%s file=%s\n' "$compacted" "$file"
