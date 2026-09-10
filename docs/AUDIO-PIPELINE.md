# Audio Pipeline (Music + Voice + SFX)

Reusable AI-audio asset pipeline for games built from this template, modeled on the
reference pipeline. **Google / Gemini is the DEFAULT for both music and voice**; all other
providers are opt-in.

- **Music:** Google **Lyria 3 Pro** (via `GEMINI_API_KEY`) — default. ElevenLabs Music opt-in.
- **Voice:** Google **Chirp 3 HD** (via `GOOGLE_CLOUD_TTS_API_KEY`) — default. Optional Gemini
  native-audio TTS reuses `GEMINI_API_KEY`. OpenAI / ElevenLabs opt-in.
- **SFX:** curated CC0/CC-BY clips first; AI fallback defaults to Google (`gemini`, which routes
  to Lyria under the hood). ElevenLabs Sound Generation opt-in.

> This pipeline is **opt-in per game.** If your game has no audio, you do not need it. When you
> do add audio, scaffold `tools/` from the contract below and ship `ai-pipeline.sh` at the repo
> root. **`sync` is the only command that spends money and MUST never run unsolicited** — run
> `./ai-pipeline.sh check` at the end of a task, present the missing list, and ask before `sync`.

---

## When to offer audio (prompt the user)

Audio generation costs money, so it is **always user-initiated** — but you must proactively
**offer** it at the two moments a game gains audio-worthy content:

- **When you create or add a level / area / encounter:** ask whether they want music for it
  (e.g. "I added the _Foundry_ level — want a music track generated for it?"). If yes, add the
  track to `tools/music/tracks.ts`, run `./ai-pipeline.sh check`, then confirm before `sync`.
