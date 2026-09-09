#!/usr/bin/env bash
set -euo pipefail
print_help() { awk 'BEGIN{n=0} /^# -{20,}/{n++; next} n==1{sub(/^# ?/,""); print} n==2{exit}' "$0"; }

# ---------------------------------------------------------------------------
# github-setup.sh — put a freshly instantiated game on GitHub, ready for an agent team.
#
# Runs on the HOST (needs the host's gh auth). Idempotent — safe to re-run.
#   1. Create the GitHub repo if it does not exist; git init / commit / push `main`.
#   2. Labels, milestones (M0 Setup, M1 Design), Project + Status stages + views,
#      seeded groundwork epics/tickets as sub-issues  (scripts/github/setup_project.py).
#   3. Ruleset on the default branch: PR required, review threads resolved, no force
#      push, and the `pr-links-issue` check (every PR must close a ticket) required.
#      `validate` / `code-review` checks are added later, once they exist (WORKFLOW.md §5).
#   4. scripts/project-sync.sh to put every issue on the board.
#
# Usage:  ./scripts/github-setup.sh [--repo owner/name] [--private] [--title "Display Title"] [--no-seed]
#   --repo     default: <gh user>/<folder name>
#   --private  create a private repo (default public)
#   --no-seed  labels, project, views and ruleset only — no milestones / groundwork epics
#              (for repos that are not games, e.g. the template itself)
#   --title    project board + issue placeholder title (default: TITLE from PORTS.env, else Title Case of the folder)
# Needs: gh with `repo` + `project` scopes:  gh auth refresh -h github.com -s project,read:project
# ---------------------------------------------------------------------------

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REPO=""
VISIBILITY="--public"
TITLE=""
SEED="--seed"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --private) VISIBILITY="--private"; shift ;;
    --title) TITLE="$2"; shift 2 ;;
    --no-seed) SEED="--no-seed"; shift ;;
    -h | --help) print_help; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

gh auth status >/dev/null 2>&1 || { echo "error: gh is not authenticated." >&2; exit 1; }
if ! gh auth status 2>&1 | grep -q "'project'"; then
  echo "error: gh token lacks the 'project' scope. Run:  gh auth refresh -h github.com -s project,read:project" >&2
  exit 1
fi

GH_USER="$(gh api user --jq .login)"
NAME="$(basename "$ROOT")"
[[ -n "$REPO" ]] || REPO="$GH_USER/$NAME"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/identity.sh"
SLUG="$(sed -n 's/^SLUG=//p' PORTS.env 2>/dev/null || true)"
[[ -n "$SLUG" ]] || SLUG="$NAME"
[[ -n "$TITLE" ]] || TITLE="$(sed -n 's/^TITLE=//p' PORTS.env 2>/dev/null || true)" # what presetup.sh recorded
[[ -n "$TITLE" ]] || TITLE="$(title_case_from_name "$NAME")"

# ---- 1. repo + first push --------------------------------------------------
if ! gh repo view "$REPO" >/dev/null 2>&1; then
  echo "==> Creating GitHub repo $REPO"
  gh repo create "$REPO" "$VISIBILITY" --description "$TITLE — multiplayer game built from base-multiplayer-game" >/dev/null # KEEP_TEMPLATE_NAME
fi
if [[ ! -d .git ]]; then
  git init -q -b main
fi
if ! git remote get-url origin >/dev/null 2>&1; then
  git remote add origin "git@github.com:$REPO.git"
fi
if [[ -z "$(git log --oneline -1 2>/dev/null)" ]]; then
  git add -A
  git commit -q -m "chore: scaffold $NAME from base-multiplayer-game" # KEEP_TEMPLATE_NAME
fi
if ! git ls-remote --exit-code --heads origin main >/dev/null 2>&1; then
  echo "==> Pushing main"
  git push -q -u origin main
fi

# ---- 2. labels, milestones, project, views, seeded issues ------------------
mkdir -p .github
python3 scripts/github/setup_project.py "$REPO" "$TITLE" "$SLUG" scripts/github/groundwork-issues.json .github/project.env "$SEED"

