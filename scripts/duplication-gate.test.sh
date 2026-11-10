#!/usr/bin/env bash
# duplication-gate.test.sh — `./validate.sh duplication` fails on any clone (docs/ENGINEERING.md §3.3, #98):
# the repo's own .jscpd.json and the installed jscpd run over a fixture large enough that one small clone reads
# as 0% duplicated, the case jscpd's rounded threshold let through; the clone turns the gate red and names both
# files, while the same fixture without it stays green.
# Needs node_modules (`pnpm install`).
#
#   scripts/duplication-gate.test.sh        # exit 0 when every case passes
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sandbox="$(mktemp -d)"
source "$repo_root/scripts/lib/shell-test.sh"
trap 'rm -rf "$sandbox"' EXIT

JSCPD_BIN="$repo_root/node_modules/.bin/jscpd"
[[ -x "$JSCPD_BIN" ]] || { echo "FAIL no jscpd at $JSCPD_BIN: install the workspace first (./validate.sh does)"; exit 1; }
# jscpd skips a file over 1,000 lines (its maxLines default), counts a file's lines from its first token to its
# last, and rounds the duplicated share to two decimals: 200 files of a comment spanning 996 lines make one
# 8-line clone about 0.004%, which rounds to 0. A comment is one token, so the filler is quick and never a clone.
FILLER_FILE_COUNT=200
FILLER_BLANK_LINES=996
CLONE_A=packages/server/src/game/seeded-clone-a.ts
CLONE_B=packages/client/src/app/seeded-clone-b.ts

# --- fixture: validate.sh, the repo's jscpd config and the filler sources ----------------------------------
fixture="$sandbox/repo"
mkdir -p "$sandbox/bin" "$sandbox/home" "$fixture/packages/shared/src/filler" \
  "$fixture/packages/server/src/game" "$fixture/packages/client/src/app"
cp "$repo_root/validate.sh" "$repo_root/.jscpd.json" "$fixture/"
printf -v blank_lines '%*s' "$FILLER_BLANK_LINES" ''
blank_lines="${blank_lines// /$'\n'}"
for ((file = 0; file < FILLER_FILE_COUNT; file++)); do
  printf 'export const fillerStart%d = %d;\n/*%s*/\nexport const fillerEnd%d = %d;\n' \
    "$file" "$file" "$blank_lines" "$file" "$file" > "$fixture/packages/shared/src/filler/filler-$file.ts"
done
# The seeded clone: 8 lines and well over 50 tokens, the same in a server and a client file.
write_clone() { # <path> <function name>
  cat > "$fixture/$1" <<TS
export function $2(values: readonly number[], limit: number): number[] {
  const kept: number[] = [];
  for (const value of values) {
    if (value > limit || Number.isNaN(value)) continue;
    kept.push(Math.round(value * 100) / 100 + limit * 2);
  }
  return kept.sort((left, right) => left - right).slice(0, limit);
}
TS
}

# Only the duplication phase calls pnpm: `pnpm jscpd ...` reaches the installed jscpd.
cat > "$sandbox/bin/pnpm" <<PNPM
#!/usr/bin/env bash
[[ "\$1" == jscpd ]] || { echo "unexpected pnpm \$*"; exit 1; }
shift
exec "$JSCPD_BIN" "\$@"
PNPM
chmod +x "$sandbox/bin/pnpm"
export PATH="$sandbox/bin:$PATH" HOME="$sandbox/home"
unset VALIDATE_CACHE_DIR

run_duplication() { # -> output in $out, exit code in $rc
  rc=0
  out="$(cd "$fixture" && ./validate.sh duplication --fresh 2>&1)" || rc=$?
}
ran() { grep -q -- "$1" <<<"$out"; } # <pattern>: whether the last run's output matches

# --- cases ------------------------------------------------------------------------------------------
run_duplication
check "the filler alone has no clone and passes" $(( rc == 0 && $(holds ran 'Found 0 clones') ))

write_clone "$CLONE_A" keepBelowLimit
write_clone "$CLONE_B" keepUnderLimit
run_duplication
# jscpd's threshold reporter prints this only when the rounded share is above the threshold (0).
check "the fixture reproduces the rounding: one clone, below the threshold reporter" $(( $(holds ran 'Found 1 clones') && $(holds ran 'too many duplicates') == 0 ))
check "one clone turns the duplication gate red" $(( rc != 0 ))
check "the red run names both copies" $(( $(holds ran "$CLONE_A") && $(holds ran "$CLONE_B") ))

finish_suite duplication-gate.test.sh
