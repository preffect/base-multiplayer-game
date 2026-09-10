#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# pr-threads.sh — review threads on a PR with the fewest possible API calls.
#
#   scripts/pr-threads.sh state <pr>                one query: latest verdict per reviewer role + unresolved count
#   scripts/pr-threads.sh list <pr>                 one query: every thread, resolved or not, as JSON
#   scripts/pr-threads.sh unresolved <pr>           same, unresolved only
#   scripts/pr-threads.sh reply <pr> <actions.json> one aliased mutation (chunks of 20):
#         [{"thread":"<thread id>","body":"what changed","resolve":false}, ...]
#         reviewers pass "resolve": true after verifying a fix; authors never do.
#
# Why: GitHub's secondary limit is ~80 content-creating requests per minute across everything
# running under one account. Replying to 26 threads one call at a time trips it; one request does not.
# ---------------------------------------------------------------------------
BATCH_SIZE=8 # GitHub's GraphQL resource limit rejects larger batches of long reply bodies (partial posts)
repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
owner="${repo%/*}" name="${repo#*/}"

THREADS_PAGE_SIZE=100
COMMENTS_PAGE_SIZE=50
list_threads() { # <pr> <unresolved-only:true|false>
  gh api graphql -F owner="$owner" -F name="$name" -F pr="$1" \
    -F threadsPage="$THREADS_PAGE_SIZE" -F commentsPage="$COMMENTS_PAGE_SIZE" -f query='
    query($owner:String!,$name:String!,$pr:Int!,$threadsPage:Int!,$commentsPage:Int!){
      repository(owner:$owner,name:$name){ pullRequest(number:$pr){
      reviewThreads(first:$threadsPage){ totalCount nodes{ id isResolved isOutdated path line
        comments(first:$commentsPage){ totalCount nodes{ author{ login } body createdAt } } } } } } }' \
    | jq --arg only "$2" --argjson threadsPage "$THREADS_PAGE_SIZE" --argjson commentsPage "$COMMENTS_PAGE_SIZE" '
      .data.repository.pullRequest.reviewThreads
      | if .totalCount > $threadsPage then error("PR exceeds one page of review threads; raise THREADS_PAGE_SIZE") else . end
      | .nodes
      | if any(.[]; .comments.totalCount > $commentsPage) then error("a thread exceeds one page of comments; raise COMMENTS_PAGE_SIZE") else . end
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

# Latest verdict per reviewer role (first line of each review body: "<role> verdict: APPROVE|REQUEST_CHANGES")
# and the number of unresolved threads — the whole merge decision in one 1-point query. Reviews are
# read newest-last, so only the threads page has to be complete.
REVIEWS_PAGE_SIZE=50
pr_state() { # <pr>
  gh api graphql -F owner="$owner" -F name="$name" -F pr="$1" \
    -F reviewsPage="$REVIEWS_PAGE_SIZE" -F threadsPage="$THREADS_PAGE_SIZE" -f query='
    query($owner:String!,$name:String!,$pr:Int!,$reviewsPage:Int!,$threadsPage:Int!){
      repository(owner:$owner,name:$name){ pullRequest(number:$pr){
        reviews(last:$reviewsPage){ totalCount nodes{ body } }
        reviewThreads(first:$threadsPage){ totalCount nodes{ isResolved } } } } }' \
    | jq --argjson reviewsPage "$REVIEWS_PAGE_SIZE" --argjson threadsPage "$THREADS_PAGE_SIZE" '
      .data.repository.pullRequest
      | if .reviewThreads.totalCount > $threadsPage
        then error("PR exceeds one page of review threads; raise THREADS_PAGE_SIZE") else . end
      | {verdicts: ([.reviews.nodes[].body // "" | capture("^(?<key>[a-z-]+) verdict: (?<value>[A-Z_]+)")?] | from_entries),
         unresolved: ([.reviewThreads.nodes[] | select(.isResolved | not)] | length)}'
}

case "${1:-}" in
  state) pr_state "${2:?pr}" ;;
  list) list_threads "${2:?pr}" false ;;
  unresolved) list_threads "${2:?pr}" true ;;
  reply) reply_threads "${2:?pr}" "${3:?actions.json}" ;;
  *) sed -n '3,15p' "${BASH_SOURCE[0]}"; exit 1 ;;
esac
