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
- **Water renders (2026-08-26); the sky's cloud texture is disabled again (2026-09-01).** The
  procedural gradient sky (real per-zone `SkyTopColor`/`SkyBottomColor`, thirtieth round) still
  ships. The real `cloud1.ddj` texture on a dome produced a real sunburst/fan artifact at the
  dome's pole that turned out not to be fixable by adjusting UV tiling alone (a real projection
  singularity, see `docs/WORLD_ISSUES.md`'s thirty-fifth round) — disabled rather than shipped
  broken. `glow.ddj` (sun billboard) is unaffected and still renders. `Weather\` (rain/snow/smog)
  and `Sun\` (real moon-phase textures) are still real, confirmed, untouched content.

## Character rendering

- ~~The front/back texture-swap bug~~ — **SOLVED 2026-08-31** (see `docs/WORLD_ISSUES.md`'s
  thirty-first round). Not a mesh/data bug at all — proved the real mesh/UV data is 100% correct
  via a real textured render (+Z shows real abs/chest texture, -Z shows real spine/shoulder-blade
  texture, exactly where each belongs). The actual cause: the default (non-orbited) camera sat on
  the character's *front* side instead of behind them, because `CameraArm`'s baseline yaw (0) put
  it on the same side `atan2(dir.x, dir.z)` faces the character's real front toward. Fixed by
  changing `CameraArm.rotation_degrees` to `(-42, 180, 0)` and updating `DEFAULT_CAMERA_YAW_DEGREES`
  to match. Live-verified: re-rendering from the exact fixed camera direction shows the real back,
  confirming standard third-person framing.
- ~~Real per-species monster models~~ — **Stone Golem implemented and visually verified 2026-09-01**
  (see `docs/WORLD_ISSUES.md`'s thirty-third round). A monster's real `.bsr` turned out to embed its
  own matching `.bsk` skeleton path directly, confirming the coordinate-space question: real mesh
  piece positions are in the same absolute bind-pose space `CharacterAssembler` already assumes for
  humans, no extra transform needed. Piece-to-bone correspondence was computed from real vertex/bone
  position data (no body-part-hinting names exist for monster mesh pieces) and confirmed via a real
  rendered screenshot — a recognizable rock-golem silhouette, not guessed. **Sand Scorpion not done
  yet** — real data confirmed to exist, same derivation process not yet run. **Wild Boar still has no
  real asset at all.** Animation playback (14 real `.ban` files known, e.g. walk/attack/die) not
  wired up — the golem currently renders in a static bind pose.
- **Equipment/weapon/shield visuals are real but not verified complete** — `armor_slots_mask`
  correctly drives which real armor pieces attach, but there's been no recent audit of whether
  every armor/weapon/shield combination actually resolves to a real asset vs. silently rendering
  nothing for an unmapped combination.
- ~~Root-cause fix: assembled player character never animated at all~~ — **fixed 2026-08-28**, same
  day as the correction above. `Skeleton3DBuilder.build_skeleton3d` now uses each bone's real
  `.bsk` world-space bind rotation (converted to a parent-relative rest transform) instead of
  `Basis.IDENTITY`, verified via real rendered screenshots showing a coherent walking stride
  instead of the previous exploded T-pose (see `docs/WORLD_ISSUES.md`'s twenty-eighth round for the
  full verification process). Player idle/walk animation playback is re-enabled in
  `World3D._physics_process`. **Not yet seen in an actual live playtest** — the isolated bare-skeleton
  test was real and visually confirmed, but the in-game result (with real equipment/weapon
  attachments layered on) hasn't been checked yet, needs a real retest. Arms showed little motion
  in the one real animation checked (`chinaman_fighter_walkforward.ban`) — unconfirmed whether
  that's correct animation content or a remaining gap.
- `hit_anim`/`death_anim` are cached per gender and now genuinely ready to wire to the
  already-decoded `player_damage_taken`/`player_died` signals (`combat.gd`) now that playback
  itself works. Picking a specific real attack animation among many similarly-named
  `skill_ch_sword_*attack*.ban` files still needs more real data than a file listing alone
  provides.

## Objects and world dressing

- ~~Object-placement completeness audit~~ — done 2026-08-31: both real zones resolve **100%** of
  their real placements to a real, existing model file. Not a rendering gap (see
  `docs/WORLD_ISSUES.md`'s twenty-ninth round). Caveat: only checked that the referenced file
  *exists*, not that it fully parses through every sub-resource — a deeper check nobody's done yet.
- ~~Real per-zone day/night lighting~~ — **wired in 2026-08-31.** Public documentation
  ([`DummkopfOfHachtenduden/SilkroadDoc`](https://github.com/DummkopfOfHachtenduden/SilkroadDoc/wiki/JMXVENVI))
  named all 16 `environment.ifo` channels, matching this project's own independently-decompiled
  channel-size sequence exactly — resolving the channel-mapping ambiguity that blocked this in the
  twenty-ninth round. `World3D` now applies the player's own zone's real `SkyTopColor`/
  `SkyBottomColor` (sampled at a fixed midday snapshot — no real day/night clock system exists yet,
  see `docs/WORLD_ISSUES.md`'s thirtieth round for that honest scope note) to the sky gradient,
  replacing the old flat-color-derived guess. `DirectionalLight3D`'s angle is still a hand-set
  constant, not real per-zone data — `SunColor`/`DiffuseColor` channels exist and could drive it,
  not attempted this round. `FogColor`/`FogNearPlane`/`FogFarPlane` deliberately left unwired (fog
  was already removed once this session after a guessed density looked bad; the real near/far
  values don't read like literal distances at face value, so wiring them needs more real evidence
  first). **Visually verified 2026-08-31** — ran the actual `v0.1.10` release binary against real
  pulled `Data.pk2`/`Map.pk2` for Jangan (`89/182`); the real environment-lighting code path was
  exercised live (same terrain-load call that also fixed the sunburst artifact) and produced a
  reasonable-looking sky, not a broken one.

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

1. **Sky (skybox instead of flat color) — partially reverted 2026-09-01.** First-pass approximation
   (2026-08-28) used real `cloud1.ddj`/`glow.ddj` textures on a dome; a sunburst/fan UV artifact
   found 2026-08-31 turned out to only be partially fixed by removing texture tiling — a real
   follow-up render (thirty-fifth round) found it's a genuine projection singularity at the dome's
   pole, not fixable by `uv1_scale` or segment count alone. **The textured cloud dome is now
   disabled** — only the procedural gradient sky (still using real per-zone `SkyTopColor`/
   `SkyBottomColor`) ships. A real fix needs a custom shader that fades the texture near the pole,
   or capping the dome so the pole is never in view — not attempted yet.
2. ~~Ground-texture completeness audit~~ — done 2026-08-28, both real zones are 100% covered,
   nothing to fix.
3. ~~Object-placement completeness audit~~ — done 2026-08-31, both zones 100% covered.
4. ~~Real day/night environment-lighting~~ — done 2026-08-31, real public channel names found and
   wired into the sky's top/bottom colors. Visually verified 2026-08-31 against a real live render.
5. ~~Front/back texture-swap root cause~~ — SOLVED 2026-08-31, a camera yaw bug, not a mesh bug.
6. ~~Real monster models~~ — Stone Golem done 2026-09-01, visually verified. Sand Scorpion and
   monster animation playback still open.
7. Weather polish, remaining animation states.
