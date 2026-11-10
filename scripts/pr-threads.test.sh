#!/usr/bin/env bash
# pr-threads.test.sh — exercises `pr-threads.sh reply` against a fake `gh` that keeps a PR's review threads in a
# JSON file, so it runs without GitHub: a batch that lands posts once in one call; a batch GitHub rejects after
# writing part of it (partial posts, #112) is retried without posting or resolving anything twice; a batch that
# wrote nothing is retried in full; a reply that landed without its resolve gets only the resolve; a failing
# retry stops with an error.
#
#   scripts/pr-threads.test.sh        # exit 0 when every case passes
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sandbox="$(mktemp -d)"
trap '[[ -n "${KEEP_SANDBOX:-}" ]] || rm -rf "$sandbox"' EXIT

LOGIN=me
REVIEWER=reviewer
THREAD_COUNT=6
STATE="$sandbox/threads.json"           # {"t1": {"isResolved": false, "comments": [{"author": ..., "body": ...}]}, ...}
CALLS="$sandbox/mutations.log"          # one line per mutation call
WRITES_BEFORE_FAILING="$sandbox/writes" # when set: a multi-thread mutation writes this many fields, then fails
FAIL_SINGLE="$sandbox/fail-single"      # when present: every one-thread mutation fails

# --- the fake gh: repo view, the viewer, the threads query, and the two mutations ----------------------------------
mkdir -p "$sandbox/bin"
cat >"$sandbox/bin/gh" <<GH
#!/usr/bin/env bash
set -euo pipefail
STATE="$STATE" CALLS="$CALLS" WRITES_BEFORE_FAILING="$WRITES_BEFORE_FAILING" FAIL_SINGLE="$FAIL_SINGLE"
[[ "\$1 \$2" == "repo view" ]] && { echo owner/repo; exit 0; }
query="" filter=""
while ((\$#)); do
  case "\$1" in
    -f) [[ "\$2" == query=* ]] && query="\${2#query=}"; shift 2 ;;
    --jq) filter="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
answer() { if [[ -n "\$filter" ]]; then jq -r "\$filter"; else cat; fi; }
if [[ "\$query" == *viewer* ]]; then
  echo '{"data":{"viewer":{"login":"$LOGIN"}}}' | answer
  exit 0
fi
if [[ "\$query" != mutation* ]]; then
  jq '{data: {repository: {pullRequest: {reviewThreads: {totalCount: length, nodes: [to_entries[] | {id: .key,
      isResolved: .value.isResolved, isOutdated: false, path: "a.ts", line: 1, comments: {totalCount: (.value.comments | length),
      nodes: [.value.comments[] | {author: {login: .author}, body, createdAt: "2026-01-01T00:00:00Z"}]}}]}}}}}' "\$STATE" | answer
  exit 0
