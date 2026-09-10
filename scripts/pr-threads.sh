#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# pr-threads.sh — review threads on a PR with the fewest possible API calls.
#
#   scripts/pr-threads.sh list <pr>                 one query: every thread, resolved or not, as JSON
#   scripts/pr-threads.sh unresolved <pr>           same, unresolved only
#   scripts/pr-threads.sh reply <pr> <actions.json> one aliased mutation (chunks of 20):
#         [{"thread":"<thread id>","body":"what changed","resolve":false}, ...]
#         reviewers pass "resolve": true after verifying a fix; authors never do.
#
# Why: GitHub's secondary limit is ~80 content-creating requests per minute across everything
# running under one account. Replying to 26 threads one call at a time trips it; one request does not.
# ---------------------------------------------------------------------------
BATCH_SIZE=20
repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
owner="${repo%/*}" name="${repo#*/}"

list_threads() { # <pr> <unresolved-only:true|false>
  gh api graphql -F owner="$owner" -F name="$name" -F pr="$1" -f query='
    query($owner:String!,$name:String!,$pr:Int!){ repository(owner:$owner,name:$name){ pullRequest(number:$pr){
      reviewThreads(first:100){ nodes{ id isResolved isOutdated path line
        comments(first:50){ nodes{ author{ login } body createdAt } } } } } } }' \
    --jq --arg only "$2" '.data.repository.pullRequest.reviewThreads.nodes
      | map(select($only=="false" or (.isResolved|not)))
      | map({id, isResolved, isOutdated, path, line,
             author: .comments.nodes[0].author.login, body: .comments.nodes[0].body,
             replies: (.comments.nodes[1:] | map({author: .author.login, body}))})'
}

reply_threads() { # <pr> <actions.json>
  local total; total="$(jq length "$2")"
  for ((start = 0; start < total; start += BATCH_SIZE)); do
    local mutation
    mutation="$(jq -r --argjson s "$start" --argjson n "$BATCH_SIZE" '
      .[$s:$s+$n] | to_entries | map(
        "r\(.key): addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:\(.value.thread|tojson), body:\(.value.body|tojson)}){ comment { id } }"
        + (if .value.resolve then " s\(.key): resolveReviewThread(input:{threadId:\(.value.thread|tojson)}){ thread { isResolved } }" else "" end)
      ) | "mutation { " + join(" ") + " }"' "$2")"
    gh api graphql -f query="$mutation" >/dev/null
  done
  echo "$total thread(s) replied"
}

case "${1:-}" in
  list) list_threads "${2:?pr}" false ;;
  unresolved) list_threads "${2:?pr}" true ;;
  reply) reply_threads "${2:?pr}" "${3:?actions.json}" ;;
  *) sed -n '3,15p' "${BASH_SOURCE[0]}"; exit 1 ;;
esac
