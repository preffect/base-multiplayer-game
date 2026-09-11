#!/usr/bin/env bash
# validate-cache.test.sh — exercises validate.sh's result cache (docs/ENGINEERING.md §1) against a
# throwaway git repo with a fake `pnpm` on PATH, so it runs without node_modules:
#   second run is cached; an untracked file change invalidates; --fresh re-runs; red is never
#   cached; `all` stamps its phases and itself; filters apply to the stored log; a worktree at the
#   same content shares the stamp.
#
#   scripts/validate-cache.test.sh        # exit 0 when every case passes
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

CACHED_HIT_SECONDS_MAX=2
FAKE_PNPM_RC_FILE="$sandbox/fake-pnpm-rc"

# --- fixture: a git repo holding validate.sh, a stub docs-index.sh, and a fake pnpm ------------
fixture="$sandbox/repo"
mkdir -p "$fixture/scripts" "$sandbox/bin" "$sandbox/home"
cp "$repo_root/validate.sh" "$fixture/validate.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/scripts/docs-index.sh"
cat > "$sandbox/bin/pnpm" <<PNPM
#!/usr/bin/env bash
echo "fake pnpm \$*"
exit "\$(cat "$FAKE_PNPM_RC_FILE")"
PNPM
chmod +x "$fixture/scripts/docs-index.sh" "$sandbox/bin/pnpm"
echo 0 > "$FAKE_PNPM_RC_FILE"
git -C "$fixture" init -q
git -C "$fixture" -c user.name=test -c user.email=test@example.com add -A
git -C "$fixture" -c user.name=test -c user.email=test@example.com commit -q -m fixture

export PATH="$sandbox/bin:$PATH" HOME="$sandbox/home"
unset VALIDATE_CACHE_DIR

# --- helpers ------------------------------------------------------------------------------------
failures=0
check() { # <description> <arithmetic-truth: 1 passes, 0 fails>
  if [[ "$2" -ne 0 ]]; then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi
}
run_validate() { # <dir> <args...>  -> stdout in $out, exit code in $rc
  rc=0
  out="$(cd "$1" && shift && ./validate.sh "$@" 2>&1)" || rc=$?
}
is_cached() { grep -q '^cached green from .* at tree [0-9a-f]\{40\}$' <<<"$out"; }
ran_pnpm() { grep -q '^fake pnpm' <<<"$out"; }

# --- cases --------------------------------------------------------------------------------------
run_validate "$fixture" test
check "first run executes and is green" $(( rc == 0 && $(ran_pnpm; echo $?) == 0 ))

start=$SECONDS
run_validate "$fixture" test
elapsed=$((SECONDS - start))
check "second run on the same tree is a cache hit" $(( rc == 0 && $(is_cached; echo $?) == 0 && $(ran_pnpm; echo $?) != 0 ))
check "cache hit returns in under ${CACHED_HIT_SECONDS_MAX}s (took ${elapsed}s)" $(( elapsed < CACHED_HIT_SECONDS_MAX ))
check "cache hit prints the stored log path" $(( $(grep -q '^log: .*\.test\.log$' <<<"$out"; echo $?) == 0 ))

run_validate "$fixture" test -G 'fake pnpm'
check "filters apply to the stored log on a hit" $(( $(is_cached; echo $?) == 0 && $(ran_pnpm; echo $?) == 0 ))

echo scratch > "$fixture/untracked.txt"
run_validate "$fixture" test
check "an untracked file change invalidates the stamp" $(( rc == 0 && $(is_cached; echo $?) != 0 && $(ran_pnpm; echo $?) == 0 ))

run_validate "$fixture" test
check "the changed tree is stamped in turn" $(( $(is_cached; echo $?) == 0 ))

run_validate "$fixture" test --fresh
check "--fresh bypasses the stamp and re-runs" $(( rc == 0 && $(is_cached; echo $?) != 0 && $(ran_pnpm; echo $?) == 0 ))

echo 1 > "$FAKE_PNPM_RC_FILE"
echo red > "$fixture/untracked.txt"
run_validate "$fixture" test
check "a red run exits non-zero" $(( rc != 0 ))
echo 0 > "$FAKE_PNPM_RC_FILE"
run_validate "$fixture" test
check "red is never cached: the next call on the same tree runs again" $(( rc == 0 && $(is_cached; echo $?) != 0 && $(ran_pnpm; echo $?) == 0 ))

run_validate "$fixture" typecheck -- --filter shared
check "extra args after -- bypass the cache" $(( rc == 0 && $(ran_pnpm; echo $?) == 0 ))
run_validate "$fixture" typecheck -- --filter shared
check "extra args are never stamped" $(( $(is_cached; echo $?) != 0 ))

echo all > "$fixture/untracked.txt"
run_validate "$fixture" all
check "all runs every phase green" $(( rc == 0 && $(grep -q '^ALL PASSED$' <<<"$out"; echo $?) == 0 ))
run_validate "$fixture" lint
check "all stamps each phase individually" $(( $(is_cached; echo $?) == 0 ))
run_validate "$fixture" all
check "all stamps itself" $(( rc == 0 && $(is_cached; echo $?) == 0 && $(ran_pnpm; echo $?) != 0 ))

echo 1 > "$FAKE_PNPM_RC_FILE"
echo all-red > "$fixture/untracked.txt"
run_validate "$fixture" all
check "a red all reports the failed phases" $(( rc != 0 && $(grep -q '^FAILED: ' <<<"$out"; echo $?) == 0 ))
echo 0 > "$FAKE_PNPM_RC_FILE"
run_validate "$fixture" all
check "a red all is not stamped" $(( rc == 0 && $(ran_pnpm; echo $?) == 0 ))

rm "$fixture/untracked.txt"
git -C "$fixture" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m same-tree
worktree="$sandbox/worktree"
git -C "$fixture" worktree add -q "$worktree" -b other HEAD
run_validate "$fixture" test
run_validate "$worktree" test
check "a worktree at the same content shares the stamp" $(( rc == 0 && $(is_cached; echo $?) == 0 ))

stamp_count="$(find "$HOME/.cache" -maxdepth 2 -name '*.test' | wc -l)"
check "stamps live under \$HOME/.cache/<slug>-validate (found $stamp_count)" $(( stamp_count > 0 ))

if [[ $failures -gt 0 ]]; then
  echo "validate-cache.test.sh: $failures failure(s)"
  exit 1
fi
echo "validate-cache.test.sh: all cases passed"
