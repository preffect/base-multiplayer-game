#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# project-sync.sh — reconcile this repo's GitHub issues with its project board.
#
# Replaces the Project UI "workflows" (auto-add, auto-close) so nobody has to click
# anything in the browser (see docs/WORKFLOW.md §4). Idempotent; safe to run any time.
#
#   1. Every open or closed issue in the repo is on the project (new items get
#      Backlog / Blocked / Done according to rules 2-3 as they are added).
#   2. Closed issues -> Status "Done".
#   3. Open issues with label "pending" -> Status "Blocked" (waiting on a human).
#   4. Open issues that are "Blocked" but no longer carry "pending" -> "Backlog".
#   Existing items in any other status (Ready, In progress, In review) are never touched.
#
# Usage:  ./scripts/project-sync.sh [--dry-run]
# Needs:  gh (repo + project scopes), jq, and .github/project.env from github-setup.sh
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ENV="$SCRIPT_DIR/../.github/project.env"
[[ -f "$PROJECT_ENV" ]] || { echo "error: $PROJECT_ENV missing — run scripts/github-setup.sh first." >&2; exit 1; }
# shellcheck disable=SC1090
source "$PROJECT_ENV" # REPO, PROJECT_OWNER, PROJECT_NUMBER, PROJECT_ID, STATUS_FIELD_ID

PENDING_LABEL="pending"
ITEM_LIMIT=1000
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# GraphQL is budgeted in points (5,000/hour), and `gh project item-list` fetches every field of
# every item (hundreds of points per call). This query asks only for what the rules need: the
# Status options, and per item its id, issue number/repository and current Status (~4 points).
PAGE_SIZE=100
fetch_page() { # <cursor-or-empty> -> JSON  (an empty cursor is sent as GraphQL null, not the string "null")
  local variables
  variables="$(jq -cn --arg id "$PROJECT_ID" --argjson first "$PAGE_SIZE" --arg after "${1:-}" \
    '{id:$id, first:$first, after:(if $after=="" then null else $after end)}')"
  jq -cn --argjson v "$variables" --arg q '
    query($id:ID!,$first:Int!,$after:String){ node(id:$id){ ... on ProjectV2 {
      field(name:"Status"){ ... on ProjectV2SingleSelectField { options { id name } } }
      items(first:$first, after:$after){ totalCount pageInfo{ hasNextPage endCursor } nodes{ id
        status: fieldValueByName(name:"Status"){ ... on ProjectV2ItemFieldSingleSelectValue { name } }
        content{ ... on Issue { number repository{ nameWithOwner } } } } } } } }' \
    '{query:$q, variables:$v}' | gh api graphql --input -
}
first_page="$(fetch_page)"
option_id() { jq -r --arg n "$1" '.data.node.field.options[] | select(.name==$n) | .id' <<<"$first_page"; }
OPT_DONE="$(option_id Done)"
OPT_BLOCKED="$(option_id Blocked)"
OPT_BACKLOG="$(option_id Backlog)"
item_count="$(jq '.data.node.items.totalCount' <<<"$first_page")"
if ((item_count >= ITEM_LIMIT)); then
  echo "error: project has >= $ITEM_LIMIT items; raise ITEM_LIMIT before running." >&2
  exit 1
fi

