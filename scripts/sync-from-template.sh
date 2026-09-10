#!/usr/bin/env bash
set -euo pipefail
print_help() { awk 'BEGIN{n=0} /^# -{20,}/{n++; next} n==1{sub(/^# ?/,""); print} n==2{exit}' "$0"; }

# ---------------------------------------------------------------------------
# sync-from-template.sh — pull template-owned files from base-multiplayer-game into this game. # KEEP_TEMPLATE_NAME
#
# Keeps a game in step with the template WITHOUT touching game-owned code (docs/WORKFLOW.md "docs
# stay in sync"; fixes are made in the template first, then copied here). Runs on the host or
# inside the devcontainer (dev-container.sh mounts the template checkout at /base-multiplayer-game). # KEEP_TEMPLATE_NAME
# Review the diff, then land it via a PR like any other change.
#
#   * Template-owned files (always synced): scripts, devcontainer, run/validate helpers,
#     process + standards docs, .mcp.json, PR template, .gitignore.
#   * Synced only while still template-default: README.md (until its "Status: not yet
#     defined" banner is replaced).
#   * Never overwritten, drift reported for manual merge: CLAUDE.md, .claude/commands/team.md.
#   * Never synced: packages/**, game-owned docs/* (only the template docs listed below are),
#     docs/INIT-GAME.md (one-shot), PORTS.env, .github/project.env, data/.
#   * Removed if present (template-only): new-game.sh, presetup.sh, base-project.md,
#     README.game.md, ha-router/ (TEMPLATE_ONLY_PATHS in scripts/lib/identity.sh).
#
# After copying, the template identity is re-applied exactly as presetup.sh does
# (project/slug/title/MCP name/ports from package.json + PORTS.env), honouring KEEP_TEMPLATE_NAME.
#
# Usage:  ./scripts/sync-from-template.sh [--template <dir>] [--dry-run]
# ---------------------------------------------------------------------------

