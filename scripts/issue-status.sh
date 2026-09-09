#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# issue-status.sh — move one ticket to a project Status without hand-copying ids.
#
# Usage:  ./scripts/issue-status.sh <issue-number> <Backlog|Ready|"In progress"|"In review"|Blocked|Done>
# Needs:  gh (project scope), jq, .github/project.env (from github-setup.sh)
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../.github/project.env"

ISSUE="${1:?issue number required}"
STATUS="${2:?status name required}"

fields_json="$(gh project field-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json)"
option_id="$(jq -r --arg n "$STATUS" '.fields[] | select(.name=="Status") | .options[] | select(.name==$n) | .id' <<<"$fields_json")"
[[ -n "$option_id" ]] || { echo "error: unknown status '$STATUS'" >&2; exit 1; }

item_id="$(gh project item-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json --limit 1000 \
  | jq -r --arg repo "$REPO" --argjson n "$ISSUE" \
    '.items[] | select(.content.type=="Issue" and .content.repository==$repo and .content.number==$n) | .id')"
if [[ -z "$item_id" ]]; then
  url="$(gh issue view "$ISSUE" -R "$REPO" --json url --jq .url)"
  item_id="$(gh project item-add "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --url "$url" --format json | jq -r .id)"
fi

gh project item-edit --project-id "$PROJECT_ID" --id "$item_id" --field-id "$STATUS_FIELD_ID" --single-select-option-id "$option_id" >/dev/null
echo "#$ISSUE -> $STATUS"