- **When you add dialog / NPC lines / a cutscene:** ask whether they want it voiced (e.g. "The
  bartender now has 6 lines — generate voice for them?"). If yes, add the NPC's voice + lines,
  run `./ai-pipeline.sh check`, confirm, then `sync`.

Never auto-`sync` on either trigger and never silently skip the offer — surface it and let the
user decide. `check` and `sync --dry` are free to run while you wait for the answer.

## 1. The `check | sync` model

One bash wrapper, `./ai-pipeline.sh`, fronts everything. `check` (default) is **offline**;
`sync` is the **only** thing that hits paid APIs.

```text
./ai-pipeline.sh            -> check (default): refresh manifests, diff vs disk, exit 1 if missing
./ai-pipeline.sh sync       -> generate everything missing (music + voice + sfx)
./ai-pipeline.sh sync --dry -> plan only; print what WOULD generate; no API calls, no keys needed
```

Three layers per modality:

1. **Source of truth (code):** track/voice/sfx definitions live in `tools/<kind>/`
   (`tracks.ts`, per-NPC `voices.ts` + dialog data, `sounds.ts`).
2. **`extract.ts`** — pure, offline, no network. Walks the source, computes a content hash per
   item, writes `public/<kind>/manifest.json`. Imported directly by `check-assets.ts` and
   `generate.ts` so the manifest is always fresh before any diff.
3. **`generate.ts`** (`pnpm <kind>:sync`) — diffs manifest vs disk/index, calls the provider
   only for **changed/missing** items, writes the audio files + rewrites `index.json`.

`check-assets.ts` re-extracts all manifests, checks each entry's file exists on disk, prints a
grouped report, and sets exit code `0` (all present) / `1` (missing) / `2` (check errored).

---

## 2. Cache keys (provider model is baked in)

- **Music:** `sha1(`id|prompt|durationMs|modelTag`).slice(0,16)` where `modelTag` comes from
  `MUSIC_MODEL_BY_PROVIDER[provider]`. Switching music providers rehashes every track (same
  prompt sounds different per model — intentional full regen).
- **Voice:** `sha1(`text|provider|voiceId|voicePrompt|model`).slice(0,16)`. Re-pointing one NPC
  at a new voice/provider regenerates only that NPC's lines. `voicePrompt` is forced to `""`
  for providers without a direction field (Chirp/ElevenLabs) so it never pollutes their hash.
- **SFX:** curated entries hash by `id + extension` only (so prompt edits never invalidate a
  curated file and the planner skips them); AI-SFX uses a fixed salt and **omits the provider**
  so flipping the SFX default doesn't invalidate existing clips.
- Runtime-only metadata (volume, loop points) is **excluded** from all hashes — tweaking volume
  must not trigger a paid regen.

---

## 3. Outputs, manifests, git

```text
public/music/{manifest,index}.json + <id>.mp3
public/voice/{manifest,index}.json + <npcId>/<context>/<NN>-<slug>.mp3
public/sfx/{manifest,index}.json   + <id>.<ext>   + CREDITS.md
```

- **`index.json`** is the runtime lookup (`id -> path`) — **committed**.
- **`manifest.json`** is the full debug/source dump — **committed**.
- **The audio files themselves are gitignored** — add to `.gitignore`:
  `public/music/*.mp3`, `public/voice/**/*.mp3`, `public/sfx/*` (keep the json + CREDITS).
- Identical voice lines (same hash) alias to one canonical file.
- **Partial-progress safe:** even on a mid-batch failure, `generate.ts` rewrites `index.json`
  from what actually landed on disk, then re-throws — so partial syncs stay usable.

---

## 4. Provider matrix

### Music

| Provider             | Select                                     | Model id (tag)                                   | Key env              | Notes                                                                                             |
| -------------------- | ------------------------------------------ | ------------------------------------------------ | -------------------- | ------------------------------------------------------------------------------------------------- |
| **Lyria 3 (Google)** | **default**                                | `lyria-3-pro-preview` (`lyria_3_pro_preview_v1`) | **`GEMINI_API_KEY`** | Default. Prompt-driven duration. Has a copyright filter; mitigate with an "original work" clause. |
| ElevenLabs Music     | `--provider elevenlabs` / `MUSIC_PROVIDER` | `elevenlabs_music_v1`                            | `ELEVENLABS_API_KEY` | Exact duration; no copyright filter. Opt-in.                                                      |

Precedence: `--provider` > `MUSIC_PROVIDER` env > `DEFAULT_MUSIC_PROVIDER` (`lyria`).

### Voice (per-NPC config in `tools/voice/voices.ts`, not a sync-time flag)

| Provider                | Select                   | Model                          | Key env                        | Notes                                                                               |
| ----------------------- | ------------------------ | ------------------------------ | ------------------------------ | ----------------------------------------------------------------------------------- |
| **Chirp 3 HD (Google)** | **default** per-NPC      | `chirp-3-hd`                   | **`GOOGLE_CLOUD_TTS_API_KEY`** | Production-grade. Use `speakingRate` (default 0.92) / SSML; no free-form direction. |
| Gemini TTS (Google)     | `provider: "gemini"`     | `gemini-2.5-flash-preview-tts` | **`GEMINI_API_KEY`**           | Optional. Free-form voice direction; returns PCM (WAV-wrap). Reuses the Lyria key.  |
| OpenAI TTS              | `provider: "openai"`     | `gpt-4o-mini-tts`              | `OPENAI_API_KEY`               | Opt-in. Per-line `instructions` direction.                                          |
| ElevenLabs TTS          | `provider: "elevenlabs"` | `eleven_multilingual_v2`       | `ELEVENLABS_API_KEY`           | Opt-in. Voice Design / Library voice ids.                                           |

**Defaults to enforce when porting the tools:**

1. `DEFAULT_MUSIC_PROVIDER = "lyria"`, `API_KEY_ENV_BY_PROVIDER.lyria = "GEMINI_API_KEY"`.
2. In `tools/voice/config.ts`, make `modelFor`'s fallthrough return the **Chirp** model and
   treat Chirp as the default provider constant (do NOT default to OpenAI). New NPC entries in
   `voices.ts` default to `{ provider: "chirp", voiceId: "en-US-Chirp3-HD-<Name>" }`.
3. A single `GEMINI_API_KEY` covers music (Lyria), the SFX default, and optional Gemini-TTS;
   `GOOGLE_CLOUD_TTS_API_KEY` covers production Chirp voice. OpenAI/ElevenLabs keys are required
   **only** when a track/NPC/SFX in scope actually uses them.

---

## 5. SFX prompt authoring (curated-first)

1. **Curated OpenGameArt-style clips are the default; AI generation is the fallback.** AI sound
   generators are unreliable for short impacts. Each `sounds.ts` entry may be
   `curated: true` with a real `extension` (`wav`/`ogg`/`flac`) and
   `attribution { source, author, license }` (CC0 preferred, CC-BY acceptable; record in
   `public/sfx/CREDITS.md`).
2. For genuinely-AI SFX, write prompts with: **onomatopoeia** ("thoomp", "whoosh"),
   **material** ("metallic", "wooden", "wet"), **era** ("8-bit", "retro arcade"),
   **constraints** ("single hit", "no music", "no voice", "dry, no reverb"), and an optional
   **reference**. Set an explicit `durationSeconds`.
3. **Compose prompts from shared templates, not ad hoc.** Music prompts splice a shared
   intro/loop framing clause, a "no vocals" clause, and an "original work" clause (the last
   helps Lyria's copyright filter) into every track so quality stays consistent.

---

## 6. `ai-pipeline.sh` (ship this skeleton at the repo root, Google default)

```bash
#!/usr/bin/env bash
# AI-audio asset pipeline. check (default, offline) | sync (paid APIs).
#   ./ai-pipeline.sh                       # check missing (exit 1 if any)
#   ./ai-pipeline.sh sync                  # generate everything missing
#   ./ai-pipeline.sh sync --dry            # plan only, no API calls
#   ./ai-pipeline.sh sync --track <id>     # music only, one track
#   ./ai-pipeline.sh sync --npc <id>       # voice only, one NPC
#   ./ai-pipeline.sh sync --sfx <id>       # sfx only, one sound
#   ./ai-pipeline.sh sync --provider <lyria|elevenlabs>      # music (default: lyria/Google)
#   ./ai-pipeline.sh sync --sfx-provider <gemini|elevenlabs> # sfx   (default: gemini/Google)
# Voice provider is per-NPC in tools/voice/voices.ts (default: chirp/Google).
# Scoping: only --track -> music; only --npc -> voice; only --sfx -> sfx; none -> all three.
set -euo pipefail
cd "$(dirname "$0")"
command -v pnpm >/dev/null || { echo "pnpm not on PATH (corepack enable pnpm)"; exit 2; }

cmd="${1:-check}"; shift || true
[[ "$cmd" == check ]] && exec pnpm exec tsx tools/check-assets.ts "$@"
[[ "$cmd" == sync ]] || { echo "usage: $0 [check|sync] ..."; exit 2; }

dry=(); m=(); v=(); s=(); mf=0; vf=0; sf=0
while [[ $# -gt 0 ]]; do case "$1" in
  --dry) dry+=(--dry); shift;;
  --track) m+=(--id "${2:?}"); mf=1; shift 2;;
  --npc)   v+=(--npc "${2:?}"); vf=1; shift 2;;
  --sfx)   s+=(--id "${2:?}"); sf=1; shift 2;;
  --provider)     m+=(--provider "${2:?}"); shift 2;;       # music: lyria(default)|elevenlabs
  --sfx-provider) s+=(--sfx-provider "${2:?}"); shift 2;;   # sfx: gemini(default)|elevenlabs
  *) echo "unknown flag: $1"; exit 2;;
esac; done

if (( mf||vf||sf )); then rm=$mf; rv=$vf; rs=$sf; else rm=1; rv=1; rs=1; fi
status=0
(( rm )) && { echo "-- MUSIC --"; pnpm music:sync "${dry[@]}" "${m[@]}" || status=$?; }
(( rv )) && { echo "-- VOICE --"; pnpm voice:sync "${dry[@]}" "${v[@]}" || status=$?; }
(( rs )) && { echo "-- SFX  --"; pnpm sfx:sync   "${dry[@]}" "${s[@]}" || status=$?; }
exit $status
```

Backing `pnpm` scripts (in root `package.json`): `music:extract|sync|sync:dry|prune`,
`voice:extract|sync|sync:dry|prune`, `sfx:extract|sync|prune`, each `tsx tools/<kind>/<script>.ts`.

Tool layout to port from the reference pipeline:

```text
tools/
  ai-pipeline.sh            # (the script above, symlinked/located at repo root)
  check-assets.ts           # refresh manifests, diff vs disk, exit 1 if missing
  shared/   { env, concurrency, fs-utils, hash }.ts
  music/    { config, tracks, types, extract, generate, lyria, elevenlabs, prune }.ts
  voice/    { config, voices, types, extract, generate, chirp, gemini, openai, elevenlabs, prune }.ts
  sfx/      { config, sounds, types, extract, generate, lyria, elevenlabs, prune }.ts
```

---

## 7. `.env.example` keys to add

Add these to the template's `.env.example` (copy to `.env`, which is gitignored). Only the keys
for providers you actually use are required — the Google defaults need just the first two.

```bash
# AI-audio asset pipeline keys. Copy to .env (gitignored). Google defaults need only the
# first two; the rest are opt-in fallback providers.

# Google Gemini — DEFAULT music (Lyria 3 Pro) and default SFX, plus optional Gemini
# native-audio TTS voice. One key covers all three.
GEMINI_API_KEY=

# Google Cloud Text-to-Speech — DEFAULT voice (Chirp 3 HD). SEPARATE GCP key from
# GEMINI_API_KEY (enable the Cloud Text-to-Speech API on it).
GOOGLE_CLOUD_TTS_API_KEY=

# --- opt-in fallback providers ---
# OpenAI — gpt-4o-mini-tts voice (per-NPC provider: "openai")
OPENAI_API_KEY=
# ElevenLabs — music (--provider elevenlabs), TTS, Voice Design/Library, SFX
ELEVENLABS_API_KEY=
```

---

## 8. Pipeline invariants (enforce)

- Defaults are Google: music = `lyria`, voice = `chirp`, sfx = `gemini`/Lyria. Others opt-in.
- `extract` and `check` are offline; **only `sync` spends money and never runs unsolicited.**
- Audio files gitignored; `manifest.json` + `index.json` committed.
- Cache keys bake in the provider model (music/voice); SFX curated keys are prompt-stable.
- Partial-progress safe: rewrite `index.json` from disk even on mid-batch failure.
- Run `./ai-pipeline.sh check` at the end of any task touching audio; present the missing list
  and **ask before `sync`**.
