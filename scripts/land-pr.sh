#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# land-pr.sh — run the review loop for one PR with the agent team, then arm auto-merge.
#
#   scripts/land-pr.sh <pr-number> [--reviewers "architect gameplay-qa ..."] [--rounds N]
#
# Each round: every pending reviewer role reviews (scripts/agent.sh, inside the devcontainer),
# then, if any verdict is REQUEST_CHANGES or any review thread (including Copilot's) is still
# unresolved, an engineer run addresses the threads and the roles that objected re-review.
# code-qa is always a reviewer (docs/TEAM.md) and is the one that re-checks open threads.
# All reviews are posted from the same GitHub account as the author, so verdicts travel in the
# review body ("<role> verdict: APPROVE|REQUEST_CHANGES") instead of GitHub's approve button.
# Merge happens only when every reviewer's latest verdict is APPROVE and no thread is open.
# Bounded: at most --rounds rounds (default 3); exits 1 with the state if the PR is not landable.
# ---------------------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT="$ROOT/scripts/agent.sh"
cd "$ROOT"
ALWAYS_REVIEWER="code-qa"
DEFAULT_REVIEWERS="architect"
DEFAULT_ROUNDS=3
VERDICT_APPROVE="APPROVE"
VERDICT_REQUEST_CHANGES="REQUEST_CHANGES"

pr="${1:?usage: land-pr.sh <pr-number> [--reviewers \"roles\"] [--rounds N]}"; shift
reviewers="$DEFAULT_REVIEWERS" rounds="$DEFAULT_ROUNDS"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reviewers) reviewers="$2"; shift 2 ;;
    --rounds) rounds="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done
grep -qw "$ALWAYS_REVIEWER" <<<"$reviewers" || reviewers="$ALWAYS_REVIEWER $reviewers"

repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
owner="${repo%/*}" name="${repo#*/}"
head_branch="$(gh pr view "$pr" --json headRefName --jq .headRefName)"

pr_state() { "$ROOT/scripts/pr-threads.sh" state "$pr"; }

review_task() { # <role> <round>
  cat <<EOF
Review pull request #$pr (round $2) as the $1 role, following your role's procedure.
The PR branch is checked out in your working directory. Post exactly one review with
\`gh api repos/$repo/pulls/$pr/reviews\` using \`event: COMMENT\`, whose body starts with the line
\`$1 verdict: $VERDICT_APPROVE\` or \`$1 verdict: $VERDICT_REQUEST_CHANGES\`, followed by your
findings; put line-anchored findings in \`comments\`. In a re-review, first
\`scripts/pr-threads.sh unresolved $pr\` (yours and Copilot's), verify each, then ONE
\`scripts/pr-threads.sh reply $pr <file>\` call resolving the fixed ones and replying on the rest,
and only then post your verdict.
EOF
}

fix_task() {
  cat <<EOF
Address every unresolved review thread on pull request #$pr: run
\`scripts/pr-threads.sh unresolved $pr\` ONCE (includes Copilot's), fix the code or decide why not,
then reply to all threads in ONE \`scripts/pr-threads.sh reply $pr <file>\` call (resolve: false),
keep \`./validate.sh all\` green, bring the branch up to date with \`git merge origin/main\` (never
rebase on a review round: rewriting history marks every thread outdated), and push. Do not resolve
threads and do not merge.
EOF
}

run_role() { # <role> <task> — one agent run; a failed run is reported, not fatal (the state check decides)
  local role="$1" task="$2"
  "$AGENT" "$role" --pr "$pr" --branch "$head_branch" "$task" || echo "!! $role run failed (exit $?)" >&2
}

pending="$reviewers"
for ((round = 1; round <= rounds; round++)); do
  echo "== PR #$pr round $round: reviewers [$pending]"
  for role in $pending; do run_role "$role" "$(review_task "$role" "$round")"; done
  state="$(pr_state)"
  unresolved="$(jq -r .unresolved <<<"$state")"
  objecting="$(jq -r --arg v "$VERDICT_REQUEST_CHANGES" '.verdicts | to_entries[] | select(.value==$v) | .key' <<<"$state" | tr '\n' ' ')"
  missing=""
  for role in $reviewers; do
    jq -e --arg r "$role" --arg v "$VERDICT_APPROVE" '.verdicts[$r]==$v' <<<"$state" >/dev/null || missing+="$role "
  done
  echo "   verdicts: $(jq -c .verdicts <<<"$state"); unresolved threads: $unresolved"
  if [[ -z "$missing" && "$unresolved" == "0" ]]; then
    gh pr merge "$pr" --squash --auto --delete-branch >/dev/null
    "$AGENT" worktree-remove "$head_branch" >/dev/null
    echo "== PR #$pr approved by [$reviewers]; auto-merge armed."
    exit 0
  fi
  ((round < rounds)) || break
  run_role engineer "$(fix_task)"
  # Re-review: whoever objected or has not approved yet, plus the always-reviewer while any
  # thread is open (someone has to verify and resolve the fixed ones).
  recheck=""; [[ "$unresolved" == "0" ]] || recheck="$ALWAYS_REVIEWER"
  pending="$(printf '%s\n' $missing $objecting $recheck | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
done
echo "== PR #$pr not landable after $rounds rounds: $(jq -c . <<<"$state")" >&2
exit 1
