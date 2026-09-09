#!/usr/bin/env bash
# AI-audio asset pipeline (music + voice + SFX). Google / Gemini is the DEFAULT for both
# music (Lyria 3 Pro) and voice (Chirp 3 HD); other providers are opt-in. See AUDIO-PIPELINE.md.
#
# Two subcommands:
#   check  (default)  OFFLINE. Refresh manifests, diff vs disk, exit 1 if anything is missing.
#   sync              Generate missing assets. The ONLY command that spends money / hits paid
#                     APIs. NEVER run it unsolicited — present the `check` missing-list first
#                     and ask before syncing.
#
# Usage:
#   ./ai-pipeline.sh                       # check missing (exit 1 if any)
#   ./ai-pipeline.sh check                 # same as above (explicit)
#   ./ai-pipeline.sh sync                  # generate everything missing
#   ./ai-pipeline.sh sync --dry            # plan only, no API calls, no keys needed
#   ./ai-pipeline.sh sync --track <id>     # music only, one track
#   ./ai-pipeline.sh sync --npc <id>       # voice only, one NPC
#   ./ai-pipeline.sh sync --sfx <id>       # sfx only, one sound
#   ./ai-pipeline.sh sync --provider <lyria|elevenlabs>      # music (default: lyria/Google)
#   ./ai-pipeline.sh sync --sfx-provider <gemini|elevenlabs> # sfx   (default: gemini/Google)
#   ./ai-pipeline.sh --help                # show this help
#
# Voice provider is configured PER-NPC in tools/voice/voices.ts (default: chirp/Google),
# not via a sync-time flag.
#
# Scoping: only --track -> music; only --npc -> voice; only --sfx -> sfx; none -> all three.
set -euo pipefail
cd "$(dirname "$0")"

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
}

# -------- help (no deps, no network) --------------------------------------------------------
case "${1:-}" in
  --help | -h | help)
    usage
    exit 0
    ;;
esac

# -------- preflight ------------------------------------------------------------------------
command -v pnpm >/dev/null || {
  echo "pnpm not on PATH (run: corepack enable pnpm)" >&2
  exit 2
}

# TODO(seam): when a game adds audio, scaffold tools/ from AUDIO-PIPELINE.md (check-assets.ts,
# music/, voice/, sfx/). Until then this guard keeps `check` honest instead of erroring out.
if [[ ! -d tools ]]; then
  echo "No tools/ audio pipeline scaffolded yet."
  echo "This game has no audio, or it has not been wired up. See AUDIO-PIPELINE.md to add it."
  # `check` on a game with no audio is trivially clean -> exit 0; `sync` has nothing to do.
  exit 0
fi

cmd="${1:-check}"
shift || true

# -------- check (default, OFFLINE) ---------------------------------------------------------
if [[ "$cmd" == "check" ]]; then
  # Re-extracts every manifest and diffs vs disk. Never touches a paid API.
  exec pnpm exec tsx tools/check-assets.ts "$@"
fi

if [[ "$cmd" != "sync" ]]; then
  echo "usage: $0 [check|sync] [flags]   (try --help)" >&2
  exit 2
fi

# -------- sync (PAID unless --dry) ---------------------------------------------------------
# Builds per-modality arg arrays and a scope mask. Default provider for music is lyria
# (Google); for sfx is gemini (Google). Voice provider is per-NPC in voices.ts.
dry=()
m=()
v=()
s=()
mf=0
vf=0
sf=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry)
      dry+=(--dry)
      shift
      ;;
    --track)
      m+=(--id "${2:?--track needs an id}")
      mf=1
      shift 2
      ;;
    --npc)
      v+=(--npc "${2:?--npc needs an id}")
      vf=1
      shift 2
      ;;
    --sfx)
      s+=(--id "${2:?--sfx needs an id}")
      sf=1
      shift 2
      ;;
    --provider) # music provider: lyria (default, Google) | elevenlabs
      m+=(--provider "${2:?--provider needs a value}")
      shift 2
      ;;
    --sfx-provider) # sfx provider: gemini (default, Google) | elevenlabs
      s+=(--sfx-provider "${2:?--sfx-provider needs a value}")
      shift 2
      ;;
    *)
      echo "unknown flag: $1   (try --help)" >&2
      exit 2
      ;;
  esac
done

# No explicit scope flag -> run all three modalities.
if ((mf || vf || sf)); then
  rm=$mf
  rv=$vf
  rs=$sf
else
  rm=1
  rv=1
  rs=1
fi

status=0
# TODO(seam): these pnpm scripts must exist in package.json once audio is wired:
#   music:sync, voice:sync, sfx:sync (each: tsx tools/<kind>/generate.ts). See AUDIO-PIPELINE.md.
((rm)) && {
  echo "-- MUSIC --"
  pnpm music:sync "${dry[@]}" "${m[@]}" || status=$?
}
((rv)) && {
  echo "-- VOICE --"
  pnpm voice:sync "${dry[@]}" "${v[@]}" || status=$?
}
((rs)) && {
  echo "-- SFX  --"
  pnpm sfx:sync "${dry[@]}" "${s[@]}" || status=$?
}
exit $status
