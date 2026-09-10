#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# resume-in-container.sh — continue a Claude Code conversation started on the HOST inside the
# devcontainer (or the other way round).
#
#   scripts/resume-in-container.sh [<session-id>] [--to <host checkout path>]
#
# ~/.claude is bind-mounted into the container, but Claude Code files transcripts under a key
# derived from the working directory (/home/you/source/<game> on the host, /workspace inside),
# so a session started in one place is invisible from the other. This copies the transcript
# (and its side directory) under the other key and prints the resume command. Run it from
# wherever the conversation currently lives; the newest transcript is used when no id is given.
#
# Inside the container the host path is not knowable from the filesystem: dev-container.sh
# injects it as HOST_WORKSPACE_DIR when it creates the container; `--to` overrides it (needed
# for a container created before that variable existed, until it is rebuilt).
# ---------------------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECTS_DIR="${HOME}/.claude/projects"
CONTAINER_WORKSPACE=/workspace

project_key() { echo "${1//\//-}"; } # /home/me/source/game -> -home-me-source-game
in_container() { [[ -f /.dockerenv ]]; }

session="" host_dir="${HOST_WORKSPACE_DIR:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --to) host_dir="${2:?--to needs a host checkout path}"; shift 2 ;;
    -h | --help) sed -n '3,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) session="$1"; shift ;;
  esac
done

if in_container; then
  [[ -n "$host_dir" ]] || {
    echo "error: the host checkout path is unknown inside the container (HOST_WORKSPACE_DIR is unset)." >&2
    echo "       Rebuild the container (./dev-container.sh rebuild) or pass --to <host checkout path>." >&2
    exit 1
  }
  from_key="$(project_key "$CONTAINER_WORKSPACE")"; to_key="$(project_key "$host_dir")"; where="on the host"
else
  from_key="$(project_key "$ROOT")"; to_key="$(project_key "$CONTAINER_WORKSPACE")"; where="inside the container (./dev-container.sh)"
fi
[[ "$from_key" != "$to_key" ]] || { echo "error: source and target project keys are both '$to_key'; nothing to copy." >&2; exit 1; }

if [[ -z "$session" ]]; then
  newest="$(ls -t "$PROJECTS_DIR/$from_key"/*.jsonl 2>/dev/null | head -1 || true)"
  # Host sessions are often started from the parent folder (the directory holding all games).
  [[ -n "$newest" ]] || newest="$(ls -t "$PROJECTS_DIR/$(project_key "$(dirname "$ROOT")")"/*.jsonl 2>/dev/null | head -1 || true)"
  [[ -n "$newest" ]] || { echo "error: no transcript found under $PROJECTS_DIR for this checkout" >&2; exit 1; }
  session="$(basename "$newest" .jsonl)"
fi
# An explicit id may live under any project key (e.g. a session started from the parent folder).
source_file="$(ls "$PROJECTS_DIR"/*/"$session.jsonl" 2>/dev/null | head -1 || true)"
[[ -f "$source_file" ]] || { echo "error: no transcript $session.jsonl under $PROJECTS_DIR" >&2; exit 1; }
from_key="$(basename "$(dirname "$source_file")")"
[[ "$from_key" != "$to_key" ]] || { echo "error: transcript $session already lives under $to_key." >&2; exit 1; }
mkdir -p "$PROJECTS_DIR/$to_key"
cp -f "$source_file" "$PROJECTS_DIR/$to_key/"
[[ -d "$PROJECTS_DIR/$from_key/$session" ]] && cp -rf "$PROJECTS_DIR/$from_key/$session" "$PROJECTS_DIR/$to_key/"
echo "Transcript $session copied under $to_key. Continue $where with:"
echo "  claude --resume $session"
