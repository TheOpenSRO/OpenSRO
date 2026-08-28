# Next steps: make the map and character actually look like the real game

Everything up through `v0.1.5` fixed *correctness* bugs — wrong scale, wrong camera, wrong spawn
positions, wrong collision. The world now loads, is proportioned correctly, and is playable. But
"playable and correctly scaled" is not the same as "looks like Silkroad Online." This doc is the
honest list of what's still missing between where the client is now and that goal, based on real
findings already logged in `docs/WORLD_ISSUES.md` and `docs/PROGRESS.md` — nothing here is new
speculation, it's a consolidation of gaps already found and flagged as open.

## Terrain

- ~~Ground-texture completeness audit~~ — done 2026-08-28: both real zones this project renders
  (Jangan `89/182`, Dunhuang `98/157`) resolve **100%** of their real per-vertex texture IDs to a
  real `Tile2D\` file. The flat-color fallback path is correct to keep but isn't currently firing
  anywhere real. Not a rendering gap after all.
- **The `.t` lightmap is wired in as ambient occlusion**, which is directionally correct but is a
  real engineering approximation, not a faithful reproduction of how the original client uses it —
  worth a side-by-side comparison against a real client screenshot once one is available.
- **Terrain seam blending exists (2026-08-24) but hasn't been re-verified since the scale fix** —
  the blend radius/strength was tuned against the old world scale.
- **Water and a first-pass sky now render** (water: 2026-08-26; sky: 2026-08-28, see
  `docs/WORLD_ISSUES.md`'s twenty-third round). The sky is an honest engineering approximation
  using the real `cloud1.ddj`/`glow.ddj` textures on a procedural gradient + cloud dome, not a
  reverse-engineered reproduction of the original blending algorithm (no config file describes it,
  and the only decompiled binary available is the server, not the client renderer). `Weather\`
  (rain/snow/smog) and `Sun\` (real moon-phase textures) are still real, confirmed, untouched
  content — worth revisiting once the sky's base look is confirmed against a real screenshot.

## Character rendering

- **The front/back texture-swap bug (reported, still not resolved).** A real user report described
  seeing the front of a texture through the back and vice versa. Three real causes checked and
  ruled out so far (2026-08-28, see `docs/WORLD_ISSUES.md`'s twenty-fifth round for detail): the
  alpha-cutout/backface-culling fix (materials in use are DXT1, no alpha channel); reversed
  triangle winding vs. stored normals (checked directly against a real `woman_torso_upper.bms`
  sample — 156/156 triangles consistent, avg dot 0.97); a negative-scale mirror transform anywhere
  in the character pipeline (none exists in code). Not yet checked: a subtle per-vertex field
  misalignment in `BmsReader`'s stride/offset handling that wouldn't trigger its existing
  NaN/unit-length self-check but could still silently swap which UV pairs with which position for
  some vertices — the next thing to check with real data before guessing further.
- **No real per-species monster models — scoped 2026-08-28, not yet implemented.** Confirmed real
  `.bsr`/`.bsk`/`.bmt` data exists for Stone Golem and Sand Scorpion (the two of this project's
  three spawned monsters that map to a real creature at all — "Wild Boar" has no real match, see
  `docs/WORLD_ISSUES.md`'s twenty-sixth round). Not implemented yet because a monster's real
  pipeline (`.bsr` compound mesh + separate `.bsk` skeleton) is materially different from both
  existing pipelines (static `ObjectLoader`, no skeleton; player `CharacterAssembler`, raw `.bms`
  parts rigidly bone-attached) and whether the `.bsr` sub-mesh coordinate space matches
  `CharacterAssembler`'s rigid-attach assumption is unconfirmed — real implementation work, ideally
  with a live playtest available to verify against, not something to guess through blind.
- **Equipment/weapon/shield visuals are real but not verified complete** — `armor_slots_mask`
  correctly drives which real armor pieces attach, but there's been no recent audit of whether
  every armor/weapon/shield combination actually resolves to a real asset vs. silently rendering
  nothing for an unmapped combination.
- **Animation coverage is real but likely partial** — walk-cycle playback exists
  (2026-08-22, "character/animation phase 3"), but idle/attack/cast/death and other real `.ban`
  animation states haven't been confirmed wired up since the scale fix changed the skeleton's own
  transform scale (animations are keyed against bind-pose bone positions, not the removed
  `skeleton.scale` hack — worth a real check that this didn't subtly break any animation that
  depended on the old scale being applied at the skeleton level rather than per-bone).

## Objects and world dressing

- **Object placement (`.o`/`.o2`) is real and positioned correctly** (absolute coordinates, real
  per-object rotation, `.cpd` compound sub-objects, all solved in the 2026-08-24 rounds) — but no
  recent audit has checked how many of a real zone's placed objects actually resolve to a real
  model vs. being silently skipped for an unmapped `type_id`.
- **Lighting is a single global `DirectionalLight3D` with a hand-set angle** — real Silkroad zones
  likely have per-zone lighting/time-of-day data (this hasn't been investigated at all; unknown
  whether it exists in the real data or whether the original client hardcodes it too).

## How to make progress here without violating the "no assumptions" rule

Every item above should be closed the same way every fix this session was: pull real data (via the
RE-box workflow — build a scratch Go tool, `scp`/`pct push` it to the box, inspect real `.pk2`
files, delete the tool and any pulled data afterward), or get a real side-by-side screenshot
comparison against the actual retail client, before changing a single rendering constant. If real
data can't be obtained for something, say so explicitly and leave it unimplemented rather than
guessing at a plausible-looking value — several real regressions this session (fog density, tile
colors, skin tone, character scale) came from exactly that shortcut.

## Suggested order

Roughly highest-visual-impact-per-effort first, based on how large each gap looks in every real
playtest screenshot so far:

1. ~~Sky (skybox instead of flat color)~~ — done 2026-08-28, first-pass approximation using real
   textures; needs a real screenshot check and revisit once one's available.
2. ~~Ground-texture completeness audit~~ — done 2026-08-28, both real zones are 100% covered,
   nothing to fix.
3. Front/back texture-swap root cause — a real, reported visual bug with no explanation yet.
4. Real monster models (replacing the placeholder capsule).
5. Weather/water polish, per-zone lighting, remaining animation states.
