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

- ~~The front/back texture-swap bug~~ — **SOLVED 2026-08-31** (see `docs/WORLD_ISSUES.md`'s
  thirty-first round). Not a mesh/data bug at all — proved the real mesh/UV data is 100% correct
  via a real textured render (+Z shows real abs/chest texture, -Z shows real spine/shoulder-blade
  texture, exactly where each belongs). The actual cause: the default (non-orbited) camera sat on
  the character's *front* side instead of behind them, because `CameraArm`'s baseline yaw (0) put
  it on the same side `atan2(dir.x, dir.z)` faces the character's real front toward. Fixed by
  changing `CameraArm.rotation_degrees` to `(-42, 180, 0)` and updating `DEFAULT_CAMERA_YAW_DEGREES`
  to match. Live-verified: re-rendering from the exact fixed camera direction shows the real back,
  confirming standard third-person framing.
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
  first). **Not yet visually verified in a live render** — real data, unit-tested logic, clean
  headless checks, but no actual screenshot comparison yet.

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
3. ~~Object-placement completeness audit~~ — done 2026-08-31, both zones 100% covered.
4. ~~Real day/night environment-lighting~~ — done 2026-08-31, real public channel names found and
   wired into the sky's top/bottom colors. Not yet visually verified in a live render.
5. ~~Front/back texture-swap root cause~~ — SOLVED 2026-08-31, a camera yaw bug, not a mesh bug.
6. Real monster models (replacing the placeholder capsule).
7. Weather polish, remaining animation states.
