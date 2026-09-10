#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# issue-status.sh — move one or more tickets to a project Status in TWO API calls total.
#
#   scripts/issue-status.sh <Status> <issue> [issue...]     e.g. issue-status.sh "In review" 21 22 23
#   scripts/issue-status.sh <issue> <Status>                (single-ticket form, kept for habit)
#
# One GraphQL query finds the project item of every issue (adding missing ones), one aliased
# mutation sets all their Status values. Never lists the whole project.
# Needs .github/project.env from scripts/github-setup.sh.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ENV="$SCRIPT_DIR/../.github/project.env"
[[ -f "$PROJECT_ENV" ]] || { echo "error: $PROJECT_ENV missing — run scripts/github-setup.sh first." >&2; exit 1; }
# shellcheck disable=SC1090
source "$PROJECT_ENV" # REPO, PROJECT_OWNER, PROJECT_NUMBER, PROJECT_ID, STATUS_FIELD_ID
OWNER="${REPO%/*}" NAME="${REPO#*/}"

if [[ "${1:-}" =~ ^[0-9]+$ ]]; then status="${2:?status name required}"; issues=("$1")
else status="${1:?status name required}"; shift; issues=("$@"); fi
[[ ${#issues[@]} -gt 0 ]] || { echo "usage: issue-status.sh <Status> <issue> [issue...]" >&2; exit 1; }

PROJECT_ITEMS_PAGE_SIZE=20 # an issue is on a handful of projects at most
issue_fields=""
for n in "${issues[@]}"; do
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "error: '$n' is not an issue number" >&2; exit 1; }
  issue_fields+="i$n: issue(number:$n){ id projectItems(first:$PROJECT_ITEMS_PAGE_SIZE){ nodes{ id project{ id } } } } "
done
state="$(gh api graphql -f query="query { node(id:\"$PROJECT_ID\"){ ... on ProjectV2 { field(name:\"Status\"){ ... on ProjectV2SingleSelectField { options { id name } } } } }
  repository(owner:\"$OWNER\", name:\"$NAME\"){ $issue_fields } }")"
for n in "${issues[@]}"; do
  jq -e ".data.repository.i$n.id" <<<"$state" >/dev/null 2>&1 || { echo "error: issue #$n not found in $REPO" >&2; exit 1; }
done
option_id="$(jq -r --arg s "$status" '.data.node.field.options[] | select(.name==$s) | .id' <<<"$state")"
[[ -n "$option_id" ]] || { echo "error: unknown status '$status'" >&2; exit 1; }

# Issues not yet on the project are added in one aliased mutation, then everything is set.
add_fields="" item_ids=()
for n in "${issues[@]}"; do
  item="$(jq -r --arg p "$PROJECT_ID" ".data.repository.i$n.projectItems.nodes[] | select(.project.id==\$p) | .id" <<<"$state" | head -1)"
  if [[ -z "$item" ]]; then
    content="$(jq -r ".data.repository.i$n.id" <<<"$state")"
    add_fields+="a$n: addProjectV2ItemById(input:{projectId:\"$PROJECT_ID\", contentId:\"$content\"}){ item { id } } "
  else item_ids+=("$n=$item"); fi
done
if [[ -n "$add_fields" ]]; then
  added="$(gh api graphql -f query="mutation { $add_fields }")"
  for n in "${issues[@]}"; do
    id="$(jq -r ".data.a$n.item.id // empty" <<<"$added")"; [[ -z "$id" ]] || item_ids+=("$n=$id")
  done
fi
set_fields=""
for pair in "${item_ids[@]}"; do
  set_fields+="s${pair%%=*}: updateProjectV2ItemFieldValue(input:{projectId:\"$PROJECT_ID\", itemId:\"${pair#*=}\", fieldId:\"$STATUS_FIELD_ID\", value:{singleSelectOptionId:\"$option_id\"}}){ projectV2Item { id } } "
done
gh api graphql -f query="mutation { $set_fields }" >/dev/null
echo "#${issues[*]} -> $status"
