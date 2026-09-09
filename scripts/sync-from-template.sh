#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# sync-from-template.sh — pull template-owned files from base-multiplayer-game into this game. # KEEP_TEMPLATE_NAME
#
# Keeps a game in step with the template WITHOUT touching game-owned code (WORKFLOW.md "docs
# stay in sync"; fixes are made in the template first, then copied here). Runs on the HOST
# (the template repo is not mounted in the devcontainer). Review the diff, then land it via
# a PR like any other change.
#
#   * Template-owned files (always synced): scripts, devcontainer, run/validate helpers,
#     process + standards docs, ha-router artifacts, .mcp.json, PR template, .gitignore.
#   * Synced only while still template-default: README.md (until its "Status: not yet
#     defined" banner is replaced), CLAUDE.md (until its "START HERE" banner is removed),
#     .claude/commands/team.md (until it differs from the template's previous version).
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
  DRY_RUN=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --template) TEMPLATE="$2"; shift 2 ;;
      --dry-run) DRY_RUN=true; shift ;;
      -h | --help) sed -n '5,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done
  [[ -f "$TEMPLATE/presetup.sh" ]] || { echo "error: template not found at $TEMPLATE (run on the host; use --template)" >&2; exit 1; }
  [[ "$(cd "$TEMPLATE" && pwd)" != "$ROOT" ]] || { echo "error: this IS the template." >&2; exit 1; }

  # ---- identity of this game (what presetup.sh baked in) ----------------------
  PROJECT="$(sed -n 's/^  "name": "\(.*\)",$/\1/p' "$ROOT/package.json" | head -1)"
  SLUG="$(sed -n 's/^SLUG=//p' "$ROOT/PORTS.env")"
  TITLE="$(sed -n 's/^TITLE=//p' "$ROOT/PORTS.env")"
  [[ -n "$TITLE" ]] || TITLE="$(echo "$PROJECT" | sed -E 's/[-_]+/ /g; s/\b(.)/\u\1/g')"
  SERVER_PORT="$(sed -n 's/^SERVER_PORT=//p' "$ROOT/PORTS.env")"
  CLIENT_PORT="$(sed -n 's/^CLIENT_PORT=//p' "$ROOT/PORTS.env")"
  [[ -n "$PROJECT" && -n "$SLUG" && -n "$SERVER_PORT" ]] || { echo "error: could not read identity from package.json / PORTS.env" >&2; exit 1; }

  ALWAYS=(
    scripts/project-sync.sh scripts/issue-status.sh scripts/github-setup.sh scripts/sync-from-template.sh
    scripts/github/setup_project.py scripts/github/groundwork-issues.json
    .devcontainer/Dockerfile .devcontainer/devcontainer.json .devcontainer/.tmux.conf
    dev-container.sh run.sh validate.sh presetup.sh ai-pipeline.sh
    .mcp.json .gitignore .prettierrc .prettierignore .github/PULL_REQUEST_TEMPLATE.md
    WORKFLOW.md ENGINEERING.md ASSET-GENERATION.md AUDIO-PIPELINE.md init-game-prompt.md base-project.md
    ha-router/HA-ROUTER.md ha-router/route.template.yml ha-router/landing-card.html ha-router/insert-landing-card.py
  )
  CONDITIONAL=() # "src|dest|grep-marker-that-must-still-be-present-in-dest"
  CONDITIONAL+=("README.game.md|README.md|Status: not yet defined")
  CONDITIONAL+=("CLAUDE.md|CLAUDE.md|START HERE")

  # ---- render a template file with THIS game's identity (same rules as presetup.sh) -----
  tag="KEEP_TEMPLATE_NAME" # built from a variable so the tag strip cannot eat these lines
  esc() { printf '%s' "$1" | sed 's/[&|\\]/\\&/g'; }
  apply() { # file search replacement [word]
    local file="$1" search="$2" repl; repl="$(esc "$3")"
    if [[ "${4:-}" == word ]]; then sed -i "/${tag}/! s|\\b${search}\\b|${repl}|g" "$file"
    else sed -i "/${tag}/! s|${search}|${repl}|g" "$file"; fi
  }
  render() { # template-file -> rendered temp file (path echoed)
    local out; out="$(mktemp)"; cp "$1" "$out"
    apply "$out" 'Base Multiplayer Game' "$TITLE" # KEEP_TEMPLATE_NAME
    apply "$out" 'base-multiplayer-game' "$PROJECT" # KEEP_TEMPLATE_NAME
    apply "$out" 'game-debug' "${SLUG}-debug" # KEEP_TEMPLATE_NAME
    apply "$out" 'base-mp' "$SLUG" # KEEP_TEMPLATE_NAME
    [[ "$SERVER_PORT" != "4400" ]] && apply "$out" '4400' "$SERVER_PORT" word
    [[ "$CLIENT_PORT" != "4402" ]] && apply "$out" '4402' "$CLIENT_PORT" word
    sed -i -e "s| *<!-- ${tag} -->||" -e "s| *# ${tag}||" "$out"
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
