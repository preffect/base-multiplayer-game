#!/usr/bin/env bash
# The client's integration tier (docs/ENGINEERING.md §2.2). The Angular unit-test builder exits 1
# when its `include` matches no file, so a client without integration specs is skipped here, the
# way vitest's passWithNoTests skips the other packages.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
if ! find src -name '*.integration.spec.ts' -print -quit | grep -q .; then
  echo "client: no *.integration.spec.ts yet — nothing to run"
  exit 0
fi
exec ng run client:test-integration
