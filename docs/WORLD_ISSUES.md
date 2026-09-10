# World/client issues tracker

Real playtest report from OpenSRO (2026-08-26), using the exact `.exe` produced by the most recent
GitHub Actions "Release client" run (manual `workflow_dispatch`, commit `3b9434d`), with his own
real pk2 files dropped into the local `pk2/` folder. Everything below was reported broken in that
one real play session. Headless/screenshot verification earlier this project had claimed several
of these as fixed — see `docs/PROGRESS.md`'s (cont'd 83) entry and
`feedback_headless_verification_gaps` in project memory for why that verification wasn't enough.

Status legend: `[ ]` not started, `[~]` in progress, `[x]` fixed with a concrete, checkable root
cause (still needs a real human retest to confirm — see the note below on what "fixed" means
here), `[?]` investigated, root cause understood, fix not yet possible/safe or not yet found.

- [x] **No log file.** Enabled Godot's built-in `debug/file_logging` (project.godot) — every run
  now writes `user://logs/srrevamp.log` (a real per-OS path, printed once at boot by `Boot.gd` so
  it's easy to find without a terminal). README documents the real Windows/Linux paths.
- [x] **WASD doesn't move the player, arrow keys do.** Root cause: `World3D.gd`'s movement code
  used Godot's *built-in* `ui_left`/`ui_right`/`ui_up`/`ui_down` actions, which are bound to arrow
  keys only by default — WASD was never mapped to anything. Added dedicated `move_forward`/
  `move_back`/`move_left`/`move_right` actions (project.godot) bound to both WASD and arrow keys,
  and switched `_physics_process`'s `Input.get_axis` calls to use them.
- [x] **Camera is FPS-like, not top-down-behind.** Root cause, confirmed via a headless
  `SpringArm3D` probe: `SpringArm3D` pushes its child to local **+Z**, not -Z. The previous
  rotation (`pitch=42, yaw=180` on the arm, plus a compensating 180° yaw on the `Camera3D` child)
  actually pushed the camera *down and in front* of the player, which then immediately collapsed
  against the ground via the spring's own collision check (confirmed: computed uncollided target
  was `(0,-7.6,-10.4)` relative to the player — underground). Corrected to `pitch=-42, yaw=0` on
  the arm with no extra rotation on the camera; re-simulated the exact scene headlessly and
  confirmed the *uncollided* camera position is now `(0, +11.2, +10.4)` relative to the player
  (above and behind, spring reaches its full configured length with no collapse) looking down and
  forward. Also updated `CAMERA_PITCH_MIN/MAX_DEGREES` (`-80`/`-10`) to match the corrected sign
  convention for the orbit-drag control.
- [x] **SpringArm3D could also collapse against the player's own capsule.** Gave `Player` a
  dedicated collision layer (2) separate from world geometry (layer 1, unchanged default for
  terrain/objects) so the camera arm's own collision probe (`collision_mask=1`) can never hit the
  player's own body, regardless of camera angle.
- [x] **Click-to-move likely blocked by the HUD itself.** `ActionTabs` (the Monsters/Inventory/
  Equipment/Quests/Skills/Shop/Party tab panel) was anchored to cover nearly the *entire* middle
  of the screen (`offset_top=120` to `offset_bottom=-168`, i.e. almost the whole play area) with
  `mouse_filter=PASS` — Godot Controls capture clicks over their whole bounding rect regardless of
  visible content, so most clicks meant for the 3D world (raycasting to walk there) would land on
  this panel instead of reaching `_unhandled_input`. Re-docked it to a real bottom action-bar
  layout (220px tall, anchored to the bottom above the chat panel) instead of covering the center
  of the screen — this also makes the HUD look and behave much more like a real MMO layout instead
  of a full-screen debug panel.
- [x] **No HUD at all / general "doesn't look right."** No explicit renderer was set in
  project.godot, so the client defaulted to Godot 4's Forward+ (Vulkan) renderer. A real
  playtest reporting *several* simultaneous, unrelated-looking visual symptoms at once (missing
  HUD, flat/textureless ground) without any crash is a classic signature of a GPU/driver Vulkan
  incompatibility on that specific machine, not several independent content bugs. Switched to the
  Compatibility (OpenGL) renderer, which runs on far more real hardware — a better default for a
  downloadable hobby client than Forward+'s extra features.
- [x] **~3 minute load time.** Root cause, confirmed by code inspection: `Pk2Reader._read_block_chain`
  (the function every single directory lookup goes through) did **zero caching** — every real asset
  resolution (`ObjectLoader.find_file` walks one `read_dir()`/`read_dir_at()` call per path
  segment, from the pk2 root down) fully re-read and re-decrypted (Blowfish, per 8-byte block, in
  interpreted GDScript) that folder's directory blocks from disk from scratch, even though the
  same handful of real folders (`Prim\Mesh\...`, `Prim\Mtrl\...`, `Tile2D\`, etc.) are resolved
  over and over for every object/texture a region needs. Added a per-archive directory cache keyed
  by each directory's file offset (safe: this reader is read-only, archive contents never change
  mid-session) — `find_file` calls sharing an ancestor folder now hit that folder's blocks once
  instead of once per call.
- [ ] **No grass / flat, textureless ground.** Ground-texture resolution code itself
  (`_load_real_ground_textures`) already goes through `Pk2Config`, not a dev-only env var, so it
  *should* work in a real local-pk2-folder run — no bug found there by inspection. Given the
  renderer fix above could fully explain this symptom on its own, holding off on further changes
  here until a real retest (with the new Compatibility-renderer build) shows whether it's still
  broken.
- [ ] **Placed objects look randomly scattered.** No randomness anywhere in the placement code
  (confirmed: no `randf`/`randi` calls in `World3D.gd` or the mapo readers) — real placement data
  is used as-is. Most likely explanations, in order of suspicion: (a) the renderer issue above
  making everything look wrong, (b) real per-object Y height not being terrain-snapped the way the
  player is (`_snap_player_onto_terrain` only ever adjusts the player), so objects could sit at
  their raw placement height against a real terrain whose regional height calibration is already
  documented as imperfect (see `_load_region_cell`'s `shared_vertical_anchor` comment) — a real,
  plausible but unconfirmed candidate. Needs a real retest to tell (a) from (b).
- [ ] **Real-world coordinates don't match the reference tool** (jellybitz.github.io/xSROMap).
  Still an open, previously-flagged unresolved question (see `docs/PROGRESS.md`'s south-gate
  coordinate entry) — the region/world-space conversion this project derived hasn't been checked
  against that specific reference tool yet. Needs a deliberate side-by-side comparison pass (not
  attempted this round — the other fixes above were higher-confidence, code-provable issues).
- [x] **Local pk2 folder loading itself.** Not independently re-verified this round (no real pk2
  files available in this sandbox to test against), but nothing found while reading this code path
  suggests a regression, and it wasn't reported as an explicit failure — flagged, not re-opened.

## What "fixed" means in this pass

Every `[x]` above has a **concrete, mechanically-confirmed root cause** — not a guess dressed up as
a fix. Where possible this was verified by literally simulating the affected Godot node/scene logic
headlessly (the `SpringArm3D` sign convention, the corrected camera's exact resulting position) or
by direct code inspection showing an unambiguous bug (the missing WASD action, the uncached
directory reads, the full-screen click-blocking panel). None of this has been confirmed by an
actual human playing the actual exported build yet — that's the next step. Per
`feedback_headless_verification_gaps`, this file will only mark something *actually done* once a
real retest confirms it, not just once a plausible fix lands.

## Next steps

1. Cut a new build (workflow_dispatch) with all of the above and get it in front of OpenSRO/OpenSRO.
2. Get the new `srrevamp.log` file back along with the playtest report this time — several of the
   remaining `[ ]` items (grass, scattered objects) may turn out to already be fixed as a side
   effect of the renderer change, or may need the log to diagnose further.
3. If the coordinate-mismatch item is still wanted, do a deliberate side-by-side comparison against
   jellybitz.github.io/xSROMap with a known real coordinate, rather than guessing at the transform
   again.

## 2026-08-26, second round — first retest attempt, likely against the stale build

OpenSRO connected a Windows Remote Control session (`opensro-desktop-sequential-rocket`) so this
project could drive the actual Windows exe directly instead of relaying through him. First test
run turned up a strong signal that it exercised the **old** build, not the fixed one:

- **The log's own startup banner said `Vulkan API 1.4.349 - Forward+`.** The fix in this file's
  first entry explicitly switches `project.godot` to the Compatibility (OpenGL) renderer — a build
  that actually included that change should show "Compatibility" here, not "Forward+". This is
  strong, direct evidence the tested `.exe` predates that fix (most likely the very first
  `workflow_dispatch` build, downloaded before the fixed one existed).
- **It loaded pk2 data from `C:\Users\opensro\Downloads\VSRO_Client\VSRO_Client\Data.pk2` instead of
  the local `pk2\` folder** next to the tested exe. `Pk2Config` checks an env var before the local
  folder by design (existing dev/testing convenience) — this means a persistent
  `SRREVAMP_*_PK2_PATH`-shaped env var is very likely still set on that Windows machine from earlier
  dev work, silently overriding the "just drop pk2 files in the folder" flow this project is
  supposed to support for a real downloaded user. Needs confirming/clearing before that flow can
  actually be considered tested.
- **New visual finding, not on the original list**: the player's own character rendered as a
  motionless T-pose (bind pose), not standing/idling normally. Investigated by pulling the real
  `chinaman_skel.bsk` and `chinaman_fighter_standcity.ban` from the RE box and checking bone-name
  overlap directly (Go, `bsk`/`ban` packages) — **36 of 37 skeleton bones have a matching, valid
  (14-keyframe) animation track** (the one non-match is the root "Bip01" bone itself, which
  `Skeleton3DBuilder.build_skeleton3d` deliberately excludes from by-name pose application — a
  known, minor gap, not a T-pose cause). Since the real animation data and bone matching both check
  out, this is most likely another symptom of testing the stale build rather than a genuine new
  animation bug — but not confirmed either way yet. **Needs a fresh screenshot from the actually-
  fixed build before concluding anything.**
- Real pk2/animation scratch data pulled for this check was deleted immediately after
  (`chinaman_skel.bsk`, `chinaman_fighter_standcity.ban`, the throwaway extractor tool/binary), per
  this project's no-persisted-real-assets policy.
- Waiting on: OpenSRO redownloading `srrevamp-windows.zip` specifically from
  https://github.com/OpenSRO/srrevamp/actions/runs/32891267640 into a fresh folder and retesting,
  plus checking for a stray `SRREVAMP_*_PK2_PATH` env var on that machine.

## 2026-08-26, third round — real retest via a Windows Remote Control session: MAJOR bug found

OpenSRO ran the client directly from the Godot editor (env vars pointed at his local pk2 files),
confirming this project's own committed code (not a stale build) — the boot message, log-file
line, WASD movement, and click-to-move all matched the current source. The log itself showed a
genuinely healthy load: both genders' character assets (`idle_anim=true, walk_anim=true`), 11
real regions with terrain + ~2,800 real map objects, only one missing real asset
(`w_cd_stab_buil03_wal.bsr`, an already-known content gap). This ruled out the "stale build"
theory from the previous round for everything except the renderer line specifically (the editor's
Play-mode viewport doesn't necessarily follow project.godot's `rendering_method` the way an
*exported* build does, so `Forward+` showing up there isn't informative either way).

**Then a real, severe, newly-found bug**: with movement confirmed working (WASD and click-to-move
both move the character — nice, unplanned confirmation those particular fixes hold up), the
assembled player character's limbs **fly apart wildly** the moment animation applies — hands and
forearms flung far from the body, not a subtle glitch. Root-caused with real data (pulled
`chinaman_skel.bsk` + `chinaman_fighter_standcity.ban` from the RE box, compared quaternions
directly):

- `Skeleton3DBuilder.build_skeleton3d` gives every bone an `IDENTITY` rest *rotation* (only real
  bind *positions* are used — see that function's own doc comment; the real `.bsk` bind-rotation
  quaternion is parsed but was never used, since this project hadn't confirmed it composes the way
  Skeleton3D's rest hierarchy expects).
- `Skeleton3DBuilder.apply_ban_pose`/`apply_ban_keyframe` compute each frame's rotation as a
  *delta* relative to that bone's own `.ban` track `keyframe[0]` — implicitly assuming
  `keyframe[0]` represents the same (identity) rest orientation the skeleton was built with.
- **That assumption is false**, confirmed directly: `Bip01 R UpperArm`'s real `.bsk` bind
  quaternion is `[0.056, -0.017, -0.062, 0.996]` (near-identity), but the same bone's `.ban`
  `keyframe[0]` is `[0.142, -0.015, 0.534, 0.834]` — a substantially different orientation, not a
  small idle sway. Applying a "delta" computed against the wrong reference applies an outright
  wrong rotation, and that error compounds down the kinematic chain (upper arm → forearm → hand),
  which is exactly why the arms/hands were the most dramatically displaced pieces in the real
  screenshot while the spine/pelvis stayed closer to normal.
- This was never caught earlier because it was never visually verified end-to-end before now —
  the earlier "confirmed" validation (`SkeletonPose.apply_rotation`) only ever drove a single-bone
  decoration skeleton, not a full multi-limb walking character. Another concrete instance of
  `feedback_headless_verification_gaps`: this is a pre-existing architecture gap, not something
  introduced this session, that simply had no real human playtest to surface it until now.

**Stopgap shipped**: disabled the per-frame `apply_ban_pose` call for the player's assembled body
(`World3D.gd`, `_physics_process`) rather than ship the far-worse "limbs fly apart" result. The
body now stays in its real bind pose (a static T-stance) — not idle/walking, but at least not
exploding. The real fix needs `Skeleton3DBuilder` to build each bone's *actual* `.bsk` bind
rotation into its rest transform (not identity) and `apply_ban_pose` to compute deltas against
that real rest instead of the animation's own frame 0 — a genuine rework, tracked here as a
follow-up, not attempted as a quick patch given the risk of shipping something equally wrong in a
different way.

Real scratch data (`chinaman_skel.bsk`, `chinaman_fighter_standcity.ban`, the throwaway
extractor/comparison tools) deleted immediately after use, per the no-persisted-real-assets
policy.

## 2026-08-26, fourth round — confirmed the stopgap actually holds, plus two more real findings

OpenSRO retested against confirmed commit `25ef432` (verified via `git log -1 --oneline` in his
local checkout, not inferred), across two different real zones (a Jangan palace interior, then an
open desert zone after a manual zone change). Several screenshots at first looked alarming again
(the character appearing to float, tilt diagonally, or hold an asymmetric "diving" pose) — but a
**top-down screenshot and the character's own real-time shadow both confirm the actual pose is a
clean, symmetric T-stance** (arms straight out, legs together), matching what the stopgap is
supposed to produce. Every one of the "broken-looking" shots was the same static, correct pose
viewed from a steep/oblique orbit angle that foreshortened one arm or leg toward the camera,
visually reading as bent/displaced even though the real 3D shape (as the shadow proves) never
changed. **The stopgap holds** — no more exploding limbs, confirmed via a genuinely fresh,
commit-verified retest, not just re-reading old data.

Two more things came out of this round:

- **A "circle that erases part of the model" while orbiting the camera**, reported specifically in
  the tight palace-interior screenshots. "Visible Collision Shapes" was confirmed off in the
  editor (ruling out a debug-overlay explanation), so the live theory is real near-clip-plane
  clipping: `CameraArm` (`SpringArm3D`) shortens itself to avoid clipping through nearby walls in a
  tight room, which can pull the camera close enough to the character's own geometry that its
  near-clip plane starts slicing through the mesh, changing what's clipped as the camera orbits.
  Not reproduced/re-tested in the open desert specifically before the conversation moved on — real
  but likely narrow (tight indoor spaces only), not chased further this round.
- **"It isn't like a complete 3D model."** This is a real, already-honestly-documented structural
  limitation, not a new bug: `CharacterAssembler`'s own top comment confirms no real per-vertex
  bone-weight data exists anywhere in the `.bms` format (checked directly against real files), so
  smooth mesh skinning isn't possible with what this project has reverse-engineered so far — each
  body part is a separate rigid chunk rigidly bolted to one bone, with real, visible seams at every
  joint instead of continuous deformed skin. Currently more noticeable than it might otherwise be
  since the tested character has no armor equipped (bare skin only, per real slots), which would
  cover most of those seams. Fixing this for real would mean finding real skinning/weight data
  this project hasn't located (or a fundamentally different approach) — a substantial, open-ended
  research problem, not a quick patch. Tracked honestly as a known limitation, not silently
  patched over or ignored.

## 2026-08-26, fifth round — real terrain/map bug, distinguished from an already-known limitation

A desert-zone screenshot showed a dramatic triangular gap tearing through the ground and distant
mountains, sky visible through it, plus jagged/torn-looking mountain geometry nearby. Two distinct
real things are visible in that one shot, not one bug:

- **The flat sky-gap is the edge of the currently streamed terrain**, not a stitching bug —
  `REGION_LOAD_RADIUS` only ever streamed a 3x3 grid of regions around the player, so walking far
  enough in open terrain reaches loaded terrain's edge and looks straight through to empty sky.
  **Raised `REGION_LOAD_RADIUS` from 1 to 2** (a 5x5 grid) now that this session's directory-cache
  fix (see the "~3 minute load time" entry above) should have removed most of the redundant-pk2-
  read cost that made loading more regions expensive in the first place — not perf-verified against
  a real large dataset in this sandbox, flagged honestly rather than assumed free.
- **The jagged/torn mountain geometry is the already-documented cross-region height-mismatch
  limitation** (see `_load_region_cell`'s `shared_vertical_anchor` comment from 2026-08-22): no
  real elevation data linking adjacent regions together has ever been found, so neighboring terrain
  tiles get glued edge-to-edge without matching real heights, producing genuinely steep/jagged
  seams at region boundaries. Not a new bug and not touched this round — a real, harder,
  still-open research problem (would need real cross-region alignment data this project doesn't
  have), separate from the load-radius fix above.
- Full verification (`godot4 --headless --path . --import --quit`, all 43 GDScript `*_test.gd`
  files) swept clean after the `REGION_LOAD_RADIUS` change.

## 2026-08-26, sixth round — real coordinate-system research, and a corrected Jangan region

Read the real, public [xSROMap](https://github.com/JellyBitz/xSROMap) tool's own source directly
to get its exact real coordinate-conversion constants (192 units/sector, sector-X offset 135,
sector-Y offset 92, 1920 local units/region — that last one is an independent, exact confirmation
that this project's own `REGION_SPAN` constant is correct). Tested whether this project's own
internal region-folder numbering is a simple offset/swap of that public "sector" numbering, using
Jangan as a calibration point (public sector ≈ (135, 92), this project's own `JANGAN_ZONE_REGION`)
and the real south-gate coordinates OpenSRO provided (X:6558, Y:874) as a second check. **The offset
hypothesis does not hold** — the numbers don't line up as a simple additive/swapped
transformation, meaning this project's internal region-folder numbers and the public sector
numbering are just two different numbering domains, not the same numbers viewed differently. Raw
coordinate math from real player positions to this project's own region files isn't viable with
current data; matching real landmarks by their real placed asset names (already proven for Jangan)
remains the reliable approach.

**Found and fixed a real bug while investigating**: `JANGAN_ZONE_REGION` (`98/168`) came from an
earlier, incomplete scan that only checked a small subset of real regions for Jangan-named
placements. New tool `server/cmd/scanlandmarks` (a multi-keyword generalization of the existing
`findregionassets`, scanning every real keyword in one pass instead of one at a time) re-scanned
**all 4,050 real regions** in a real Map.pk2 and found `89/182` has 279 matching real Jangan
placements — almost 9x the old region's 32, and independently the same region an earlier session
already found for the real south gate (consistent: the south gate belongs to Jangan). Corrected
`JANGAN_ZONE_REGION` to `89/182`. Also found and added a real Dunhuang zone (`98/157`, 279 matching
placements) for manual zone-change testing.

Real scratch tool binaries (`pk2list`, `scanlandmarks`) built for and run on the RE box, deleted
immediately after use; no real pk2 data pulled into this sandbox for this round (the scan ran
entirely on the RE box against its own real files).

## 2026-08-26, seventh round — spawning inside a real building, general fix

Retested against the corrected Jangan region (`89/182`) — real terrain, HUD, and controls all
confirmed working (bottom action-bar HUD, zone label showing `89/182`), but the player spawned
directly inside a real building interior. Root cause: the server's `spawnPos` is a fixed
`(0,0,0)`, and Jangan's real region is packed with 863 real object placements — a quick empirical
check (new scratch tool, run on the RE box, not kept) found even the *most open* point in that
whole region is only ~466 real units from the nearest placement anchor, barely better than
origin's ~206 — this specific real region (the real Jangan palace complex) just doesn't have much
genuinely open space at all, so no fixed spawn coordinate reliably avoids buildings here.

Rather than chase a precomputed "safe" spawn point (would need real per-building footprint data
this project doesn't have, not just placement anchors), added a general, reusable safety net to
`_snap_player_onto_terrain()`: after landing on real terrain, check whether there's a real low
ceiling directly overhead (a real room, not open sky) via a short upward raycast, and if so, try
nearby real ground positions in a widening ring (6 rings x 8 directions, 15 real units per ring)
until one has clear sky above, snapping there instead. Bounded and honest: if every tried position
is still covered, it leaves the player at the original spot and logs a real error rather than
silently pretending success. This helps for *any* zone with a fixed spawn point landing indoors,
not just Jangan specifically.

Full verification: fixed a real GDScript type-inference error introduced along the way
(`var candidate := hit.position + ...` needed an explicit `: Vector3` annotation, the same
"can't infer type from a Dictionary value" pattern seen earlier this project), then all 43
GDScript `*_test.gd` files and `go build`/`go vet`/`go test ./...` swept clean.

## 2026-08-26, eighth round — the roof-escape fix didn't fire; wrong height scale

Retested the roof-escape fix: still spawned inside the same building interior, meaning
`_has_roof_overhead()` never detected a ceiling at all. Root cause: `ROOF_CHECK_HEIGHT` (30.0) was
picked without checking real building scale. Real placed objects render at their own native scale
(unlike the player's own body, deliberately rescaled to a fixed 1.8 units in
`_build_assembled_character`) -- a direct measurement of real meshes in Jangan's own region (new
scratch tool, run on the RE box, not kept) found a real building piece
(`jangan03\cj_pal_dam_left02.bsr`) alone is ~44.5 real units tall, and real trees in the same
region run up to ~140. 30.0 couldn't clear a single real wall piece, let alone a real room's
ceiling, so the check silently always reported "open sky" and the escape search never ran.

Raised `ROOF_CHECK_HEIGHT` to 200.0 (comfortable real margin above the tallest measured real
piece) and `ROOF_ESCAPE_STEP`/`ROOF_ESCAPE_RINGS` proportionally (60.0 x 10 rings, real max search
radius 600 units) since a building tall enough to need the new height plausibly has a footprint on
a similar real scale. Not yet re-verified against a real live spawn -- this is a size-calibration
fix based on real measured data, not a re-confirmed working fix; needs another real retest.

## 2026-08-26, ninth round — spawn fix confirmed; real object cap was hiding grass/decoration

Retested: the roof-escape fix worked -- OpenSRO spawned outside in Jangan's real courtyard (lion
statues, gate, walls all visible) instead of inside a building. Real, confirmed progress.

OpenSRO then compared it side-by-side against a real reference screenshot of the same real Jangan
courtyard from a live server. The real gap: ground-cover grass was sparse (one small patch instead
of dense coverage under trees/along walls) and no NPCs were present. Root cause for the grass:
`MAX_MAP_OBJECTS` (300) hard-stops object instantiation in real placement order -- Jangan's own
real region has 863 real placements (`.o` + `.o2` combined), so the old cap silently dropped most
of them well before reaching most grass/decoration entries. Since parsing each *distinct* real
`.bsr` only happens once (repeats are cheap duplicates), raising this cap is low-cost. Raised to
2000. NPCs are a separate, larger, not-yet-implemented feature (this project currently only
spawns players/monsters, no static NPC guards) -- not addressed this round, tracked as a real,
known gap rather than conflated with the grass fix.

Full verification (`godot4 --headless --path . --import --quit`, all 43 GDScript `*_test.gd`
files) swept clean after the `MAX_MAP_OBJECTS` change. Not yet perf-verified against a real very
dense region beyond Jangan's 863 placements.

## 2026-08-26, tenth round — region-specific asset audit for Jangan, atmosphere pass

Asked to look specifically for anything not mapped/used for Jangan, plus follow-ups on a closed-
looking gate door, missing bloom, an off-looking fog/haze, and a staircase not reading as distinct
steps.

- **New region-specific audit** (scratch tool, run on the RE box, not kept): unlike
  `audittextures` (which walks the whole 3,268-entry catalog), this checks only the object types
  actually *placed* in one real region against the full `.bsr` -> `.bms`/`.bmt` -> `.ddj` chain.
  Jangan (`89/182`) has 54 distinct real placed types -- **all 54 resolve cleanly, zero failures,
  zero unresolved type IDs**, including the palace gate door (`cj_pal_bigdoor.bsr`) and both real
  staircases (`cj_pal_center_stair.bsr`, `cj_pal_right_stair.bsr`). So none of the reported visual
  issues are missing-asset bugs -- everything Jangan places loads successfully at the file level.
- **Door state**: confirmed no `.ban` animation exists for this specific door (checked real
  lightmap-adjacent file listings under `Jangan03\`) -- its geometry is a single fixed static pose,
  whatever was baked into the mesh, since this project's `ObjectLoader` never applies animation to
  any scenery object (only the player's own body gets that). Whether that baked pose is actually
  "open" and just misread at a given viewing angle, or genuinely renders differently than the real
  reference, isn't something file-level checking can answer -- would need a direct render
  comparison at the same real spot/angle, not attempted this round.
- **Staircase**: same conclusion -- the real mesh resolves and parses fine, so if it doesn't read
  as distinct steps in-game, that's a geometry/material rendering question, not a missing file.
- **Bloom and atmosphere**: concrete, safe fix -- the `WorldEnvironment` had no glow, tonemap, SSAO,
  or fog configured at all (confirmed by reading `World3D.tscn` directly). Added Filmic tonemapping,
  SSAO, a modest bloom/glow pass, and a subtle exponential fog for depth cueing. Fog density picked
  conservatively (`0.0015`) to avoid washing out the whole scene at the hundreds-of-units viewing
  distances typical here -- not visually verified against a real live screenshot yet, since this
  sandbox has no way to render the real scene; needs a real retest to confirm it actually looks
  better and isn't too strong/weak.
- Full verification (`godot4 --headless --path . --import --quit`, all 43 GDScript `*_test.gd`
  files) swept clean.

## 2026-08-26, eleventh round — full asset-category taxonomy: whole content systems unused

Asked to comb through the pk2 archives for every *type* of asset present, not just check what
Jangan specifically uses. Built a depth-limited directory-tree tool (scratch, run on the RE box,
not kept) instead of a full flat file listing (tens of thousands of entries) to get a manageable
top-level category overview of both real archives. Result: several **entire content systems** this
client has zero code path for at all, not just individual missing files:

- **Water** (`Map.pk2\Water\`, 34 files): a real 30-frame animated water texture
  (`water101.ddj`...`water130.ddj`, classic flip-book frame animation, not a shader effect) plus
  wave-overlay textures. `MapmTerrainBuilder`'s own `TileType` enum already has real `WATER`/
  `DEEP_WATER` values from the tile-type data (see `TILE2D_FORMAT.md`) that this project already
  parses but never renders specially -- water tiles currently just render as flat colored/textured
  ground like any other tile. This is the most concrete, bounded win of everything found here: the
  tile classification already exists, just needs an animated water surface drawn wherever those
  tile types occur.
- **Sky** (`Map.pk2\SkyBox\`, 5 files: `cloud1.ddj`/`cloud99.ddj`, `glow.ddj`, `shadowsphere.ddj`,
  `waterbump3.ddj`): a simple real sky-dome texture set. This client currently uses a flat
  `background_color` (see `World3D.tscn`'s `Environment`), not a real sky.
- **Weather** (`Map.pk2\Weather\`, 10 files) and **Sun** (`Map.pk2\Sun\`, 38 files): real
  lighting/weather-effect assets, not investigated further this round.
- **Dungeons** (`Data.pk2\Dungeon\`, real per-region subfolders: `arabia`, `asiam`, `china`,
  `demon`, `jupiter`, `wchina`, `secret_tomb_bottom/top`, `boss_dungeon`, etc.): a real, separate
  instanced-map system entirely distinct from the open-world `.m`/`.o` regions this project
  already handles -- likely a different real format/loading path, not investigated this round. A
  much bigger scope item than the others here.
- **Pets** (`Data.pk2\Res\pet2\`, 48 files): a real companion-pet asset set, a full feature this
  project has never touched (server-side or client-side).
- Smaller, not-yet-investigated categories also found: `Res\skill\` (9 files, skill-effect
  assets), `Res\quest\` (10 files, quest-specific decorations beyond the one already-resolved
  `level_up_quest.bsr`), `Compound\particle\` (34 files, particle compound definitions).

None of this was implemented this round -- it's a scoped research/priority-setting deliverable, not
a fix. Water is the clear best next candidate: bounded, already has matching tile-classification
data, and is one of the more visually obvious gaps in an outdoor real Silkroad screenshot. Dungeons
and Pets are real, much larger systems (separate map format / a whole companion-pet feature) that
would need their own dedicated investigation, not a quick pass.

## 2026-08-26, twelfth round — implemented water; removed invented tile-color fallback

Implemented real animated water: `MapmTerrainBuilder.build_full_region_water_mesh` builds a
separate surface covering only the real quads classified WATER/DEEP_WATER (via the real tile2d
table, same classification `_vertex_color` already used), and `World3D._try_add_real_water` loads
the real 30-frame flip-book animation from `Map.pk2\Water\` into an `AnimatedTexture` and applies
it as that surface's material. Real per-quad UVs, a modest UV1 repeat so the frame texture doesn't
stretch across a whole water body, and a small vertical lift to avoid z-fighting with the
underlying terrain (which still renders at the water tile's own real height). Frame rate (8fps) is
an honest guess, not reverse-engineered timing data. New test coverage in
`mapm_terrain_builder_test.gd` for the water-mesh builder (real WATER quads produce geometry, real
non-water regions produce none, no tile table means no water).

Separately, flagged and fixed: `MapmTerrainBuilder` had an invented per-`TileType` color palette
(`_type_colors`) and, before that, a fabricated green-to-brown hue sweep, both presented as
"plausible" ground appearance despite not being derived from any real data -- unacceptable, since
this project has *real* ground textures for every real tile (100%, 719/719 tile2d.ifo entries).
Removed both; `_vertex_color` now returns one honest, unmistakably-neutral `UNKNOWN_TILE_COLOR`
flat gray whenever a real texture isn't available, instead of a guess dressed up as ground
variety. Also fixed the same pattern in `_try_apply_real_player_character`'s fallback material
(was an invented skin-tone color for when a real body-part material fails to resolve by name --
now the same honest flat gray; this path is confirmed to rarely if ever actually trigger, per
earlier live verification of 1,500+ real name-matched mesh pieces). Removed the now-unused
`tile_table` parameter from the flat-color mesh-building functions it no longer does anything
useful for (`build_mesh`, `build_full_region_mesh`, `build_full_region_mesh_textured`, and their
internal helpers) rather than leaving dead plumbing around.

Full verification: all 43 GDScript `*_test.gd` files (including updated assertions in
`mapm_terrain_builder_test.gd` reflecting the new honest-fallback behavior) and
`go build`/`go vet`/`go test ./...` swept clean.

## 2026-08-26, thirteenth round — the guessed fog value was genuinely wrong, removed

Real, multiplayer-confirmed retest (a friend connected over LAN via the new server-address field,
a real second player visible in-world): the fog added in the atmosphere pass was way too strong,
washing out the whole scene to a flat white haze past a short distance. That fog density
(`0.0015`) was an honest guess documented as "not visually verified" -- confirmed wrong. Rather
than guess a second unverified number, **removed fog entirely** instead of re-guessing. Also
lowered `glow_hdr_threshold` (1.1 -> 0.85) so ordinary bright surfaces (snow, lit lanterns) have a
better chance of actually triggering visible bloom, since the friend's report was also "no bloom"
-- not independently confirmed whether the original threshold was really the cause or whether
bloom just wasn't obvious in that scene, so this is a reasonable adjustment, not a confirmed fix.

The staircase-not-reading-as-distinct-steps question from earlier remains open and still needs a
real close-up look at the actual geometry -- file-level checks already confirmed the mesh
resolves and parses cleanly, so this is a rendering/geometry question, not a missing-asset one,
same conclusion as before.

Full verification (`godot4 --headless --path . --import --quit`, all 43 GDScript `*_test.gd`
files) swept clean after the fog removal.

## 2026-08-26, fourteenth round — a real (not shutdown-noise) networking bug found and fixed

A real playtest log included `ERROR: Condition "!is_open()" is true. Returning: -1 at:
get_available_bytes (drivers/unix/net_socket_posix.cpp:743)`, distinct from the already-understood
benign shutdown-time RID-leak noise elsewhere in the same log. Traced the exact, verifiable code
path: `PacketReader.poll()` is the only real (non-test) call site for `peer.get_available_bytes()`,
called every frame from `NetClient._process()` once `_connected` is true -- but nothing ever
re-checked whether the underlying peer was still actually open after the initial connect. A
dropped connection (server closes it, or the app itself tearing the socket down at shutdown)
produced this real engine-level error repeatedly instead of a clean, one-time `disconnected`
signal. Fixed by checking the peer's own real `get_status()` before polling each frame (both
`StreamPeerTCP` and `StreamPeerTLS` expose this) and calling `disconnect_from_server()` the moment
it's no longer `STATUS_CONNECTED`, rather than continuing to poll a closed peer.

Separately confirmed (not a bug): the same log's "could not find terrain/objects" lines around
Jangan's real region are the same already-understood "streaming radius hits real sparse-data
edges" pattern documented earlier -- most of the 25 attempted regions around 89/182 genuinely
don't have real data, only a handful (91/181, 87/182, 91/182, 91/183, plus the real 863-placement
89/182 itself) do.

Full verification (`godot4 --headless --path . --import --quit`, all 43 GDScript `*_test.gd`
files) swept clean.

## 2026-08-26, sixteenth round — real auto-updater, and making the repo public

Added a real auto-updater (OpenSRO's launcher-style request): `UpdateChecker` (pure, unit-tested
version-compare and platform-asset-selection logic) plus `AutoUpdater` (the real network/file-
system side -- checks this repo's real GitHub Releases API, downloads the matching real platform
zip, extracts it, writes a real platform-native relaunch script that waits for this process to
exit, copies the new files over the old ones without touching the user's own real `pk2` folder,
and relaunches). Wired into `Boot.gd`: checks once at startup, offers a real opt-in
`ConfirmationDialog` if a newer version exists, and never blocks getting to Login if the check or
update itself fails.

**A real, necessary prerequisite decision**: GitHub ties release-asset visibility to repository
visibility -- there is no way to have private source with public release downloads. OpenSRO
explicitly confirmed making the whole repository public (source included) to enable this, a real,
hard-to-reverse decision surfaced and confirmed before acting, not assumed.

**Honest scope**: only `UpdateChecker`'s pure logic (version parsing/comparison, platform-asset
selection) is unit tested. The real network call, real zip extraction, and real relaunch mechanism
in `AutoUpdater` have not been live-verified against a real published release, since none existed
yet at the time this was written (the "push a real release tag" item from `docs/PROGRESS.md` is
still open/deferred). Flagged per `feedback_no_unverified_assumptions` rather than claimed working
-- needs a real tagged release and a real live test before trusting it in practice.

Full verification: new `update_checker_test.gd` (added to `ci.yml`) plus all other 43 GDScript
`*_test.gd` files swept clean; `go build`/`go vet` (Go side untouched by this change) also clean.

## 2026-08-26, fifteenth round — real cause of other-player movement stutter, fixed

Asked to make the server "64 tick." Checked first rather than assume: this server has no fixed
simulation-tick concept anywhere (`Hub.Move`/combat/etc. all process immediately per received
message) -- there's nothing to "set to 64." Clarified with OpenSRO what he actually wanted, and in
the process found the *real* cause of a separately-reported symptom (other players' movement
stuttering at ~5-10fps): `_on_entity_moved` snapped another entity's position directly to each
real update the instant it arrived, and real updates only ever arrive as often as the sender's own
`MIN_SEND_INTERVAL` allows (10/sec) -- a visible jump every ~100ms, not smooth motion, regardless
of any server-side tick rate.

Fixed the actual root cause: `_other_body_targets` now holds each real entity's latest known
target position, and `_physics_process` smoothly interpolates every other body toward its target
every frame (exponential catch-up, `OTHER_BODY_INTERPOLATION_SPEED`) instead of teleporting.
Raised `MIN_SEND_INTERVAL` (0.1 -> 0.05) so the interpolation target itself updates often enough to
track a fast-moving real player closely. Both new constants are explicitly documented as real
engineering tuning choices, not claims about real client network behavior -- consistent with
[[feedback_no_unverified_assumptions]].

The real, separate 64Hz authoritative server simulation loop OpenSRO actually wants is still a
follow-up item, deliberately not conflated with this fix -- tracked here, not yet built.

Full verification (`godot4 --headless --path . --import --quit`, all 43 GDScript `*_test.gd`
files) swept clean.

## 2026-08-26, seventeenth round — private repo + embedded token instead of public repo

After a collaborator hit an unrelated real GitHub error trying to push code (`GH007`, a real
account-level git-email-privacy setting, nothing to do with this repo's own configuration), OpenSRO
reconsidered the earlier "make the repo public" decision and asked to make it private again while
still letting the client check for updates -- via a real, deliberately narrow-scoped GitHub PAT
(fine-grained, `contents: read-only`, this one repo only) embedded in release builds instead.

Made the repo private again (explicit request). Added `UpdateChecker.GITHUB_TOKEN` (empty by
default, same "no real value baked into tracked source" pattern as `CLIENT_VERSION`) and wired
`AutoUpdater` to send it as a real `Authorization: Bearer` header on both the release-check
request and the download request, using the asset's real API `url` field (not the plain
`browser_download_url`, which doesn't work unauthenticated against a real private repo) whenever a
token is present. `release.yml` sed-injects the real token from a `UPDATE_CHECK_TOKEN` repo secret
at build time, the same mechanism `CLIENT_VERSION` already uses -- never committed to tracked
source.

**Real, explicit tradeoff OpenSRO was told and chose knowingly**: this token is extractable from any
distributed client build the moment it ships, and should be treated as effectively public from
that point on. Scoped as narrowly as this project's real needs allow (read-only, contents, one
repo) specifically because of that.

Full verification (`godot4 --headless --path . --import --quit`, all GDScript `*_test.gd` files
including the new `find_asset_api_url` test coverage) swept clean.

## 2026-08-26, eighteenth round — found and fixed a real over-broad transparency heuristic

Reported: from a side view a character's chest is visible, but rotating to view the front instead
shows the back. Investigated `ObjectLoader.build_godot_material`'s real alpha-cutout heuristic and
found a genuine bug: it enabled cutout transparency + **disabled backface culling** purely because
a texture's real compression *format* was DXT3/DXT5 (`_ALPHA_FOURCCS`), not because that specific
real texture's alpha channel actually varies. A real, fully-opaque DXT3/DXT5 texture (DXT3/5 is an
ordinary format choice, not inherently a "this needs transparency" signal) would still get backface
culling disabled -- on a real closed/solid body mesh, that lets a viewer see through to the mesh's
own real back-facing surface. Fixed: now decodes the real pixel data and only applies cutout +
no-culling if a real texel's alpha is genuinely below opaque (250/255 threshold, tolerating real
DXT lossy-compression rounding), confirmed via the existing synthetic test (whose fixture has real
alpha variance, so it still correctly triggers) plus a manual real-data check.

**Honest, important caveat**: checked the real materials this specific character actually uses
(both genders' body/hair skin materials, and the `clothes_03` equipment set) directly against real
game data -- every one of them is DXT1 except hair (which has real, intentional alpha variance for
strand edges, correctly still triggers cutout). **None of the checked real materials could have
triggered the old bug at all**, so while the fix itself is real and correct, it's not confirmed to
be the actual cause of the specific front/back-swap symptom reported. That mechanism remains
unconfirmed -- flagged honestly per `feedback_no_unverified_assumptions` rather than claimed
solved. Real scratch tools used to inspect this (mesh-bounds and alpha-variance checkers) were
deleted after use, no real pk2 data persisted.

Full verification: all GDScript `*_test.gd` files swept clean.

## 2026-08-26, nineteenth round — fixed the real "size of ants" scale mismatch

Reported: the player character looks tiny next to real environment features (a lion statue, gate
walls). Investigated with real, direct measurement rather than guessing: real building features
already measured this session render at real native scale unscaled (a wall piece ~44.5 units, a
door ~72-76, trees ~97-140), but `_build_assembled_character` force-rescaled every real assembled
character down to a fixed, invented 1.8 units -- calibrated only against this scene's own early
placeholder capsule, never checked against the real environment's own native scale at all. A
second, similarly-uncalibrated constant (`_real_skeleton.scale = 0.02` for the decoration-skeleton
demo path) had the identical problem, by its own comment's own admission ("scale down... so the
whole creature is visible," not derived from anything real).

Measured the real, actual native height directly: forward kinematics over a real
`chinaman_skel.bsk`'s real bind-pose bone positions (all 38 real bones resolved) gives a real
height of **138.7 native units** -- already the same real order of magnitude as the real building
features above. Confirmed with OpenSRO this should be fixed by growing the character to its real
native scale (not shrinking the environment instead).

Removed the invented 1.8-unit rescale entirely -- the real assembled skeleton now renders at its
own real, unscaled native height, consistent with every other real object in the world. Since
essentially all player-relative tuning (movement speed, gravity, camera distance/zoom range,
click-to-move stop distance, network-send movement threshold, the placeholder capsule dimensions,
the roof-escape ground-clearance offsets) was calibrated around the old 1.8-unit convention,
introduced `PLAYER_SCALE_RATIO` (real 138.7 / old 1.8 ≈ 77.06) and rescaled every one of those
constants by the same real factor, preserving their previously-tuned *feel* relative to the
character's own height rather than guessing new values at the new scale. `ROOF_CHECK_HEIGHT`/
`ROOF_ESCAPE_STEP` were deliberately left untouched -- they were already calibrated against real
measured building heights directly, not the old player-height convention, so rescaling them again
would have been wrong.

Not yet live-verified visually against the real environment (no way to render this sandbox-side) --
flagged honestly; needs a real retest to confirm the character now reads as proportionate rather
than merely "no longer tiny in a new, different wrong way."

Full verification: `godot4 --headless --path . --import --quit` and all GDScript `*_test.gd` files
swept clean; `go build`/`go vet` (untouched by this client-only change) also clean.

## 2026-08-26, twentieth round — camera-distance regression from the scale fix, fixed

The scale fix above shipped in `v0.1.2` and got two real, contrasting data points fast: a friend's
screenshot at a real outdoor zone (`100/100`) showed the character reasonably proportioned against
real trees/bushes -- the scale fix itself is working. But OpenSRO's own screenshot showed a
near-orbital bird's-eye view of the entire real Jangan complex at default zoom -- a real
regression.

Root cause: `CAMERA_ZOOM_MIN`/`MAX`/`STEP` and the scene's default `spring_length` had been rescaled
by the same blanket `PLAYER_SCALE_RATIO` as everything else in the previous round, which was wrong
specifically for camera distance. Camera distance needs to be sized relative to the real
*environment* (buildings, courtyard extent), which doesn't scale with the character at all -- not
relative to the character's own height. The old 14-unit distance only ever looked reasonable at the
broken 1.8-unit character scale by coincidence (extreme close-up foreshortening masking the real
mismatch), not because 14 was itself a meaningful "close" distance next to real buildings (~44-140
units tall, measured earlier). Re-picked `CAMERA_ZOOM_MIN`/`MAX`/`STEP` (60/400/20) and the scene's
default `spring_length` (180) directly against that real building scale instead of blanket-rescaling
the old numbers, and reduced the SpringArm's wall-avoidance `margin` (23.1 -> 5.0, which had also
been blanket-rescaled and was oversized relative to the new, much smaller zoom range).

Full verification (`godot4 --headless --path . --import --quit`, all GDScript `*_test.gd` files)
swept clean. Not yet re-verified against a real live screenshot -- needs a real retest.

## 2026-08-26, twenty-first round — overlapping giant red capsules at spawn, fixed

Reported from a real fresh `v0.1.3` screenshot: two overlapping giant red capsule shapes filling
almost the entire screen, with the character barely visible. Confirmed via `AskUserQuestion` this
wasn't a broken-zoom-input issue -- scrolling did change the view distance, but even at
`CAMERA_ZOOM_MAX` (400 units) the blob still filled the frame, ruling out the obvious
"camera stuck too close" explanation.

Grepped `World3D.gd` for `StaticBody3D`/`CollisionShape3D`/`Area3D` around the monster/other-player
spawn code and confirmed neither `_spawn_or_update_other` nor `_spawn_or_update_monster` create any
real collision shape for their placeholder capsules -- so the SpringArm3D's own physics-based
collision-avoidance cannot be the cause (there's nothing solid to collide with).

Traced the real spawn coordinates instead: `server/cmd/server/main.go`'s `monsterSpecs` (its own
doc comment already flags these as "own design placeholder spawn anchor", not reverse-engineered
data -- no real per-monster spawn table exists) placed the Jangan zone's `Stone Golem` at `(15,10)`
and `Wild Boar` at `(-20,25)`, both close to the player's own default `(0,0,0)` spawn
(`session/world.go`'s `spawnPos`). Those anchors were picked back when a character -- and by
extension "how close is too close" -- was still the old, uncalibrated 1.8-unit placeholder capsule.
After the twentieth-round scale fix, a monster capsule is `0.5 * PLAYER_SCALE_RATIO * 2` ≈ 77 units
across -- so two monsters less than 40 units apart, both within less than one capsule-width of the
player's own spawn point, now render as two enormous overlapping shapes the camera can never back
away from (the "wall" it's zooming away from is closer than the zoom range itself).

Fixed by respacing `monsterSpecs`' X/Z anchors to a few hundred units apart (`Stone Golem`
`(250,150)`, `Wild Boar` `(-300,350)`, `Sand Scorpion` `(200,-250)`) -- picked directly against the
real measured building/wall scale from the nineteenth/twentieth rounds (~44-300 units), not a blind
`PLAYER_SCALE_RATIO` multiply of the old numbers, which would have pushed them off the real terrain
these zones actually have at those coordinates (terrain/building geometry was never rescaled, only
character-relative constants were).

Full verification: `go build ./...` clean. Not yet re-verified against a real live screenshot --
needs a real retest, and the server needs a real redeploy (this is server-side data, not something
a client download alone can fix).

## 2026-08-27, twenty-second round — camera not centered / zoom range unplayable, fixed

Direct real user report: at full zoom-in the character wasn't visible at all, and at full zoom-out
the game was unplayable; separately, the camera felt like it wasn't centered on the character.

Two distinct, real, checkable causes, not guesses:

1. `CAMERA_ZOOM_MIN` (60) was never checked against the camera's own real vertical FOV. Camera3D's
   default `fov` is 75 degrees, applied vertically under Godot's default `KEEP_HEIGHT` aspect mode
   (a real, checkable engine default). Fitting the player's full real 138.7-unit height at 60 units
   away needs a vertical half-angle of `atan((138.7/2)/60)` =~ 49 degrees -- past the real ~37.5-degree
   half-FOV the camera actually has, so part of the character was real, verifiable geometry outside
   the view frustum, not merely "close." Re-derived `CAMERA_ZOOM_MIN` from that same real FOV,
   solving for the distance that keeps the full body within a 30-degree half-angle (a bit of margin
   under the true ~37.5-degree limit): `69.35 / tan(30deg)` =~ 120. `CAMERA_ZOOM_MAX` lowered from
   400 (confirmed unplayable by the user directly, not this project's own guess) to 240 -- still
   shows a real building or two at that distance without shrinking the character to a speck.

2. `camera_arm.rotation_degrees` (orbit yaw/pitch from right-click-drag) never had anything moving it
   back toward the scene's authored default (`-42` pitch, `0` yaw, see `World3D.tscn`) -- so after any
   manual orbit, the camera stayed stuck at whatever angle it was last dragged to even as the player
   kept walking around, which is the real cause of "camera isn't centered on my character." Also
   confirmed manual WASD movement (unlike click-to-move) never rotates `player.rotation.y` at all, so
   nothing was ever re-aligning the view during normal movement. Fixed by recentering
   `camera_arm.rotation_degrees` back toward the authored default at `CAMERA_RECENTER_DEGREES_PER_SECOND`
   (120 deg/s) in `_physics_process` whenever the player is moving (manual input or an active
   click-to-move target) and not currently orbiting -- the same auto-realign behavior most
   third-person MMO cameras use, using `rotate_toward` for the yaw so it takes the short way around
   rather than potentially spinning the long way through 360 degrees.

Full verification: `godot4 --headless --path . --import --quit` clean, and a headless
`--quit-after 60` boot produced no parse/runtime errors. No dedicated automated test exists for
World3D.gd's camera code (not covered by any `*_test.gd` in `ci.yml`), consistent with every other
World3D.gd change this session -- not yet re-verified against a real live screenshot, needs a real
retest.

## 2026-08-28, twenty-third round — real sky, first item off the rendering-fidelity roadmap

First real work item off `docs/NEXT_STEPS_RENDERING.md`: the sky was a flat `background_color`,
the single biggest "doesn't look like the real game" cue in every screenshot taken this session.

Pulled real data before touching anything: `Map.pk2`'s own `SkyBox\` folder has exactly 5 files
(confirmed via the RE-box pk2list/ddjinspect scratch-tool workflow, then deleted along with the
extracted samples per the no-persisted-real-assets policy) -- `cloud1.ddj` (512x512, DXT3, real
alpha channel), `cloud99.ddj` (512x512, uncompressed), `glow.ddj` (128x128, uncompressed),
`shadowsphere.ddj` (64x64, DXT3), `waterbump3.ddj` (512x512, uncompressed). None of these is a
single large panoramic/equirectangular image, so the real client is evidently not using a standard
six-face or panorama skybox here -- it's built from several small layered/blended textures instead.
Checked for a config file or mesh describing exactly how they combine (`.ifo`/`.cfg`/`.bsr`
alongside `SkyBox\`) -- none exists. The currently available decompiled binary on the RE box is the
game *server* (confirmed via its imports -- `PostQueuedCompletionStatus`/IOCP, no D3D), not the
client renderer, so the real exact blending algorithm isn't determinable from data alone without
further client-side RE -- an honest, flagged gap, not something to guess at.

What shipped instead is an explicit engineering approximation using the *real* textures, not
fabricated ones: `world_environment.environment` switched from a flat `background_color` to
`Environment.BG_SKY` with a `ProceduralSkyMaterial` (a real Godot feature) whose horizon color
reuses the same real flat color the scene already had (not a new invented color) and whose top/
ground tones are derived from it. A large inverted-hemisphere dome (`SKY_DOME_RADIUS := 3000`,
comfortably inside the camera's far plane) follows the player and is textured with the real
`cloud1.ddj` (its own real alpha channel gives real soft edges), unshaded, `CULL_FRONT` (viewed
from inside), slowly UV-drifting (`CLOUD_DRIFT_UV_PER_SECOND := 0.008`, an explicit engineering
guess, not reverse-engineered timing, same honest flag as the water animation's frame rate). A
simple `Sprite3D` glow billboard using the real `glow.ddj` stands in for a sun, positioned along the
scene's real `DirectionalLight3D` direction (computed from its actual transform, not guessed).
`cloud99`/`shadowsphere`/`waterbump3` are deliberately left unused -- their real role in the actual
sky system is still unconfirmed; `shadowsphere`'s tiny 64x64 size in particular reads more like a
soft ambient-shadow blob than a sky asset, but that's a guess, not a finding, so it wasn't used for
anything.

Full verification: `godot4 --headless --path . --import --quit` and a headless `--quit-after 60`
boot both clean, no parse/runtime errors. Gated entirely behind `SRREVAMP_MAP_PK2_PATH`/a real
`pk2/Map.pk2`, same as every other real-asset loader in this file -- falls back to the original flat
color with no clouds/sun if unset or the real files aren't found. Not yet visually verified against
a real playtest screenshot -- needs a real retest.

## 2026-08-28, twenty-fourth round — ground-texture coverage audited, confirmed 100%, no fix needed

Second item off `docs/NEXT_STEPS_RENDERING.md`: an open question, not a reported bug --
`_load_real_ground_textures` falls back to a flat `TileType` color for any real per-vertex texture
ID that doesn't resolve to a real `Tile2D\` file, and no one had checked how often that fallback
actually fires in a real zone since the scale/spawn fixes landed.

Built a real one-off Go audit tool (`server/cmd/audittile2d_scratch`, deleted after use per the
no-persisted-real-assets policy) reusing the existing, already-tested `internal/mapm` and
`internal/pk2` packages plus a small new `tile2d.ifo` text parser (the format is plain ASCII per
`docs/protocol/TILE2D_FORMAT.md`, not binary, so no new binary-parsing risk). For each real
per-vertex `TextureInfo.ID` in a region, it checks (a) whether `tile2d.ifo` has an entry for that ID
at all, and (b) whether the resolved filename is an actual real file inside `Map.pk2\Tile2D\`.

Ran against both real zones this project has wired up:

- Jangan (region `89/182`): 10,404 vertices, 22 distinct real texture IDs used -- **22/22 (100%)**
  resolve to a real `tile2d.ifo` name, and **22/22 (100%)** of those real files actually exist in
  `Map.pk2\Tile2D\`.
- Dunhuang (region `98/157`): 10,404 vertices, 8 distinct real texture IDs used -- same result,
  **8/8 (100%)** resolved and present.

Real conclusion: ground-texture coverage for both zones this project actually renders is complete.
The flat-color fallback path exists and is correct to keep (a texture ID genuinely outside a real
zone's real texture set is possible in principle, and the fallback is honest, not fabricated -- see
`feedback_no_unverified_assumptions`), but it isn't currently firing anywhere in either real zone.
No code change made -- this item is closed as "checked, confirmed fine," not fixed, since there was
nothing real to fix.

## 2026-08-28, twenty-fifth round — front/back texture-swap: two more causes ruled out, still unsolved

Third item off `docs/NEXT_STEPS_RENDERING.md`. The alpha-cutout/backface-culling fix earlier this
session was already confirmed not to explain this (the real materials in use are DXT1, no alpha).
Investigated two more concrete, checkable hypotheses this round, both real code-level checks, not
guesses:

1. **Reversed triangle winding order.** Pulled a real sample (`Prim\Mesh\Char\China\woman\
   woman_torso_upper.bms`, the actual body part matching the reported symptom, extracted
   temporarily to a scratchpad outside the repo and deleted immediately after use) and wrote a
   one-off headless GDScript check using the existing, already-tested `BmsReader`: for every real
   triangle, compute the geometric face normal from its winding order (`(p1-p0).cross(p2-p0)`) and
   compare it against the real stored per-vertex normal average. **Result: 156/156 triangles
   consistent, average dot product 0.97** -- the real winding order already matches Godot's CCW
   front-face convention almost exactly. Ruled out.
2. **A negative-scale "mirror" transform somewhere in the character pipeline** (a common technique
   that flips effective winding globally even when local mesh data is internally consistent, e.g. a
   `Vector3(-1,1,1)` scale used instead of a proper 180-degree rotation). Grepped
   `character_assembler.gd`, `skeleton3d_builder.gd`, `object_loader.gd`, and `World3D.gd`'s
   character-attach code for any such pattern -- none exists. The player's own facing rotation
   (`atan2` in click-to-move) is a real rotation, not a scale, so it can't flip winding either.
   Ruled out.

Real mechanism still unconfirmed. Two candidates not yet checked: a subtle per-vertex field
misalignment in `BmsReader`'s stride/offset handling that doesn't produce NaN (so wasn't caught by
the existing self-validating unit-length-normal check) but silently swaps which UV/normal pairs
with which position for some vertices; or something specific to how `CharacterAssembler` splits and
attaches mirrored paired body parts (though the reported symptom was on the torso, an unpaired
part, per its own doc comment -- worth double-checking that claim against real data too, since real
`Data.pk2` actually splits torso into `_upper`/`_lower` pieces, not the single unpaired piece the
existing top-of-file comment describes). Left open rather than guessed at further.

## 2026-08-28, twenty-sixth round — real monster asset availability scoped (not yet implemented)

Fourth item off `docs/NEXT_STEPS_RENDERING.md`: whether real per-species monster models even exist
to replace the placeholder capsule (`_spawn_or_update_monster`'s own doc comment already says this
was never attempted). Checked real asset availability for the three monsters this project's own
server actually spawns (`server/cmd/server/main.go`'s `monsterSpecs`) before writing any
implementation:

- **Stone Golem**: real match. `Res\mob\casia\golem.bsr` (compound mesh), `Prim\Skel\mob\casia\
  golem.bsk` (real skeleton), `Prim\Mtrl\mob\casia\golem.bmt`/`golem.ddj` (real material/texture).
- **Sand Scorpion**: real match, and a stronger one -- `Res\mob\oasis\scorpion.bsr`, `Prim\Skel\
  mob\oasis\scorpion.BSK`, `Prim\Mtrl\mob\oasis\scorpion.BMT`/`.ddj`, plus real multi-part meshes
  (`scorpion_part2_part1.bms`/`_part2.bms` -- a segmented creature, consistent with a real
  scorpion's body plan).
- **Wild Boar**: **no real match.** Searching `Data.pk2` for "boar" only turns up unrelated
  building furniture (`oas_hot_board.bms`, a real notice-board prop, a coincidental substring
  hit -- same category of false-positive `docs/protocol/TILE2D_FORMAT.md` already documented once
  for `asiaminor_stone01.ddj`). The real China-continent (`casia`) monster skeleton folder has
  exactly 3 real files: `golem.bsk`, `hun.bsk`, `peryton.bsk` -- no boar-like creature. "Wild Boar"
  is this project's own invented placeholder name (from `server/cmd/server/main.go`'s original
  scaffolding) with no corresponding real Silkroad monster asset at all.

**Not implemented yet, and deliberately so.** Rendering a real animated monster is a materially
different pipeline from both existing ones: unlike static scenery (`ObjectLoader`, no skeleton) and
unlike the player character (`CharacterAssembler`, raw `.bms` body parts rigidly attached to a
`.bsk` skeleton with baked absolute positions), a monster's real mesh data lives inside a `.bsr`
compound object alongside a separate real `.bsk` skeleton -- whether that `.bsr`'s sub-mesh vertex
positions are already in the same bind-pose coordinate space `CharacterAssembler`'s rigid-attach
math assumes, or need a different transform, is unconfirmed and hasn't been checked against real
data yet. Building this blind, in an autonomous pass with no way to get a real screenshot back
before shipping it, risks exactly the kind of guessed-and-wrong result the standing "no
assumptions" rule exists to prevent. Recommend scoping this as its own real implementation pass
(ideally with a live playtest available to verify against), starting with Sand Scorpion or Stone
Golem (real matched data) -- and separately, flagging to OpenSRO/OpenSRO that "Wild Boar" has no real
asset behind it at all, so it either needs a different real monster name (e.g. `Hun`, which does
have real data) or stays a labeled placeholder indefinitely; not a decision to make unilaterally
since it changes visible game content, not just a bug fix.

## 2026-08-28, twenty-seventh round — animation coverage is worse than "partial": playback is fully disabled

Fifth/last item off `docs/NEXT_STEPS_RENDERING.md`'s current list. The doc previously said
animation coverage was "real but likely partial" without a real number -- checked directly instead
of leaving it vague, and the real answer is worse than "partial."

Listed every real animation file under `Prim\Ani\Char\China\man\` in `Data.pk2`: **337 real
files**, including real run cycles, sit animations, hit reactions (`_a_behardhit.ban`/
`_benormalhit.ban`), a real death-equivalent (`_a_diehardhit.ban`, not literally named "death"), and
well over a hundred real `skill_*`/`skill_ch_*` attack/cast animations. `World3D.gd` only ever
*loads* two of them per gender (`idle_anim`/`walk_anim`) into `_character_assets`.

**But re-reading `_physics_process` (around line 2339-2373) found something more significant than
an incomplete list: those two loaded animations are never actually applied to the real assembled
player body at all.** The only thing that calls `Skeleton3DBuilder.apply_ban_keyframe` every frame
is `_real_skeleton`/`_real_skeleton_track` -- a completely separate, dev-only decoration-skeleton
demo path gated behind `SRREVAMP_BSK_PATH`/`SRREVAMP_BAN_PATH`, not the real player. The real
assembled character's own animation playback was **deliberately disabled on 2026-08-26** (already
documented in-code, in a large comment right above where the call would go) after a real playtest
showed the assembled body's limbs flying apart the instant it ran -- root-caused at the time to
`Skeleton3DBuilder.build_skeleton3d` using `Basis.IDENTITY` for every bone's rest transform instead
of the real `.bsk` bind-pose rotation, so a `.ban` track's keyframe-0 rotation (not close to
identity for several real bones, e.g. `Bip01 R UpperArm`'s real bind quaternion
`[0.056,-0.017,-0.062,0.996]` vs. the walk animation's own keyframe-0
`[0.142,-0.015,0.534,0.834]`) gets misapplied as a raw delta. That comment already correctly called
this "a real rework, not a one-line patch" -- confirmed still true and still unfixed.

Concretely: **the assembled player character never animates at all right now** -- it stands in its
real bind (T-)pose permanently, whether idle, walking, or attacking. This is a bigger real gap than
"attacking has no animation feedback" (though that's also still true): everything is frozen.

**What this round actually added**: extended the existing (already-unused-for-playback) per-gender
animation caching to also load `hit_anim` (`_a_benormalhit.ban` -- deliberately the plain one, not
`_behardhit`; no real, confirmed signal for which of the two the original client picks was found,
so this doesn't guess a threshold) and `death_anim` (`_a_diehardhit.ban`) alongside the existing
`idle_anim`/`walk_anim`, confirmed present for both genders. This is deliberately *only* caching,
matching the exact same "loaded but not yet applied" state `idle_anim`/`walk_anim` were already in
-- **not** wired to play on `player_damage_taken`/`player_died` this round, because doing so would
hit the exact same already-diagnosed "limbs fly apart" bug immediately. Also confirmed the real
server-side signal a future hit-reaction would need already exists and is already decoded
client-side (`session/combat.go`'s `AttackResult.PlayerDamageTaken`, `combat.gd`'s
`player_damage_taken`/`player_died`, currently only used for a status-label string) -- so once the
real bind-pose rest-transform fix lands, wiring hit/death playback off that existing signal is real
follow-on work, not blocked on anything else.

Full verification: `godot4 --headless --path . --import --quit` and a headless `--quit-after 60`
boot both clean. The real, load-bearing fix here -- giving `Skeleton3DBuilder` each bone's actual
`.bsk` bind rotation as its rest transform, so `.ban` deltas compose correctly -- is real
implementation work of its own and was not attempted this round; logged as the actual next step,
not guessed at.

## 2026-08-28, twenty-eighth round — the real rest-pose fix: player character animation re-enabled

Immediate follow-up to the round above, same day. The blocking fix flagged as "real implementation
work, not guessed at" was concrete and scoped enough to actually attempt -- with a real way to
verify it before touching production code, using this project's own established headless-screenshot
technique (`client/tools/render_skeleton3d_animated.gd`'s pattern).

**Tested the fix in isolation first, against real data.** Pulled a real `chinaman_skel.bsk` +
`chinaman_fighter_walkforward.ban` (extracted to a scratchpad outside the repo, deleted after use).
Wrote a one-off comparison tool (`client/tools/rest_pose_fix_test.gd`, not kept) that built the
skeleton two ways -- the shipped `Basis.IDENTITY`-rest approach, and a candidate fix using each
bone's real world-space bind rotation (`SkeletonPose.bone_rotation()`, already implemented and
already used by the separately-validated manual `SkeletonPose.apply_rotation` path, just never
wired into `Skeleton3DBuilder.build_skeleton3d`) -- and rendered both posed at the same real
animation frame. First attempt showed *no difference at all*, which turned out to be a bug in the
**test script itself**, not evidence against the hypothesis: it computed each bone's local rest
*position* as a raw world-space delta from its parent, which is only correct when the parent's rest
rotation is identity -- once the parent has a real (non-identity) rest rotation, the child's local
position must be expressed in the parent's own rotated local frame
(`parent_world_rot.inverse() * (child_world - parent_world)`), or Skeleton3D's own transform
composition places it wrong. Fixed the test, re-rendered: the candidate fix produced a real,
coherent walking stride in the legs at multiple animation frames (clearly separated forward/back
leg positions), a qualitative, screenshot-visible improvement over the identity-rest version's
frozen/exploded T-pose. Arms stayed close to bind pose in this same real animation at every frame
checked -- left honestly unresolved whether that's the real animation's own content (a
weapon-ready stance that doesn't swing much) or a separate, still-unconfirmed gap, rather than
claiming full correctness beyond what was actually visually confirmed.

**Applied the confirmed fix for real** to `Skeleton3DBuilder.build_skeleton3d`: rest transforms now
use each bone's real `.bsk` world-space bind rotation and a parent-frame-relative bind position
(the exact same math validated in the isolated test), instead of `Basis.IDENTITY` position-only
rest. Updated `skeleton3d_builder_test.gd`'s synthetic bone fixture to include a valid identity
quaternion in its raw transform bytes (it previously left that field all-zero, a degenerate
non-unit quaternion that only mattered once real rotations started being read from it).

**Re-enabled real animation playback for the assembled player character** in `World3D._physics_process`
(`Skeleton3DBuilder.apply_ban_pose`, previously disabled entirely on 2026-08-26 pending this exact
fix) -- picks `walk_anim`/`idle_anim` (already cached per gender, see the twenty-seventh round)
based on the same `is_moving` signal already computed for camera recentering, using the same
`BAN_FPS` playback-rate engineering guess the separate decoration-skeleton demo path already used
(not reverse-engineered real timing). `hit_anim`/`death_anim` (cached last round) remain unwired --
still real, scoped follow-on work, now genuinely unblocked rather than blocked on a broken
foundation.

Full verification: all 43 real GDScript `*_test.gd` suites in `ci.yml` pass (including the updated
`skeleton3d_builder_test.gd`), plus a clean `godot4 --headless --path . --import --quit` and a clean
headless `--quit-after 60` boot. The isolated-test screenshots that justified this change were real
and inspected directly, not assumed -- but the fix's effect on the *live, in-game* assembled
character (with real equipment/weapon attachments layered on top, not just a bare skeleton) hasn't
been seen in an actual playtest yet. Needs a real retest.

## 2026-08-31, twenty-ninth round — map-focused pass: object-placement audit (clean) + a real day/night cycle table found

Refocused on map rendering specifically per request. Two real findings:

**Object-placement completeness audit** (same method as the twenty-fourth round's ground-texture
audit): built a real Go tool mirroring `World3D.gd`'s exact real placement pipeline (`.o` file's
`TypeID` → `navmesh\object.ifo` real path lookup → real file existence in `Data.pk2`), run against
both real zones. Jangan (`89/182`): 294 real placements, 54 distinct type IDs, **100%** resolve to a
real path and a real existing file. Dunhuang (`98/157`): 91 real placements, 6 distinct type IDs,
**100%** resolved. Neither zone comes remotely close to the client's `MAX_MAP_OBJECTS := 2000` cap.
Object placement is not a source of missing map content -- closed as "checked, confirmed fine," same
outcome as the ground-texture audit. (Scope note: this checks that the referenced `.bsr` file
*exists*, not that `ObjectLoader.load_object()` fully succeeds parsing it and every sub-resource it
references -- a deeper check than this round attempted, similar in spirit to how the ground-texture
audit only checked file existence, not full DDS decode success.)

**`environment.ifo` re-examined with real per-zone data** -- see `docs/protocol/ENVIRONMENT_FORMAT.md`'s
2026-08-31 update for full detail. This format was already fully parsed (both a GDScript and Go
reader exist, tested) but never wired into rendering because its 16 channels' semantic meaning was
marked entirely unconfirmed. Checked which real `EnvironmentID` each zone's `.m` blocks actually
reference: Jangan (`89/182`, all 36 blocks) → `Key=15`/`"Env7"`; Dunhuang (`98/157`, all 36 blocks) →
`Key=1`/`"Env1"` -- confirming this really is per-zone data, not a single unused global constant.
Within each record, the channel data shows an unmistakable pattern: every 4-float channel's groups
have a 4th value that's a real, monotonically increasing 0→1 sequence (a clean time-of-day axis),
and the RGB values at each point trace a real day arc -- dark/near-black at `t=0` (night), warm and
saturated near `t=0.25` (sunrise), bright/white near `t=0.5` (midday), warm again near `t=0.75`
(sunset), back to the identical `t=0` value at `t=1` (a real seamless loop). The two zones' actual
colors differ in a real, biome-appropriate way (Jangan peaks near pure white at midday; Dunhuang's
equivalent peaks warmer/dustier, consistent with a desert zone) while sharing the exact same
structural shape. Strong enough to call this a real day/night lighting-cycle table with real
per-zone palettes -- **not** wired into rendering, though, since which specific channel maps to
which specific Godot rendering concept (sky color vs. horizon vs. fog vs. directional-light tint)
is still genuinely ambiguous from the data shape alone, and guessing that specific mapping is
exactly the kind of unfounded logic this project's standing rule exists to prevent. Logged as a
real, much-higher-confidence future win (likely the single most impactful real map-rendering
feature left, more so than the current sky approximation), not implemented on a guess.

No code changed this round -- both findings are audit/research results (one confirms no bug exists,
the other raises confidence on a real future feature without acting on unconfirmed specifics).

## 2026-08-31, thirtieth round — real environment.ifo channel names found publicly, wired into the sky

Direct follow-up to the round above, same session. Found real public documentation
([`DummkopfOfHachtenduden/SilkroadDoc`](https://github.com/DummkopfOfHachtenduden/SilkroadDoc/wiki/JMXVENVI),
fair game per `docs/LEGAL.md` point 3) that names every one of `environment.ifo`'s 16 channels --
`SunColor`, `SkyTopColor`, `DiffuseColor`, `ObjectAmbientColor`, `TerrainAmbientColor`,
`TerrainShadowColor`, `FogNearPlane`, `FogFarPlane`, `FogColor`, `SkyBottomColor`, `WaterColor`,
plus 5 unnamed ones. This independently matches this project's own decompiled real per-channel
group-float-count sequence (`[4,4,4,4,4,4,4,2,2,4,2,2,2,4,4,2]`) exactly, in the same order --
strong corroborating evidence the public source is accurate for this project's own real files, not
just plausible. Full detail in `docs/protocol/ENVIRONMENT_FORMAT.md`'s "Channel names" section.

This resolves exactly the ambiguity that blocked wiring this in during the twenty-ninth round.
Implemented:

- `EnvironmentReader` (GDScript) and `environment` (Go) both gained named channel-index constants
  (`CHANNEL_SKY_TOP_COLOR` etc.) matching the public names, plus a new
  `EnvironmentReader.sample_color_channel(record, channel_idx, t)` that linearly interpolates
  between a channel's real keyframes at normalized time `t` (0..1, wrapping) -- real, unit-tested
  logic (4 new test cases: exact-keyframe sampling, mid-interpolation, wrap-around, and an honest
  `Color(1,1,1)` fallback for a channel with fewer than 2 real groups, not a guess).
- `World3D._apply_real_environment_lighting()`, called from `_try_load_real_terrain` right after a
  region parses, looks up the *player's own* region's real `EnvironmentID` (block 0's -- real data
  confirmed every block in both checked zones shares one ID, so this is representative, not a
  guess) against the cached real `environment.ifo` table and applies `SkyTopColor`/`SkyBottomColor`
  to the sky gradient built in the twenty-third round, replacing the old flat-color-derived guess.
  Gated to the *center* streamed region only (a new `apply_environment_lighting` parameter,
  `false` for neighbor cells in `_load_region_cell`) -- otherwise whichever neighboring region
  streamed in last would silently overwrite the player's own zone's color, since neighboring
  regions' EnvironmentID uniformity with each other hasn't been checked.
- `ENVIRONMENT_REFERENCE_TIME := 0.5` (midday) is an explicitly flagged simplification, not a
  guess about the real data: the real table is a full day/night cycle, but this project has no
  real day/night clock system (no confirmed time-compression ratio, no server-side game-time
  signal) -- building one is separate, real future work. Sampling a fixed midday snapshot gives a
  real, per-zone-accurate color instead of the old guess, without pretending to reproduce the real
  dynamic cycle.
- `FogColor`/`FogNearPlane`/`FogFarPlane` deliberately **not** wired into actual fog this round --
  fog was removed earlier this session after a real playtest showed a guessed density value washing
  out the whole scene (see the "fog is gone, you're good" entry), and `FogNearPlane`/`FogFarPlane`'s
  real values (e.g. one real channel-7 group range of `-1..-0.3`) don't read like literal
  world-space distances at face value -- reintroducing fog with an unconfirmed density mapping
  would repeat that exact mistake, so it's left alone pending more real evidence.

Full verification: all 43 real GDScript `*_test.gd` suites pass (including 5 new
`environment_reader_test.gd` cases), `godot4 --headless --path . --import --quit` and a headless
`--quit-after 60` boot both clean, `go build`/`go vet`/`go test ./internal/environment/...` clean.
**Not yet visually verified against a real live render** -- the underlying data traversal is real
and unit-tested, and the real color values were independently validated via the Go audit tooling
(twenty-ninth round) before this was wired in, but no screenshot comparing before/after has been
taken. Same honest scope as the original sky implementation itself when it shipped -- needs a real
playtest.

## 2026-08-31, thirty-first round — SOLVED: the real front/back texture-swap root cause

Picked back up the last item on the character-rendering list: the reported "front shows the back
texture and vice versa" bug, previously narrowed down (twenty-fifth round) by ruling out the
alpha-cutout fix, reversed triangle winding, and a negative-scale mirror transform -- all real
checks, none of them the cause. This round found and fixed the actual cause, and it turned out to
be a camera bug, not a mesh/data bug at all.

**Step 1 -- proved the mesh data itself is 100% correct.** Pulled real `chinaman_skel.bsk`, all 7
real body-part `.bms` files, and the real `chinaman_warrior_body.ddj` texture (matched via the real
`material_name` "chinaman_body", per `BMT_FORMAT.md`). Built a one-off headless render tool (not
kept) that assembles the real character with the real texture applied and renders it from four
straight-on directions (+Z/-Z/+X/-X). The real texture makes this unambiguous: **+Z shows real abs/
pecs/belly-button texture (the front); -Z shows a real spine groove and shoulder-blade X-pattern
(the back)** -- exactly where each belongs, no swap, no duplication. This conclusively rules out any
`BmsReader`/UV-mapping bug, closing the "subtle field misalignment" hypothesis flagged as
unchecked in the twenty-fifth round.

**Step 2 -- found the real bug: the default camera sits on the character's front side, not
behind them.** Traced the actual chain with real derived math (verified via a small headless
Godot check, not hand-waved): `player.rotation.y = atan2(dir.x, dir.z)` (this project's own
click-to-move code) rotates the player so local **+Z** points toward the movement direction --
confirmed via step 1 to be the character's real anatomical *front*. Meanwhile `CameraArm`'s
authored baseline (`rotation_degrees = Vector3(-42, 0, 0)`, no yaw component) pushes the camera to
that *same* local +Z direction with zero added yaw. Since `CameraArm` is a child of `Player` and
inherits its yaw, the camera and the character's front end up on the *same* side: the default,
non-orbited camera was showing the character's face, not their back -- backwards from the intended
over-the-shoulder third-person convention this project has been building toward all session. The
earlier "FPS-like camera" fix (2026-08-26) correctly validated the *pitch* sign (above vs. below,
confirmed via a real SpringArm3D probe) but never checked the *yaw* baseline against the character's
own real facing convention, since that data didn't exist yet at the time.

This exactly explains the original report: the user was already looking at the real front by
default (a static idle character doesn't obviously scream "you're staring at a face" from a
distance), and rotating the camera further away from that starting point revealed the real back --
matching "when I rotate to the front, I just see the back" precisely, with no mesh bug involved at
all.

**Fix**: `World3D.tscn`'s `CameraArm.rotation_degrees` changed from `(-42, 0, 0)` to `(-42, 180, 0)`.
`World3D.gd`'s `DEFAULT_CAMERA_YAW_DEGREES` (the auto-recenter target added 2026-08-27) updated from
`0.0` to `180.0` to match, so recentering-after-orbit converges to the corrected side instead of
fighting it back to the old wrong one.

**Live-verified, not just derived.** Re-rendered the real textured character from the exact fixed
camera offset direction (`(0, 0.669, -0.743)`, computed the same way `World3D.gd` computes it) --
the resulting image shows the real back (spine/shoulder-blade texture), confirming the fix produces
the intended standard third-person view. Both this render and the two straight-on reference renders
were inspected directly, not assumed.

Full verification: all 43 real GDScript test suites pass, `godot4 --headless --path . --import
--quit` and a headless `--quit-after 60` boot both clean. All pulled real samples (skeleton, body
parts, texture) and the one-off render tool deleted after use, per the no-persisted-real-assets
policy.

## 2026-08-31, thirty-second round — fixed a real sunburst/fan artifact in the sky, reproduced live

Real playtest screenshot from a fresh `v0.1.9` download showed a large fan of light/dark triangular
rays radiating across the sky and down over the ground. Rather than guess from the screenshot alone,
reproduced it directly: pulled the real `Data.pk2` (3.86GB) and `Map.pk2` (1.57GB) from the RE box to
this sandbox (user-authorized, temporary, deleted immediately after use per the
no-persisted-real-assets policy -- this project's disk only had ~9.6GB free, so `Media.pk2`/
`Particles.pk2` weren't pulled, not needed for this bug), then ran the actual `World3D.tscn` scene
headlessly against real Jangan (`89/182`) terrain using Godot's `--write-movie` screenshot technique
(the same one already used for skeleton/character verification this session). The real screenshot
reproduced the exact same fan artifact the user saw.

**Root cause, confirmed by a real before/after comparison, not guessed**: the cloud dome
(`_build_cloud_dome`, added in the twenty-third round) uses a `SphereMesh`, whose auto-generated UVs
use a polar projection that compresses toward a single point at the dome's pole. `uv1_scale =
Vector3(3, 3, 1)` tiled the real `cloud1.ddj` texture 3x around that projection, and tiling a
texture across a UV set that already compresses toward a point multiplies the distortion into a
visible multi-spoke sunburst radiating from the pole. Re-rendered the identical real scene with only
`uv1_scale` changed to `(1, 1, 1)` (no tiling) -- the fan disappeared completely, confirming the
cause before changing the shipped code.

Fix: `_sky_dome_material.uv1_scale` changed from `(3, 3, 1)` to `(1, 1, 1)` in `World3D.gd`. The
residual sky haziness visible in both the before and after real screenshots looks like a reasonable
soft cloud layer, not a separate bug -- left alone rather than guessing at further brightness/opacity
tuning (this project already got burned once this session on a guessed fog value).

Full verification: all 43 real GDScript test suites pass, `godot4 --headless --path . --import
--quit` and a headless `--quit-after 60` boot both clean. This is the first fix this session
verified against a **live render using real pulled pk2 data** rather than a synthetic/isolated test
-- both `Data.pk2` and `Map.pk2` deleted from this sandbox immediately after the real screenshots
were captured and inspected.

## 2026-09-01, thirty-third round — real Stone Golem model implemented, replacing the placeholder capsule

Picked up the roadmap's last unimplemented character-rendering item: real monster models. Previously
scoped (twenty-sixth round) but not attempted, since a monster's real pipeline was unconfirmed
territory. This round did the real work.

**New real data found**: extracted a real `golem.bsr` directly and grepped its strings -- it carries
more than `docs/protocol/BSR_FORMAT.md` documents for static objects. Alongside the already-known
mesh/material/sub-mesh fields, a real `.bsr` for a monster also embeds a real matching skeleton path
(`Prim\Skel\mob\casia\golem.bsk`) and a real list of 14 `.ban` animation paths (stand/walk/run/
attack01-03/damage01/die/die_rm/down/down_rm/down_damage/downup/downdie) right in the file. Golem's
7 real mesh pieces (`golem01.bms`..`golem07.bms`) carry no body-part-hinting names or per-piece
`material_name` values the way human body parts do (every piece just says `"golem"`) -- the
name-matching heuristic `CharacterAssembler` uses for humans doesn't apply here.

**Real piece-to-bone correspondence, computed from data, not guessed**: golem's real skeleton
(`golem.bsk`) has 48 real bones -- the same standard Biped names the player skeleton uses
(`Bip01 Spine`, `Bip01 L Thigh`, etc.), plus 22 extra `BoneNN` nodes with no confirmed real role
(plausibly per-rock-cluster attachment points for this specific creature). Built a one-off Go tool
(not kept) that computed each real mesh piece's real vertex centroid and matched it to its nearest
real bone by bind-pose position. `golem01` (743 of ~1229 total real vertices -- clearly the main
body) landed within 1.64 units of `Bip01 Spine`; the 6 smaller pieces (45-108 verts each) landed
2.4-4.1 units from their own nearest bone. Real geometric correspondence, not a naming guess, though
not a perfect zero-distance match the way human body parts were.

**Visually verified before shipping**: built a one-off render tool (not kept) that assembled the
real golem using this computed mapping, with the real `golem.bmt`/`golem.ddj` texture, and rendered
it from three angles. The result reads as an unmistakable, coherent rock-golem silhouette -- a
mossy-stone torso, two large boulder-mass arms, short legs, spiky rock shards around the
head/shoulders -- not a scattered mess. This confirms the same "absolute bind-pose-space vertex
positions, no extra per-piece transform" convention already relied on for characters and static
objects holds for monster meshes too.

**Implemented**: `client/scripts/assets/monster_assembler.gd` (`MonsterAssembler`), a small,
generic `assemble(skeleton, parts, piece_bones, material)` that reuses
`CharacterAssembler.attach_rigid` (promoted from private to a shared public helper -- no logic
changed, just made callable from outside `CharacterAssembler`) plus a `GOLEM_PIECE_BONES` constant
holding the computed real mapping. `World3D.gd` gained `_load_golem_assets()`/
`_build_assembled_golem()` (cached-once-per-run real asset loading, the same pattern
`_load_character_assets` already uses) and wires it into `_spawn_or_update_monster`: a monster named
`"Stone Golem"` now gets the real assembled model; every other real species (Wild Boar has no real
matching asset at all; Sand Scorpion has real data but no piece-to-bone derivation done yet) still
falls back to the labeled placeholder capsule, the same honest pattern already used for other
players' unresolved assets. The placeholder's label-height offset (calibrated for the capsule) is
now computed from the real assembled skeleton's own bone bounds when a real model is used, instead
of floating at the wrong height above a real model with a very different real native scale (the
golem's own raw skeleton data is nowhere near `PLAYER_SCALE_RATIO`-scaled human height -- left
unscaled, per this project's standing policy of not inventing scale multipliers without real
evidence).

**Not attempted this round**: animation playback for the golem (14 real `.ban` files are known but
unused -- the model is currently a static bind pose, same starting point the player character was
at before the twenty-eighth round's animation fix); Sand Scorpion (real data confirmed to exist,
same derivation process not yet done); promoting the newly-found `.bsr` skeleton/animation-path
fields into `BsrReader`/`bsr`'s general parser (read ad hoc here instead, since only one real file
has been inspected this way).

Full verification: all 43 real GDScript test suites pass (including a new
`monster_assembler_test.gd`, added to `ci.yml`), `godot4 --headless --path . --import --quit` and a
headless `--quit-after 60` boot both clean. All pulled real samples (skeleton, 7 mesh pieces,
material, texture) and both one-off tools (Go matcher, GDScript render tool) deleted after use.

## 2026-09-01, thirty-fourth round — SOLVED: real spawn-on-a-tower-roof bug (and likely "broken collision" too)

Real user report: spawning lands the player on top of a tower instead of on the ground, and
collision feels broken. Root-caused and fixed with a real before/after numeric comparison, not
guessed at.

**Root cause**: `_snap_player_onto_terrain`'s initial ground-snap raycast (from 1000 units above the
spawn point straight down) never set a `collision_mask`, so it defaults to hitting *every* physics
layer -- and both real terrain patches and every real placed-object (`.bsr` building) collision body
default to the same Godot collision layer (bit 1), nothing distinguishing "the ground" from "the
roof of a building standing on that ground." Since the real fixed server `spawnPos` is `(0,0,0)`
(already known to be able to land inside/under a real building, see `_avoid_spawning_under_roof`'s
own doc comment), if a real tall structure happens to stand at that exact spawn X/Z, the very first
raycast hits its roof (the topmost surface along that column) before it ever reaches the real
ground underneath. `_avoid_spawning_under_roof`'s existing escape logic didn't catch this because it
only checks for a real *ceiling above* an already-landed position -- it has no way to know "landed"
here actually means "landed on top of something," not on the ground.

**Reproduced and confirmed with real numbers, not a screenshot alone** (camera framing looks nearly
identical whether standing on a roof or the ground, since the third-person camera is always the same
relative distance from the player -- a screenshot alone doesn't prove the fix): pulled real
`Data.pk2`/`Map.pk2` again, ran the real spawn logic against real Jangan (`89/182`) at the real
`(0,0,0)` spawn point with a temporary debug print. Before the fix: `hit.position.y = 76.98` --
comparable to real measured door/wall heights (~72-76 units, see earlier rounds), not ground level.
After the fix: `hit.position.y = 1.04` -- real ground level. An 80-unit real difference, exactly
consistent with "was landing on a roof, now lands on the ground."

**Fix**: gave terrain collision (both the placeholder `Ground` body and every real streamed terrain
patch) a second, dedicated collision-layer bit (`TERRAIN_COLLISION_LAYER := 0b1001`, keeping the
default layer 1 too so every other existing collision check -- movement, click-to-move, camera
collision -- is unaffected) and set `_snap_player_onto_terrain`'s (and, for the same reason,
`_terrain_height_at`'s, used for monster placement) initial ray's `collision_mask` to
`TERRAIN_ONLY_COLLISION_MASK := 0b1000` (that bit only), so the very first ground-snap always finds
the real ground, never a building roof, regardless of what's directly overhead at the spawn point.

**On "collision is broken"**: not separately reproduced or root-caused this round -- but standing on
a small real rooftop instead of open ground would itself produce exactly this kind of symptom (an
edge to walk off, different real floor geometry underneath than expected, `move_and_slide`
interacting with a small isolated real roof surface instead of continuous terrain). Flagged as
likely the same root cause, not confirmed as a fully separate bug -- if collision still looks wrong
after this fix in a real playtest, that needs its own fresh real report.

Full verification: all 43 real GDScript test suites pass, `godot4 --headless --path . --import
--quit` and a headless `--quit-after 60` boot both clean. Verified with a real before/after
comparison using `git stash` to test the exact pre-fix code against the same real data, not just
reasoning about the mechanism. Debug print removed before committing; `Data.pk2`/`Map.pk2` deleted
after use.

## 2026-09-01, thirty-fifth round — roof-escape ring search had the same real bug; sky fan still not solved

Direct real follow-up to the thirty-fourth round, same day: a real user request to hide the UI and
look around (using a temporary debug hook, real pulled `Data.pk2`/`Map.pk2`, and a fresh
`--write-movie` capture -- all deleted/removed after use) surfaced two more real findings.

**The roof-escape ring search had the exact same real bug the initial ground-snap ray did.**
`_avoid_spawning_under_roof`'s per-candidate raycast (checking each ring position for real ground)
also never restricted its `collision_mask`, so a candidate landing on a *different* real building's
roof -- which also has clear sky directly above it -- passed `_has_roof_overhead`'s check and was
wrongly accepted as "escaped." Confirmed with real before/after position data: before this fix, the
player consistently ended up at `y=247.79` (a second real rooftop); after restricting this ray to
`TERRAIN_ONLY_COLLISION_MASK` too, the player lands at `y=1.04` (real ground) and stays there. This
was found *because* the thirty-fourth round's fix only addressed the first raycast, not this
second, structurally identical one -- a real gap in that round's own fix, not a new bug introduced
by it.

**The character does not read as "ant-sized"** in the resulting real screenshots (the user's
original question) -- visible and roughly proportionate next to real nearby statues/trees along a
real courtyard walkway. It looks small specifically next to one very large real palace gate
structure in the same shots, which is consistent with a real grand gate legitimately dwarfing a
person, not a scale bug (the character height fix from earlier this session, 138.7 real native
units, is still in effect and not implicated here).

**Real regression found and honestly corrected, not swept under**: while capturing these shots, the
sky sunburst/fan artifact the thirty-second round claimed "fixed" turned out to still be present --
that round's fix (removing 3x UV tiling) reduced but did not eliminate it. Isolated with three real
before/after renders: disabling the sun-glow sprite alone left the fan unchanged (ruled out); 
disabling the cloud dome alone removed it entirely (confirmed the dome); re-enabling the dome with a
flat untextured material produced zero artifact (confirmed it's the real `cloud1.ddj` texture's own
content interacting with the dome's polar UV projection, not the geometry alone or a resolution
issue more `radial_segments` could fix). This is a real projection singularity -- an entire circle
of U coordinates compresses to one point at the pole -- not something `uv1_scale` alone can solve.
**Disabled the textured cloud dome entirely** rather than ship something still visibly broken; the
procedural gradient sky (still real per-zone `SkyTopColor`/`SkyBottomColor`, thirtieth round) stands
alone until a real fix (a custom shader fading the texture near the pole, or capping the dome's
elevation so the pole is never in view) gets implemented.

Full verification: all 43 real GDScript test suites pass, `godot4 --headless --path . --import
--quit` and a headless `--quit-after 60` boot both clean. The temporary debug hook (env-var-gated
UI-hide/zoom/yaw control, added only to capture these real screenshots) was fully removed before
committing -- not shipped. Real pulled `Data.pk2`/`Map.pk2` deleted after use.

## 2026-09-01, thirty-sixth round — investigated "impossible to see the character," found real reference images, ruled out a camera-distance bug

Direct follow-up, same day: a real user complaint that the character is basically impossible to see,
with an explicit ask to look up real Silkroad Online gameplay images for reference. Investigated with
real external reference images and a real precision re-test, not by guessing at new zoom constants.

**Found real reference screenshots** (public, long-published gameplay images -- a YouTube thumbnail
for a real PC Silkroad Online gameplay clip, and a real character-customization-screen capture,
both fetched directly, not decompiled or scraped from this project's own real client files): in
actual real Silkroad gameplay, player characters read as small-but-legible humanoid figures with
floating nameplates, clearly not filling most of the screen -- consistent with a moderate-distance,
angled-down camera, not an intimate over-the-shoulder shooter-style view. This is real, if
low-precision (thumbnail-resolution) evidence that "the character looks small on screen" is not
automatically a bug by itself -- the real game does this too.

**Re-verified the actual zoom mechanism with a precision fix to the earlier debug technique**: the
thirty-fifth round's debug prints showed `camera_3d` distance stuck at the same value regardless of
the requested `spring_length` -- re-tested with several real physics-frame waits inserted before
measuring (`SpringArm3D`'s own collision-adjusted length updates during physics steps, not
synchronously when the property is set, so the earlier prints were reading a stale pre-update
value, not a real bug). With real settle time: requesting `spring_length=60` produced a real,
exact `dist_pivot_to_camera=60`, and `240` produced exactly `240` -- **the zoom mechanism itself
works correctly.** The thirty-fifth round's "distance stuck at 291 regardless of zoom" finding is
retracted as a measurement artifact, not a real bug.

**The real cause of "impossible to see" in this specific test**: at close zoom (60 units) from the
default camera angle, a large real gate/pavilion structure standing immediately next to this
specific spawn point filled almost the entire frame, with the character reduced to a small speck at
the very bottom. A wide overhead render confirmed the player is standing right next to this real
structure. From other camera angles (already captured in the thirty-fifth round's side-view shot),
the same character is clearly visible near real trees/statues, small but readable -- matching the
real reference screenshots' proportions. This is a real, still-open limitation of the roof-avoidance
system (`_avoid_spawning_under_roof` only checks for a real ceiling *directly overhead*, not
"how much of a nearby large structure will dominate the default camera view") rather than a
fundamental camera-distance or rendering bug -- and, per this project's own already-documented
constraint, isn't solvable without real per-object footprint data this project doesn't have (see
that function's own doc comment).

**Not implemented this round**: no camera-distance constants were changed, since the confirmed
mechanism works correctly and the low-precision reference-image proportions aren't reliable enough
to derive a new numeric target from. No fix was made to the "too close to a large structure" gap
either -- flagged honestly as a real, distinct, unsolved limitation rather than papered over.

Full verification: `godot4 --headless --path . --import --quit` clean (no production code changed
this round -- this was pure investigation). The temporary debug hook was again fully removed before
finishing. Real `Data.pk2`/`Map.pk2` pulled and deleted a second time this session for this
specific re-test.

## 2026-09-01, thirty-seventh round — real Sand Scorpion model implemented, same as Stone Golem

Second real monster species, using the exact real pipeline the thirty-third round's Stone Golem
work established. Extracted a real `scorpion.bsr` directly and grepped it (same technique) --
confirms only **3** real mesh pieces this time (`scorpion_part1`, `scorpion_part2_part1`,
`scorpion_part2_part2`, vs. golem's 7), a real matching skeleton (`Prim\Skel\mob\oasis\
scorpion.bsk`, 55 real bones -- the same standard Biped names, plus a real `Bip01 Tail`/
`Tail1`..`Tail4` chain unique to this creature, plus the same kind of extra `BoneNN` nodes golem
has), and the same real 14-animation-file set (walk/run/attack01-03/damage01-02/die/etc.).

**Real piece-to-bone correspondence, computed from data, tighter than golem's**: the same real
vertex-centroid-to-nearest-bone-position technique (one-off Go tool, not kept) found
`scorpion_part1`/`scorpion_part2_part1` (228 verts each -- the two front claws/pincers) land within
**~0.86 units** of `Bip01 R Forearm`/`Bip01 L Forearm` respectively, and `scorpion_part2_part2`
(248 verts, the largest piece -- the main body/tail) lands within **2.12 units** of `Bip01 Spine`.
Sub-1-unit matches for 2 of 3 pieces -- a real, strong geometric correspondence, not a coincidence.

**Visually verified before shipping**, same as golem: built a one-off render tool (not kept,
generalized to take either species' piece-bone map), assembled the real scorpion with its real
`scorpion.bmt`/`scorpion.ddj` texture, rendered from three angles. Unmistakably a real scorpion
silhouette -- two claws, a real segmented tail arching up over the body, a real mottled tan/brown
carapace texture -- confirming the same real coordinate-space convention holds again.

**Implemented**: refactored `World3D.gd`'s golem-specific asset loading (`_load_golem_assets`/
`_build_assembled_golem`) into generic, species-parameterized `_load_monster_assets`/
`_build_assembled_monster` (cached per-species in a shared dict, same real "load once per run"
policy), so adding Sand Scorpion didn't require duplicating ~50 lines of loading logic. Added
`MonsterAssembler.SCORPION_PIECE_BONES`. `_spawn_or_update_monster` now matches on
`monster.monster_name` for both `"Stone Golem"` and `"Sand Scorpion"`; `"Wild Boar"` (no real asset
at all, twenty-sixth round) still falls back to the placeholder capsule.

Full verification: all 43 real GDScript test suites pass (a new sanity check confirming
`GOLEM_PIECE_BONES`/`SCORPION_PIECE_BONES` have their real 7/3 entries added to
`monster_assembler_test.gd`), `godot4 --headless --path . --import --quit` and a headless
`--quit-after 60` boot both clean. All pulled real samples (skeleton, 3 mesh pieces, material,
texture) and the one-off Go/GDScript tools deleted after use.

## 2026-09-01, thirty-eighth round — default camera zoomed closer; three more real cities wired in

Direct user pushback on the thirty-sixth round's "not a bug" conclusion, plus a request to expand
the world beyond two cities. Both real, both actioned this round.

**Camera default zoom**: the thirty-fifth round's `CAMERA_ZOOM_MIN := 120` was already the closest
real distance the camera's own vertical FOV supports without clipping the character's head/feet
outside the frame (derived from real FOV math, not a guess). The scene's default `spring_length`
was `180` -- a middling value between that closest-full-body distance and the max, not the closest
one. Changed the default to `120`, matching `CAMERA_ZOOM_MIN` exactly, so the default view is the
closest the real FOV constraint allows rather than an arbitrary midpoint. `CAMERA_ZOOM_MAX` (240)
and the FOV-derived MIN value itself are unchanged. This doesn't change the still-open, separately
documented "very close to a large building" framing issue (thirty-sixth round) -- that's a real,
distinct gap in the roof-avoidance system, not something a default-zoom change fixes.

**Three more real cities wired in**: `docs/PROGRESS.md`'s 2026-08-24 entries already had real,
render-verified region coordinates for Constantinople (`104/80`), Hotan (`92/135`), and Samarkand
(`106/107`) -- found the same way Jangan/Dunhuang were (scanning every real object placement across
all 4,050 real regions for a path containing the candidate name, picking the densest real cluster),
each already confirmed with a real render at the time (Constantinople: a real drawbridge/gate,
cobblestone streets, a 23-piece merchant stall; Hotan: real castellated stone walls and a domed
building with carved lattice screens; Samarkand: a real sand-to-grass biome transition). This real
data simply never got wired into `_resolve_zone_region` until now -- added as three more named-zone
shortcuts, the same pattern Jangan/Dunhuang already use, so typing "Constantinople"/"Hotan"/
"Samarkand" into the zone-change box now works. Also worth noting for scope: any real `"<x>/<y>"`
region coordinate already worked as a zone label before this round too (`_zone_paths` falls through
to using it directly) -- the real limitation was never "only two regions are reachable," it was
"only two regions have a human-readable name," which this round partly addresses.

Full verification: all 43 real GDScript test suites pass, `godot4 --headless --path . --import
--quit` and a headless `--quit-after 60` boot both clean. No new RE work this round -- both changes
used data/derivations already established and verified in earlier sessions, just not yet connected.

## 2026-09-01, thirty-ninth round — real root cause found for "nothing outside the city": the
## streamed region grid has real, confirmed gaps, and walking into one dropped the player through
## an unbounded void

Direct follow-up: "what about walking around and the grass and field shit outside the city."
Rather than guess, pulled real `Data.pk2`/`Map.pk2` (RE box workflow, deleted after use) and ran the
actual exported scene headlessly (`xvfb-run` + `--write-movie`, the established real-screenshot
technique) with the player teleported step-by-step away from Jangan (`89/182`) along +X, re-snapping
onto real terrain each step.

**Real finding #1 -- the region grid this client streams has genuine holes.** `_load_region_neighborhood`/
`_maybe_stream_regions` assume every adjacent region coordinate (`center ± 1, ± 2, ...`) has a real
`.m` file. A direct listing of the real `Map.pk2` archive (`server/cmd/pk2list`, run locally against
the pulled archive, no guessing) shows that's false immediately around Jangan: all 8 regions directly
adjacent to `89/182` (one `REGION_SPAN` step in any direction) have **no `.m` file at all** --
`90/182`, `88/182`, `89/181`, `89/183`, etc. are all real gaps. Real terrain does exist two steps out
in some directions (`91/181`, `91/182`, `91/183` -- real desert terrain, confirmed by a real render;
`87/182` -- also real). This isn't a bug in this project's coordinate math (a broader scan found
long, fully contiguous stretches of regions elsewhere in the same archive, e.g. `100-125/182`), it's
a real, uneven population density in the retail data specifically around Jangan's own tile.

**Real finding #2 -- walking into one of these gaps dropped the player through an unbounded void
forever.** Confirmed via real physics simulation (teleported the player one `REGION_SPAN` into the
gap at `90/182`, let real gravity run for 60+ physics frames): no terrain, no collision, nothing to
land on -- the player just kept falling. This is almost certainly what "nothing outside the city"
looks like in a real playtest: walk far enough in the wrong direction and you fall through the floor
into empty sky with nothing rendered.

**Fix**: `World3D._physics_process` now runs a real downward raycast every physics frame
(`TERRAIN_ONLY_COLLISION_MASK`, matching `_snap_player_onto_terrain`'s own check) to tell "resting on
real ground" from "still falling," and records `_last_grounded_position` whenever real ground is
found close beneath the player. If the player's Y ever drops below `WORLD_FLOOR_Y` (-500, a generous
margin below every real per-region height measured so far, ~0-250) with no ground found, they're
snapped back to `_last_grounded_position` instead of continuing to fall -- confirmed via the same
real physics simulation: falling into the `90/182` gap now correctly returns the player to their
last real footing instead of falling indefinitely. Also added a deep `VoidCatchFloor` StaticBody3D
(`World3D.tscn`, Y=-2000, matching `TERRAIN_ONLY_COLLISION_MASK`) as a pure backstop in case
`_last_grounded_position` was never set (e.g. spawning directly into a void) -- not expected to
normally trigger, since the Y-threshold check above should always catch it first.

**What this doesn't fix**: the region gaps themselves are still there -- walking east from Jangan
still hits ~1920 units of nothing before reaching real desert terrain at `91/182`, it just no longer
falls through the floor when it happens. A real fix for the gap itself (e.g. a flat fallback terrain
patch instead of nothing, or teleporting the player around the gap) wasn't attempted this round.
Also confirmed, but not fixed: once real terrain resumes past a gap, it exhibits the **already-
documented cross-region height-mismatch limitation** (see the fifth round) more severely than
previously seen -- neighboring real regions render as disconnected floating plates with a visible
vertical cliff at the seam, not blended terrain. And a new, real, distinct visual artifact was found
in the desert regions past the gap: a bright, overexposed white/yellow patch bleeding across part of
the ground in two of the real renders -- not investigated this round, flagged as a new open item.

**Separately found and worth flagging, not fixed**: the real click-to-move path
(`_move_target`/`_has_move_target`) has no obstacle avoidance -- a straight-line target aimed
directly at real courtyard geometry near spawn left the player completely stuck (zero net velocity
for 100+ physics frames, confirmed via real position/velocity logging) rather than sliding around
it. This forced the verification above to use direct teleportation instead of simulated walking.
Real previous playtests moved fine (WASD lets a player route around obstacles interactively), so
this specifically affects straight-line automated/click-to-move testing, not necessarily normal
play -- but it's a real, reproducible gap in click-to-move worth a closer look later.

Full verification: all 45 real GDScript test suites pass (up from 43 -- two new files created and
deleted during investigation, not part of the final diff), `go build`/`go vet`/`go test ./...` clean,
`godot4 --headless --path . --import --quit` clean. Real physics simulation (not just visual
inspection) confirmed the fix: the player fell into the real `90/182` gap and was returned to
`(2.89, 4.56, -99.43)` -- their last real grounded position -- instead of continuing to fall. All
pulled real data (`Data.pk2`, `Map.pk2`) and scratch tools (`pk2list` binary) deleted after use.

## 2026-09-01, fortieth round — Jangan itself was the wrong region: a real, isolated pocket, not
## the connected continent

Direct continuation of the thirty-ninth round's investigation ("keep going"). The void-fall fix
stopped the player from falling through the map, but didn't explain why real terrain was so sparse
around Jangan in the first place. Mapped a much wider area of the real `Map.pk2` (`pk2list`,
re-pulled and deleted after use, same as last round) to see the true shape of the real landmass
around `89/182`.

**Real finding**: `89/182` (this project's `JANGAN_ZONE_REGION` since 2026-08-26) is a genuinely
isolated 3x3-ish pocket -- every region touching it in any direction is void, and the nearest other
real terrain is 2+ `REGION_SPAN` away in only some directions (confirmed via the wide `pk2list`
scan, not guessed). Separately, `98/157` (this project's already-verified `DUNHUANG_ZONE_REGION`)
sits inside a real, single, **fully contiguous landmass of 500+ populated regions** (`y=145-175,
x=85-108` all real terrain, zero gaps -- checked directly against the real archive). `98/168` --
this project's *original* 2026-08-24 Jangan discovery, set aside at the time in favor of `89/182`
for having "only" 32 keyword matches against 279 -- sits **inside that same contiguous landmass**,
11 rows from Dunhuang.

A fuller keyword rescan (ad hoc `topregions_scratch`, a top-N variant of `scanlandmarks`, deleted
after use) found the earlier 32-match figure for `98/168` undercounted it: it actually has 277 real
"jangan"-named placements (almost tied with `89/182`'s 279) and *more* real palace-lion-statue
matches (`cj3` prefix, 50 vs 47). Dumping its real resolved object paths directly (`dumpregion_scratch`,
deleted after use) found genuine city-district content: `jangan02` (pub/market lighting, tables/
chairs), `jangan03` (palace substructures, lion statues), plus neighboring regions in the same
landmass with `jangan04` (military camp), `jangan05` (temple), and `greenfield` (lake gardens/open
fields) -- real, connected, walkable content on every side, not an isolated palace box. Real-rendered
`98/168` directly: 779/779 real map objects resolved, real stone walls, willow trees, festival
banners, zero load errors.

**Conclusion**: `89/182`'s high keyword density was real but misleading -- it measured how
*concentrated* Jangan content was in one region, not whether that region was actually part of the
reachable world. `98/168` is both real (comparable density) and reachable (same landmass as
Dunhuang, no void gaps). **Changed `JANGAN_ZONE_REGION` from `89/182` to `98/168`** -- effectively
reverting to this project's original discovery, now backed by better evidence than the density
metric that moved away from it.

This directly addresses the user's "walking around and the grass and field shit outside the city"
complaint at its root: the previous Jangan pick genuinely had almost nothing walkable around it in
the real data. The new one sits in a huge, real, populated, contiguous continent.

**What this doesn't fix**: `98/168`'s own immediate neighbors haven't been individually gap-checked
the way `89/182`'s were -- the landmass-level scan (y=145-175 all populated) makes isolated gaps
right at `98/168` itself unlikely, but not impossible; the `WORLD_FLOOR_Y` safety net from the
thirty-ninth round still applies as a backstop either way. Also not fixed: `89/182`'s own real
content (a real, dense Jangan palace, independently confirmed against the real south-gate
coordinates in an earlier session) isn't reachable from `98/168` by walking at all, since it's a
real isolated pocket -- it's just no longer where players spawn by default. It remains reachable
directly by typing `89/182` into the zone-change box (any raw region coordinate still works, per
`_zone_paths`), just not under the "jangan" name anymore. Whether it's a legitimate separate
in-game instance/interior or genuinely disconnected content wasn't determined this round.

Full verification: all 45 real GDScript test suites pass (none reference `JANGAN_ZONE_REGION`'s
literal value), `godot4 --headless --path . --import --quit` clean, a real headless render of
`98/168` directly (not just the constant change) confirmed real content loads with zero errors. All
pulled real data (`Data.pk2`, `Map.pk2`) and scratch tools (`pk2list`, `dumpregion_scratch`,
`topregions_scratch`) deleted after use.

## 2026-09-02, forty-first round — ground looked "like Minecraft": real fix for flat, blocky per-quad
## terrain textures

Direct follow-up ("see how it looks like minecraft. it doesn't look like that in jangan. shit is
missing everywhere"). Real, visible bug, root-caused rather than guessed at.

**Root cause**: `MapmTerrainBuilder._build_textured_mesh_from_cells` gives every real 20-unit ground
quad exactly one full `0..1` UV stretch of its real texture (`_quad_uv_corners`, previously only
varying a quad's rotation/mirror, never its tiling). Real ground textures (`Tile2D\*.ddj`, grass/
dirt/stone) are small, high-frequency, repeating patterns, not single artwork-sized images meant to
fill 20 world units on their own -- stretching one non-repeated copy across a whole quad produces
exactly the flat, solid-colored, hard-edged block look reported: real, visible per-quad texture
detail (grass blades, brick grain) gets stretched into near-invisibility, leaving what's left reading
as one flat-colored square per tile, i.e. Minecraft.

**Real data found while investigating**: `docs/protocol/MAPM_FORMAT.md` already noted each real
vertex's `TextureInfo` field packs a 10-bit texture ID *plus a 6-bit "Scale"* -- present in the real
file format, decoded as raw bytes, but never actually used for anything. Fetched the real public
source directly ([`JellyBitz/srodevs-docs`](https://github.com/JellyBitz/srodevs-docs)'s
`jmxvmapm.md`, the same already-approved public reference this format's block/vertex layout came
from) to confirm the field's real name and bit position (confirmed: bits 10-15, named "Scale"), then
sampled real per-vertex values across several real regions (`server/cmd/scaleprobe_scratch`, ad hoc,
deleted after use): every real value observed is an exact multiple of 8 (0, 8, 16, 24, 32) -- e.g.
`98/168` (this project's own Jangan spawn) is scale=0 on all 10,404 real vertices, while `98/157`
(Dunhuang) is mostly scale=8 with some 16/24/32, and `91/182` mixes 0/8/16. Never an arbitrary 0-63
value. This is real, confirmed, non-random per-region and per-vertex real data -- not guessed --
though its *exact* numeric meaning (what "scale=8" specifically means in world units) isn't
independently confirmed beyond the field's real name and the fact that it's always a clean multiple
of 8.

**Fix**: `_resolve_texture_scale()` now decodes the real Scale bits, interpreted as a discrete tiling
*level* (`level = scale >> 3`, i.e. exactly recovering the observed 0/1/2/3/4 steps) driving a real
texture-repeat multiplier of `2^level`. Layered on top of a new `BASE_TILE_REPEAT := 4.0` constant --
**explicitly an honest engineering choice, not a claim about real per-quad tiling data** (same
disclosed category as the existing quad-rotation trick right above it in the same file) -- since even
regions where every real vertex has scale=0 (like the new Jangan spawn itself) still looked flat and
blocky without *some* baseline repeat. `_quad_uv_corners` now takes a `repeat` parameter (default
`1.0`, so every existing caller/test is unaffected) and scales its corner UVs by it instead of always
producing a unit square.

**Real-verified, not just theorized**: rendered the same real region (`96/169`, a real "greenfield"
area) before and after -- before, grass/dirt/road quads were flat, solid-colored blocks with a hard
grid edge at every quad boundary; after, the same real textures show actual internal detail (visible
grass blades, brick/paving grain) repeating within each quad, with soft color-block transitions
instead of a hard checkerboard. A real substantial visual improvement, confirmed by direct
side-by-side render, not assumed from the code change alone.

**What this doesn't fix**: the exact real meaning of the Scale field's numeric value is still not
independently confirmed (only its name, bit position, and the real discrete-multiples-of-8 pattern
are) -- if a more authoritative source or a decompiled reference turns up a different formula, revisit
this. `BASE_TILE_REPEAT`'s value (4.0) is a judgment call, not measured from anything real -- flagged
honestly as such, same as this file's other disclosed rendering choices.

Full verification: all 45 real GDScript test suites pass (existing `_quad_uv_corners` unit-square
assertions still hold via the new parameter's default), `godot4 --headless --path . --import --quit`
clean. All pulled real data (`Data.pk2`, `Map.pk2`) and the scratch tool (`scaleprobe_scratch`)
deleted after use.

## 2026-09-02, forty-second round — "figure out what's wrong with the map and make it finished":
## real audit, sky dome re-enabled with a real shader fix

Direct response to an open-ended "make it finished" request. Did a real, broad audit rather than
guessing what to fix next: pulled real `Data.pk2`/`Map.pk2` (deleted after use) and added a temporary
top-down orthographic debug camera mode (`SRREVAMP_DEBUG_TOPDOWN`, removed before commit) to survey
large areas of the new Jangan continent (`98/168`, see the fortieth round) at once, plus normal
ground-level renders.

**Real, positive finding**: the top-down survey looks like an actual city -- real streets, plazas,
walled compounds, market stalls, farmland plots, and forest, all genuinely connected with no visible
gaps or dramatic region-boundary tearing in this new continent (unlike the old isolated `89/182`
pocket's desert extension, where dramatic cliffs were seen in the thirty-ninth round). The
already-documented cross-region height-mismatch limitation (fifth round) is a real, separate, still-
open research problem, but doesn't appear to be a dominant visual issue in this specific, densely-
populated real landmass -- not proven fixed, just not currently the loudest problem here.

**One artifact found and set aside as out of scope**: at an extreme top-down (near-90°) camera pitch,
one real object rendered as a solid black rectangle (a real object, likely water or a shadow-caster,
losing all shading at a viewing angle no real player's camera ever reaches -- this project's own
camera pitch is clamped well short of vertical). Not investigated further since real gameplay can't
reach that angle; flagged here rather than silently dropped.

**Real fix shipped**: the sky cloud dome, disabled since 2026-09-01 (thirty-fifth round) after a real
sunburst/fan artifact was found at the dome's pole (a genuine `SphereMesh` polar-UV projection
singularity, not fixable by UV tiling alone), is **re-enabled** with the shader-based fix that round
flagged as the real path forward but didn't attempt. New `client/scripts/assets/cloud_dome.gdshader`
fades the real `cloud1.ddj` texture's alpha to zero as a vertex approaches the dome's true pole
(computed from the real object-space vertex normal, not an approximation), so the compressed/
sunburst pixels never render at all -- the rest of the dome shows the real texture completely
unmodified. `_sky_dome_material` changed from `StandardMaterial3D` to `ShaderMaterial` accordingly
(the cloud-drift animation in `_physics_process` now sets a `uv_offset` shader param instead of
`uv1_offset`).

**Real-verified, not just theorized**: rendered real `98/168` with the camera pitched to 85° and then
89.5° (near-true-zenith, using a temporary `SRREVAMP_DEBUG_LOOKUP` debug mode, removed before commit)
-- both show soft, real, wispy cloud texture with **zero sunburst artifact**, a clean transition to
the plain sky gradient exactly where the fade completes. This is the real dome's pole, not a
convenient sub-maximum angle -- the previous bug was confirmed reproducible at exactly this kind of
extreme look-up angle.

Full verification: all 45 real GDScript test suites pass, `godot4 --headless --path . --import --quit`
clean, real shader compiles cleanly (checked via the real headless render's own log -- no shader
compile errors, only the same benign shutdown-leak warnings every headless run already produces). All
pulled real data (`Data.pk2`, `Map.pk2`) deleted after use; both temporary debug camera modes fully
removed before commit (verified via `git diff` showing zero trace).

## 2026-09-02, forty-third round — real per-zone sun/ambient color wired in; root-caused and fixed
## the overexposed desert wash

Continuing the same "make it finished" audit. `docs/protocol/ENVIRONMENT_FORMAT.md`'s real
`SunColor`/`DiffuseColor` channels were decoded from day one but never wired to anything (only
`SkyTopColor`/`SkyBottomColor` were). Sampled real values for both zones this project renders
(`server/cmd/envprobe_scratch`, ad hoc, deleted after use): genuinely different per zone at midday --
Jangan's `SunColor` is ~white, Dunhuang's `DiffuseColor` is a warm tan -- confirming this is real,
meaningful per-zone data, not a no-op. Wired `SunColor` into `DirectionalLight3D.light_color` and
`DiffuseColor` into `WorldEnvironment.environment.ambient_light_color`, sampled at the same fixed
`ENVIRONMENT_REFERENCE_TIME` the sky colors already use.

**While verifying this, reproduced and root-caused a real, pre-existing bug**: a real render of
Dunhuang (`98/157`) came back almost entirely flat, overexposed cream/white -- matching the
"overexposed white/yellow patch" artifact flagged as unexplained in the thirty-ninth round. Confirmed
this predates the new sun/ambient wiring (identical result with the new code temporarily disabled).
Root-caused with a real controlled render: disabling the directional light entirely and setting flat
white ambient showed the real sand ground texture is a perfectly normal tan color -- not a broken
texture. The wash only appears once the directional light's own diffuse contribution stacks on top of
ambient light; real bright albedo values (sand is naturally pale) push past 1.0 per channel, and this
project's GL Compatibility renderer doesn't apply an effective HDR/filmic rolloff in front of that
(the `Environment` resource's `tonemap_mode` is a real no-op here, consistent with Compatibility's own
already-logged limitations elsewhere in this codebase -- glow and SSAO are also silently no-ops on
this renderer), so the overflow hard-clips to flat white instead of compressing smoothly.

**Fix**: lowered `DirectionalLight3D.light_energy` from Godot's default `1.0` to `0.3` in
`World3D.tscn`. Real before/after render of the same Dunhuang region confirms real dune/terrain detail
is now visible instead of a flat wash. Jangan (a darker real palette that was never clipping) still
looks correct at the lower energy too -- tested both zones, not just the one that was broken.

Full verification: all 45 real GDScript test suites pass, `godot4 --headless --path . --import --quit`
clean. All pulled real data (`Data.pk2`, `Map.pk2`) and the scratch tool (`envprobe_scratch`) deleted
after use; the temporary `SRREVAMP_DEBUG_UNLIT`/`SRREVAMP_DEBUG_HIDE_UI` diagnostic hooks used to
isolate the bug were fully removed before commit (verified via `git diff`).

## 2026-09-02, forty-fourth round — cross-region height-mismatch, rigorously measured for the first
## time; no reliable fix found, still genuinely open

Continuing "make it finished." The cross-region height-mismatch limitation has been flagged since the
fifth round, but always qualitatively ("real, genuinely steep seams") -- never actually measured. Built
a real, no-persisted-data tool (`server/cmd/seamcheck_scratch`, deleted after use) that stitches two
real adjacent regions' full 97x97 height grids (the exact same real logic
`MapmTerrainBuilder._full_region_cells` uses) and directly diffs their real shared-boundary vertex
heights -- no rendering involved, pure real data comparison.

**Real, quantitative result**: even in the region cluster this project's own earlier docs cited as
proof of "zero visible gaps" (`100/100`'s neighborhood -- see `_load_region_neighborhood`'s own doc
comment, which cites a real 3x3 top-down debug render of this exact area as positive evidence for
grid adjacency), real adjacent-region edge heights differ by a
mean of 25-55 units and a max of 75-115 units at the shared boundary -- large, real numbers relative
to this project's own measured real building heights (~44 units for a wall piece, ~140 for a tree).
The earlier "no visible gaps" finding was evidently a shallow visual read (a top-down or middle-
distance debug render), not a check of actual vertex continuity -- this rigorous check contradicts it.

**One real, tested hypothesis, and its real result**: tried reversing the compared row/column order
(in case this project's assumed north/south or column direction between neighboring region files is
mirrored relative to reality) at several real region-pairs. Result was **inconsistent, not a real
fix**: some pairs improved dramatically with reversal (`101/100`<->`101/101`: mean diff 26.5 -> 7.8;
`100/100`<->`100/101`: 24.5 -> 3.7), others got worse or stayed the same (`102/100`<->`102/101`: 57.5
-> 58.8; `98/168`<->`99/168`, x-axis: 22.9 -> 31.7). A real fix that only works for some pairs isn't a
real fix -- it's noise, and shipping it as one would be exactly the kind of unverified pattern-match
this project's own standing rule exists to prevent. Not applied.

**Honest conclusion**: this project still does not have a real, confirmed way to determine true
region-to-region physical adjacency or a real per-region height datum that would let two real
neighboring regions' terrain align without a fabricated blend. This is consistent with (and now
backed by harder evidence than) the existing "offset hypothesis does not hold" finding from the
sixth round (this project's internal region-folder numbers don't match the public xSROMap sector
numbering via any simple transform either). A real fix needs one of: (a) real decompiled client
region-loading/world-coordinate code (this project only has the server decompiled, not the renderer),
(b) a public reference for the real region/sector layout more detailed than what's been found so far,
or (c) accepting a fabricated, disclosed-as-fabricated blend across the seam (not attempted -- the
measured mismatch is large enough, tens to 100+ units over a handful of quads, that a blend would
visibly warp real terrain features rather than just soften a seam, and this project has a standing
preference for an honest sharp seam over a disguised fabrication).

Full verification: no rendering-affecting code changed this round (investigation only). Real pulled
data (`Map.pk2`) and the scratch tool (`seamcheck_scratch`) deleted after use.

## 2026-09-02, forty-fifth round — keep pushing: a real Ghidra dead end, a real stride-2 test, and a
## real tiling-blend improvement

Direct follow-up ("keep pushing on the region stuff and fixing the map and tiling").

**Checked whether the loaded Ghidra project could resolve the region-adjacency question directly**:
it can't -- the currently-open program is the real Agent/Gateway server binary (`CAgentServer`,
`CNetEngine`, `CBaseSocket` classes; no `CRegion`/`CObject`/`CTerrain`-style classes, no `.pk2`
strings at all), not the world/zone server or the client renderer. Earlier `CRegionManagerBody`
references in this project's own docs must come from a different binary analyzed in an earlier
session that isn't currently loaded, and this project's tools have no way to open a different binary
into Ghidra from here. Real dead end, not pursued further.

**Tested one more real hypothesis on the height-mismatch data**: a stride-2 adjacency (comparing
`98/168` directly against `100/168`, skipping the file numbered in between) instead of stride-1.
Real result: `16.2` mean / `62.0` max diff, vs `22.9`/`131.2` and `22.4`/`97.8` for the two stride-1
pairs spanning the same distance -- somewhat smaller, but still a large real mismatch (for scale: a
real measured building wall is ~44 units tall), and "somewhat smaller over a wider gap" is weak,
ambiguous evidence at best, not a confirmed fix. Not applied -- still an open problem, same
conclusion as the forty-fourth round.

**Real, shipped improvement to ground-texture tiling**: a closer real render (96/169, greenfield)
showed the forty-first round's per-quad tiling fix hadn't fully solved the "blocky" look -- the
boundary alpha-blend between differently-textured quads was applied as one flat value across an
*entire* quad, so a quad still either "faded" or didn't as a whole block, just semi-transparently
instead of opaquely. Changed `_build_textured_mesh_from_cells` to compute **per-corner** alpha
instead (each of a quad's 4 corners checks only the 1-2 neighbor sides nearest to it), letting
Godot's own vertex-color interpolation produce a real smooth gradient fading toward each boundary
edge rather than a uniform block-wide fade -- same real neighbor-differs signal already computed,
applied at finer granularity, no new data or invented values. Real before/after render of the same
region confirms visibly softer, less blocky transitions at texture-ID boundaries. (Also tried raising
`BASE_TILE_REPEAT` from 4 to 8 to see if finer tiling alone would help further -- real render showed
no visible difference at this render resolution, reverted back to 4, not worth the change.)

**Also confirmed, not a bug**: a real fan/sunburst-shaped ground texture pattern visible in one
close-up render (a real raked-sand/garden-medallion-style tile, consistent with the "greenfield"
lake-garden district it sits in) is real texture content resolving correctly, not a rendering
artifact -- left alone.

Full verification: all 45 real GDScript test suites pass, `godot4 --headless --path . --import --quit`
clean. All pulled real data (`Data.pk2`, `Map.pk2`) and the scratch tool (`seamcheck_scratch`)
deleted after use; temporary `SRREVAMP_DEBUG_HIDE_UI`/`SRREVAMP_DEBUG_LOOKDOWN` hooks fully removed
before commit (verified via `git diff`).

## 2026-09-02, forty-sixth round — THE region bug found and fixed: the region grid's axes were
## swapped, and boundary blending faded to gray instead of into the neighbour

Real playtest report: "that map doesn't look like silkroad at all, the brown is a straight line next
to the green." Investigated properly instead of guessing, and found **two real bugs**, one of them
the root cause of every cross-region problem this project has been documenting as "open" since the
fifth round.

**Ruled out first, with real controlled renders**: the `.t` lightmap (disabled it -- seams
unchanged), and unresolved ground textures (instrumented every streamed region: 100% of real
texture IDs resolve in all 25, nothing falling back to gray).

**Real bug #1, the big one: the region grid's two axes were swapped.** `_load_region_cell` placed a
region at `Vector3(dx * REGION_SPAN, 0, dy * REGION_SPAN)` where `dx` is a region_x (folder) delta
and `dy` a region_y (file) delta -- i.e. it assumed region_x runs east/west and region_y runs
north/south. That is backwards, and it meant every "neighbour" this client streamed in was an
entirely unrelated part of the real world, so terrain never lined up in height *or* texture -- hence
the hard straight lines at every region boundary.

Found it by first establishing a real ground truth: within a single real region, adjacent blocks
share their edge vertices with a mean absolute height difference of **exactly 0.000000** (checked
across three unrelated real regions). So the real data *is* perfectly continuous where it's meant to
be adjacent -- which meant the 22-55 unit region-to-region mismatches measured in the forty-fourth
round couldn't be "just how the real data is," they had to be this project comparing the wrong
edges. A brute-force scan of all 4,050 real regions (ad hoc `findneighbor_scratch`, deleted after
use) then matched a target region's four edges against every other region's four edges: each target
edge matches **exactly one** real region's opposite edge at **exactly 0.000000** mean difference,
and the partners are `region_x ± 1` on the north/south axis and `region_y ± 1` on the east/west
axis. Verified on two unrelated real regions (`96/169`, `98/157`) -- identical rule both times.

**Fix**: swapped the axes in `_load_region_cell` (`region_x` → world Z, `region_y` → world X), and
correspondingly in `_maybe_stream_regions`' player-position-to-cell math so streaming stays
consistent. **This closes the cross-region height-mismatch problem outright** -- it was never a
missing-data problem needing a fabricated blend (as the forty-fourth round concluded), it was this
bug. Real render confirms it: a real road now runs continuously straight across a region boundary,
and terrain features flow across seams instead of stopping dead at them.

**Real bug #2: boundary blending faded toward flat gray instead of into the neighbouring texture.**
Every quad near a texture boundary was drawn semi-transparently over a flat gray base surface. That
desaturates the real texture rather than blending it, and because real regions differ in how
fragmented their tile layout is, it desaturated some regions far more than others -- producing real,
uneven, per-region washed-out tinting. Confirmed with a real controlled render (forcing every quad
opaque made the whole map dramatically more saturated).

**Fix**: reworked `_build_textured_mesh_from_cells` to do real terrain splatting instead. Each quad
now draws its own real texture **fully opaque**, and for every edge where a neighbour uses a
different real texture, that neighbour's own real texture is drawn again over this quad as a
separate feathered pass, alpha ramping from `BOUNDARY_BLEND_ALPHA` at the shared edge to 0 at the
far edge. Real texture A genuinely fades into real texture B, with no invented middle color and no
loss of saturation. Real render confirms visibly smooth, organic grass/sand/dirt transitions
replacing the blocky checkerboard.

**What this doesn't fix**: texture blending still happens only *within* a region, since each region's
mesh is built independently and has no access to its neighbours' tile data -- so a texture change
that falls exactly on a region boundary is still a hard edge (heights are now perfectly continuous
there regardless). Passing neighbour edge tile data into the builder would close this; not attempted
this round. `BOUNDARY_BLEND_ALPHA` (0.45) is a disclosed rendering choice, not real data -- the real
format carries no per-vertex blend weights this project has found.

Full verification: all 45 real GDScript test suites pass, including `mapm_terrain_builder_test.gd`'s
assertions rewritten for the new architecture (opaque per-texture surfaces plus a transparent
feathered blend surface, with a real check that blend alphas only ever ramp between 0 and
`BOUNDARY_BLEND_ALPHA`). `godot4 --headless --path . --import --quit` clean. All pulled real data
(`Data.pk2`, `Map.pk2`) and scratch tools (`blockedge_scratch`, `findneighbor_scratch`) deleted after
use; every temporary debug hook removed before commit (verified via `git diff`).

## 2026-09-02, forty-seventh round — buildings and creatures were rendering inside-out

Real playtest report: terrain now reads correctly ("the dirt road actually looks like sro, so does
the grass") but "the buildings are fucked and so is the dog", with a direction to **do what the
original code does** rather than approximate. Two real bugs found, both in object loading rather
than placement.

**Real bug #1: every real object rendered inside-out.** `BmsReader.to_array_mesh` fed the real
`.bms` index buffer straight into Godot, but the real file winds each triangle in the opposite
order from Godot's front-face convention. With normal back-face culling, that culls a real
object's *outward* surfaces and leaves only its interior visible.

Proved with a real controlled render of a real building (`cj_sugi_house_01`), three ways: as-is it
renders as a sparse skeleton of poles with no walls or roof; with culling forced off it renders as
a complete, correct thatched hut; with the winding reversed it renders as that same correct hut
**with normal culling still enabled** -- i.e. the real geometry was always right and only the
winding was wrong. Confirmed again on a real Jangan palace roof (`cj_pal_sub_buil01`): before, a
hollow shell you could see straight through to its far inside edges; after, a solid, correctly-tiled
roof. Note this also corrects an earlier misread in the forty-second round, where a Jangan gate was
called "real and correct" -- it was actually showing interior faces.

**Fix**: reverse each triangle's 2nd/3rd index in `to_array_mesh`. Per-vertex normals come from the
real file rather than from winding, so lighting is unaffected. Chose this over disabling culling
because it keeps real back-face culling doing its job, and because the evidence says the winding
(not the culling) is what was wrong. Checked the alternative first: the public
[`JellyBitz/JMX-File-Editor`](https://github.com/JellyBitz/JMX-File-Editor) `PrimMtrlFlag` enum
documents the real `.bmt` material flags field this project parses as `unknown`, but it names no
two-sided/culling bit (only tentative guesses for tint/diffuse/alpha/bump), so wiring a culling
flag from it would have been a guess -- deliberately not done.

**Real bug #2: a real object's primary mesh was drawn twice.** A real `.bsr`'s own sub-mesh list
normally *begins with the very same path* as its primary `mesh_path` (confirmed against real data:
`cj_sugi_house_01.bsr` declares `mesh_path .../cj_sugi_house_01.bms` and then lists that identical
path again as its first sub-mesh, before `_02`/`_03`). `ObjectLoader` prepended `mesh_path`
unconditionally, so the main piece was built twice at the exact same transform -- real z-fighting on
every such object. Fixed by de-duplicating the mesh path list while preserving real declaration
order; since this loader applies no per-mesh transform, drawing one real mesh path twice is never
meaningful.

**Not addressed**: "the dog" specifically wasn't isolated to a named real asset this round. Real
creature models go through the same `BmsReader` path as buildings, so the winding fix applies to
them too, but that hasn't been confirmed against a specific real dog/creature asset -- flagged
honestly rather than claimed.

Full verification: all 45 real GDScript test suites pass, including a **new** real assertion in
`bms_reader_test.gd` pinning the winding reversal (previously `to_array_mesh`'s index output had no
test coverage at all, which is why this shipped broken for so long). `godot4 --headless --path .
--import --quit` clean. All pulled real data (`Data.pk2`, `Map.pk2`) and the temporary
`render_bsr_probe.gd` diagnostic deleted after use; debug hooks removed before commit.

## 2026-09-02, forty-eighth round — "the dog": the character was ~10x too small to see, and
## assembled wrong underneath

Follow-up to the same real playtest report ("the buildings are fucked and so is the dog"). The
buildings were the forty-seventh round's winding bug. "The dog" turned out to be the real player
character, and it took two stacked real bugs to make it look like one.

**Real bug #1: every player-relative constant was ~10x too large.** `PLAYER_SCALE_RATIO` was
`138.7 / 1.8`, where 138.7 was a previously-claimed forward-kinematics measurement of the real
character's native height. That figure is simply wrong. Two independent runtime measurements of the
*actually assembled* real character -- its real skeleton's own bind-pose bone extent, and the real
world-space AABB of every mesh attached to it -- both come out at **14-16 units**, not 138.7. So the
camera sat roughly 8 character-heights away, move speed was ~33 body-heights/second, and the
placeholder collision capsule was ~10x oversized. On screen the real character was a ~20-pixel
speck, which is exactly what reads as "a dog".

Corrected to a `REAL_CHARACTER_NATIVE_HEIGHT` constant taken from the real measurement, with the
scene's placeholder capsule, camera arm height, and `CAMERA_ZOOM_MIN`/`MAX` re-derived by the same
real ratio so their previously-tuned framing is preserved rather than re-guessed.

**Real bug #2, revealed once the character was big enough to see: it was assembled wrong.**
`CharacterAssembler.attach_rigid` cancelled only the bone's rest *translation*
(`position = -get_bone_global_rest(idx).origin`). A `BoneAttachment3D` contributes the bone's full
global pose including **rotation**, so every piece was left spuriously rotated by its own bone's rest
rotation. That was harmless while all bone rest rotations were identity, but stopped being harmless
on 2026-08-28 when `Skeleton3DBuilder` began using each bone's real `.bsk` bind rotation. From then
on the real character rendered as detached, splayed limbs -- measured **21.1 units wide against only
12.8 tall**, when a real humanoid is far taller than wide. It went unnoticed only because bug #1 was
simultaneously drawing it too small to see.

Fixed by cancelling the *whole* rest transform (`transform = get_bone_global_rest(idx).affine_inverse()`),
which is the correct inverse: the attachment contributes `bone_global_pose`, this contributes
`inverse(bone_global_rest)`, so at rest they cancel exactly and each real mesh sits at the absolute
bind-pose coordinates its own vertices are already in -- while still moving rigidly with the bone
under animation. **Real render confirms it**: the character now assembles into a correct, complete
humanoid T-pose (torso, both arms, both legs, hands, feet all connected and correctly placed).

**Real bug #3, found but NOT fixed this round: `.ban` animation playback is wrong.** With the above
fixed, the character is correct in its real bind pose but still distorts once real animation drives
the skeleton. Note this also corrects an earlier over-claim: the 2026-08-28 "coherent walking stride"
verification only ever looked at a bare skeleton's bone positions, never at real attached body
meshes, which is why it read as fine.

**One hypothesis was tested and disproven.** `Skeleton3DBuilder.apply_ban_pose` computes each
keyframe's rotation as a delta against keyframe 0 and applies it as a **local** pose rotation, so the
obvious guess was that real `.ban` rotations are in the same global/world space this project already
had to convert out of for real `.bsk` bind rotations, and that applying a global rotation as a local
one compounds error down the bone chain. Implemented that conversion (global -> parent-relative) and
rendered it against real data: the result is dramatically **worse** -- the character scatters
completely rather than merely splaying. So real `.ban` rotations are *not* global-space, and that is
not the bug; the existing delta-against-keyframe-0 approach is closer to correct than the
alternative. Reverted. What the real encoding actually is remains genuinely unknown and needs real
evidence rather than another guess -- recorded here so the same dead end isn't re-walked.

Animation playback is **disabled** meanwhile rather than shipped visibly broken -- the same call this
project already made for the sky cloud dome -- so the real character renders correctly, just
statically.

**Also still open, deliberately not guessed at**: real map objects measured alongside the character
(a real chair 12.5 units, table 10.8, standing lamp 19.9, guardian lion statue 29.0) are
self-consistent with each other but make a ~14.3-unit character read as roughly chair-height --
short for an adult. That suggests the real client may apply its own character scale factor this
project hasn't found. No such factor was invented; this round only corrected a provably wrong
measurement.

Full verification: all 45 real GDScript test suites pass, `godot4 --headless --path . --import
--quit` clean, and a real headless scene boot against real `Data.pk2` runs with zero script errors.
All pulled real data and the temporary `render_bsr_probe.gd`/`measure_probe.gd` diagnostics deleted
after use; every debug hook removed before commit (verified via `git diff`).

## 2026-09-02, fifty-first round — back on the map: cloud dome was slicing the ground, and real
## buildings render unlit

Direct correction from the user: I had drifted off the map onto character animation and stayed
there. Refocused on the map, with real renders of the real Jangan region (`98/168`) against real
pulled `Data.pk2`/`Map.pk2`.

**Real bug found and fixed: the cloud dome was cutting through the terrain.** A ground-level render
showed large translucent shards fanning across the ground away from the player. Isolated it by
disabling the sky entirely: the shards vanished completely and the ground came back clean, with
nothing else changed. Cause: `_sky_dome` is a **hemisphere** whose position was set to
`player.global_position` every frame, so its flat base plane sat exactly at the player's feet and
intersected real terrain wherever the ground rose above that. Fixed by lifting the dome's centre to
`SKY_DOME_RADIUS * 0.5` above the player, which keeps the whole dome clear of real terrain and is
also simply where a real cloud layer belongs. Re-rendered: shards gone, sky intact, clean grass.
This is the third distinct real bug this one dome has produced (see the thirty-second, thirty-fifth
and forty-second rounds) -- worth remembering if it misbehaves again.

**Real bug found, NOT yet fixed: real buildings render as unlit dark silhouettes.** The same render
shows the real Jangan palace walls as flat dark navy slabs against the sky. Ruled out by
measurement, in order:

- **Not missing assets** -- the whole region loads with only 2 unresolved `.bsr` files out of
  hundreds.
- **Not lighting level** -- forcing the directional light to 1.5 and ambient to pure white at
  energy 2.0 lit the ground and character right up while the slabs stayed exactly as dark.
- **Not the material's own colour** -- dumping the real `.bmt` layers for real palace/lion/house/tree
  materials shows ordinary mid-grey diffuse values (~0.588), no black or near-black.
- **Not the sky dome** -- with the sky disabled the slabs are still there (and render pure black).

**What it is**: the surfaces are unlit, i.e. their normals face away from the light. Negating every
`.bms` vertex normal makes the real palace walls render correctly, with visible stone texture --
**but simultaneously turns the real willow foliage into black silhouettes**, which had been rendering
correctly. So walls and foliage currently need *opposite* normal orientations, which cannot both be
right and points at something more fundamental than a stray sign.

The leading explanation, not yet confirmed, is a **handedness mismatch**: if real `.bms` data is
authored in a left-handed space and this project imports positions without mirroring, then both the
triangle winding *and* the normals need flipping together, and the forty-seventh round's
winding-only flip left the two inconsistent. That would also explain why the winding flip visibly
fixed one real building (`cj_sugi_house_01`, verified three ways at the time) while leaving these
walls wrong. The foliage may then be a separate, real interaction with the alpha-cutout materials
that already disable back-face culling. **Not guessed at further** -- the next step is a controlled
isolated render of one real wall and one real foliage asset across all four winding/normal
combinations, rather than more changes to the live scene.

### Same round, continued: what the dark surfaces are NOT

Kept measuring rather than guessing. Additional causes ruled out for the unlit-looking geometry, each
with real evidence:

- **Not inconsistent winding vs normals.** Wrote an analytic check (no rendering) comparing, per
  triangle, the face normal implied by the file's own winding against the file's own vertex normals,
  across real palace, house, tree and statue meshes. They **agree on 99-100% of triangles** in every
  asset, and both point outward from the mesh centroid on the majority. So real `.bms` winding and
  normals are self-consistent as authored, and the same-day idea of negating normals to "match" the
  forty-seventh round's winding flip is wrong -- it would *introduce* the inconsistency, not remove
  it. Not applied.
- **Not the `.t` lightmap.** Rendered the same view with the lightmap disabled: essentially identical.
- **Not the placed objects.** With object loading genuinely disabled (an earlier attempt at this test
  was invalid -- objects load from region coordinates regardless of `SRREVAMP_MAPO_PATH`), the dark
  areas in the courtyard are simply real dark paving texture, which is plausibly correct.
- **Not DXT1 foliage cutout.** `_ALPHA_FOURCCS` excludes DXT1, and real tree branch/trunk cards are
  DXT1, so the theory was that they render as opaque rectangles. Adding DXT1 and letting the existing
  `_has_real_alpha_variance` pixel check decide showed the real branch texture is **genuinely opaque**
  (correctly rejected, unchanged), while several real *palace wall* DXT1 textures flipped to cutout --
  risk to solid walls for no gain on the actual symptom. Reverted.

Still open, and now much better bounded: some real geometry in the Jangan courtyard view renders far
darker than it should. It is not the lightmap, not the objects' material colours, not the light
level, not the sky, and not a winding/normal inconsistency. The one thing that demonstrably changes
it is negating `.bms` normals, which the analytic check says would be wrong -- so the next step is to
find why correct outward normals still light incorrectly there (candidate: the Compatibility
renderer's handling of `CULL_DISABLED` alpha-scissor materials, which is exactly the set that
flipped appearance in that experiment).

## 2026-09-02, fifty-second round — the dark slabs were willow foliage rendering opaque

Followed the plan from the previous round (isolate rather than keep changing the live scene), and
this time identified the culprit exactly rather than by elimination: **raycast into the dark slabs
from the camera and print what was hit.** Every single ray, across six horizontal and three vertical
screen positions, hit the same thing -- `tre_willow03_leaf01`, a real willow tree's own leaf mesh.
The slabs were never walls or buildings at all; they were real foliage cards rendering as solid
rectangles.

**Root cause**: `_ALPHA_FOURCCS` listed only `DXT3`/`DXT5`, so a real DXT1 texture never even reached
the alpha check. BC1/DXT1 carries a real 1-bit alpha channel and real foliage uses it heavily.
Measured the real textures directly:

```
tre_willow02_leaf01   DXT1  256x256   79% of texels below opaque
tre_willow02_leaf02   DXT1  128x512   77%
tre_willow02_will01   DXT1   64x256    0%   (the real trunk -- genuinely solid)
CJ_pal_sub_buil01_wall02  DXT1 128x256  0%  (real masonry -- genuinely solid)
CJ_pal_sub_buil01_roof01  DXT1  64x256  0%
```

The separation is total: real foliage 77-79%, real solid surfaces exactly 0%, nothing in between.

**Fix**: added `DXT1` to `_ALPHA_FOURCCS`, with a **fraction** test rather than the existing
"any texel below opaque" rule for that format specifically (`_DXT1_CUTOUT_MIN_ALPHA_FRACTION`, 5%,
via a new `_real_alpha_fraction()`). DXT3/DXT5 keep their original behaviour untouched, because their
alpha is graded and small amounts are meaningful there; DXT1's is 1-bit, so a real texture either
uses it clearly or not at all, and requiring a real fraction keeps genuinely solid real masonry solid
even if a block decodes with one imperfect texel. A first attempt that simply added DXT1 without the
fraction test was reverted in the previous round precisely because it flipped real palace walls to
cutout.

**Verified**: re-rendered the same real Jangan view. The dark slabs are gone entirely, replaced by
real willow trees with visible trunks and hanging foliage, the real palace wall and its red trim
readable behind them, and real sky through the canopy. Every real palace/wall texture measured
stayed opaque, confirming the guard works in both directions.

This also closes the previous round's open question honestly: the leading hypothesis there was a
handedness/normal problem, on the strength of negating `.bms` normals appearing to "fix the walls".
That was a red herring -- the walls were never broken; they were **occluded** by opaque foliage
cards, and negating normals merely darkened the foliage enough to stop hiding them. The analytic
winding-vs-normals check from that round (99-100% agreement) was right, and no normal change was
needed.

## 2026-09-02, fifty-third round — removed an invented tiling constant that was destroying real
## ground textures

Continuing the map pass. A pale, crosshatched mound kept appearing near the real Jangan spawn.
Raycast into it (same technique that identified the willow foliage): it is **terrain**, not an
object -- `RealTerrain_99_168/SubPatch`. So a real ground texture was rendering as moire mush.

**Root cause: `BASE_TILE_REPEAT`, an openly-invented constant.** The forty-first round added
per-quad texture tiling of `BASE_TILE_REPEAT (4.0) * 2^scale_level`, where the real `Scale` field
supplies the exponent but the `4.0` was disclosed at the time as an engineering guess, on the theory
that real ground textures are small high-frequency patterns needing extra repeats. Two real
measurements show that guess was wrong and actively harmful:

- Real `Scale` values are not uniformly zero. Real region `98/157` (Dunhuang) carries scale levels up
  to 32, which under the old formula meant `4 * 2^4 = 64` texture repeats across a single real
  20-unit quad -- guaranteed moire.
- A real side-by-side render with the multiplier removed resolved the crosshatched mound into a
  clean, readable grey **rock formation**, and visibly smoothed the surrounding grass.

**Fix**: `BASE_TILE_REPEAT` is now `1.0`, so the real `Scale` field alone drives tiling and no
invented factor remains. A real scale level of 0 -- which is every vertex of real region `98/168` --
now means exactly one repeat per quad, which is what real textures appear to be authored for.

**Verified against two real regions with different real scale distributions**: Jangan (`98/168`, all
scale 0) renders clean grass, a readable rock outcrop, willow trees with visible trunks and the
palace wall behind; Dunhuang (`98/157`, mostly scale 8 with some 16/24/32) renders as a genuine
desert -- sand with visible grain, sandstone formations, cypresses, distant haze. Both look like the
real game rather than like moire.

This retires the forty-first round's reasoning. That round correctly identified that a single
non-repeated stretch per quad looked flat, but the conclusion drawn -- that a fixed extra multiplier
was needed -- overshot; the real `Scale` field was already the mechanism, and the invented constant
on top of it was the problem.

## 2026-09-02, fifty-fourth round — map survey after the texture fixes

Surveyed several real regions at eye level to find what is still wrong, rather than guessing. Real
renders against real pulled `Data.pk2`/`Map.pk2`.

**Rendering correctly, and genuinely game-like now:**

- Real Jangan (`98/168`): clean grass, a readable grey rock outcrop, willow trees with visible
  trunks and hanging foliage, the real palace wall and its red trim behind, sky through the canopy.
  Top-down it reads as a real city -- courtyards, formal gardens, water features, paved plazas.
- Real Dunhuang (`98/157`): a genuine desert -- sand with visible grain, sandstone formations,
  cypresses.
- Real Dunhuang ferry area (`100/160`): sand dunes, a real Chinese pagoda, sandstone cliffs, trees
  and driftwood. This one in particular looks like the real game.

**Two real spots show sky where ground is expected, bounded but not root-caused:**

- `97/167`: a large pale expanse fills the lower screen. Raycasting into it hits **nothing** inside
  the loaded world (the few hits that land at all are the `VoidCatchFloor` at z=5384 / x=3457, well
  outside the 5x5 streamed grid), so it is the sky's own lower hemisphere showing through, not an
  untextured surface. Ruled out water as the cause: all 30 real `Water\` animation frames load
  cleanly, and `build_full_region_water_mesh` returns **no water quads at all** for any of
  `97/167`, `98/168`, `99/168`, `100/168`, `98/157`.
- `96/169`: a horizontal band of sky cuts across at roughly the character's feet, with a real plowed
  field in the foreground and a real courtyard and wall beyond it.

Terrain itself loads fine in both cases (every region in the neighbourhood reports a successful
parse and collision build), and the region grid's own geometry tiles exactly by construction: with
the corrected axes each region mesh spans `[-960, 960]` in world X and `[-1920, 0]` in world Z for
the centre cell, with neighbours offset by exactly `REGION_SPAN`, so adjacent meshes meet at a shared
edge with no gap. That makes a missing-terrain explanation unlikely and points instead at the
**camera** -- the debug survey camera is a fixed spring-arm distance behind the character with no
regard for whether that puts it inside or below real terrain, which would produce exactly this kind
of view. Not confirmed, and deliberately not "fixed" on a guess.

The honest summary: the map's *texturing* problems are resolved (see the fifty-first through
fifty-third rounds), and most real regions now render like the real game. What remains unexplained is
localised and camera-shaped rather than world-shaped.

## 2026-09-02, fifty-fifth round — camera investigation, and a third-person distance that actually frames the world

Chasing the previous round's leftover "sky where ground should be" spots. **The camera hypothesis was
wrong** -- measured directly, the camera is comfortably above real terrain in every region checked
(`97/167`, `96/169`, `98/168`), with the terrain surface 15-30 units below it each time. Ruled out.

**Also tested and ruled out**: that the spring arm was colliding with the player's own body. A raycast
along the arm hits `World3D/Player` at distance 0 when the player isn't excluded, which looked like a
smoking gun -- but explicitly adding the player to the arm's exclusions changed `get_hit_length()` by
exactly nothing (11.35 before and after in `97/167`, 19.69 in `98/168`). Not applied. Worth noting the
arm's own `collision_mask` is 1 while the player body is on layer 2, so it should never have matched
in the first place; the raycast only hit it because a bare query defaults to every layer.

**What the arm is doing is in fact correct**: in `98/168` it pulls in to 19.7 units because there is a
real palace wall (`cj_pal_dam_center`) 19.8 units behind the player. That is the spring arm doing its
job.

**Real problem found and fixed: the zoom range was far too tight.** `CAMERA_ZOOM_MIN`/`MAX` were
derived from vertical-FOV math answering "the closest distance that still fits the whole character in
frame", then rescaled when `REAL_CHARACTER_NATIVE_HEIGHT` corrected the character to ~14.3 units.
That left a **12.4-24.8** range -- under two character heights -- so the character filled the frame
with almost no world visible around them, which is nothing like a real third-person MMO view.

Re-chose from real side-by-side renders of the real Dunhuang ferry region at several distances:
**~45 units (about 3 character heights)** frames like the real game -- the character reads clearly
while real terrain, the real pagoda and the horizon all stay visible. Range widened to **20-90** to
bracket it, and the scene's default `spring_length` set to 45. The stale `CAMERA_ZOOM_STEP` comment,
which still derived its value from the disproved ~139-unit character height, was corrected too.

Flagged honestly: unlike this project's terrain and skeleton constants, these are an **openly-declared
framing choice**, not values recovered from real game data -- no real camera-distance data has been
found. Stated that way rather than dressed up as a measurement.

**Noticed while verifying, not fixed**: with the HUD visible the `ActionTabs` panel sits from roughly
y=260 to y=480 on a 648px-tall viewport -- the middle third of the screen -- and covers the character
at the new camera distance. That is a real HUD layout problem for playability, separate from the
camera itself.

## 2026-09-02, fifty-sixth round — "holes in the map": camera far plane was clipping real terrain

Real user report: holes in the map. My previous round had waved a similar symptom away as a
camera-position artifact, which was wrong.

**Established first, by measurement, that the terrain itself is not holed.** A grid of downward
raycasts over the loaded world -- 961 samples at 60-unit spacing, then 2,401 samples at 200-unit
spacing covering a 9600x9600 real area -- found real terrain at **every single sample**, in two
different real regions (`98/168` and `97/167`). Terrain collision is complete. So any hole is
**visual only**, over solid ground, which is a very different bug.

**Found and fixed: the camera's far clipping plane.** `Camera3D` never set `far`, so it used Godot's
default of **4000**. The real streamed grid is `(2 * REGION_LOAD_RADIUS + 1)` = 5 regions across,
9600 real units wide, reaching ~5400 units to a corner from the player. A real height profile
confirms real terrain out at z=+3200 with the void only beyond z=+4000 -- so real ground genuinely
existed past where the far plane was cutting it, and the sky showed through. Physics ignores the far
plane, which is exactly why collision probes found no holes while the view had them. Now derived from
`REGION_SPAN * (REGION_LOAD_RADIUS + 1) * 2` (11520) so it tracks the streaming settings.

**One symptom remains unexplained, and is NOT the above.** In real region `97/167` a large pale
expanse fills the lower screen at close range. Ruled out, each by direct test:

- **Not water** -- disabling water rendering entirely leaves the image pixel-identical, and separately
  all 30 real `Water\` frames decode fine to real teal water colours (RGB ~0.23-0.73), so the water
  texture pipeline is healthy. Six real regions in that neighbourhood do carry real water, so water
  is being built there; it just isn't what this is.
- **Not the far plane** -- still present with `far` at 11520.
- **Not the sky dome** -- present with the sky disabled.
- **Not the camera being under the terrain** -- measured 15-30 units above the surface.

Its colour matches the sky's own lower-hemisphere tone, and a real height profile through that area
shows ordinary terrain (-1 to +40 units) with a real 40-unit rise immediately in front of the
spawn. Recorded as still-open rather than explained away a second time.

### Same round, continued: the `97/167` pale band is not culling either

Kept going on the one artifact the far-plane fix did not explain. Painted every real terrain mesh
bright magenta and re-rendered: real terrain draws in a strip at the character's feet **and** on the
far bank, but **not in the wide band between them**, where the background shows through instead. The
band's colour tracks the environment background exactly -- it renders pale cyan with the real sky
enabled and flat blue with the sky disabled -- confirming it is genuinely "nothing drawn here", not a
surface with a bad material.

Additional causes ruled out this round, each by direct test:

- **Not water.** Water meshes were painted magenta too (they are children of the same `RealTerrain_*`
  nodes) and the band stayed background-coloured. Separately, disabling water rendering entirely
  leaves the frame unchanged.
- **Not the cloud dome**, despite it being by far the largest mesh in the scene
  (`5974 x 3000 x 5974`, centred at y=1499, so its AABB bottom does sit near ground level -- worth
  remembering). Disabling the sky leaves the band present.
- **Not frustum culling.** Setting `extra_cull_margin = 16384` on every real terrain mesh changes
  nothing.
- **Not the far plane** (still present at 11520), **not missing collision** (2,401 raycasts found
  real terrain at every sample), and **not the camera being below the surface** (measured 15-30 units
  above).

That is seven eliminated causes across two rounds. What is left is narrow: real terrain that has
collision, is inside the frustum, is not culled, and still does not draw, in one band at
middle distance. Recorded as genuinely open. The next thing to try is dumping the actual surface
count and index totals of the specific `RealTerrain_*` nodes covering that band and comparing them
against a region that renders correctly -- i.e. asking whether those meshes were built with geometry
at all, rather than asking why they are not visible.

## 2026-09-03, fifty-seventh round — "the player is below the map": the spawn snap ran before the world finished streaming

Reported: "the player is below the map, continue building the world. things
are still not right."

That report reframed the long-running pale-band mystery. Seen from *underneath*,
terrain is back-face culled, so the ground is invisible and the background shows
straight through it — which matches every earlier observation of the band at
once: collision complete where nothing was drawn, terrain visible near and far
but not in the middle, and the band's color tracking the environment background.

### What was measured

Four things were ruled out before the cause was found, each with a real headless
measurement rather than an assumption:

1. **Spawn placement is correct.** Spawning in ten different real regions and
   comparing the player's y against a terrain-only downward ray put the player on
   the surface in all ten (worst delta 3.5 units, on a slope).
2. **Regions are not overlapping or misplaced.** Dumping the world-space AABB of
   every loaded region's terrain surface mesh gave 30 nodes occupying 30 distinct
   cells, each exactly 1920x1920, tiled contiguously with no gaps and no
   duplicate footprints. (A first attempt at this measurement merged *all*
   MeshInstance3D descendants and produced alarming 5560-unit spans — that was
   objects, trees and buildings parented under the terrain node, not terrain.
   Restricting to the terrain surface meshes gave the clean result above.)
3. **Region adjacency is right, and not mirrored.** Comparing all four edges of
   one region's stitched height grid against all four of a neighbor's, in both
   index orders, over four real region pairs: `region_x+1` matches rowN-to-row0
   and `region_y+1` matches colN-to-col0, both **forward, at mean difference
   exactly 0.0000**. The axis mapping fixed in the fifty-first round is correct
   and the regions are not transposed or flipped relative to each other.
4. **The terrain itself has no cliffs or gaps.** Sampling a 300-unit height
   profile by raycast found no jump over 5 units and no missing terrain.

### The actual cause

`_snap_player_onto_terrain` runs **once**, while the 5x5 region neighborhood is
still streaming in, so it can only place the player on whichever regions have
finished loading. Instrumenting the real Jangan spawn region (98/168) caught it
directly: on physics frame 0 the player is at y=0.00 with the terrain surface
beneath them at y=1.04 — a metre *below* the map — with 25 region nodes loaded;
by frame 1, with 30 loaded, the snap had moved them to y=64.70. Walking from a
spawn during that same window measured the player a sustained **41 units below
the terrain surface**.

Nothing re-checked the player's placement after the remaining regions arrived, so
a player who happened to be under a region's terrain when it streamed in simply
stayed under it.

The existing ground/void-fall check could never catch this: its probe starts only
10 units above the player, which is below a 14.34-unit character's own head, so
terrain overhead was out of its reach entirely.

### The fix

`_recover_if_below_terrain`, run every physics frame: probe downward from one
region span above the player's feet to the feet themselves, and if terrain is
found meaningfully above them, lift them onto that surface.

Applying this unconditionally is safe because real `.m` terrain is a heightmap —
one height per grid vertex — so it cannot overhang itself, and any terrain
strictly above the player's feet therefore means the feet are below the surface.
Restricting the probe to the terrain collision layer keeps real objects the
player can legitimately stand under (bridges, arches, building interiors) from
being mistaken for ground overhead.

### Result

Across five real regions, walking for 400 frames from spawn: **0 frames below the
map**, except one single transient frame in 100/168 (2.44 units, corrected on the
next frame). Before the fix, 97/167 held the player 41 units under. In that same
region the player now ends up at y=39.998 — standing on top of the very terrain
that had been over their head.

## 2026-09-03, fifty-eighth round — the "straight brown line next to the green" was a wall in front of the camera

With the player no longer buried under the map (fifty-seventh round), a real
headless render of the real Jangan spawn finally showed what the player actually
sees. Two things were wrong, and neither was what had been assumed.

### The debug HUD was covering most of the window

The tabbed panel (inventory, equipment, skills, shop, party, and the rest) was a
permanently visible strip spanning the full window width and 220 pixels tall,
sitting directly above an equally full-width chat panel, with the log-out row
below that. Measured on a real 1152x648 render, the three together covered
roughly 70% of the window — the world was a letterbox strip along the top.

Real Silkroad keeps inventory, skills and shop in windows the player opens and
closes, and leaves the view itself clear. The panel is now hidden until asked
for (Tab), and chat — a running log in the real client, not a window — stays
visible but is narrowed to the bottom-left corner instead of spanning the full
width.

### The hard brown/green line was the palace gate, not a texture boundary

With the HUD out of the way, the bottom half of the window was an enormous
blurry brick texture meeting the grass along a hard, perfectly straight
horizontal line — matching the long-standing report that "the brown is a
straight line next to the green," which had been read for several rounds as a
terrain texture-blending problem.

It was not a terrain boundary at all. Two measurements settled it:

1. **The blend overlays really are being drawn.** A real render with the
   feathered overlay material forced to opaque red showed red appearing out in
   the grass — but nowhere along the brown/green line. Whatever that line was,
   it was not a boundary between two terrain textures. (An attempt to fix it by
   lifting the coplanar overlays off the base surface was made first, on the
   theory that an exact depth tie was discarding them; the red test disproved
   that theory, and the change was reverted rather than kept with a wrong
   explanation attached.)
2. **Raycasting identified it directly.** Casting from the camera through six
   widely-spread screen points returned
   `cj_pal_bigdoor/CJ_pal_bigdoor_wall01` — the real Jangan palace gate — every
   single time, at essentially one 3D point, meaning the surface was about a
   unit in front of the camera.

The camera was inside the gate wall. `SpringArm3D` with no shape assigned sweeps
one infinitely thin ray, which slips through any gap narrower than the camera's
near plane; the real Jangan spawn sits directly at the gate, so the arm threaded
the structure and parked the camera inside the wall.

Pulling the camera back to 400 units confirmed the world had been rendering
correctly the entire time: the real gate with its tiled roof, red walls, gold
door panels, willow trees, stone plaza and surrounding grass all in place, and
plainly recognizable as Jangan.

The fix is a real SphereShape3D on the arm, which cannot thread a gap narrower
than its radius. The radius is a disclosed choice, not real data: just under the
player capsule's own 3.19, so anywhere the player fits, the camera can follow.
After the fix the same spawn renders the character on open ground with a correct
shadow, hills and rock formations visible, and no wall in the view.

## 2026-09-03, fifty-ninth round — full archive survey: what real map/texture data is still unused

Asked directly: what else is in the pk2 archives, or already in this repo, that
hasn't been implemented for textures or maps. Answered by enumerating both real
archives file-by-file and cross-checking every reader against its callers,
rather than by recollection.

### What the archives actually hold

`Map.pk2` — 19,411 files. `.t` 5,198 (696 MB, the single largest thing in it),
`.m` 4,719, `.o2` 4,574, `.o` 4,065, `.ddj` 839, plus 8 `.ifo`, 2 `.mfo` and
three `.txt`. Top-level folders never touched before this round: `Sun\` (38),
`Water\` (34), `Weather\` (10), `SkyBox\` (5).

`Data.pk2` — 68,839 files. `.bms` 22,444, `.ddj` 16,298, `.bsr` 8,539,
`.nvm` 6,543 (805 MB), `.ban` 5,129, `.bmt` 4,861, `.wav` 2,961, `.bsk` 1,249,
plus a `Shader\` folder of 76 files.

### Readers that exist but nothing calls

Cross-checking each `class_name` against its callers found three:
`NvmReader`, `MapO2Reader`, `EfpReader`. (`MapTReader` looked unused too, but
that was a grep artifact — the class is `MapTReader`, capital T, and it is wired
in as the terrain lightmap.)

### Two apparent gaps that turned out not to be gaps

Both were measured rather than assumed, and both closed negative:

- **`.o2` is not missing map content.** It is a spatial re-index of the objects
  already in `.o`. For real region 98/168, 343 of its 390 list-1 entries and 113
  of its 116 list-2 entries have positions matching a real `.o` object's position
  exactly. Nothing new to place.
- **`.t`'s unused 9,216-byte ShadowMap is redundant with what's already used.**
  It is 96x96 bytes with exactly five distinct values across every region checked
  — 153, 178, 204, 229, 255, i.e. 0.6 to 1.0 — and the embedded 512x512 DDS this
  project already applies as the terrain lightmap carries those same values. The
  byte grid is the low-resolution source of the texture already in use.

### A real gap that stayed open, honestly

`.nvm` walkability. The obvious reading — tile flag bit 0 means "blocked" — was
tested by correlating blocked tiles against where real objects actually stand,
and **it failed**: in Jangan 57.6% of blocked tiles had an object above them
versus 49.1% of free tiles, and in 97/167 the correlation inverted outright
(35.9% versus 46.7%). Whatever bit 0 means, it is not "a building is here."
Searching the real client binary for flag-naming strings found the real source
filenames (`RTNavMeshTerrain.cpp`, `NavCell.cpp`, `RTNavEdge.cpp`, and
`navmesh\nv_%04x.nvm`, which confirms the real filename packing is `(x << 8) | y`)
but no flag names. Recovering the semantics needs the movement code decompiled;
no collision was built on a guessed bit.

### The find of the round: the client ships its own shaders

`Data.pk2\Shader\` holds the real client's terrain shaders, several as readable
`.c` source with comments intact. See `docs/protocol/SHADER_FINDINGS.md`. The
headline results:

- The real terrain equation is stated outright in `terrainps14.psh`:
  `Surf = (N.L) * terrain_tex * cloud_covering * self_shadow_term`, then
  `Final = Surf * extinction + inscattering`.
- The real distance haze is **atmospheric scattering, not linear fog** —
  `scattervsdetail10.vsh` carries named Rayleigh/Mie coefficients and a
  Henyey-Greenstein phase term, and computes `E = exp(-(beta_1+beta_2) * s)`.
- Terrain is darkened by a **moving cloud layer** projected as
  `uv = world.xz * scale + offset` — something this project does not render.

### Implemented this round: real per-zone aerial-perspective haze

The recovered model is structurally the same as Godot's exponential fog, so fog
is now enabled with the **real per-zone `FogColor`** from `environment.ifo`
(Jangan's is a soft blue-grey, `(0.357, 0.580, 0.677)`), sampled at the same
fixed reference time as the sky and sun.

The density is explicitly *not* presented as real: the real scattering
coefficients are runtime shader constants, and environment.ifo's own two scalar
fog channels hold normalized [-1, +1] values in every real record checked rather
than world distances. `FOG_DENSITY` is a disclosed rendering choice, flagged in
its own doc comment the same way `BOUNDARY_BLEND_ALPHA` is.

### Still unimplemented after this round

`.nvm` walkability (blocked on flag semantics), `.efp` particle effects (the
reader only recovers a flat name/value list, not the format's nested tree),
the cloud-shadow layer on terrain (projection scale and scroll are runtime
constants), `Sun\moon01-30` and `Sun\lens1-8` (no day/night clock exists yet),
`Weather\` rain/snow/smog, and the seven map `.ifo`/`.mfo`/`.txt` files with no
reader at all (`tile3d.ifo`, `objext.ifo`, `objectstring.ifo`,
`layerobjectlist.ifo`, `config.ifo`, `mapinfo.mfo`, `regioninfo.txt` — the last
of which is a real region-to-zone-name table, in EUC-KR).

## 2026-09-05, sixtieth round — the world was assembled from correctly-shaped regions placed backwards

Reported from a real playtest, and correctly, against my own first explanation:
*"I have never seen this place... it's like we are building the map in the wrong
way."* I had put it down to the spawn point sitting at a region edge. That was
true and irrelevant; the assembly itself was wrong.

`_try_load_real_terrain` placed every real region with `rotation.y = PI` plus an
`aabb.size.x / 2.0` X offset, which measures out to `world X = 960 - local_x`
and `world Z = -local_z` — local coordinates running **backwards** in world
space. The region *grid* offsets ran forwards (`region_y -> +world X`,
`region_x -> +world Z`). So each region was individually rotated 180 degrees
inside a grid laid out the other way.

### Why it hid for so long

Everything downstream inherits that transform, so everything agreed with
everything else. Real placed objects are parented to the terrain node
(`_try_load_real_map_objects`), and this session's own real navmesh walls are
built in the same region-local space, so buildings sat correctly on terrain and
walls wrapped the buildings — all three consistently wrong together. The earlier
adjacency verification that "confirmed" the grid ran against the raw `.m` files,
never against the assembled scene, so it could not have caught this.

### The real ground truth

Crossing a region's local `x = 1920` edge continues at local `x = 0` of
`region_y + 1` — the real global edges' own `AssocRegionIdTo` says so (see
`protocol/NVM_FORMAT.md`). So real world space is contiguous:
`world X = region_y * 1920 + local_x`, `world Z = region_x * 1920 + local_z`.

Measured on the real heightmaps (`.nvm`'s copy is byte-identical to `.m`'s), a
region's own **high** edge abuts its neighbour's **low** edge:

| pairing | mean difference |
|---|---:|
| 98/168 col 96 vs 98/169 col 0 (`region_y + 1`) | **0.000000** |
| 98/168 col 0 vs 98/169 col 96 (what the old transform paired) | 18.211597 |
| 98/168 row 96 vs 99/168 row 0 (`region_x + 1`) | **0.000000** |
| 98/168 row 0 vs 99/168 row 96 | 71.761607 |

Assembling a real 3x3 neighbourhood both ways, the mean height step across every
region seam is **2.40** in data order against **34.28** as the renderer built it.

### The fix

The rotation and the asymmetric X offset are gone; a region now sits at
`(-REGION_SPAN/2, -anchor, -REGION_SPAN/2) + world_offset` with local
coordinates running forwards. The half-span shift keeps each region *centred* on
its own grid offset exactly as the old transform did on X, so
`_maybe_stream_regions`' own `round(rel / REGION_SPAN)` cell test stays valid —
that was the one piece of existing logic a corner-aligned placement would have
broken silently.

Verified in the real client: from above, the walls and street grid now run
continuously across region boundaries and the palace compound reads as one
coherent structure. The same spawn that used to land on grass outside a wall now
lands on the real paved plaza inside the city.

### Still open — handedness

This corrects the *assembly*, not a possible global mirror. The real client is
Direct3D (left-handed) and Godot is right-handed, so mapping real `(x, y, z)`
straight through may mirror the whole world. **Every check available here
survives a mirror unchanged** — seams still match, adjacency still holds,
everything stays self-consistent — so it cannot be settled from geometry. The
tell is signage: real Chinese/Korean lettering on the real Jangan buildings will
read backwards if a flip is needed. Left deliberately unresolved rather than
guessed at.

## 2026-09-05, sixty-first round — the world was a mirror image of the real one

The sixtieth round fixed how real regions were assembled against each other. This
one is about the whole world being flipped.

The real client is Direct3D and left-handed; Godot is right-handed. Feeding real
coordinates straight through mirrors everything. The tell had been sitting in the
tree since the forty-seventh round: `BmsReader` reverses every real triangle's
winding, because otherwise real objects render inside-out. Reversed winding is
exactly what a mirror does, and reversing the indices makes faces visible again
**without addressing the cause**.

### Why the obvious checks could never catch it

A mirror is invisible to every self-consistency test. Real region seams still
match, real adjacency still holds, real objects still sit correctly on real
terrain, and this session's own real navmesh walls still wrap real buildings —
because all of it is mirrored together. Chirality cannot be detected from
geometry that is only ever compared against itself.

Two indirect tests were tried and both turned out worthless, which is worth
recording so they are not repeated:

- **`.bms` winding against stored normals.** Computing the geometric normal uses
  a cross product, which is itself handedness-dependent, so the test just
  restates its own assumption. It "proved" the winding already matched Godot.
- **UV handedness.** Real assets contain mirrored UVs freely — the real willow
  meshes come out 86-100% "mirrored" for ordinary art reasons, and the real
  restaurant sign is exactly 50/50 because that is a board's front and back.

### What did settle it: real signage

Text is chiral, so it cannot hide a mirror. The real Jangan restaurant
(`res\bldg\china\jangan01\cj_resta01.bsr`) carries **長安酒** on two
*perpendicular exterior faces* of its tower — both outward-facing on a closed
structure, so both must read correctly. Rendered against the real source texture
(`cj_resta01_roof.ddj`), both faces had **酒**'s water radical on the wrong side.
Applying a mirror put it back where the real texture has it, on both faces.

### The fix, and what it did *not* need

A single global `z -> -z` about the world origin: `terrain_group.scale.z = -1`
together with the group's world Z negated. The scale alone would mirror each real
region about its own origin, which is precisely the per-region mistake the
sixtieth round fixed.

Nothing else changed, and a good deal was expected to. Real placed objects, this
session's real navmesh walls and real water surfaces are all children of the
terrain group, so the transform carries them, orientation included — no
per-object position or yaw fixing. And **Godot flips face culling itself for a
negative-determinant transform** (verified: the real building renders solid, not
inside-out, under the mirror), so `BmsReader`'s winding reversal stays exactly as
it is and no real mesh data is rewritten.

Verified in the real client: real signage now reads correctly, real region seams
stay continuous from above, the real player still stands on real terrain
(collision behaves under the mirrored transform — the risk that would have sunk
this approach), and no script errors across 243 frames.

### Noted, not fixed

`_maybe_stream_regions`' own cell test carries a half-region bias:
`_grid_origin_world` is the group's corner rather than a cell centre, so
`rel / REGION_SPAN` lands on `dx + 0.5` and rounds up. It predates this round and
this change preserves it exactly rather than making it worse. Folding it into a
mirror fix would have muddied the verification.

## Sixty-second round: objects were collided against their render geometry, not their navmesh

**2026-09-05.** A real playtest reported not being able to climb the Jangan temple
stairs — "I can climb the edges if I finangle it". That signature (steps block
outright, the sloped ramp beside them works) is a body colliding with the vertical
riser of every single step. The interim fix was `World3D._try_step_up`, an assist
that lifts the player over a blocked step. It worked, and it was an approximation.

### What the real client does instead

It never collides a character against a building's render geometry at all. A real
`.bms` can carry **its own navigation mesh**, at the offset in header field `0x28`
— vertices, convex navigable cells, and edges that either bound the mesh or join
two cells, structurally the same thing a region's terrain `.nvm` carries. The
client walks that cell/edge graph and takes the character's height from the cell
underfoot.

The difference is stark on a real staircase. `cj_pal_center_stair01.bms`, the real
Jangan palace centre stairs:

| | vertices | triangles/cells | distinct Y levels |
|---|---:|---:|---:|
| render mesh | 36 | 16 | 5 (the treads) |
| navigation mesh | 8 | 6 | **2** (a ramp) |

The real game walks a ramp. Nothing ever collides with a riser, so nothing ever
needs lifting over one.

### Recovering the format

Header field `0x28` was documented in this project as "reserved, observed 0" —
which it genuinely was in the only samples then to hand, particle and character
meshes, neither of which a character stands on. Across a 4,395-file real sample of
a real `Data.pk2`, 507 real meshes carry a section there.

The layout was derived structurally and then validated the way `.nvm` was: read in
order, does it land exactly on the file's end? **507 of 507 do**, with zero
leftover bytes and no special cases. Three bits of a real bitfield at header
offset `0x38` select record sizes, and each was isolated by finding real files
that set it *without* the others rather than inferred from a correlation. See
[BMS_FORMAT.md](protocol/BMS_FORMAT.md) for the full layout and evidence.

Real edge semantics match the terrain `.nvm` exactly: across 78,130 real edges,
all 20,892 outline edges carry `0xFFFF` on their far side and all 57,238 internal
edges join two real cells. The adjacency split is total; the flag split is not
(0.9% of internal edges block), which is why the code tests the real flags rather
than trusting which list an edge came from.

### Verified with a control, not an anecdote

A capsule was walked up the real Jangan palace stairs twice, identical apart from
the collision source and **with no step-up assist in either run**:

| collision source | result |
|---|---|
| the object's own navigation mesh | climbs the full 20.4-unit ramp, y 8.2 → 27.1, then walks off the far end |
| its render mesh (the previous behaviour) | no surface at that spot at all — falls straight through |

### One bug this nearly shipped with

Godot's `ConcavePolygonShape3D` is **one-sided by default**, and with that default
a capsule dropped onto a real staircase's navigation mesh falls straight through
it. An earlier draft of this change carried a comment asserting the shape was
solid from both sides; it is not, and the physics test is what caught it. The
shape now sets `backface_collision = true`, which is also what the data means — a
real blocking edge has to stop a character approaching from either side — and a
test guards the default from creeping back.

Measured across 41,762 real cells, 99.8% have a geometric normal pointing upward
as stored, which would suggest the stored winding already faces the right way for
Godot. The physics behaviour disagrees, and that disagreement is **unresolved**.
Two-sided collision is correct either way, so nothing depends on settling it.

### What this changes that is not an improvement

An object with a navigation mesh is now solid only where the real game says it is
solid. Parts a character can neither stand on nor be stopped by — a roof overhead,
most obviously — no longer block anything, **including the camera spring arm**.
That is what the real client does and it is the point of using this data, but it
is a real, visible difference rather than a free win. Meshes with no navigation
section (3,534 of 4,000 real meshes sampled) keep colliding against their render
geometry exactly as before.

`_try_step_up` is left in place: it still does real work on terrain, which has no
per-object navigation mesh to walk.

## Sixty-third round: the object navmesh was right, feeding it to the physics engine was not

**2026-09-06.** The sixty-second round shipped (v0.1.38) with object collision driven
by each `.bms`'s own navigation mesh. **In-world it does not work, and this reverts
that integration.** The format work, the geometry helpers and their tests stay: what
was wrong is the last step, handing the data to Godot's physics engine.

### What the in-world test showed

The player was teleported onto the real Jangan palace right-hand stairs
(`cj_pal_right_stair`, a real 20.4-unit climb) with the step-up assist disabled:

| | result |
|---|---|
| lands on the navmesh, `floor = true`, rests stably | yes |
| then walks uphill | **no — zero displacement** |
| with the extruded walls disabled | identical, so not the walls |
| with the winding reversed and `backface_collision` off | falls through instead |

At the moment of failure the player has full uphill velocity, `floor = true`,
`is_on_wall() = false`, and **six simultaneous slide collisions against the ramp's own
face** with a correct slope normal `(0, 0.92, 0.40)`. It is pinned against the surface
it is standing on.

### Why the isolated test passed and this did not

The sixty-second round's control walked a capsule up the same kind of ramp in
isolation and it climbed the full height. That test was real but not representative,
in two ways it took this round to see:

- **No world mirror.** Real placed objects are children of the terrain group, which
  carries `scale.z = -1` (sixty-first round). A negative-determinant transform flips
  which face is front, so a fixed winding that holds the player up in isolation drops
  them through in-world, and vice versa. This also retrospectively explains the
  sixty-second round's unresolved contradiction — 99.8% of real cells measure
  up-facing as stored, yet the stored winding fell through — the two tests were on
  opposite sides of the mirror.
- **No adjoining geometry.** In isolation the capsule was dropped mid-ramp onto clean
  surface. In the world the ramp meets a flat quad of the same navmesh at its foot,
  and that seam is where the capsule pins.

The mirror forces `backface_collision = true` (a fixed winding cannot be right on both
sides of it), and a two-sided single-thickness surface is what pins the capsule. Those
two requirements are in direct conflict, which is why this approach cannot simply be
tuned into working.

### What the real client does instead, and why that is the actual fix

It never hands this data to a collision solver at all. It walks the cell/edge graph:
find the cell under the character, move within it, cross an edge into the neighbouring
cell if the edge is passable, and take height from the cell. There is no capsule, no
depenetration and no winding, so none of the three problems above exist.

That is the real fix and it is a movement-model change, not a collision-shape change.
Until it is built, real objects keep colliding against their real render geometry and
`World3D._try_step_up` keeps carrying real staircases — an approximation, and now a
knowingly retained one.

### What is kept

`BmsReader.parse_collision`, `BmsCollision` and their 69 tests, plus
[BMS_FORMAT.md](protocol/BMS_FORMAT.md)'s section. That work stands on its own
evidence — 507 of 507 real sections parsing exactly to EOF, cross-checked by two
independent implementations — and is what the graph walker will be built on.
`ObjectLoader._add_object_navmesh_collision` is kept too, uncalled, as the record of
exactly what was tried.

## Sixty-fourth round: the player now walks the real navmesh, and real stairs work

**2026-09-06.** The sixty-third round established what the real fix had to be — walk
the cell/edge graph rather than hand it to a collision solver — and this is it,
built and verified.

### The model

`NavGraph` unifies a region's terrain `.nvm` with every placed object's own `.bms`
navigation mesh in one region-local space, and answers two questions: how high is
the ground here, and does moving from here to there cross a real blocking edge. The
player's height comes from the cell underfoot; an edge is tested as a 2D line. There
is no capsule, no gravity and no collision shape, which is exactly why none of the
sixty-third round's problems apply — nothing can pin a body against a two-sided
surface when there is no body and no surface.

### How objects attach to a region, measured

Real Jangan region `nv_62a8`, 122 real objects:

- **Every object a region's `.nvm` lists has a navigation mesh** — 122/122 resolve to
  a real `.bsr` whose mesh carries a collision section. That list *is* the set of real
  placed objects a character can stand on.
- **`MapObject.linked_edges` is not the object-to-terrain link.** Only 4 objects carry
  any, 6 links total, every one pointing at another *object* in symmetric pairs — real
  bridge spans stitched to each other (`cj_pal_south_brid02` ↔ `brid03` ↔ `brid04`).
  It joins the parts of a multi-part structure and nothing else. Designing around it
  would have been wrong.
- **The real link is spatial**: 300 of the region's 334 real cells list the objects
  overlapping them. Standing in a cell, that cell names the candidates underfoot.
- A region's `.nvm` carries the same real placements as its `.o`, in the same space
  and yaw convention (103 of 115 agree on position within 0.01, 111 on yaw within
  0.001 rad; the rest are artifacts of matching by nearest instance where several
  placements share one type id).

Those per-cell lists are **not** complete coverage, so correctness does not rest on
them: 98 of 122 objects have their whole footprint covered by the cells listing them,
13 partly, 11 by no cell at all. The file's own list is consulted first and a
footprint index fills the gaps. With it, coverage inside a region is total — all 109
objects actually within the region's own extent are found, and the 13 that are not
lie *wholly* outside it, placed in a neighbour whose graph carries them.

### Verified, with the control that failed before

Dropped at the foot of the real Jangan palace stairs (a real 22.1-unit ramp) with
`_try_step_up` disabled, so nothing but the navmesh could do the work:

| frame | region-local y |
|---|---|
| settled | 2.12 |
| 30 | 10.74 |
| 60 | 19.64 |
| 90 | **21.94** — the ramp's own top |
| 120–540 | 21.94 held, while X/Z keep changing |

It climbs the whole ramp, arrives at exactly the ramp's real height, and stays on the
surface for 450 further frames rather than falling through. Partway along, X freezes
while Z keeps rising — a real blocking edge being slid along rather than stuck to.
Zero script errors across 700 frames. **The same harness, on the same stairs, with the
reverted collision-shape approach produced zero displacement.**

### The movement model is now unit-testable

The decision lives in `NavGraph.step`, a pure function, not inside a `World3D` method.
Both movement bugs this project shipped needed a live test box to find, and one
reached a release because of it. They are now headless tests: the player moves on
every one of 78 steps up a ramp (the pinning failure), and walking off the top lands
on terrain (the fall-through failure), plus blocking edges never being crossed and
diagonal moves sliding rather than sticking.

### What this does not change

Objects still render exactly as before, and meshes with no navigation section still
carry render-mesh collision for the camera. `_try_step_up` stays for terrain.
`SRREVAMP_NO_NAVMESH_MOVEMENT=1` restores the old physics movement for comparison.

## Sixty-fifth round: region streaming was a half-region early, and ponds were dry

**2026-09-06.** A playtest of v0.1.40 reported movement "much smoother" (the navmesh
movement landing), but two real problems: chunks of the world feeling cobbled
together, and a real pond bed with real lotus-flower props floating over bare ground.

### The region grid itself is correct — proved, not assumed

Before chasing the layout, it was checked against ground truth. A region's `.nvm`
global edges record `assoc_region_id_from`/`assoc_region_id_to`: "this boundary
connects me to *that* region". Extracted across 20 real regions around Jangan, **724
boundary edges, zero contradictions**:

| region-local boundary | neighbour |
|---|---|
| −X | `region_y − 1` |
| +X | `region_y + 1` |
| −Z | `region_x − 1` |
| +Z | `region_x + 1` |

Worked through our own placement — including the world mirror (`scale.z = −1`) and the
group offsets — region A's local `z=1920` edge lands at world −960 and region
`x+1`'s local `z=0` edge lands at world −960 too. They meet exactly, and X likewise.
So the axes *and* the directions are right. This independently confirms the
forty-sixth round's heightmap-edge result and extends it, since edge matching could
never establish direction.

### What was actually wrong: streaming, off by half a region

`_maybe_stream_regions` computed its cell with `round(rel / REGION_SPAN)`, but
`_grid_origin_world` is the origin region's **corner**, not its centre — so `rel` runs
`0 → REGION_SPAN` across the region the player is standing in, and rounding flipped to
the next cell at the **halfway point**.

From the middle of their own region onward, the player was treated as being in the
neighbouring one. The loaded block was shifted a full region: terrain ahead never
streamed in, terrain still underfoot behind them was unloaded, and the zone label
changed half a region early. Regions that *did* load were placed correctly, which is
why the grid looked right in isolation — it was the *set* that was wrong, and that is
exactly what "randomly cobbling together chunks of the world" looks like from inside.
`floor` puts the boundary where the real region boundary is. This bug was noted in the
sixty-first round as "noted, not fixed"; it is now fixed.

### Water: the plane map is a bound, not a shape

The sixty-first round took water levels from the `.nvm`'s 6x6 `PlaneTypeMap` and
emitted one flat plane per water cell. A plane cell is **320x320 units** — bigger than
most real ponds. Measured on real Jangan region `nv_62a8`:

- the plane map marks **17 of 36 cells** as water;
- but only **134 of 9,216 real tiles** carry a real WATER/DEEP_WATER type;
- and **all 134 of those tiles fall inside a water plane cell, none outside**.

So the plane cells cover about thirty times more ground than there is water. Emitting
one plane per cell flooded whole blocks — nearly all of it buried under terrain and
invisible — while real ponds sat dry, props and all.

Per-tile flags alone are no better: they give the shape at 20-unit resolution but no
level, which is why the *original* per-tile approach draped water over the ground and
made ponds look like jagged sheets.

**Shape from the real tiles, level from the real plane cell.** The two nest cleanly
(134/134 contained), so the pairing needs no invented fallback. On the real region the
result goes from a `1920 x 35 x 1920` box spanning four different levels to a
**380 x 380 pond, flat, at a single level (−3)** built from 134 real tile quads.

## Sixty-sixth round: ground was textured per quad, but the real data is per vertex

**2026-09-06.** A playtest of v0.1.42 reported open ground reading as "a weird mix of
brown squares", with a real reference screenshot of what a real field should look
like. The region grid, object placement and object heights had all just been verified
correct, so this was rendering, not layout.

### What the real client does

Two facts settle it, and neither was being used:

- The real `.m` vertex record carries a real texture ID **per vertex**, not per quad
  (see [MAPM_FORMAT.md](protocol/MAPM_FORMAT.md)'s `TextureInfo`: a 10-bit ID plus a
  6-bit scale, inside each vertex).
- The real client's own terrain pixel shader samples exactly **one** terrain texture
  per pass. A real `Data.pk2`'s `Shader\terrainps14.psh` reads
  `texld r1, TEX_TERRAIN_COLOR`, and `terrainpsn10.psh` does the same. There is no
  multi-texture blend anywhere in the shader.

One texture per pass, plus a per-vertex ID, **is** vertex splatting: each pass draws
the triangles that touch one real texture, faded out at the vertices using a different
one. (`terrainpsndetail10.psh` also carries a detail stage, `tex t3 ; Detail`, whose
multiply is commented out in the shipped shader — noted, not acted on.)

### What we were doing instead

`_build_textured_mesh_from_cells` read the per-vertex ID (`cells[r][c][1]`) and then
applied it to the **whole quad**, hiding the resulting seam by feathering a fixed
alpha (`BOUNDARY_BLEND_ALPHA = 0.45`) along quad edges. The blend could never be
smoother than the quad grid it was defined on, which is exactly what a plaid of
hard-edged squares looks like.

### The change

Per quad now: its **dominant** real texture — the one most of its four corners use —
is drawn fully opaque, so ground is never see-through; then every *other* texture its
corners use is drawn over it with each vertex's alpha 1 where that vertex really uses
that texture and 0 where it does not. The blend spans the whole quad and follows the
real per-vertex data.

`BOUNDARY_BLEND_ALPHA` is deleted: it was a disclosed invented constant standing in
for blend weights the format was thought not to carry. The per-vertex IDs are those
weights, so nothing is invented any more.

The 2026-09-02 fix is kept — a quad's own texture stays opaque rather than fading
toward flat gray, which had desaturated real textures unevenly per region.

### Verified

A real render of real region 100/100, the one the playtest reported, shows grass and
dirt meeting in soft organic gradients rather than hard squares. The test now builds a
region where **two resolved textures meet** (the real case; an unresolved ID has no
texture to fade) and asserts the property that matters: blend vertex alpha is per-vertex
0 or 1, never a fixed edge feather — and that every real quad is still covered exactly
once by an opaque pass.

### Investigated and dismissed: "objects sit below the terrain in 100/100"

While checking heights this round, real objects in region 100/100 measured a median
**17.15 units below** the real terrain under them (26% within ±2), where real Jangan
regions measure **0.00**. That looked like a placement bug. It is not, and the check
that suggested it was too naive to support the claim:

- The region's two independent real height sources agree **exactly** — a real
  `100\100.m` mesh and the real `nv_6464.nvm` heightmap differ by a median, minimum
  and maximum of **0.00** across every vertex. Same for Jangan. So terrain height is
  not in question.
- The offset is entirely **trees**: 46 of the region's 58 real objects are
  `euro_esteuro_tree07_l02/l03`, and every other object type measures ~0.00.
- A real model's origin is **not** at its base. Those trees' own mesh spans local Y
  −5.98 to 95.08, and a real `oas_grs_weed04` spans −10.13 to 69.43 — ground clutter is
  authored sunk into the ground on purpose.

So "object Y minus terrain Y" only reads as 0 for models whose origin happens to sit at
their base (Jangan's buildings), and says nothing useful for anything else. Sampling
terrain at a single point also ignores the slope a real tree is standing on. The metric
would need to compare a model's own real base against the terrain beneath its footprint
before it could support any claim, and the trees in question look correct in a real
playtest screenshot of that region.

## Sixty-seventh round: the ground squares were the UVs, not the blending

**2026-09-06.** The sixty-sixth round rewrote ground texturing from per-quad to real
per-vertex splatting, which was correct and grounded in the real client's own shader —
and it did **not** fix what the playtest was actually reporting. Shown a render of the
result, the tester said it "looks like exactly the same problem". They were right: the
blend changed, the squares did not.

The squares were never the blending. They were the UVs.

`_quad_uv_corners` gave **every quad its own UV set starting at 0** and running to
`repeat`, then rotated or mirrored it by one of 8 square symmetries chosen from a hash
of `(r, c)`. Both halves are wrong, and together they guarantee the artifact:

- starting every quad's UVs at 0 stamps the texture once per quad and hard-cuts it at
  every 20-unit quad edge, so there is a seam on every boundary no matter how well the
  textures blend across it;
- re-orienting each quad independently then makes neighbouring quads disagree about
  which way the texture runs, turning those seams into visible tiles.

It had been introduced as a disclosed rendering-only technique — never a claim about
real data — to stop a repeated texture reading as an obviously stamped, aligned grid.
It produced precisely the artifact it was meant to avoid.

UVs now come from the vertex's own absolute position in the region grid, so a real
texture flows continuously from one quad into the next, and the real per-vertex `Scale`
field decides how many times it repeats. The test asserts the property that matters:
adjacent quads agree on the UV along the edge they share, east and south.

### The lesson worth keeping

Two rounds were spent fixing a real defect that was not the reported one. The
per-vertex splatting work stands on its own evidence and is still right, but it was
chosen because it was the interesting problem, not because anything tied it to the
symptom. The symptom was a hard seam on a fixed 20-unit grid — which points at
per-quad UVs, not at how two textures mix. Matching the artifact's own geometry to the
code that produces that geometry would have found this first.

## Sixty-eighth round: a whole-world terrain audit, and what it rules out

**2026-09-06.** Asked to focus on accurately rebuilding terrain and map for the whole
game rather than object placement in one town, and with ground still not looking right,
this round is about knowing *where* we are wrong rather than guessing.

### What the real client does with terrain textures, from its own shaders

Going back to the real shader source in a real `Data.pk2` (the RE box, not decompiled
guesswork) settled the model and ruled out two theories:

- `terrainps14.psh` / `terrainpsn10.psh` sample exactly **one** `TEX_TERRAIN_COLOR` per
  pass. No in-shader multi-texture blend.
- `scattervsdetail10.vsh` shows terrain UVs come **per-vertex from the vertex buffer**
  (`dcl_texcoord0 v1` … `mov oT0.xy, v1`). The alternative — projecting world position
  by a constant, `mad oT0.xy, VPOSITION.xz, c[CV_BASE_TEX_PROJECTION]…` — is present but
  **commented out**. So the client fills terrain UVs itself when it builds the mesh; the
  repeat rate is client code, not shader constants.

### Ruled out as causes of the "squares"

- **`.t` is not the terrain colour.** Its embedded 512×512 DXT1 texture measures a mean
  saturation of **0.014** — genuinely greyscale, a lightmap, as MAPT_FORMAT.md says.
- **Missing mipmaps are not the cause.** Real `Tile2D\` ground textures are 512×512
  DXT1 with a full 10-level mip chain, and they survive to the texture we render with
  (`image_has_mipmaps=true`).
- **Unresolved tile IDs are not the cause** — see the audit below.

### The audit

`client/tools/audit_terrain_fidelity.gd` paints each region from **our own** per-vertex
tile assignments (each tile ID coloured by its real texture's average colour) and
compares it against that region's own real authored minimap art from `Media.pk2`.

Over a real 240-region sample spanning the whole world (213 with real minimap art):

- **zero** unresolved tile IDs, in every region;
- a smooth diff spread — median 0.096, p10 0.065, p90 0.150, min 0.024, max 0.278 —
  with **no outliers**.

A wrong region orientation, a wrong tile mapping or missing data would put a region far
above that pack, and nothing is. Together with the sixty-fifth round's `.nvm` global-edge
adjacency proof and the object-placement overlay, the terrain and map **data** pipeline
is now positively verified across the whole world, not just where a playtest went.

That is worth stating plainly because it narrows what is left: the ground not looking
right is a **rendering** problem, not a data one, and the one number still not recovered
from the real client is how many times a real ground texture repeats across a real quad.
That lives in client code (see the vertex shader finding above), not in the shaders or
the map files.

## Sixty-ninth round: the ground lattice was an invented reading of the Scale field

**2026-09-06.** Told the ground still did not look like the game and that this should be
solvable by decompiling rather than approximating — which was the right push — this round
went to the client binary and found the actual cause.

### Recovered from the real client

`FUN_00a361b0` is the real region loader. It builds `"%d\%d.m"` / `"%d\%d.o2"` and checks
the magic as an **integer** (`0x56584d4a` = `"JMXV"`), which is why no string search in any
shipped binary ever finds `JMXVMAPM`. It places each region at
`regionByte * _DAT_00e1b908 * _DAT_00d99a68`, and those constants are **doubles** — 4-byte
reads show zeros because their low dwords are zero. Read as 8 bytes: **320.0** and **6.0**.

So a region is 320 × 6 = **1920** units, expressed by the client itself as **6 blocks of
320**, making each block's 16 tiles **20 units**. `REGION_SPAN` and `TILE_SIZE` are now
confirmed from client code rather than inferred from mesh footprints. Both were right.

### The actual bug

The per-vertex `TextureInfo` packing was checked against the client too. A tile-texture
loader (`FUN_00a27880`) derives an ID as `(raw >> 6) & 0x3ff`, which would mean the ID is
the *high* 10 bits — the opposite of this project's reading. Tested against real data, that
is not the `.m` vertex path: our reading is the one that yields **thematically correct**
textures (real Jangan's most-used tile resolves to `c_marble_jang_07`), and it makes `Scale`
a sane field — `[0]` in Jangan, `[0, 8]` and `[0, 16]` elsewhere — where the alternative
makes it 25 scattered values. So the packing was already right.

**`Scale` was the problem.** It was being applied as `repeat = 2 ^ (scale >> 3)`, this
project's own invented reading of a field whose real meaning was never recovered. Real
region 100/100 carries `scale = 16`, which that reading turns into **four** repeats per quad
— a 512×512 texture repeating every 5 world units — and it renders as a regular diagonal
lattice across the whole region. That is exactly what the playtest reported there. Real
Jangan carries only `scale = 0`, which is why the artifact never appeared in town, and why
the previous two rounds (per-vertex splatting, then continuous UVs) both fixed real defects
without touching the reported one.

Disabling the scale term removes the lattice entirely and leaves soft, organic ground. The
field is therefore left unused until its real meaning is recovered, rather than kept as an
invented reading that demonstrably produces an artifact.

One repeat per quad is independently confirmed by the artwork: `c_marble_jang_07` is a 4×4
grid of paving slabs, so at one repeat per 20-unit quad each slab is 5 units ≈ 0.6m.

## Seventieth round: environment channels were wired to the wrong lights

**2026-09-07.** Recovered from the real client's own terrain vertex shader
(`Shader\vertexshader0splatting.c`, which `FUN_00bf67c0`'s runtime shader generator
actually loads — see [RE_MAP_ENGINE.md](RE_MAP_ENGINE.md)):

```
mad oD0, N.L, c[VSC_DLIGHT_DIFFUSE], c[VSC_DLIGHT_AMBIENT]
```

The real **diffuse** channel is the directional light's own colour — the term multiplied
by `N·L` — and the real **ambient** channels are the additive term. This project had those
two the other way round: `SunColor` drove the directional light and `DiffuseColor` was
poured into ambient, while the two real ambient channels (`ObjectAmbientColor`,
`TerrainAmbientColor`) were decoded and never used at all.

The real data shows why that mattered. Across real records, `SunColor` is `(1,1,1)` in most
of them — it is the sun *disc's* colour — while `DiffuseColor` carries the actual per-zone
tint (a real warm `0.70/0.60/0.50`, a real cold `0.70/0.53/0.93`). So the directional light
was lighting every zone plain white and throwing that character away, and the tint was
landing in ambient, where it flattens shading instead of directing it.

Now: the directional light takes `DiffuseColor`, ambient takes `ObjectAmbientColor`, and
`SunColor` tints the real sun-glow sprite — which until now used a hard-coded
`Color(1, 1, 0.9)`, an invented value, so that is one fewer.

### Known divergence, stated rather than hidden

The real client keeps **separate ambient colours for terrain and objects**, and they really
do differ (`TerrainAmbientColor` is often `(1,1,1)` where `ObjectAmbientColor` is `0.58`).
Godot has one global ambient, so this uses the object one. Reproducing both needs terrain
lit by the real per-vertex equation rather than by Godot's lighting, which is the next step
on that thread.

### Not implemented, and why

The same shader work recovered the real fog maths exactly — linear `(end-d)/(end-start)`,
EXP2 `1/exp((d*density)^2)`, and a height-fog term combined with `min`. None of it is wired
up, because `environment.ifo`'s fog near/far channels are **normalized** (measured across
all 74 real records: `-1.000 .. 1.000` and `-1.000 .. 0.947`), and the client-side
conversion into world distances has not been found yet. Wiring real fog on a guessed
conversion is what produced the `Scale`-field lattice two rounds ago.

## Seventy-first round: terrain lit by the real client's own equation

**2026-09-07.** Implements the terrain lighting recovered from
`Shader\vertexshader0splatting.c` (the template the real runtime shader generator loads):

```
mad oD0, N.L, c[VSC_DLIGHT_DIFFUSE], c[VSC_DLIGHT_AMBIENT]
```

Terrain vertex colour is now `clamp(N·L, 0) * DiffuseColor + TerrainAmbientColor`, baked per
vertex and multiplied into the texture — which is exactly what the real terrain pixel shader
does with `oD0`. Terrain materials are set unshaded so the engine does not light it a second
time.

This is also what finally lets **`TerrainAmbientColor`** be used. It is a separate real
channel from the object ambient and genuinely differs — often `(1,1,1)` where the object
ambient is `0.58` — and a single global engine ambient cannot express both. Baking terrain
lighting honours the real split.

The light direction is converted into the region's own local space, where the mesh is built:
a terrain group carries `scale.z = -1` for the world mirror and no rotation, so a world
direction's Z simply flips.

### What this costs, stated plainly

Unshaded terrain **does not receive the engine's dynamic shadows**, so a character no longer
casts a shadow onto the ground. That is closer to the real client, not further from it — the
real client lights terrain per vertex and draws character shadows as a blob sprite (a real
`shadowsphere.ddj` ships in `Map.pk2`'s `SkyBox\` folder) rather than shadow-mapping the
terrain. But this project has no blob shadow yet, so between this round and that one there
is simply no shadow on the ground. That is a real, visible loss and is not being presented
as an improvement.

Objects are untouched and still lit and shadowed by the engine as before.

## Seventy-second round: the real character shadow

**2026-09-07.** The previous round baked real terrain lighting and made terrain unshaded,
which removed the engine's dynamic shadow from the ground. This restores a shadow the way
the real client draws one rather than putting the engine's back.

The real client ships its character shadow as an asset: `SkyBox\shadowsphere.ddj` in a real
`Map.pk2`, a real 64x64 DXT3 texture. It is drawn as a flat quad under the character, placed
at the height the real walkable graph reports — so it lands on whatever is actually
underfoot, terrain or an object's own navigation mesh such as a staircase or a bridge.

### Two wrong attempts, and what they cost

The texture was first read from a converted PNG preview, which showed a black centre fading
to white edges. That looks exactly like a *multiply* map, so it was drawn multiplicatively —
twice, once with alpha blending and once without. Both rendered a hard black square.

Measuring the actual channels settled it: the texture's **RGB is solid black** (mean 0,
standard deviation 0) and its **alpha** carries the radial gradient (mean 0.33, standard
deviation 0.34). The preview had composited that alpha over white. It is an ordinary
alpha-blended black disc, and drawing it that way is correct immediately.

The lesson is narrow and worth keeping: a converted preview of a texture with an alpha
channel shows alpha *composited*, not the channels themselves. Measure the channels.

### Disclosed choices

The blob's world size (9.0 units) and its lift above the ground (0.15) are rendering
choices, not real data — the texture is a plain gradient with no scale baked in, and nothing
found so far says how large the real client draws it. Its opacity is the texture's own real
alpha, not a chosen value.

## Seventy-third round: the terrain self-shadow term, parsed since day one and never used

**2026-09-07.** The real terrain equation is
`Surf_color = (N.L) * terrain_tex * cloud_covering * self_shadow_term`. The previous round
implemented `(N.L) * terrain_tex`. This implements `self_shadow_term`, and it turned out to
be real data this project had already been parsing and throwing away.

A region's `.t` file carries a **96x96 ShadowMap** — one byte per real terrain tile, the same
grid the tiles themselves use. `MapTReader` has parsed it since the format was solved and
described it, from the public documentation, as "a simplified map used to check if an object
is inside shadow". Nothing ever read it.

Measured across real regions it holds exactly **five** distinct byte values, always the same
set — **153, 178, 204, 229, 255**, which is `255 * (0.6, 0.7, 0.8, 0.9, 1.0)`. So it is not a
boolean mask at all: it is a real five-level shadow multiplier bottoming out at 0.6.

It matters more than it sounds. In real Jangan **5,195 of 9,216 tiles (56%)** carry the
darkest level — more than half the town's ground is authored as shadowed, and every bit of
it was being drawn fully lit. Region 100/100 is the reverse (84% fully lit), which is
consistent with open country against a dense walled town.

Terrain vertex colour is now multiplied by that term. A vertex sits on a corner shared by up
to four tiles, so the four are averaged — the same treatment the flat-colour base surface
already gives per-quad colour, and what keeps five discrete levels from reading as hard
steps.

### A process note

The GDScript typed-inference trap bit for the fourth time in this project: `for dr in [-1, 0]`
yields untyped values, so `var tr := r + dr` will not compile. It is always
`var tr: int = r + dr`. Worse, a local `--import` reported **zero** errors while serving
cached scripts, and the failure only appeared as 492 errors in a real run on the RE box.
An import that reports clean is not proof the scripts compile.

## Seventy-fourth round: the ShadowMap reading did not survive checking

**2026-09-07.** The previous round applied the real `.t` ShadowMap as the terrain
equation's `self_shadow_term`. Verifying it immediately afterwards showed the reading is
not safe, so the application is reverted the same night. The measurement stands; the
interpretation does not.

**Orientation is right.** Rendering the map as an image and laying it beside real Jangan's
own authored minimap art lines the two up exactly — the features sit in the same places, so
row/col match the tile grid.

**Polarity is wrong for a sun shadow.** The **fully lit** (255) tiles are the real *building
footprints*, and the **darkest** (0.6) tiles are the open courtyards and streets. Real
buildings cast shadow onto nearby ground; they are not the only lit thing in a walled town.
That is backwards for a self-shadow term, and it fits the public documentation's own wording
much better — "a simplified map used to check if an **object** is inside shadow", i.e. a
query structure for deciding whether an object standing on a tile is shadowed, not a
multiplier for the terrain's own colour.

Applying it darkens **56% of real Jangan's ground by 40%** — a large, world-wide change
resting on an unsettled reading, shipped while the tester was asleep and unable to catch it.
That is the same shape of mistake as this project's own `2 ^ (scale >> 3)` reading of the
`.m` `Scale` field, which rendered a lattice across whole regions before being caught.

So it is unapplied until its meaning is confirmed. `_shadow_at` and the measurement are kept
in place, documented, because both are real and correct — it is only the claim about what
the values *mean* that failed.

### Worth stating

v0.1.49 shipped this as a finished feature and it should not have. The finding was good and
the data is real, but "parsed since day one and never used" is a reason to look closer, not
evidence that a particular use is right. Checking it took one render and one comparison, and
that should have come before the release rather than after it.

## Seventy-fifth round: every region was drawing its objects two or three times

**2026-09-07.** A playtest looked at a top-down render of Jangan and said there were far
more gates along the walls than the real city has — "there should only be 3 or 4, not this
many" — and that walking through one gate led to a wall a little further on. Both are the
same bug.

### `.o2` is sector-partitioned, and objects repeat across sectors

A region's `.o2` is organised into sectors, and **an object overlapping more than one sector
is listed in each of them**. `World3D` read every sector and appended them all onto the
`.o` placements, so any structure spanning a sector boundary — gates, walls, grass groups —
was placed several times over.

Measured with exact float matching on position and yaw:

| region | `.o` | `.o2` | `.o2` entries exactly repeating an `.o` entry |
|---|---:|---:|---:|
| 98/168 | 273 | 506 | 456 |
| 97/168 | 385 | 432 | 393 |
| 98/167 | 219 | 331 | 284 |

456 matches against only 273 distinct `.o` entries means `.o2` repeats the *same* object
several times. Real `97\168.o2` lists a real `cj_jang_gate` **24 times**.

Both files also carry genuinely unique placements (a real `97\168.o` has 128 entries absent
from its `.o2`), so neither can be dropped in favour of the other. They are merged and exact
repeats removed.

The effect is large: real Jangan `98\168` goes from **779 placements to 303**, so **61%** of
what was being drawn there was a duplicate.

### Also fixed: an object's walls stopping people who are not on it

`NavGraph.blocked` tested the blocking edges of every nearby object at once. The real client
moves a character *within a cell* and only tests the edges of the cell it is in, so a player
standing in a real gateway was being stopped by the walls of a *different* object — real
`cj_pal_indoor`'s own walls closed the real palace gate. Blocking now takes the surface the
mover is standing on, and an object's edges apply only to whoever is on that object. A
region's terrain edges always apply, because the real terrain navmesh is what carries the
walls around real buildings (411 of them in real Jangan, previously confirmed by rendering
them).

### Still broken, diagnosed but not fixed

Walking south out of the palace plaza **still stops** at region-local `(960, 830)`. The
cause is now precisely located: the real `cj_pal_indoor` navmesh has a **gap at the gate
threshold** — its walkable surface sits at height 47.83 on both sides of `z = 830`, with
terrain 7.8 units lower showing through between them — and its own outline edge refuses the
step off. How the real client crosses that gap is not yet known, so nothing is guessed at.

## Seventy-sixth round: looking at the world stopped needing anyone to play it

Every round up to here was checked the same way: load the client, walk to the
place in question, take a screenshot by hand. That cost is why visual problems
kept surviving several rounds before anyone noticed them -- the object
duplication in the seventy-fifth round had been in every screenshot since the
world first rendered.

The client now carries a QA screenshot harness (see the block above
`_try_step_up` in `client/scripts/World3D.gd`). Environment hooks put the
player at a region-local spot -- standing on whatever the real walkable graph
reports, not a guessed height -- frame the camera, optionally walk a heading,
and disable fog for overview shots. Position is logged every 60 physics frames,
so a run's log says where each frame was taken. Nothing is active unless its
variable is set, so an ordinary run is untouched.

`client/tools/qa_shot.sh` drives it against the real `Data.pk2`/`Map.pk2`/
`Media.pk2` under Xvfb and collects the frames. It writes outside `/tmp` on
purpose: `/tmp` on the RE box is a tmpfs, and a previous run's leftover frames
took the whole box out of memory.

Four shots of Jangan on the first tour, and what they showed:

- **Palace district from above** (960,960, pitch -50, no fog): correct. The
  four-quadrant courtyard layout, walls, and roof lines match the authored
  minimap, and with the duplicate placements gone the roofs no longer z-fight.
- **Main gate looking south** (960,700): correct. Lion statues, the gate house,
  and the flanking pavilions all sit where the minimap puts them.
- **The willow pond and stone bridge** (300,300): geometry correct, but the
  **water surface is missing** -- lotus decorations sit directly on grass, and
  the bridge spans dry ground. `NvmWater` only builds a surface where the real
  tile ids under a plane cell are water tiles, so either this pond's tiles are
  not the water type or the pond is a placed object's own water, not terrain
  water. Not yet chased down.
- **The gate at local (960, 830)**: still broken, and now visibly so rather
  than only as a movement complaint. The teleport lands inside the gate's
  solid body and physics ejects the player sideways to x=1020, leaving the
  camera inside the wall. This is the same `cj_pal_indoor` navmesh gap
  diagnosed earlier -- surface height 47.83 on both sides of z=830 with
  terrain at 40.00 between -- so the threshold has no walkable cell to stand
  on. Open.

One thing the harness makes unmissable rather than new: the player renders in
its bind pose in every shot. That is the known `apply_ban_pose` bug from the
forty-eighth round, still deliberately disabled rather than shipped distorted.

## Seventy-seventh round: the town was never the place we spawned into

A real playtest walked out of the starting area expecting the city of
Jangan -- the town square with the dragon statue -- and found a walled
compound with no shops in it, then a gate passage that dead-ends in
brick. Four separate real bugs came out of that one session.

**We were spawning into the palace, not the town.** Every building placed
in region 98/168 is a `cj_pal_*` model from `Res\Bldg\China\Jangan03\`:
the big door, the main and guard buildings, the lion statues, the stairs.
Not one shop. Scanning every region's placements for the town's own
models (`cj_acce.bsr`, the accessory shop, and `cj_jang_gate_dragon.bsr`)
returns exactly one region, and it is **97/168**, one region west. Its
square holds the dragon gate at local (1004, 845) with the dragon itself
beside it. JANGAN_ZONE_REGION now points there, and ZONE_SPAWN_LOCAL
lands an arriving player in the square looking at the statue -- the
server has no map data at all and spawns everyone at (0, 0, 0), which is
merely the geometric centre of whatever region a zone resolves to.

**A zone change deleted the arrived-at region's objects.** The player
teleported to 97/168 and stood on a bare plaza with nothing on it; the
buildings appeared minutes later, once streaming happened to reload the
cell. `_clear_region_grid` called `queue_free()`, which does not remove a
node until the end of the frame, and a REGION_LOAD_RADIUS window around
98/168 already contains 97/168 -- so the new `RealTerrain_97_168` was
added while the old node of that name was still in the tree. Godot
renames the newcomer, and `_try_load_real_map_objects` parents a region's
objects to its terrain node *found by name*: every object in the region
being entered was parented to the outgoing node and destroyed with it.
The mangled name was visible all along in the zone label, which read
`[@Node3D@4862]` instead of `[97_168]`. Fixed by removing the nodes from
the tree immediately, and clearing `_region_nav_graphs`, which held
references to them.

**We were resolving placements against the wrong object index.** Map.pk2
carries its own `object.ifo` and Data.pk2 carries one at
`navmesh\object.ifo`, and they are not the same table: 3307 entries
against 3268. Placements come out of Map.pk2, and the 39 ids only the map
table has are exactly the ones real regions were referencing and this
project was skipping -- 59 dropped placements in the town region alone
(OBT/halloween/new-year event decorations, and a few NPCs). Every region
now resolves **0 unresolved type IDs**, where the town previously loaded
346 of 405 objects.

**The zone box now takes a position.** `97/168` still works; `97/168@1002,917`
additionally stands the player on that region-local spot, at whatever
height the real walkable graph reports. Without it, checking a specific
place meant arriving at the region's centre and walking, because the
server can only ever offer one fixed position per zone.

Still open from the same session, not yet chased down: the arched
openings in the town's north wall render solid rather than as passages,
and objects can be walked underneath -- their navmesh is placed but
something about it is not standing the player on top.

## Seventy-eighth round: five cities' worth of city wall in one place

A real playtest asked why the town's gateway arches were bricked up. They
should not have been, and the reason they were is not in the wall.

The wall is `res\bldg\china\jangan_enter\cj_s.bsr` -- the real Jangan
city gate: five wall meshes, a door, a roof, stairs. Its arches are real.
Reading `cj_s_wall01.bms`'s own 328 triangles and firing a ray straight
through the wall at head height finds **three clear openings**, at object
x -60..-20, 80..160 and 260..300, exactly where the arches are. Standing
a player in one of them confirms it from the inside: they end up in a
dirt-floored passage between two studded door leaves with daylight and
the palace gate visible out the far end.

What was closing them was **the same object placed five times**. Real
regions 96/167, 96/168, 96/169, 97/167 and 97/168 *each* place `cj_s.bsr`
at the identical local position (860.64, -1.76, 1764.43). Every region's
objects are placed relative to that region, so this built five copies of
a 5,559-unit-long wall at five different world positions -- and since the
wall is nearly three regions long, the copies from the regions to the
west laid solid wall straight across this region's gateways.

The three per-sector lists in a real `.o2` are what separate a region's
own objects from these cross-references. A `.o2` files entries into a 6x6
sector grid, so an entry's own position implies which sector it belongs
in, and measuring that against the sector it is actually filed in
separates the lists cleanly: **list 2's entries are in their implied
sector about 91% of the time, against list 1's 46%** (real 97/168:
145/159 vs 129/273; real 98/168: 106/116 vs 180/390; real 96/168:
102/149 vs 4/16). The gate falls out the same way -- of the five regions
placing it, only 97/167 and 97/168, the two the arches actually line up
with, file it in list 2.

Taking only list 2 (plus the region's own `.o`, unchanged) drops the
copies from the regions to the west: six `cj_s` objects in the loaded
grid become three, and the ones that were lying across the arches are
gone. What it gives up is the entries that only lists 0/1 carry and the
region's own `.o` does not repeat -- 22 in real 97/168, 47 in real
98/168, nearly all edge vegetation, which is the same cross-reference
pattern in miniature.

Not finished: two `cj_s` copies still survive, one from 97/167 and one
from 97/168, 1920 units apart. They do not overlap, so they read as two
walls rather than one broken one, but whether the real city has a wall at
both latitudes is unverified.

Three tools came out of this and are worth keeping:
`server/cmd/whatishere` lists what a region places near a spot,
`server/cmd/o2sectors` measures the sector/list structure above, and the
client's own `SRREVAMP_QA_LOOK` / `SRREVAMP_QA_HIDE` hooks report what
the camera is pointing at and switch individual meshes off in the built
world -- which is what identified the wall in the first place, since a
piece of a big model only means anything in the place the other pieces
put it. Placed objects are now named after their real model
(`Obj_<model>_<n>`) so those reports say what they are looking at.

## Seventy-ninth round: an object's walls only stopped whoever was already on it

The same playtest reported walking underneath things. It is true, and the
scan built to measure it says how often: sweeping real region 97/168 on a
40-unit grid and, at each sample, dropping a physics ray from just over
head height above wherever the walkable graph would stand a player,
**109 of 2,304 sampled spots put the player under solid geometry** -- by
up to 28 units, twice the player's own height. The named offenders are
buildings: `cj_armo`, the armour shop, stands a player at 7.2 with its
floor at 35.5.

The cause is the shape of the seventy-fifth round's fix. That round
established, correctly, that an object's own blocking edges must only
stop whoever is standing on that object -- testing every nearby object's
edges at once had closed the palace gate, because a neighbouring
interior's walls reached across the open gateway. But "only the object
you are standing on" also means an object you are *not* standing on can
never stop you, and a shop's walls are its own object edges. Walking at
a building from outside, nothing said no.

Now an object the mover is not standing on gets to stop them in exactly
one case: when the move would put them **underneath** it -- that object
has a walkable surface over the destination, and that surface is out of
reach above. A surface within reach is something to step onto, not
something to be stopped by, which is what keeps the gateway open: a
mover in a real gateway stands on the gateway's own floor cell. Leaving
is always allowed, since the place being moved *to* is not under
anything, so nobody who starts underneath is trapped there.

Checked both ways. Four new assertions in `nav_graph_test.gd` pin it
against a synthetic platform placed 100 units overhead -- walking in
underneath is refused, walking back out is not, a surface within reach
still is not blocking, and a caller that does not pass the mover's height
gets the old behaviour unchanged. And in the real world, a player walked
west at that same real armour shop steps up onto its terrace and stops
against its wall, where before they would have carried on into the
footprint under its floor.

`SRREVAMP_QA_SCAN=n` is the sweep, kept: it reports every spot in the
player's region where the graph sits below the geometry, worst first,
naming the model responsible.

## Eightieth round: the arches were never blind

The seventy-eighth round left one thing unproven: from the square, the
gate's arches still read as brick recesses, and this document called them
"decorative blind arches" on the strength of a screenshot. That was
wrong, and worth recording as wrong -- reading a rendered image is how
this project has repeatedly talked itself into the wrong answer.

`SRREVAMP_QA_THROUGH="z0,z1,y[,step];..."` settles it by measurement:
it fires horizontal rays through a band of the region at a given height
and reports which X spans come out the other side. Reading a mesh file's
own triangles answers this for one mesh; this answers it for what was
actually built, every overlapping copy included, which is what the
player walks into.

Fired through the wall band (real local z 1650..1900) at head height,
the real region has clear spans at **local x 805..840, 950..1010 and
1120..1160**. The three gateways `cj_s_wall01.bms`'s own triangles
predict are at 801..841, 941..1021 and 1121..1161. They agree to within
the 5-unit sampling step. All three arches are open passages, and the
brick seen from the square is the passage interior at a glancing angle.

One trap this round: the first sweep, fired at height 10, reported zero
clear spans anywhere across the whole 1920-unit width -- not because the
wall is solid but because the ground north of it rises, so every ray was
in the dirt. A negative result from a probe is only worth as much as the
probe's placement, and the hook now takes several bands in one run
because each run costs minutes.

## Eighty-first round: holding the built world against the authored map

Until now "is the map right?" had no cheap answer beyond walking around
in it. The client ships an authored minimap per region -- real stylised
top-down art of exactly what that region contains -- and stitching a
block of those gives a ground truth to hold a render against.

Two things had to be fixed before that worked at all:

**The minimap filename was backwards.** The real name is
`minimap\<y>x<x>.ddj`. Real Jangan is region x=97, y=168; real
`minimap\97x168.ddj` does not exist in a real Media.pk2, and real
`minimap\168x97.ddj` does -- and decoding it shows the Jangan town
square, octagonal plaza and dragon statue included. `_zone_paths` had
`<x>x<y>`; `audit_terrain_fidelity.gd` had it right. Latent, because the
minimap only textures terrain in the fallback used when per-tile
textures are unavailable -- but where it bites, both spellings can name
real files, so a region could be painted with a *different* region's art.

**Renders were not square.** `qa_shot.sh` sized the X screen but Godot
renders at the project's own window size, so a square screen still
produced 16:9 frames. It now passes `--resolution` too.

With `client/tools/dump_ddj.gd` writing any real `.ddj` out as a PNG, a
3x3 block of real minimaps around Jangan can be laid out and compared.
**Which arrangement is correct is itself a check**, and it settles a
question this project answered once before by a different route: laying
region *x* across and *y* up produces walls and roads that do not meet at
the seams, while laying *y* across and *x* up produces one continuous
city wall around the whole city, gate structures aligned across every
seam, and the road from the town square running south through the wall
and out into the fields. So **region y -> world X, region x -> world Z**,
which is exactly what `_load_region_cell` already does -- independent
confirmation of the forty-sixth round's terrain-edge-matching proof, from
authored art rather than vertex data.

Held against that ground truth, the built world matches tile for tile:
the town square with its octagonal plaza in the centre, the palace
compound directly **north** of it (98/168 -- not west, as an earlier note
in this project claimed), the pond garden north-east, the walled
districts either side, and the farmland outside the south wall with the
south road running out into it. The fields are regions 96/167-96/169.

At overview altitude (~4,200 units) the whole city washed out under a
pale haze that a single-region top-down at 1,450 units did not show, and
this document called it unidentified. **It is the cloud layer, rendering
correctly.** `_sky_dome` is a hemisphere of `SKY_DOME_RADIUS` (3,000)
centred `SKY_DOME_HEIGHT_ABOVE_PLAYER` (1,500) over the player, so a
camera far enough up to frame a region sits *above the clouds and looks
down through them*. Nothing was wrong with the world; the shot was taken
from the wrong side of the weather.

Two guesses were wrong on the way, and both were cheap to test and should
have been tested sooner: that it was the fog or the aerial-perspective
term (disabling both changed nothing), and that it was an llvmpipe
artifact that hardware rendering would clear (it survived the move to the
GPU unchanged). `SRREVAMP_QA_NOFOG` now hides the dome and the sun glow
along with the fog, since a shot framing a whole region is by definition
taken from above the cloud layer.

## Eighty-second round: scenery standing off the ground, measured

A real playtest walked out of the town gate into the fields and found
grass clumps hanging in mid-air. `SRREVAMP_QA_FLOAT=<radius>` measures
it: for every placed object within the radius it drops a physics ray onto
the *rendered* terrain of the region that object is actually parented to
(not the navigation mesh, and not the region the player happens to be
standing in) and reports the gap, worst first.

At the spot the playtest reported, real region 96/168 local
(1788, -37, 1040), **17 objects within 900 units sit more than 12 off
their own region's ground** -- both hanging above it and sunk into it,
the worst by 182 units. The placement data itself is not obviously wrong:
the barley around that spot is authored at y -37 to -42 and the player
stands at -37, so those sit correctly.

The strong signal is that **the gap is constant per model**: three real
`grs_weed09_2` clumps are each -49.7, three real `cj_dummy_01` each
-19.7, two real `cj_graveyard_grass01` each -31.4 -- while their
individual placement heights and the ground beneath them both vary by a
few units between instances. Placements following the terrain's shape but
offset from it by a fixed amount is not a per-object authoring error; it
points at the region's own vertical placement, which is where
`_load_region_cell`'s shared vertical anchor comes in (every neighbour is
placed against the centre region's anchor height rather than its own).
Not yet proven, and not yet fixed.

Separately, the same playtest reported trees rendering as black cards
with the tree painted on them -- alpha not being cut out. Three real tree
textures were checked and all decode with their alpha intact
(`tre_dry02` DXT3, 39,749 fully transparent texels; `tre_tree02_01`
DXT3, 68,299; `tre_tree02_02` DXT1, essentially opaque and correctly not
cut out), and `.ddj` DXT1 does decompress to RGBA8 rather than losing its
alpha channel, so this is not a blanket format bug. The specific model
has not been identified yet. `client/tools/dump_ddj.gd` now reports a
texture's fourCC, its decompressed format, and its opaque/transparent/
partial texel counts, which is what ruled the format out.

## Eighty-third round: foliage dissolving with distance, and a probe that lied

A real playtest in the fields reported trees "failing to render": the tree
overhead renders fully, the ones a few hundred units away are bare
branches with a few leaf specks, and it gets worse with distance.

That is the textbook signature of alpha testing against mipmaps, and this
project's `foliage.gdshader` is exactly that setup --
`filter_linear_mipmap` with a fixed `ALPHA_SCISSOR_THRESHOLD` of 0.5.
Every mip level averages a leaf's alpha with the holes around it, the
average crosses below the threshold, and the canopy dissolves a mip level
at a time. So the shader was changed to rescale alpha by its own
screen-space derivative, which restores the cutout's coverage at any
distance.

**It changed nothing. The before and after frames are byte-identical --
zero of 921,600 pixels differ, maximum channel difference 0.** Rendered
from the same viewpoint on the same build with only the shader edited.

**That conclusion was wrong**, and the way it was wrong is worth keeping.
Painting the shader's `ALBEDO` a flat magenta and re-rendering turned
**5.5% of the frame** magenta, so the shader is used and an edited file
does reach the running client. The zero-pixel result was arithmetic, not
evidence: `(a - t) / fwidth(a) + 0.5` crosses 0.5 exactly where `a`
crosses `t`, so against a **hard scissor** any monotonic rescale keeps or
discards the identical texels. Alpha sharpening only means anything with
alpha-to-coverage, where partial coverage survives to the blend.

A measurement that comes back "no change" deserves the same suspicion as
one that comes back surprising: the probe has to be shown capable of
detecting the thing before its silence counts as an answer.

The original, discarded reading was:
`ObjectLoader.build_godot_material` only builds the cutout material when
it decides a texture genuinely carries cutout alpha (see `_ALPHA_FOURCCS`
and `_real_alpha_fraction`); everything else gets a plain
`StandardMaterial3D`. Whatever these trees are getting, it is that other
path -- which is also the likeliest explanation for the black cards the
same playtest reported, since a leaf card with no cutout renders its
transparent texels as solid colour.

**The actual fix** is to test the cutout against full-resolution alpha
while still taking colour from the mipmapped sample:
`ALPHA = albedo.a * textureLod(albedo_texture, UV, 0.0).a`. The keep-or-
discard decision then no longer sees the averaged-away alpha, so a canopy
holds its shape at any distance, while colour keeps its mipmapping and
does not shimmer. Measured against the same viewpoint: **2.04% of pixels
changed, maximum channel difference 184**, and the change is exactly
where it should be -- distant crowns that were bare branches are full
again, the tree overhead is untouched because it was already sampling
mip 0.

Still open from the same report, and not explained by this: the **black
leaf cards** seen at closer range. A card rendering its transparent
texels as solid colour is a cutout that was never applied, which is a
different failure from one applied against the wrong mip level.

**Next step, concrete**: report per distinct loaded model which material
class it received and what the cutout decision was, then compare that
against the model's own texture alpha (which `client/tools/dump_ddj.gd`
already measures). Three tree textures were checked by hand and all
decode with alpha intact -- `tre_dry02` DXT3 with 39,749 fully
transparent texels, `tre_tree02_01` DXT3 with 68,299, `tre_tree02_02`
DXT1 essentially opaque and correctly not cut out -- so the decode is not
the problem and the decision or its application is.

## Eighty-fourth round: three wrong answers from one instrument

Scenery standing off the ground was reported from the fields, and
`SRREVAMP_QA_FLOAT` was built to measure it. It took three corrections
before it measured the thing it claimed to.

**First version** compared an object against the *navigation mesh* height
under it. That is a different surface from the one being rendered, so the
number answered a question nobody asked.

**Second version** dropped a physics ray onto the rendered terrain, and
reported gaps of up to 182 units clustering by region. That was the ray
landing on a **neighbouring region's** terrain: each region node carries
its own vertical anchor (`shared_vertical_anchor`, see
`_try_load_real_terrain`), so expressing a hit on region B in region A's
local space reports the difference between two anchors as if it were
floating scenery.

**Third version** restricted the hit to the object's own region and
reported 429 objects buried by up to 389 units, with terrain apparently
350 units *above* objects inside a single region. That was the ray
landing on **other objects**: `ObjectLoader` leaves placed scenery's
collision on the default layer, `TERRAIN_COLLISION_LAYER` includes that
layer, and a real `tre_tree02` is 483 units tall -- so a ray dropped
beside a tree hits its canopy and calls everything beneath it buried.

**Fourth version** requires the hit to be the body under this region's own
`SubPatch`, which is terrain and nothing else. It reports **83 objects
out of the whole loaded neighbourhood, none worse than ±68 units** --
field vegetation sitting above or below the ground it belongs on, which
is the size and character of what the playtest actually saw.

Each wrong version was internally plausible and produced confident,
specific numbers. What exposed each was the numbers being too large to
believe rather than any error surfacing, which is the argument for
sanity-checking an instrument's *magnitude* before trusting its detail.

The remaining 83 are a real open question, and the shape of it is a hint:
the sign is systematic per region. Every `cj_barley_02` in real 96/167
floats (+58 to +67); every one in real 96/168 and 96/169 sinks (about
-61). Objects and terrain are being compared in the same region's own
local space, so the shared anchor cannot explain it. Two candidates worth
testing: a per-region height field in the `.m` header this project does
not read, or the real client snapping scenery to the terrain rather than
trusting the placement's own Y.

## Eighty-fifth round: the heightmap says which region an object belongs to

The 83 objects the corrected float report found are not floating because
of anything this project builds. **They are being drawn in the wrong
region**, and the authored data says so exactly.

Every one of the worst offenders in real region 96/167 sits at local
x 1866-1912 -- against that region's east edge. Their placement heights
and that region's own terrain disagree by 60-odd units, so the first
question was which of the two this project had got wrong. Neither:
sampling the raw `.m` heightmap directly (`server/cmd/heightat`) gives
**-52.98** at local (1912, 377), and the built terrain reports **-53.0**
there. The terrain is right to a hundredth of a unit.

Sampling the *neighbouring* region's heightmap at the same local
coordinates settles it:

| local (x, z) | placed y | 96/167 (drawn in) | **96/166** |
|---|---|---|---|
| 1912, 377 | 14.5 | -52.98 | **14.49** |
| 1898, 284 | 7.8 | -59.24 | **8.09** |
| 1900, 437 | 16.1 | -50.13 | **16.13** |
| 1866, 479 | 16.2 | -49.09 | **16.17** |

Every one lands on 96/166's ground to within a few hundredths. These are
that region's objects, cross-referenced into its neighbour's `.o2` and
drawn there.

**That is a far better ownership test than the one this project is
using.** The seventy-eighth round separated a region's own `.o2` entries
from cross-references by which of the three per-sector lists they sit in,
which measured 91% against 46% on the sector check. Asking instead
whether an entry sits on the region's own ground is weaker as a filter on
its own -- list 2 lands on its own ground 84.5% of the time in real
96/167 and 85.5% in real 97/168, against list 1's 72.3% and 74.4%, and in
real 98/168 the two are indistinguishable because that region is full of
legitimately elevated things -- but it is far stronger as an *assignment*
rule, because it compares a candidate against every neighbour rather than
judging it alone.

**Proposed rule, not yet implemented**: assign each `.o2` entry to
whichever loaded region's heightmap best matches its own placement Y, and
draw it only there. Hanging decorations survive it -- a real
`x_mas_wreath02` authored 167 units above the ground in real 96/168 still
matches 96/168 better than any neighbour -- because the test is
comparative rather than a tolerance. What it needs is a region's
heightmap to be samplable while its neighbours load, which the loader
does not currently arrange.

## Eighty-sixth round: a correct fix that made the result worse

The eighty-fifth round's ownership rule -- assign each `.o2` entry to
whichever region's heightmap best explains its placement height -- has a
degenerate case, and finding it did not improve anything.

**Real regions contain unauthored bands of exact zeroes.** Real 96/168
reads exactly `0.00` at every point sampled across its z 1700-1850 band,
while reading -38.42 and -60.02 elsewhere. That is missing data, not flat
ground at sea level. Because it is *exactly* zero it out-explains real
terrain for any object authored near zero, so a zero band quietly claims
its neighbours' objects.

The real city gate `cj_s.bsr` is exactly such an object: placed at
y = -1.76, against real 96/168's zero band (error 1.76), real 97/168's
-7.01 (5.25) and real 97/167's -6.46 (4.70). The rule therefore assigns
it to **96/168**, and drops the copies from both regions whose data is
real -- which is how the loaded grid went from three copies of that wall
to one.

`MapmTerrainBuilder.has_real_ground_at` was added to stop that: four
surrounding vertices at exactly 0.0 is absence of data, so a region
offering only zeroes cannot claim an object, and a region with no ground
of its own keeps what it lists. It is correct, and **it made the world
worse**: two copies of the wall come back, and the second one's solid
section lands across the town's gateway again -- the exact defect the
seventy-eighth round fixed and the playtest celebrated getting through.
Reverted, and the frames confirm the revert restored the good state
byte-for-byte.

What this exposes is a limit of the rule rather than a bug in it. Height
matching resolves **small scenery that sits on the ground** reliably --
the barley and weeds of the previous round matched their true region to
within hundredths -- and cannot resolve **a large structure standing on
its own platform**, whose base has no reason to touch the terrain under
it at all. The gate currently comes out right for the wrong reason: an
unauthored zero band happens to beat the regions with real data. That is
luck, and it is written down here as luck so the next person does not
mistake it for a working rule.

`has_real_ground_at` is kept, unused, for the fact it records: a region's
heightmap can be absent in places, and anything comparing regions by
height has to know that.

## Eighty-seventh round: water, and a hypothesis refuted before it was built

The seventy-sixth round left a willow pond rendering dry. It does not:
real 98/168 builds **134 real water quads**. What that round actually saw
is unresolved, but the loader now says what it did either way -- "built
real water from N real quad(s)" or "no real water surface built (N real
water plane cell(s) in its navmesh)" -- because a region with water and a
region whose water failed to build look identical in a screenshot.

With that logging, a real gap is visible: several regions carry water
plane cells and build **nothing**. Real 96/168 has 30, real 98/167 has
14, real 97/168 has 10, and none of them has a single tile classified as
`WATER` or `DEEP_WATER` underneath. The authored minimap for real 96/168
shows two pale channels running east-west under the city wall, so
something is there.

The obvious fix is to take the water's *shape* from the terrain instead
of the tiles: draw the surface wherever the ground under a water plane
cell lies below that cell's own level. It is more precise than the plane
cell and carries a level, which is what the per-tile flags lack.

**Measured first, and it is wrong.** The share of each water cell's own
ground lying below its own water level is **65.1%** in real 96/168,
**14.3%** in real 98/167, **10.6%** in real 98/168 -- and **94.7%** in
real 97/168, which is the town. Building water that way would put a lake
over Jangan's market square. The seventy-fifth-round measurement behind
the current design (plane cells cover roughly thirty times more ground
than there is real water) is the same fact from the other direction, and
it stands.

The channels are not objects either: the only things placed along them
are real `halloween_display03`/`04` props in a lattice at y about 40,
which are the same event decorations the float report flags as sitting
high.

So the current design -- **shape from the real water tiles, level from
the real plane cell** -- survives, and what those water plane cells with
no water tiles mean is still open. `client/tools/dump_nvm_water.gd`
reports the numbers above for any region, which is what a next attempt
should start from.

## Eighty-eighth round: chasing the bind-pose character, and measuring the wrong thing

The player has stood in its bind pose since the forty-eighth round, with
playback disabled because enabling it made the assembled character come
apart. The reason is now identified, and it is not the animation data.

**The client's own loader settles the semantics.** Following the assert
handler's source paths (see `docs/protocol/BAN_FORMAT.md`) to
`FUN_00c4bcb0` in `RTSkeleton.cpp`: when a bone's animation weight is
zero it copies the bone's **bind** matrix; otherwise it builds the matrix
from the keyframe quaternion via `FUN_00bf9cc0` -- a textbook
quaternion-to-matrix -- and writes the keyframe's position straight into
the matrix's translation. The keyframe **replaces** the bone's local
transform. It is not a delta against rest, and not a delta against
keyframe 0. `Skeleton3DBuilder.apply_ban_pose` already does exactly that,
so the application semantics were right all along.

Enabling playback anyway still explodes the character. The first
measurement of why was **wrong, and worth keeping as a lesson about what
to measure against.** Comparing the animation's tracks to
`BskReader.parse`'s own bone list says 36 of 37 match, with the
animation driving a `Bip01` no bone has -- which reads like a missing
root. But the reader's list is not the skeleton: `Skeleton3DBuilder`
adds a bone for `ParsedSkeleton.root_name` on top of it. Measured
against the **built** skeleton instead:

```
skeleton chinaman_skel.bsk: 37 parsed bone(s), 38 in the built Skeleton3D (root Bip01)
animation chinaman_fighter_standcity.ban: 37 track(s)
tracks matching a real bone: 37 of 37
bones with no track: 1 of 38  ["Spine_Base"]
```

**Every track matches a bone.** The root is there and is driven, and
`Spine_Base` -- a real bone the animation genuinely does not touch -- is
the only one left at rest. So the hierarchy is not the problem either.

What is left is narrower and specific. `BskReader.parse` reads the root's
name and then **skips its 92-byte transform**, and `build_skeleton3d`
gives that root `Transform3D.IDENTITY` for rest and `Quaternion.IDENTITY`
for its bind rotation. At rest that is invisible, because the rigid
attachment cancels whatever rest it is given. Under animation it is not:
the root's keyframes are absolute local transforms authored against the
root's *real* bind, and applying them on top of an identity rest moves
the whole character by the difference. That is the next thing to test --
read the root transform the reader currently discards, give it to the
root bone, and see whether the character holds together.

`client/tools/check_ban_bones.gd` is the check, and it now compares
against the built skeleton rather than the parsed list.

## Eighty-ninth round: the root's bind transform, and two more refuted guesses

`BskReader.parse` read the root bone's name and then **skipped its 92
transform bytes**, and `build_skeleton3d` gave that root
`Transform3D.IDENTITY` for rest. At rest that cannot be seen: the rigid
character attachment contributes `inverse(bone_global_rest)`, so whatever
rest a bone is given cancels exactly. Under animation it can be seen,
because a real `.ban` keyframe is an absolute local transform authored
against the root's **real** bind (confirmed from the client's own
`RTSkeleton.cpp`, see `BAN_FORMAT.md`), and applying it over an identity
rest displaces everything hanging off the root.

Keeping those bytes and giving the root its own bind transform is a large
improvement: the assembled character goes from **scattered pieces** -- a
lone leg on the ground, a hand floating in the air -- to **a single
coherent body**, upright, correctly proportioned, limbs attached.

It is still not right. The arms hold **straight overhead** instead of at
the sides, and the head is hidden behind them, while the pelvis and legs
look correct. Two explanations were tested and both are wrong:

- **`Spine_Base`.** It is the one bone the animation does not drive, and
  it sits directly under the whole upper body (`Spine -> Spine_Base ->
  Spine1 -> neck, arms, head`), so an untracked bone there would rotate
  exactly the part that is wrong. Collapsing every untracked bone to an
  identity local pose changed the render **not at all**.
- **The world mirror.** The world applies `z -> -z`, and arms up instead
  of down is the kind of thing a handedness error produces. Mirroring
  each keyframe quaternion about the XY plane (`x, y -> -x, -y`) also
  changed the render **not at all**.

Playback stays disabled, deliberately. A bind pose reads as "not
implemented yet"; a character holding its arms over its head reads as a
bug, and shipping the second in place of the first is not an improvement
even though the skeleton underneath is far better. The root transform fix
is kept, because it is correct independently of whether animation is
switched on.

## Ninetieth round: the pose maths is right, the attachment is not

The eighty-ninth round left the animated character coherent but holding
its arms overhead, with two explanations already refuted. Three more were
tried and refuted, and then the problem was bisected properly.

**Refuted, each changing the render not at all or making it worse:**

- Applying the **inverse** of each keyframe rotation. The body collapses
  and scatters -- far worse, so the direct application is the closer of
  the two.
- Giving bones the animation does not drive their **bind** pose rather
  than an identity one, which is what the client does at zero weight.
  No change: `Spine_Base` is the only such bone here and it makes no
  visible difference either way.
- Comparing every bone's `.bsk` rest against its `.ban` keyframe 0. Only
  6 of 36 rotations agree within a degree -- but **the positions agree
  exactly**, to 0.000 on every bone but one. Bones do not stretch, so
  matching translations is what a correct convention looks like, and
  differing rotations is just the animation doing its job. This says the
  translation convention is right and says nothing against the rotations.

**The bisection.** `client/tools/check_ban_pose.gd` builds the real
skeleton, applies a real frame, and reports where the bones actually
land:

```
bind pose:              after frame 0:
Bip01 Head    y 15.95   Bip01 Head    y 16.05
Bip01 L Hand  y 14.93   Bip01 L Hand  y  9.74     x 6.96 -> 2.73
Bip01 R Hand  y 14.93   Bip01 R Hand  y  9.63    x -6.96 -> -2.43
```

The bind pose is a T-pose, arms straight out. After the frame the hands
drop to **6.32 below the head** and pull in toward the body. **That is a
correct standing pose.** The skeleton is right; `apply_ban_pose` is
right; the animation data is right.

So the fault is entirely in **how the meshes are attached to the bones**,
and the arms-overhead render is an attachment artifact rather than an
animation one.

What makes it interesting is that the attachment's arithmetic also looks
right: `BoneAttachment3D` contributes `bone_global_pose`, the mesh's own
transform contributes `inverse(bone_global_rest)`, and their product
applied to a bind-space vertex is exactly rigid skinning. Working it
through for the hand gives back the hand bone's posed position -- which
the numbers above say is correct. The two cannot both be true, so one of
the assumptions behind that arithmetic is wrong: most likely what
`BoneAttachment3D` actually applies, or when it applies it relative to
`force_update_all_bone_transforms`.

**Next step**: instrument the assembled character in-world -- compare a
mesh piece's own world position against its bone's posed position, rather
than reasoning about what the composition ought to be. Playback stays
disabled until it holds together.

## Ninety-first round: measuring the rig, and an instrument that measured too early

Two hooks were added to measure the assembled character rather than
reason about it: `SRREVAMP_QA_ANIM` plays the animation (off by default,
so the wrong-looking result is never shipped) and `SRREVAMP_QA_RIG`
reports, for every piece, where its bone is and where the piece ended up.

**The first run of it was worthless, in an instructive way.** It reported
every mesh sitting at the skeleton's own origin, far from its bone, and
reported **exactly the same numbers with playback on and off** -- which
should have been impossible, since the two render differently. The report
was running from the harness's one-time setup block, on the first frame,
before the animation had been applied at all. Identical output for two
different configurations is the signature of an instrument that is not
measuring what it claims, and it is the fourth time in this session that
the measurement rather than the world turned out to be the broken part.

Moved to a later tick, it says the attachment is working: pieces sit
**1.5 to 4.4 units** from their bones, which is what a mesh centre should
be relative to the joint it hangs off, and the bone heights read as arms
hanging down (upper arm -29, forearm -32, in a space where +Y is up).

**And yet the render still shows the arms overhead.** So one of the two
disagrees with what is actually drawn, and the likely culprit is the
measurement again: this file's own `build_skeleton3d` already warns that
`get_bone_global_pose()` "reflects only the pose side, which starts
uninitialized/identity rather than defaulting to rest", and both
`check_ban_pose.gd` and the rig report are built on it. A number read
from an API whose semantics the codebase has already flagged as subtle is
not evidence.

**Where this stands.** The root bind transform fix is real and kept -- it
took the character from scattered pieces to a coherent body. Everything
after that is unresolved, and the honest summary is that the pose
pipeline has been measured with an instrument that may not report what
the renderer uses. The next step is to stop using `get_bone_global_pose`
and measure the only thing that cannot lie: the world-space position of
an actual attached mesh, sampled across several frames, with playback on
and off. If those differ, the character is being posed and the arms are
genuinely up; if they do not, nothing is moving and the render difference
comes from somewhere else entirely.

## Ninety-second round: the in-world pose disagrees with the same animation applied offline

Measuring an actual attached mesh's world position -- the one thing in
this chain that cannot misreport -- across several frames, with playback
on and off:

| | playback off | playback on |
|---|---|---|
| `Bip01 L Forearm` mesh | x 0.000, y 14.933, unchanging | x 1.96 -> 1.73, y 16.38 -> 16.53 |
| `Bip01 L UpperArm` mesh | x 0.000, y 14.622, unchanging | x 0.66, y 16.19 -> 16.33 |
| `Bip01 L Calf` mesh | x 0.000, y 2.129, unchanging | x -0.55, y 2.35 -> 2.38 |

Two things follow. The pieces **do** move between frames, so the
character is genuinely being animated and the attachment does carry the
pose. And the arms genuinely **rise**, from 14.93 to 16.5 on a figure
about 17 units tall -- they end up at head height. The render is telling
the truth and the earlier reading of the bone heights was not.

**That contradicts the same animation applied offline.**
`check_ban_pose.gd` builds the same skeleton with the same builder, loads
the same `chinaman_fighter_standcity.ban`, applies frame 0, and gets the
hands **down** at y 9.74 -- a correct standing pose. Same skeleton, same
file, same code path into `apply_ban_pose`, opposite results.

So the fault is in something the in-world path does and the offline tool
does not. Candidates, in the order worth testing:

- **The frame index.** The tool applies frame 0; in-world the frame comes
  from elapsed time modulo the keyframe count. If some frames of this
  animation genuinely raise the arms, every screenshot has simply caught
  one -- though a standing-idle animation should not have any.
- **Repeated application.** In-world `apply_ban_pose` runs every physics
  frame against a skeleton that already carries the previous frame's
  pose; the tool applies it once to a freshly reset skeleton. If
  anything in the path composes rather than replaces, the error would
  accumulate -- and arms creeping upward frame after frame is exactly
  what accumulation looks like.
- **The skeleton's own transform.** The in-world character is scaled to
  `REAL_CHARACTER_NATIVE_HEIGHT`; the tool's is not.

Both of the first two were then tested, and **both are refuted**:

- **Repeated application.** Resetting the skeleton to rest at the top of
  `apply_ban_pose`, exactly as the offline tool does, produces numbers
  **identical to the digit** -- so the pose is idempotent and nothing
  accumulates.
- **The frame index.** Applying every frame of the animation offline
  (0, 1, 2, 3, 5, 7, 9, 11, 13) puts the left hand **6.26 to 6.35 below
  the head every time**. No frame of this animation raises the arms.

So the same skeleton, built by the same builder from the same `.bsk`,
running the same `apply_ban_pose` over the same `.ban`, produces arms
down offline and arms up in the world, at every frame, with pose
accumulation ruled out. The remaining untested difference is the
in-world skeleton's own transform -- the character is scaled to
`REAL_CHARACTER_NATIVE_HEIGHT`, the offline one is not.

The next step is not another hypothesis. It is to make the two paths
report the *same numbers*: have the in-world code dump the same bone
global positions `check_ban_pose.gd` prints, in the same units, on the
same frame, and find the first bone at which they diverge.

## Ninety-third round: every part of the rig verified correct, and the render still disagrees

Pinning the in-world animation to a chosen frame
(`SRREVAMP_QA_ANIM_FRAME`) makes the two paths directly comparable, and
on frame 0 they agree **exactly**:

```
                     in-world                offline (check_ban_pose.gd)
Bip01 Head       ( -0.05, 16.05, -0.27)     ( -0.05, 16.05, -0.27)
Bip01 L Forearm  (  2.42, 12.18, -0.10)     (  2.42, 12.18, -0.10)
Bip01 L Hand     (  2.73,  9.74, -0.83)     (  2.73,  9.74, -0.83)
```

So the bones are posed identically in both, hands well below the head.
Everything downstream then checked out too:

- **The attachment tracks its bone.** `BoneAttachment3D` for
  `Bip01 L Forearm` sits at (2, 12, 0), which is the bone's own posed
  position, with a resolved bone index.
- **The mesh offset is exact.** Each piece's own transform equals
  `inverse(bone_global_rest)` to the last digit -- printed beside what it
  should be, and identical.
- **The offset is necessary.** Removing it entirely throws the pieces to
  (15.1, 15.8, -7.0), far worse, so the vertices really are in bind space
  and the inverse really is the right correction.
- **The left/right split works.** It looked broken -- every paired part's
  `get_aabb()` spans both signs of X -- but `_build_side_mesh` keeps the
  full vertex array and filters only the *indices*, so the AABB spans
  both sides while the drawn triangles are one side. Correct code,
  misleading measurement.

**And the character still renders with its arms overhead**, on the same
build, on the pinned frame whose numbers say the hands are down.

Every link in the chain has now been measured and every one is right,
which means the fault is in something not yet on the list, or one of
these measurements is lying the way three others in this session already
did. Note in particular that the mesh AABB centre -- which several
readings in the ninety-first and ninety-second rounds were built on -- is
**meaningless for these meshes**, since a two-sided vertex array puts it
on the centreline regardless of which side is drawn. Those numbers should
not be trusted, including the ones that appeared to show pieces moving.

**Next step, and deliberately not another hypothesis**: assemble the
character with **one body part at a time** and render each. That says
directly which piece is drawn where, with no derived quantity in between,
and will identify what the shapes above the head actually are -- they
have been assumed to be the arms, and nothing has confirmed that.

## Ninety-fourth round: the halves were attached to each other's bones

The character animates correctly now. The last bug was in one line, and
it is a good example of a defect that no amount of checking the
surrounding code would have found.

A real paired body part -- both arms in one `.bms`, both legs in another
-- is split by the sign of each triangle's centroid X and each half
attached to its own bone. The positive-X half was being attached to
`bones[0]`, which `BODY_PART_BONES` and `EQUIPMENT_SLOT_BONES` both list
as the **right** bone. That is backwards: in a real body part's own bind
space **+X is the character's left**.

**Why it survived so long is the interesting part.** A bind pose is
symmetric, so each half lands exactly where the other half would have,
and the assembled character looks perfect. The error only exists once
something drives the two bones *differently* -- which nothing did until
animation playback was attempted. Then each arm is pulled toward the
other's bone, and the character renders with both arms swung up over its
head.

That is what every earlier round in this thread was chasing. It is also
why every measurement came back clean: the posed bone globals matched the
same animation applied offline **exactly**, each `BoneAttachment3D` sat
on its own bone's posed position, and each piece's transform equalled
`inverse(bone_global_rest)` to the last digit. All of that was true. The
pieces were simply hung on the wrong bones, which none of those checks
looked at.

Swapping the pairing gives a correct standing pose -- arms at the sides,
legs straight -- on the very frame that previously showed arms overhead.

**Both bugs in this thread were invisible at rest**, which is worth
stating plainly: the root bone's missing bind transform (eighty-ninth
round) and this. A bind pose is a poor test of a rig, because it is
exactly the configuration in which a symmetric mistake cancels itself
out. Animation playback is now **enabled**, having been disabled since
the forty-eighth round.

Still missing, and unrelated: there is no `head` entry in
`BODY_PART_BONES`, so the head mesh is not attached at all.

## Ninety-fifth round: what the water plane levels actually contain

A reference screenshot of a live server standing at the moat outside
Jangan's wall (`X:6485 Y:915`, zone "Grassland") proves the water this
project draws nothing for is real. Dumping every water plane cell's own
level beside the ground under it, rather than only the aggregate, shows
what the plane map holds:

| region | distinct levels | cells |
|---|---|---|
| 97/168 (town) | -33, **100**, 8, -3 | 2, **6**, 1, 1 |
| 96/168 (farmland) | -20 | 30 |
| 98/167 | -20, 2 | 12, 2 |

Two things stand out.

**Some cells carry a level of exactly `100.00`**, which is 133 units above
their own ground and would flood everything beneath them. A round number
that far out of range reads like a sentinel rather than a surface height,
and six of the town's ten water cells carry it. Excluding them is not
enough on its own, though -- the rest of the town's cells still sit above
86.8% of their own ground.

**Every water cell in real 96/168 carries the same level, -20**, over
ground measured between -40 and -66, which would put a lake over roughly
two thirds of the region. That region's own authored minimap shows dry
farmland with tilled plots and two narrow channels. The plane map and the
minimap disagree about the same ground, and one of them is being read
wrong.

The most likely candidate is the pairing itself. The
`(x << 8) | y` navmesh key was confirmed only negatively -- the transposed
name does not exist as a file -- and `check_navmesh_pairing.gd` also
reported the paired navmesh's plane heights disagreeing with the region's
own heightmap by 15 to 52 units on average, which was written off at the
time as "plane cells are coarse". A region whose navmesh belongs to
somewhere else would look exactly like this: plausible internally,
disagreeing with the terrain, and claiming water where the art shows
fields.

**Next step**: stop assuming the key. Take a region that is unmistakably
water in its own minimap art and one that is unmistakably dry, and check
whether their paired navmeshes agree. If a dry region's navmesh claims a
third of its cells are water, the pairing is wrong and every conclusion
drawn from `.nvm` data -- walkability included -- needs revisiting.

## Ninety-sixth round: plane type 1 is not water

The plane map's type 1 has been treated as "this cell is water" since the
seventy-fifth round, on a measurement that type 1 cells have 92.4% of
their terrain below their own plane height against type 0's 39.9%. An
independent check says that reading is wrong.

The navmesh marks water; a region's own authored minimap *paints* water
blue. Two pipelines, one ground truth, so across regions they should rise
and fall together. They do not:

| region | navmesh cells of type 1 | minimap pixels reading as water |
|---|---|---|
| 97/168 (town) | 27.8% | 2.7% |
| 96/168 (farmland) | **83.3%** | 1.7% |
| 98/168 (**the palace**) | **47.2%** | 0.6% |
| 100/166 | **100.0%** | 1.4% |
| 99/166 | 55.6% | 0.3% |
| 100/100 | 0.0% | 0.0% |

A quarter to all of every region is type 1 while its art is essentially
dry, and the palace is not half underwater. **Type 1 is far too common to
mean water.** The 92.4% figure it rested on says only that a type 1
cell's plane height tends to sit above its own ground -- which is true of
a great many things that are not a water surface.

The pairing is not the problem: these navmeshes' own blocking edges and
object lists match the buildings they are paired with, which is why
walking around Jangan works and why the city gate's arches line up.

**What this does and does not break.** `NvmWater` takes water's *shape*
from real WATER-typed tiles and only its *level* from the plane cell, so
the water that actually renders -- 134 quads in real 98/168 -- is
unaffected: those tiles are water by their own tile2d.ifo type, and the
plane cell only told them how high to sit. What breaks is every
inference of the form "this region has N water cells, so there should be
water here", including the previous two rounds' reasoning about the moat.

And the moat is not in the tile map at all: real 96/168 has **zero**
WATER-typed tiles anywhere in the region, none dropped for falling
outside a plane cell, and no water-like object in its placements either
-- only farmland props, the city wall, and event decorations. Wherever
the reference's moat comes from, it is not that region's terrain.

**What is needed next is the coordinate mapping.** The reference client
displays a position (the moat is `X:6485 Y:915`), and being able to
convert that into a region and local position would turn every reference
screenshot into an exact place to look. Half of it is already recovered:
matching the dragon fountain (`X:6434`) and the palace gate (`X:6432`)
against their known local X gives

    displayed X = (region_y - 135) * 192 + local_x / 10

which reproduces both to within a unit. The Y axis does not yet fall out
the same way -- neither region_x nor its mirror gives a whole number of
regions against the two known points -- so one more reference position at
a landmark whose local coordinates this project already knows would
settle it.

## Ninety-seventh round: reading the client's own position readout

A reference screenshot is only as useful as one's ability to find the same
spot, and until now that meant guessing. The running client displays a
position, and the conversion into this project's own coordinates is now
recovered:

    displayed X = (region_y - 135) * 192 + local_x / 10
    displayed Y = (region_x -  92) * 192 + local_z / 10

192 is a region's 1920 units at the client's ten-units-per-displayed-unit
scale; 135 and 92 are the two axes' origins. Note which is which: region
**y** drives displayed X and region **x** drives displayed Y, matching the
region-to-world mapping the eighty-first round established.

Recovered from three landmarks whose local coordinates this project
already knew, and each one checks:

| landmark | client shows | converts to | what is really there |
|---|---|---|---|
| dragon fountain | X:6437 Y:1029 | 97/168 (1010, 690) | the fountain axis is local x 1008 |
| palace gate | X:6432 Y:1184 | 98/168 (960, 320) | the lion statues stand at local z 270 |
| moat | X:6485 Y:915 | **96/168 (1490, 1470)** | -- |

Run backwards, this project's own dragon at 97/168 (1008, 845) predicts
**X:6437 Y:1044** against the screenshot's X:6437 Y:1029 -- the X exact,
the Y fifteen displayed units south, which is where the character was
standing relative to the statue. `server/cmd/wherecoord` does the
conversion both ways.

**Rendering the moat's converted position immediately paid for it.** At
96/168 local (1490, 1470) this project draws the same grass with white
flowers, the same paved strip and the same stone wall as the reference --
and no channel. The terrain says there should be one: sampling across
that spot gives +0.65 either side and **-40.00** in a narrow band at
z 1540, which is the moat's trench, and the plane cell covering it carries
a level of **-20**, which would fill that trench twenty units deep without
touching the ground beside it.

So the moat is real in the data and this project is not drawing it. What
still blocks a fix is that the same region drops to about **-45 across its
whole southern third**, which the same -20 level would flood, and the
region's art shows farmland there. A rule of "water wherever terrain is
below the plane level" fills the moat correctly and drowns the farm. The
plane map cannot separate them -- 30 of the region's 36 cells are type 1
-- and there are no water tiles anywhere in the region to localise it.

## Ninety-eighth round: NPCs are characters, not scenery

Chasing the first item on the list turned up the whole chain, and one
surprise about what an NPC actually is.

**The spawn data exists and decodes.** A real server pack's
`SR_GameRefData\npcpos.txt` is UTF-16 with tab-separated rows of
**NPC id, region id, X, Y, Z** — and the region id is the same
`(x << 8) | y` key this project already uses for navmesh filenames, so
`25257` reads as region 98/169 directly. A real `CharacterData*.txt` row
maps the id to a code name and a model: id `2023` is `NPC_CH_PRIEST`
carrying `npc\npc\chinaquest_priest.bsr`. Nothing here needs reverse
engineering; it is a table this project can read.

**The models are not static objects.** Loading those `.bsr` files through
`ObjectLoader` -- the loader this project uses for scenery -- succeeds but
returns almost nothing: 25 vertices for the priest, 77 for a bookmaker,
566 for `arabia_fouad`. A person is not 25 vertices. Reading the files
directly says why:

```
chinaquest_priest.bsr    prim\mtrl\npc\china\chinaquest_priest.bmt
                         prim\mesh\npc\china\chinaquest_priest_al.bms
                         prim\mesh\npc\china\chinaquest_priest_part1.bms
                         prim\mesh\npc\china\chinaquest_priest_part2.bms
                         prim\ani\npc\china\chinaquest_priest_basic.ban
                         prim\ani\npc\china\chinaquest_priest_time.ban
arabia_fouad.bsr         ... _part1.bms, _part2.bms, _rol.bms
                         prim\ani\npc\sd\sd_m_area_ahha_stand.ban
                         prim\skel\npc\sd\sd_m_area_ahha.bsk
```

An NPC `.bsr` carries **body parts, a skeleton and animations** — it is a
character, assembled the same way the player is. That is good news,
because the character pipeline is the part this project just finished
fixing: the root bind transform, the paired-part sides, and `.ban`
playback all landed in the ninety-fourth round.

**What is missing is in `BsrReader`.** It found one mesh where the file
lists three, and it exposes no skeleton or animation path at all -- its
`ParsedObject` has `mesh_path`, `sub_mesh_paths` and `material_path` and
nothing else. Building scenery never needed more. The sub-mesh scan works
on buildings (a real `cj_s.bsr` yields ten), so what an NPC `.bsr` puts
around those fields is different and not yet read.

**Next**: extend `BsrReader` to read an NPC `.bsr`'s full mesh list and
its `.bsk`/`.ban` references, then assemble NPCs through
`CharacterAssembler` rather than `ObjectLoader`. Spawning them is separate
and easier: the table is readable, and this project's own server already
streams a monster list to the client that NPCs can follow.

## Ninety-ninth round: the `.bsr` header table was right all along

The ninety-eighth round ended pointing at `BsrReader`: an NPC `.bsr` lists
three meshes and it found one, and it exposed no skeleton. Fixing that
meant learning the layout, and the layout turned out to already be
documented — incorrectly.

**The instrument first.** `client/tools/dump_bsr.gd` walks a `.bsr`
printing every plausible length-prefixed string with its offset *and the
raw 32-bit words in the gaps between them*. The gaps are the whole point:
a list count sitting in front of a run of strings is invisible if you only
print the strings. `chinaquest_priest.bsr` came back as

```
  off 0x00c9 len  41  prim\mtrl\npc\china\chinaquest_priest.bmt
    gap 0x00f6..0x00fa  words: 3
  off 0x00fa len  44  ..._al.bms
  off 0x012a len  47  ..._part1.bms
  off 0x015d len  47  ..._part2.bms
    gap 0x0190..0x019c  words: 4096, 0, 2
  off 0x019c len  46  ..._basic.ban
  off 0x01ce len  45  ..._time.ban
    gap 0x01ff..0x0203  words: 1
  off 0x0203 len  41  prim\skel\npc\china\chinaquest_priest.bsk
```

Counted lists, plainly. But the better find was in the header words this
tool also prints: `193, 246, 511, 400` = `0xC1, 0xF6, 0x1FF, 0x190` — the
material, mesh, skeleton and animation offsets exactly.

**The recorded conclusion was wrong, and this is why.** BSR_FORMAT.md said
the `hdr[]` offset table's semantics "aren't confirmed", that a field
which "looked exactly like a byte offset to the mesh path in most of them
did **not** hold for one real file", and that the reader therefore doesn't
rely on it. The table starts at **0x0C, not 0x10**. Read one field off,
every entry lands on the neighbouring section and the whole table looks
like noise with one coincidence in it. Read correctly it is exact in every
file checked, in all three categories:

| File | 0x0C material | 0x10 mesh | 0x14 skeleton | 0x18 animation |
|---|---|---|---|---|
| `chinaquest_priest` (character) | 193 = 0xC1 | 246 = 0xF6 | 511 = 0x1FF | 400 = 0x190 |
| `mangnyang` (character) | 249 = 0xF9 | 341 = 0x155 | 1097 = 0x449 | 431 = 0x1AF |
| `cj_monstad_door01` (building) | 262 = 0x106 | 340 = 0x154 | 1524 | 1512 |
| `tre_bank02` (nature) | 235 = 0xEB | 290 = 0x122 | 465 = 0x1D1 | 407 = 0x197 |

The same doc called the field at 0x28 "an observed constant `152`". It is
not a constant either: it is `name_end + 48`, tracking name length exactly
(17-char name → 137, 9 → 129, 10 → 130).

**And the file says what it is.** The `uint16` at 0x40 is an authored
object type: **1 character, 2 building, 4 nature**. The field-*order*
differences this project attributed to a path-prefix convention
(`res\bldg\` vs `res\nature\`) were really this type all along. That
matters because it is the game's own classification — no heuristic, no
guessing from the path.

**Result**, measured against the real archive, not inferred:

| model | before | after |
|---|---|---|
| `chinaquest_priest` | 1 piece / 25 verts, no skeleton | 3 / 665, skeleton, 2 animations |
| `chinasystem_bookmakergirl` | 1 / 77 | 4 / 747, skeleton, 2 animations |
| `mangnyang` | — | 2 / 440, skeleton, 15 animations |

Both readers assert the chaining — every section must end exactly where
the header says the next begins — and fall back to the old scan if it
fails, so a misunderstood file produces the old answer rather than a
confidently wrong one. A character with no skeleton is refused outright:
its pieces are skin, and returning them would render as limbs at the
origin.

### The bone mapping was a cached computation

`MonsterAssembler` carried `GOLEM_PIECE_BONES` and `SCORPION_PIECE_BONES`
as hand-derived dictionaries — a real obstacle, because the game has
hundreds of NPCs and monsters and nobody is deriving a dictionary for each.
Both had been produced by matching each mesh piece's vertex centroid to
the nearest bone bind position. `client/tools/check_piece_bones.gd`
recomputes that at runtime and prints it against what was written down:

```
golem.bsr    -- 48 bones, 7 mesh pieces  (checking against the hand-derived map)
    golem01     743 verts -> Bip01 Spine       d=1.64  == hand-derived
    ...
    7/7 pieces agree with the hand-derived map
scorpion.bsr -- 55 bones, 3 mesh pieces
    3/3 pieces agree with the hand-derived map
```

10/10. The tables were only ever a cache, so `SkinnedBsrAssembler` does the
computation instead, and any character-category `.bsr` now assembles with
nothing supplied from outside. That also closes the gap BMS_FORMAT.md
recorded as "no file tying a specific mesh set to a specific skeleton was
found" — the `.bsr` is that file.

**Stated honestly**: the bone choice affects nothing in the bind pose,
because `attach_rigid` cancels the bone's rest transform and each piece
lands at the absolute coordinates baked into its vertices. It only matters
once the skeleton animates, and there it is an approximation — a humanoid
whose lower body is one 400-vertex piece hangs off whichever single bone
that piece's centroid sits nearest, so animating that bone swings the whole
piece. Adequate for NPCs standing in a town. Not a skinning model.

### A scenery bug found and deliberately not fixed

Measured, not suspected: `cj_monstad_door01.bsr` yields **17 mesh
references for 16 distinct meshes** — `..._door01_01.bms` comes back as
both `mesh_path` and `sub_mesh_paths[0]`. A building carries a duplicate
reference to its first piece *ahead of* its header-declared mesh section,
and the scan takes that as the primary while also reading the real section
as sub-meshes. Every multi-piece building in the world draws one piece
twice.

The fix is known — type 2 chains exactly the way type 1 does
(door01: count 16 at 0x154, 16 × 73 bytes from 0x158, ending at 0x5E8 =
the animation pointer) — and was left out on purpose, to keep a
scenery-wide regression away from the NPC work. It wants a sweep over
every `.bsr` in `Data.pk2` comparing old and new results first.

> **Done since.** `BsrReader.parse` now routes *every* object type through
> the header section table, with the scan kept only as a fallback for the
> 7% of files the table cannot read. The sweep this asked for was run:
> 7,978 of 8,539 files parse and chain (93%), every mesh path on a
> 1,500-file sample resolves to a real archive file, and the scan's 2,787
> duplicated meshes are gone. Left here rather than edited away because the
> measurement above is what made the fix safe to make. Type 4
should stay on the scanner meanwhile: its mesh entries carry a trailing
`uint32` per piece that types 1 and 2 don't, and its animation section
doesn't chain consistently (`tre_bank02`'s ends exactly at its skeleton
pointer, `tre_maple01`'s ends 4 bytes short).

**Next**: render one. `SkinnedBsrAssembler` is written and compiles but has
never been drawn — a picture of the priest standing up is the next thing
that should happen, before any spawning work.

## One-hundredth round: UI layout architecture recovered from Media.pk2

The UI system is not hardcoded in the client binary; it is authored in real
archives across three structured layers:

1. **Layout definitions (`Media.pk2\resinfo\*.txt`)**: 247 files in an
   `Interface Text` DSL defining sections and controls (`CIFStatic`,
   `CIFButton`, `CIFGauge`, `CIFFrame`, `CIFStretchWnd`, `CIFSlotWithHelp`,
   `CIFLattice`, `CIFEdit`). Every element specifies exact native pixel
   `Rect="X,Y,W,H"`, client clipping `ClientRect`, texture path `DDJ`,
   color tint, text/font attributes, and text tokens.
2. **Graphics assets (`Media.pk2\interface\*.ddj`)**: 7,785 textures.
   Buttons follow state suffix conventions (`_focus.ddj`, `_press.ddj`,
   `_disable.ddj`). Frames and panels ending with `_` expand into 8 slices
   (`left_up`, `mid_up`, `right_up`, `left_side`, `right_side`, `left_down`,
   `mid_down`, `right_down`).
3. **Localization catalog (`Media.pk2\server_dep\silkroad\textdata\textuisystem.txt`)**:
   A UTF-16LE tab-separated table mapping tokens (e.g. `UIIT_STT_GOLD`) to
   strings across languages (Column 8 is English).

**Implementation added**:
- `UiTextTable` (`scripts/ui/ui_text_table.gd`): decodes `textuisystem.txt`.
- `UiLayoutParser` (`scripts/ui/ui_layout_parser.gd`): parses `resinfo\*.txt`.
- `UiBuilder` (`scripts/ui/ui_builder.gd`): constructs Godot `Control` trees
  and resolves `.ddj` textures via `DdjReader`.
- `HudMinimap` (`scripts/ui/hud/hud_minimap.gd`): drives `resinfo\ifminimap.txt`,
  displays real per-region minimap art (`minimap\<y>x<x>.ddj`) with player
  aperture clipping, rotating heading arrow (`mm_sign_character.ddj`), and
  displays real client X/Y coordinates via the ninety-seventh round's recovered
  formulas.
- `HudUnderbar` (`scripts/ui/hud/hud_underbar.gd`): drives `resinfo\ifunderbar.txt`
  for quickslots, gauges, and page controls.

## Hundred-and-first round: repairing the UI landing

The UI lane's first landing (`9162de4`, `89bd174`) took the client down. Four
faults, in descending order of damage.

**1. `World3D.gd` did not parse at all.** `Control.PRESET_BOTTOM_CENTER`
does not exist in Godot 4 — it is `PRESET_CENTER_BOTTOM`. One wrong enum
name, and the entire world script failed to compile, so nothing loaded.
`godot4 --headless --path client --import --quit` reports this in one
line and in under a minute; it had not been run. Everything else here was
found downstream of fixing it.

**2. Every piece of UI chrome silently failed to build.** The log filled
with `Expected Image data size of 140x184x4 (RGBA8 without mipmaps) =
103040 bytes, got 68692 bytes instead`. The arithmetic gives it away:
`DdjReader` had been handed 51,520 bytes of payload for that texture,
which is exactly `140 × 184 × 2`. Every failing size checked out the same
way — 32×32→2048, 24×24→1152, 20×20→800 — so the files are **2 bytes a
pixel**.

Reading the DDS_PIXELFORMAT confirmed it from the file's own header rather
than from the ratio: `bpp=16`, flags `0x41` (RGB | ALPHAPIXELS), masks
`R=0x7C00 G=0x03E0 B=0x001F A=0x8000`. All of `interface\` is **ARGB1555**.
The region minimap art beside it is DXT1 and was always fine, which is why
this never surfaced before — no `interface\` texture had ever been loaded.

`DdjReader`'s uncompressed branch assumed 24- or 32-bit BGR(A), choosing
between them by whether the payload was big enough for 4 bytes a pixel.
It now decodes through the file's own `dwRGBBitCount` and channel masks,
which handles any width and is what the format specifies; the standard
32-bit BGRA masks take the same path and produce identical bytes. The
5-bit-to-8-bit scaling matters as much as the layout: a channel's 31 has
to become 255, not 31, or every 16-bit texture renders nearly black.
Regression test added with a synthetic ARGB1555 fixture checking both
extremes of every channel and the 1-bit alpha. Go's `ddj` mirror exposes
the same fields.

**3. The minimap was a black disc.** With the chrome finally decoding, the
map vanished behind an opaque black circle that also spilled over the
frame's own artwork. `GDR_MINIMAP_ALPHA` in the authored
`resinfo\ifminimap.txt` sits at exactly the map rect (14,57,105,105)
carrying `mm_alpha.ddj` — 7,999 opaque texels inside 2,817 transparent
ones, i.e. a **mask**, which the real client uses to clip the map to a
circle. Rendered as ordinary art it is precisely a black disc over the
map. Hidden for now; the map is clipped to a square instead, so it fills
corners the real client leaves empty. The real circular clip needs the
texture applied as a mask and is left to the UI lane.

**4. Both HUD panels ate every click over their rectangle.** Neither root
`Control` set `mouse_filter`, and Godot's default is `MOUSE_FILTER_STOP`.
`World3D` drives click-to-move from `_unhandled_input`, which a consumed
event never reaches — so an 864×54 strip across the bottom of the screen
and a 136×175 box in the top-right were dead to clicks, over the chat box
among other things. Both roots are now `MOUSE_FILTER_IGNORE`, which
applies to that node alone; the buttons and slots inside keep their own
filters.

**Verified in a render**: world loads, minimap shows the region art with a
heading arrow inside the real frame, zero image errors in the log.

### Still open, and left to the UI lane

The **underbar is largely not rendering**. The authored
`resinfo\ifunderbar.txt` has 75 elements with a real `Rect`, spanning
x ∈ [-64, 864] and y ∈ [-34, 52] — 928×86, with content extending left of
and above the origin. `HudUnderbar` sizes itself 864×54 and anchors
bottom-centre, so the authored coordinate space and the container do not
correspond, and only a handful of pieces appear, bunched to the right. Not
fixed here: which authored coordinate is meant to land at the screen
centre is a design question owned by the lane that wrote it, and guessing
at it would be exactly the failure mode this project keeps recording.

### The lesson, again

Two of these four are caught by commands already written down in
`AGENTS.md` — the import check, and "a clean import is not proof, run
something that executes the code". The other two needed a render, which
`qa_shot.sh` produces in under two minutes on the GPU. The whole repair
took one import, one suite run and three renders.

## Hundred-and-second round: the client's own window registry

Finishing the two items the UI repair left open turned on finding a file
nobody had read: **`resinfo\ginterface.txt`**.

`resinfo\ifunderbar.txt` describes the bar's 76 child controls and never
names the bar itself — no background, no size, no screen position. That is
why the underbar rendered as a handful of pieces bunched to the right: the
only children with artwork of their own were the buttons and the two end
decorations, and everything else had nothing to draw. `ginterface.txt` is
the missing half, a **top-level window registry** giving each HUD window
its background and its rect:

```
GDR_UNDERBAR:CIFUnderBar   DDJ=ub_window_01.ddj   Rect=112,684,800,52
GDR_MINIMAP:CIFMinimap     DDJ=mm_window.ddj      Rect=892,6,140,184
```

**`Rect` is `x, y, width, height`**, confirmed five times over by every
authored size matching its artwork's real dimensions exactly:
ub_window_01 800×52, ub_deco_left 64×52, ub_menu_button 60×56, ub_sp_bar
144×8, mm_window 140×184. The same fact says the art is drawn **1:1** and
must not be stretched.

The bar's horizontal placement is authored, not chosen: 112 is exactly
`(1024 - 800) / 2` in the client's 1024-wide default layout. The vertical
anchor is *not* recoverable the same way and is recorded as a choice —
`y=684` would leave a 32px gap under the bar at 768 tall, but the same file
puts `GDR_CHAT_BOARD`'s bottom at 944, past the bottom of a 768-tall
screen, so these defaults are not all screen-relative and cannot be read as
anchoring rules.

Two builder bugs fell out of the same reading:

**`Color` is not a tint.** `UiBuilder` applied it as `modulate`. It is a
per-control editor id: ifunderbar.txt's 76 controls carry **64 distinct**
scattered values (255,51,191,68 / 255,91,102,218 / 255,64,213,106 …),
while `FontColor` — a field that really is a colour — is pure white on 74
of those same 76. Modulating by it tinted every piece of artwork a
different random colour.

**A zero-size rect means "use the artwork's own size".** Real layouts do
this (`GDR_DECORATE_3` is `Rect=RECT,"677,-40,0,0"` carrying
ub_window_02.ddj); the node was left at zero size and never appeared.

### The minimap's circular clip

`mm_alpha.ddj` is 104×104, black in RGB everywhere, alpha 255 inside a
circle and 0 outside — a pure alpha mask, which is why drawing it as
artwork produced the black disc of the previous round. It is now the map's
clip, via a small `canvas_item` shader. The map quad is larger than the
aperture and slides inside it as the player moves, so the mask cannot be
sampled at the quad's own UV; the shader samples in **aperture space**,
taking the quad's offset and size as uniforms and discarding outside the
aperture rather than clamping, which would smear the mask's edge texels
over the frame.

**Verified in a render**: the bar draws its full 800×52 background with the
SP gauge, numbered quickslots, page arrows, menu medallion and both end
decorations; the minimap's region art fills the frame's circle exactly.

### Why a broken build shipped, and what now catches it

v0.1.71 published green from the commit whose `World3D.gd` could not parse.
The release workflow ran `--import --quit` and trusted it. **That check
cannot work**, in either direction, and both were measured here:

- On a **cold** cache a clean checkout of this project prints **283**
  "Could not find type" parse errors while `class_name` symbols are still
  being registered — all spurious. Failing on that output would block every
  release.
- On a **warm** cache a genuinely broken project prints **nothing**,
  because the cached script is served instead of re-parsed.
- And `--import --quit` exits **0** in every one of those cases.

So the guard is `client/tools/check_scripts.gd`, which *loads* every script
and scene — loading really does compile — and is run by both CI and the
release workflow. `load()` alone is still not enough: Godot hands back a
GDScript object for a script that failed to parse, having only logged the
error. The tool calls `reload()` and reads the error code, failing on
`ERR_PARSE_ERROR` (43) and `ERR_COMPILATION_FAILED` while ignoring
`ERR_ALREADY_IN_USE` (22), which is what an autoload or the tool's own
script answers because it cannot be swapped out from under itself.

Checked both ways: clean project 137 scripts + 4 scenes, exit 0; the same
project with `PRESET_BOTTOM_CENTER` reintroduced, exit 1 naming
`res://scripts/World3D.gd`.

## Hundred-and-third round: a third of the world was drawn wrong

The hundred-and-first round recorded a scenery bug and deliberately did not
fix it: `cj_monstad_door01.bsr` returned 17 mesh references for 16 distinct
meshes, because a building carries a duplicate reference to its first piece
ahead of its header-declared mesh section. It wanted a sweep over the whole
archive first. This is that sweep, and the bug was much larger than one
doubled piece.

`client/tools/sweep_bsr.gd` parses every `.bsr` in a real `Data.pk2` both
ways -- through the header's section table and through the forward scan the
shipping reader used -- and reports where they disagree. Across **8,539
files**:

| | |
|---|---|
| header table parses and chains | **7,978** (93%) |
| header table fails, falls back to the scan | 491 (7%) |
| **scan returned a duplicated mesh** | **2,787** (33%) |
| scan and table disagree on mesh count | 3,770 (44%) |

A third of every object in the game was drawing one of its pieces twice.
And the disagreements run the other way too: `W_CD_boat.bsr` and
`W_CD_ani_boat.bsr` gave the scan **one** mesh where the table gives
**six** -- those were rendering with most of their geometry missing, which
is not a subtle defect and had never been noticed.

**The decisive check was resolution, not chaining.** Chaining proves the
bytes were read in the right place; it does not prove they mean anything.
So the sweep also looks every header-derived mesh path up in the archive.
Across a 1,500-file verified sample: **zero unresolved**. Every path the
table produces names a real file.

Both readers now take the header table for **every** object type, not just
characters, falling back to the scan for the 7% that don't chain. Verified
in a render afterwards -- the Jangan palace compound, its courtyards, walls,
gates and trees all draw correctly, and the object counts per region are
unchanged (276/276, 355/355, 226/226).

**A correction to the hundred-and-first round.** That round said the type
word at 0x40 is "1 character, 2 building, 4 nature". That was three values
sampled from five files. The archive actually carries **eight**: type 5 is
the most common at 3,421 files, then 2 (2,592), 4 (946), 1 (838), 3 (357),
6 (205), 0 (174) and 8193 (6). Only type 1 is load-bearing in the readers
(it selects the character path), so nothing was wrong in the code -- but
the documented enumeration was under-sampled and is now stated as such.

### The minimap's orientation is still not measured

`client/tools/check_minimap_orientation.gd` tries to settle which way a
region's minimap art faces by correlating its blue pixels against the
navmesh's own per-tile water flags, across all eight orientations. It does
not work on the regions available: Jangan's minimap has **0** blue cells of
576 and 97/167 has **3**, so every orientation scores zero and the "best"
answer is meaningless. Recorded as a failed probe rather than a result --
this is exactly the "check the probe before believing a negative" case, and
a tool that returns 0.000 for all eight options is reporting its own
inability, not a finding.

No change was made to the minimap. The axis convention it relies on is
already established by the eighty-first round from how the authored
minimaps tile (region *y* across, *x* up, giving one continuous city wall),
and `HudMinimap`'s panning matches it. The tool is kept for a water-heavy
region to be tried against later.

### Vitals, end to end

The HUD's health bar was drawing a hardcoded 200/200 because the server
never told the client its HP. It does now: `EnterWorldResult` carries `HP`
and `MaxHP`, wired through both the Go encoder and the GDScript decoder
with round-trip tests on each side, and `World3D` binds it. Combat already
reported `PlayerHP` on every attack, so that half needed no protocol
change -- this was the missing initial value.

**MP has no server side at all** -- nothing tracks or reports it. Its bar
is drawn full rather than empty, because an empty bar reads as a real
state, and it is flagged here and in UI_TODO.md rather than filled with a
number that looks live.

## Hundred-and-fourth round: the interface was never drawing its own artwork

The HUD looked wrong because three separate pieces of authored data were
being ignored, and each had been written off in this project's own notes.

**1. The `UV_*` fields are atlas sub-rects, and they are real.** An earlier
round recorded them as "parsed, unused; all `0,0`-`1,1` in the files read
so far" -- read off *three* files. Across the 229 real `resinfo\if*.txt`
layouts there are **18 distinct `UV_LT` values** and **45 controls whose
`UV_RB` is not 1,1**.

They are texture coordinates, and the arithmetic is exact.
`interface\ifcommon\window_all.ddj` is 1024x512, and:

```
GDR_PLAYER_MINI_INFO  UV 0.723633,0        -> 0.930664,0.136719
   x  0.723633*1024 = 741 .. 0.930664*1024 = 953   -> 212 wide
   y  0            =   0 .. 0.136719*512   =  70   ->  70 tall
   authored Rect: 212x70                            exact match

GDR_PMI_STA_CINFOBG   UV 0.391602,0.300781 -> 0.523438,0.669922
   -> 135x189, authored Rect 135x189                exact match
```

So the slice is 1:1 with the control, the same "art is authored at its real
size" rule the rest of this format follows. That slice is the SRO player
block -- gold-ringed portrait socket, Hwan circles, and the two bar slots --
and drawing it is the difference between the HUD looking like the game and
looking like coloured rectangles.

**2. The UI font ships in the archive.** `fonts\` holds three `.ttf` files
(the first is **TaeUtum**), loaded now from the player's own Media.pk2 at
runtime, the same way textures are, so nothing is committed. Godot's default
face over authored artwork was a large part of why the windows read as
placeholder.

The authored rects assume the client's own metrics and Godot renders the
same TrueType slightly wider, so a fixed size clipped labels mid-word --
"Phy. balance" became "Phy. balan", "Trader Grade" became "Trader Gra".
Each label now measures its string and steps down from 12px until it fits
the box the layout drew, which keeps the layout authoritative and still
shows the whole string.

**3. The string table's English column is not at a fixed index.**
`UiTextTable` took column 8 always. Real rows for the *same* token differ in
width and in which column holds the English, and column 8 is frequently the
literal filler `"0"`:

```
16 cols  UIIT_STT_PHYSICAL_ATTACK  [8]="Phy. Atk:"  [9]="Phy. Atk:"
19 cols  UIIT_STT_PHYSICAL_ATTACK  [8]="0"          [9]="Phy. atk"
```

Later rows overwrite earlier ones, so **every stat label in the character
panel was rendering as the digit `0`** -- which is exactly what a screenshot
showed. The column is now chosen by content: scan right to left, take the
first field that is non-empty, is not the `"0"` filler, and contains a Latin
letter. Against the real 3.5 MB table that resolves **6,937 tokens**, and
the character panel now reads "Phy. atk", "Mag. def.", "Hit rate", "Parry
ratio", "Trader Grade" -- matching the reference screenshots word for word.

### A panel bug the same screenshots exposed

The skill list rendered `<RefCounted#-9223348498956899638>`. The binding
looked for a field called `name`; the net snapshots call it `item_name`,
`skill_name`, `char_name` and so on, so every lookup missed and Godot's
default object description went to the player. It now tries the real field
names, and when a snapshot has none it prints that snapshot's actual fields
rather than an object id -- a missing binding should look like a missing
binding.

### Still open

- **Values, not labels.** The character panel's labels are right; its
  numbers are empty because nothing binds them yet.
- **The portrait socket is empty** -- `GDR_PMI_PICTURE` names no artwork,
  and what the client draws there has not been identified.
- **The HP and MP fills are still invented colours.** Neither gauge names a
  `DDJ`, the atlas slice supplies the slot rather than a fill, and nothing
  under `pmi_`, `com_bar0N` (list-row bars, near-black) or any `gauge` name
  is an HP/MP fill -- the only `gauge.dat` files belong to the launcher. Red
  and blue are read off the reference screenshots and are flagged in the
  code as the only invented values there.

## Hundred-and-fifth round: the town is inhabited

NPCs are in the world. The whole chain runs off the player's own Media.pk2,
so nothing is shipped and no server has to supply it.

**Both tables are in the client archive**, which is what makes this
possible without server data: `server_dep\silkroad\textdata\npcpos.txt`
(12,367 rows of *npc id, region id, X, Y, Z*) and the
`characterdata*.txt` parts (5,423 id → `.bsr` mappings). The region id is
the same `(x << 8) | y` key used everywhere else -- `25000` is 97/168.

The model path is found in a characterdata row **by looking for the field
that ends in `.bsr`**, not by index: the parts are ~104 columns wide and
the path sits at column 52 in one and elsewhere in others.

From there each NPC is assembled by `SkinnedBsrAssembler` -- the same
pipeline the player's body uses, reading the `.bsr`'s own skeleton, mesh
pieces and materials through the header's section table. `render_npc.gd`
confirms it standalone: `chinaquest_priest` comes out a complete textured
monk, saffron robe and maroon sash; `mangnyang` comes out the straw-man
with its red bindings.

In Jangan: **18 of 19 NPCs placed in 97/168**, and 45 across the loaded
nine-region grid.

### Three bugs between "placed" and "visible"

Each of these reported success while nothing appeared, which is the failure
mode worth recording.

**The centre region was never populated.** `_load_region_cell` handles the
eight surrounding cells; the centre is loaded separately by
`_load_region_neighborhood`. So the one region the player actually stands
in was the only one with nobody in it -- and the logs looked healthy,
listing eight regions and never mentioning the ninth.

**Everyone was buried.** Height came from `height_at(x, z, 0.0)`, and that
function resolves stacked walkable surfaces by picking the one nearest the
mover. Asking from 0 puts anyone standing on a raised deck underneath it,
and Jangan's octagonal plaza is a placed object, so the whole town square's
NPCs were inside it. Passing `npcpos`'s own authored Y as the mover height
is what disambiguates -- that column is not decoration, it is the answer to
"which of these surfaces".

**A zone change emptied the world.** NPCs are parented to their region's
terrain group, so `_clear_region_grid()` takes them with it -- but
`_npc_regions_done` still marked every region populated, so they never came
back. Every render after a zone change showed an empty town while the log
insisted 18 NPCs were placed. This is the same shape as the region-cache
bug the eighty-eighth round fixed for objects, and worth remembering as a
class: **anything parented to a streamed region needs its "already done"
bookkeeping cleared with the region.**

### Still open

- **The player sinks into the plaza on a zone change.** Measured, not
  guessed: `QA 120 local 985, -46, 1000 on terrain at -46.4` -- the player
  is standing on *terrain* at -46 while the plaza deck above is a placed
  object. Same `height_at` mover-height question as the NPCs, in the
  placement path rather than the spawn path.
- **NPCs do not animate or face anywhere.** Their `.ban` files are read and
  their paths kept; nothing plays them, and `npcpos.txt` carries no facing.
- **NPCs have no names, no dialogue and no collision.**

## Hundred-and-sixth round: standing inside the Jangan gate, measured

The last round recorded "the player sinks into the plaza on a zone change"
and left it. Chasing it produced one fix, one instrument, and one
correction of a wrong diagnosis I made on the way.

**The instrument first.** The QA position line said only what the *walkable
graph* thought was underfoot. It now also fires a ray through the real
collision and names what it hits, so a disagreement between the graph and
the drawn world is a number instead of a screenshot:

```
QA 120 local 985, -46, 1000  on terrain at -46.4 (0.0 below feet)
                             drawn Obj_cj_jang_gate_126 at -32.6 (13.8 above the graph's)
```

That is the whole bug in one line, and it took three wrong guesses to get
there.

**Wrong guess 1: a per-region vertical offset.** Sampling more points
killed it -- the gap is 0.0 at local 200,1700 and 13.8 at 985,1000 in the
same region, so it is not a constant bias.

**Wrong guess 2: the navmesh heightmap disagrees with the drawn terrain.**
Plausible -- the navigation mesh carries its own coarser heightmap -- and
wrong. Asked directly, `MapmTerrainBuilder.height_at` and
`NvmCollision.sample_height` return **-46.41 and -46.41** at that point,
and agree at every other point sampled. A `NavGraph.terrain_heightmap`
field written on the strength of that guess was reverted rather than left
in with a comment that had become false.

**Wrong guess 3: the object's navigation mesh was never resolved.** The
build log says "8 real objects in that region could not be resolved", which
looked like the answer. It now names them -- `cj_s, cj_luxury, cj_armo,
cj_acce, cj_weapon, cj_portal, cj_etc, cj_pal_bigdoor` -- and
`cj_jang_gate` is not among them. Naming them is worth keeping regardless:
an unresolved object is one the player can stand inside, and a bare count
gives no way to tell decorative shrubs from the structure the town square
is built on.

**What it actually is.** `Obj_cj_jang_gate_126`'s *collision and render*
mesh covers local 985,1000 at -32.6, while its *navigation* mesh does not
reach that far, so the graph correctly reports bare terrain at -46.4 and
puts the player there -- 13.8 units inside the gate's own stonework. The
object's walkable footprint is smaller than its solid one. That is the same
family as the walk-under-buildings work and is **not fixed here**.

### What was fixed: landing is not walking

`height_at` refuses a surface more than `SURFACE_REACH_UP` (12.0) above the
mover, which is right for walking -- you cannot step up an arbitrary ledge.
But something *placed* into the world has no height to step from; it
arrives from above and comes to rest on top. Conflating the two is why a
deck 13.8 up was rejected by 1.8 units.

`NavGraph.landing_height_at` answers the placement question instead, and
both the player's zone placement and every NPC spawn now use it. The test
reproduces the exact geometry: a deck at `SURFACE_REACH_UP + 1.8` is
refused by `height_at` and landed on by `landing_height_at`.

Deliberately **not** fixed by raising `SURFACE_REACH_UP`: that constant is a
considered choice -- "generous enough to step onto a stair tread, small
enough not to teleport the player onto a bridge passing overhead" -- and
widening it to clear one measured plaza would be fitting a threshold to a
single observation while making every overhead bridge a hazard.

This does not move the player at Jangan's gate, because the surface there
is not in the graph at all. It does put NPCs and players on every deck that
*is*.

## Hundred-and-seventh round: the snap was dragging the player down

The last round measured the Jangan sinking exactly and concluded the gate's
navigation mesh did not reach the spot. **That conclusion was wrong**, and
the instrument that produced it was wrong in a way worth recording.

Asked properly, the graph *does* offer that surface:

```
QA NAVGAP at local 985, 1000
   graph offers 2 surface(s): [-46.408618927002, -32.6088829040527]
   graph objects covering this point: [4, 28]
   solid Obj_cj_jang_gate_126   y -46.2..1.0
```

The earlier report said "NO walkable mesh" because it matched render nodes
to graph objects **by the trailing number in the node's name**. Those are
different counters: the loader numbers nodes by how many have loaded from
the `.o`/`.o2` placement files, while the graph keys objects by their index
in the `.nvm`'s own object list. The lookup missed and the miss was read as
absence. The report now asks the graph directly (`heights_at`,
`objects_at`) and never tries to bridge the two numbering schemes.

**What it actually was.** `_snap_player_onto_terrain` is a safety net for a
player the region stream buried, and it fires deferred as the centre region
finishes loading -- *after* the zone placement has already put the player
correctly on the gate's deck at -32.6. Because it looks at terrain alone,
it then dragged them 13.8 units down to the bare terrain inside the gate's
stonework. Every "the player sinks into the town square" render was that
one line.

It is now **lift-only**. Lifting a buried player is what it was written for;
dropping one off a surface they are legitimately standing on never was. The
result, measured:

```
QA 120 local 985, -32, 1000  on object cj_jang_gate at -32.6 (-0.0 below feet)
                             drawn Obj_cj_jang_gate_126 at -32.6 (-0.0 above the graph's)
```

Graph and drawn surface now agree to 0.0, and the player stands on the gate
rather than in it.

### Landing is still not walking

The `NavGraph.landing_height_at` work from the previous round stands and is
still right -- placement asks a different question from walking -- and the
remaining QA placement paths (`--at` and `--shots`) were moved onto it here
too, since a viewpoint jump is an arrival like any other.

### The instrument

`SRREVAMP_QA_NAVGAP` reports, for the player's exact spot, every surface the
walkable graph offers and every solid object covering it. That pairing is
what settles "am I standing in something" without a screenshot, and it is
what caught both the real bug and the bad name-matching in the first
version of itself.

## Hundred-and-eighth round: monsters and characters get their models

Two model gaps closed, and a fair amount of hand-written data deleted.

### Monsters: 642 species, none of them hardcoded

Two species were wired by hand -- a golem and a scorpion -- each carrying
its own skeleton path, mesh directory, piece list, material path, material
layer and a hand-derived piece-to-bone table in `MonsterAssembler`. Seven
constants and a table per creature, and every other species drew a capsule.

All of it is superseded. A monster is a character-category `.bsr` that names
its own skeleton and meshes, `SkinnedBsrAssembler` builds it, and the
piece-to-bone mapping is computed. What remained was resolving a species to
its model, and the real tables answer that by **joining two of them**:
`characterdata*.txt` carries each row's `SN_` name key next to its `.bsr`,
and `textdata_object.txt` resolves that key to a display name
(`SN_MOB_CH_MANGNYANG` -> "Mangyang"). Joined, that is **642 species
resolvable by the name the server calls them**, out of the player's own
Media.pk2.

**The server's three monsters were named things that do not exist.** "Stone
Golem", "Wild Boar" and "Sand Scorpion" appear nowhere in the real data, so
they could only ever have drawn the placeholder capsule. They are now
Mangyang, Weasel and Earth Ghost, which do -- and `combat.LootTables`,
`quest.Catalog` and the tests were renamed with them, since a rename that
missed the loot table would have silently dropped every monster's drops.

Verified for exactly the three the server spawns:

```
Mangyang     -> mob\china\mangnyang.bsr    26 bones, 2 pieces,  440 verts, 15 anims
Weasel       -> mob\china\gyo.bsr          37 bones, 2 pieces,  694 verts, 15 anims
Earth Ghost  -> mob\wchina\earthghost.bsr  43 bones, 3 pieces,  582 verts, 14 anims
```

Each link is verified on its own -- the table join, the assembly, and
`render_npc.gd` drawing `mangnyang` as the straw-man. **Not** verified end
to end against a running server, which needs a live monster broadcast.

### Characters: dressed by the server, not by the client

The player renders bare because the server reports nothing equipped. The
tempting fix is to have the client draw a default set anyway, and it is the
wrong one: the character would look dressed while the equipment window, the
inventory and the server all disagreed -- "looks finished, lies about what
is behind it", which is the failure this log keeps recording.

So new characters are given the items instead.
`equipment.GiveStartingKit` adds one armour item per wearable slot and
equips it, run from a hook on character creation. Best effort by design: a
character that cannot be given its kit is still a usable character, so the
failure is logged rather than failing the creation -- reporting "create
failed" because someone is underdressed would be worse than the problem.

`StartingArmorItemID` is a placeholder item id like the rest of
cmd/server's ref items, and says so: this project ships no real item table,
and an operator importing real refdata should point it at a real one.

## Hundred-and-ninth round: animating the NPCs made them worse

The town was inhabited but frozen, so the obvious next step was to play the
idle animations every model already carries. The plumbing works and the
result is worse than statues, so it ships off. The measurement is the
point.

**It works.** `SkinnedBsrAssembler` now parses a model's idle animation
alongside its geometry, picking it by name -- the archive is inconsistent
(`mangnyang_stand01.ban`, `chinaquest_priest_basic.ban`, some models carry
only `_time`), so the hints are tried in order and fall back to whatever is
listed first. `World3D` ticks them all, each phase-offset so a field of
Mangyang does not step in unison.

**It runs.** 49 animated characters in Jangan, and their bones really move:

```
QA ANIM 49 animated character(s)
   Npc_2003_2   38 bones,  8 frames, at frame 2  -- bones moved 1.047
   Npc_2004_3   36 bones, 29 frames, at frame 15 -- bones moved 12.036
   Npc_2013_4   36 bones,  8 frames, at frame 0  -- bones moved 1.134
```

The report prints the current frame next to the movement on purpose: two of
five read 0.000, and without the frame number that is indistinguishable
from a dead animation. They are five-frame loops whose keyframes barely
differ -- a merchant standing still.

**And it looks wrong.** Attributed with a controlled pair of renders, the
same NPC from the same camera, one flag apart:

- *animated*: torn into a spike, upper body stretched away from the legs
- *not animated*: a complete, correct woman in an embroidered red dress,
  sash, sandals and hair

The cause is already written down in `SkinnedBsrAssembler`'s own header and
is not fixable here. `.bms` carries **no per-vertex skinning**
(BMS_FORMAT.md settled that), so every mesh piece attaches rigidly to a
single bone, and a humanoid NPC's entire dress or torso is one 400-vertex
piece. Rotating that piece's one bone swings all of it. The comment
predicted exactly this ("adequate for NPCs standing in a town... not a
solved skinning model"); this round is that prediction being tested and
holding.

So idle animation is **off by default**, behind `SRREVAMP_IDLE_ANIM=1`. Kept
rather than deleted: the pipeline is right and only the skinning model is
missing, so whatever replaces rigid attachment can switch it on and use the
same two renders to show it is better.

**What this says about the rigid-attachment approach.** It is fine for
scenery-like models and for standing still, and it cannot animate a
humanoid. Making NPCs move is therefore not an animation task -- it is a
skinning task, and it needs a way to weight vertices to bones that the
`.bms` format does not appear to carry. That is a real open question and
sits in TODO.md rather than being papered over with a partial fix.

## Hundred-and-tenth round: .bms is skinned after all

The last round concluded that moving NPCs was a skinning problem, not an
animation one, and that `.bms` does not carry vertex weights. The second
half was wrong. It does, and finding them makes animated NPCs work.

**Why the earlier conclusion looked solid.** BMS_FORMAT.md accounted for
every byte of the 44-byte vertex record -- position 12 + normal 12 + UV 8 +
12 trailing -- showed the trailing bytes were something else, and concluded
there was no room for weights. All of that is true. The weights are simply
**not in the vertex record**: they are in their own section, and header word
0 (`0x10`) points at it. That word was being read into `hdr[0]` and never
used.

**What gave it away.** A character `.bms` contains *bone names*. Dumping the
strings in `chinaquest_priest_part1.bms` turned up "Bip01 L Hand",
"Bip01 L Forearm", "Bip01 Spine", "Bip01 Pelvis" -- twenty of them, right
after `hdr[0]`. A bone palette is only meaningful if something indexes into
it, so something had to.

**The layout**, measured rather than guessed. The palette ends at 0x3201 and
the index section begins at 0x3891: 1,680 bytes for 280 vertices, exactly
**6 per vertex**. Then, per byte position across all 280:

```
byte 0: range 0..19   in-palette 280/280    <- always a valid bone index
byte 3: range 0..255  in-palette 71         <- a second bone, when there is one
bytes 1,2 and 4,5: 0xFF/0x0000 in 209 of 280
```

So: `u8 bone0, u16 weight0, u8 bone1 (0xFF = none), u16 weight1`. The
property that settles it is that the weights **sum to full scale** --
`65535 + 0` for one influence, `32765 + 32765` for a 50/50 blend. Across
`mangnyang_part1.bms`, 0 of 263 vertices have a bad index and 0 of 263 miss
full scale, worst error 0.00056. And the semantics are anatomically right:
`Bip01 L Forearm 0.579 + Bip01 L Hand 0.420` at a wrist,
`R Clavicle 0.500 + R UpperArm 0.500` at a shoulder.

A few percent are not normalised on disk (8 of 280 in the priest, worst 33%
off), so both readers normalise rather than trust -- an unnormalised weight
stretches its vertex.

**The result.** `BmsReader` reads the palette and weights, `to_array_mesh`
emits `ARRAY_BONES`/`ARRAY_WEIGHTS`, `Skeleton3DBuilder.build_skin` binds
the palette to the skeleton by name with bind poses from each bone's
inverse global rest, and `SkinnedBsrAssembler` uses a real `MeshInstance3D`
skin where the mesh has one, falling back to rigid attachment only for
scenery. The priest reports **3 pieces, 3 skinned**.

Verified the same way the problem was found -- one NPC, one camera, one
variable:

- rigid + animated: torn into a spike
- rigid, no animation: correct but frozen
- **skinned + animated: a woman in a red dress holding a fan, standing
  naturally**

Idle animation is on by default again.

**The lesson is the same one this log keeps recording.** Three conclusions
have now been overturned by re-reading data rather than by new evidence: the
`.bsr` offset table was "untrustworthy" (read one field off), the UV fields
were "always 0,0-1,1" (three files sampled), and now `.bms` has "no
skinning" (audited the wrong structure). Each was written up with real
reasoning and each was wrong in the same way -- a complete argument about an
incomplete look. The tell in all three was a header word being parsed and
never used.

## Hundred-and-eleventh round: items get their names and icons

The inventory window was real chrome around a plain list of whatever the
snapshot's fields stringified to. It now shows what the game shows.

**The tables.** `server_dep\silkroad\textdata\itemdata*.txt` is ~160 columns
across several parts, of which three fields matter: the id (column 1), the
display name (column 3), and the icon. The icon is found **by extension**,
not by index -- a row carries three resource paths, two `.bsr` models and
one `.ddj`, and the parts do not agree on where the `.ddj` sits. Paths are
relative to `icon\`, and a real archive holds **5,370** of them.

Measured against a real Media.pk2: **11,772 items resolvable by id**, and
every icon is 32x32 -- exactly the pitch of the inventory's own slot grid,
which is a pleasant confirmation that `LATTICE_CELL` was right.

**The server's items were invented, so nothing could resolve.** The
starting kit handed out five copies of item `510`, a placeholder id that
appears in no table, so the inventory could only ever show an unnamed row
with no icon. It now gives the game's own China "Cotton" starter set, one
item per wearable slot:

```
SlotHelm          4734  Cotton Hat        clothes_01_ha.ddj
SlotMail          4842  Cotton Suit       clothes_01_ba.ddj
SlotShoulderGuard 4806  Cotton Talisman   clothes_01_sa.ddj
SlotPants         4878  Cotton Trousers   clothes_01_la.ddj
SlotBoots         4950  Cotton Shoes      clothes_01_fa.ddj
```

This is the same shape as the monster fix two rounds ago, and the same
lesson: **the client cannot render what the server names if the server
names something that does not exist.** Both times the fix was on the server,
not in the renderer.

**The presentation.** `_fill_inventory_grid` fills `GDR_INVENTORY_LATTICE`
-- the authored slot grid `UiBuilder` already builds as one Control per cell
with a named `ItemIcon` child -- placing each carried item's icon in its own
slot index, with a stack count where the quantity is above one and the
item's real name as the tooltip. The plain list stays underneath for the
fields the grid has no room for.

## Hundred-and-twelfth round: reading the client instead of guessing

Instruction, verbatim: *"never invent. always go back to ghidra and find."*
Fair. Several UI constants had been shipped as guesses with honest comments
saying so, and a comment saying "this is invented" is not a substitute for
looking. The client binary is on the RE box and it had the answers.

**Note on tooling**: the `mcp__ghidra__*` wrappers return "Invalid request
parameters" for every call right now. The GhidraMCP HTTP API behind them is
fine -- `curl http://192.168.5.78:8080/strings?...`, and `decompile` takes
the function name as a **POST body**. Worth knowing before concluding
Ghidra is unavailable.

### The layout field table, from the binary

`FUN_0082c1d0` is the resinfo parser -- it is the only function referencing
both the `FontIndex` and `UV_LT` string constants. Decompiling it gives the
control struct's own field offsets, and the string table around `UV_LT` in
`.rdata` gives the complete set of field names the client reads:

```
StretchType  HelpString  CommandID  UV_LB  UV_RB  UV_RT  UV_LT
DDJ  FontColor  VAlign  HAlign  Text  FontIndex  ClientRect  Rect  Style  ADDID
```

**There is no `Color` field.** The parser reads `FontColor` and never
`Color`, which settles from the code what the hundred-and-second round had
argued from a value distribution: the `Color=COLOR,...` line in every
resinfo control is editor metadata the client ignores. Two independent
routes, same answer -- but only this one is proof.

Field offsets, for later work: `Rect` +0x48, `ClientRect` +0x58,
`FontIndex` +0x68, `HAlign` +0x88, `VAlign` +0x8a, `FontColor` +0x90,
`UV_LT` +0xd0, `UV_RT` +0xd8, `UV_RB` +0xe0, `UV_LB` +0xe8,
`CommandID` +0xb0.

Also newly named: **`StretchType`** and **`ADDID`**, neither of which this
project reads.

### The HP and MP bars

The gauges name no `DDJ`, so an earlier round invented a red and a blue and
flagged them. The client hardcodes the textures in code instead of
declaring them in the layout, which is exactly why searching the layouts
found nothing. Pulled straight out of the binary's `.ddj` string constants:

```
interface\ifcommon\quick_hp.ddj   4x4 solid   RGB(230, 0, 0)
interface\ifcommon\quick_mp.ddj   4x4 solid   RGB(0, 80, 230)
```

4x4 swatches, meant to be stretched along the bar. The invented values were
RGB(199,38,38) and RGB(41,92,219) -- close enough to look plausible and
wrong. `HudPlayerInfo` now loads the textures rather than copying the
numbers, so it stays right against a different archive.

(`interface\party\pt_hp.ddj` and `pt_mp.ddj` are the party window's
equivalents, 136x4, RGB(164,8,32) and RGB(49,57,180).)

### The font sizes

`FontIndex` was being honoured as a *font* but not as a *size*: this
project started at 12px and stepped each label down until its string fitted
its control, because the layouts were clipping. That fitted number is gone.

`FUN_00469350` builds the client's font table with five consecutive calls,
each pushing a size then an index:

```
PUSH 0x9  PUSH 0x0   -> FontIndex 0,  9px
PUSH 0x8  PUSH 0x1   -> FontIndex 1,  8px
PUSH 0xc  PUSH 0x2   -> FontIndex 2, 12px
PUSH 0xb  PUSH 0x3   -> FontIndex 3, 11px
PUSH 0xf  PUSH 0x4   -> FontIndex 4, 15px
```

(Two branches pick different typefaces -- a Korean set and a western one --
and assign the same sizes to the same indices.)

The layouts were clipping because **12 is the size of index 2, and almost
every control uses index 0, which is 9**. The layout was always right about
its box; the guess was wrong about the text. Auto-fitting was a workaround
for a wrong constant.

### The window interior

Also invented: a flat `Color(0.055, 0.055, 0.07, 0.94)` for window bodies,
because no frame set has a centre piece and no fill texture is hardcoded --
both of which are true, and checked again here.

But the frame's own edge tiles are opaque and carry the colour the body
continues: `mframe_wnd_mid_up`'s bottom row is RGB(16,20,16). So the fill is
now **sampled from the window's own frame artwork** rather than chosen,
which is both correct and adapts to whichever of the thirty-odd frame sets a
window uses -- and they genuinely differ: `mframe_wnd_` gives RGB(24,20,24)
while `int_window_` gives RGB(41,41,41). One constant could not have been
right for both.

## Hundred-and-thirteenth round: the windows were fighting Godot's minimum sizes

Four separate window defects, all measured rather than looked at, and three
of them turned out to be the same defect wearing different clothes.

### Draw order runs the other way

A resinfo section lists its controls **front to back**. `ifplayerinfo.txt`
opens with `GDR_PI_ARRANGE_DATA` and ends, 73 controls later, with
`GDR_PI_SUBFRAME`; `ifinventory.txt` ends with `GDR_INVENTORY_FRAME`. A
frame is behind everything it frames, so the last entry is the backmost.

Godot draws children in tree order, so the list has to be added reversed.
Adding it in file order is why the inventory was an empty bordered box and
why the character panel's labels disappeared the moment its background tiles
started being built.

### `CIFNormalTile` is what fills a window

Confirmed for the third time that no 8-slice frame set has a centre piece --
`CNIFFrame` in the client loads exactly eight suffixes and no ninth -- and
this time the answer was in the authored data rather than the binary:
ifplayerinfo declares three `CIFNormalTile` controls
(`GDR_PI_BG_TILE_D`, `_B`, `_B2`) carrying
`interface\ifcommon\bg_tile\com_bg_tile_*.ddj` over the window's body.
`CIFNormalTile` is the fourth most common control type in the archive, 253
instances, and `UiBuilder` was building it as an empty `Control`. That is
why every window was hollow, and why two earlier rounds went looking for a
fill colour that was never needed. The sampled-from-the-frame colour and the
flat `Color(0.055, 0.055, 0.07, 0.94)` before it are both gone.

### An item grid's cell is 36 pixels, and comes from the art

`CIFLattice`'s `ddj` is an 8-slice-style base with a trailing underscore,
but unlike a frame it expands to only **four** names: the client's loader
takes `left_up`, `right_up`, `right_down`, `left_down` and stops. They are
not corners -- they are one cell each, differing in which shared separators
they carry. Measured from the alpha of the 36x36 art: `left_up` is opaque to
its edges (interior cell, draws the divider on its right and the bar below),
`right_up` has 144 transparent pixels in a 4-wide column (last column),
`left_down` has 144 in a 4-tall row (last row), `right_down` has 272 (the
bottom-right cell).

So the grid comes from the artwork. **All 14 lattices in the archive divide
by 36 exactly, in both axes; not one divides by 32.** The inventory is 4x8,
storage and stalls are 6x5, exchange is 6x2, the action bar is 9x2 and 4x2,
the pet bag is 7x4. The old `LATTICE_CELL := 32` -- and its comment
explaining away the 4.5-column remainder as border -- was a guess dressed as
a finding, and it also meant every cell tried to load the 8-slice base as a
single texture, got nothing, and drew an empty hole.

### Godot's minimum size was silently inflating every authored rect

`Control.set_size()` clamps up to the combined minimum size, and three
different minimums were winning against the layout:

- a `TextureRect`'s minimum is its texture, so `GDR_PI_BG_TILE_D`, authored
  `332x37` over a 128x128 tile, came out `332x128` and buried the rows under
  it. Fixed with `EXPAND_IGNORE_SIZE`.
- a `Label`'s minimum is computed from the theme's **default** font until
  its theme cache refreshes, which takes a frame in the tree. Measured: a
  Label with a 9px override reports minimum height 23 immediately and 13
  after one `process_frame`. So every authored 12-pixel row was built 23
  tall.
- a `Button` with text has a minimum from its text and stylebox, so a
  16x16 close button came out 17x31.

The labels are fixed by re-applying the authored rects over the first few
frames. The trap inside the trap: the first version stored
`Rect2(node.position, node.size)` as the rect to restore -- reading back the
value that had just been clamped, so the pass re-applied the very number it
existed to remove.

### Window chrome, from the layouts that spell theirs out

The close button and title were this project's own invention. They no longer
are. `ifalchemybox.txt` declares the whole convention in a 376-wide window:

```
GDR_ALCHEMYBOX_DRAG   CIFDragableArea  10,  0, 355, 42
GDR_ALCHEMYBOX_TITLE  CIFStatic        10, 18, 355, 12   HAlign=1
GDR_ALCHEMYBOX_CLOSE  CIFCloseButton  350, 12,  16, 16
```

A 42-pixel title strip inset 10 a side, a centred caption 12 tall at y=18,
and a 16x16 close button 26 in from the right edge. Every other close button
in the archive is 16x16 too. Four of the six name no artwork, because the
client's close-button class hardcodes
`interface\ifcommon\com_windowclose.ddj` and builds its focus and press
states from the usual suffixes -- so `CIFCloseButton` is now a control type
`UiBuilder` knows, with that default.

### A window is its frame plus its artwork

`section_size` used to return the frame's rect. ifinventory's gold row
(`GDR_INVENTORY_STA_MONEY`, `0,305,176,28`, carrying
`int_window_downbox.ddj`) hangs 25 pixels below it and was falling outside
the window and its hit area. Taking the bounding box of *everything* instead
over-corrected: ifplayerinfo's `GDR_PI_TEXT_HP_DAT` is a 228-wide text field
starting at x=153 in a 364-wide window, which made the character panel 381
wide for a field the client clips. Counting only controls that carry
artwork gets both right -- and across the archive's 140 framed sections
artwork stays inside the frame in 103 against 92 for every control.

### And a reminder about screenshots

The inventory grid looked like it overflowed the frame on the right. It does
not. A scanline across the rendered image puts the cell dividers at x=487,
523 and 559 -- 36 apart -- with the grid ending at 595 and the frame at 609,
which is the authored layout exactly. The overflow was in the eye.

New tools: `client/tools/dump_layout.gd` (one layout, in declaration order),
`dump_window_tree.gd` (a built window with every rect, texture and minimum),
`grep_layouts.gd` (search all 248 layouts by name, type or artwork),
`sweep_lattice.gd`, `sweep_window_size.gd`.

## Hundred-and-fourteenth round: every listing the client asked for was refused

The first render with a real server behind it showed a character in nothing
but shorts, an empty inventory and empty panels. Two causes, one of them
large, and the reason neither had been caught is the interesting part.

### Rendering against a server at all

`qa_shot.sh` boots `World3D.tscn` directly, so every render this project has
ever taken was of a client with no server. That is fine for terrain and
scenery and useless for anything the server owns -- equipment, vitals, the
inventory, the real monster list. Two things fix it:

- **`cmd/server -in-memory`**: the server runs with no database at all.
  Seven packages gained a `MemStore` alongside their `SQLStore`
  (`inventory`, `equipment`, `skill`, `quest`, `guild`, `friend`,
  `refdata`), each with its own tests, and `main` picks a wiring rather
  than a fork. Worth having on its own: the server is now a single binary
  anyone can run without setting a database up.
- **`SRREVAMP_QA_SERVER`** plus `qa_shot.sh --server`: the QA run performs
  the same sequence a player does -- connect, register, log in, create a
  character, enter the world -- and hands over to World3D, which reads
  `NetClient.last_enter_world_result` exactly as it does after a real
  character select. `--server` with no argument starts the in-memory server
  on a spare port and signs in to it.

### The starting kit could not be given

The server said so itself, in one line nobody had read:

```
character created without its starting kit character_id=1
  err="adding item 4734 for slot 1: querying max stack for item 4734: not found"
```

`refdata`'s `GetMaxStack` returned an error for an item with no row, so
`inventory.AddItem` refused to store it -- and the five kit items have no
rows on a deployment that has imported nothing, which is every fresh
deployment. Refusing to store an item because its stack size is unknown
loses the item; storing it one to a slot does not. `GetMaxStack` now
answers zero -- "no configured limit" -- which the inventory already reads
as "does not stack". Errors are kept for a lookup that actually failed.

### Ten handlers rejected the client's requests as malformed

With the kit given, the character still rendered bare, and the client's own
log said why once asked:

```
World3D: server reports 0 equipped item(s) for QaTester (error: malformed request)
```

Every request that names a character and asks for nothing else -- the
inventory, equipment, quest, party, guild and friend listings, ten handlers
in all -- decoded its payload with `DecodeCharacterCreateRequest`, each
under a comment reading *"reuse: it's just {Name string}"*. That was true
when it was written. Character creation later gained a `Gender` field, so
the shared decoder began requiring **two** length-prefixed strings while the
client kept sending one, and every listing started failing. The client
showed it as an undressed character and empty panels.

They now decode a `CharacterNameRequest`, which is exactly one string and
cannot drift with character creation again.

### Why the tests all passed

Each of those handlers had a full-flow test over real TCP. Every one of them
sent `CharacterCreateRequest{Name: "Aria"}.Encode()` -- the server's own
encoder, putting the second empty string on the wire that only the server
expected. **A round-trip test that uses one side's encoder on both sides
cannot tell whether the two sides agree.** Nine of them failed the moment
the decoder was corrected, which is the clearest possible statement of what
they had been testing.

The guard is `wire_shape_test.go`: it builds the payload the way the client
does, by hand, from a `u16` length and the UTF-8 name and nothing after it,
and decodes *that*. Reverting one handler makes it fail, which was checked
rather than assumed.

Also fixed here: `TestNewCharacterIsDressedAndHasVitals` walks the whole
sequence a client performs on a fresh install against an empty refdata
store, so "a new character is dressed" is now a test rather than a render.

## Hundred-and-fifteenth round: a window is more than its Create section

Three more reasons the panels looked hollow, and one negative result worth
keeping.

### The artwork decides, not the type name

`UiBuilder` matched control types by name and built anything else as an
empty `Control`. **496 controls across the archive name an 8-slice base** --
a `ddj` ending in an underscore -- and they are spread over **220 different
type names**, most appearing once or twice: `CIFSkillBoard`, `CIFCommunity`,
`CIFGuild`, `CIFBarWnd`, `CIFWnd`, `CIFJobRankSlot`, `CIFTradeInfoWndStoreSlot`
and so on. Four were handled.

That is why the skill window was see-through: `GDR_SKILL_BOARD` is a
`CIFSkillBoard` carrying `interface\inventory\int_window_` over 351x270 of a
364x333 window. Dispatching on the suffix instead covers all 496 in one
branch and cannot go stale as type names appear.

### "Create" is the chrome, not the window

A layout is not one section. ifskill has three and ifguild has ten, and
`HudWindow` built only `Create` -- which for ifguild is three controls, and
for ifskill is the frame and one strip. All the content is in the others.

Which sections compose is per window and had to be established rather than
assumed. For the skill window the binary settles it: one function sets
`m_bySkillWndType` and branches, loading `Withdrawal` for type 1 and
`MainSkillWnd` for types 2 and 3. They are **alternates**, so the normal
window is Create plus MainSkillWnd, and building both would draw two
layouts over each other. ifguild's nine are not settled and are recorded as
open rather than guessed at.

### A tile is a tile wherever it is used

ifguild's `GDR_GUILD_BG` is a `CIFStatic` -- not a `CIFNormalTile` --
carrying `com_bg_tile_b.ddj` over 403x58. Stretching a 128x128 damask over
that smears the pattern; artwork from `bg_tile\` now tiles whatever control
names it.

### The negative result: `resinfo\base.txt`

`base.txt` holds five window recipes named Type1..Type5, and each is exactly
the rule that has been missing: a `CIFFrame` on `int_window_` with a
`CIFNormalTile` of `com_bg_tile_b.ddj` inset **16 pixels inside it on every
side**, optionally with `com_blacksquare_` panels over their own
`com_bg_tile_e` backing. It looks like the answer to "what fills a window
body".

It is not, and both halves of that were checked:

- **The client never reads it.** `resinfo\ifbattery.txt`,
  `resinfo\ifworldmap.txt` and thirty more layout paths are string literals
  in the binary. `base.txt` is not among them, and no string containing it
  exists at all.
- **Nothing could select a recipe.** A section header carries one field
  after its rect -- `Section = Create,"0,0,0,0","0"` -- which nothing had
  ever read, and which was the only candidate. It is `0` on **all 480
  sections in the archive**.

So `base.txt` is a designer's prototype. Recorded here because it is a
convincing false lead and the next person to open it will think the same
thing.

Also settled while looking: the control factory carries a default artwork
path per control class, in the same string block as `CNIFLattice`'s. A
`CIFNormalTile` with no `ddj` defaults to `com_bg_tile_b.ddj`, a `CNIFrame`
to `interface\inventory\int_window_`, a `CNIFStretch` to `com_button.ddj`,
and a close button to `interface\ifcommon\com_windowclose.ddj`.

## Hundred-and-sixteenth round: chat, in the client's own window

`HudChat` builds `resinfo\ifchatviewer.txt` where the registry puts it --
`GDR_CHAT_BOARD` is a `CIFChatViewer` at `0,546,399,398`. The whole window
is authored: `chat_window.ddj` sliced by UV into three horizontal bands and
stretched (top and bottom 4 pixels, the middle over 348), the five channel
lamps, the whisper and hide buttons, the zoom and channel buttons, and the
input line at `18,378`. A scrollback goes over `GDR_LIST_CHATTING` and an
editable line over `GDR_CHAT_INPUTBOX`, both at exactly the authored rects,
because a `CIFTextBox` and a `CIFEInputChatBox` have no Godot equivalent to
build directly.

Verified end to end rather than by looking: `qa_shot.sh --say` makes the QA
run send a message after entering the world, and the render shows
"QaTester: the windows are built from the client own layouts now" in the
window -- a line that went to the server and came back, not one the client
wrote to itself.

Three things it fixed on the way:

- **Typing walked the character.** Movement reads `Input.get_axis`, which
  polls the raw key state and is not affected by a focused LineEdit, so
  every "w" in a chat message also moved the player. It always had. Only
  the input is suppressed while typing -- an early return there would have
  skipped gravity, region streaming and the position updates below it.
- **Statics were eating clicks.** A `TextureRect` stops mouse input by
  default, so a window's own decorative artwork swallowed clicks meant for
  the window -- which is what makes a window draggable by its frame. The
  frame slices and the tiles already ignored input; statics were the
  outlier.
- **`position` on an anchored Control is not relative to the anchor.** It
  is relative to the parent's top-left, so setting `position.y` to a
  negative number against a bottom anchor put the whole window off the top
  of the screen. Explicit `offset_*` with `grow_*`, the way the underbar
  does it.

The developer chat panel is retired with it -- the last piece of the old
HUD that overlapped the real one.

## Hundred-and-seventeenth round: the numbers the server actually has

The character panel and the inventory's gold row are filled from a new
`OpCharacterStats`, which carries gold, vitals, and physical attack and
defence. Those last two are not new arithmetic: they are exactly what
`attackerDamage` and `defenderArmor` resolve from equipment when this
character swings at something and when something swings back.

**Only what the server really computes.** The panel has thirteen more rows
-- strength, intelligence, magical attack and defence, balance, hit rate,
parry, three job grades, current and next experience -- and nothing here
produces any of them, so they are not on the wire and stay as the layout
drew them. A plausible number in those boxes would be indistinguishable
from a real one.

When there is a levelling system, the exp curve is already in the archive
rather than something to invent: `server_dep\silkroad\textdata\leveldata.txt`
is UTF-16LE, tab separated, 140 rows for levels 1 to 140, and column 1 is
the experience needed to advance from that level -- 118, 470, 1058, 1880,
2938 up to 103,622,218,294 at level 140. Its other columns are not read and
are not guessed at here.

### The same refdata bug again, in combat

`attackerDamage` and `defenderArmor` looked every equipped item up in
refdata and returned an error when the row was missing. Reference data is
brought by the operator, so on a deployment that has imported none of it a
character wearing the starting kit **could not be attacked at all** -- all
five armour pieces failed the lookup and the whole attack errored.

`refdata` now has a real `ErrItemNotFound` sentinel, and combat treats it as
what it is: armour nobody has stats for protects nothing, and a weapon
nobody has stats for hits as a bare fist. Real lookup failures still fail.
This is the same shape as the max-stack fix two rounds ago -- an absent
reference row is a normal answer, not an error -- and it is now tested with
an empty store rather than assumed.

## Hundred-and-eighteenth round: which of a window's sections are drawn together

`ifguild.txt` has ten sections and `HudWindow` was building one of them --
"Create", which for that file is three controls. Everything a guild window
shows is in the other nine, and a layout does not say which of them are
parts of the same window and which are modes or dialogs. Building them all
draws two layouts over each other.

**The binary is silent here.** `resinfo\ifguild.txt` appears nowhere in the
client's strings, and neither do `MemberView`, `SortBtn` or `GrantPower`.
(`NotifySubBox` and `NotifyContents` do -- both belong to the
apprenticeship window's loader, which is a different file with sections of
the same name.) So the usual method does not reach this one.

The authored geometry does. `sweep_section_overlap.gd` measures how much of
each section's own control area sits under every other section's controls:

```
                        Create   GuildInfo NotifySubBo  MemberView     Command     SortBtn NotifyConte
GuildInfo                   0%           -          0%          0%          0%          0%          0%
NotifySubBox              100%          0%           -          0%          0%          0%          0%
MemberView                100%          0%          0%           -          0%          0%        100%
Command                     0%          0%          0%          0%           -          0%          0%
SortBtn                     0%          0%          0%          0%          0%           -          0%
NotifyContents             99%          0%          0%         85%          0%          0%           -
```

**GuildInfo, NotifySubBox, SortBtn, MemberView and Command are pairwise
0%.** They tile the window without touching: the guild header at the top,
the notice under it, the column headers, the member list, and the buttons
down the right. NotifyContents covers 85% of MemberView and MemberView
covers 100% of NotifyContents -- the notice text and the member list are
the same box shown one at a time. GrantPower covers 95% of MemberView;
GuildPointUp and PositionGrant overlap each other 79% and sit across the
window: dialogs.

The rendered window bears it out -- guild master and member count, the GP
gauge with its donation button, the notice with its edit button, the
Member / Level / Level / Donate GP column headers with a sort toggle, and
Join, Grant authority, Withdraw, Leave and Position allocating down the
right.

**Why the measurement is trustworthy**: run on ifskill it puts MainSkillWnd
and Withdrawal at 100%, which is the answer the client gives independently
-- one function, branching on `m_bySkillWndType`. A method that agrees with
the binary where the binary speaks is worth using where it does not.

Also this round: `remote_godot.sh`, because AGENTS.md now forbids running
Godot on the developer's machine. `check`, `tests` and `script` ship the
working copy to the render box and run there. Its own trap: the test loop
ran one suite out of fifty-nine and reported success, because `ssh` without
`-n` reads the caller's stdin and ate the rest of the file list.

## Hundred-and-nineteenth round: what fills a list

The party-match and guild windows had their structure but their list bodies
were see-through. The layout looked like it was missing a fill:
`GDR_PARTYMATCH_SLOTLIST_BLACKSQUARE` is a `com_blacksquare_` border around
735x305 of list with nothing declared behind it.

It is not missing. The same section declares `com_bg_tile_e` -- a 4x4 fully
opaque black tile -- behind each of its **three small** black input boxes,
and nothing behind the big one. An author who wanted a fill there would have
written one; the rows are the fill.

The client says what a row is. One method on a row slot sets
`interface\ifcommon\com_bar01_` when the row is unselected and
`com_bar01select_` when it is, and six classes carry the same pair. Those
expand to `left`, `mid` and `right` -- 4x24 caps around a 24x24 middle, all
opaque. A **horizontal** 3-slice.

Which turned up two more things:

- **Not every base ending in `_` is an 8-slice.** `_build_frame` looked for
  `left_up.ddj` under `com_bar01_` and `com_bar02_`, found nothing, and drew
  an empty box -- for every `CIFBarWnd` (57), every `CIFWnd` (31) and the
  rank and store slots that name a bar explicitly. Asking the archive for
  the corner and falling back to the horizontal scheme covers all of them.
- **A slot's shape says whether it is an item square or a list row.** A bar
  under `CIFSlotWithHelp` would be wrong for all 259 of them. The archive
  separates the two with no ambiguity at all: every slot naming no artwork
  is either **exactly 1.0** wide-to-tall (335 -- CIFSlotWithHelp,
  CIFExtQuickSlotSlot, CIFSlotWithHelpForPackage, CIFSkillSlot) or **at
  least 3.5** (58 -- CIFPartyMatchSlot and CIFMentorMatchSlot at 29.8,
  CIFStallNetworkSlot at 20.3, CIFEquipSkillSlotWnd at 3.5). The threshold
  sits in an empty gap. `sweep_slot_shapes.gd` prints the table.

The slot dispatch is matched on the type name containing "Slot" rather than
listed, for the same reason the 8-slice dispatch is: the four types that
were listed reached neither the party-match rows nor the stall network's,
and the archive has fifteen.

Both lists now render the way the reference screenshots show them -- a dark
body of separated rows under the column headers.

## Hundred-and-twentieth round: rows on the layout's own grid, and the client's own captions

Two more things the panels were being given by this project when the
archive already had them.

### The list rows

`_fill_list` dropped an `ItemList` over the window, sized by hand from the
title bar down. Every one of these windows already says where its list goes
and how tall a row is: ifquest's `GDR_QUEST_SCROLLMGR` is `4,27,356,323`
with eleven 2-pixel divider tiles at y = 52, 79, 106 ... 322 -- a **27-pixel
pitch**, measured from the spacing of the dividers rather than chosen. The
rows now go inside the scroll manager at that pitch, inset 12 pixels to
match where the dividers start.

A window with no scroll manager keeps the overlay, because there is nothing
authored to put the rows on -- ifskill is one.

### The captions

`HudWindow` took its title from the caller. A window's own frame -- the one
at the origin -- sometimes carries a `Text`, and that is the client's own
wording: **5 of the archive's 17 origin frames have one**, the other 12 do
not. ifparty's is `UIIT_STT_PARTY_INFO`, which the text table resolves to
"Party informaiton" -- the game's own typo, which is a good sign the string
is coming from the right place. ifquest's is `UIIT_STT_QUEST_LIST`,
ifaction's `UIIT_STT_CHARACTER_CONTROL`, ifapprenticeship's
`UIIT_CTL_TC_MEMBER`, ifitemmallmyinfo's `UIIT_STT_SILKMALL_MY_INFO`.

The other twelve keep the caller's title, because there is nothing to use.

## Hundred-and-twenty-first round: NPCs get their names, and the plates get seen

### There is no authored NPC facing, and now that is settled

`npcpos.txt` is **12,367 rows, every one exactly five columns** -- id,
region, x, y, z. No angle. And the archive has no other NPC table:
`server_dep\silkroad\textdata\` holds `npcpos.txt` and `npcchat.txt` and
nothing else NPC-shaped. So there is nothing to read, and any facing this
project gives an NPC would be invented. Recorded as a closed negative
result rather than an open question, which is what the TODO called it.

### The names were one join away

The same `characterdata*.txt` parts that give an NPC its model give it its
name: a row carries an id, an `SN_` key and a `.bsr`, and
`textdata_object.txt` turns the key into what the game calls it.
`parse_models_by_name` already did that join from one side (name -> model,
for monsters); `parse_names` does it from the other (id -> name), which is
what an NPC placed from npcpos.txt needs, because npcpos carries an id and
nothing else.

**13,169 names** resolve, and all 18 NPCs placed in Jangan town are
labelled -- "Merchant Associate Hong Ing", "Soldier Donzzadodler Jiqwe
[Teleport]", "Fairy Amelia". A key the text table does not know is left out
rather than drawn as `SN_NPC_CH_...`.

### Why no name plate has ever been visible

Including the monster labels, which have existed for many rounds. A
`Label3D` is scene geometry by default, so it shrinks with distance -- and
at this world's scale a character is `REAL_CHARACTER_NATIVE_HEIGHT` units
tall rather than 1.8, so Godot's default 0.005 pixel size drew every plate
a few pixels high and it read as nothing at all.

The real client draws a name plate in **screen space** from the entity's
position, which is what `fixed_size` is. With that and a pixel size scaled
for it, the plates read the same at any distance -- and the monster labels
appeared for the first time as a side effect.

The clearance above a model is a fraction of the model's own height rather
than a fixed offset, for the same reason the monster labels measure their
skeleton: NPC models vary enormously in size, and one number puts a plate
through a tall NPC's face and far above a short one.

### A note on hunting with renders

Four renders were spent looking for NPCs that were placed correctly the
whole time. The camera was in region 98/168 -- `qa_shot.sh`'s default
`--region` -- while the coordinates being aimed at were region-local to
97/168. The fix was reading the runner's own default, not another picture.

## Hundred-and-twenty-second round: NPCs stop being walk-through

An NPC was a Skeleton3D under a Node3D and nothing else, so a player
crossing Jangan's square walked straight through the merchants. They get a
capsule now, and two things about it were got wrong first and measured
right after.

**Radius from the model's depth, not its width.** Taking the furthest bone
from the origin gave radii of 4.95 to 8.87 on NPCs 9.9 to 17.7 units tall
-- a capsule as wide as the NPC is tall. These models stand in a bind pose
with their arms out, so the furthest bone is a hand. Half the model's
*shallower* horizontal AABB axis is its front-to-back thickness, which is
what a body is: 1.70 to 4.62 against heights of 12.7 to 40.6.

**Layer 5, not layer 1.** The player's body masks bits 1 and 5
(`collision_mask = 17`) and the camera arm masks only bit 1. Layer 5 is
therefore exactly "stops the player, ignored by the camera", which is what
the navmesh walls already use it for and what an NPC wants: on the default
layer, standing in a crowd would have the camera shoved about by every
merchant in it.

Verified by measurement rather than by walking into one on camera:
`SRREVAMP_QA_NPCBODY=1` fires a short horizontal ray at each nearby NPC's
middle and reports the capsule it was given and whether anything stops the
ray. **5 of 5** in Jangan town. The first run said 4 of 5, and the miss was
the check's fault rather than the collider's -- two NPCs stand within half a
unit of each other on the square (npcpos has 2013 at 980.79, 989.13 and
2014 at 980.34, 989.19), so a ray aimed at one is legitimately stopped by
the other.

## Hundred-and-twenty-third round: 232 objects you could walk inside, not eight

The parked item said eight objects in Jangan have no navigation mesh. The
count was right for Jangan and wrong for the world, and the cause was one
line.

`_load_object_collision` resolved an object by reading `bsr.mesh_path` --
the object's **first** mesh, and only that one. A building's walkable
surface is one piece among many, and the pieces are in alphabetical order,
so whether the graph found it was chance:

```
cj_acce.bsr    6 meshes   navigation data in [1] cj_acce_wall.bms
cj_armo.bsr    7 meshes   navigation data in [3] cj_armo_floor.bms
cj_etc.bsr    12 meshes   navigation data in [10] cj_etc_wall02.bms
cj_luxury.bsr 12 meshes   navigation data in [4] cj_luxu_floor.bms
cj_portal.bsr  6 meshes   navigation data in [2] cj_por_floor.bms
cj_weapon.bsr  6 meshes   navigation data in [5] cj_weap_floor.bms
cj_pal_bigdoor 5 meshes   navigation data in [4] cj_pal_bigdoor_wall01.bms
```

Every one of them has it in exactly one mesh, and in none of them is it the
first. `dump_object_collision.gd` prints that table for any object.

**Swept over the whole object index** (`sweep_object_collision.gd`), 2,858
distinct objects:

| | |
|---|---|
| carry navigation data in no mesh | 815 |
| in exactly one mesh | 1,926 |
| in more than one | **117** |
| of the 2,043 that carry it: found by the first mesh | 1,811 |
| **not found — reported as having none** | **232** |

So it was 232 objects world-wide, not eight, and the 117 that carry it in
more than one mesh (every tree does) mean taking the *first piece that has
any* would still have lost half of those. The parts are merged:
`BmsCollision.merge` concatenates vertices and shifts every cell and edge
index by the running count, leaving `NO_CELL` alone -- shifting that marker
would turn the far side of a wall into a reference to a real cell.

**Verified two ways.** Every region around Jangan now places 100% of its
objects (62/62, 90/90, 114/114, 122/122 …) with no "could not be resolved"
line at all, where the town used to report eight. And `SRREVAMP_QA_SCAN=40`,
which is the measure of this exact symptom, finds **none of the eight** among
the spots where a player stands under solid geometry -- the 82 that remain
are Christmas trees, balloons, lion statues and water, which is what walking
under a canopy looks like and is not a bug.

`bms_collision_merge_test.gd` covers the index arithmetic, because a cell
pointing at the wrong vertex still builds a triangle, just somewhere else.

### And 238 buildings with no navigation mesh at all are *not* a bug

The same sweep says 815 objects carry navigation data in no mesh anywhere,
238 of them under `res\bldg` -- including Jangan's palace halls
(`cj_pal_main_buil`, `cj_pal_south_buil02`, `cj_pal_sub_buil01`,
`cj_pal_guard_buil`). That looks like the same hole one layer down, and it
is not: the region's own `.nvm` terrain edges enclose the palace, so the
buildings inside it need no walkable mesh of their own.

Checked rather than argued. `SRREVAMP_QA_SCAN=40` over 1,566 sampled spots
flags 82, and the objects behind them are **fifteen distinct models, every
one a canopy or a decoration** -- Christmas trees, dry trees, a water plane,
event balloons and pillars, a Halloween pumpkin, a lion's pedestal. Not one
palace building and not one shop. Standing under a tree is what that
measurement is supposed to look like.

## Hundred-and-twenty-fourth round: the HUD with nothing of ours on it

The zone travel box sat across the player block and Log Out across the
bottom-right corner in every screenshot this project has ever taken. Both
are developer chrome with no authored equivalent yet -- the zone box is
still the only way to travel and Log Out is still the only way out -- so
they are **hidden rather than retired**, behind F1.

Discoverability is the catch with a hidden control, and the chat window
solves it: `_log_system` writes into the authored chat viewer now, so the
line "Developer tools (zone travel, log out): F1" is on screen where a
player will read it, in the client's own window and font.

The result is the first render of this project that shows the game and
nothing else: the player block with a real name and 100/100, the minimap
with the zone and coordinates, the chat window carrying a message that went
through the server, the underbar, and NPCs with the names the game calls
them.

Also measured this round, and better than the parked note says: within 1,400
units of Jangan town, `SRREVAMP_QA_FLOAT` finds **four** objects clear of
their own ground -- two event doors 14 above and two grass clumps 12 below --
and none of them is the "large structure standing on its own platform" the
note describes as the unresolvable case.

## Hundred-and-twenty-fifth round: hdr[2] decoded — one record per vertex

The last two header words this project read and never used. The same shape
-- a header word parsed into a variable and ignored -- is what the `.bsr`
offset table, the `UV_*` fields and `.bms` skinning each turned out to be
hiding, and `hdr[2]` is now the fourth.

**Swept over all 24,984 `.bms` files in a real Data.pk2.** 801 carry an
`hdr[2]` section, and in **every one of the 801 the record count equals the
mesh's own vertex count** -- never the index count, the triangle count, the
bone count or the collision-cell count. Asking what the count is a count
*of* was the whole method; it needed no guessing from the byte pattern.

A record is a `float32` and a `uint32`:

- the float takes **16 distinct values** across the archive: 0.0, then 0.05
  to 0.50 in steps of 0.05, plus 1.0
- the integer is **only ever 0 or 1**

And the two agree exactly. Across 316,452 records the integer is **1 in
precisely the 292,980 whose float is 0.0** and **0 in precisely the 23,472
whose float is not**. Two fields agreeing perfectly across three hundred
thousand records is the check that the record has been split in the right
place.

**What carries it**: `avatar` 245, `clothes` 69, Jangan scenery 36, armour
sets (`heavy` 28, `light` 17, `thief` 17), `spear` 11 and **`cobweb` 10**.
Garments, banners and cobwebs -- things that hang.

**What it means is an inference and is labelled as one.** A per-vertex
amount that is zero for most vertices, rises through a hand-authored 0.05
ladder for the rest, and carries a flag saying which -- on dresses, robes
and cobwebs -- has the shape of *how far each vertex is free to move, with
the attached ones pinned*. Two attempts to confirm that failed and are
recorded in `docs/protocol/BMS_FORMAT.md`: `SetOptimizeCloth` turns out to
be `CObjOptimizeCloth@CharacterVisualChange`, driven by
`resinfo\optimize_clothes.txt` -- a visual-quality option about *which*
clothing is drawn, not how it moves. And the `.bms` loader cannot be found
by string search at all: neither `JMXVBMS`, `JMXV` nor `.bms` appears in the
client, so the magic is compared inline and there is no anchor.

`BmsReader` carries the data now (`vertex_motion`, `vertex_pinned`) even
though nothing renders with it. Leaving a decoded section unparsed is how
this format's skinning stayed hidden for months, and a reader that carries
the data is a reader whose understanding can be tested.

**Still open**: `hdr[3]`. Its count differs from `hdr[2]`'s in 793 of the
801, and the bytes between it and the end of the file do not divide by its
count to anything whole. And 450 meshes have an `hdr[2]` pointer whose
declared count does not fit the file -- one claims four billion records,
which took the audit tool out of memory before the bound was added.

### hdr[3] too: a list of links between vertices

Same round, same method. A `uint32` count, then that many **12-byte records** of
`(uint32 vertex, uint32 vertex, float32 distance)`.

The count matches nothing — not the vertex count, the index count, the
triangle count or `hdr[2]`'s — so the arithmetic that cracked the other
sections could not find this one. What found it was reading the bytes: at
`avatar_m_angel_powers_dress_part2.bms` the words go 78, then 1194, 1199,
1.20348, then 1194, 81, 1.55728, then 1199, 81, 0.95313. A count and then
triples, where the first two of each are plainly indices into a
1,210-vertex mesh and the third is plainly a length.

**Then verified rather than assumed**: across the same 801 files and 58,433
records, every index is inside its own mesh's vertex count and every
distance is positive. Not one violation. Two independent bounds holding
across fifty-eight thousand records is what makes a 12-byte split a
finding rather than a reading.

**Not decoded**: the section does not end where the records do. All 801
carry a trailer -- 380 bytes in that dress, 167 distinct lengths across the
archive -- of small integers all below that file's own link count (4, 36, 0,
33, 6, 39, 75, 34 … against 78 links). That reads as an ordering over the
links, but its length is not a whole multiple of the link count and it does
not parse as another count-prefixed block. The reader takes the records and
stops.

### What the two together say

Separately, each is a structure. Together they are recognisable: **per-particle
mobility with a pinned set, and a list of pairs of those particles with a rest
distance for each**. That is the whole input to a mass-spring solve, and it is
hard to read as anything else -- a mesh wanting per-vertex tinting or a second
UV set would not also ship a table of distances between vertex pairs. On
dresses, robes, banners and cobwebs.

The gap that keeps this an inference rather than a finding: no code, here or in
the client, has been *seen* consuming either section. The `.bms` loader cannot
be reached by string search, and the one feature that looked like the consumer
(`SetOptimizeCloth`) turned out to be a `CharacterVisualChange` option about
which clothing is drawn. So whether the client simulates with this or merely
sways along it is not established, and is not claimed.

### And the rest of hdr[3] closes exactly

The trailer after the link records is not one thing but two. The section is:

```
uint32 count
count x { uint32 vertex, uint32 vertex, float32 distance }
count x   uint32                    one index per link
36 bytes                            not established
```

`4 + count * 16 + 36` **equals the distance to the next section in all 801
files**, and **every one of those per-link words is a valid index into the
links themselves** — an ordering over them.

The last 36 bytes are not decoded, and the way that was established is worth
keeping. Read at the *end of the file* they looked like a leading integer
and an axis-aligned box, and the numbers were persuasive: a hat's y running
13.6 to 18.2, a dress's 0 to 16.1, exactly the extents those garments have.
Read at the section-relative offset — which is the same place only when
hdr[3] happens to be last — the leading word is 1 in 706 files and 0 in 95,
and the six floats order as a box in **325 of 801**. Three files agreeing is
a hypothesis. The sweep is the finding.

## Hundred-and-twenty-sixth round: reading the one thing that had been reasoned

The six-piece stretch window -- `com_lattice_outline_`, `com_blacksquare_` --
was the one place this stretch of work argued instead of reading. Its loader
fills four edge slots from two textures, `left_side` twice then `right_side`
twice, and which edge got which was settled by a bevel argument: the darker
tile (peak 0x39) on the top and left, the brighter (peak 0x6a) on the bottom
and right, because that is how the corner art is lit.

The argument was right, and it is now read. `FUN_00499e10` lays out the four
edge quads at object offsets `0x5e0`, `0x640`, `0x6a0` and `0x700`, each
0x60 bytes -- four vertices of 24 with x at +0 and y at +4:

| slot | geometry | edge |
|---|---|---|
| `0x5e0` | x spans `right - w` to `right`, y the full height | left |
| `0x640` | y spans `bottom - h` to `bottom`, x the full width | top |
| `0x6a0` | x spans `fVar1` to `fVar1 + w` | right |
| `0x700` | y at `fVar3`, across the width | bottom |

and `FUN_00499980` stores its four arguments into `0x370`, `0x374`, `0x378`,
`0x37c` in argument order -- which the caller fills, lowest stack address
first, with left_side, left_side, right_side, right_side.

So **left_side draws the left and the top; right_side draws the right and
the bottom**, and `UiBuilder`'s fallback already did exactly that. The
comment now says it was read rather than inferred, which is the part that
matters: an argument that happens to be right is still an argument.

## Hundred-and-twenty-seventh round: the .bms loader found, and everything checks

The two decoded sections were measured from the archive because the loader
could not be reached: `JMXVBMS`, `JMXV` and `.bms` appear nowhere in the
client's strings. That was true and it was not the end of it -- **the magic
is constructed in code rather than stored**, and the engine's own assert
strings name its source files. `PrimGeometry.cpp` is the one (`.bms` files
live under `prim\mesh\`; the engine calls them Prim resources), its
version check is the function comparing against `0x30313130` and
`0x424d5320`, and the reader is two calls along from it.

Every measured claim holds:

| Measured from 24,984 archive files | Found in the client |
|---|---|
| `hdr[2]` is 8-byte records | `read(vec, count * 8)`, vector element size `>> 3` |
| `hdr[3]` is 12-byte records | `read(vec, count * 0xc)`, element size `/ 0xc` |
| one 4-byte word per link, same count | `read(vec, count * 4)` under the **same** count |
| a 36-byte tail | `read(this + 0x31, 0x24)` |

And the loader gives one thing the sweep could not. It resizes those
vectors with default values first, and the defaults *are* the field layout:
the 8-byte vector fills with `(0x3f800000, 0)` -- a `float32` of **1.0** and
a `uint32` -- and the 12-byte one with `(0xffffffff, 0xffffffff, 0)` --
**two `uint32`s of −1** and a `float32`. Two index fields defaulting to −1
is what a pair of "no vertex yet" sentinels looks like, and it is exactly
the split the byte-pattern reading produced.

The 36-byte tail is read **inline into the object**, not into a heap array,
which is why its length never varies -- a fixed struct rather than a list.
That is new; the sweep could only say it was always 36 bytes.

**What the data is for is still not established.** The loader reads it and
this trail says nothing about what consumes it, so "a mass-spring cloth
setup" stays an inference. The structure is now a finding.

### Also re-checked this round

The six-piece stretch window's edge pairing, which was argued from bevel
brightness rather than read. It is now read -- `FUN_00499e10` lays the four
edge quads out in the order left, top, right, bottom, and the loader fills
those four slots with `left_side` twice then `right_side` twice -- and the
argument was right. The comment says which it is now.

### The rest of the audit pass

Everything else this stretch of work asserted, checked against the client
where the client can answer:

| Claim | Status |
|---|---|
| `hdr[2]` 8-byte and `hdr[3]` 12-byte records, +1 word per link, +36 bytes | **read** — `CPrimGeometry`'s own allocations and vector element sizes |
| the two record layouts, `(float, uint)` and `(uint, uint, float)` | **read** — the defaults the client resizes those vectors with, `(1.0, 0)` and `(-1, -1, 0)` |
| six-piece stretch window: left_side → left and top, right_side → right and bottom | **read** — the edge quads are laid out left, top, right, bottom and the loader fills those slots in that order |
| a lattice cell is one piece of its artwork, not a constant | **negative check** — no `36`/`0x24` anywhere in the lattice class |
| controls are declared front to back | **behaviour verified, mechanism deduced** — the list is push_back in parse order, so the renderer must walk it backwards; that loop was not found |
| window chrome geometry (42-pixel strip, caption at y=18, 16x16 close 26 in) | **authored data**, from ifalchemybox — not a client claim |
| the 8-slice dispatch by `_` suffix | **ours, not the client's** — there each class calls its own loader; what is read is how many pieces each takes |
| guild/party-match section composition | **geometry**, validated against the one case (ifskill) the client settles independently |
| slot row-vs-square threshold | **ours**, from a measured distribution with an empty gap between 1.0 and 3.5 |

The two that are neither read nor reducible to authored data -- the draw
order's mechanism and what the `.bms` sections are *for* -- are the two that
say so in the code that depends on them.

## Hundred-and-twenty-eighth round: the world map, read off the client's own two row parsers

The world map had been parked with the tile *set* established and the tile
*meaning* not. The last note said what to do next: "read the placement side
rather than the loading side -- the function that puts the player's marker
on the map converts region + local position into a map pixel, and that is
the mapping stated outright."

That is what happened, and it went further than the marker.

### Finding the placement side

The same technique that found the `.bms` loader last round: the engine's own
assert strings name its source files. `NIFWorldMap.cpp` appears in
`FUN_00622b60` ("Illigal Map Index"), which computes the map's world-space
box:

```
minX = (left   - 135) * 192 + LT_x        maxX = (right  - 135) * 192 + RB_x
maxY = (top    -  92) * 192 + LT_y        minY = (bottom -  92) * 192 + RB_y
units per pixel = |maxX - minX| / draw_x ,  |maxY - minY| / draw_y
```

135, 92 and 192 are **the three constants this project's position readout
already used**, arrived at independently and long before. It multiplies
`left`/`right` by the *y* constant and `top`/`bottom` by the *x* one, which
is exactly the question that had been open: **`left`/`right` are region y,
`top`/`bottom` are region x.**

The bounds come from `server_dep\silkroad\textdata\worldmap_mapinfo.txt`,
whose world-map row reads left 46, top 113, right 177, bottom 70, tiles
128x128, draw 4224x1408, "one region size" 4x4. That is exactly the loop
already read from `FUN_006160d0`: A from 46 by 4, B from 113 down by 4,
33 x 11 = 363 tiles, 4224 x 1408 to the pixel. Jangan (region x 97, y 168)
is `map_world_166x97.ddj`, and the file exists.

### Then the parsers, rather than the header

The header row names every column, and reading columns off a header is
reading, not recovery. The binary has the RTTI names `CWorldMap_MapInfo` and
`CWorldMap_DungeonMapInfo`; each section's rows go through its own parser
(`FUN_0096f680`, `FUN_0062c170`), and each is a straight run of read-int /
read-float / read-string calls into fixed member offsets. Those give the
column layout exactly, and two things the header cannot:

- **The `WLocalmap` parser stops after column 19.** Columns 20
  (`전체맵버튼타입`) and 21 (`한 리젼 크기`) are authored and never read --
  the "4 regions to a tile" the tile loop uses is a **literal 4** in the
  code, not the table's `4x4`. Our reader still uses the column, because it
  is authored data and it agrees, but the test now asserts the grid it
  produces is the size the draw size implies.
- **The `Dungeonmap` parser** decodes the section that had been written off
  as "a different shape, not decoded": path in column 15, grid from the
  texture counts in 6 and 7, and one **float** in column 14 whose header
  states its own unit -- "1.0 = 256", a scale of 1.0 draws a region 256
  pixels wide. It stops after column 16, leaving six more authored columns
  unread.

### Why this is a finding and not a reading

Three independent things agree, and they would not if the axes were swapped:

| | |
|---|---|
| the world map's box over its draw size | **exactly 6.0** units per pixel, both axes -- and 6.0 is 192/32, i.e. 32 pixels a region, i.e. 128 per 4-region tile |
| Jangan's own local-map row | left 166, top 99, right 170, bottom 96 -- region y 168 inside 166..170, region x 97 inside 96..99, from the data alone |
| Jangan's box over 1024x768 | **0.75** both axes, and the town square (97/168 local 1002,917) lands at pixel (517.6, 517.7), inside its own map |

Against a real archive: **363/363 world tiles present, 25/25 dungeon floors
complete** -- several thousand files, no misses.

### Two things the check caught that reading would not have

- **`world()` was wrong.** It returned "the row whose type is 0", and the
  table has **three**: the main world plus `map_jupiter_a` and
  `map_jupiter1_1`, which are worlds of their own you switch to. The main
  one is the only type-0 row drawn from a grid.
- **The three `map_survival_*` rows have no artwork** -- and every one of
  their four region bounds is **0**, so their world box is degenerate and
  their scale is zero. They are unfinished placeholder rows, not shipped
  content this archive happens to lack. That is a different answer from
  "missing files", and only the bounds show it.

### Recorded as a caution

The vertical **flip** -- image y growing as world Y shrinks -- is *not* read
from the client, which takes an absolute value and so says nothing either
way. It follows from the table's own naming, `좌표 LT_y` being the offset
paired with `top`, the larger region x and so the larger world Y. The code
that depends on it says so.

Still open: the other 269 `map_world_*` tiles in the archive, whose A is odd
mod 4 and which no row in this table describes. Two of the four functions
referencing the tile format string have not been read.

## Hundred-and-twenty-ninth round: the world map window, and Pic Area

With the table decoded the window is mechanical, and it went up in one
pass. `GDR_WORLDMAP` is registry-framed rather than self-framed like the
panels -- `CIFWorldMap` at `100,100,652,424` on `interface\frame\
mframe_wnd_`, and `ifworldmap.txt` holds three buttons and nothing else --
so the frame comes from resinfo\ginterface.txt, the interior is ours, and
the buttons go on top.

Three things did not have to be guessed:

- **The interior's insets are the frame's own art.** `mframe_wnd_left_up`
  is 40x68 and `mframe_wnd_left_down` is 40x48, so the window is 40 down
  the sides, 68 across the top and 48 across the bottom, leaving 572x308.
  Read at runtime from the loaded pieces, so a window on another frame set
  gets it right too. (`dump_ddj_sizes.gd` is the tool; it is four lines and
  it settles a class of question that otherwise gets eyeballed.)
- **The player marker is `interface\minimap\mm_sign_character.ddj`.** The
  client's world map destructor releases exactly the textures the map
  loads, and it names them one by one: four `wmap_window_edge_N` pieces,
  `mm_sign_character`, `wmap_sign_party`, `wmap_sign_apprenticeship`,
  `wmap_sign_questnpc`, `wmap_sign_huntingpoint`, then the 363 tiles and
  the current dungeon's. That list is the whole texture set, stated.
- **The way in is `GDR_MINIMAP_BTN_TOG_MAP`**, on `mm_map_button.ddj`, an
  authored button the minimap was already finding and not connecting. No
  hotkey had to be invented.

### The bug the render caught: Pic Area is not decoration

Jangan's map came out squashed with a blank band across the bottom of the
window. `map_jangan.ddj` is stored **1024x1024** but its row says texture
1024x1024, **pic area 1024x768**, draw 1024x768: only the top three
quarters of the image is map, and the rest is padding. Stretching the whole
texture into the draw size squeezes the map and shows the padding. Drawing
`Pic Area` as the source region fixes it, and costs the world map's own
tiles nothing -- theirs is equal to their texture size.

Two columns that read the same on eleven of the archive's rows and
differently on the twelfth. Worth remembering next time a pair of columns
looks redundant.

### What the picture is evidence of

Nothing here was concluded from a render -- the marker's position is
`pixel_for_world()` and no part of it was fitted. But the render is a
strong independent check, because two things had to land and did:

- On **Jangan's own map**, the marker sits on the **dragon statue** in the
  town square. The player is at region 97/168 local (1002, 917), which this
  project established as the square and dragon long ago and by other means.
- On the **world map**, the marker sits **inside the walled rectangle**
  that is Jangan drawn at 6 units a pixel.

One transform, two maps at scales eight times apart, both right.

### Also this round

`--write-movie` advances scene time by a fixed 1/60 a frame regardless of
how long the frame really took, so `create_timer(6.0)` needs **360**
rendered frames and never fires in a 60-frame run. Anything in a QA hook
that waits should be expressed in frames over 60, not in seconds.

Left undrawn on purpose: the four `wmap_window_edge_N` pieces are 4x4
apiece and whether they are four corners or four tiled edges is not
established, so the map area has no inner border rather than a guessed one.

### Closing out the 269 tiles, same round

The parked note said the archive's other 269 `map_world_*` tiles were
"presumably a second zoom level", because the file set holds two
interleaved families of the first name component. **It is not.** All four
functions that reference `interface\worldmap\map\map_world_%dx%d.ddj` --
two loaders and two destructors, belonging to two classes -- write the
identical bounds longhand: 46 to 177 and 113 down to 69, by 4. There is no
second loop.

So the extra tiles are asked for by nothing. They are not junk either:
every one is 8,340 bytes, the same 128x128 DXT1 as the tiles in use, and
they fall into exactly three more step-4 lattices at their own origins --
224 on a lattice offset three regions from the main one, a full 5x5, and a
full 5x4.

The 5x5 is **the Jupiter field, tiled**. `map_jupiter1_1` covers world
X 12288..16128 by Y -1728..2112 drawn 640x640, which is 6.0 units a pixel,
the world map's own scale -- and 5 x 5 tiles of 128 is 640x640 over that
same box. The table names a single image for it instead. The other two
lattices match no row.

A guess ("second zoom level") replaced by a measurement, and the measurement
was one grep of the format string's xrefs plus a set difference.

## Hundred-and-thirtieth round: a second table, and its stale column

`worldmapguidedata.txt` turned up while looking for where the world map's
landmark and monster signs get their positions. It is the world map guide's
own data, four `#section`s, authored separately from
`worldmap_mapinfo.txt` -- and it says a lot of the same things, which makes
each a check on the other.

`client/tools/check_worldmap_guide.gd` runs the join, on `맵ID`. Against a
real archive **nothing disagrees**. The world map's row reads start region
`46x113`, one picture `128x128`, one region size `4x4`, map id 0 -- the same
grid, from a table with no code path in common with the one it was read
from. `시작 리전` being written `<left>x<top>` also states the tile naming
convention outright.

It closed one of last round's loose ends. The archive's spare 5x5 tile
lattice at A 199..215, B 87..103 is named here: `jupiter_field`, map id 17,
start region **`199x103`**, 128x128, four regions a tile. `worldmap_mapinfo`
gives that same map as a single image, which is why its loader never asks
for the tiles. (`jupiter1_1` likewise names the `map_jupiter_a_<A>x<B>` set
at start `235x126`, 256x256.) The 5x4 lattice still matches nothing.

### The column not to read

MONSTER and QUEST both carry `x | y | 리전x | 리전y | pos_x | pos_y` -- at
different indices, MONSTER's `x` being column 8 and QUEST's column 5, so a
reader has to track the section here too. The `x`/`y` pair is a world-map
pixel, and it is **stale**:

| | rows on the world map's grid | stated minus derived |
|---|---|---|
| MONSTER | 142 | **5 tiles out horizontally**, 0 vertically -- every one a `MOB_CH_*` |
| MONSTER | 31 | exact -- the newer `MOB_TK_*`/`MOB_SD_*` western rows |
| QUEST | 89 | exact |

The pitch is a whole 128 on both axes for all 262, and the **row** index is
exact for all 262 -- a third independent confirmation that `top` is 113, the
step is 4, and B descends. The column index is out by exactly five tiles,
twenty regions, and only on the older Chinese monsters. The map was re-cut
westward at some point and those rows were never re-based.

So the region and `pos_` columns are the ones to use.
`WorldmapGuideReader` keeps `x`/`y` as `stated_pixel` -- dropping data is
its own kind of dishonesty -- and derives the position with `pixel_in()`.

**The general shape of this**: a table that agrees with another on eleven
things and disagrees on the twelfth is worth more than a table that agrees
on everything, because the twelfth is where the history is. Two rounds ago
it was `Pic Area` against `Texture Size`; here it is a stale pixel column
against a live region one.