# Everything lives in main() so bash parses the whole file BEFORE running it: this script
# copies itself from the template, and bash otherwise reads a script lazily while executing.
main() {
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  TEMPLATE="$(cd "$ROOT/.." && pwd)/base-multiplayer-game" # KEEP_TEMPLATE_NAME
  # Inside the devcontainer (or from a worktree) the sibling path does not exist; use the mount.
  [[ -f "$TEMPLATE/presetup.sh" || ! -f /base-multiplayer-game/presetup.sh ]] || TEMPLATE=/base-multiplayer-game # KEEP_TEMPLATE_NAME
  DRY_RUN=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --template) TEMPLATE="$2"; shift 2 ;;
      --dry-run) DRY_RUN=true; shift ;;
      -h | --help) print_help; exit 0 ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done
  [[ -f "$TEMPLATE/presetup.sh" ]] || { echo "error: template not found at $TEMPLATE (use --template, or rebuild the devcontainer so it is mounted)" >&2; exit 1; }
  [[ "$(cd "$TEMPLATE" && pwd)" != "$ROOT" ]] || { echo "error: this IS the template." >&2; exit 1; }

  # The identity-render engine comes from the TEMPLATE (always its newest version).
  # shellcheck disable=SC1091
  source "$TEMPLATE/scripts/lib/identity.sh"

  # ---- identity of this game (what presetup.sh baked in) ----------------------
  PROJECT="$(sed -n 's/^  "name": "\(.*\)",$/\1/p' "$ROOT/package.json" | head -1)"
  SLUG="$(sed -n 's/^SLUG=//p' "$ROOT/PORTS.env")"
  TITLE="$(sed -n 's/^TITLE=//p' "$ROOT/PORTS.env")"
  [[ -n "$TITLE" ]] || TITLE="$(title_case_from_name "$PROJECT")"
  SERVER_PORT="$(sed -n 's/^SERVER_PORT=//p' "$ROOT/PORTS.env")"
  CLIENT_PORT="$(sed -n 's/^CLIENT_PORT=//p' "$ROOT/PORTS.env")"
  [[ -n "$PROJECT" && -n "$SLUG" && -n "$SERVER_PORT" ]] || { echo "error: could not read identity from package.json / PORTS.env" >&2; exit 1; }

  ALWAYS=(
    scripts/project-sync.sh scripts/issue-status.sh scripts/github-setup.sh scripts/sync-from-template.sh
    scripts/lib/identity.sh scripts/agent.sh scripts/land-pr.sh scripts/worktree.sh scripts/resume-in-container.sh scripts/pr-threads.sh
    .claude/.gitignore
    scripts/github/setup_project.py scripts/github/groundwork-issues.json scripts/github/main-ruleset.json
    .github/workflows/pr-links-issue.yml
    .devcontainer/Dockerfile .devcontainer/devcontainer.json .devcontainer/.tmux.conf .devcontainer/post-create.sh
    dev-container.sh run.sh validate.sh ai-pipeline.sh
    .mcp.json .gitignore .prettierrc .prettierignore .github/PULL_REQUEST_TEMPLATE.md
    docs/WORKFLOW.md docs/TEAM.md docs/ENGINEERING.md docs/ASSET-GENERATION.md docs/AUDIO-PIPELINE.md
  )
  # Every team role the template defines (a role added there is synced without editing this list).
  ALWAYS+=(.claude/roles/_common.md) # the shared ground rules; the roles themselves are the agent definitions
  for f in "$TEMPLATE"/.claude/agents/*.md; do ALWAYS+=(".claude/agents/$(basename "$f")"); done
  CONDITIONAL=() # "src|dest|grep-marker-that-must-still-be-present-in-dest"
  CONDITIONAL+=("README.game.md|README.md|Status: not yet defined")
  # Files agents are told to edit in place (CLAUDE.md sections, team roles): never overwritten —
  # drift against the template is reported for a manual merge instead.
  MANUAL=(CLAUDE.md .claude/commands/team.md)

  # ---- render a template file with THIS game's identity (scripts/lib/identity.sh) -------
  render() { # template-file -> rendered temp file (path echoed)
    local out; out="$(mktemp)"; cp "$1" "$out"
    render_identity "$TITLE" "$PROJECT" "$SLUG" "$SERVER_PORT" "$CLIENT_PORT" "$out"
    echo "$out"
  }

  copied=()
  copy_file() { # src-rel dest-rel — copy only when the RENDERED template differs from dest
    local src="$TEMPLATE/$1" dest="$ROOT/$2" rendered
    [[ -f "$src" ]] || return 0
    rendered="$(render "$src")"
    if [[ -f "$dest" ]] && cmp -s "$rendered" "$dest"; then rm -f "$rendered"; return 0; fi
    copied+=("$2")
    if ! $DRY_RUN; then
      mkdir -p "$(dirname "$dest")"
      cp "$rendered" "$dest"
      [[ -x "$src" ]] && chmod +x "$dest"
    fi
    rm -f "$rendered"
  }
  for f in "${ALWAYS[@]}"; do copy_file "$f" "$f"; done
  for entry in "${CONDITIONAL[@]}"; do
    IFS='|' read -r src dest marker <<<"$entry"
    if [[ ! -f "$ROOT/$dest" ]] || grep -q "$marker" "$ROOT/$dest"; then copy_file "$src" "$dest"; fi
  done
  # Template-only files (scripts/lib/identity.sh TEMPLATE_ONLY_PATHS) are removed if they crept in.
  removed=()
  for f in "${TEMPLATE_ONLY_PATHS[@]}"; do
    [[ -e "$ROOT/$f" ]] || continue
    removed+=("$f"); $DRY_RUN || rm -rf "${ROOT:?}/$f"
  done
  drifted=()
  for f in "${MANUAL[@]}"; do
    [[ -f "$TEMPLATE/$f" && -f "$ROOT/$f" ]] || continue
    rendered="$(render "$TEMPLATE/$f")"
    cmp -s "$rendered" "$ROOT/$f" || drifted+=("$f")
    rm -f "$rendered"
  done

  if ((${#removed[@]})); then
    $DRY_RUN && echo "Would remove template-only files:" || echo "Removed template-only files:"
    printf '  %s\n' "${removed[@]}"
  fi
  if ((${#drifted[@]})); then
    echo "Differs from the template but is edited in place by agents — merge manually if the template change matters:"
    printf '  %s\n' "${drifted[@]}"
  fi
  # Re-rendering shortens/lengthens words inside markdown tables; let the game's prettier re-align.
  if ((${#copied[@]})) && ! $DRY_RUN && [[ -x "$ROOT/node_modules/.bin/prettier" ]]; then
    (cd "$ROOT" && node_modules/.bin/prettier --write --ignore-unknown "${copied[@]}" >/dev/null 2>&1 || true)
  fi
  if ((${#copied[@]} + ${#removed[@]} == 0)); then
    echo "Already in sync with $TEMPLATE."
  elif ((${#copied[@]})); then
    $DRY_RUN && echo "Would update (dry run):" || echo "Updated from template ($TITLE / $PROJECT / $SLUG / $SERVER_PORT-$CLIENT_PORT):"
    printf '  %s\n' "${copied[@]}"
    $DRY_RUN || echo "Review with 'git diff', then land via a PR (docs/WORKFLOW.md §5). Rebuild the devcontainer if .devcontainer/* changed."
  fi
}

# exit on the same line: bash must not read further from a file main() may have replaced.
main "$@"; exit $?
