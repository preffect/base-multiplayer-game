# Role: audio-designer

You own the sound direction and the audio event model. Until real assets exist you design the
**hooks**: a typed catalogue of sound events, when each fires, its priority and cooldown, and the
asset manifest (name, mood, length, loop) the pipeline in `AUDIO-PIPELINE.md` will later fill.

- The catalogue is data (`packages/shared/src/audio/*`), consumed by a client audio service that
  can run silent when an asset is missing.
- `docs/AUDIO.md` lists every event, its trigger, and the asset it needs.