# number->item-id and number->status maps for THIS repo's issues only (the project is
# owner-level and may hold items from other repositories), paging until the end.
declare -A item_id_by_number status_by_number
page="$first_page"
while :; do
  while IFS=$'\t' read -r number item_id status; do
    item_id_by_number["$number"]="$item_id"
    status_by_number["$number"]="$status"
  done < <(jq -r --arg repo "$REPO" \
    '.data.node.items.nodes[] | select(.content.repository.nameWithOwner==$repo)
     | [.content.number, .id, (.status.name // "")] | @tsv' <<<"$page")
  jq -e '.data.node.items.pageInfo.hasNextPage' <<<"$page" >/dev/null || break
  page="$(fetch_page "$(jq -r '.data.node.items.pageInfo.endCursor' <<<"$page")")"
done
issues_json="$(gh issue list -R "$REPO" --state all --limit "$ITEM_LIMIT" --json number,id,state,labels)"

# Status changes are queued and sent as ONE GraphQL request per batch (aliased mutations):
# GitHub's secondary rate limit counts requests, and a board of 50 tickets used to be 50 calls.
BATCH_SIZE=20
queued_items=() queued_options=()
set_status() { # item-id option-id  (queued; flushed by flush_status)
  queued_items+=("$1"); queued_options+=("$2")
}
flush_status() {
  $DRY_RUN && return 0
  local start n count
  for ((start = 0; start < ${#queued_items[@]}; start += BATCH_SIZE)); do
    count=$(( ${#queued_items[@]} - start )); ((count > BATCH_SIZE)) && count=$BATCH_SIZE
    local query="mutation {"
    for ((n = 0; n < count; n++)); do
      query+=" m${n}: updateProjectV2ItemFieldValue(input:{projectId:\"${PROJECT_ID}\", itemId:\"${queued_items[start + n]}\", fieldId:\"${STATUS_FIELD_ID}\", value:{singleSelectOptionId:\"${queued_options[start + n]}\"}}) { projectV2Item { id } }"
    done
    query+=" }"
    graphql_with_retry "$query" >/dev/null || return 1
    sleep 1
  done
}

# Retry a throttled request a few times so a transient limit cannot leave the board half-updated.
MAX_ATTEMPTS=3
RETRY_SECONDS=60
graphql_with_retry() { # <query> -> response JSON
  local attempt output
  for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    if output="$(jq -cn --arg q "$1" '{query:$q}' | gh api graphql --input - 2>&1)"; then echo "$output"; return 0; fi
    if [[ "$output" == *"rate limit"* || "$output" == *"secondary"* ]] && ((attempt < MAX_ATTEMPTS)); then sleep "$RETRY_SECONDS"; continue; fi
    echo "error: board update failed: ${output:0:200}" >&2; return 1
  done
}

# Issues missing from the board are added in ONE aliased mutation per batch; their item ids
# then feed the status queue like everyone else's.
add_items() { # <number=content-id ...> -> sets item_id_by_number
  local start count n query response
  local pairs=("$@")
  for ((start = 0; start < ${#pairs[@]}; start += BATCH_SIZE)); do
    count=$(( ${#pairs[@]} - start )); ((count > BATCH_SIZE)) && count=$BATCH_SIZE
    query="mutation {"
    for ((n = 0; n < count; n++)); do
      query+=" a${pairs[start + n]%%=*}: addProjectV2ItemById(input:{projectId:\"${PROJECT_ID}\", contentId:\"${pairs[start + n]#*=}\"}) { item { id } }"
    done
    query+=" }"
    response="$(graphql_with_retry "$query")" || return 1
    for ((n = 0; n < count; n++)); do
      local number="${pairs[start + n]%%=*}"
      item_id_by_number["$number"]="$(jq -r ".data.a$number.item.id" <<<"$response")"
    done
    sleep 1
  done
}

issue_rows="$(jq -r --arg p "$PENDING_LABEL" '.[] | [.number, .id, .state, (any(.labels[]; .name==$p))] | @tsv' <<<"$issues_json")"

# Pass 1: add every issue that is not on the board yet (one request per batch).
missing=()
while IFS=$'\t' read -r number content_id state has_pending; do
  [[ -n "${item_id_by_number[$number]:-}" ]] || missing+=("$number=$content_id")
done <<<"$issue_rows"
added=${#missing[@]}
if ((added)) && ! $DRY_RUN; then add_items "${missing[@]}"; fi

# Pass 2: queue the status rules.
done=0 blocked=0 unblocked=0
while IFS=$'\t' read -r number content_id state has_pending; do
  item_id="${item_id_by_number[$number]:-}"
  current="${status_by_number[$number]:-}"
  if [[ -z "$current" && -z "${status_by_number[$number]+x}" ]]; then # newly added this run
    if [[ "$state" == "CLOSED" ]]; then set_status "$item_id" "$OPT_DONE"
    elif [[ "$has_pending" == "true" ]]; then set_status "$item_id" "$OPT_BLOCKED"
    else set_status "$item_id" "$OPT_BACKLOG"
    fi
    continue
  fi
  if [[ "$state" == "CLOSED" && "$current" != "Done" ]]; then
    set_status "$item_id" "$OPT_DONE"; done=$((done + 1))
  elif [[ "$state" == "OPEN" && "$has_pending" == "true" && "$current" != "Blocked" ]]; then
    set_status "$item_id" "$OPT_BLOCKED"; blocked=$((blocked + 1))
  elif [[ "$state" == "OPEN" && "$has_pending" == "false" && "$current" == "Blocked" ]]; then
    set_status "$item_id" "$OPT_BACKLOG"; unblocked=$((unblocked + 1))
  fi
done <<<"$issue_rows"
flush_status

$DRY_RUN && echo "(dry run — nothing changed)"
printf '%-32s %s\n' "added to project:" "$added" "closed -> Done:" "$done" \
  "pending -> Blocked:" "$blocked" "un-pended -> Backlog:" "$unblocked"