fi
echo "\$query" >>"\$CALLS"
string='"(?:[^"\\\\]|\\\\.)*"'
mapfile -t fields < <(grep -oP "(addPullRequestReviewThreadReply\\(input:\\{pullRequestReviewThreadId:\$string, body:\$string|resolveReviewThread\\(input:\\{threadId:\$string)" <<<"\$query")
replies=\$( (grep -o addPullRequestReviewThreadReply <<<"\$query" || true) | wc -l)
limit=\${#fields[@]}
if ((replies > 1)) && [[ -s "\$WRITES_BEFORE_FAILING" ]]; then limit=\$(cat "\$WRITES_BEFORE_FAILING"); fi
if ((replies <= 1)) && [[ -e "\$FAIL_SINGLE" ]]; then limit=-1; fi
for ((index = 0; index < limit && index < \${#fields[@]}; index++)); do
  mapfile -t strings < <(grep -oP "\$string" <<<"\${fields[index]}" | jq -r .)
  if [[ "\${fields[index]}" == addPull* ]]; then
    jq --arg thread "\${strings[0]}" --arg body "\${strings[1]}" '.[\$thread].comments += [{author: "$LOGIN", body: \$body}]' \\
      "\$STATE" >"\$STATE.new"
  else
    jq --arg thread "\${strings[0]}" '.[\$thread].isResolved = true' "\$STATE" >"\$STATE.new"
  fi
  mv "\$STATE.new" "\$STATE"
done
if ((limit < \${#fields[@]})); then echo '{"errors":[{"message":"Resource limits for this query exceeded"}]}'; exit 1; fi
echo '{"data":{}}'
GH
chmod +x "$sandbox/bin/gh"

# --- helpers --------------------------------------------------------------------------------------------------------
failures=0
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
pass() { echo "pass  $1"; }

# Fresh threads, each opened by the reviewer, and actions replying to all of them, resolving every other one.
setup() { # <writes before a batch fails, or empty>
  jq -n --argjson count "$THREAD_COUNT" --arg reviewer "$REVIEWER" \
    '[range(1; $count + 1) | {key: "t\(.)", value: {isResolved: false, comments: [{author: $reviewer, body: "finding \(.)"}]}}]
     | from_entries' >"$STATE"
  jq -n --argjson count "$THREAD_COUNT" '[range(1; $count + 1) | {thread: "t\(.)", body: "fixed in round \(.)", resolve: (. % 2 == 0)}]' \
    >"$sandbox/actions.json"
  : >"$CALLS"
  printf '%s' "$1" >"$WRITES_BEFORE_FAILING"
  rm -f "$FAIL_SINGLE"
}

reply() { (cd "$sandbox" && PATH="$sandbox/bin:$PATH" "$repo_root/scripts/pr-threads.sh" reply 1 "$sandbox/actions.json"); }

# Every thread holds exactly one reply from us, its own, and is resolved exactly when its action says so.
each_replied_once() {
  jq -e --slurpfile actions "$sandbox/actions.json" --arg login "$LOGIN" '
    all($actions[0][]; . as $action
      | ([$ARGS.named.state[$action.thread].comments[] | select(.author == $login) | .body] == [$action.body])
        and ($ARGS.named.state[$action.thread].isResolved == $action.resolve))' --argjson state "$(cat "$STATE")" \
    -n >/dev/null
}

# --- cases ----------------------------------------------------------------------------------------------------------
setup ""
if reply >/dev/null && each_replied_once && [[ "$(wc -l <"$CALLS")" -eq 2 ]]; then
  pass "a batch that lands posts each reply once, one call per batch"
else fail "a batch that lands posts each reply once, one call per batch"; fi

setup 3
if reply >/dev/null && each_replied_once; then
  pass "a batch rejected after a partial post is retried without posting or resolving twice"
else fail "a batch rejected after a partial post is retried without posting or resolving twice"; fi

setup 0
if reply >/dev/null && each_replied_once; then
  pass "a batch rejected before writing anything is retried in full"
else fail "a batch rejected before writing anything is retried in full"; fi

# t2's reply and resolve are the batch's fields 2 and 3: stopping after 2 leaves t2 replied but unresolved.
setup 2
before="$(jq '.t2.comments | length' "$STATE")"
if reply >/dev/null && each_replied_once && [[ "$(jq '.t2.comments | length' "$STATE")" -eq $((before + 1)) ]] \
  && grep -q 'resolveReviewThread(input:{threadId:"t2"})' <(tail -n +2 "$CALLS") \
  && ! grep -q 'pullRequestReviewThreadId:"t2"' <(tail -n +2 "$CALLS"); then
  pass "a reply that landed without its resolve gets only the resolve"
else fail "a reply that landed without its resolve gets only the resolve"; fi

setup 0
touch "$FAIL_SINGLE"
if output="$(reply 2>&1)"; then
  fail "a failing retry stops with an error"
elif [[ "$output" == *"error: reply to thread"* ]]; then
  pass "a failing retry stops with an error"
else fail "a failing retry stops with an error (got: $output)"; fi

((failures == 0)) && echo "all cases passed" || { echo "$failures case(s) failed"; exit 1; }
