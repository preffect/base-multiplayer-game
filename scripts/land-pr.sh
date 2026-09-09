#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# land-pr.sh — run the review loop for one PR with the agent team, then arm auto-merge.
#
#   scripts/land-pr.sh <pr-number> [--reviewers "code-qa architect ..."] [--rounds N]
#
# Each round: every pending reviewer role reviews (scripts/agent.sh, inside the devcontainer),
# then, if any verdict is REQUEST_CHANGES or any review thread (including Copilot's) is still
# unresolved, an engineer run addresses the threads and the roles that objected re-review.
# All reviews are posted from the same GitHub account as the author, so verdicts travel in the
# review body ("<role> verdict: APPROVE|REQUEST_CHANGES") instead of GitHub's approve button.
# Merge happens only when every reviewer's latest verdict is APPROVE and no thread is open.
# Bounded: at most --rounds rounds (default 3); exits 1 with the state if the PR is not landable.
# ---------------------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT="$ROOT/scripts/agent.sh"
cd "$ROOT"
DEFAULT_REVIEWERS="code-qa architect"
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

repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
owner="${repo%/*}" name="${repo#*/}"
head_branch="$(gh pr view "$pr" --json headRefName --jq .headRefName)"

# Latest verdict per role (from review bodies) and the count of unresolved threads, one call.
pr_state() {
  gh api graphql -F owner="$owner" -F name="$name" -F pr="$pr" -f query='
    query($owner:String!,$name:String!,$pr:Int!){ repository(owner:$owner,name:$name){ pullRequest(number:$pr){
      reviews(last:50){ nodes{ body } }
      reviewThreads(first:100){ nodes{ isResolved } } } } }' \
    --jq '.data.repository.pullRequest
      | {verdicts: ([.reviews.nodes[].body | capture("^(?<key>[a-z-]+) verdict: (?<value>[A-Z_]+)")?] | from_entries),
         unresolved: ([.reviewThreads.nodes[] | select(.isResolved | not)] | length)}'
}

review_task() { # <role> <round>
  cat <<EOF
Review pull request #$pr (round $2) as the $1 role, following your role's procedure.
The PR branch is checked out in your working directory. Post exactly one review with
\`gh api repos/$repo/pulls/$pr/reviews\` using \`event: COMMENT\`, whose body starts with the line
\`$1 verdict: $VERDICT_APPROVE\` or \`$1 verdict: $VERDICT_REQUEST_CHANGES\`, followed by your
findings; put line-anchored findings in \`comments\`. In a re-review, first check every unresolved
thread (yours and Copilot's): resolve the ones that are fixed (GraphQL resolveReviewThread), reply on
the ones that are not, and only then post your verdict.
EOF
}

fix_task() {
  cat <<EOF
Address every unresolved review thread on pull request #$pr (list them with
\`gh api graphql\` on pullRequest.reviewThreads, including Copilot's). Fix the code or explain
in a reply why not, reply on each thread with what changed, keep \`./validate.sh all\` green,
rebase on origin/main, and push. Do not resolve threads yourself and do not merge.
EOF
}

pending="$reviewers"
for ((round = 1; round <= rounds; round++)); do
  echo "== PR #$pr round $round: reviewers [$pending]"
  for role in $pending; do
    "$AGENT" "$role" --pr "$pr" --branch "$head_branch" "$(review_task "$role" "$round")"
  done
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
    [[ -d "$ROOT/.worktrees/$head_branch" ]] && "$AGENT" worktree-remove "$head_branch" >/dev/null
    echo "== PR #$pr approved by [$reviewers]; auto-merge armed."
    exit 0
  fi
  ((round < rounds)) || break
  "$AGENT" engineer --pr "$pr" --branch "$head_branch" "$(fix_task)"
  # Re-review: whoever objected or has not approved yet; code-qa always re-checks the threads.
  pending="$(printf '%s\n' $missing $objecting code-qa | awk '!seen[$0]++' | tr '\n' ' ')"
done
echo "== PR #$pr not landable after $rounds rounds: $(jq -c . <<<"$state")" >&2
exit 1
