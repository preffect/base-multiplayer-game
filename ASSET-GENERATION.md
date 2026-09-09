# Visual Asset Quality Bar (Drop-In Prompt)

> **When generating ANY visual asset — player, monster/enemy, item, tile, vehicle,
> structure, projectile, UI emblem — follow this document.** It is a non-negotiable quality
> gate. `./validate.sh all` being green is necessary but **NOT sufficient**: "it renders and
> typecheck passes" is not done. An asset is done only when it clears every checklist item
> below.
>
> **No placeholders, no shortcuts — ever.** There is no "temporary art" phase. Do not ship a
> flat, blocky, or "I'll polish it later" asset to get something on screen. Build every asset to
> this bar on the first pass — the first version a player sees is already the finished version.

This template draws **all** visual assets in code — there are intentionally **zero bitmap
files** (no png/svg/webp committed). A player or monster or item is built from layered shapes,
gradients, and palettes, not a single flat rectangle. This is medium-agnostic: it applies
equally to Canvas 2D, Pixi/Phaser `Graphics`, SVG, or generated-image workflows.

---

## 1. Build every asset in layers, back-to-front

Minimum layer stack for any player / monster / item / structure:

1. **Drop shadow / ground contact** — an offset radial gradient or dark shape so it sits in
   the world rather than floating.
2. **Body fill with a gradient or a light→dark palette ramp — never one flat color.**
   Multi-stop linear gradient for cylinders / metal / glass; radial gradient for orbs / lights
   / energy. In pixel-art this means an explicit **highlight row/edge AND a shadow row/edge**
   built from `lighten()` / `darken()` of the base color.
3. **Structural / material detail** — bevels, rivets/bolts, panel seams, plating, trim,
   brushed-metal speckle, vents, hazard stripes, stitching — whatever suits the material.
4. **Signature feature(s)** — the 2–3 elements that say _what this thing is and does_ (a
   furnace has molten pools; a healer carries a glowing vial; a turret has a barrel and a
   targeting eye). See the Legibility Test.
5. **Glow / emissive accents** — LEDs, eyes, screens, thrusters — drawn as **bright core +
   soft halo + tiny white glint**, never a solid dot.
6. **In-world label / stencil** where a real object would carry one.
7. **Crisp outline stroke / dark edge** so the silhouette reads against any background.

**If your asset has fewer than ~5 of these layers, it is a placeholder, not an asset.**

---

## 2. Palette discipline

- Define **named palette constants** — a base plus at least one darker and one lighter shade
  per material (e.g. `STEEL_DARK / STEEL_BASE / STEEL_LIGHT`). **Never scatter raw hex literals
  through draw code.**
- Each asset uses a small, intentional ramp (1–2 hues + an accent). **Reuse the shared
  color/shading helpers** so each new asset matches the existing art style and the game stays
  visually coherent.

---

## 3. Animation / juice

- Thread a time value `t` into the render path. Give every asset **at least one idle motion**:
  pulse, blink, drift, rotate, ripple, bob, or sway. Static is acceptable only for genuinely
  inert props.

---

## 4. Silhouette + legibility

- **Distinct silhouette:** two different monsters or items must be recognizable from their
  outline alone — not the same blob recolored.
- **Legibility test (say it out loud):** point at the finished asset and name **2–3 visible
  features** that tell the player what it is and what it does. If you can't, it isn't finished.

---

## 5. Structure / maintainability

- **No 400+ line monolith renderers.** One thin orchestrator that calls small, single-feature
  helpers (`drawShadow`, `drawBody`, `drawRivets`, `drawGlow`, `drawLabel`, `drawOutline`).
  Put reusable primitives in a shared art-helpers module so every asset inherits the house
  style.
- Express dimensions as **fractions of the asset's size** (`w`, `h`, `r`) so it scales across
  zoom / LOD.
- **Pre-render once** into an offscreen canvas / cached `Graphics`, then blit each frame.
  Detail is therefore free per frame — there is no performance excuse for flat art.

---

## 6. Per-asset checklist (run for EACH asset)

- [ ] ≥5 distinct draw layers, including shadow, gradient/ramped body, material detail,
      signature feature, and outline.
- [ ] No flat single-color fill as the whole asset; the body has visible shading / volume.
- [ ] Uses named palette constants and the shared shading helpers — no scattered raw hex.
- [ ] Has ≥1 idle animation driven by `t`.
- [ ] Distinct, readable silhouette; passes the legibility test (name 2–3 features).
- [ ] Built from small composable helpers; dimensions are size-relative; pre-rendered/cached.
- [ ] Glow/emissive elements use core + halo + glint, not a solid dot.
- [ ] `./validate.sh all` is green (necessary, not sufficient — the visual bar is the real gate).

---

## 7. Acceptance criteria

An asset is **accepted** only when every box in §6 is checked AND a reviewer can pass the
legibility test on it. If it fails any box, it is rejected and **redone now**, not deferred.

---

## 8. Good vs. lazy (concrete)

**GOOD — a fuel canister:** radial drop shadow → vertical gradient cylinder body → black label
band with a stenciled tag → steel regulator dial with a needle → colored valve handle →
pulsing pressure-gauge LED with halo → dark outline. ~9 layers, one animated element.

**GOOD — a boss:** shadow → thick legs (darkened armor) → tapered torso built row-by-row → 3
armor plates (darker) → glowing energy veins → crested helmet head → glowing eyes with a white
glint → fists → chest highlight (lightened). ~30 explicit layered shapes, distinct silhouette.

**LAZY (reject and redo):**

```ts
ctx.fillStyle = 'red';
ctx.fillRect(x, y, 16, 16);
```

A flat square: no shadow, no gradient, no detail, no animation, no outline, indistinguishable
from every other entity. There are no asset shortcuts — never ship this, not even as a
"temporary" first pass. Build it to the bar above.
