#!/usr/bin/env bash
set -euo pipefail
print_help() { awk 'BEGIN{n=0} /^# -{20,}/{n++; next} n==1{sub(/^# ?/,""); print} n==2{exit}' "$0"; }

# ---------------------------------------------------------------------------
# sync-from-template.sh — pull template-owned files from base-multiplayer-game into this game. # KEEP_TEMPLATE_NAME
#
# Keeps a game in step with the template WITHOUT touching game-owned code (WORKFLOW.md "docs
# stay in sync"; fixes are made in the template first, then copied here). Runs on the host or
# inside the devcontainer (dev-container.sh mounts the template checkout at /base-multiplayer-game). # KEEP_TEMPLATE_NAME
# Review the diff, then land it via a PR like any other change.
#
#   * Template-owned files (always synced): scripts, devcontainer, run/validate helpers,
#     process + standards docs, ha-router artifacts, .mcp.json, PR template, .gitignore.
#   * Synced only while still template-default: README.md (until its "Status: not yet
#     defined" banner is replaced).
#   * Never overwritten, drift reported for manual merge: CLAUDE.md, .claude/commands/team.md.
#   * Never synced: packages/**, init-game.md, PORTS.env, .github/project.env, data/, docs/.
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
  [[ -f "$TEMPLATE/presetup.sh" || ! -f /base-multiplayer-game/presetup.sh ]] || TEMPLATE=/base-multiplayer-game # mounted by dev-container.sh # KEEP_TEMPLATE_NAME
  DRY_RUN=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --template) TEMPLATE="$2"; shift 2 ;;
      --dry-run) DRY_RUN=true; shift ;;
      -h | --help) print_help; exit 0 ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done
  [[ -f "$TEMPLATE/presetup.sh" ]] || { echo "error: template not found at $TEMPLATE (use --template)" >&2; exit 1; }
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
    scripts/lib/identity.sh scripts/agent.sh scripts/land-pr.sh scripts/resume-in-container.sh
    .claude/roles/_common.md .claude/roles/architect.md .claude/roles/engineer.md .claude/roles/game-designer.md
    .claude/roles/graphics-designer.md .claude/roles/ui-designer.md .claude/roles/audio-designer.md
    .claude/roles/perf-engineer.md .claude/roles/devops.md .claude/roles/code-qa.md .claude/roles/gameplay-qa.md
    .claude/roles/graphics-qa.md .claude/.gitignore
    scripts/github/setup_project.py scripts/github/groundwork-issues.json
    .devcontainer/Dockerfile .devcontainer/devcontainer.json .devcontainer/.tmux.conf .devcontainer/post-create.sh
    dev-container.sh run.sh validate.sh presetup.sh ai-pipeline.sh
    .mcp.json .gitignore .prettierrc .prettierignore .github/PULL_REQUEST_TEMPLATE.md
    WORKFLOW.md TEAM.md ENGINEERING.md ASSET-GENERATION.md AUDIO-PIPELINE.md init-game-prompt.md base-project.md
    ha-router/HA-ROUTER.md ha-router/route.template.yml ha-router/landing-card.html ha-router/insert-landing-card.py
  )
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
  drifted=()
  for f in "${MANUAL[@]}"; do
    [[ -f "$TEMPLATE/$f" && -f "$ROOT/$f" ]] || continue
    rendered="$(render "$TEMPLATE/$f")"
    cmp -s "$rendered" "$ROOT/$f" || drifted+=("$f")
    rm -f "$rendered"
  done

  if ((${#drifted[@]})); then
    echo "Differs from the template but is edited in place by agents — merge manually if the template change matters:"
    printf '  %s\n' "${drifted[@]}"
  fi
  if ((${#copied[@]} == 0)); then
    echo "Already in sync with $TEMPLATE."
  else
    $DRY_RUN && echo "Would update (dry run):" || echo "Updated from template ($TITLE / $PROJECT / $SLUG / $SERVER_PORT-$CLIENT_PORT):"
    printf '  %s\n' "${copied[@]}"
    $DRY_RUN || echo "Review with 'git diff', then land via a PR (WORKFLOW.md §5). Rebuild the devcontainer if .devcontainer/* changed."
  fi
}

# exit on the same line: bash must not read further from a file main() may have replaced.
main "$@"; exit $?