# ---- 3. ruleset on the default branch (upsert, so existing repos pick up rule changes) ----
RULESET_FILE="scripts/github/main-ruleset.json"
RULESET_NAME="$(jq -r .name "$RULESET_FILE")"
ruleset_id="$(gh api "repos/$REPO/rulesets" --jq ".[] | select(.name==\"$RULESET_NAME\") | .id" 2>/dev/null | head -1)"
if [[ -n "$ruleset_id" ]]; then
  echo "==> Updating branch ruleset #$ruleset_id"
  gh api "repos/$REPO/rulesets/$ruleset_id" --method PUT --input "$RULESET_FILE" >/dev/null
else
  echo "==> Applying branch ruleset"
  gh api "repos/$REPO/rulesets" --method POST --input "$RULESET_FILE" >/dev/null
fi

# ---- 4. board sync + land the generated project.env through a PR --------------
./scripts/project-sync.sh
starting_branch="$(git branch --show-current)"
git fetch -q origin main
if ! git cat-file -e origin/main:.github/project.env 2>/dev/null \
   || ! git show origin/main:.github/project.env | cmp -s - .github/project.env; then
  # main is PR-protected, so project.env lands via a PR whenever it is missing from main or its
  # ids changed (e.g. the project was recreated). Generated ids, no reviewer role exists at setup
  # time — merged directly (WORKFLOW.md §6). Idempotent across re-runs.
  branch="chore/project-env"
  generated="$(mktemp)"; cp .github/project.env "$generated"
  git checkout -q main
  git fetch -q origin "$branch" 2>/dev/null || true
  if git show-ref -q --verify "refs/remotes/origin/$branch"; then
    rm -f .github/project.env
    git checkout -q -B "$branch" "origin/$branch"
  else
    git checkout -q -B "$branch"
  fi
  cp "$generated" .github/project.env; rm -f "$generated"
  if [[ -n "$(git status --porcelain .github/project.env)" ]]; then
    git add .github/project.env
    git commit -q -m "chore: record GitHub project ids for project-sync.sh"
  fi
  git push -q -u origin "$branch"
  # (gh pr view <branch> errors on a deprecated projectCards field; pr list --head is reliable)
  if [[ -z "$(gh pr list -R "$REPO" --head "$branch" --json number --jq '.[0].number')" ]]; then
    # Every PR closes a ticket (WORKFLOW.md §5) — including this generated one.
    ticket_title="Record GitHub project ids (.github/project.env)"
    # (`.[0].number // empty` so a missing ticket yields "" rather than the literal string "null")
    ticket="$(gh issue list -R "$REPO" --state all --search "in:title \"$ticket_title\"" --json number --jq '.[0].number // empty')"
    [[ -n "$ticket" ]] || ticket="$(gh issue create -R "$REPO" -t "$ticket_title" -l area:tooling-mcp -l role:devops \
      -b "Generated by scripts/github-setup.sh: commit the project/board ids that scripts/project-sync.sh and scripts/issue-status.sh read." | grep -oE '[0-9]+$')"
    gh pr create -R "$REPO" -B main -H "$branch" -t "chore: record GitHub project ids" \
      -b "Closes #${ticket}. Generated by scripts/github-setup.sh; used by scripts/project-sync.sh and scripts/issue-status.sh." >/dev/null
  fi
  # Auto-merge: GitHub merges once the required pr-links-issue check passes; no polling here.
  gh pr merge "$branch" -R "$REPO" --squash --delete-branch --auto >/dev/null
  git checkout -q main && git pull -q origin main
  [[ "$starting_branch" == "main" || -z "$starting_branch" ]] || git checkout -q "$starting_branch"
fi

cat <<EOF

GitHub ready: https://github.com/$REPO
  Issues    https://github.com/$REPO/issues        (labels, milestones, epics with sub-issues)
  Board     $(sed -n 's/^PROJECT_NUMBER=//p' .github/project.env | xargs -I{} echo "https://github.com/users/$GH_USER/projects/{}")
  Your inbox (waiting on you)  https://github.com/issues/assigned
Rules: WORKFLOW.md — PR required, reviewers run on every PR, all review threads resolved before merge.
EOF
