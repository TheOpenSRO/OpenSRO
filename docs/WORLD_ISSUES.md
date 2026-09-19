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

### Town labels, same round

The world map draws a name plate for every local map the table carries that
falls inside it. Two of the three things that needs are authored:

- the **plate** is `wmap_name_side` + `wmap_name_middle`, 8x24 caps around
  a 4x24 middle that tiles -- a horizontal three-slice, the same scheme as
  `com_bar01_`, and measured from the art rather than assumed
- the **name** is the row's own `UIIT_`/`SN_` key through the text table --
  a column the client's parser reads and throws away, so it is there to be
  used
- the **position** is ours: `world_min`/`world_max` give the box that map
  covers and the plate sits at its middle, which the world map's own
  transform turns into a pixel. Where the client puts its own signs
  (`wmap_sign_location.ddj`, 432x36) is not established, and the code says
  so.

A row whose name does not resolve draws nothing rather than a raw
`SN_ZONE_*`, and the three placeholder rows with zero region bounds fall
out on their own -- their box is a point.

Also fixed while rendering it: the window could be opened before the first
position arrived, and centring on a player who is nowhere yet parks the
view in the middle of the map. It now centres on the first fix.

## Hundred-and-thirty-first round: the character dressed from the game's own tables

"Fix the player models and armor" -- and the first render against a live
server showed what was wrong with them: the server had equipped the six
Cotton starter items, and the client drew an ornate gold set. Not a bug in
the drawing; a bug in what was being drawn. The client had no idea what
item 4842 *looks like*, so it picked a look by `item_id % 8` from eight
`clothes_NN` sets it had found by convention, hung each piece off a bone
it had guessed from the file's two-letter suffix, and had one piece -- the
shoulder guard -- sitting at the pelvis for a reason nobody had found.

All of that rested on one recorded belief: "real per-item ID-to-model
mapping data doesn't exist anywhere this project can reach (checked;
`_RefObjItem` has no code-name/model column)". It is column 52 of the item
table. `4842 Cotton Suit` reads `item\china\man_item\clothes_01_ba.bsr`,
and every one of the 7,264 rows that names a model names a file that is
really in Data.pk2 (`client/tools/check_item_requirements.gd`).

### What the files say, read rather than guessed

- **The body is a `.bsr` like an NPC's.** `characterdata`'s rows 1907-1932
  are the 26 playable China classes: `CHAR_CH_MAN_FIGHTER` ->
  `char\china\chinaman_fighter.bsr`, type **0** in its header (the client's
  factory builds a `ResChar` for case 0 -- BSR_FORMAT.md already had that
  and called the type "unconfirmed"), naming the skeleton, nine skinned
  pieces, the material and 217 animations. `SkinnedBsrAssembler` builds it
  with real weights, the same path every NPC already took; the player was
  the last character still rigidly assembled from a hand-kept path table.
- **An item is a `.bsr` of type 5**, and it says how it hangs. A suit,
  trousers, a hat, boots or wristlets name no skeleton: their mesh's bone
  palette names the body's own bones (`clothes_01_ba.bms` lists nine,
  `Bip01 Neck1` first), so they are skinned onto the body like a body
  piece. A weapon or a shoulder piece names **a skeleton of its own and
  the body bone it hangs from** -- `blade_01.bsk` under `Bip01 R HandMid`,
  `clothes_sa.bsk` under `Bip01 Neck1` -- authored right after the skeleton
  path, where this project's reader had been reading a bare path list and
  stopping. That second string is the whole shoulder-guard mystery: its
  vertices are in its own skeleton's space, and reading them as body space
  put them by the hip.
- **The weapon bone is per item** (`Bip01 R HandMid`, not the
  `Bip01 R Hand` this project chose), and comes from the file.

### Who may wear what, from the tables

The code name is a summary of the row -- `ITEM_CH_M_CLOTHES_01_BA_A_RARE`
is race, gender, family, degree, piece, variant, rarity -- and every part
agrees with a column, measured over every equipment row in a real table:
`CH`/`EU` against Country 0/1 with no exceptions, `M`/`W` against
ReqGender 1/0, and the six piece letters against TypeID4 (HA 1, SA 2, BA 3,
LA 4, AA 5, FA 6; 136-140 rows each). **AA is the gauntlet**: the equipment
window's own slot artwork is `equip_slot_gauntlet.ddj`, the one slot the
avatar struct's debug dump skipped and EQUIP_SLOTS.md could not name.

The level requirement is four `(type, level)` pairs, and only seven type
values occur in the whole table: 1, and 513 through 518.
`skillmasterydata.txt` names them -- row 1 is `캐릭터`, *character*, and
513-518 are Warrior, Wizard, Rogue, Warlock, Bard, Cleric, the six European
masteries. **`ReqLevelType` is a mastery id, and 1 is the character
itself.** A China item asks for a character level; a European item asks for
a mastery level. That is the "sometimes skill level" of the original,
stated by its own tables.

The server now enforces the slot (from the type ids), the race, the gender
and the level where the requirement is by character level
(`equipment.Refusal`); mastery-level and stat requirements are read and
kept but not enforced, because nothing tracks those numbers yet and
refusing on one the server does not have would be inventing it. Characters
have a level (1, no way to gain one) so that the most common requirement
can be checked at all. Slots are renumbered to the game's own order --
helm, mail, shoulder guard, gauntlet, pants, boots, weapon, shield -- and
the starting kit dresses all six armour slots.

### On the wire

The snapshot other players receive carried a five-bit armour mask and two
booleans; it now carries slot and item id per worn slot, because the id is
what dressing needs and the mask could only ever draw one look.

### What the picture is evidence of

The marker of this round is not a measurement but the thing measured for:
a new character, dressed by the server, draws with the Cotton Hat on its
head, the Cotton Talisman at its collar, the Cotton Wristlet on its forearm
and the Cotton Suit on its back -- the white set the table names, smoothly
skinned, where two hours earlier it wore gold.

### Corrections to the record

- `docs/protocol/EQUIP_SLOTS.md` guessed two unlabeled gap slots in the
  avatar struct; the twelve-byte stride allows one, and it is the gauntlet.
- `CharacterAssembler`'s header claimed `.bms` has no bone weights; the
  hundred-and-tenth round had already shown otherwise, and the header now
  says so.
- The README's "no item-to-model mapping exists" is replaced by where it is.

### Measured, and not a model problem: the character stands under a placed object at the QA spot

The full-body render at the long-standing QA spot, local (1002, 917) in
97/168, showed the character buried to the waist. Before touching the model
the rig report was extended to measure it, and the answer is placement:

```
player at y -51.90; bones -51.89 (Bip01 R Toe0) .. -35.85 (Bip01 Head); meshes -52.00 .. -32.67; ground -51.90
first surface down from overhead: y -40.45 (11.45 from the feet) on .../Obj_cj_jang_gate_126/cj_jang_gate07
walkable heights in this column: [-51.90]
```

The body is the right size -- 16 units from toe to head, and both
`chinaman_skel.bsk` and the `europeman_skel.bsk` the fighter's `.bsr`
happens to name stand 15.95 tall with the same bone names, so the swap is
harmless -- and the feet are exactly on the one walkable height the nav
graph knows in that column. What sits 11.45 units above the feet is a
placed object's collider (`cj_jang_gate07`), which the nav graph does not
list as a surface here. The earlier render at the same spot, before any of
this round's changes, shows the same waist-level cut. A world-lane item,
recorded rather than papered over with a spawn offset: either that object's
deck should be a walkable surface here, or the spot is under something a
player was never meant to stand beneath. The QA tour's own square spot,
(1002, 1020), is on the plaza deck the nav graph knows.

### The starting kit is the table's own defaults now

The kit had given the six `_RARE` Cotton rows -- hat, suit, talisman,
wristlet, trousers, shoes -- because those were the rows found first. The
table marks what a new character actually starts with: every code name
ending in `_A_DEF`, and for a China character that is a suit, trousers and
shoes in one of three families (Cotton garment, Cloth protector, Copper
armour), one weapon of each of five kinds, and arrows for the bow. No hat,
no shoulder guard, no gauntlet. `StartingKitFor` now gives the garment set
for the character's gender and the Copper Sword; the family and the weapon
are this project's picks (the original chooses by the class picked at
creation, which this server does not record), the rows are the game's.

## Hundred-and-thirty-second round: the animation table inside the `.bsr`

The body's animations had been chosen by matching file names against hints
-- `_standcity`, `_walkforward` -- which worked for the two China fighters
and would have worked for nothing else. The `.bsr` header has eight
section pointers and this project read four. The next two are **mesh
groups** and **animation groups**, and the animation groups are the
game's own answer to "which animation plays for what".

Parsed offline from seven real files -- the two China fighters, the
warrior, a monster, an NPC, a sword and a shoulder piece -- with one entry
layout (`type, file index, event count, events of four words, walk-point
count, points, a trailing float`), and in every one the parse ends
**exactly** on the sound-effect pointer, which is what makes it a reading.

The groups are keyed by weapon kind: a China body carries `spear`, `bow`,
`sword`, `default`, `cart` and four avatar groups; the client's own table
of seventeen names (`FUN_00d77650`, beside the `nDefaultWearNum <
DEFAULT_WEAR_NUM` assert) adds Europe's `onehand_sword`, `twohand_sword`,
`dagger`, `dual_axe`, `onehand_staff`, `twohand_staff`. Within a group,
each entry's **action type** is a number paired, in the `default` group,
with a self-describing file: 0 `chinaman_fighter_standcity`, 1
`_walkforward`, 2 a plain attack, 3 `_benormalhit`, 4 `_diehardhit`, 6
`chinaman_standbattle`, 7 `_runforward`, 13-15 sitting, 22 blocking, 23
walking backward, 36 the death loop, 38 pickup, 50-57 emotes, 26 and up
skills. A monster's group reads the same way (`mangnyang`: 0 stand01, 1
walk, 2 attack01, 3 damage01, 4 die, 7 run); an NPC's has 0 `_basic` and
122 `_time`, the fidget.

A weapon group lists only what differs -- `sword` has its own attacks and
run but **no stand or walk** -- so lookup is "the weapon's group, then
`default`", and that is now what `BsrReader.animation_for` does, what the
player uses (with the held weapon's TypeID4 choosing the group: sword and
blade share `sword`, spear and glaive share `spear`, bow is `bow` -- the
three China masteries' own pairs), and what every NPC and monster uses for
its idle instead of a name hint.

Two things the table settled on the way past. The game's default gait is
the run -- type 7 is what a sword replaces, type 1 is not -- so moving now
plays the run. And a warrior-class body has an entry whose file index is
`0xFFFFFFFF`, "no file": the reader leaves that path empty rather than
indexing off the end.

**Not read from the binary**: how the client composes the group *name*
for a held weapon. It resolves names by string compare
(`FUN_00a5b300`) and the one caller found is the avatar visual-change
path, which takes the name from a text table. The China pairing above is
read off the tables and the groups a body actually carries; Europe's is
not mapped yet.

### Both bodies, and the one-shots

The woman renders in her own default kit -- 3652/3653/3654 and the sword
-- on `chinawoman_fighter.bsr`, whose `sword` group hands the run to
`chinaman_fighter_runforward_sword` (a man's file, listed in the woman's
own group: the game's data, not a mix-up here). `qa_shot.sh --gender
china_woman` creates her.

The action types also cover what happens in a fight, and those now play
by type rather than not at all: a monster hit plays its type-3 entry once
and returns to its idle, a monster death plays type 4 once and holds the
last frame -- the body stays where it fell until the animation has run,
then the next monster list removes it -- and the player's own type-3 hit
reaction plays over stand or run. `qa_shot.sh --attack` swings at the
nearest monster every second so these can be rendered.

### Other players stop being statues

Another player's body was built, dressed and then left in its bind pose --
arms out, which no character in the game ever does -- because only the
local player's tick applied a pose. Every other body now plays the town
idle of the group its weapon selects, and switches to that group's run
while its body is still catching up to a position update (a tenth of the
body's height from its target counts as moving, so the tail of the
interpolation reads as standing). Same table, same fallback, same phase
offset that keeps a crowd out of step. Not rendered: it takes two clients,
which the harness does not have; the path is the local player's with the
gait chosen from movement rather than from input.

### The swing, the blow and the reply, on the table's own clock

An attack now plays the weapon group's next plain attack -- types 2, 5,
16, 17 in turn, `sword_base_01` to `_04`, or the bare-handed straight-left
/ straight-right / hook-left / hook-right -- and the target's hit reaction
plays when that swing's **hit event** falls, not when the packet lands.
Every attack entry carries one or two type-1 events (`sword_base_01` at
200 and 566, `mangnyang_attack01` at 651) and every walk and run two
type-2 events with `(0, 1)` then `(1, 0)` -- footsteps, one per foot, at
305 and 633 of a run about 950 long. Those numbers read as milliseconds in
every entry checked; the unit is inferred from them, not read from the
client's use of them, and the code says so.

When the monster strikes back, it plays its own type-2 attack and the
player's type-3 reaction lands at *its* hit event. The QA harness attacks
about once a second now (`--attack`), which is roughly a swing's length.

Not done, and not guessed: how long the character stays in the battle
stance (type 6, `chinaman_standbattle`, or a weapon group's own) after a
fight. Nothing found says, so the body returns to the town idle when its
swing ends.

## Hundred-and-thirty-third round: the weapon picks its group in a switch

The last round left one thing unread: how the client turns a held weapon
into the name of an animation group. It resolves names by string compare
(`FUN_00a5b300`), and the one caller found then was the avatar path. The
answer was one step from the table itself.

The name table (`FUN_00d77650`) is an array of twenty `std::string`s at
`0xec6280`, 28 bytes apart, seventeen of them set: 0 `default`, 1 `sword`,
2 `spear`, 3 `bow`, 4 `cart`, 5 `onehand_staff`, 6 `onehand_sword`, 7
`twohand_sword`, 8 `dagger`, 9 `dual_axe`, 10 `harf`, 11 `twohand_staff`,
12 `onehand_staff`, 13 `avatar_wing`, 14-16 `avatar_nasrun1`-`3`. The
three short names are under Ghidra's five-character minimum for its
string list and were read out of the exe's `.rdata` with objdump -- `bow`,
`cart` and `harf`, the harp with an f. `FUN_00a5b300` walks that array,
and the functions that index it directly are the interesting ones.

**`FUN_00a5a7d0`** is the switch: a 16-bit packed type id shifted down by
eleven -- `TypeID4` -- and a race byte. 2 and 3 return entry 1 (`sword`),
4 and 5 entry 2 (`spear`), 6 and 12 entry 3 (`bow`), 7 `onehand_sword`,
8 `twohand_sword`, 9 `dual_axe`, 10 entry 12 and 15 entry 5 (both
`onehand_staff`), 11 `twohand_staff`, 13 `dagger`, 14 `harf`, and 16
`sword` for race 0 and `onehand_sword` for race 1; anything else is null,
and the caller (`FUN_00a5bd10`, `CObjCharacter.cpp`) asserts `pStrAniNew`
on it. That caller reads the item in equip-visual slot 6 -- the weapon, in
the slot order EQUIP_SLOTS.md records -- and, before any of that, answers
`cart` (entry 4) while the character is pulling a transport. The race byte
is `+0x9c` of the character's data, the same byte `FUN_009dd040` tests to
load `cj_store.bsr` or `euro_streetstall01.bsr` for a stall.

Checked against the real item table on the box: the weapon rows (TypeID3
6) tallied by TypeID4 and code-name family give exactly one family per
case -- 216 `CH_SWORD` at 2, 215 `CH_BLADE` at 3, 216 `CH_SPEAR` at 4,
216 `CH_TBLADE` at 5, 215 `CH_BOW` at 6, and 250-251 each of `EU_SWORD` 7,
`EU_TSWORD` 8, `EU_AXE` 9, `EU_DARKSTAFF` 10, `EU_TSTAFF` 11, `EU_CROSSBOW`
12, `EU_DAGGER` 13, `EU_HARP` 14, `EU_STAFF` 15 -- plus 15 `FORT_FORTRESS`
at 16 and 17 `ETC_FIREWORK` at 1, the null case. So the crossbow shares the
bow's animations and the cleric rod and the dark staff share
`onehand_staff`, neither of which the tables alone could have said.
`WEAPON_ANIMATION_GROUP` is now that switch, and `FUN_00a5b550` confirms
the lookup order this project had read off the data: the action in the
weapon's group, then in `default`.

The avatar groups turned out not to be weapon-driven. `FUN_004ea570` is
`CharacterVisualChangeManager.cpp` parsing
`textdata\charactervisualchange.txt` -- a row is five numbers, a group name
and two model paths, and the header of the real file names them
`... MaterialID, AnimationName, BsrName(M), BsrName(F)`. About forty rows
name `avatar_nasrun1`-`3`, all of them Nasrun and Amalrun mall-hat skills.

The fight from last round, re-rendered after the disk was cleared: the log
shows the exchange as designed -- swing after swing at the weasel, each
answered, 2 off it and 4 off the player a round -- and the frames show the
sword-base swings with the blade overhead. The weasel itself stands behind
a snowman decoration from that camera, so its reaction is on the log, not
in a picture.

Still not read: how long the battle stance lasts.

## Hundred-and-thirty-fourth round: two players on the public server, and what "mad wack" was

The first two people to log into the public test server (a VM that follows
`dev`, `deploy/README.md`) sent screenshots: one of them T-posed in
underwear, both in a red set nobody was given, a Mangyang drawn as a
treasure chest, a Weasel with a label and no body, a huge ornate disc at
each player's feet or side, NPC names in Arabic and Spanish, and name
plates readable across the whole plaza. Six things, four causes.

**The client was v0.1.86.** That release is nineteen commits behind `dev`,
from before the character was dressed from the tables (round 131), before
other players were animated (round 132), and before the equipment wire
changed from a mask and two booleans to slot-and-item pairs. Against the
new server the old client reads the count byte as the mask and the first
slot byte as "has a shield", and draws a shield from its old variant list
at its old bone: the disc. The T-pose and the red set are round 131 and
132's bugs, already fixed. Nothing to change but the release -- and the
debug panel below now prints the build, because a screenshot of an old
client against a new server looks like six unrelated bugs.

**The chest and the missing Weasel were the display-name join.** The
client resolved a monster's model by joining characterdata's `SN_` key
through `textdata_object.txt` to a display name and matching the name the
server sent. That name is whatever language column the archive yields,
and this archive's yielded Arabic and Spanish -- so "Mangyang" matched a
different row and "Weasel" matched none. The server now sends each
species' **code name** (`MOB_CH_MANGNYANG`, `MOB_CH_GYO` for the Weasel,
`MOB_WC_EARTHGHOST`; the rows' own keys, read off the box's table) in the
monster snapshot, and the client resolves the model by code first,
`NpcTableReader.parse_models_by_code` over every row. Measured on the
box's archive first: the name join already had two rows named "Mangyang"
(the event `MOB_EVE_STRONG_TQ_MANGNYANG` and the real one, same model by
luck) and kept whichever came last.

**The Arabic and Spanish were the language-column rule.** `UiTextTable`
took column 8 when it held Latin text but then preferred the *rightmost*
Latin field after it, on the theory that a later column was more recently
authored. Measured against the box's three text tables the two rules
disagree on 93 of 13,059 object rows, 243 of 12,570 UI rows and 2 of
8,395 item rows, and in every one of them the rightmost field was a
Vietnamese column ("Hép b¸u vËt" where column 9 said "Jewel Box"). On a
multi-language archive the rightmost Latin field is Spanish, or an Arabic
column carrying a Latin name. Column 8 first, then left to right, labels
Jangan's nineteen town NPCs identically on the box's archive and English
on the other; the test has both shapes.

**Name plates now show within a range** -- `NAME_PLATE_RANGE`, 80 units, a
project choice (nothing found says where the original starts drawing
names), fading over the last tenth, adjustable live from the panel and
remembered. Other players' plates are now the same plate NPCs get, over
the body's own height, instead of a world-sized default label.

Two more things from the same evening. The login screen remembers the
server that last answered and the account name (`ClientSettings`,
`user://settings.cfg`, no password), because the public server's address
is not `127.0.0.1`. And "my chat box is too tiny on this TV": a UI scale
and a chat font size, both remembered, both on the panel.

*Addendum, same night -- "my scaling is fucking up the text"*: at UI
scale 2.35 the login screen's Register button read "Registe". Reproduced
on the box in a 1160x700 window, then varied: at 2.0 the word draws
whole, at 2.5 the last glyph is missing again, and at 2.35 with the
project's font oversampling switched off it draws whole. So Godot 4.2
loses a string's last glyph under *fractional* font oversampling (the
window sets oversampling to its content scale factor). The project
setting that lets the window drive it is now off and `ClientSettings`
sets it by hand: the scale itself when it is a whole number, 1.0
otherwise -- whole-number scales stay crisp, fractional ones are
rasterised at base size and scaled, slightly soft, complete.

**The debug panel** (F3, `DebugPanel`) is the answer to the next such
report: the build and, from source, the branch and commit; the server and
zone; world and region-local position, camera, gender, weapon group; every
worn slot's item and model; every other player with gender, group and worn
ids; every monster with code, model, hp and distance; NPC counts; the ten
nearest name plates; the three archives with sizes, the species counts,
and what `SN_MOB_CH_MANGNYANG` reads in this archive (the language column,
in one line); `ObjectLoader`'s load failures with the last twelve paths;
frame times, draw calls, memory. Copy puts it on the clipboard, Save
writes `user://logs/diag-<time>.txt`, and there is a draw-mode switch
(wireframe, unshaded, overdraw, lighting), a camera-through-walls toggle,
an attack-nearest button and a region-local teleport.

Not settled from the pictures, and not guessed: Alexandria's white ground
and black buildings on that archive. The panel's loading section will
say which files were missing; the box's archive has to be rendered there
first to know whether it is the archive or the client.

*Later the same night*: on v0.1.87 Alexandria's ground rendered textured
and the panel's Copy showed one load failure (a Dunhuang building,
unrelated) -- the white ground was the old client. **The black buildings
are not**: a render on the box at 90/48 (663, 526) draws the large
structure behind the spawn solid black too, with the ground, stalls,
trees and walls beside it textured. Every texture it asks for is found
(no loading failure names it), so it is a material or texture-format
question, not a missing file; measured next.

## Hundred-and-thirty-fifth round: the `.ban` files carry their own clock

"The animations are happening at 5x speed for everything." They were.
Every animation played at `BAN_FPS`, a hand-picked 30 keyframes a second
that the code itself called an engineering guess, and the `.ban` header
words this project had filed as unknown -- observed `(666, 30, 1)` --
were the clip's duration in milliseconds, the grid its keys were
authored on, and whether it loops. The "offset table" the reader skipped
is the key time table: when each keyframe falls, in milliseconds.

Measured with `client/tools/dump_ban_times.gd` over the China fighter's
animations, every file parsing to exactly its own length:

| Clip | Duration | Keys | At 30 keys a second it took |
|---|---|---|---|
| `chinaman_fighter_standcity` (town idle) | 2333 ms | 14 | 466 ms -- five times too fast |
| `chinaman_standbattle` | 2000 ms | 5 | 166 ms -- twelve times |
| `spear_stand` / `bow_stand` | 2000 ms | 5 | 166 ms |
| `spear_run_fighter` / `bow_run_fighter` | 666 ms | 17-18 | 566-600 ms -- about right, which is why the run looked plausible in renders |
| `spear_walk_fighter` | 1166 ms | 24 | 800 ms |
| `skill_ch_sword_geomgi_c` | 2000 ms | 50 | 1666 ms |

The keys are not evenly spaced (`[0, 466, 500, 583, 933, 1166 .. 2333]`
for the idle), every time is a multiple of 33.3 ms -- the 30 in the
header is the authoring grid, not a playback rate -- and the cyclic flag
is 1 for stands, walks and runs and 0 for skills, sitting and dying.

So `BanReader` reads `duration_ms`, `authored_fps`, `cyclic` and
`key_times`, and `Skeleton3DBuilder.apply_ban_pose_at` poses a skeleton
at a time on the clip's own clock, blending rotation (slerp) and position
between the two keys that bracket it -- a 2000 ms stance with five keys
would otherwise be a slideshow. Every player of an animation in World3D
(the player's stand/run and one-shots, every NPC's and monster's idle,
hit and death, other players' gaits, the QA animation report) runs on
that, and `BAN_FPS` is gone. The `.bsr` event times of round 132, read
as milliseconds by inference, sit on the same 33 ms grid as these key
times, which is as close to confirmation as the data gives.

### The camera and the click, from the same evening

Three controls complaints, all real. The camera swung back to its default
yaw and pitch whenever the character moved -- `CAMERA_RECENTER_DEGREES_PER_SECOND`,
120 a second -- so every view a player set up was thrown away the moment
they walked; it now stays where it was put, and W/A/S/D are relative to
it (W walks away from the camera whichever way it has been orbited)
with the character facing the way it walks. The click ray used the default
collision mask, so it hit the player's own capsule, the invisible navmesh
wall bodies and NPC capsules before the ground -- "the character does not
move to the direction you click"; it now hits terrain and placed objects
only. And a left drag orbits like a right drag, becoming a destination
only if released within six pixels of where it was pressed.

The debug panel gained a row of town buttons -- Jangan, Donwhang, Hotan,
Constantinople, Samarkand, Alexandria -- each the zone box's own
`x/y@localX,localZ` target that was being typed by hand.

Reported and not reproduced: "when I touch a building I get stuck in
it". Two measurements with the new `SRREVAMP_QA_COLUMNS` probe (what the
walkable graph knows at a column: the navmesh cell's own object list, each
placed object's cells, footprint and drawn extent, and the blocking edges
within 40 units), plus a walk:

- **The armour shop is walled.** `cj_armo` carries navigation in one of
  its seven meshes, `cj_armo_floor` (73 cells at 7.2 above the ground),
  and a walk west into it from (240, 1100) steps onto the porch strip at
  x 245 and stops dead at x 231 for the rest of the run, `on object
  cj_armo at 7.2` -- the porch's inner edge blocks, as it should. Inside
  the footprint (x 126-230) the graph has terrain only, but nothing walks
  there.
- **The QA spot (1002, 917) is under a bridge deck the navmesh does not
  carry.** `cj_jang_gate` (object 4 of region 97/168, footprint 444-1505 x
  295-1617) has navigation in one of its five meshes, `cj_jang_gate06`,
  180 cells spanning y -33 to 1; the piece drawn over that column,
  `cj_jang_gate07`, has none, and gate06's nearest cells to (1002, 917)
  are 240 units away. So `landing_height_at` puts a QA arrival there on
  the terrain 22 units below the deck, inside it, and 85 units west at
  (915, 940) on the deck. Not a placement bug: the real navigation data
  has no surface there. Whether the real client keeps a character off
  that column (a pond, per the plane grid?) is not established; QA
  arrivals should use (915, 940).

So the report is not this. A Copy from the panel at the moment it
happens -- position, camera, and what the graph says underfoot -- is
the next measurement. Alexandria's "things floating in the air":
`SRREVAMP_QA_FLOAT=400` around its spawn (90/48 at 663, 526) finds no
placed object more than 12 off its region's ground on the box's archive.

## Two-hundred-and-thirty-second round: attacks have no distance rule -- the server never refuses on it, the client's approach is the rule

The RE tick's step for 2026-09-19 11:04. Looking for the next per-fight value found an
absent rule instead: srrevamp's client sends an attack for any clicked monster and its
server accepts it at any distance. Read: the server dump contains no `0x3007`
(`UIIT_SKILL_USE_FAIL_WRONGDISTANCE`) while every neighbouring skill-failure code does
(`0x3003/4/5/8/9` in `Skill_CheckUseConditions`, `0x3006` in `CanBeAttackedBy`), so the
original server does not gate by distance either -- its client walks into range before it
sends. Basic attacks carry skilldata `Range` 0 (melee), meaning the weapon's own range;
other skills 6..200 in the table (150 on 6,889 rows), a unit not yet tied to world units.
Filed in TODO with the next probe (the itemdata `Range` column, the client's comparison
with the target's `BCRadius`). No value changed; monsters do not move server-side, so their
speed columns are not a shipped number yet either.

## Two-hundred-and-thirty-first round: the run speed is 50 world units per second, read at its use-site, and the client moves at the table's number

The RE tick's step for 2026-09-19 10:49, closing round 230. The chain, every link read
(`refobj_binary_format.md`):

- Field 42 of the common record is `RegionID`, resolved to a pointer at `+0xd8` -- which is
  why the nine words that follow are fields 43-51, one later than round 230 counted:
  `Speed1` is the word at **`+0xe4`**, `Speed2` at **`+0xe6`** (columns 46/47).
- `CGObjMobile::vslot_215` loads exactly those two into the walk (`+0x16c`) and run
  (`+0x170`) slots; `GObjPC_InitStats` publishes them as params 23/24; `FUN_0048b810`
  copies one into the live speed by move mode; and the step
  `CGObjMoverByDest::FUN_0048bff0` advances the position by `dir * |speed * dt|`, `dt` the
  main loop's seconds delta, capped at 160 per step. **World units per second.** (Round
  230's "speed getter" `FUN_0048b840` is the heading -- `atan2` of the direction.)
- Wired: `NpcTableReader.parse_speeds_by_code` (columns 46/47, tested); `World3D` reads
  the player's body row at load and moves at its run speed -- 50 -- with the old feel
  tuning (47.8) kept only as `MOVE_SPEED_FALLBACK`, disclosed. A straight QA walk covered
  49 units in its first 60 frames, then the navmesh stopped it at the pedestal; 0 errors.

## Two-hundred-and-thirtieth round: the character record's speed words, and why MOVE_SPEED is not changed to 50 yet

The RE tick's step for 2026-09-19 10:34, on the client's feel-tuned `MOVE_SPEED` (6 metres
per second scaled to the character, about 47.8 units/s). Read: the common record's fields
44-52 are nine 16-bit words at `+0xdc..+0xec` (the deserializer switches its base register
to `ebx` there, which is why `fields.py` left them unresolved), so `Speed1/Speed2` --
columns 46/47 by the schema every checked anchor has matched -- are the words at
`+0xe2/+0xe4`; every `CHAR_CH_*`/`CHAR_EU_*` player row in the user's table reads **16 / 50**
(Mangyang 8/22, Tigerwoman 20/90). The server's speed getter `GObjPC::FUN_0048b840` goes
through the character's current mover (`CGObjMoverByDest`/`ByCmd` at `+0x14c/+0x150`), whose
speed slot returns a published float; the step that multiplies by time was not found this
pass. So 50 agrees with the tuning within 5% under one reading of the unit, and that is
exactly the "suggestive curve" the rules say not to promote: `MOVE_SPEED` stays, its
comment now says what the number in reach is and what reading would earn it.
`refobj_binary_format.md` carries the layout; `RE_COMPLETION.md` the next probe.

## Two-hundred-and-twenty-ninth round: the fog planes are channels 10 and 11 times the view distance -- the model behind FOG_DENSITY, read

The RE tick's step for 2026-09-19 10:19, from the client's disclosed constants: `FOG_DENSITY`
had been a bounded rendering choice because "environment.ifo's two fog channels hold
normalized values, not distances". Both halves are read now (`ENVIRONMENT_FORMAT.md`):

- The client's environment update `Map::FUN_00a1baf0` evaluates the six FloatGraphs in file
  order (record `+0x25c .. +0x36c`, channels 7, 8, 10, 11, 12, 15) and multiplies the third
  and fourth -- **channels 10 and 11** -- by the view-distance global at `0xec54b0`
  (**2500.0** in the image), storing them as the fog near and far planes; its no-record
  fallback is `-0.2` and `1.0` times the same global. Channels 7, 8, 12 and 15 go through
  `(v + 1) / 2` and `1 - v` instead. The public doc's "FogNearPlane/FogFarPlane" at 7/8 is
  wrong for this client.
- The 74 real records agree: channel 10 in [-0.147, 0.813], channel 11 in [0.467, 1.0]
  (`tools/dump_environment_floats.gd`, new); the others span [-1, 1]. Jangan's Env7 puts
  the fog at 1250..2250 world units.
- `EnvironmentReader.CHANNEL_FOG_NEAR_PLANE/FAR_PLANE` are 10/11 now, with a float-channel
  sampler and tests; `World3D` computes each zone's real planes, logs them and shows them
  in QA_LOOK. What is still disclosed is the drawing: Godot 4.2's fog is exponential from
  the camera, so the real linear range needs a depth pass -- filed in TODO with the formula.
  No drawn pixel changed this round.

## Two-hundred-and-twenty-eighth round: the disclosed census is fallbacks and decisions; a stale comment corrected; naming levers measured

The RE tick's step for 2026-09-19 10:07. A census of every DISCLOSED / own-design marker in
the server code, against what a fight actually uses: monster attack and gold come from
the species' attack skill (col 83 -> `'att'`) and `levelgold.txt`; `monsterStatsForLevel`
is only their fallback, though its comment still said the two had "no identified real
table" -- corrected. The others in the fight path are fallbacks too (the own-design skill
catalog's DamageBonus; `session/skill.go`'s level+1 when no table) or enumerated
decisions with their reasons written (skill experience on kill: 42 call sites read; MP
not persisted; the regen percentage kept above the engine's floor of 1). Naming
coverage measured from the index: 15.0% of 34,207 server functions named by leaf; the
self-naming-string levers are spent (one `Class::Method()` leftover,
`FUN_005bb770` = `Party::BroadcastToLocalMember`, named now). No value changed.

## Two-hundred-and-twenty-seventh round: how long a drop lies on the ground -- DecayTime, read and wired per item

The RE tick's step for 2026-09-19 09:49, from the disclosed census: `grounditem.Lifetime`
was a 3-minute own-design value ("the sweep that deletes stale items was not located").

### Read

- `CGItem::Update` asserts a ground item is in life-state 2; `CGObj::Update` (`0x484d10`)
  accumulates the frame delta for a state-2 object at `obj+0x3c` and, once the float at
  `ref+0x18 -> +0x84` is exceeded, fires slot 218 = `SetLifeState(3, 0xff, 0)` -- removal.
  `CGObj::EnterWorld` puts the object into state 2 with the accumulator at zero (slot 226
  -> `SetLifeState(2, 0xff, 0)`; the base setter *adds* its third argument to the
  accumulator, which `FUN_004181d0` exploits by pre-loading the full value to remove an
  object on the spot).
- `+0x84` is field 14 of `RefObjCommon_ExtractData`: nine inline counter bumps, four string
  reads and one schema skip precede its bump; the value is `fild`ed, unsigned-fixed and
  divided by the 1000.0 at `0xb45c68` before `fstp [esi+0x84]` -- **milliseconds in the
  text, seconds in the record.** Field 14 -> text column 13 (`refobj_binary_format.md`'s
  rule, anchored again by field 41 = column 40 = the regen amount). `fields.py` had
  mis-attributed it because it matches `mov` stores only; noted in the doc.
- The player's own table: 10000 for 6,494 of 15,338 rows (gold, potions, weapons, armour),
  180000 for 8,402, 20000 for 383, 1800000 for 55, 3600000 for 1, 1000 for 2.
- Consequence the data forces: an ordinary drop (10 s) vanishes before its 30 s ownership
  window ends. That is the game's rule.

### Wired (v0.1.393)

`DecayTime` is column 52 of the items export (a strict suffix), `refdata.Item.DecayTimeMs`,
`items.decay_time_ms` in PostgreSQL, and `grounditem.Hub.SetDecayLookup`: each drop's
`ExpiresAt` is fixed from its own row at drop time; `FallbackLifetime` (the old 3 min,
still disclosed) applies only to a row with no value. Tests cover both. The public server's
items were re-exported from the user's Media.pk2 and re-imported (15,338 rows); the render
box's `items.csv` for `qa_shot --server` was refreshed. `deploy/README.md` says to re-run the
export when the exporter grows a column.

## Two-hundred-and-twenty-sixth round: the retail sky is fixed at midday -- ENVIRONMENT_REFERENCE_TIME = 0.5 is the client's own value

The RE tick's step for 2026-09-19 09:34, the second and last budgeted on the day/night link,
and it closed the other way round: there is no cycle to reproduce.

- `SWorld` keeps a day/night phase at `+0x26a3`. Its constructor (`Map::FUN_00a2f370`) sets
  it to **0.5** (`_DAT_00e1b7e0`, read from the image) and clears the advance flag.
- `SWorld::vslot_004`, the per-frame update, advances the phase only under that flag:
  `phase += dt * 0.0005` (`_DAT_00de4f88`; `dt` is the seconds frame delta -- clamped to 3.0
  beside a millisecond twin clamped to 3000), wrapping at 1.0 with a 30-day counter -- a
  **2000 s** day, dormant. Nothing in this build sets the flag, and the setter
  `SWorld::vslot_020` has no time-passing caller.
- The environment update `Map::FUN_00a1baf0` evaluates every graph at the RAW phase through
  `FUN_004e55e0` (16-byte keyframes, time at `+0xc` -- the ColorGraph evaluator); the sun
  and its shadow are drawn for `0.25 <= phase <= 0.875`.

So the retail client renders a fixed midday, exactly what srrevamp has done since round 136
as a "flagged simplification". `ENVIRONMENT_REFERENCE_TIME = 0.5` is promoted from
disclosed to read; the day/night TODO closes as not-a-gap; the server's `0x34be` clock is
confirmed to feed nothing in the sky. The dormant machinery (rate, shift, sun angle) is
written down in `docs/protocol/game_clock.md` for the day a live cycle is wanted as our own
design.

## Two-hundred-and-twenty-fifth round: the sky does not read the game clock -- a negative result that reshapes the day/night probe

The RE tick's step for 2026-09-19 09:19, one tick on round 224's open link. Read: the
`S_SetWorldTime` handler (`0x54f6b0`) sets a calendar time on the clock and locks it. Found
by enumeration: nothing outside the clock module reads the clock's fields -- not the
hour/minute, not the synced `time_t`, not the seconds value (one alchemy timer), not the
elapsed counter (UI timers). So the environment sampler is not fed by this clock's fields;
either a value is pushed to it by a call, or `SWorld` runs its own day/night accumulator
with a period of its own. The probe moves to `SWorld`'s update slot
(`docs/protocol/game_clock.md`). No value changed.

## Two-hundred-and-twenty-fourth round: the game clock -- server time every ten minutes, real-time advance, and the four other periodic jobs named

The RE tick's step for 2026-09-19 09:04. Round 223's timer table left four jobs unnamed;
naming them found the clock. Spec: `docs/protocol/game_clock.md`.

- **10 s** (slot 365): `CGStorage::CheckRentalItemValidity`. **30 s** (slot 368): COS-only
  (silk pet / mercenary). **60 s** (slot 366): training-camp accounting (`AQ_TrainingCamp`,
  ops `0x3c86`/`0x3c87`) plus rent items in equip slots. **600 s** (slot 367): the clock.
- The clock: the server packs `GetLocalTime()` into 32 bits (year-16:6, month:4, day:5,
  hour:5, minute:6, second:6) and sends `0x34be`; the client's handler (`0x89a250`,
  registered in the opcode table beside `0x34aa`, `0x34d2`...) unpacks the same fields,
  `mktime`s them, seeds a millisecond clock (ms since the server-local week start) and
  advances it 1:1 with real time (`CGame::vslot_011`, published as seconds via the double
  `0.001` at `0xdd3020`), re-syncing every ten minutes with a 2000 ms drift reset. The scene
  command `S_SetWorldTime` locks it (`+0x931`); the console prints it as `ServerTime`.
- **Not read:** the sky/fog sampler's mapping from that clock onto the environment tables'
  0..1 axis -- its only located readers are the clock's own display and an alchemy timer.
  So no day/night cycle is wired; `ENVIRONMENT_REFERENCE_TIME`'s note, which said "no
  server-side game-time signal", now says the signal is read and names what is not.

No srrevamp value changed. A `0x34be`-shaped sync is an additive op away once the mapping
is read.

## Two-hundred-and-twenty-third round: the PC tick is one second, read -- and it grounds three shipped units at once

The RE tick's step for 2026-09-19 08:49. Round 222 had parked the period of
`CGObjPC::vslot_415`. The repo's own `internal/mana` note held the mechanism (the regen job
is a TIMER registered with a vcall thunk and a `.rdata` interval); following it closes the
question and corrects two earlier rounds. Spec: `docs/protocol/character_state.md`.

### Read

- `CGObjChar::Create` (`0x4a6f40`) registers the character's periodic jobs on a timer
  vector at `this+0x18c` (0x18-byte nodes: elapsed, interval, callback), each callback the
  vcall thunk of a vtable slot. Slot 364 -- the job that calls `controller->slot11(pc)`,
  which is `CGObjPC::vslot_415` -- is registered three times with `fld1` = **1.0**. Beside
  it: slot 362 (regen) 4.0, slot 365 10.0, slot 368 30.0, slot 366 60.0, slot 367 600.0.
- The ticker `GObjPC::FUN_004ab690(dt)` adds dt to each node and fires the callback when
  it reaches the interval; it is called from `CGObjChar::Update(dt)` (slot 211, offset
  `0x34c`) -- the slot the main loop's fixed step `CMainProcess::FUN_00413b30` calls on
  every object, passing `_DAT_00d6a8ec`, the accumulator round 219 showed is in seconds.
- Therefore the intervals are seconds: `vslot_415` runs once per second; the battle
  stance reverts **20 s** after the last blow; berserk's float countdown (advanced 1.0 per
  `vslot_415` call) is **60 s**; regeneration ticks every **4 s**. Three shipped values whose
  unit was labelled "inferred" are read, and their code comments say so now.

### Corrected

Rounds 220 and 222 said slot 364 was dead because nothing referenced `0x4ac6b2`. That is
the thunk's `jmp`; the entry is `0x4ac6b0` (`mov eax,[ecx]` first), referenced three times.
The vcall-thunk search must take the entry. And the "parked" verdict of round 222 was
premature by one grep of the repo: the mechanism was already written down in
`internal/mana/mana.go` -- docs before dump, again.

No numeric value changed (20, 60, 4 were already shipped); labels and specs did.

## Two-hundred-and-twenty-second round: the world keeps its controller at +8; the PC tick's scheduler is parked with its state written down

The RE tick's step for 2026-09-19 08:34, the fifth on the period of `CGObjPC::vslot_415`.
Read: the world's vtable slot 1 stores the controller at `world+8`
(`GObjPC::FUN_005eb2c0`, in the CGameWorld unit), called from the zone-name switch in
`CMainProcess::FUN_005f5b60`; `CGObjPC::vslot_373` is the AsyncQuery completion callback,
not the tick. Not found: any decompiled function that reads `world+8` and calls slot 11 on
it, by any spelling, within five lines -- so the dispatch is not a text pattern.

Parked, deliberately: the unit is already labelled as an inference on the two values it
touches (berserk 60, stance 20), both consistent only with a one-second tick; the answer
would change a label, not a shipped number. The remaining route (a Ghidra data-flow pass
from the `world+8` stores) is written in `docs/protocol/character_state.md`. Five
ticks is the budget this question gets until a value depends on it.

## Two-hundred-and-twenty-first round: "OnTimer_Second" is an ordinal -- the event system is not the PC tick

The RE tick's step for 2026-09-19 08:19, on round 220's probe. A correction and a
narrowing, no value changed (`docs/protocol/character_state.md`, fourth pass):

- The `CEVENTHandler` timer API is read: a handler is constructed, armed with
  `FUN_0063ccc0(ms, ms)`, and registered with `FUN_0063d070(world, ..)`. Every arming call
  in the binary is a script's (10 s, 5 min, 1 h); none is 1000 ms. "OnTimer_Second" names a
  world's second timer, not a per-second event -- round 220's reading of it was wrong.
- `CLobby_RemoveStalePlayers(dt)`, the main loop's other seconds consumer, is only that.
- The load-form scan finds 321 slot-11 call sites, 175 outside quest scripts; a common
  receiver is the global manager at `0xcc387c`, not a controller. The scheduler is one of
  the rest, and the remaining route is a disassembly walk of those sites.

## Two-hundred-and-twentieth round: the PC tick's dispatch, byte-checked -- slot 364 is dead, and the pattern that finds virtual calls in this image

The RE tick's step for 2026-09-19 08:04, still after the period of `CGObjPC::vslot_415`
(rounds 218-219). Not closed. What was established, at the byte level of the server image
(`docs/protocol/character_state.md`, third pass):

- The image encodes virtual calls as `mov r,[r+disp]; call r`; a `call [r+disp]` search
  finds three in seven megabytes. Scanning the load form, the dump and the image agree
  exactly on who reaches the PC update: slot 415 from `vslot_416` and `FUN_00605010`
  only, slot 416 from the siege controller only.
- `CGObjPC::vslot_364`, the one function that calls `controller->slot11(pc)` from a PC
  field, is **dead in this build**: the only `[r+0x5b0]` in the image is its vcall thunk
  (`0x4ac6b2`), referenced by nothing; its entry is referenced only by the vtable.
- The event system carries per-second events (`OnTimer_Second` handlers), which is the
  likeliest live path; its poster is the next probe.

Method notes worth keeping: the vcall-thunk search (`FF A0 <disp32>` in the padding after
a function) and the load-form scan are both in the round's commands; `/var/tmp/infn2.sh`
for two-pattern function greps. No srrevamp value changed.

## Two-hundred-and-nineteenth round: the server's clock is in seconds; the PC tick's scheduler is still one hop away

The RE tick's step for 2026-09-19 07:49, chasing round 218's open unit (the period of
`CGObjPC::vslot_415`, which would ground both berserk's 60 and the stance's 20). Not
closed; what was read is in `docs/protocol/character_state.md`:

- The main loop's delta is in seconds: `const@0xb45c68` divides milliseconds into the delta
  fed to `CMainProcess::FUN_00413840` and multiplies the accumulated delta back into
  milliseconds for `FUN_0041bfa0`, so it is 1000 -- read from two use-sites.
- `FUN_00413840` clamps the delta to 1.0, accumulates it, and fires a fixed step
  (`FUN_00413b30`) at a period kept in `CMainProcess+0x44`, initialised 0 and set at
  runtime (unlocated). That step drives object slots `0x618`/`0x34c`, not `vslot_415`.
- All 578 `CGameWorldLayer` functions were scanned for a slot-11 or slot-415 dispatch:
  none. Controllers' slot 11 is "update this PC" for every world kind.

So the scheduler that calls `controller->slot11(pc)` is the one function left between the
loop and the stance/berserk countdowns. No srrevamp value changed this round.

## Two-hundred-and-eighteenth round: the battle stance lasts 20 ticks -- the server's BattleState timer, read

The RE tick's step for 2026-09-19 07:34. `COMBAT_STANCE_SECONDS` (how long the player
holds `STAND_BATTLE` after combat) had been a disclosed 5.0 since round 132: "the retail
revert timeout was never found". It is the server's, not the client's, and it is read now.

### Read (`docs/protocol/character_state.md`)

- `CGObjPC::SetCharacterState` (`0x4f0ad0`, slot 171) switches on the state type; case 8
  -- the wire's BattleState -- is `GObjPC::FUN_004e2910`, which arms `pc+0x203c = 20`
  when the value is 1, stores the byte at `chardata+0xd`, and announces it (`0x30bf`,
  through `GObjPC::FUN_004a8340`: opcode, object id, type, value). Case 7 is PvP state.
- `CGObjPC::vslot_415` (`0x52aa90`), the PC's periodic update, decrements that counter
  once per call and calls the setter back at zero. Every attack re-arms it. So the stance
  lasts **20 ticks** after the last combat action.
- The same update advances the timed-effect list with `dt = 1.0`
  (`FUN_006560c0(pc+0x1dfc, 1.0f)`) -- the float countdown berserk's 60.0 runs on -- so
  berserk and the stance count in the same unit; the stance is a third of a berserk.

### Not read

The period of `vslot_415`. It is reached via `vslot_416` and `FUN_00605010` behind the
world-context controllers' slot 11; the scheduler that fires those was not located (the
main loop's `CMainProcess::FUN_00414140` has a 1000 ms accumulator, but the link to slot
415 was not traced). A one-second tick is the only reading under which berserk is a
minute; `COMBAT_STANCE_SECONDS = 20` now rests on exactly that inference, labelled the
same way berserk's 60 is -- which replaces a 5.0 that had no relation to the binary.

### srrevamp's gap, named

The original's stance is server-driven and visible to everyone in range; srrevamp's
client holds the pose itself from its own last action, and its server carries no
battle-state byte. Recorded in the spec as the next step for this channel.

## Two-hundred-and-seventeenth round: the teleport list is the client's own, and columns 8/9 have no reader -- a correction and a narrowed probe

The RE tick's step for 2026-09-19 07:23. The teleport row's open probe was "the
server's destination-list builder", on the belief (recorded in `teleport_network.md`)
that the entries `UI_TELEPORT::FUN_006fd3e0` formats were a server reply. They are not.

### Read

- The client builds the destination list from its **own** link records:
  `UI_TELEPORT::FUN_009767b0` counts the current gate's links,
  `GlobalDataManager::FUN_00976a30(k)` selects one, and each becomes a 0x18-byte list
  item numbered `"%d. %s"`. Free vs fee reads the record word at `+0x10` --
  `RefParse_teleportlink`'s third direct field, column 3 -- so the client agrees with the
  server's use-site (`FUN_00513590`) that **column 3 is the fee**: two binaries, neither
  consulted about the other.
- The `entry+6` byte is not a level. It is set only when the gate is `STORE_TOMB_GATE_IN`
  (string at `0xdaddb8`, read from the image with a PE section walk), to the item's
  ordinal, and the item is greyed (`0xff969696`) when the player byte at `+0x20ff` is 0
  or below it. That byte is the SERVER's: the NPC-talk reply handler
  `NetProcessInInterface::FUN_0088b200` stores one payload byte there for
  `STORE_TOMB_GATE_IN`, and reads two for `STORE_DESERT_MERCHANT_HUNTER_GATE` /
  `STORE_DESERT_THIEF_GATE` (`0xdae620` / `0xdae5f0`). The tomb's per-floor gating is a
  per-player count handed over at talk time, keyed by gate name -- not a link column.
- The one level range the client's gate code shows, `UIIT_STT_GOD_LV_EXTENT`
  (`CITeleportGate::vslot_025`: `"%d - %d"` from `+0x2bc/+0x2c0`, class switch on
  `+0x2b4`), is formatted from the gate STRUCTURE's own object record
  (`GlobalDataManager::FUN_0093f5f0` -> `RefData_usableresobjiddata`), not a link.
- Nothing in the dialog or the gate object reads the link's restriction triples.

### What it means

Columns 8/9 have no reader in the server's use handler, the client's dialog, or the
client's gate object. srrevamp does not consume them, so nothing changes in code; the
spec and the SYSTEMS row now say exactly where they were looked for and not found. The
remaining place is the server's link-binding pass (a `CRefTeleport`'s link vector is
filled from `CRefTeleLink` rows; the `_REFTELELINK` binder, `0x82d770`, keeps its column
names in a static descriptor table, so the names are not in the dump). Tool added on the
box: `/var/tmp/infn2.sh <re1> <re2>` lists functions matching BOTH patterns.

## Two-hundred-and-sixteenth round: the warehouse's capacity -- a per-user row, no default in the binary, and the client's own 30-slot pages

The RE tick's step for 2026-09-19 07:00, following round 215's open probe. srrevamp's
warehouse accepted 50 slots because the container inherited the bag's
`SlotsPerCharacter`, while its authored window (`ifstorageroom`) draws 30 cells -- so
slots 30-49 were stored but unreachable. Both halves are read now.

### Read from the server

- The capacity is a per-user row: `DB_Bind__ChestInfo` (`0x8586e0`) names the table
  `_ChestInfo` and its column `ChestSize`; `AQ_CharDataLoader::DoWork` (`0x43d980`)
  loads it by UserJID through the bound query into the character object at `+0x110`.
- A user without the row FAILS to load (`LOADTARGET_CHEST Failed` / `failed to load
  user's chest size [UserJID: %d]`): the binary carries no default. The starting size
  is written by the database's user-creation procedure. That procedure is in no archive
  this project holds -- checked again: the 2.6 GB "complete server files" pack is five
  inner rars of binaries, media, tools and a billing website (its ASP pages call
  `_GetSilkDataForGameServer`/`CGI_WebPurchaseSilk`, nothing that creates a user), no
  `.bak`/`.sql` anywhere.
- The ceiling is the expander's `0x70` = 112 (already `inventory.MaxStorageSlots`).

### Read from the client

- `CIFStorageRoom::Create` (`0x6cc780`) builds exactly `0x1e` = 30 slot controls; the
  move handler (`0x6cd350`) addresses a warehouse slot as `cell + page * 0x1e` -- the
  warehouse is PAGED by 30, the page chosen by the authored `GDR_STORAGE_SPIN_PAGE`.
- `CNIFSpinButtonCtrl` (constructor `0x49d2e0`): the control is backed by
  `store\str_slot_02.ddj`, with `com_left_arrow.ddj` at (0,0) 16x16, the value label
  at (16,4) 18x12, `com_right_arrow.ddj` at (34,0) 16x16; the label shows value+1
  (`0x49d4d0`), and the arrows step within [min,max] (`0x49d580`/`0x49d5c0`).

### What changed

- `inventory.Store` gained `Capacity()`; both stores carry a per-container capacity
  (the bag keeps 50; the warehouse is opened with `storage.DefaultCapacity`).
- `storage.DefaultCapacity = 50` is DISCLOSED in its own comment: kept at what this
  server has enforced so no tester's reach shrinks; `storage.MaxCapacity` = 112.
- The storage list reply carries the capacity as a trailing u16 after the durability
  block (`session.StorageListResult`); an older client stops reading before it.
- The client builds `CIFSpinButtonCtrl` from the constructor's geometry and art, and the
  storage window pages its lattice: `_storage_page`, `ceil(capacity / 30)` pages, a
  withdraw addresses `cell + page * 30`.

### Measured

- `go test`: 56 packages ok, including the list round-trip with and without durability
  entries and against an old payload (capacity 0). Doc guards pass.
- Box: `ALL LOAD` (233 scripts); 76 suites, 0 failing (`storage_test.gd` new).
- End to end (`SRREVAMP_QA_STORAGE_ITEM=1 --server`, the new binary): `warehouse lists 0
  slot(s), 0 item(s); capacity 50 = 2 page(s) of 30` -> `deposit accepted` -> `warehouse
  lists 1 slot(s), 1 item(s); capacity 50 = 2 page(s) of 30`, 0 script errors; the frame
  shows the spin control (arrows, page "1") on the authored strip under the lattice.

### Left open

The storage-expansion item's slot increment (an itemdata param) and the expander path
(`AQ_StorageExpander`, `_STRG_ADD_LINKED_STORAGE`), which would make the capacity grow
as the game's does. A pre-existing note from this run: `hud_window_test.gd` prints
`Compile Error: Identifier not found: NetClient` (hud_panels.gd:379, the shop code,
unchanged) under `remote_godot.sh script`, yet reports `ALL PASS`; the suite runner does
not count "Compile Error" as a failure -- worth tightening.

## Two-hundred-and-fifteenth round: the warehouse is the account's -- the game's own SQL applied, with a lossless migration

The RE tick's step for 2026-09-19 06:30. `docs/SYSTEMS.md` carried "per-account vs
per-character scope" as the storage row's open probe. The fact itself had been read
on 2026-09-16 (`docs/protocol/server_sql.md`): `AQ_CharDataLoader::SelectUsedSlotsForStorage`
(`0x43d2c0`) issues `SELECT SLOT FROM _CHEST WHERE UserJID=%d ...` for the warehouse
against `... FROM _INVENTORY WHERE CharID=%d ...` for the bag and `_GUILDCHEST WHERE
GuildID` for the guild's -- and it was parked because merging per-character warehouses
"could overflow and destroy items". This round closes it.

### What was read this time

The gold side had no citation of its own. `AQ_StorageUpdater::MoveItemWithGold`
(`0x45af70`) calls

```
{?=CALL _UPDATE_USER_N_CHAR_GOLD (%d,%I64d, %d,%I64d)}
```

with `(userJID, user gold, charID, character gold)`: the first id is the player
object's vslot at `+8` and its balance the int64 at player `+0x1ca8`; the second id
is the vslot at `+0x380` and its balance the char-data int64 at `+0x78`. The item
procedures (`_STRG_MOVE_ITEM (%d,%d,%d,%d,%d,%d,%d,0)`) receive both ids plus a move
kind (`+0x28`: 2 = bag to chest, `0x20`/`0x21` = guild chest, 10/11/12 = the gold
moves). So the warehouse's gold is the USER's balance, exactly as its items are.

### What changed in srrevamp

- `inventory.SQLStore` takes an owner column (`OpenSQLStoreOwned`); the bag stays
  `character_id`, the warehouse is `account_storage_slots` keyed by `account_id`.
- `account.StorageGoldStore` (`accounts.storage_gold`) replaces
  `characters.storage_gold` as the stored balance; `storage.Service` resolves the
  acting character to its account and never takes an account id from a caller.
- `storage.MigrateToAccounts` moves the old per-character rows and gold once at boot.
  Lossless by construction: a row keeps its slot when free, else the lowest free
  slot; gold is summed; one transaction; a legacy row is deleted only after its copy
  is written; a `schema_migrations` row makes a second boot a no-op.

### Measured

- Public server before deploy: 1 warehouse row, 0 stored gold, no account with two
  characters holding anything (counted in the database); `pg_dump` taken
  (`~/backups/srrevamp-20260919T065504Z-before-warehouse-per-account.sql.gz`).
- `migrate_test.go` on the real schema: two characters on one account, both with
  slot 0 -> the account holds all four rows (the collision moved to slot 2, the
  others where they were), 500 gold summed, legacy table empty, second run a no-op
  even with a fresh legacy row present.
- `storage_test.go`: what Aria deposits, Bram (same account) lists and withdraws;
  another account's character sees nothing; gold likewise.
- End to end on the box (`SRREVAMP_QA_STORAGE_ITEM=1 --server`, the new binary):
  `warehouse lists 0 slot(s)` -> `deposit accepted` -> `warehouse lists 1 slot(s), 1
  item(s)`, 0 script errors. The client now prints the warehouse's state on every
  list result and on each accepted move, so this is read from the log rather than
  inferred from the absence of a refusal.
- Go: 56 packages ok. Doc guards pass.

### Left unread

The per-user chest CAPACITY (`failed to load user's chest size [UserJID: %d]`):
which column or procedure supplies it and its default. The 112 and 210 caps in
`inventory.go` come from the expansion paths, not from the load.

## Two-hundred-and-fourteenth round: debug lane: a console in the chat line, GM commands behind a gate, and a Help window

"Give me more debug tools to test the client" — after a playtest crash in the
storage deposit that arrived as an impression ("it crashed") rather than a fact.
Testers had F1, F3 (with Copy), `/unstuck`, the log file, and the `SRREVAMP_QA_*`
hooks that only work in render-box runs. Now they have tools that work **in
play**, with every result going to chat and the log.

**All of this is srrevamp's own design.** The original client has no slash
console and no GM console for players; its help and notices went through an
embedded Internet Explorer control (an ifhelp/web-board panel) that Godot has no
equivalent for, and **the original's help dialogs were not recovered** — this
round did not decompile what the ESC Help button opens. What *is* grounded is
the slot: the System window's Help button (`GDR_SYSTEM_BTN_HELP`, text token
`UIIT_STT_HELP`, round 138) and the authored game-guide frame
(`resinfo\ifgameguide.txt`, loaded by `CIFGameGuide::Create` at `0x00765920`
together with `interface\guide\gd_scroll_*.ddj` and the strings
`UIIT_STT_GAMEGUIDE_START_1/2`; its left menu `CIFGGMenu` names
`UIIT_STT_GAMEGUIDE`, `UIIT_STT_QUESTGUIDE2`, `UIIT_STT_GAMEEVENTGUIDE`). The
Help window reuses that frame for its chrome; what sits inside it — a document
list and a RichTextLabel — is ours.

### The chat console (`client/scripts/ui/console.gd`)

Any chat line beginning with `/` goes through `Console.submit`. Client-side:
`/help` (prints the one-line list, and with no argument opens the Help window),
`/where` (zone, region y/x, local and world coordinates, walkable height under
the player), `/log` (the log path; opens the folder on desktop), `/copy` (the F3
payload to the clipboard), `/fps`, `/entities` (monsters / name plates / other
players / ground items), `/wire on|off` (NetClient prints every received
packet's opcode and size — `WIRE recv opcode=0x.... size=N`), `/cam free|orbit`
(`set_camera_view`: free, or the fixed-pitch Quarter Angle view), `/errors` (the
last 20 script-error lines, read back from the session log), plus `/w` and
`/unstuck`, which moved here from `_send_chat`. **An unknown command answers
with the help line, never silence.** The console reaches the world only through
a dictionary of Callables (`World3D._console_host`), so it is tested headless
with recording stubs (`console_test.gd`, 28 checks).

### The GM commands (`server/internal/gm`, `server/internal/session/gm.go`)

ONE additive op pair: `OpGMCommand 0x00F1` (character name, the line as typed,
the selected monster id) and `OpGMCommandResult 0x00F2` (is_gm, refused, text,
optional position/zone, level-up, refresh bits). New commands are new words in
the line, not new opcodes.

The gate is an account-username list: `-gm-accounts` / env
`SRREVAMP_GM_ACCOUNTS` (comma-separated, trimmed, case as stored in
`accounts.username`; default none). The username is stored on the session at
login (`AuthenticatedUsername`; `authenticate` now takes it) because the account
Store has no by-id lookup. A non-GM's command is refused with a chat reply; the
enter-world **probe** (an empty line) is answered silently with `is_gm`, which
is how the client learns whether to show the GM tooltip/section and greet a GM
once. Every command — allowed or refused — is logged server-side with the
account, the character and the line.

The commands call existing store methods only: `/tp <x> <z>` and `/goto
<zone|monster>` reply with a position the client applies (movement is
client-authoritative; the same path `/unstuck` uses; a cross-zone `/goto`
changes zone first and stands at the position when the zone loads); `/give
<item id> [qty]` checks the item table and uses the shop's `AddItem` (the client
resolves an item code to its id from its own itemdata); `/gold <n>`
(`AddGold`/`DeductGold`); `/level <n>` applies the combat path's own level-up
arithmetic (`+leveldata.StatPointsPerLevel` points and
`+character.StatGrowthPerLevel` Str/Int per level, `ResetHP`, mana refill to
`MaxMPFor`), only upwards, capped at the table's max level, refused without a
level table; `/heal` (`ResetHP` + mana refill); `/spawn <monster> [n]`
(`SpawnSpecies` with the roster's own stats — `cmd/server.gmSpecies()`
converts `monsterSpecs` the way `maintainMonster` does — n ≤ 20, 4 units apart,
no respawn); `/kill` (the hub's `ApplyDamage` to zero on the client's selected
monster, `OpMonsterDied` to the rest of the zone; **no exp, gold, drops or
quest credit**); `/durability <slot 0-8> <n>` (`SetDurability`); `/sp <n>`
(`AddSkillPoints`). Own choices, all disclosed in the replies: the spawn cap and
spacing, level-down refused, GM kills pay nothing.

Tests: `gm_test.go` (gate: trimmed/case/empty/nil; every command's effect on
the mem stores; unknown/empty → the help line; missing deps refuse rather than
panic) and `session/gm_test.go` (wire round-trips; the gate over a real socket:
GM probe answered with the help, non-GM probe silent, non-GM command refused
with `is_gm=false`).

### Error capture and the Copy payload

`project.godot` already writes SCRIPT ERRORs to `user://logs/srrevamp.log`
(file logging on, 10 files kept). The F3 Copy payload (`debug_panel.gd
diagnostics()`) now ends with `== script errors (N)` (the last 20 error lines
in the log) and `== last 20 log lines`, so a pasted report carries what a
tester would otherwise have to attach the log for. `/errors` and `/copy` read
the same file.

### The Help window (`client/scripts/ui/help_window.gd`, `md_to_bbcode.gd`)

Opened from ESC → Help (which used to print a controls line), from `/help` with
no arguments, and by `SRREVAMP_QA_HELP=1`. A one-line "Type /help …" hint prints
once on entering the world instead of a popup (the original's login notice was
a web panel; not recovered, so nothing is claimed about it). The window is a
`HudWindow` built from `ifgameguide.txt` (a plain sized panel if an operator's
archive lacks it), with a left `ItemList` of documents and a `RichTextLabel`
fed by `MdToBbcode.convert` — headings, bold/italic, code spans and fences,
bullet/numbered lists, links as plain "text (url)", tables as monospace rows;
brackets escaped one-pass (`md_to_bbcode_test.gd`, 25 checks). The docs are
bundled by `client/tools/bundle_docs.sh`: it copies `docs/DEBUG_TOOLS.md` and
`docs/HELP_PLAYING.md` into `client/docs/` and generates
`client/docs/RELEASE_NOTES.md` from the last 20 `v*` tags (`git tag -n`); the
copies are committed because the release runner's checkout may be shallow, and
the notes file says it is a snapshot. `export_presets.cfg` gained
`include_filter="docs/*.md"` so the PCK ships them; `remote_godot.sh` ships
`client/docs` to the box. The GM section of DEBUG_TOOLS.md sits between
`<!-- gm-only -->` sentinels and is stripped for a non-GM.

### Discoverability

The chat input line and the underbar's menu button carry a tooltip (our
wording) listing the client commands, plus the GM line when `is_gm`. A GM sees
`GM tools: /tp /give /level /spawn /heal /gold /durability /sp /kill /goto --
type /help` once in chat on enter-world.

### Verification

Go: `go build ./... && go vet ./... && go test -count=1 -p 1 ./...` all green
(the `gm` and `session` packages included; `server/README.md`'s guard test sees
the new `-gm-accounts` row). Box: `remote_godot.sh check` → `ALL LOAD` (229
scripts, 5 scenes); `gm_test.gd`, `console_test.gd`, `md_to_bbcode_test.gd` →
`ALL PASS`. Two `--server` renders with `SERVER_BIN=/var/tmp/srv-debug` and
`SRREVAMP_QA_COMMANDS` feeding lines through the same parser as the chat: the
GM run (`SRREVAMP_GM_ACCOUNTS=qa`) and the non-GM run (unset) -- both from the
lane's own client copy (`CLIENT_DIR=/opt/srrevamp-client-debug`; the first two
attempts rendered the default `/opt/srrevamp-client` and proved nothing, which
is the trap to remember: `qa_shot.sh` does `cd "$CLIENT_DIR"`).

GM run, client log (`Console:`/`QA COMMAND:`/`CONSOLE:`/`GM REPLY:` are the
markers):

```
Console: GM probe sent for QaTester
Console: ready (help window authored frame, log .../SRRevamp/logs/srrevamp.log)
GM REPLY: GM: /tp <x> <z>, /goto <zone|monster>, /give <item id> [qty], /gold <n>, /level <n>, /heal, /spawn <monster> [n], /kill, /durability <slot> <n>, /sp <n>
QA HELP: opened the Help window
QA COMMAND: /where          -> CONSOLE: zone: jangan / local: 42.0, 1860.0 / world: 42.0, -30.1, -60.0 / walkable height ...
QA COMMAND: /fps            -> CONSOLE: FPS: 3.0            (a movie-writer run)
QA COMMAND: /entities       -> CONSOLE: monsters 23, npcs (name plates) 95, other players 0, ground items 0
QA COMMAND: /cam orbit      -> CONSOLE: Camera: orbit.
QA COMMAND: /frobnicate     -> CONSOLE: Unknown command /frobnicate. Commands: /help /where ... + the GM tools line
QA COMMAND: /give 3 5       -> GM REPLY: gave 5 x item 3
QA COMMAND: /give 3645 1    -> GM REPLY: gave 1 x item 3645
QA COMMAND: /gold 500       -> GM REPLY: gold now 1500
QA COMMAND: /level 3        -> GM REPLY: level 1 -> 3: +6 stat points (6 unspent), Str 22, Int 22, HP 229, MP 229
QA COMMAND: /heal           -> GM REPLY: healed: HP 229/229, MP 229/229
QA COMMAND: /sp 5           -> GM REPLY: skill points now 5
QA COMMAND: /durability 6 3 -> GM REPLY: slot 6 durability set to 3
QA COMMAND: /spawn MOB_CH_MANGNYANG 2 -> GM REPLY: spawned 2 x Mangyang (level 1, HP 54) at 48, -60 -- ids 25,26; no respawn
QA COMMAND: /tp -300 -880   -> GM REPLY: teleporting to -300.0, -880.0
QA COMMAND: /errors         -> CONSOLE: No script errors logged this session.
QA COMMAND: /copy           -> CONSOLE: Copied the debug report (4253 chars) to the clipboard.
QA COMMAND: /log            -> CONSOLE: Log file: .../srrevamp.log / Opened the log folder.
```

(`/spawn MOB_CH_MANGYANG` in the first pass was refused with the list of real
code names -- the roster spells it `MOB_CH_MANGNYANG` -- which is the "refuses
unknown, lists what it knows" behaviour working. The HUD in frame 150 shows
`Lv 3`, `229 / 229` after `/level 3`: the level-up went through to the stats
packet.) `/heal` did not reach the server in that first pass: `heal` was
missing from the console's forwarded-word list and fell to "unknown command";
fixed, and `console_test.gd` now checks every GM word forwards.

GM run, server log (every command with the account):

```
"GM accounts enabled" accounts=[qa]
"gm command" account=qa character=QaTester line="give 3 5" refused=false reply="gave 5 x item 3"
"gm command" account=qa character=QaTester line="level 3" refused=false reply="level 1 -> 3: ..."
"gm command" account=qa character=QaTester line=heal refused=false reply="healed: HP 229/229, MP 229/229"
"gm command" account=qa character=QaTester line="spawn MOB_CH_MANGNYANG 2" refused=false reply="spawned 2 x Mangyang ..."
"gm command" account=qa character=QaTester line="tp -300 -880" refused=false reply="teleporting to -300.0, -880.0"
```

Non-GM run (gate unset): the probe is silent (no GM line, no GM tools in
`/help`), and

```
QA COMMAND: /give 3 5       -> GM REPLY: GM commands are not enabled for your account.
QA COMMAND: /tp -300 -880   -> GM REPLY: GM commands are not enabled for your account.
QA COMMAND: /help           -> CONSOLE: Commands: /help /where /log /copy /fps /entities /wire on|off /cam free|orbit /errors /unstuck /w <name> <msg>
server: "no GM accounts set (-gm-accounts / SRREVAMP_GM_ACCOUNTS) -- the GM console is off"
server: "gm command refused: not a GM" account=qa character=QaTester line="give 3 5"
server: "gm command refused: not a GM" account=qa character=QaTester line="tp -300 -880"
```

`/where`'s first version printed `region y/x: 0/-1` -- arithmetic on the
world origin, i.e. the cell *relative to the zone centre*, not the real
region. It now finds the loaded `RealTerrain_<x>_<y>` cell whose own space
contains the player (the inverse of `_place_at_region_local`) and reports
that, plus the walkable graph's height and the terrain ray's.

The final short run: `/where` → `region: 97/168 (x/y as in 97\168.m)`, `local:
1002.0, 1020.0`, `walkable height here: -30.12 (graph), terrain ray -43.52,
feet at -30.12`; `/heal` → `healed: HP 200/200, MP 200/200`; `/kill` with
nothing selected → `no target selected -- click a monster first`; `/goto
donwhang` → `travelling to donwhang` and the zone changed.

**Found by the tools, not fixed here (world lane's code):** the zone change
`/goto` triggered prints `SCRIPT ERROR: Trying to assign invalid previously
freed instance. at: _tick_idle_animations (World3D.gd:3406)` 125 times --
`var skeleton: Skeleton3D = entry[0]` assigns the freed node to a typed
variable *before* the `is_instance_valid` check on the next line (commit
115d88b). It is not new: `/var/tmp/potion2.log` on the box, another lane's
run, has the same lines. `/errors` and the F3 Copy payload now show exactly
this kind of thing to a tester.

### Left out (see docs/TODO.md)

- The original's help dialogs and the web panel were not recovered; the Help
  window's interior is ours.
- `/give` by item **code** is resolved client-side only when the code→id map
  is loaded; the server takes numeric ids.
- `/spawn` is not announced to *other* clients until their next monster list.
- The release notes are a committed snapshot; the release workflow does not
  yet regenerate them at build time (needs tags in the runner's checkout).

### Coordinator's addendum (merge)

- The zone-change error the tools surfaced is fixed in the merge: `_tick_idle_animations` now
  tests `is_instance_valid(entry[0])` on the raw Variant before the typed `Skeleton3D`
  assignment (Godot raises on the assignment itself).
- The release workflow now runs `client/tools/bundle_docs.sh` (after `git fetch --tags`) before
  the export, so a shipped client's Help window shows the tagged commit's docs and real release
  notes; `internal/systems/bundled_docs_test.go` keeps the committed `client/docs/` copies
  identical to `docs/`.

## Two-hundred-and-thirteenth round: world lane: the measured pass, and the building trap closed at its cause

Directive: a measured correctness pass over the world — count the faults per region, fix the
systemic ones at their rule, never per object, verify by trace. Run 2026-09-19 on the render box
against the real archives; every number below is from a log, none from a picture.

### 1. The sweep (before)

One boot per zone, radius 1 (nine regions each), `SRREVAMP_QA_FLOAT=400 SRREVAMP_QA_NAVGAP=1`,
`/var/tmp/world_sweep2.sh`:

| zone | regions | archive misses | floats > 12 within 400 | duplicate placements dropped (centre region) |
|---|---|---:|---:|---|
| Jangan town 97/168 @ 1002,1020 | 9 | 2 | 0 | 146 of 544 |
| Jangan palace 98/168 @ 960,830 | 9 | 2 | 0 | 113 of 389 |
| Jangan farmland 96/168 @ 130,360 | 9 | 2 | 0 | 125 of 265 |
| Alexandria 90/48 @ 663,526 | 9 | 0 | 0 | 16 of 106 |
| Hotan 92/135 @ 960,960 | 9 | 0 | 0 | 106 of 405 |
| Constantinople 104/80 @ 960,960 | 9 | 0 | 0 | 208 of 414 |
| Samarkand 106/107 @ 960,960 | 9 | 0 | 0 | 6 of 69 |

- **Misses**: the same two paths in every Jangan-cluster boot, both placed by region 97/169:
  `res\bldg\china\dunhuang\buildings\w_cd_stab_buil03_wal.bsr` and
  `res\artifact\guild\constantinople\fortress_ct_fort_in_gate01.bsr`. Checked with `pk2list`:
  neither `.bsr` exists anywhere in this `Data.pk2` under any folder or case (only their `.bms`
  pieces and lightmaps do). Per-asset gaps in the archive, not a folder or case rule; no fix.
- **Floats**: none at threshold 12 in any zone.
- **Duplicates dropped**: the `.o`/`.o2` exact-repeat merge of round 75, behaving as measured
  then. Not a fault.
- **NAVGAP** is a point probe (AABBs of what is drawn against what the graph offers at one spot)
  and cannot count trap sites; it confirmed the spawn stands on the gate object with two
  offered surfaces (−46.4 terrain, −32.6 deck). The trap needed a different measurement.

### 2. Why a player gets stuck in a building — the actual rule, from the binary

Round 162 diagnosed the Alexandria trap as physics (object trimesh colliders on layer 1 against
the player's mask 17). That is not the live path: with a graph loaded the player moves on
`NavGraph.step` and `move_and_slide` never runs. The trap was in the graph's own rule, and the
real rule was recoverable — the client's navmesh walk is in the decompiled dump. Read this
session: `CRTNavMeshTerrain::vslot_002` (0x4047a0), `RTNavMeshTerrain::FUN_00404060`,
`CRTNavMeshObj::vslot_002` (0x44b500), the entry test `RTNavMeshObj::FUN_0044a790`, the
in-object walk `CRTNavMeshObj::FUN_0044add0`, the deserializer at 0x4489b0, the `GetCell`
selectors off `objdump` (the decompiler dropped them), and the constants off `.rdata`. Written
up in `docs/protocol/NAVMESH_MOVEMENT.md`; the short form:

- A character is either on the terrain or on exactly **one** object, and the client remembers
  which. Nothing is inferred from height.
- From the terrain, an object is entered only by crossing one of its **outline edges with bit 0
  clear** (a doorway — 5.3% of all outline edges, one to three per shop). Bit 0 set is a wall,
  whatever height the floor behind it has. Edges with `0x10` are not tested at all from outside
  (the arch under a city wall).
- On an object only **that object's** edges apply: internal edges directionally (value 1 blocks
  the `cell_to` side, value 2 the `cell_from` side), outline edges as exits (value 2 or `0x10`
  refuse). The terrain's walls and other objects' do not apply — unless the object's collision
  section names an event `"event"`/`"EVENT"` (byte `+0x94`, set at 0x449395/0x4495d9, read at
  0x404c71); those are 59 fortress/dungeon/arena structures, no town object.
- Push 0.01 past a crossed edge and short of a wall (double at 0x00e1b820); slide along walls.

Our rule inferred footing from height: any surface within 12 units up was "the ground", and an
object's walls applied only to someone already on it. So a terrain mover walking at a shop whose
floor sits 5 units up was let through the wall (walls untested for terrain movers), lifted onto
the floor (within reach), and then held by the same walls from inside. That is the Alexandria
shape exactly (terrain 863, floor 868.5), and it is what the weapon shop's walled back yard does
to anyone approaching from the east.

Whole-index measurement (`client/tools/sweep_object_edge_flags.gd`, 2,043 object navmeshes,
62,120 outline + 90,018 internal edges): outline 81.1% flag 3, 11.5% `0x83`, 5.3% flag 0, 0.9%
`0x10`, 0.4% `0x08`; internal 94.2% flag 4, 3.8% flag 7, 25 genuinely one-way. 484 objects
enterable, 1,559 sealed. `cj_weapon` 3 doorways / 31 walls, `cj_armo` 1 / 44, `cj_pal_indoor`
10 / 56, `cj_pal_center_stair` 2 / 6, `cj_s` (city wall) 121 walls + 21 underpass edges.

### 3. The fix

`client/scripts/nav/nav_graph.gd` now walks the move edge by edge with a tracked footing
(`step_tracked(from, motion, standing_on) -> StepResult`): enter through open outline edges,
exit through them, block and slide on walls, directional internal edges, `0x10`, the
`"event"` marker, the 0.01 push, a same-height hand-off across coincident edges (stair head
onto a deck, bridge span to span). `PlacedObject` keeps every edge with its flags, list and
from-side; `surface_at`/`landing_height_at` are unchanged and now only settle footing after a
teleport, a region change or a landing. `World3D._move_on_nav_graph` carries the footing from
frame to frame and re-settles it only when something else moved the player (> 1 unit) or the
graph changed; `QA_WALK`/`SRREVAMP_QA_NAVTRACE` print every doorway, exit and wall as `NAV`
lines, and the QA position line reports the tracked footing.

One disclosed deviation: a terrain mover already inside an outline (after a teleport, or through
a gap) is let out through a wall; the client's entry test has no notion of sides. Chosen against
traps in states the game cannot reach.

Unit tests (`nav_graph_test.gd`, 55 checks, ALL PASS on the box): ramp climb and descent with
tracked footing, wall from both sides, doorway both ways at a 5.5-unit floor, another object's
wall not applying / applying with the event marker, terrain walls not applying on an object,
`0x10` under and on, one-way internal edges, the coincident-edge hand-off, landing on the 13.8
deck. Whole client: `remote_godot.sh check` ALL LOAD.

### 4. Verification by trace, real data

`client/tools/walk_probe.gd` (new, headless, ~10 s): builds a region's real graph and walks it,
printing footing, doorways and walls. Jangan 97/168, weapon shop (object 33):

| walk | result |
|---|---|
| terrain north of the shop, heading local −z | **onto** at z 1542.0 (open edge 9), floor y 4.6–4.7, **off** at z 1404.0 (open edge 10), terrain, no wall |
| on the floor, heading +x | wall at x 57.3 (east wall, flag 3), stopped on the shop |
| terrain east of the walled yard, heading −x | wall at x 220.0, stopped **on the terrain** — the trap case: the old rule lifted the mover into the yard |

Live client (`qa_shot.sh --walk`, NAV lines): from local 240,1470 heading world 270 the player
stopped at 220.0,1470 `on terrain` (yard wall); after the spawn roof-escape relocated a start
onto the shop floor, walking north followed the floor's own cells down from y 4.6 to −0.9 and
stopped at the wall at 47.4,1542.1 `on object cj_weapon`. World heading 270 is local −x and
world 180 is local +z (mirrored z), for anyone aiming a walk from `walk_probe` output.

### 5. Left as found

- `_avoid_spawning_under_roof` still relocates a spawn by render-mesh ceilings and terrain
  rays; twice in these runs it moved a QA start 45–60 units, once onto a shop floor. It does not
  consult the graph. Worth a look, since it can place a player where walking could not.
- Object render-mesh colliders stay on layer 1 (camera, clicks); the player does not use them
  while a graph covers them, so round 162's deferred re-layering is moot rather than done.
- Linked edges (`0x08`) are not followed through the `.nvm` link table; the event gates
  (`0xc0` bits of the wide-record byte) are not read. Both are documented, neither is in a town.
- Lighting: not touched. Round 136's `light()` scaling of sun by diffuse/ambient needs the
  material colours read per object (BMT_FORMAT.md has the layout); no measurement was taken this
  round, so nothing was written.

Proposed tag: `v0.1.3xx — Buildings hold: the client's own navmesh walk (doorways, walls,
underpasses) replaces height-guessed footing; NAV traces; edge-flag survey and walk probe tools.`

## Two-hundred-and-twelfth round: gear wears out, and the smith repairs it -- per-instance durability, built from the reading

Durability was fully READ (durability.md: the creation roll, the max formula,
the loss rolls, the broken rule, the client update, the repair cost) but
srrevamp carried none of it -- every item was indestructible and the shop's
repair buttons were inert. This builds it, every number from the spec's
citations, nothing invented.

### The instance

`internal/durability` is the pure rules, each constant cited to
SR_GameServer.exe: `RollWhiteStatUnit` (the min of three `rand()/32767`
draws), `RollVariance` (twelve 5-bit groups), `MaxDurability`
(`round(Dur_L + v0/31*(Dur_U-Dur_L))`, group 0 / 31), `LossChancePercent`
(`min(2*rate,100)`), the armour walk (slots 0..7 except the weapon, first
success), and `Apply` (clamp, refuse below 0, report the break). 20-case
table test; the min-of-three mean is checked at 0.25 over 100k draws.

An item instance now carries `Variance uint64` and `Durability int`
(`inventory.Slot`, `equipment.Equipped`), rolled once when the item is
created (`inventory.FreshInstance`) and carried unchanged wherever it goes:
equip/unequip, the warehouse, a trade, a ground drop picked up, the shop's
sell-rollback (`AddItemInstance` replaces the re-rolling `AddItem` on every
transfer path). Persisted in both stores (memory and the two SQL containers,
with `ADD COLUMN IF NOT EXISTS` migrations); a row from before this existed
reads `-1` (Untracked) and gets a real instance, once, on first read.

### Consumption

`performAttack` wears gear the way `Combat_ResolveDamage` +
`RollDurabilityLoss` do: a landed blow rolls the weapon (slot 6) once at
rate = hits; the counterattack rolls one armour piece per hit, or the shield
on a block. Every loss is -1 through `durability.Apply`; at 0 the item is
broken, and a broken weapon deals the unarmed damage while broken armour and
a broken shield defend for nothing (the three combat stat sums skip it, which
is how the engine's ParamKeeper removal shows up here). `SRREVAMP_DURABILITY_LOSS_ALWAYS=1`
is a QA accelerant (2%/hit is hundreds of swings otherwise), disclosed.

### Repair

`OpRepair` (0x007a/0x007b): repair one worn slot or all, charging the gold
`repair.Estimate` asks (unit price = itemdata col 28 / max, floor 1.0, cap
100000), restoring durability to max, refusing with the engine's own codes
(0x1c07 not enough money, 0x1c09 nothing to repair). The store window's two
authored buttons -- `GDR_STORE_BTN_REPAIR`, `GDR_STORE_BTN_REPAIRALL`,
read from `ifstore.txt` -- are wired to it.

### On the wire, additively

Inventory, equipment, move and repair results gain a **trailing** durability
block (u16 count, then per slot u32/s32/s32): it rides after the counted
records, so a client built before it stops at the count and never sees it,
while a newer client reads it. Tested: the slot bytes are byte-identical with
or without the block. The client shows real `Durability cur / max` in the
item tooltip (replacing the placeholder `L / L`) and dims a broken item's
icon (the exact original treatment is not recovered; the grey is ours).

### Verified

- `go test -p 1 ./...`: 55 packages ok. New: `internal/durability` (rules),
  `inventory` (fresh roll / instance carry / SetDurability / legacy init),
  `session` (repair over the wire + gold charged + full afterwards, the
  additive-block byte-identity, broken weapon -> unarmed, one-point wear +
  break).
- Live on the render box (`--server`, in-memory, YOUR build): the worn
  weapon rolled max **62**, and each landed hit dropped it 62 -> 61 -> ...
  -> 32 over 31 hits, persisted and logged (`durability lost ... slot=6`).
  A break + damage-drop is covered by the unit test rather than a
  multi-minute drain render.

### Disclosed / not done

- The durability tooltip line is on hover, which an offscreen QA frame does
  not capture; verified by the wire test and the server log, not a picture.
- Single-slot "Repair" falls back to "Repair All" -- there is no per-slot
  selection UI yet.
- The warehouse LIST does not emit the block yet (the instance still
  survives storage; the warehouse tooltip just will not show durability
  until a later pass).
- The broken-icon dim is our grey, not the original's treatment.

**Merged (coordinator).** Re-run on the merged build with every lane's change together: 29 weapon-wear
events (65 -> 37) logged across the run, kills, drops, pick-ups and the attribution log all intact. No
armour wear appeared under `SRREVAMP_DURABILITY_LOSS_ALWAYS`, and that is the engine's own rule showing
through the accelerant: `RollDurabilityLoss` stops at the FIRST slot whose roll passes even when that
slot is empty, so a helmet-less character's slot 0 absorbs every forced roll; at the real 2% the empty
slot merely wastes a roll, as it does in the game. Armour and shield wear are covered by the unit tests.

## Two-hundred-and-eleventh round: the character window says what the server knows -- and Phy. atk had been a roll

The UI note said thirteen rows stayed blank "because nothing on this server computes
them". By tonight the server had level, Str/Int with growth, HP/MP from the grounded
formulas, EXP on the real curve, stat points and both attack ranges -- the note was
stale and the panel was showing a single number where the client shows a range, and
that number was a fresh random roll on every open (`attackerDamage` returns
`rollDamage(min, max)`).

### The authored panel, dumped (`ifplayerinfo.txt`, 73 controls)

Value fields are the `_DAT` -- or `2` -- siblings of their labels: `TEXT_CURXP` is the
label at (32, 41) and `TEXT_CURXP2` at (96, 41) the value, likewise `NEXTXP/NEXTXP2`
and `STAT/STAT2`; `HONOR_DATA`; `STRENGTH_DAT`/`INTELLECT_DAT` with `BTN_ADDHP` (62, 109)
and `BTN_ADDMP` (62, 138) beside them -- the stat-point buttons, named for what a point
raises; `HP_DAT`/`MP_DAT` over `GAUGE_HPGAUGE`/`MPGAUGE` (`chr_hp.ddj`/`chr_mp.ddj`,
188x12); the eight combat `_DAT`s; the three job rows with grade, title, exp text and a
gauge each; `TEXT_LEVEL` across the top. The old code filled the label `TEXT_CURXP`
(no such value there) and never touched `CURXP2`.

### What the client itself does with them (`CIFPlayerInfo::vslot_012`, `0x006b8910`)

Its refresh formats `L"%d ~ %d"` for the two attack rows, `L"%d / %d"` for HP and MP
from the character block, `L"%I64d"` twice for the exp pair -- so Current/Next Exp.
are **absolute integers**, not percentages -- `L"%d"` for the plain rows, `L"%d %%"` for
the two balance rows and `L"%d%% (%d)"` for a job row, and builds the title from
`UIIT_STT_LV_LEVEL` and the level byte (`DAT_00eef5ec+0x21a`). The balance value is
`FUN_009d4d70`, a getter of a stored byte at `CICPlayer+0x20d8`, copied from `+0x868`
by `FUN_009d4d50`; where that comes from was not chased -- which is why those two rows
stay blank rather than get a formula.

### Wire and server

`CharacterStatsResult` grows an additive 28-byte tail (84 body bytes): `Str, Int,
StatPoints, PhysAttackMin, MagAttackMin, MagAttackMax, MagDefense`; a 56-byte result
still decodes with them 0 (`TestCharacterStatsResultCarriesCharacterRows`). The
builder is one function now (`buildCharacterStats`), the ranges come from
`combat.WeaponRange` for both attack types (`weaponRanges`: unarmed = the unarmed
damage, magical 0), `PhysAttack` is the range's TOP instead of a roll, and
`MagDefense` is the same armour sum as `PhysDefense` over the magical column.

New `OpSpendStatPoints 0x00F0` (name, u8 str, u8 int) applies
`GObjPC_SpendStatPoints`' rule (`0x00511470`: refused unless `s+i <= pool`, then
`Str += s`, `Int += i`, pool down by the sum; the same increment `GObjPC_SetLevel`
spends two of its five points through) via `SetLeveling`, and answers with the
refreshed stats result. `TestSpendStatPointsFollowsTheEngineRule` pins it: 4 of 3
refused untouched, 0 refused, 3 of 3 gives 23/22/0 with MaxHP = MaxHPFor(23, 2).

### Client

`HudPanels._fill_character_window` fills the rows listed in its header and wires the
two buttons once (`disabled` while the pool is empty); the title is the server's level
once its stats have arrived (World3D had been passing a placeholder 1, so the window
said "Lv 1" forever); HP/MP drive the authored gauges. `SRREVAMP_QA_SPEND_STAT=1`
presses the Str button once as soon as there is a point.

### Measured (render box, in-memory server from this branch, `--panels character --attack`, fast)

Log lines, each the server's own numbers:

    Lv 1 | exp 0 / next 118 | stat points 0 | str 20 int 20 | hp 126/200 mp 200/200 | phy 21~23 def 5 | mag 35~40 def 12
    Lv 1 | exp 97 / next 118 | ...                                        (four kills, 24 exp each)
    Lv 2 | exp 3 / next 470 | stat points 3 | str 21 int 21 | hp 214/214 mp 214/214 | phy 21~23 | mag 36~40
    spending 1 stat point(s) on Str
    Lv 2 | exp 3 / next 470 | stat points 2 | str 22 int 21 | hp 214/224 | phy 22~24 | mag 36~40

Str 21 -> 22, pool 3 -> 2, MaxHP 214 -> 224 (= 22 x 10 x 1.02), the physical range up
one at both ends (the Str reinforce), and the magical minimum 35 -> 36 at the
level-up (the Int reinforce) -- the arithmetic `WeaponRange` and `MaxHPFor` predict.
The frame (`scratchpad/charwin/charwin_440.png`) shows the same numbers in the
authored rows; the underbar's EXP 9.36% is 44/470. No layout was changed, so no
pixel comparison was made; `docs/reference/ui` carries no character reference image.

### Out of this lane, noted

The run's client log has `ObjectLoader: item\etc\drop_ch_money_large.bsr not found in
archive` (x8) and `drop_ch_bag.bsr` (x7): the ground items' drop models do not resolve
in this archive by that path -- the drops lane's, and the parent should look.

## Two-hundred-and-tenth round: items carry their names everywhere -- the plates resolved through the wrong table

"HP ?? ??" on a dropped potion's plate and "Looted 2x item #4" in the chat had
one cause each, and neither was the font.

**Measured against the archive (2026-09-19).** Item 4 is `ITEM_ETC_HP_POTION_01`
(the "item #4"). Its `itemdata_5000.txt` row, read out of the user's own
Media.pk2: column 3 is *literally* `HP ?? ??` -- the Korean was mangled to
question marks in the file itself, upstream of this project -- and column 5 is
`SN_ITEM_ETC_HP_POTION_01`. That key resolves in `textdata_object.txt` (one
3.5 MB file, not sharded): 16 columns, 0-based column 7 `0`, column 8
`HP Recovery Herb` -- the shape `UiTextTable`'s column rule already handles.
`textdata_object.txt` carries **9,315** `SN_ITEM_` keys; `textuisystem.txt`,
the UI-string catalog, carries **0**.

**The cause.** `World3D._item_display_name` -- the resolver the ground plates
were given -- called `display_name(_ui_text_table)`, and `_ui_text_table` is
`textuisystem.txt`. Nothing could ever resolve through it, so every name fell
to column 3, which for consumables is the mangled Korean. The HUD's tooltips
and buy/sell prompts resolve through their own parse of `textdata_object.txt`
(`_object_names` in HudPanels), which is why the same potion's tooltip read
correctly all along. The chat lines never resolved at all: `Looted %dx item
#%d`, the pick-up print, the trade summary and the three dev lists printed ids.

**What changed.**
- `ItemTableReader.Item.display_name` still resolves the `SN_` key through the
  table it is given, but falls back to column 3 **only when that text reads as
  English** (new `reads_as_english`: printable ASCII, at least one letter, no
  `?`); otherwise "". A player sees the client's own name or nothing -- never an
  id, never a row of question marks. A weapon's English column 3 still stands
  in when the key is unknown (Copper Sword).
- `World3D._object_names()` hands out the one parsed `textdata_object.txt`,
  sharing the variable the monster-model loader already filled
  (`_object_name_table`), so the 3.5 MB file is parsed once, not per caller.
  `_item_display_name` uses it. `_item_label_for_line` is the chat/log variant:
  display name, else the item's own code name (a fact from the table, English),
  else nothing -- the code name is for lines, never plates.
- Routed: the ground-item plate (`GroundItems.label_text`, which now omits the
  plate entirely when there is no name rather than showing an id), the pick-up
  result (now also a chat line, `Picked up 2x HP Recovery Herb.` -- the line
  itself is ours, the name is the client's), `Looted`, the trade summary, and
  the inventory/equipment/shop dev lists.
- Test: `item_table_reader_test.gd` gains the real shapes -- the potion row
  resolving through an object-table fixture, showing nothing through a
  UI-catalog fixture and with no table, the weapon's English column 3 standing
  in, and `reads_as_english` on English / `HP ?? ??` / Hangul / digits / blank.

**Verified.** `remote_godot.sh check`: 222 scripts ALL LOAD; the item test ALL
PASS. In-world (`--server`, in-memory server, Mangyang spawn, fast attacks,
`SRREVAMP_QA_PICKUP=1`): `ground item 2 (HP Recovery Herb x2) at ...`,
`picked up 2x HP Recovery Herb (ground item 2, item 4)`, `QA PICKUP: result 0
-> 2x HP Recovery Herb`, repeated for items 4 and 6; the frame shows the chat
lines "Picked up 52 gold." / "Picked up 2x HP Recovery Herb." and the plates
over the pile.

**Disclosed.** The `Picked up …` / `Looted …` wording is ours (the client's own
acquire message was not looked up); the English-ness test is our rule for when
column 3 may stand in. Not touched: the tooltip's durability line, the store's
repair controls, the character window, click/cursor/target code.

## Two-hundred-and-ninth round: the skill window was right and silent -- Bicheon's first skill needs mastery 5, and now it says so

**The report.** A level-3 fighter with Bicheon 3 and 9 SP: "leveling up my Bicheon
but it's not giving me skills to add; the UI looks broken and maybe assumed", with
a screenshot of the window -- rows of grey cells, three "up arrows" at the end of
each row, LEVEL UP dimmed.

**What the data says (the user's own skilldata export, `skills.csv` from
Media.pk2, fields 22/23/19 = raw cols 34/36/46).** Bicheon (mastery 257) has no
level-1 skill below mastery **5**: `SKILL_CH_SWORD_SMASH_A_01` (id 3, group 174)
needs Bicheon 5 and 2 SP; `CHAIN_A` 7; `SHIELD_A` and `PASSIVE_A` 10; `GEOMGI_A`
14; `KNOCKDOWN_A` / `DOWNATTACK_A` 19. Only `SKILL_CH_SWORD_BASE_01` (the basic
swing) needs 0. So at Bicheon 3 there is genuinely nothing to learn.

**Why Bicheon could not be raised to 5.** A mastery cannot pass the character's
level: `Mastery_LevelUp` (`0x0059c4e0`) refuses with `0x3804` when
`characterLevel < currentMasteryLevel + levelsRequested` (already cited in
`session/skill.go`). Character level 3 -> Bicheon caps at 3 -> the first skill
is out of reach until character level 5. Both rules are the game's; the server
applies both; the client showed both correctly -- LEVEL UP disabled with its
reason in a tooltip, every cell locked with its requirement in a tooltip.

**The "up arrows".** `interface\skill\skl_mastery_nothing.ddj` is a 32x32 dark
cell with an embossed diamond -- dumped with `tools/dump_ddj.gd` and looked at.
At window scale the diamond reads as an arrow. It is the empty-column padding
`CIFSkillGroup::SetGroup` draws up to eight columns (recovered earlier from the
decompile), so a row shows `8 - skills` of them. Bicheon's rows hold
5/7/6/5/5/5/4/5/3 skills (logged by the client), hence three pads on the
five-skill rows the screenshot showed, one on the chain row, two on the shield
row. The coloured icon at each row's left is the group's pack icon
(`skillgroup\china\pack_sword_*.ddj` at 6,8), not a skill cell.

**What was actually wrong: two things the window did not say.**
1. Skill names never resolved. They live in
   `server_dep\silkroad\textdata\textdata_equip&skill.txt`, which nothing
   loaded, so tooltips showed `SN_SKILL_CH_SWORD_SMASH_A`. It is loaded now
   beside the skill catalogue; the pserver client's English for that skill is
   **"Strike Smash"**, with its authored description.
2. A locked cell's tooltip gave the cost but not the gap. It now reads, from the
   same real numbers: `Learn Lv 1: Bicheon Lv 5 required (yours: Lv 3)`,
   `Skill point needed: 2` (the client's own `UIIT_STT_NEED_SP`), and -- when the
   requirement is above the character's level -- `A mastery cannot pass your
   character level (Lv 3). Reach character level 5, then raise Bicheon to Lv 5.`

**Verified.** `SRREVAMP_QA_SKILL_STATE="sp=9,level=3,257=3"` (new; sets points,
character level and mastery levels for a render without a server) reproduces
the user's window: `Bicheon Lv 3, 9 SP, char Lv 3, total 3/9 -> LEVEL UP
disabled: at your character-level cap (Lv 3)`; first cell
`SKILL_CH_SWORD_SMASH_A_01 learned=0 available=false` with the tooltip above.
Server side, `TestLearnGateOnTheRealFirstBicheonSkill` drives
`LearnSkillHandler` with the real row: refused at Bicheon 3 with 9 SP ("mastery
level too low"), refused at Bicheon 5 with 1 SP, learned at Bicheon 5 for
exactly 2. 222 scripts load on the box.

**Not changed, on purpose.** The grey books, the pads and the tooltip-only
explanations are what the real client does; nothing was drawn that its layout
does not have. **Disclosed:** the two explanation sentences are ours (the
client has no string for the character-level cap in `textuisystem.txt`); the
requirement numbers and the SP label are not.

## Two-hundred-and-eighth round: the blow lands on the monster it was aimed at -- results name their monster

### The report, and what it could not have been

"I think I just watched one Mangyang kill another Mangyang" -- on the public
server, v0.1.381. Server-side that cannot happen: the only damage paths are the
player's attack and the monster's counterattack on that same player
(`performAttack`), `internal/ai` is a state-machine spec that applies nothing,
`internal/world` applies no damage, and the server log for that window shows
exactly one session online. So the death was real (the player's own kill) and
the *attribution* was the client's.

### The cause, read in the client

`_on_attack_result` schedules the monster's hit reaction, its floating damage,
the skill hit effect and the monster's counter-swing `lands_after` seconds later
(the swing's own hit event), and every one of them looked up
**`_last_attack_target` at callback time** -- deliberately, per its comment,
"so a monster that died in the meantime keeps its die animation". A retarget
between the swing and its landing (a click, or the QA loop) therefore made the
*new* target flinch, take the number and swing back while the *old* one, whose
death arrived by the list sync, fell over. That is one Mangyang appearing to
kill another. `_on_monster_damaged` -- the zone broadcast the attacker also
receives -- mirrored the mistake: it played an immediate reaction on any monster
that was not the *current* target, so after a retarget the real victim would
have flinched twice.

The wire carried nothing to pin it: `AttackResult` had no monster id, though
the request did.

### The fix

- **Wire.** `AttackResult` gains `MonsterID int64`, appended after the three
  flag bytes (offset 34 after the error string, 42 bytes total). The decoder
  reads it only when present, so an older server's 34-byte result still decodes
  with `MonsterID 0`, and an older client stops at 34 and ignores it.
  `performAttack` fills it for the plain attack and the skill cast (both reuse
  the type), the "target not found" / "damage calculation failed" refusals name
  it too, and the no-combat skill reply carries the requested target.
  `TestAttackResultCarriesMonsterID` round-trips it and decodes a truncated
  (old-server) payload.
- **Client fallback.** `NetClient` keeps `_attack_targets_in_flight`: every
  `attack()` / `use_skill()` that actually went out pushes its target, every
  `OpAttackResult` pops the oldest, and a result whose `monster_id` is 0 (a
  server that predates the field) takes the popped id. Cleared on connect and
  disconnect.
- **Attribution.** `_on_attack_result` pins the hit reaction, the number, the
  effect and the counter-swing to the result's monster; a blow that killed
  plays no hit reaction (the die animation comes from the list sync). The
  result handler marks `_own_hit_until[monster]` for `lands_after + 750 ms`,
  and `_on_monster_damaged` skips its immediate reaction for a marked monster
  instead of comparing against the live target.
- **QA.** `SRREVAMP_QA_ATTACK_ALTERNATE=1` makes the attack loop swing at the
  nearest and second-nearest monster in turn, and the deferred callbacks log
  `blow lands on monster X (now targeting Y) -- animating X` whenever the live
  target has moved on.

### Measured

Render box, in-memory server built from this branch, Jangan farmland (`97\168`
at local 130,2280), fast attacks alternating between Mangyangs. Twenty-nine
deferred callbacks fired with the live target already on another monster --
`blow lands on monster 14 (now targeting 8) -- animating 14`, `counter-swing by
monster 14 (now targeting 8) -- animating 14`, `... 8 (now targeting 14) ... 8`,
and so on through monsters 17, 20, 25, 26, 27, 28, 29 -- and in every one the
animated id equals the result's monster. Under the previous code each of those
lines would have animated the "now targeting" id. Six kills in the run, each
followed by its gold and potion on the ground at the right corpse. `check`: 222
scripts load; Go: 54 packages ok.

### Not verified

The user's exact click sequence on the public server (no recording exists);
the reproduction is the same race driven by the QA loop. Nothing about the
server's combat resolution changed.

## Two-hundred-and-seventh round: a kill leaves its gold and loot on the ground, picked up by the engine's own rules

The user: "items don't drop on the ground when it dies." They did not drop at
all -- the kill dropped straight into the killer's bag (`OpLootDropped`), and on
the public server `monster_drops` is empty so nothing dropped even there. The
real game leaves items on the ground as objects the killer walks to and picks
up. Built that.

### What the engine does, read from SR_GameServer.exe

A dropped stack is a `CGItem` (`CGItem : CGObj : IGObj : CBase`), in world
state 2 ("on the ground"), its fields recovered from the constructor
(`CGItem::vslot_000`, `0x0048f8a0`) and `CGItem::Update` (`0x0048f9b0`):

- **Pick permission** is the `IGObj::CanPick` virtual, vtable **slot 53**
  (named by the engine's own `"## Illegal ##  IGObj::CanPick Entered!"` stub at
  `0x0057df40`). A ground item answers yes; picking a non-pickable object is
  refused `0x1839`.
- **The pick itself** is `GObjPC::CheckCanPickUp` (`0x004a9050`), reached via
  `CGObjPC::vslot_387`. It reads the item's owner at `+0x150` and busy flag at
  `+0x14c`, and takes a **range** as an argument: the player path passes
  `.rdata 0xb45b44 = 10.0`, the pet path `0xb462b4 = 2000.0`. Beyond range it
  sets result **4**; someone else's item inside the window is **0x1812**; an
  item already being picked is **0x1813**; the distance is the plain 3-D
  `sqrt(dx²+dy²+dz²)` of `FUN_00405270`.
- **The ownership window** is in `CGItem::Update`: the elapsed-time field at
  `+0x158` accumulates the frame delta and is compared against
  `.rdata 0xb45e58 = 30.0` seconds, then `GObjPC::FUN_004901c0` clears the owner
  (`+0x150 = 0`) and broadcasts `0x304D`. Inside it, only the owner (and, from
  `CheckCanPickUp`'s tail, a same-party member when the party shares items,
  `FUN_004ea200() & 2`) may pick.
- **The lifetime** before an unclaimed item vanishes was NOT found: `CGItem::
  DoJob` (`0x00491750`) is an assert stub and no per-item despawn sweep turned
  up. So it is own design, disclosed: 3 minutes.

Six names added to `recovered_names.tsv` would duplicate the coordinator's file;
they are cited inline in `internal/grounditem/grounditem.go` and
`docs/protocol/ground_items.md` (new) instead.

### Built

- **`internal/grounditem`** -- the ground-item hub with those rules
  (`PickRange` 10, `OwnershipWindow` 30 s, the refusal codes, `Lifetime` 3 min
  own design). Unit-tested: range at exactly 10 units, the 30 s window and the
  one-shot ownership release, a party member picking a shared drop, the busy
  flag, and expiry.
- **Server wire** (additive, `session/grounditem.go`): `OpGroundItemList
  0x006a`/`Result 0x006b`; `OpGroundItemSpawned 0x006c`, `Removed 0x006d`,
  `OwnerReleased 0x006e` broadcast to the zone; `OpPickUp 0x006f`/`Result
  0x0079`. `performAttack` (plain attack AND skill kill) drops the kill's gold
  as the pile the engine spawns (`ITEM_ETC_GOLD_03`, id 3, picked up as gold)
  and `combat.LootTables`' rolls as ground items within 2 units of the corpse
  (scatter own design), owned by the killer; a 1 s sweep releases windows and
  expires stale items. **The drop CONTENT is still the placeholder table** --
  the real per-monster drop tables are DB-only and in no reachable archive
  (RE_COMPLETION "Loot is DB-only, censused"); this changes where a drop goes,
  not what drops. `OpLootDropped` is no longer sent (a hub is always wired in
  `main.go`); the `nil`-hub path keeps it for the existing tests.
- **Client**: `GroundItemsNet` (decoders), `NetClient` signals/senders, and a
  `GroundItems` node that draws each stack with its `drop_model_path` model out
  of Data.pk2, a name plate, and a layer-7 click collider. `_try_pick_up_item`
  ray-tests that layer, asks the server, and walks to the item so the arrival
  re-asks if out of reach.

### Verified by measurement (render box, in-memory server, Jangan farmland)

Killing Mangyangs: two ground items spawn within the 2-unit scatter of the
corpse, owner = the killer; the list returns them; a pick from 50 units is
refused with server code 4 and the logged distance; stepping on and picking
returns code 0, puts "49 gold" on the character and the potion (id 4, x2) in
the bag, and broadcasts the removal -- zero refusals in range. Frame:
`scratchpad/drops/f00000149.png` (a drop on the grass at the fighter's feet,
target window up, EXP climbing). The full Go suite is green on a private test
DB; the shared `srrevamp_test` is clobbered by the other lanes running
concurrently.

### For the coordinator

Add the pick-up to `_unhandled_input`'s left-click chain, before the attack:
`if not _try_pick_up_item(p) and not _try_talk_to_npc(p) and not
_try_attack_monster(p): _try_set_move_target(p)`.

### Open / disclosed

- Drop **content** is the placeholder table (real drop tables unavailable).
- The unclaimed-item **lifetime** (3 min) is own design.
- The **drop scatter** (2 units) is own design; the engine's spread was not read.
- The item **name plate** for non-gold drops shows raw text -- item-name
  resolution is the tooltip lane's, not touched here.
- The server measures range in the horizontal plane only at the call site
  (monsters/drops sit at a placeholder y=0 while clients report real terrain
  height); the `internal/grounditem` rule is the engine's full 3-D distance.

**Merged (coordinator).** `_try_pick_up_item` now heads the left-click chain (item -> monster -> NPC ->
ground: a drop lies inside its killer's next target's tall click capsule, so the item must test first).
Re-run on the merged build with the three lanes' `combat.go` changes together: two kills, each leaving a
gold pile and a potion at the corpse owned by the killer, `picked up 40 gold (ground item 1)`, result 0.

## Two-hundred-and-sixth round: a monster click was already an attack -- the dispatch order fixed, and the client's own cursors from sro_client.exe

The report was "clicking a monster opens the NPC talk window, and there is
no sword cursor over anything attackable". Both were measured before
anything was changed.

**The click, measured.** A new hook, `SRREVAMP_QA_CLICK="monster,npc,ground"`,
stands the player 40 units in front of the nearest target of each kind,
aims the camera, projects the target's middle to the screen and puts that
point through the real left-click path -- after first firing both click rays
at it side-effect-free and printing what each hit (collider path, layer
bits, the tag found walking up). Against the box's in-memory server and
against the public server (`192.168.5.25:15779`), the answer was the same:

```
QA CLICK monster: 'Yeoha' -> screen (480, 251)
   probe npc     layer 0b10000:  no hit
   probe monster layer 0b100000: .../OtherEntities/@Node3D@2686/ClickBody -> monster_id=20
   dispatched -> attack
QA CLICK npc: 'Storage-Keeper' -> probe npc: .../RealTerrain_97_168/Npc_2014_5/Body -> npc_name=...
   dispatched -> talk
QA CLICK ground: dispatched -> walk
```

So a monster's colliders are on the monster layer only (`0b100000`), carry a
`monster_id` and no `npc_name`, and the NPC-layer ray does not see them: the
talk window **cannot** open from a monster click in either environment. The
public server's Mangyangs report `54/54` HP -- the grounded characterdata
value -- so monster HP is not wrong either.

What was wrong in principle: the dispatcher ran `_try_talk_to_npc` first, on
`NPC_COLLISION_LAYER`, which is the navmesh **wall** layer, so an NPC body in
line behind a monster would have taken the click. The order is now monster,
NPC, walk (`_dispatch_left_click`, one function for the real click and the
hook), which is also how the client's own hover code treats the object under
the mouse -- it classifies what the pick returns, never wall-first. Read
honestly, the user's "it shows up as an NPC to talk to" is most likely the
**target window** opening on the click (its bar is broken -- another lane),
with no cursor change to say "attack" and, on a server with no item refdata,
placeholder 1-damage hits that leave the bar at 100%. That is an inference
from the measurement; the measurement itself is the fact.

**The cursors, from the client.** `Media.pk2` holds one cursor file
(`cursor\cursor_normal1.tga`); the other archives none. The client hides the
OS cursor (`SetCursor(NULL)`, three sites) and sets Win32 *resource* cursors
by id: `FUN_00ba6260` is `SetCursorResource(id)` --
`LoadCursorA(hInstance, MAKEINTRESOURCE(id))` -- fed by `FUN_00777ec0`
(`SetHoverCursor`) and `FUN_00777e70` (a forced cursor, -1 restores). The
mouse-move handler `CGInterface::vslot_005` (`0x00789820`) picks the object
under the mouse and switches on its class -- the classes recovered from the
type-id objects each class's `vslot_000` returns:

| class under the mouse | cursor id |
|---|---|
| nothing / friendly | `0x95` (arrow, hotspot 2,1) |
| `CICMonster`, `CICMonsterNPC`, `CICATStruct`; `CICUser` / `CICGuard` when the relation is `0xca`/`0xcc` | `0x97` attack |
| `CICNPC` | `0x98` talk (hotspot 2,26) |
| `CIItem` (on the ground) | `0x99` pick up (`0x9a` with a modifier) |
| `CITeleportGate` | `0xa1` |
| `CICUser` / `CICCos` with Alt held | `0xa0` |

`sro_client.exe` carries them as RT_GROUP_CURSOR groups over RT_CURSOR
images: 17 groups, ids `0x95..0xaf`, every one a 32x32 8-bit DIB plus AND
mask with a real hotspot (the first two WORDs of the RT_CURSOR data -- the
2220-byte size is exactly 4 + 40 + 1024 palette + 1024 XOR + 128 AND).

`client/scripts/ui/cursor_set.gd` reads them at runtime from the exe beside
the archives (`Data.pk2`'s folder holds `sro_client.exe` in every install):
PE header -> `.rsrc` -> the two resource types -> group -> image -> RGBA with
the AND bit as transparency. Nothing is extracted or shipped; a missing exe
leaves the system arrow and says so once. `World3D` classifies the hover with
the same two rays the click uses (monster -> attack, NPC -> talk, else
arrow), settled once a frame after GUI routing so a window always shows the
arrow (4.2 has no `gui_get_hovered_control`; the first draft used it, the
load check passed, and the call failed at runtime -- the project's own trap,
caught by the hook's log). The pick-up and gate kinds are wired to their ids
for the lanes that add ground items and gates.

**Verified.** `cursor_set_test.gd` decodes a hand-built 4x2 8-bit cursor
(palette, bottom-up rows, AND mask, hotspot) -- 14 checks pass. On the box,
`CursorSet: 16 cursor group(s) read from sro_client.exe` (the odd named
group is skipped), and the hook logs `kind=attack id=0x97 hotspot=(2, 1)` at
the monster click, `kind=talk id=0x98 hotspot=(2, 26)` at the NPC, `normal
0x95` at the ground. The frames show the decoded art as a QA swatch drawn at
the click point -- the golden sword over the Yeoha, the "..." bubble over
the storage keeper -- because offscreen frames never contain the OS cursor;
that is a swatch of the texture, not the cursor itself.

**Disclosed.** The hotspots are the files' own. The hover is throttled to
one classification per 50 ms (ours). The public-server run created a
`QaTester` character there. The box's `skills.csv` beside the archives did
not parse with the box's Sep-14 server binary ("wrong number of fields");
this lane ran with only `leveldata.csv` -- for the data lane.

## Two-hundred-and-fifth round: the target window from its own layout -- the 4 px gauge in the 196x51 piece, not a red block

The report: "the healthbar for it is a fuggin mess". The screenshot showed the
frame with a fat red rectangle and a "100%" label sitting under it. That
window was `World3D._build_target_window`: `interface\targetwindow\tw_type1.ddj`
(200x72) stretched to 320x115, and a `ColorRect` plus a percent `Label` at
rects "eyeballed from the art and tuned by rendering" -- its own comment said
so. None of it was the client's.

**What the archive authors** (`tools/dump_layout.gd`, `list_archive_dir.gd`):

- `ginterface.txt` registers `GDR_TARGETWINDOW` (`CIFTargetWindow`) at
  **(442, 10)**, rect 10x10 -- "the art's own size".
- `iftargetwindowex.txt` is the container: a 16x16 close button at (176, 9)
  and one sub-window per target kind, each an atlas piece of
  `interface\ifcommon\window_all.ddj` at its own size -- `GDR_TW_COMMONENEMY`
  **196x51** at uv (0.5303, 0)..(0.7217, 0.0996) = pixels (543, 0) on the
  1024x512 sheet, `GDR_TW_SPECIALMOBWND` 196x78, `_PLAYERWND` 196x36,
  `_JOB_PLAYERWND` 196x58. The older `iftargetwindow.txt` lists the same
  pieces plus 236-wide twins, a buff viewer and a fortress window; both agree
  on the common-enemy piece. So the frame is that piece, not `tw_type1.ddj`
  (which nothing in either layout names; the `tw_type1..4` frames stay
  unaccounted for).
- `iftw_commonenemy.txt`, a normal monster's inside, is three controls: the
  gem `GDR_TWCE_GEM` at **(8, 5) 20x20**, the HP gauge
  `GDR_TWCE_GAUGE_HPGAUGE` (`CIFGauge`, `interface\targetwindow\tw_hp.ddj`) at
  **(14, 37) 168x4**, and the name `GDR_TWCE_TEXT_ID` at (34, 10) 137x12,
  centred, font index 0. **No level text and no rank icon.** Those are the
  special-mob layout's (`iftw_specialmob.txt`: `_LEVEL` (10, 56) 30x16, the
  rank icon `_ICON` (65, 54) 16x16, `_TEXT_LEV` (85, 56) 168x12, plus the
  same gem, gauge and name).
- `interface\targetwindow\` holds the gauge art (`tw_hp.ddj`, `tw_mp.ddj`,
  `tw_hp_npc.ddj`), the level gems (`tw_gem_weak1/2, normal, strong1/2,
  animal, npc, player, wanted_rank`), the rank icons and the job marks.

**What the client binary does with it** (sro_client.exe dump on the RE box):

- `CIFTargetWindowCommonEnemy::Create` (`0x0069aaa0`) loads its "Create"
  section by name -- these sub-windows are layout-driven, not code-drawn.
- `CIFTargetWindow` (`0x00699540`; the dump mis-files it under `UI_SILKMALL`)
  switches on the target's rarity (`+0x1eb`): 0 takes the common-enemy window,
  the rest the special one with `Client_TargetWindow_RankIcon`. (It also
  scales a special mob's *displayed* max HP by rarity -- champion x2, elite
  x4, giant x20, titan x100 -- a client display rule, noted for the server
  lane, not applied here: srrevamp shows the server's number.)
- The gem and the name colour come from one classifier,
  `FUN_007780c0(targetLevel)` (`0x007780c0`): `d = targetLevel - playerLevel`
  (the player's level byte at `DAT_00eef5ec+0x868`); `d < -6` -> class 0,
  `< -3` -> 1, `< 1` -> 2, `<= 5` -> 3, else 4, and the switch at
  `0x006996f0`..`0x699749` pairs them: weak2 `0xff87d2ff`, weak1 `0xffa5e0ce`,
  normal white, strong1 `0xffffb387`, strong2 `0xffff8787`.
- A gauge, `CNIFGauge::vslot_013` (`0x00498960`) -> `FUN_0046d6f0(ratio)`
  (`0x0046d6f0`): `+0x264 = ratio * fullWidth` and `+0x27c = ratio * fullU`
  -- the drawn width **and** the texture's U extent scale together, so the
  fill is clipped from the left, never squashed. (It also draws a second,
  dimmer ratio when two differ -- a damage ghost -- not built here.) Godot's
  `TextureProgressBar`, which `UiBuilder._build_gauge` already makes of a
  `CIFGauge`, clips the same way.

**Shipped.** `client/scripts/ui/hud/hud_target.gd` (new, `HudTarget`): the
container's close button and the common/special pieces from
`iftargetwindowex.txt`, each piece's own inner layout from `iftw_*.txt`
through `UiBuilder.build_section`, the gem slot given a `TextureRect` at its
authored rect (an art-less static builds as a Label), the gauge fed
`hp/max` from the server's snapshot, the name coloured and the gem chosen by
the recovered classifier from the player's own level (`_on_world_stats` now
hands it over; unknown level -> the neutral class, not a guess), the rank
icon only on the special window. `World3D.gd` keeps `_build_target_window`
/ `_show_target` / `_set_target_hp` / `_clear_target` as thin wrappers so no
caller moved; the hand-built constants and nodes are gone. Placement: the
registry's (442, 10) kept as an offset from the 1024-wide layout's centre
line (identical at 1024; the real client's left-vs-centre anchoring is not
recovered and is stated in the code). `hud_target_test.gd` covers the
classifier's boundaries, the rank switch and the no-archive path.

**Measured.** `--server --attack` at region 96/168 local (1089, 600), current
server binary: the log prints `gauge (14, 37) size (168, 4)` -- the authored
rect to the pixel -- and `fill 100.0% (249/249)` falling to `97.6% (243/249)`
with the server's own numbers over four hits. On frame 210 the red fill
spans x = 584..748 (window at 570 + authored 14; 165 px = 168 x 0.976) over
rows y = 47..50 (10 + 37, four rows; row 48 is the art's own highlight). The
crop (`scratchpad/target/target_crop_x4.png`) is the real window: the 196x51
piece 1:1, the red strong2 gem and salmon name for a monster far above a
level-1 player, the thin gauge in its slot, the close button.

**Stated, not claimed.** The special-mob window's two level texts are built
but left empty: which of `_LEVEL` / `_TEXT_LEV` carries the number and which
a word (`UIIT_STT_MOB_STRONG` sits in that code) is unread. The common
window's own layout shows no level; the level is what the gem says. The
atlas region for the 196x78 special piece comes out 77.9999 rows and is
drawn a sub-pixel stretched -- `UiBuilder.load_texture_region` keeps float
regions; rounding them is a nit for that file's owner. `tw_type1..4.ddj`
are real art nothing in these layouts uses.

## Two-hundred-and-fourth round: the public server had no reference data -- fed from the player's own archive, and a kill pays

The user's playtest on sro.opensro.org: no EXP on a kill, monster health that "felt wrong",
nothing dropping. The first two had one cause, and it was not a formula. The public server's
database held `items 0, skills 0, monster_drops 0, drop_group_entries 0`, and its compose command
passed only `-addr` and `-postgres-dsn` -- the server had been booting since 2026-09-11 with the
line `no leveldata CSV set (SRREVAMP_LEVELDATA_CSV) -- characters will not level` in its log.
Without items a weapon has no stats, so every hit was the floor band's 1; without leveldata a
kill pays nothing; without skills nothing can be learned. Every grounded formula in the server
was running on empty tables.

**What was done (all from the user's own Media.pk2, nothing from the repo).** `cmd/pk2list`
extracted the text tables on the render box; `export-refdata` produced 15,338 item rows and
33,698 skill rows, `export-leveldata` 140 levels. One correction along the way: the archive holds
more `itemdata_*`/`skilldata_*` parts than the client loads (124 against the 63 + 47 the index
files name), and the exporter keeps the *last* definition of a duplicated id, so the parts were
fed in the index files' own order rather than glob order (they differ: `1000, 2000, ...` against
`1000, 10000, 11000, ...`) -- 326 item and 290 skill ids conflict across parts and the client's
load order is the only defensible tiebreak. The CSVs now sit beside the pk2s on the render box
(the QA harness reads them from `PK2_DIR`) and in `~/srrevamp-data` on the VM; the raw extracted
tables were deleted. Items and skills were imported into Postgres (`items 15338, skills 33698`);
leveldata went in through the untracked `docker-compose.override.yml` as a read-only mount plus
`-leveldata-csv=/data/leveldata.csv`, with the base command restated because a compose override
*replaces* `command`. Boot log after: `loaded EXP curve path=/data/leveldata.csv maxLevel=140`.

**Measured, against the public server, from the render box.** A fresh level-1 china_man QA
character (`SRREVAMP_QA_SERVER=192.168.5.25:15779`, `--attack`, `QA_ATTACK_FAST`).

First attempt, booted at `--region 96\168.m`: the nearest monster was a **Yeoha** (249 HP, level
10) and the hits were 1-2 with the counter-blows 80-93. That is the floor band doing its grounded
job against a monster nine levels up, not a data failure -- and it exposed a QA trap: the client's
world frame is anchored on the region it boots with, while the server's frame is fixed on the
town, so booting one region south displaced every entity by a region. For `--server` runs, boot
`97\168.m` and address other regions through local coordinates past 1920.

Second attempt, `--region 97\168.m --at 130,2280` (the real Mangyang spawn, npcpos region 24744
local 1089.65/600.09 in the server's frame): **hits of 12-14, 26 on a crit; a Mangyang dead in
four; five kills in the run**. The character's row afterwards, read from Postgres:

| character | level | exp | gold | str/int | stat points | hp |
|---|---|---|---|---|---|---|
| DataProbe (first run, no kill) | 1 | 0 | 1000 | 20/20 | 0 | 80 |
| DataProbe2 (after five kills) | **2** | **3** | **1267** | **21/21** | **3** | **185** |

Five kills at level 1's 24-exp unit is 120 against a 118-exp threshold: level 2 with two or three
over, which is what the row says (the per-kill amount and the last point's rounding are the
combat lane's to reconcile, not this one's). EXP, levelling, stat growth and gold all move on the
public server now.

**Shipped in code.** One boot log in `cmd/server/main.go`: `reference data in PostgreSQL
items=N skills=N monsterDrops=N dropGroupEntries=N`, and a WARN when `items` is 0 that names the
recipe -- the EXP curve already warned; the tables did not, which is how a week went by.
`deploy/README.md`'s reference-data section is rewritten as the recipe actually run (it had
covered items only and still spoke of a flat "5"); `docs/HANDOFF_OPENSRO.md` points at it.

**Not this lane's, seen in passing.** (1) A fresh character's first HP reading was 107 after a
93 blow, so it started at 200, but after dying it respawned at 80 and later at 185 as level 2 --
the spawn-time HP looks like the old 200/200 placeholder where the respawn uses the grounded
formula. (2) Drops: with `monster_drops` and `drop_group_entries` empty the loot roll has nothing
to roll; the real tables are DB-only and the server package on the render box has no shard
backup (`smc.bak` is the manager DB), so "items don't drop" stays a mechanic-and-content question
for the drops lane. (3) Two QA characters (`DataProbe`, `DataProbe2`, account `qa-data`) now
exist on the public server; harmless, deletable.

## Two-hundred-and-third round: berserk orbs are earned on the killing blow, by the game's own chance

"I get berserk balls for attacking; you should get some when it dies." The
report was right, and the reason was that `berserk.FillPerHit = 8` was own
design, declared as such. The engine's rule is read now, function by function,
and it is a **kill** rule with no fractional gauge anywhere in it.

**The one piece of state.** `_CHAR.RemainHwanCount` (charData+0x86, 0..5) has
exactly one mover, `GObjPC::AddHwanCount` (`0x004e4d00`): the delta arrives in
ESI, a positive delta is refused while `GetBodyMode()==1` (berserk on), the
result is clamped to `[0, 5]`, persisted with dirty bit 0x10, and
`FUN_004e3fb0(4, ...)` announces it. The client's five orbs are that byte.

**Who calls it.** Six call sites in the disassembly (`call 0x4e4d00`):
the activation handler (-5, the spend already recovered), two item paths,
`EngageSkill` at `0x5935be` -- `movzx esi,[skill_ref+0x18]; neg esi`: **a skill
spends its own hwan cost**, the `Consume_WHAN`-style byte, gated on it being
non-zero and the caster being a PC -- the party share (below), and the one
that earns: the per-target apply pass `FUN_00593800` at `0x593b97`, with
`mov esi,[esp+0x14]`, a computed amount.

**When it fires.** The apply pass gates the earn on the effect block's
`+0x54`, and `Combat_ResolveDamage` writes that field exactly once (its line
1150): on the **killing blow** -- when the accumulated damage reaches the
target's HP (state byte `|0x80`) -- and only if the attacker's `GetBodyMode()`
is not 1 and the target's vtable slot 62, `IGObj::GetLifeState`, answered 1
(it was alive, so a corpse cannot pay twice). The apply pass then requires
the attacker to be a PC (slot 7), asks `FUN_00410880(pc, &amount)` for a
chance, and rolls `rand() % 10000 < chance`.

**How much, and how likely -- `GObjPC::HwanGainChance` (`0x00410880`), from
its asm at `0x410880-0x4109c0` with every constant read out of .rdata:**

	amount = 1
	pct    = 8.0                                        ; 0xb45e14 (float) = 8.0
	if LevelGapClass(target - attacker) == 2:           ; victim more than 3 levels below
	    pct = 8.0 - 0.25 * (attackerLvl - targetLvl - 5) ; 0xb45eb0 = 8.0, 0xb45ca8 = 0.25 (doubles)
	    pct = clamp(pct, 0.25, 8.0)                     ; 0xb45b50 = 0.25 (float)
	chance = ftol(pct * 100.0)                          ; 0xb45af0 = 100.0 -> 1/100 % units
	if target.IsMonster():                              ; slot 10
	    switch target.GetMonsterClass():                ; slot 75; jump table at 0x4109e8
	      3, 8:  amount = 5; chance = 10,000,000         ; unique: all five orbs, certain
	      4:     chance *= 5                              ; giant
	      6:     chance *= 2                              ; elite
	if p := attacker.GetParam(184); p != 0: chance = chance * p / 100
	return chance & 0xffff

`LevelGapClass` is `FUN_0040fe60`: `diff = target - attacker` as bytes; `diff <
-3 -> 2`, `diff < 11 -> 0`, else `1`. Only class 2 decays; a much higher victim
earns no bonus. So an even fight is **8% per kill for one orb**, a victim six
levels below 7.75%, ten below 6.75%, thirty-six or more below the 0.25% floor;
a giant five times that, an elite twice, and a unique fills the five outright.

**The party branch.** When the victim `IsMonster` and answers slot 193,
`CGObjMob::IsPartySupportMonster`, and the killer's party has bit 0 of
`party+0x10` set -- the exp-sharing flag `internal/party` already recovered --
`FUN_005bcf30` walks the party and gives the amount to every member that is a
PC, alive (`GetLifeState()==1`) and in the killer's region. An ordinary kill
pays the killer alone.

**Settled by use-site, not name.** Param 184 (registry: default 0, max 1000,
no tag) is the engine's own gain modifier; srrevamp publishes no source for
it. The `HwanGain` rate `internal/rates` carries from the pserver's config is
NOT read on this path in the dump build; how that build applied it, if at all,
is not established.

**Shipped.** `internal/berserk` keeps the orb count (0..5) as its state and
earns with `EarnOnKill(Kill{...})`, whose `GainChance` is the table above,
pinned point by point in `berserk_test.go` (twenty cases, including the
floor, the clamp back to base at a four-level gap, giant-far-below = 3375, and
the unique's certainty); `Gauge()` is `Charges * 20` so the HUD and the wire
are untouched. `session/combat.go` no longer fills on every attack; it calls
`EarnOnKill` inside the kill block with the monster's level and rarity and
reports the count on the same attack result. `hwan_test.go` proves both
deterministic ends at the wire: a non-killing blow earns nothing, a unique
kill pays all five. Activation still requires and spends five.

**Not wired, stated:** the party-support share (srrevamp spawns no
party-support monsters); persisting the count (the engine's is a DB column;
srrevamp clears it on disconnect); a skill's own hwan cost on cast (needs the
`Consume_WHAN` column index); param 184's source.

## Two-hundred-and-second round: an own-skeleton item hangs the way the client hangs it -- the attach bone's rest inverse, the root's rest cancels

*Written 2026-09-18 on branch `worktree-agent-ac224f246bb987f6a`, for the coordinator to file as
the next `docs/WORLD_ISSUES.md` round. Evidence first; the decompile lives on the RE box
(`/var/tmp/decomp_client`, `sro_client.exe`), not in this repo.*

### The question

Round 137 hung an own-skeleton item (a weapon, the `_sa` collar) under a `BoneAttachment3D` with the
item skeleton's local transform set to the **item root's** rest inverse -- "chosen by rendering",
its own comment said. Round 141 measured that this floats the `clothes_01_sa` collar as a grey
rectangle by the neck. The lineup render of 2026-09-18 added that the spear and bow splay off the
hand. One rule was wanted, read from the client, that fits sword, blade, spear, bow and collar.

### What the `.bsr` and `.bsk` files carry (data)

`tools/dump_bsk_raw.gd` (new) prints a `.bsr`'s skeleton entry and every float of a `.bsk` record:

| item `.bsr` | own `.bsk` | attach bone | root rest (euler deg) |
|---|---|---|---|
| `sword_01` | `prim\skel\item\china\weapon\sword_01.bsk` (Bone01, Bone02, ai_start, ai_end) | `Bip01 R HandMid` | (89.2, -83.1, 95.3) |
| `blade_01` | `...\blade_01.bsk` (Bone01, ai_start, ai_end) | `Bip01 R HandMid` | (0, 180, 0) |
| `spear_01` | `...\spear_01.bsk` | `Bip01 R HandMid` | (0, 179.6, 0) |
| `bow_01` | `...\bow_01.bsk` (Bone01 only) | `Bip01 L Hand` | (0, 0, 0) |
| `clothes_01_sa` | `prim\skel\item\china\clothes_sa.bsk` (Bone01 + two flap chains Bone03/04, Bone05/06) | `Bip01 Neck1` | (0, -90, 90) |

The body (`chinaman_fighter.bsr`) names `prim\skel\char\europe\europeman_skel.bsk`; its bones sit
where `china\chinaman_skel.bsk`'s do (`Bip01 Neck1` (0, 15.45, 0.19), `Head` (0, 15.95, 0.09),
`R HandMid` (-7.97, 14.93, 0.33), clavicles (+-0.33, 15.0, 0.19) in both).

**The `.bsk` record, from its loader** (`CPrimBranch::vslot_001` = `FUN_00bfb580`,
`objengine\PrimSkeleton.cpp`; per-bone `PrimSkeleton::FUN_00bfae90` reads, `FUN_00bf9e60`
applies): header `uint32` at 0x0c = bone count; then per bone a kind byte (0 bone / 1 dummy --
`CRTBone`/`CRTDummy`, both `CRTSocket`), name, parent name (empty for a root -- the 92-vs-88 byte
"two shapes" of BSK_FORMAT.md), **three (quaternion, vector) transforms in order: local, world
bind, inverse bind**, then a `uint32` count of child names (the "announce" list). Verified on the
data: for every root the three rotations are q, q, q^-1; for `sword_01` Bone02 the second is the
root's rotation (its world), the third its inverse, and the third translation is `-R^-1 p`
(blade: p (0.0027, 0, 0.0058) -> (0.0027, -0, 0.0058); spear: (-0.0013, -0.026, 0.0081) ->
(-0.0012, 0.026, 0.0082)). BSK_FORMAT.md now says so.

### What the client does with it (binary)

- **Link.** `CCompChar::FUN_00c4fc70` (a part's `RTSkeleton`): if the part's attach-bone
  `std::string` (`owner+0x58`, size at `+0x6c`) is non-empty, the bone is found by name
  (`FUN_00c2c890`/`FUN_00c2c820`), the item skeleton is registered in the body skeleton's child
  list, and the item **root bone's parent socket** (`root+0xc`) is set to that body bone with
  update mode `root+0xa0 := 1`. `CCompChar::FUN_00c4c1e0` is the unlink (both back to 0).
- **Update.** `CRTBone::vslot_003` dispatches on the mode: 0 -> `RTSkeleton::FUN_00c49f20`,
  1 -> `CRTBone::FUN_00c48fe0`. Each bone owns three 4x4 matrices at `+0x80`: `mat0` local
  (the prim's local bind, or the animated quaternion/position at `+0x2c`/`+0x3c`), `mat1` world,
  `mat2` skin. Mode 0: `mat1 = mat0 x parent.mat1` (or `= mat0` with no parent),
  `mat2 = prim.mat2 x mat1` -- ordinary FK, `out = a x b` in D3D row-vector order, skin =
  inverse bind x world. **Mode 1: identical except the parent frame is `[R(parent.mat2) |
  t(parent.mat1)]`** -- the attach bone's skin rotation at the attach bone's world position
  (the temp matrix at `DAT_0111316c` is filled from `parent block+0x80`, then its row 3 from
  `+0x70..+0x78`, i.e. `mat1`'s translation).
- **Consequence.** For a root, local = world bind, so `invBind_root x local_root = I` and the
  root's skin matrix is `[R(attach.skin) | t(attach.world)]` (translation: `-t_L R_L^-1 R_L R_s +
  t_L R_s + t_w = t_w`). The item's **model space lands at the attach bone's position with the
  body's axes**, rotated only by the bone's rotation relative to its own bind. The item root's rest
  never shows. Item child bones (the collar's flaps, a weapon's `ai_*`) are mode 0 under that root
  and reduce to the same `[I | t_w]` at rest.
- **In Godot**, under a `BoneAttachment3D` (which applies the bone's full pose `[B_pose | p]`), that
  is the constant item-skeleton local transform `(B_rest_attach^-1, 0)`; the item skeleton keeps its
  file rests so its skin is identity at rest. `SkinnedBsrAssembler.attach_item_from_archive` now
  does that, replacing round 137's `get_bone_rest(0).affine_inverse()`.

### Measured, before and after (`tools/probe_attach.gd`, new)

Body space: Y up, arms along +-X, front -Z. "current" = round 137, "client" = the rule above;
the probe also re-measures the **shipped** code path (a real `attach_item_from_archive` under a
`BoneAttachment3D`, two frames later) and it matches the "client" rows to the printed precision.

| item | rest: current heading | rest: client heading | idle (standcity 0 s): current | idle: client | centroid-to-bone |
|---|---|---|---|---|---|
| sword_01 | (0.01,-0.02,-1.00) -Z | (-0.02,-0.02,-1.00) -Z | (-0.27,0.01,-0.96) | (-0.26,-0.02,-0.96) | 1.27 |
| blade_01 | (0.08,-1.00,0.02) **-Y** | (0.09,-0.02,-1.00) -Z | (0.96,0.06,-0.27) **+X** | (-0.27,0.09,-0.96) | 1.37 |
| spear_01 | (0.13,-0.99,0.01) **-Y** | (0.14,-0.01,-0.99) -Z | (0.96,0.11,-0.27) **+X** | (-0.27,0.14,-0.95) | 12.28 |
| bow_01 | (-0.25,-0.97,-0.03) -Y | (-0.26,-0.03,0.97) +Z | (-0.93,0.22,0.29) | (0.25,0.07,0.97) | 0.22 |
| clothes_01_sa | long axis (-0.08,0.43,**-0.90**) front-to-back | (-0.79,0.61,0.08) **across** | | | 1.63 |

Under round 137 the sword pointed forward while the blade and spear -- same hand, same clips --
pointed down at rest and sideways in the idle: it fitted `sword_01` only because that root's rest
(89, -83, 95) happens to equal the hand's global rest (89.5, -90, 90). Under the client's rule all
three hand weapons share one heading, and the collar lies across the shoulders, centred on the
neck: centroid (-0.15, 17.07, 0.22) = `Bip01 Neck1` + (0, 1.63, 0), i.e. jaw height, 6 wide.
That height is what the data plus the rule give (the mesh is authored 1.6 above its origin); I
have no original-client picture of the cotton collar to say it is a standing collar by design, so
that is stated, not claimed.

Renders (scratchpad `attach/`): `attach_lineup.png` (four outfits at rest), `attach_idle.png`
(heavy set + collar + sword posed with `standcity.ban` at 0 s), `attach_gizmo.png` (the same
with the item nodes' axes drawn -- `render_lineup.gd --gizmo=1`, new). The gizmo was needed: a
blade pointing **at** the camera from the upper right of the frame projects outward and up, which
I first misread as "along the arm"; the node's blue +Z runs toward the image centre and the blade
exactly opposite, as the numbers say.

### On the coordinator's datum (sword forward offline, tip-down in-world)

With a correctly following attachment, `standcity.ban` at 0 s puts the sword **forward,
horizontal, at hip height under both the old and the new rule** (hand at (-2.45, 8.63, 1.18);
its turn from the T-pose is about the body's Z axis, which leaves a -Z blade unchanged). Neither
composition produces tip-down at that clip and time, so an in-world tip-down hang is a difference
in the **pose** path (clip, time, or stance), not in attach. Round 137's "hangs tip-down" was
judged from a render; this round's rule explains the offline result and predicts in-world will
match it once the same clip is applied.

### Files

- `client/scripts/assets/skinned_bsr_assembler.gd` -- the rule, with its citation, replacing the
  render-picked transform.
- `client/tools/probe_attach.gd` (new), `client/tools/dump_bsk_raw.gd` (new),
  `client/tools/render_lineup.gd` (`--gizmo`).
- `docs/protocol/BSR_FORMAT.md` (composition section), `docs/protocol/BSK_FORMAT.md` (record
  semantics from the loader).

**In-world check (coordinator).** Merged and rendered at the real spawn (97/168 @ 1002, 1020) with the
heavy set and the starter spear (`6=3634`): `wears 4/4`, animation group `spear`
(`spear_stand_city_fighter.ban`); in the front, three-quarter and side frames the spear hangs from the
right hand and follows the stance, no longer detached or splayed sideways as under the old rule.
The heading itself is the probe's measurement, not the frame's.

## Two-hundred-and-first round: the inventory -- the gold row, dragging in the bag, and onto the doll

A round written for `docs/WORLD_ISSUES.md` (the coordinator numbers and merges it).
Everything below was checked against the server's own answers in a `qa_shot.sh --server`
render, not read off a picture; the frames are only the confirmation that the window drew
what the log says.

### The gold readout was already wired — the TODO line was stale

`HudPanels._apply_stats` writes `GDR_INVENTORY_STA_GOLD` from `OpCharacterStats`'s `gold`, and
`_populate("inventory")` requests those stats on open. The render log shows the row and its
source agreeing: `inventory gold readout 1,000 (server gold 1000)` — 1000 being
`character.StartingGold` (own design, disclosed in its comment). One log line was added so a
render can hold the row against the server value; nothing else changed for gold.

### Drag-and-drop between bag slots: `OpInventoryMove` (0x0032 / 0x0033)

There was no way to rearrange the bag: `inventory.Store` had `List`/`AddItem`/`RemoveItem` only
and `InventoryNet` only `OP_LIST`. Added:

- **`inventory.Store.MoveItem(ctx, characterID, from, to)`** on both stores, one rule:
  `from` must hold something (`ErrSlotEmpty`), both indices in range (`ErrInvalidSlot`), a
  self-move is a no-op; then `to` empty → move; `to` holds the **same item with stack room** →
  merge what fits (up to MaxStack), remainder stays; anything else (a different item, or a full
  or non-stackable same item) → swap. Quantities are conserved in every branch. `SQLStore` does
  it in one transaction; a swap deletes and re-inserts the two rows because `(character_id,
  slot)` is the primary key. `move_test.go` runs the seven cases against **both** stores (7/7
  mem, 7/7 sql).
- **Wire**: `InventoryMoveRequest` = name + two s64 slot indices (the `UseItemRequest` shape
  with a second index). The reply is an `InventoryListResult` on `OpInventoryMoveResult` —
  the whole bag as it stands, or the refusal — the same reuse the storage list already makes,
  so the client redraws from the answer instead of assuming the move happened.
- **Client**: `InventoryNet.OP_MOVE`/`encode_move_request` (byte-layout test in
  `inventory_test.gd`), `NetClient.move_item` + `inventory_move_result`. The drag is done by
  hand in `HudPanels` (the cells are plain Controls from `UiBuilder`, so Godot's
  `_get_drag_data` route was not available): a press on a filled cell arms it, 4 px of motion
  starts it (a copy of the icon follows the mouse), the release is resolved against the
  lattice cells' own rects (slot = child index, the same indexing `_fill_inventory_grid` draws
  by) or the docked doll's `GDR_EQUIPMENT_SLOT_*` rects; Escape cancels. Nothing is sent
  until a drop lands somewhere that means something. When a vendor window is open a click
  still sells/deposits, as before.

**Verified** (`SRREVAMP_QA_MOVE="0,9"`, the new hook): a fresh character's bag is empty (its
kit is equipped straight out of it), so the hook first **unequips the boots** (real
`OP_UNEQUIP`; they land in the lowest free slot, 0), lists, moves, lists again:

```
QA MOVE before: {0:3645 x1}
QA MOVE after:  {9:3645 x1} (asked 0 -> 9)
```

Both lines are the server's list. The frame shows the boots icon in the third row, second
column — slot 9 of the 4×8 lattice — and the gold row at 1,000.

### Dragging onto the paper doll equips — and it exposed an old ambiguity

Dropping a bag stack on a worn slot sends `OpEquip(slot, from)`; the server's rules decide.
The QA hook then "drops" the moved slot on the doll's boots rect **through the same hit-test a
real drag uses** (`_drop_bag_item` at the slot control's centre, `(796, 371)` in the frame):

```
QA MOVE equip-drop: dropping bag slot 9 at (796, 371) (the doll's boots rect)
QA MOVE equip-drop: bag {} (dropped slot 9 on the doll's boots rect)
```

The bag came back empty and the final frame shows the boots icon in the doll's boots slot again.

Two things this run found on the way, both fixed:

1. **The box's in-memory server refused the equip until it had reference data.**
   `equipRefusal` deliberately refuses an item its tables do not know (the documented
   potion-equip incident), and no `items.csv` sat beside the pk2s. That is the server being
   right. For the run, `itemdata_*.txt` were extracted with `pk2list -extract`, turned into
   `items.csv` with `export-refdata` (16,819 rows; item 3645's type ids `3,1,1,6` = clothes
   `FA`, boots), passed as `SRREVAMP_ITEMS_CSV`, and deleted afterwards.
2. **A successful equip/unequip answered `EquipmentResult{}`** — on the wire identical to
   "wearing nothing" — and the client's shared `equipment_result` handler redrew the paper
   doll bare from it while the body stayed dressed (seen in a frame: every worn-slot icon
   blank after the equip). `handleEquip`/`handleUnequip` now answer with the worn list via
   `sendWornList`, the same way the move op answers with the bag; and the client no longer
   redraws the doll from an *error* result either (it logs the refusal and keeps the last
   known equipment). No opcode or payload shape changed — an ack simply carries the list.

### Not done / flagged

- The authored grid is 4×8 (32 cells) while `SlotsPerCharacter` is 50: a stack the server puts
  past slot 31 has no cell to draw in, and no drag can reach it. Pre-existing; not touched.
- The drag is client-authored behaviour (threshold, ghost icon, Escape); nothing about how the
  original's drag looks was recovered, and none is claimed.
- The QA sequence runs before the QA harness opens the panel, so the doll-drop waits for the
  window (polls up to ~20 s) rather than assuming it exists.

## Two-hundredth round: the minimap's signs

`interface\minimap\` has one sign per kind of thing around the player. `HudMinimap.update_signs`
now draws `mm_sign_npc`, `mm_sign_monster` and `mm_sign_otherplayer` at the entities' real
positions, from the lists the client already has: the `Npc_*` holders under each loaded
`RealTerrain_*` group, `_monster_bodies`, `_other_bodies` (World3D passes positions only — the UI
seam stays "positions in, nothing out"). `mm_sign_questnpc` and `mm_sign_party` exist but nothing
the client receives yet says which NPC carries a quest or who is in the party, so they are not
drawn.

**Placement rule** (pure, tested): the tile is laid so the player sits at the aperture centre and
one region (1920 units) spans `256 × zoom` px with world X along u and world Z along v — the same
rule `update_player` positions the tile by (round 100) — so a sign lands on the map's own pixel
for that spot: `offset = (entity − player).xz / 1920 × map_size`. A sign whose centre falls
outside the 52.5 px aperture circle is hidden. Signs are pooled `TextureRect`s between the map and
the player arrow, sized by their own artwork.

**Measured.** At the Jangan spawn (97/168 local 1002,1020) with the in-memory server:
`HudMinimap: signs drawn 8 of 71 entities (npc 49, monster 22, other 0): npc@(-3,4) npc@(-3,4)
npc@(-3,39) npc@(13,22) npc@(-19,22) monster@(21,-21) monster@(22,-37) monster@(4,-21)`.
Pixel clusters in the frame (connected components inside the aperture): three red 12-px clusters
at x offsets 21, 22, 3 and two blue at −20, 13 — matching the three monsters and the two
south-west/south-east NPCs (a constant ≈9 px y shift between log and cluster centres is the
sign core's position in its 16-px art plus the HUD's top offset). The three signs not visible as
clusters are accounted for by the log: two NPCs share the spot (−3,4), under the player's own
16-px arrow, and one at (−3,39) sits under the frame's "S" marker. So: the client's art has
**monsters red and NPCs blue** — the file names decide, not a colour assumption (an earlier read
of the frame had that backwards).

Files: `client/scripts/ui/hud/hud_minimap.gd`, `client/scripts/ui/hud/hud_minimap_test.gd`
(offset rule, culling, no-artwork path), `client/scripts/World3D.gd` (three lines in the per-frame
minimap block plus two position helpers — nowhere near the player-pose code).

## Hundred-and-ninety-ninth round: the client's UI font, the way the client picks it

**What was wrong.** `UiBuilder` mapped a control's `FontIndex` to *the index-th `.ttf` in
`fonts\` directory order* and used the recovered sizes `[9, 8, 12, 11, 15]` as pixel sizes.
The first was a guess, the second a unit error; together every window's text was a third too
small and set in a Korean face (TaeUtum) the client never uses for the English UI.

**How the client actually does it** (client binary, decompiled dump in `/var/tmp/decomp_client`,
disassembly via `tools/ghidra/Disasm.java` on `re_client`):

1. **Bundled fonts are installed, not drawn from directly.** `Game.cpp` walks `fonts\` in
   Media.pk2, extracts each file (`CreateFileA(..., GENERIC_WRITE, CREATE_ALWAYS,
   FILE_ATTRIBUTE_HIDDEN)`, asserts `"CreateFile(%s)"` at Game.cpp:0x3fa/0x405) and registers it
   with `AddFontResourceA` in `gfxmainframe::FUN_00ba60b0` (assert `"AddFontResource(%s)"`,
   gfxmainframe.cpp:0x1fb). So GDI can resolve the bundled families by name.
2. **One face for every FontIndex, by name, from the text table.** The font-table builder
   `FUN_00469350` registers the five indices with `GNFontChar::FUN_004927b0(index, size)`:
   `(0,9) (1,8) (2,12) (3,11) (4,15)`. The face travels in ESI — invisible in the decompile, plain
   in the disassembly: `004693eb MOV ESI,[ESP+0x34]` (the caller's 7th argument), `TEST ESI,ESI`,
   `JZ 0046941c` → `0046941c MOV ESI,0xe172d8` (the NULL fallback), then the calls. The 5th call at
   `00469445` (index 4) uses whichever face is current. The one caller (`funcs_010.c:47812`)
   builds that 7th argument from `FUN_008c9c30(L"UIC_STT_FONTNAME")` — a UI text-table lookup —
   converted to a `char*` by `FUN_004fc950`.
3. **The fallback literal** at `0xe172d8` is `b1 bc b8 b2 c3 bc 00` (DumpBytes.java) = CP949
   **"굴림체"** (GulimChe).
4. **Creation.** `GNFontChar::FUN_004927b0` → `FUN_00baa110(this, index, size, face, italic,
   bold, underline)` (assert `"CreateFont(%s)"`, sriflib/GNFontChar.cpp), which fills a `LOGFONTA`
   and calls `CreateFontIndirectA`:
   - `lfHeight = -MulDiv(size, 0x60, 0x48)` — **points at a hardcoded 96 dpi**; a negative
     lfHeight is the em height in pixels. Index 0 = 9pt = **12px**; the table is
     `[12, 11, 16, 15, 20]` (MulDiv rounds to nearest: 8pt → 10.67 → 11, 11pt → 14.67 → 15).
   - Four variants per index: `[0]` regular, `[1]` italic (`lfItalic=1`), `[2]` bold
     (`lfWeight=600`), `[3]` underline; the caller's flags `(0,1,0)` create regular + bold.
     Which controls draw with the bold variant is not recovered; none is applied.
   - `lfCharSet=1` (DEFAULT_CHARSET), `lfQuality=0` (DEFAULT_QUALITY).

**What the archive says** (`tools/dump_fonts.gd`, new, reads the player's own Media.pk2):

| Source | Family |
|---|---|
| `textuisystem.txt` `UIC_STT_FONTNAME`, English column | **Tahoma** |
| same row, Korean column | 굴림체 (= the binary's fallback) |
| a second, 16-column `UIC_STT_FONTNAME` row | Arial |
| `fonts\기본서체.ttf` ("basic typeface") | TaeUtum (400) |
| `fonts\영문서체.ttf` ("English typeface") | Arial Rounded MT Bold (700) |
| `fonts\채팅서체.ttf` ("chat typeface") | SeUtum (400) |
| `vplus\vfont.ttf` | Arial (400) |

Tahoma is not in the archive; it is a Windows system font, and the real client renders the
English UI in the system's copy.

**What is shipped.** `UiBuilder` now resolves the face as the client does: the text table's
`UIC_STT_FONTNAME` (falling back to the binary's 굴림체); a bundled file whose family is that
name; else the system's font of that name via `OS.get_system_font_path`, accepted **only if the
loaded file's own family name matches** (fontconfig returns a substitute — DejaVu Sans for
Tahoma on the render box — and a substitute must not pass as the real face); else — **disclosed,
ours** — Arial from `vplus\vfont.ttf`, chosen because it is the archive's other authored value
for this same key. Sizes are the em pixels above (`FONT_SIZES`), with the point table kept as
`FONT_POINT_SIZES`. One log line says what was resolved:
`UiBuilder: UI face 'Tahoma' (UIC_STT_FONTNAME) -> <source> (family '...'); sizes px [12, 11, 16, 15, 20]`.

**Rendering flags.** The reference screenshots' text is aliased: every glyph pixel of "Current
Exp." in `character.png` falls in one luminance bucket (`{12: 162}`), i.e. one text colour and no
edge ramp. The font is therefore set to `FONT_ANTIALIASING_NONE`; `HINTING_NORMAL`, no autohinter
and `SUBPIXEL_POSITIONING_DISABLED` are the Godot analogs of GDI's integer-pixel, native-hinted
rendering — the aliasing is measured, those three are the analog, not values read from the binary.

**Measured against the reference** (`docs/reference/ui/character.png`, which is a **1.066×**
crop: its frame is 388 px for an authored `GDR_PI_SUBFRAME` of 364×356, so reference pixels are
divided by 1.066):

| | reference (÷1.066) | ours, 1:1, Arial fallback |
|---|---|---|
| "Current Exp." cap height | 9 rows → 8.4 px | **9 rows** |
| descender rows below it | 2 | **2** |
| glyph luminance levels | 1 (`{12: 162}`) | **1** (`{12: 166}`) |
| "Phy. balance" width | 68 px → 63.8 px | 69 px (Arial is the wider face, +8%) |

Tahoma's own metrics predict the same: capHeight 1489/2048 × 12 = 8.7 px; the previous 9 px em
would have given 6.5 px. `GDR_PI_TEXT_HP_DAT` carries `FontIndex 1` (11 px) and the HP readout
now renders smaller than its row label, as in the reference.

**A second fix the measurement forced: no clipping.** The reference draws "Phy. balance" 63.8 px
wide and "Mag. balance" 65.7 px wide inside authored rects (`GDR_PI_TEXT_PHYBAL`, `_MAGBAL`) of
**58 px** — the client lets a static's text overrun its rect (UI_TODO rule 13 already recorded
`TEXT_HP_DAT` overrunning by 17). `_apply_font` had `clip_text = true`, which cut those to
"Phy. balan" / "Trader Gra"; it is now false and every label in the window renders whole.

**Not grounded / open.** The bold (600) variant's users; whether `lfQuality=0` on the original
machines produced aliased text by policy or by size (the reference shows aliased, which is what is
matched); the Tahoma path itself was verified by code path and the family guard, not by a render —
the render box has no Tahoma, so its frames show the Arial fallback (logged as such). On a
Windows machine with Tahoma installed the resolution takes the system-font branch.

Files: `client/scripts/ui/ui_builder.gd`, `client/scripts/ui/ui_builder_test.gd` (font table,
face fallback), `client/tools/dump_fonts.gd` (new).

## Hundred-and-ninety-eighth round: the legs the animation "ate" were inside the dragon's pedestal -- the rig is fine

The hundred-and-ninety-seventh round measured a dressed player at Jangan local (1002, 917) rendering only
waist-up under the town idle, with the toe bone on the ground and the rest pose
rendering whole, and concluded the fault was the skinned mesh under
`apply_ban_pose`. That conclusion was wrong, and the evidence that overturns it
was already in that round's own rig report.

**What the skinning actually does under the idle -- as numbers.** The new
`tools/probe_skinning.gd` replicates the vertex shader on the CPU: for every
skinned piece it computes `sum_k w_k * (bone_global_pose_k * skin_bind_k) * v`
at rest and after `Skeleton3DBuilder.apply_ban_pose_at(standcity.ban, 0 s)` --
the exact call the world makes each frame. Every piece stays on the body:

| piece | rest y | posed y |
|---|---|---|
| `man_calf` | 0.00 .. 4.26 | 0.01 .. 4.31 |
| `man_thigh` | 3.96 .. 9.86 | 4.05 .. 9.93 |
| `man_pelvis` | 8.90 .. 11.28 | 9.00 .. 11.39 |
| `man_torso_lower` | 10.87 .. 13.42 | 11.00 .. 13.58 |
| `man_arm_lower` | 14.51 .. 15.36 | 8.15 .. 11.76 |
| `chinaman_fighter_hair` | 16.01 .. 19.23 | 16.12 .. 19.36 |

The arms drop from the T-pose to the sides (lower arm centroid 14.9 -> 9.2);
the legs move by a tenth of a unit. 37 of 43 bones have tracks (the six
without are `Spine_Base`, `L HandMid2` and four cloak bones, which keep their
rest); no track names a missing bone; every vertex's weights sum to 1. The
chain dump agrees: `Bip01 R Toe0` global rest (-2.51, 0.00, -1.12) -> posed
(-2.06, 0.01, -0.16). Nothing in the pose lowers or folds the legs.

**What hid them.** The rig report's ray from 60 above the feet, fired at
(1002, 917), had said: *first surface down from overhead at 11.45 above the
feet on `cj_jang_gate07`*, and *one walkable height in this column* (the
terrain, -51.90). That is a solid top 11.45 units over the spot the nav
landed the player on. The pelvis sits at 9.9 .. 11.4 -- so the "tiles" the
waist appeared to stand on were that object's top face, and everything below
it was inside the object. `QA_AT` teleports without collision, so it can put a
player inside a solid; a walking player cannot get there. Three offsets settle
the object's extent: (1020, 917) and (985, 917) are still under `gate07`'s top
(+11.45), (1002, 945) is clear (nearest collider 43 up). `cj_jang_gate07` is
the square's raised plaza; at (1002, 917) its top is the dragon's pedestal,
which is correctly *not* walkable. The docs' "square and dragon at local
~1002, 917" is where the dragon is, not where one stands.

**Where one does stand.** The game's own Jangan spawn is 97/168 local
(1002, **1020**) (`worldmap.go`). There the same dressed body under the same
running idle reports *first surface at -0.00 from the feet on `cj_jang_gate07`*
with two walkable heights in the column, terrain -43.92 and platform -30.12,
the player on the platform; bones -30.10 (toe) .. -14.03 (head), meshes -30.21
.. -10.88. The frame shows the whole fighter on the tiles, sword hanging,
arms at his sides. The palace courtyard (98/168 at 960, 830) gives the same:
surface at -0.00 on `CJ_pal_indoor_floor01`, legs on the floor.

**Shipped.** `tools/probe_skinning.gd` (the CPU skinning replica -- a rig
question is now numbers, headless, in 20 s); `render_dressed_character.gd
--pose=<s> [--group] [--ban]` (the world's idle applied offline, one ~40 s GL
run); and `_qa_rig_report` now says in words when the overhead surface is
above the feet: `** player is INSIDE <object>: its top is N above the feet ...
this is not the rig **` -- the line that would have stopped the hundred-and-ninety-seventh round's
misread. No change to `Skeleton3DBuilder`, the readers or the pose call site:
there was nothing to fix. The 2026-09-08 "stands correctly, arms at its
sides" note in `World3D.gd` stands, now with a mesh-level measurement behind
it rather than a bone-only one.

**Still open, other lanes.** The sword's orientation differs between the
offline posed render (pointing forward) and the world (tip-down at the leg)
at the same clip -- the item-attach lane's question, not this one.

## Hundred-and-ninety-seventh round: a dressed fighter standing in the real world, and the legs that seemed to vanish

> **Corrected by the hundred-and-ninety-eighth round.** The "animation eats the legs" conclusion
> below was wrong: `QA_AT` had teleported the player *inside* the dragon's pedestal (it has no
> collision), and this round's own rig report said so -- "first surface down from overhead ...
> 11.45 from the feet on cj_jang_gate07". The skinning under the idle is correct, measured
> vertex-by-vertex. The hook, the item ids and the equipment result stand.

"Focus on textures, equipment, images from the pk2." So: dress the player
*in the world*, not on a plain backdrop, and drive it from real item ids
the server could actually send.

**The hook.** `SRREVAMP_QA_EQUIP="slot=item_id,.."` (and `qa_shot.sh
--equip`) stands in for the server's equipment list when no server is
present. It feeds `_real_player_equipped_items` a `slot -> item id`
dictionary (slots are `EquipmentNet.SLOT_*`), so the ids resolve through
the real item table (`_item_models`) on the exact same path the server's
list drives -- not a shortcut around it. The loadout used is the China-man
newbie **default** kit, read out of Media.pk2 by the new
`tools/dump_item_set.gd` (filter the item table by code-name substring):
the `_DEF` rows are the literal starting gear. `ITEM_CH_M_HEAVY_01_BA/LA/FA`
= **3637 / 3638 / 3639** (chest, legs, boots; the `BA`/`LA`/`FA` suffix and
`type_ids[3]` = 3/4/6 give the worn slot), and `ITEM_CH_SWORD_01_A_DEF` =
**3632** (`type_ids[3]` = 2 -> the `sword` animation group). The client
logs `china_man wears 4/4 item(s)`; chest/legs/boots attach weighted onto
the body, the sword hangs from its own skeleton on `Bip01 R HandMid`. The
`_sa` shoulder is deliberately left out (round 141's mis-hung accessory).

**A measured find, not a screenshot one.** In the world the dressed body
renders only from the waist up -- the legs are below the plaza tiles, in a
front shot at 55 units as much as a back shot at 16. That reads as "sunk,"
but it is not: `SRREVAMP_QA_RIG` puts the lowest bone `Bip01 R Toe0` at
y -51.89 against a landing height of -51.90 -- **the feet are on the
ground**, and the bone chain spans a correct 16 units up to the head. The
same body assembled by `tools/measure_assembled.gd`/`render_dressed_character.gd`
in its **rest pose** renders whole, legs and all (bounds 18x19x9). The only
difference between the two is the per-frame `apply_ban_pose_at` running the
town idle (`chinaman_fighter_standcity.ban`) on the in-world skeleton. So
the fault is in the **skinned mesh under that pose**, not in where the
bones sit -- the lower-body verts stop following their (correctly placed)
leg bones once the idle is applied.

This is the same `apply_ban_pose` bug this file has chased before (the
"arms and legs splayed" note in `World3D.gd`, and the 2026-09-02 round that
left it disabled). It was re-enabled 2026-09-08 as "stands correctly, arms
at its sides" -- but that check, by its own admission, "only ever looked at
a bare skeleton's bone positions, never at real attached body meshes."
This round is that missing check: with real meshes on, the animated pose
eats the legs. The bone globals reading correct is exactly why a bone-only
look passed it. Left as a measured finding for the rig lane, not flipped
from here -- the enable/disable toggle has been flipped on screenshots
before, and the honest datum is "rest pose whole, idle pose legless," with
the fault localised to the skinning, not the placement. The equipment
pipeline itself is correct end to end.

## Hundred-and-ninety-sixth round: a slot is a container, and ctx is its key

Last round named the reinforce quad and stopped at one question: does a derived
bind **overwrite** its target's slot or **accumulate** into it? Param 13's slot 0
is written twice -- directly from the weapon's own range, and by propagation from
the Str-derived param 17 -- and which survives decides whether a player's damage
is the weapon alone or the weapon plus a Str term.

**It accumulates.** And getting there explained an argument this project has been
carrying unexplained since the ParamKeeper was first named.

`ParamKeeper_StoreSlot` shows a slot is not a float. It is a container, allocated
on first use, and the value is stored **keyed by `ctx`** -- the third argument of
`ParamKeeper_SetParam(slot, ctx, value)`, which had never had a meaning attached
to it. It is the identity of the contributor, so two sources writing the same
slot each keep their own entry: same key replaces, different keys coexist.

`FUN_004b2e60` reduces a container, and how it combines entries depends on which
slot it is:

```
acc = (slot == 3) ? 100.0 : 0
for each entry:
    slot 3  ->  acc = entry * acc / 100      percentages compound
    slot 2  ->  acc = (entry/100 + 1) * acc  multipliers compound
    slot 0  ->  acc = entry + acc            SUM
    slot 1  ->  acc = entry + acc            SUM
```

So the four slots are base (summed), additive % (summed), multiplier
(compounding) and percent scale (compounding from 100) -- and
`ParamKeeper_EvaluateParam` combines them exactly as this project already had it,
`slot0 * (slot1+100)/100 * slot2 * slot3/100`, with a clamp asserting in
`GParamKeeper.cpp:301`.

**What that means for damage**: a player's physical damage in the real game is
the weapon's range **plus** a term of roughly `Str x reinforce%`. srrevamp's
damage ignores Str entirely.

**Still not shipped, and the gap is now exact rather than vague.** The magnitude
needs one more fact: whether an item's reinforce *replaces* the innate base in
param 34 or adds to it, which the `ctx` keying decides. `GObjPC_InitStats` writes
ctx 0; `Char_PublishCombatStats` passes the stat-source pointer as ctx. Different
keys would mean they sum, giving a Copper Sword user 61.2% reinforce instead of
30.6%. That reads wrong -- so it is written down as the next question rather than
shipped as a formula. Being able to state the objection precisely is the whole
value of having read this far.

## Hundred-and-ninety-fifth round: reinforce, settled by the slot argument

Last round left params 34-37 as a lead: their bases are 30.6 / 34.2 / 49.0 /
54.8, and 30.6/34.2 are exactly a Copper Sword's physical reinforce. I declined
to promote it on one numeric coincidence, and flagged an objection -- the
magical pair did **not** match that same sword.

Both halves resolve, and the thing that resolved them was already on screen: the
**slot argument** to `ParamKeeper_BindDerived`, which I had been reading past.

Every edge in the graph binds at slot 0 (base) *except six*, and four of those
are `34 -> 17`, `36 -> 18`, `35 -> 19`, `37 -> 20`, all at **slot 3** -- the
percent scale, which `ParamKeeper_EvaluateParam` divides by 100. So the engine
itself treats these four as percentages applied to damage, physical and magical
respectively. That is what a reinforce is, stated by the code rather than
inferred from a number.

And the objection dissolves once the right census is run. The bases are not one
weapon's stats: **306 is the floor of physical reinforce across every weapon in
the table** (zero below it) and **490 the floor of magical**. They are the
minimum of each column, taken independently -- which is why the physical matched
the starter sword and the magical the starter blade. An innate baseline being
the table's floor is exactly right, and "a tier-1 sword matching it" was me
looking at the wrong end of the relationship.

So: **34/36 are physical reinforce min/max, 35/37 magical**, and the question
two rounds ago -- the one combat stat the client reads that the server never
exports -- is answered. It lands on the Str/Int-derived damage, as a percentage.

**Nothing is exported or wired from it, and that is the point.** Using reinforce
means knowing whether a derived bind *overwrites* its target's slot or
*accumulates* into it. Param 13's slot 0 is written twice: directly from the
aggregate's `+0x1b8` (the weapon's own range) and by propagation from 17
(Str-derived, scaled by reinforce). Which one survives decides whether a
player's damage is the weapon's range alone or the weapon's range **plus** a
Str-derived term -- a formula change, not a constant.
`Param_PropagateToDependents` settles it and has not been read. Exporting the
columns now would add a field nothing consumes, which is the exact pattern the
last four rounds have been correcting.

## Hundred-and-ninety-fourth round: the stat graph, and a guess of mine refuted

Last round ended with six unnamed fields and a guess: that params 58 and 59 were
the item table's phys/mag **reinforce**, on the strength of their sitting between
the defence block and the damage block. `GObjPC_InitStats` settles it, and the
guess was wrong.

The function declares the whole graph in one place, and `ResolveRegArg`'s
annotations make the edges readable without any inference:

```
1 (Str) -> 17, 18 -> 13, 14   physical damage min/max
1 (Str) -> 21     -> 5        physical flat absorb
2 (Int) -> 19, 20 -> 15, 16   magical damage min/max
2 (Int) -> 22     -> 6        magical flat absorb
58      -> 50 -> 21 -> 5      physical flat absorb
59      -> 51 -> 22 -> 6      magical flat absorb
34, 36, 35, 37 -> 17, 18, 19, 20   into the damage quad
```

So **58 and 59 feed flat absorb** -- a defence stat -- and reinforce is a weapon
stat. The candidates are refuted. The four remaining unnamed fields (34-37) feed
the damage quad instead.

**The three roots check out against the `_CHAR` schema**, which is what makes the
rest trustworthy rather than merely consistent:

```
param 0 = Level   SetParam(0, charData+0x65)   _CHAR.CurLevel
param 1 = Str     SetParam(1, charData+0x74)   _CHAR.Strength
param 2 = Int     SetParam(2, charData+0x76)   _CHAR.Intellect
```

Two real constants fall out: a character's innate **attack rate and parry are
both 10.0** (`.rdata 0x00b45b44`), each with a level-derived binding. srrevamp
models neither stat, so nothing is wired from them.

**And one lead I am deliberately not promoting.** The damage quad's bases,
set before any gear exists, are 30.6 / 34.2 physical and 49.0 / 54.8 magical.
30.6 and 34.2 are *numerically identical* to a Copper Sword's physical reinforce
(306 / 342 in tenths, from the verified tooltip row) -- which would make the
damage quad the reinforce quad and answer the question this round started with.
It stays a lead: a tier-1 sword matching the character's innate base exactly is
as easily authored design as identity, the magical pair does **not** match that
same sword (49.0/54.8 against its 51.9/59.1), and a single numeric coincidence
is exactly the shape of evidence characterdata col 79 was wrong about twice.

## Hundred-and-ninety-third round: an absence inside a measurement window

Applying last round's two-reader check forward -- what does the CLIENT read that
the server never exports? -- turns up exactly one combat stat: phys/mag
**reinforce**, itemdata 105/107 and 109/111, which the client displays as
`"Phy. reinforce 30.6 % ~ 34.2 %"` and `cmd/export-refdata` has never carried.
Everything else the client reads is either exported or purely presentational
(the worn model, the drop model, the name string id).

Chasing where reinforce might land on the server meant finishing
`Char_PublishCombatStats`, and finishing it caught me out.

**The publication is eighteen fields, not eleven.** The pass that first mapped
it cut its disassembly at 220 instructions. Six writes sit past that, and the
last of them is `+0x1dc -> param 12` at `0x00497ef0` -- three hundred
instructions beyond where the reading stopped.

Param 12 is `'cri'`, the critical chance. This project had written down that
`Char_PublishCombatStats` does **not** publish it, and then used that absence to
argue the player's critical must arrive by the item-modifier path
(`Stat_ApplyTaggedModifier`'s `'cri'` tag). It does not. It arrives by the same
route as every other combat stat, published from `+0x1dc` immediately after
`'hra'` attack rate at `+0x1d8` -- exactly where anyone would expect the pair to
sit, had they looked that far.

The shipped behaviour was right the whole time: a player's critical chance is
the weapon's own Critical column, itemdata 116, and that has not changed. What
changes is the citation, and it gets *better* -- the stat now has the same
provenance as parry, blocking and attack rate instead of a special case.

**The lesson is narrow and worth keeping**: a disassembly window is a
measurement boundary, and an absence found inside one is not an absence. This is
the third false negative in this epic from a probe that did not reach far
enough -- after `grep '== 0x'` missing every `!=` branch, and a param census
whose regex required `0x` and so skipped every parameter below ten. All three
read as settled questions.

Six of the eighteen fields are still unnamed -- `+0x1b0` and `+0x1b4` (params
58, 59, with 23 also written from `+0x1b4`) and `+0x1c8`/`+0x1cc`/`+0x1d0`/
`+0x1d4` (params 34-37). `+0x1b0`/`+0x1b4` sit between the defence block and the
damage block and are the obvious candidates for reinforce, which is precisely
why they are recorded as candidates and not as an answer.

## Hundred-and-ninety-second round: the client had been right all along

Last round withdrew `HitRateMax` and `CriticalMax` on tooltip evidence, with the
columns left "unidentified". Both halves of that now have better backing, and
one of them came from a source already sitting in this repository.

**The data side.** A 3,818-row weapon census says these are not proportional
ranges. If column 114 were the hit-rate maximum, `114/113` would be roughly
constant; it clusters at **~2.11** for some weapons and **~1.22** for others.
`117 − 116` is **0** on 1,131 rows, **12** on 927, **13** on 892, then a
scatter. Real ranges in this table do not behave that way -- defence runs
2 → 2.5, block 10 → 20, each a proportional spread.

Worth recording that my first two samples suggested a clean `+12` offset and a
clean `x1.25` ratio, and both dissolved at scale. Two rows are not a census.

**The use-site.** `client/scripts/npc/item_table_reader.gd` -- written from real
tooltips, long before any of this -- reads `COL_ATTACK_RATE := 113` and
`COL_CRITICAL := 116` as single ints and prints `"Attack rate %d"` /
`"Critical %d"`, while reading defence and block as `Vector2` pairs printed as
`"%s ~ %s"`. **It never reads 114 or 117 at all.** That is the independent
witness the withdrawal wanted, and it was in the tree the whole time.

**And the two readers agree on everything else.** This project parses the item
table twice, from opposite ends: the client for tooltips, `cmd/export-refdata`
for the server's CSV. Written at different times for different reasons, they now
pin identical columns for durability, both defences, block, both attacks, attack
rate, critical, required level and the TypeIDs. `ITEM_FORMAT.md` carries the
table.

That makes a disagreement between those two files a **bug signal** rather than a
style difference -- and one had already been caught that way without anyone
noticing: the exporter emitted a literal `"0"` for both defences while the client
had been reading 65/66 and 76/77 correctly all along. A Cotton Suit's tooltip
showed its real defence while the server treated the character as wearing
nothing, and the two files disagreeing was the evidence.

## Hundred-and-ninety-first round: a max that was never a max

The reachability sweep has one more kind of answer in it: not "this value never
arrives" but "this value arrives wrong".

`cmd/export-refdata` read the weapon's attack rate and critical as min/max
*pairs* -- columns 113/114 and 116/117 -- on the reasonable assumption that they
work the way physical defence does. The table this project already verified says
otherwise. A Copper Sword reads **24** at col 113 and **30** at 114, **3** at
col 116 and **15** at 117, and its +5 tooltip showed *"Attack rate 24"* and
*"Critical 3"* -- single values. A real maximum would have displayed as a range,
the way physical attack does (`27 ~ 28`).

So columns 114 and 117 are something else, unidentified. They are no longer
exported: `HitRateMax` and `CriticalMax` are zero now, and the column positions
stay so the CSV width is unchanged. Nothing reads either field today, which is
exactly why this was worth doing before something did -- a mislabel is a
landmine for whoever reaches for it next, and 15 is five times a Copper Sword's
real critical. `CriticalMin` (col 116) and `HitRateMin` (col 113) are the
verified tooltip values and stay.

**And a deliberate inconsistency, written down rather than churned.** A real
item has per-instance variance -- the table gives a range and each instance sits
inside it -- and srrevamp models none, so every consumer picks an end.
`defenderArmor` takes `PhysDefenseMax`, `defenderBlock` takes `BlockRatioMin`,
and neither end is more correct than the other. Making armour match would move a
displayed stat and a shop price for no grounded reason, so it stays as it is and
`refdata.Item` now carries the record that the difference was examined rather
than missed.

## Hundred-and-ninetieth round: PvP had been left behind, and why

Two rounds of asking "does this recovered thing actually reach anything?" found
a value that was never exported and four the client threw away. The same
question asked of the *duel* path finds the biggest one yet.

`handleDuelAttack` computed `damage := base - armor`. A bare flat subtraction --
no `/(1 + pct/100)` mitigation shape, no critical, no block, no level term. The
grounding audit meanwhile said PvP *"reuses the same combat model ... no separate
formula"*, which had been true when it was written and had quietly stopped being
true six recoveries ago.

**The cause was duplication, so the fix is one function.** `combat.ResolveBlow`
now runs every blow in the game -- a player hitting a monster, a monster's
counterattack, and one player duelling another -- in the order the engine runs
them:

```
a successful BLOCK skips everything (the real resolve function jumps past
  every Formula_Mitigate* call, so no damage is computed at all)
otherwise  mitigate:  damage / (1 + pct/100) - flat
then       multiply:  x2 on a critical
then       scale:     the level-difference term, last
```

Berserk deliberately stays outside it: that is per-character state the combat
package does not hold, and the caller that has it applies it between the
critical and the level term, which is where the engine has it.

So duels crit and get blocked now, with real inputs on both sides -- a weapon's
Critical column and a shield's block ratio, both players, both real levels. The
duel result carries the two outcomes as appended fields, and a 9-byte result
from an older server still decodes without inventing them.

`Monster.Block` came along with it, characterdata col 76. It reads **0 for every
species on the Jangan ladder**, which is the real value and not an unmodelled
one: blocking is a shield mechanic and monsters carry no shields. 938 of the
game's other monsters do read 20.

**Two silent no-ops in one round, both of the same family.** The first heredoc
that was meant to add `ResolveBlow` was written as `cd server && cat >> ...` from
a directory that was already `server`; `cd` failed, `&&` short-circuited, the
function was never added -- and the `go build` that followed printed `BUILD-OK`
on an unchanged file. Last round's was a string replace that matched nothing.
Both produce a confident success message over work that did not happen. Every
edit in this round asserts its own effect before moving on, and the one that
mattered was caught by the compiler two commands later rather than by a release.

## Hundred-and-eighty-ninth round: four recovered mechanics nobody could see

Last round caught a value that never reached production. The same question asked
of the other side of the wire turns up four more.

`AttackResult` has carried `MonsterCritical`, `PlayerCritical`, `PlayerBlocked`
and `DeathExpLost` for several releases. **The client decodes none of them** --
its own `AttackResult` class stops at `berserk_active`. So criticals doubled
blows, shields stopped hits dead and dying cost experience, and a player saw a
plain damage number for all of it. `player_died` turned out to be worse: decoded
since the first combat release and read by nothing, so death itself was silent.

All five are decoded and shown now. A critical says `CRITICAL!`, a block says
`Blocked it` rather than a damage figure, and a death says what it cost:

```
Hit for 60 CRITICAL! (440 HP left). Blocked it (HP 200).
You were killed. Lost 25900 experience.
```

The decoder takes each field at its own width, because each was appended in its
own release: an 18-byte result, a 23-byte one with the berserk tail, then 31,
32, 33 and 34. The client test now walks **every one of those widths** and
asserts the shorter ones report *absence* rather than a truncated field read as
a real value -- the failure mode that matters when an older server meets a newer
client.

Verified by booting the real scene rather than by a parse check: `load()` on
`World3D.gd` succeeds even when compilation aborts early on a missing autoload,
which is not proof of anything. A real `qa_shot` boot reports zero script errors
and a loaded region grid.

## Hundred-and-eighty-eighth round: the edit that silently did nothing

Last round shipped `TwoHanded` as recovered and wired, with a tagged release
saying so. **It never reached the exporter.** The edit that was meant to map
column 93 matched nothing — the replacement text had the wrong indentation, and
a silent no-op is what a non-matching string replace does. So `fTwoHanded = 93`
sat defined and unused, the equipment rule that depends on it was inert in every
real deployment, and the build was perfectly happy: Go objects to an unused
local, not an unused const.

Nothing caught it. The round-trip test only checked the record's WIDTH, and the
new column test only checked defence and block. Both passed.

Fixed, and now pinned by a test that was **verified to fail without the fix** --
reverting the one line produces `TwoHanded = false, want true` -- because a test
that passes either way is worth nothing. Every edit in this round asserts its own
replacement matched before writing the file.

**Column 61 is `ItemClass`**, and it was the last placeholder in the item
exporter that anything actually reads -- it flows through the shop listing and
out to the client, where it had been a constant 0.

Derived from the ORDER of the server's own deserialiser rather than by
pattern-matching the data. `RefObjItem::ExtractData` reads fields consecutively
off the row -- `+0x198` (4 bytes), `+0x19c` (1), `+0x1a0` (4), `+0x1a4` (4),
`+0x1a8` (1) -- and `+0x19c` is confirmed as `ReqGender` by
`CGPCInventoryOP::CheckEquipsetIntegrity`, which compares it to the character's
`GetGender()`. This exporter already pinned 57/58/59/60 as
MaxStack/ReqGender/ReqStr/ReqInt, exactly those four in exactly that order, so
the next field is column 61 -- a one-byte read, matching `m_btItemClass`.

Checked against the binary's own assertion, not a curve: `ExtractData` asserts
*"ItemClass must be not zero"* / `m_btItemClass > 0`, and column 61 is non-zero
on **all 21,552** equipment rows.

The sweep is otherwise finished. Every other `"0"` placeholder left in either
exporter -- `FlyingSpeed`, `Interruptable`, `Overlap`, `AutoAttackType`,
`Basic_Name`, `Basic_ChainCode`, `Basic_RecycleCost` -- has **zero readers**
anywhere in the server, so a wrong value there cannot reach anything. They stay
as they are, now for a measured reason rather than an unexamined one.

## Hundred-and-eighty-seventh round: both hands are on your weapon

Shipping shield blocking last round quietly made a dormant gap load-bearing.
Nothing stopped a character equipping a two-handed sword *and* a shield -- and
with no blocking that was only a drawing mistake, while with blocking it is free
damage avoidance. `equipment.TwoHanded` existed as a field, was exported as a
literal `"0"`, and nothing in the server read it.

**Itemdata column 93 is `TwoHanded`.** A clean 0/1, **constant within every
weapon kind** (`TypeID4`) and 0 on all 511 shield rows. Found by diffing a known
one-hander (Copper Sword) against a known two-hander (Crescent spear), which on
its own is only a suggestive column -- so it was settled against a source that
knows nothing about this table: the **client's own weapon-to-animation-group
switch**, recovered in the hundred-and-thirty-third round from a different
binary by a different route. That table names five kinds outright, and column 93
agrees with every one:

```
TypeID4  7      -> onehand_sword   col93 = 0
TypeID4 10, 15  -> onehand_staff   col93 = 0
TypeID4  8      -> twohand_sword   col93 = 1
TypeID4 11      -> twohand_staff   col93 = 1
```

Five for five. The rest fall out consistently -- spear, glaive, bow, axe,
crossbow and harp read 1; blade and dagger read 0.

So the column is exported now, and `equipment.TwoHandedConflict` refuses a
shield onto a two-handed weapon and a two-handed weapon onto a worn shield. It
lives beside `equipment.Refusal` rather than inside it because it is the only
rule that depends on what is ALREADY worn rather than on the incoming item
alone. The real game gives the shield its own slot 7 -- the same index this
package already used, confirmed in `CGPCInventoryOP::CheckEquipsetIntegrity`,
which tests `local_c != 7` for exactly that slot.

An unknown worn item is treated as occupying its slot but not as two-handed:
it cannot be *shown* to need both hands, so it blocks nothing, but it still
fills the shield slot, which is what the weapon case needs.

## Hundred-and-eighty-sixth round: armour was doing nothing, and now shields block

Blocking was left unshipped last round for a stated reason: a player's block
chance is a shield's block ratio, and this project's curated item export had no
such column. That was a self-imposed limit, not a data one -- and going to lift
it turned up something worse sitting next to it.

**`cmd/export-refdata` was emitting a literal `"0"` for both armour defences.**
The line carried the note *"armour, not verified"*. That note stopped being true
when `docs/protocol/ITEM_FORMAT.md` grounded those columns three ways -- the real
`_RefObjItem` column order, the heavy-vs-cloth characteristic, and a real +5
tooltip -- and the exporter was never revisited. So **every deployment that
imported through this tool gave armour no defence at all**, while
`defenderArmor` dutifully read the zeroes. Both defences are now exported from
their verified columns: physical 65/66, magical 76/77.

The same pass adds the shield's block ratio at 74/75 as an appended optional
column, the pattern every earlier addition used (Price/SellPrice, then the
Param-block restore amounts), so an export made at any older width still loads
and simply blocks nothing.

**So shields block now**, and a blocked hit deals nothing. That is not a design
choice: on a successful roll `Combat_ResolveDamage` falls through to
`JZ 0x005905fb`, which lands past **all four** `Formula_Mitigate*` call pairs
(`0x58f15d`, `0x58f2fb`, `0x58f7ea`, `0x58f9b2`), so no damage is ever computed
and the damage record keeps its zero-initialised `+0x28` physical, `+0x24`
magical and `+0x20` total. A *failed* block jumps to `0x58f739`, before the third
pair, and resolves normally. The roll comes before mitigation in this code for
the same reason: mitigation is precisely what it skips.

The block is unopposed against monsters, and that is measured rather than
assumed -- the real chance divides by `(1 + the attacker's 'evbl'/100)`, and
`GObjMob_PublishStats` publishes params 0, 3-12, 23, 24, 27-33 and 140, with
param 56 not among them.

The export width guard earned its keep: `TestItemRecordRoundTripsThroughTheImporter`
failed immediately on the new columns because the exporter and importer had
drifted apart, which is exactly the drift it exists to catch. A new test pins the
six defence/block values through a full export-import round trip with a Cotton
garment's real readings (2~2.5 physical, 4.3~5.2 magical) and a starter shield's
10~20 -- the check that would have caught the zeroed defences years earlier.

## Hundred-and-eighty-fifth round: the player crits too, and I was wrong yesterday

Last round ended "the player never crits: param 12 is not among the fifteen
`Char_PublishCombatStats` publishes, and comes from the item stat-tag path this
project does not model." The first half is true. The conclusion is not.

`Stat_ApplyTaggedModifier` maps the tag `'cri'` to param 12, and that is the
item-modifier path -- which is exactly where a **weapon's Critical column
(itemdata 116)** goes. That column was verified against a real +5 tooltip two
epics ago (a Copper Sword reads 3; the tooltip showed 3) and has been loaded as
`refdata.Item.CriticalMin` ever since, with nowhere to spend it. The input was
already on disk. Checking one route and concluding about all of them is the
mistake, and it is the same shape as the greps recorded in the tooling README:
an absence found by looking in one place reads exactly like an absence.

So the player crits now, at the weapon's own chance, doubling the blow. It is
unopposed against monsters and that is not a simplification: the real chance
divides by `(1 + the target's 'evcr'/100)`, and `GObjMob_PublishStats` publishes
params 0, 3-12, 23, 24, 27-33 and 140 -- param 57 is not among them.

**Blocking is fully recovered and deliberately not shipped.** A blocked hit
deals *nothing*, and the control flow proves it rather than a comment asserting
it: on a successful roll execution falls through to `JZ 0x005905fb`, which lands
**past all four** `Formula_Mitigate*` call pairs (`0x58f15d`, `0x58f2fb`,
`0x58f7ea`, `0x58f9b2`), so no damage is ever computed and the record's `+0x28`
physical / `+0x24` magical / `+0x20` total keep their zero-initialised value. A
*failed* block jumps to `0x58f739`, before the third pair, and resolves normally.

The disassembly also showed how one roll function serves two chances:

```
0058f0c8  MOVZX EAX,byte ptr [EBX + 0xe]   ; the BLOCK chance
0058f0d2  OR ECX,0x42000000                ; 'B'
0058ed8c  MOVZX EAX,byte ptr [ESP + 0x2f]  ; the CRITICAL chance
0058ed97  OR ECX,0x43000000                ; 'C'
```

The key byte is what the bad-luck accumulator is stored under, so blocks and
criticals get independent streak protection -- and it settles, rather than
assumes, that the block roll takes the block chance.

Not shipped because of the *input*, not the mechanic: a player's block chance is
a shield's block ratio (itemdata cols 74-75, 10~20, on exactly the 500 shield
rows) and srrevamp's curated item export has no such column, so wiring it needs
a schema change the operator's existing exports would not satisfy. The monster
side would never fire either -- every Jangan-ladder species reads 0 for col 76,
though 938 other monsters carry 20.

## Hundred-and-eighty-fourth round: criticals, and the dice behind them

The standing item read "crit/block/hit rolls -- values recovered, dice not".
The dice are recovered, and monsters now crit.

`FUN_00599cc0`, reached through `FUN_005a1a20` from `Combat_ResolveDamage`, is
the game's chance roll for both criticals and blocks:

```
chance == 0     -> fail, no roll taken
chance >= 100   -> succeed, no roll taken
otherwise       -> succeed when chance >= rand() % 101
```

Inclusive at both ends -- the modulus is `0x65`, not 100 -- so a chance of 100 is
a certainty rather than a 100-in-101 near-certainty.

**A critical doubles.** `Formula_MitigatePhysicalDamage` builds a multiplier,
1.0 normally and `GetParam(189) + 2.0` for a berserk attacker, then does
`if (flags & 2) multiplier += multiplier` before multiplying the
already-mitigated damage by it. Bit 1 is set by `Combat_ResolveDamage` when the
critical roll succeeds, so an ordinary critical turns 1.0 into 2.0 -- and a
berserk critical is 4.6x, because it doubles whatever the multiplier already is.

**The monster's chance is characterdata col 78.** Settled by disassembling
`GObjMob_PublishStats`, which publishes the ref-object's fields into ParamKeeper
params in a consecutive 4-byte run:

```
+0x230 -> 5    +0x234 -> 6    +0x238 -> 7    +0x23c -> 8
+0x240 -> 9    +0x244 -> 10   +0x248 -> 11   +0x24c -> 12 ('cri')
```

Two of those offsets were already proven -- +0x230 is col 71, the flat absorb,
and +0x238 is col 73, the reduction percentage -- which anchors the whole run
onto columns 71..78 and puts the critical chance on col 78. The data then agrees
four independent ways: cols 73 and 74 equal the monster's level *exactly* on
every row; cols 75 and 77 are identical (`25 + 2*level`); col 76 is 0 for every
monster on the Jangan ladder, which is right because blocking is a shield
mechanic; and col 78 reads **2 on 7,493 of the game's 7,495 monster rows**. The
two rows that differ (0 and 20) are what prove it is a real column rather than a
shared default, which is why it is carried per-species rather than hardcoded.

Not modelled, and disclosed: the real roll also keeps a per-actor accumulator,
raised by `chance` on every miss and dropped by 100 on every hit, and compares
*that* on subsequent rolls instead of the raw chance -- bad-luck protection.
srrevamp rolls memorylessly, so its criticals are streakier than the game's,
never more or less frequent on average. And the player never crits: param 12 is
not among the fifteen `Char_PublishCombatStats` publishes, and comes from the
item stat-tag path this project does not model.

**A bug this nearly shipped, caught by the test.** `internal/session`'s
`TestMain` sets the shared generator to **nil** on purpose, because
`RollDamage(min, max, nil)` returns the maximum and lets the flow tests assert
exact numbers. My `RollChance` had taken nil to mean "never succeeds" -- the
opposite convention in the same package -- so every critical in every session
test was silently impossible, and the end-to-end test failed with a chance of
100. Aligned to the package's own rule: nil takes the maximum outcome. Getting
this backwards fails quietly, which is the dangerous direction.

Also fixed while in the file: inserting the level-advantage block two rounds ago
had been done *above* `func MitigateDamage`, which detached that function's
entire doc comment from it and left it attached to a `const` block. Reordered.

## Hundred-and-eighty-third round: the game does not define an unarmed attack

`unarmedDamage = 5` was the last value in the grounding audit carrying no reason
at all -- just "Own [design]." It has one now, and it is an absence established
by enumeration rather than by failing to find something.

Damage reaches the engine as params 190/191, published from the equipment
aggregate; the numbers live in a skill's `'att'` parameter, which is how a
monster's attack was recovered. An unarmed player would therefore need a base
attack skill with **no weapon type** -- and there is none. Every `_BASE_01`
attack skill in the game is weapon-typed, all twelve:

```
CH   SWORD(2)      SPEAR(40)      BOW(70)
EU   SWORD(8419)   TSWORD(8420)   AXE(8421)    CROSSBOW(9354)  DAGGER(9355)
     STAFF(9944)   WAND_WARLOCK(10625)  HARP(11162)  WAND_CLERIC(11526)
```

The state exists visually -- the client's own animation-group table, recovered
in the hundred-and-thirty-third round, has index 0 `default` for an empty hand
-- but nothing in the data gives it a damage value. So 5 is a number this
project must invent to have a fight, not one it failed to find.

**A trap caught on the way, and it nearly shipped.** Player rows in
`characterdata` read `[83]=1 [84]=2 [85]=40 [86]=70`, where a monster row has 0
in both of the last two. Read as numbers, `[85]/[86]` is a tidy 40~70 damage
range sitting exactly where an unarmed attack ought to be. It is nothing of the
kind: those columns hold **base-attack skill ids**. 2 / 40 / 70 resolve to
precisely the three Chinese base skills, and a European row reads
8419 / 8420 / 8421 -- consecutive ids in the thousands that nobody would mistake
for damage. Checking a second race is what refuted it; the single-race reading
was entirely plausible and entirely wrong.

Two stale rows in the grounding audit were corrected at the same time. **Monster
spawn positions** still said "own design, clustered at two farmland anchors
(region 96/168)" -- Mangyang's are real `npcpos` rows as of v0.1.161, and the
anchors are region **97/168**, a label this project got wrong for as long as they
existed. **Inventory size** now carries its proven reason: the starting size is a
`_CHAR.InventorySize` row, not a constant in the exe, and the binary gives only
the ceilings (77 normally, 99 under a predicate, hard cap below 100) plus the
fact that the general inventory begins at index 13 after 13 equipment slots.

And the `__FILE__` source-path lever is **exhausted, not open**: 164 distinct
source paths in the client and 50 in the server, with 444 of 446 client and 166
of 166 server functions already namespaced. Recorded so no later tick re-runs it
hoping for yield.

## Hundred-and-eighty-second round: a player's armour has no percentage, and that is the answer

The last combat value the grounding audit listed as untraced was the player's
own mitigation percentage. It is settled, and the answer is **zero** — recovered
as zero, not assumed.

Param 7 has exactly **three** writers, and none can set it for a player:

```
GObjMob_PublishStats     004c3730   mobs only (characterdata col 73 = its level)
Char_PublishCombatStats  00497830   from the _RefObjItem defence block -- and no
                                    percentage-reduction column is populated on
                                    ANY of the 21,560 item rows
skill-effect applier     00594ac0   only via the skill param code 'ar', which
                                    appears on ZERO of 29,342 skill rows
```

`'ar'` is `SkillGlobal::RefSkill_ParseParams` writing `skill+0x268` as a 3-word
run, published into params 7 and 8. Its single numeric hit in the skill table
turned out to be a skill's **own id column**. The mechanism exists; nothing
shipped uses it.

**What makes this convincing rather than merely absent** is where the *live*
defensive codes go instead:

```
'defp'  273 skills   skill+0x25c   -> params 5/6 slot 0   the FLAT absorb
'defr'    4 skills   skill+0x260   -> params 5/6 slot 1   a % boost to the flat
'ar'      0 skills   skill+0x268   -> params 7/8 slot 0   the reduction %
```

Defensive buffs raise your flat absorb. They never touch the percentage. So the
asymmetry this project already had — monsters carry a percentage, players do not
— is the game's own design, and `playerMitigationPercent` now says so as an
explicit cited `0` routed through the same `combat.MitigateDamage` the monster
side uses. No number changed; the zero stopped being a coincidence.

**Two mistakes inside this round, both producing false negatives.** The first
census said `'defp'`, `'defr'` and `'heal'` appeared on zero rows — because the
multi-char constants were worked out by hand and were wrong (`'defr'` is
1684366962, not 1684366450); recomputed, `'defp'` is on 273 skills. And the code
list was harvested with `grep '== 0x'`, which misses every branch MSVC emits as
`!=` — `'ar'`, the one code the whole question turned on, is exactly such a
branch. False negatives are the dangerous kind here: an absent value looks
exactly like a settled question.

## Hundred-and-eighty-first round: where a player's combat stats come from

`Char_PublishCombatStats` (`00497830`) publishes fifteen ParamKeeper params from
fifteen consecutive float fields. Every one of those calls decompiles to the
same line — `ParamKeeper_SetParam(0, piVar1, param_1)` — because both the id and
the value ride in registers, so the map only exists in the disassembly:

```
+0x198 -> 5           physical flat absorb
+0x19c -> 9           'era'  parry rate
+0x1a0 -> 7           physical reduction %
+0x1a4 -> 10          'bri'  blocking rate
+0x1a8 -> 6           magical flat absorb
+0x1ac -> 8           magical reduction %
+0x1b8 -> 13 AND 191  physical damage min
+0x1bc -> 14 AND 190  physical damage max
+0x1c0 -> 15 AND 193  magical damage min
+0x1c4 -> 16 AND 192  magical damage max
+0x1d8 -> 11          'hra'  attack rate
```

**Params 13/14 and 190/191 are the same two floats.** Two rounds ago this
project found two different damage rolls — `Formula_RollWeaponDamage`'s uniform
`rand() % (max-min+1) + min` on 190/191, and the centre-biased min-of-three roll
on 13/14 — and could not say how they related. They read an identical range;
they differ in distribution alone.

**The defence block decodes two columns the schema calls undecoded.** It runs
PD, ER, PAR, BR, MD, MAR at consecutive floats, exactly the `_RefObjItem` order
`refdata_schema.md` records, and two of them land on params the *client* names:
ER on 9 (`PARAM_ER` = "Parry rate") and BR on 10 (`PARAM_BLOCKING`). Those
anchors bracket PAR onto param 7 — the physical reduction percentage — and MAR
onto 8. It is an ordering argument with a named anchor on each side, not a
use-site on PAR itself, and it is written down at that strength.

**Nothing shipped from it, and that is the point.** Whether a player's param 7 is
ever non-zero is still open: the fields come from an object whose class is
unidentified (it is *not* `CRefObjChar` — that has `uint8 Lvl` at 0x198, read
here as a float). A census of all 21,560 item rows finds no populated
percentage-reduction column anywhere — only the PD and MD triples, the
non-shield pair at 68–69, and the shield block ratio at 74–75, with columns 70
and 88–90 zero on every row. That is suggestive that gear grants no percentage
mitigation, and suggestive is precisely what this project does not ship. The
player stays on the flat term.

Corrected on the way: `ITEM_FORMAT.md` had the armour defences as **pairs**.
They are **triples** — 65/66/67 and 76/77/78 are populated on exactly the same
10,163 rows. The third value scales with tier alongside min/max (heavy body
armour tiers 1→5 read 0.4, 0.6, 0.8, 1.0, 1.3 against physical defence
2.5→27.5) but not as a fixed fraction of either, so its shape is recorded and
its meaning is not.

## Hundred-and-eightieth round: dying costs something now

srrevamp had no death penalty at all — a killed character had its HP reset and
walked away. The real one is recovered and shipped.

`GObjPC_OnDeath` (`004e6980`) gates the whole penalty on
**`10 < Char_GetLevel(victim)`** — levels 1–10 die free — and then multiplies
the level's EXP unit by one of four constants:

```
killed by a MONSTER   normal      unit * 100     no SP loss
                      PK-flagged  unit * 300     60 SP
killed by a PLAYER    normal      unit *  20     no SP loss
                      PK-flagged  unit * 100     20 SP
```

The loss is clamped (the block's own CLAMP assert spells the minimum as `1.0`,
and names the source file: `D:\WORK2005\Source\SilkroadOnline\Server\
SR_GameServer\GObjPC.cpp` line 6168), reduced by a stat this project has not
resolved, and applied through `GainExpAndLevel` — vtable slot `0x170` = 92, the
same function that *grants* experience — with a **negative** 64-bit amount.
Nothing in the block touches `CurLevel`: a death never costs a level.

**The EXP unit is the same field a kill is paid from**, and that is not an
assumption. `Formula_MonsterExpReward`'s disassembly reads the identical
`levelTable[lvl]+0x1c`, and in the same handful of instructions also shows the
minimum-level rule (`CMP EBX,EAX / JLE / MOV EBX,EAX` across two
`Char_GetLevel` calls) that `leveldata.KillExp` already implements. One
function confirmed both the field and a rule recovered separately.

It also resolves half of the long-standing `pc[0x72d]` item: that byte (victim
+0x1CB4) is compared against **5**, and gates the harsh branches *together
with* `charData+0xb4` = `PKPenaltyPoint` from the recovered `_CHAR` schema.
What the state enum means is still unrecovered, so the branches are labelled by
the condition that can be named.

**What it costs, checked against the ORIGINAL client's own `leveldata.txt`**
(identical to the pserver's at every level sampled, so not a private-server
edit — only level 110's exp-to-next differs, a pserver cap edit):

```
lvl  11   74.2% of a level      lvl  50    1.9%
lvl  20   16.7%                 lvl  90    0.2%
lvl  30    6.1%                 lvl 110    ~0%
```

Steeply regressive: brutal the moment the level-10 grace period ends, shrugged
off at cap. That shape is the game's, not a choice made here.

Only the monster branch is reachable — srrevamp has no PK system — so the other
three are implemented, tested and disclosed as unreachable rather than left
out. The reduction stat is read through a register-passed ParamKeeper id this
code has not resolved and is **left out rather than guessed at**, which makes
srrevamp's penalty a strict upper bound on the real one.

## Hundred-and-seventy-ninth round: what "attack rate" actually does

The open item read "crit/block/hit rolls — values recovered, dice not". The
dice are recovered now, and the surprise is that **attack rate is not a
hit/miss roll at all**.

`Formula_MitigatePhysicalDamage` opens by calling `FUN_0040dce0`, and that is
where a blow's size is decided:

```
lo, hi  = GetParam(13), GetParam(14)     each scaled by (1 + bonus%/100)
centre% = clamp( ((hra/era) * 0.5 + levelTerm) * 100 , 10 , 90 )
p       = min(u1, u2, u3)                ui = rand()/32767 * 100
damage% = centre% ± p                    fair coin, then clamped to [0, 100]
damage  = lo + damage%/100 * (hi - lo)
```

`hra` is param 11 (**attack rate**) on the attacker and `era` is param 9
(**parry rate**) on the defender — the two stats the client's own
`textuisystem.txt` named for us two rounds ago. So the attacker's attack rate
against the defender's parry sets **where in the weapon's damage range the blow
lands**, clamped so it is never below 10% nor above 90% of the range. Missing
is not modelled here at all.

The excursion `p` is the **minimum of three uniform samples**, which is heavily
biased toward zero — so blows cluster near the centre and only occasionally
reach the ends. The distribution is not uniform.

`_DAT_00b45af8 = 32767.0` is `RAND_MAX`, which is the check that this reading is
right: `rand()/32767 * 100` is a uniform percentage, and that only makes sense
if every other constant in the expression has been read at the right width.
The clamps are floats 10.0 and 90.0; the `hra/era` scale is the double 0.5.

**Nothing was rewired from this**, deliberately. This is a *second* roll, on
params 13/14, distinct from `Formula_RollWeaponDamage` (uniform,
`rand() % (max-min+1) + min` on params 190/191) which is what this project's
`combat.RollDamage` already implements correctly and which `Combat_ResolveDamage`
also calls. srrevamp has no attack-rate or parry-rate stat, so porting the
centre would mean inventing its only input.

**One piece of it was wireable, and is now wired.** The same formula ends with

```
if defLvl < atkLvl { damage = (levelTerm + 1.0) * damage }
levelTerm = clamp((level(ECX) - level(EDI)) * 0.03, 0, 0.3)
```

so out-levelling the target is worth **+3% a level, capped at +30%**. Which
object is the attacker was settled on the disassembly (`SUB ESI,EAX` after two
`Char_GetLevel` calls) plus an independent fact: the other object is the one
supplying defence params 5 and 7, which this project already established are
the *target's* (cols 71/73 via `GObjMob_PublishStats`). Applied last, after
mitigation and after the berserk multiplier — and applied in both directions,
since a monster is the attacker in its own counterattack.

Guarded on both levels being non-zero: a zero means "not set", not "level
zero", and without that guard a level-1 character would collect a 3% bonus
against every fixture whose level was simply never filled in.

## Hundred-and-seventy-eighth round: berserk doubles the blow, and always did

Berserk's damage was `+50%`, this project's own disclosed design, because three
sessions of grepping for "berserk" found nothing. It is called **Hwan**
internally. With the RTTI class names in place the whole chain reads straight
through, and every link is a named function:

```
CGObjChar::SetBerserk   slot 198  0x004a9fc0   writes the flag at (*(this+0x30))+3
CGObjChar::IsBerserk    slot  64  0x004aa5b0   reads that same byte
Combat_ResolveDamage              0x0058e5f0   sets damage-flag bit 2 when the
                                               ATTACKER IsBerserk()
Formula_MitigatePhysicalDamage    0x0040e450   multiplier = GetParam(189) + 2.0
Formula_MitigateMagicalDamage     0x0040e830   (instead of the usual 1.0)
```

The setter and the predicate touching the *same byte* is what ties the pair
together — neither alone would have been more than a suggestive name.

**×2 exactly.** The 2.0 is the double at `.rdata 0x00b45f30`. Its two
neighbours in the same block are `0x00b45af0 = 100.0` and `0x00b45ac0 = 1.0` —
the two constants of this engine's already-confirmed `/(1 + p/100)` idiom — so
the width is settled, not assumed. All three read as `0.0` at float width
because a double's low word is zero, and the float reading is incoherent
anyway: it would make a berserk attacker deal *no damage at all*.

**The order was wrong too, and that mattered.** This code boosted the raw
weapon roll and carried a comment saying that was "the order the real formula
implies". It is not. The real formula divides by the percentage term, subtracts
the flat term, clamps at zero, and *then* multiplies. The two differ whenever
the flat term is non-zero — `2*(d/(1+p) - f)` against `(2d)/(1+p) - f` — and
the old order quietly scaled the defence away and over-paid berserk. Fixed.

Left alone deliberately: param 189 is a separate berserk-damage **stat** that
adds on top of the 2.0 (`SetBerserk`'s fifth argument grants it a base 0.3,
float at `0x00b45b8c`), but every call site in the binary bar one passes 0
there. So 2.0 is the plain case, 2.3 the special one, and the stat is not
modelled rather than folded in at a guessed rate. The duration stays own
design and is now known to be genuinely unrecoverable from this function:
every call site passes `0xff`/`0` for its state-change slot and float duration,
so the real server keeps that timer somewhere else.

Fell out on the way: the tag→param vocabulary nearly doubled, harvested by
grepping the 21 tag dispatchers for `in_EAX == 0x…` beside `ResolveRegArg`'s
own annotations — `'dara'`→174-177, `'drua'`→128-130, `'hpmp'`→25,26,
`'rals'`→27-32 (recorded as 27 alone before), and `'DABR'`/`'SPDU'`, the two
tags a `CRefHWANLevel` row's effect list is built from (`{uint32 tag; uint8
value}` pairs).

## Hundred-and-seventy-seventh round: a monster standing where the game put it

Mangyang no longer stands on an anchor this project invented. It stands on its
four real `npcpos` rows — the client's own placement table, 12,367 rows across
1,451 regions — in region 96/168, the farmland immediately south of Jangan.
Those four rows are that region's *entire* npcpos content, all four are id
1933, and `characterdata` gives 1933 as `MOB_CH_MANGNYANG` at level 1 with 54
HP: the same species and the same two numbers the roster already carried,
reached by a different route.

**The conversion was wrong, and only measuring it found that.** The recorded
region→world transform had been *derived* from the region layout. Measured
against the client's own region group nodes at eleven columns, it has the wrong
sign on Z:

```
worldX = (ry − 168)·1920 + (localX − 960)
worldZ = (97 − rx)·1920 + (960 − localZ)
```

World Z is mirrored — local z runs opposite to world Z inside a region, *and*
the region-to-region step runs opposite too, so the two cancel and regions
still tile without a seam. World X has no such mirror, so both axes were probed
in both directions rather than one being assumed from the other: `97/169` →
`(+1920, 0)`, `97/167` → `(−1920, 0)`, `98/168` → `(0, −1920)`, `96/168` →
`(0, +1920)`. The derived formula predicted `(130, −1560)` for the first real
row; the measurement is `(130, 2280)`. That monster would have spawned 3,840
units away, on the far side of the town. The origin was wrong too: it is the
centre region's geometric centre, local (960, 960), not `ZONE_SPAWN_LOCAL` —
the client *moves* the player to the landing spot afterwards.

**The check that passed was incapable of failing.** The transform had been
sanity-checked by "distance from town rises with monster level", and it does.
But the old Z is exactly `−(true Z) + 900`, and a sign flip applied to both the
monster and the reference point preserves every distance between them. The
table was an isometry of the right answer. It looked like evidence and was not
— the cleanest example yet of why a suggestive curve never promotes a value.

Two independent checks did hold. The formula reproduces, exactly, the two
anchors this project's monsters already stood on — `(0, −840)` and
`(340, −340)`, derived by an unrelated route in an earlier session. And doing
so revealed those anchors are in region **97/168** at locals (960, 1800) and
(1300, 1300), not 96/168 as `main.go` had said for as long as they existed; no
local position in 96/168 maps to either. The coordinates were right, the region
label was wrong.

Walkability was measured before anything was wired, which is why this sat a
tick. Each of the four columns reports exactly one surface, its landing height
equal to the terrain height within 0.05, no blocking edge within 40 units, and
the nearest navmesh cell of any placed object 174 units or more away — open
field, nothing to spawn inside or on top of. Their authored heights disagree
with the measured terrain by 11–41 units and are dropped: the client resolves
standing height from the walkable graph and ignores the authored y.

`SRREVAMP_QA_COLUMNS` grew an `rx/ry@x,z` form to make any of this askable —
it could previously only report the region the player was standing in, and a
spawn point's world coordinate can only come from its own region's group node.
Its print also now names the region the frame is centred on instead of calling
the pair "the server's coordinates", which is true only when the grid happens
to be built around the zone's own centre.

The transform lives in `server/internal/worldmap` with all eleven measured
columns as its tests; the roster stores the npcpos rows verbatim so the
grounded fact is what is in the source. The other ten species' real regions are
known but unmeasured, and most sit beyond the radius-2 grid the town loads.

## Hundred-and-seventy-sixth round: a player's health was never a constant

`MaxHP = 100 + 40*(level-1)` is gone. The real one is

    MaxHP = Str * 10 * 1.02^(level-1)
    MaxMP = Int * 10 * 1.02^(level-1)

recovered whole from `SR_GameServer.exe`, and it closes the oldest open item in
`docs/RE_COMPLETION.md`.

Why it stayed open for three sessions is the interesting part, because the
ledger's own "next probe" was aimed at something that does not exist. It said:
find the `FUN_004b3510(0, ...)` push that fills slot 0 for the hp/mp params.
There is no such push. The base never arrives as a value at all.

`GObjPC_InitStats` does not compute stats. It **declares a graph** -- 30 edges,
each one `ParamKeeper_BindDerived(source, target, slot)` -- in a class the
binary names itself in an assert: `GParamKeeper.cpp`. Health is a chain:

    Str(1) -> 52 -> 54 -> MaxHP(3)

with `1000.0` pushed into slot 3 of param 52 and `1.02^(level-1) * 100` into
slot 3 of param 54. A node evaluates as `slot0*(slot1+100)/100*slot2*slot3/100`
with slot 3 defaulting to 100, so the chain collapses to
`Str * (1000/100) * 1.02^(level-1)`. **The base was the stat all along**, which
is why looking for a constant found nothing. At the starting Str of 20 that is
200 health at level 1 -- close enough to a plausible constant that the wrong
shape never looked wrong.

Two layers had to come off before any of that was readable, and both are the
kind of thing that makes a decompilation lie by omission rather than by error.

**One: the argument was not in the arguments.** The parameter's identity travels
in `DI` -- `MOVZX EDX,DI` then `MOV ECX,[ESI + EDX*4 + 4]` indexes the keeper's
array of param objects. Ghidra never assigned `EDI` to a parameter, so all 297
call sites decompiled to `ParamKeeper_SetParam(slot, 0, value)`. That C is
correct, compiles in the head, reads fine, and identifies nothing.

**Two: the ids are never written down.** The callers do not `MOV EDI, imm`. The
optimiser materialises each constant from whichever register already holds a
nearby one, because `LEA` is three bytes where `MOV imm32` is five:

    MOV  EDI,0x3
    LEA  EBX,[EDI + 0x33]      ; 0x36
    LEA  EDI,[EBX + -0x32]     ; 0x04
    LEA  EBX,[EDI + 0x33]      ; 0x37
    LEA  EDI,[EBX + -0x1]      ; 0x36  <- the id this call uses

A grep for `MOV EDI` finds a handful of the 297 and every one it finds is stale
by the time of the call.

`client/tools/ghidra/ResolveRegArg.java` undoes both: it walks each calling
function forward keeping a small abstract state over the registers, modelling
only the moves these chains actually use, and treating anything else as UNKNOWN
rather than guessing -- 278 of 297 resolved, 19 honestly unresolved (they are
loop-carried). It then writes each resolved id back as a pre-comment, so the
**dump itself** now reads:

    /* BindDerived source->target: EBX 0x36 (54), EDI 0x3 (3) */
    ParamKeeper_BindDerived(0);

The identity is back in the source permanently, not in a commit message.

**The ids are pinned by use-site, never by shape** -- the discipline this file
has learned twice the hard way on characterdata col 79:

- **3 and 4 are MaxHP and MaxMP** because `GObjMob_PublishStats` pushes
  `refobj+0x19c` and `+0x1a0` at them, and `+0x19c` is the exact field
  `RefObjChar_ExtractData` asserts `m_dwMaxHP > 0` on -- the strongest anchor in
  that struct.
- **0, 1, 2 are Level, Str, Int** because `GObjPC_InitStats` pushes
  `charData+0x65`, `+0x74`, `+0x76` at them; and 0 is confirmed Level a *second*
  time, independently, by the monster path pushing its level virtual at the same
  id.
- The **direction** of every graph edge is proven mechanically:
  `Param_PropagateToDependents`, which a write calls, walks the owner's list and
  stores into each registered target. Independently, Level/Str/Int only ever
  appear as the source -- they come from `charData` and cannot be derived.

Stated plainly, because it is the one number here that is ours: **starting
Str/Int = 20 is own design, disclosed.** It is not in the binary. Nothing writes
a constant to `charData+0x74` or `+0x76` anywhere in `SR_GameServer.exe`,
because character creation happened on the database side and this project has no
artifact of it. The formula is the game's; those two integers are a choice, made
so a level-1 character has 200 health.

Shipped with it: `Str`/`Int` on the character (migrated, existing rows default
to 20 rather than 0, which would otherwise have left every character on zero
health), health and mana derived from them everywhere, and the SQL HP reset
running the real formula. Three tests that had quietly hardcoded the old
100-HP base now derive their expectations from `character.StartingMaxHP`
instead, so the next change to the formula fails loudly rather than silently
testing nothing.

## Hundred-and-seventy-fifth round: monster HP is real now (characterdata col 59)

The 174th round flagged col 79 as the likely monster MaxHP and deliberately did
not ship it. Good thing: **it was wrong.** Col 79 is 23.5*level -- the same
value `leveldata` col 5 carries -- and a clean-looking curve turns out to be no
evidence at all of what a column *means*.

The real answer came out of the binary. The pserver's own `SR_GameServer.exe`
(8.9 MB PE32, now a second Ghidra project `re_server`) is a much better RE
target than the client: it kept RTTI class names, `D:\WORK2005\...` source
paths and assertion strings. Xref'ing the string `RefObjChar::ExtractData!!!!`
lands in the row parser, which deserialises a characterdata row field-by-field
into `CRefObjChar`; the assertion `m_dwMaxHP > 0` inside that same function
names the field's offset, **0x19c**. The struct there reads
`uint8 Lvl; uint8 CharGender; uint32 MaxHP; uint32 MaxMP;` at 0x198, 0x199,
0x19c, 0x1a0 -- two bytes, two padding, two dwords -- and laying that against
the data confirms it four ways: col 57 is the already-verified Level (a byte,
1..110), col 58 is CharGender (1 for player men, 2 for monsters), col 59 is
MaxHP, and col 60 is MaxMP, which is 0 for every single monster. Monsters have
no mana; that is exactly right.

So the ladder now carries the game's own HP (Mangyang 54 ... Yeoha 249, Earth
Ghost 1451) instead of a disclosed `50+22*lvl` curve. The values are not
monotonic in level and that is authored design rather than noise -- a `_CLON`
is a weaker slave version, so the level-4 Old Weasel (83) really does sit under
the level-3 Big-eyed Ghost (85). That apparent "inconsistency" was the very
reason an earlier pass had rejected col 59. Defence, attack and gold stay the
disclosed curve; rarity now multiplies gold only, since real HP already says
what a species is.

The modded-pserver worry got measured instead of assumed: y0gi's own
`SR_GameRefData/CharacterData_*.txt` agrees value-for-value with the pserver
client's characterdata, and its 104 columns differ from the client's 105 only
at the tail, so indices <=79 transfer directly.

**Player HP/MP did not fall out of this**, and three sources are now
definitively ruled out: characterdata's `CHAR_CH_*` rows are MaxHP=0/MaxMP=0,
neither `LevelData.txt` nor `RefLevel.txt` has an HP/MP column, and the
server's `_Char` table persists CurLevel/Strength/Intellect/RemainStatPoint but
no MaxHP/MaxMP. They are computed in `CGObjPC` from level+Str+Int, and that
function is still unlocated -- so there is still **no MP pool**, rather than a
guessed one.

## Hundred-and-seventy-fourth round: regrounding the combat loop

A re-verification pass over everything the combat loop (rounds 171-173) touched,
against real client data on the RE box -- because the `main.go` roster comment
claimed all 11 species were "GROUNDED" while the memory recorded only 3 levels
as actually checked. That gap is the project's classic failure shape, so it got
checked.

It held. Every one of the 11 monster CodeNames exists in the real
`characterdata_*.txt`; every Level matches col 57 exactly (1,2,3,4,5,6,7,8,9,10,
27), every Rarity is 0 (col 15), and every English Name matches
`textdata_object`'s real English column -- including the counter-intuitive ones
("Small-eyed Ghost" really is the retail string for `MOB_CH_BIGEYEGHOST_CLON`).
The EXP curve re-checked too (loaded CSV == real `leveldata.txt`, level 9 =
17978), as did the shop price grounding (Copper Sword id 71 = 890/427, cols
26/31) and the loot potion IDs (4/11/6/13 = the real HP/MP_POTION_01/03). The
own-design disclosures (per-level MaxHP, berserk numbers, `monsterStatsForLevel`)
are all honestly labelled. No invented value dressed as real.

Two things came out of it. **One gap fixed:** the roster grew from 3 to 11 but
`combat.LootTables` still had entries for only Mangyang/Weasel/Earth Ghost, so
the 8 new species dropped nothing -- exactly the "rename the spawns and silently
drop the loot" failure the file's own comment warns about. Filled in all eight
(disclosed own-design chances, real item IDs, grounded names). **One candidate
strengthened, not acted on:** characterdata col 79 is a near-perfect ~23.5/level
line across the ladder (24,47,71,94,118,141,165,188,212,235) -- a much better
MaxHP candidate than the non-monotonic col 59. Still not grounded (loader
column-map not decompiled; pserver stat values may be modded), so monster HP
stays disclosed; recorded in `GROUNDING_AUDIT.md` for the next pass. See that
doc's 2026-09-13 section.

## Hundred-and-seventy-third round: berserk -- the five-orb gauge

The real Silkroad berserk, on the authored orbs. The mini-frame carries five
circles (GDR_PMI_CIRCLE0..4) that went unused; they are the berserk gauge.
Fighting fills a server-side gauge (berserk.Tracker, +8 a hit), the orbs light
as it fills, and at full the R key unleashes berserk -- a damage burst
(+50% for 20s, disclosed own design; the mechanic is real, the numbers are
server-side and were never recovered) -- and the orbs glow. The gauge and
active flag ride on every AttackResult (appended, back-compatible), so the HUD
tracks it live. Verified in a render: orbs filled through combat, then all
glowed while berserk, "Berserk!" logged beside the level-up.

## Hundred-and-seventy-second round: leveling that pays off

Killing advanced the character but nothing showed it: max HP was a flat 100,
the level label was hardcoded to 1, and the underbar's EXP/SP gauges were
never fed. Now HP scales with level (MaxHPForLevel, base 100 + 40/level,
disclosed), a level-up (and a respawn) heals to that maximum, and the stats
packet carries level/exp/exp-to-next/SP (appended) which the world HUD applies
on enter-world, each kill and each level-up. The EXP curve itself is real --
leveldata.txt exported to a CSV the server loads. Verified in a render: the
Jangan ladder took a character to level 2, HP 100 -> 140, the EXP gauge
climbing and "You have advanced to level 2" logged.

## Hundred-and-seventy-first round: the real Jangan monster ladder

Three hand-tuned monsters with inconsistent stats (a level-5 Weasel weaker
than a level-1 Mangyang) became the real Jangan ladder -- Mangyang through
Yeoha, levels 1-10, plus the donghwang Earth Ghost -- 23 monsters across two
hunting grounds. Each species' identity is grounded in characterdata (CodeName,
Name via textdata_object, Level/Rarity at cols 57/15); their combat numbers
come from one disclosed level curve (monsterStatsForLevel) rather than
per-species guesses, so exp (ExpFor off MaxHP) scales with level too.
Positions are own design, clustered at the two farmland anchors already
measured walkable, so every monster stands on verified terrain.

## Hundred-and-seventieth round: the armour defence block, grounded at last

Round 140 left armour tooltips without a defence line, on the assumption that
"armour reuses the weapon columns for different stats, not yet measured." That
assumption was wrong twice over. Armour does not reuse the attack columns --
weapons leave columns 65-77 zero and armour leaves the attack columns zero, so
they are separate blocks. And it is measurable: `refdata_schema.md` already
records the real DB `_RefObjItem` defence column order (PD, ER, PAR, BR, MD),
and it maps straight onto the data positions -- physical defence first at
65-66, the shield-only block ratio at 74-75, magical defence right after at
76-77. Three independent lines agree: that DB order, the min/max-pair structure
matching the verified weapon block, and the values themselves obeying real
armour behaviour -- a Cotton garment reads 2~2.5 physical / 4.3~5.2 magical and
a Copper heavy 2.5~3 / 3.2~3.9, i.e. heavy has more physical and cloth more
magical, the cloth=magic / heavy=physical characteristic; a shield alone adds
Block ratio 10~20. Tooltips now show "Phy./Mag. def. pwr. X ~ Y" for armour
and shields, the sword still shows none, and the ER/PAR/MAR columns whose
semantics the schema calls undecoded stay out rather than get a guessed label.

## Hundred-and-sixty-ninth round: the warehouse holds gold too

The warehouse now keeps gold as well as items, finishing the authored
window's Total Gold line and its money button. Warehouse gold is a
per-character balance on the characters row (`storage_gold` beside `gold`);
character.Store gained AddStorageGold / DeductStorageGold, and storage.Service
moves gold between purse and warehouse the same careful way it moves items --
deduct one side, credit the other, refund on a failed credit. OpStorageGold
carries an op (query / deposit / withdraw) and an amount, and its result the
two balances, so the window and the bag always show the server's own numbers
rather than a client guess. A render deposited 250: the purse 960 -> 710 and
the warehouse's Total Gold 0 -> 250.

## Hundred-and-sixty-eighth round: the warehouse -- a second item container

Talk to a warehouse keeper -> Storage opens the authored warehouse window
(ifstorageroom) with the bag beside it; clicking a bag item deposits it and a
stored item withdraws it, each a quantity dialog. Verified in a render: 8
arrows deposited, the bag stack 20 -> 12 and the warehouse holding them.

The warehouse is not new machinery. It is an ordinary inventory container on
its own table, so it inherits every stacking and placement rule the bag has --
inventory.OpenSQLStore gained a named variant for a second table
(storage_slots), and storage.Service just moves items between the two
containers, reading the slot's own item and count from the source rather than
trusting the client, and returning the item if the destination add fails.
OpStorageList reuses the inventory-list wire shape.

Grounded that the service is reachable: the storage NPCs really are named with
WAREHOUSE (NPC_CH_WAREHOUSE_M / _W, and the EU/CA/KT/WC equivalents), so
NpcServiceReader's `codename contains WAREHOUSE` test -- an earlier guess --
turns out to match the real data, and a warehouse keeper's talk box offers
Storage the same way a smith's offers Buy.

## Hundred-and-sixty-seventh round: selling back, and stackables that stack

Two follow-ups finished the shop's economic loop. **Selling**: the store now
opens with the bag beside it, and a click on a bag item offers to sell it --
a "Sell X? N gold each" dialog with a quantity stepper, then the server buys
it back at the item's real SellPrice (`shop.Sell` reads the slot's own item
and count from its own inventory, never trusting the client, and puts the
item back if crediting gold fails). A render sold 5 arrows: the stack 20 ->
15, the purse 960 -> 965. **Stacking**: export-refdata had hardcoded
MaxStack=1 for every item on a note that it "is 1 for every row" -- but that
was the wrong column. Column 57 is the real MaxStack: 1 for all 8,616
equipment rows, a real cap for stackables (a potion 5,000, arrows 2,500,
alchemy stones 500). Reading it makes potions and materials stack to one
slot instead of one-each; a render bought 20 arrows and they landed as a
single slot of 20. The client's ItemTableReader now reads MaxStack (col 57)
and SellPrice (col 31) too, for the buy stepper's cap and the sell estimate.

## Hundred-and-sixty-sixth round: the shop's prices were real all along

The round below priced the Copper Sword at 540 gold from the own-design stat
formula, "there being no real vendor price table." That was half right: the
restored *database* `_RefObjItem` had no price, but the client's own
itemdata.txt does. `_RefObjCommon` column 26 is Price and column 31 is
SellPrice, and they line up exactly -- column 32, ReqLevelType1, is the one
ItemTableReader already reads, so the two on its left are pinned. A Copper
Sword reads 890 buy / 427 sell, an HP potion 600 / 210, a shield 495 / 238;
SellPrice is under Price on every row, weapons carry a CostRepair (198) that
consumables read 0, all internally consistent. So the shop now charges the
real 890 -- verified in a render, purse 1,000 -> 110 -- and the own-design
formula is only a fallback for an import that predates the columns.
export-refdata emits the two new columns (appended, so an older 28-column
export still loads); the refdata Item, the CSV loader and the SQL schema
carry Price/SellPrice; shop.Price prefers the real number, and shop.SellValue
(real SellPrice, for selling back) is ready for the sell path. This is the
one grounding dead-end this project has reopened -- GROUNDING_AUDIT.md moves
shop prices from own-design to recovered.

## Hundred-and-sixty-fifth round: the NPC shop -- real goods, real prices, a real purchase

Talk -> Buy now opens the client's own store window filled with what the
NPC really sells, and you can buy it. Grounded throughout; the two hard
parts were where the shop's shape lives and why buying broke.

**The store window carries no tabs -- the store *class* builds them.**
`resinfo\ifstore.txt` has a 6x5 lattice (GDR_STORE_LAT, 21,71,216,180 ->
30 cells), a page spinner and repair buttons, but not one tab control. The
tabs are built in code: decompiling both store classes (FUN_006cf5a0
CIFStore, FUN_006d2c70 CIFStoreForPackage) shows an identical loop from
x=16 stepping 0x38=56 while x<0xf0=240 -- four `com_short_tab` tabs -- then
a 4-tabs x pages x 30-slot store (classic 2 pages, package 8). So the
visible window is the same either way; the branch only changes invisible
page capacity. We build the tab strip the same way, over the authored
frame, and take the classic 30-slot branch.

**Its two slot sets are alternates behind `#ifdef RENEWAL_SHOP_SYSTEM`.**
The layout declares both CIFSlotWithHelp (classic) and
CIFSlotWithHelpForPackage (renewal) over the same grid; reading both draws
60 slots. UiLayoutParser gained optional `#ifdef`/`#else`/`#endif`
selection (off by default -- every window built so far relies on reading
both branches, since the client binds by class), and the store builds with
nothing defined: the base 30-slot grid, no RESTORE_SOLDITEM_INSHOP buyback
row.

**Item names come from the name string id, not the object name.** itemdata
column 3 is written in mixed languages -- "Copper Sword" but Korean for
many consumables; column 5 is the `SN_ITEM_*` id that textdata_object turns
into real English ("HP Recovery Potion (X-Large)"). Reading column 5 fixed
Korean names everywhere items show, not just the shop. Tab names
(SN_TAB_WEAPON -> "Weapon") resolve through textuisystem.

**Buying broke twice, both fixed.** The in-memory server never loaded item
refdata, so its shop sold nothing ("no such item"); added `-items-csv`
beside the existing `-skills-csv`. Then OpShopList returned the entire
~12,000-item catalogue in one 329 KB packet, past a single frame -- the
server closed the session and the client hung at login. A shop only needs
its own NPC's goods, so the list request now carries the item ids to price
(the smith's 19, capped at 500) and the server prices just those. Verified
in a render: a Copper Sword priced 540 gold (the server's own disclosed
formula, there being no real vendor price table), bought, purse 1,000 ->
460.

## Hundred-and-sixty-fourth round: the inventory was a debug list over the real grid

Playtest: the inventory looked nothing like the game -- a plain list of
`slot_index=0, Item_id=501` text rows, not a grid of item slots. It reads as
pure "assumed" UI.

The cause was a leftover debug fallback, not a missing window. `ifinventory.txt`
*does* define the real bag -- `GDR_INVENTORY_FRAME` (chrome),
`GDR_INVENTORY_LATTICE:CIFLattice` (the slot grid, Rect 18,13,144,288, built by
UiBuilder into one icon cell each), `GDR_INVENTORY_LATTICE_OUTLINE`, and
`GDR_INVENTORY_STA_GOLD` -- and `_fill_inventory_grid` already fills that grid
with item icons. But the same handler *also* called `_fill_list("inventory",
...)`, and because ifinventory.txt has no scroll-manager control, that fell
through to `_fill_list_overlay`, which drops a full-window `ItemList` of debug
text **on top of** the grid. The authored grid was there the whole time, hidden
under the overlay. Removed the `_fill_list` call for the inventory; the lattice
grid is the presentation, the same as the real client.

A render (`--server --panels inventory,equipment`) confirms it: the inventory is
now the real framed slot grid with its gold readout, and the equipment paper
doll shows the starter kit's real gear icons (sword/shirt/pants/boots) on the 3D
character. Empty bag cells are only because the test server's drops are the
placeholder item IDs 500-502 (no icon art); real item ids render their icons,
as the equipped slots prove.

Note on client versions: this archive's `ifinventory.txt` is bag-only (the paper
doll is the separate `ifequipment.txt`). A newer client fuses them into one
window; since the build is data-driven off whatever `ifinventory.txt` the
player's own pk2 carries, it renders whichever layout that version defines.

## Hundred-and-sixty-third round: the level-up burst, end to end from the real effect

The playtest asked for the level-up animation, recovered from the client, wired end to end. Done —
server trigger through to the on-screen burst, verified in a render (the chat reads the real "You
have advanced to level 10." and a golden burst envelops the character).

**What the real effect is.** `system\system_levelup.efp` in Particles.pk2 (JMXVEFF 0011) is a
~19-emitter layered effect. Its `RenderMesh` nodes each pair a mesh with a texture; walking the
node stream on the RE box (`pk2list` extract + a token walk) recovered the real pairings for the
four core primitives:

    levelup01.bms -> won-light-up-i.ddj      (vertical light shaft)
    levelup02.bms -> won-light-up-sb.ddj     (soft bloom)
    levelup03.bms -> hoon-out-light-02.ddj   (ground ring)
    levelup04.bms -> sdamage-wb-01.ddj       (rising sparkle/lotus)

plus more emitters (`cho-won-001/002`, `light-up2`, `wind-won-01`, a `nasun-line.ban`) not used yet.
The message is `UIIT_MSG_STRGERR_LEVEL` "You have advanced to level [%d]." (textuisystem.txt,
English column), looked up at runtime with the level substituted into its own `[%d]`.

**What could NOT be recovered, and the honest call made.** The `.efp`'s per-emitter `ScaleGraph`/
`DiffuseGraph` keyframe curves. The reader flattens the tagged tree to `(name, raw-bytes)`
(EFP_FORMAT.md), so the graph block has no confirmed schema. A float32 decode of the ScaleGraph
block *looked* like a 4-float header then `(value, time)` pairs with a monotonic time axis to ~1.0
— and it fit cleanly on the first few nodes — but held on only ~a third of this file's 30 ScaleGraph
nodes when checked across all of them. That is a guessed structure, not a recovered one, and using
it would both dress a guess as real and hardcode game-data values. So the curves are **not** driven
from the file. The effect (`client/scripts/effects/level_up_effect.gd`) instead loads the **real
meshes and textures at runtime** from the player's own Particles.pk2 (never committed, BYO like all
real assets) and drives them with a **disclosed designed** grow→overshoot→fade additive animation
that matches the effect's recovered *character*. Only the burst's *size* is data-driven: each layer
is normalized to the player's own rendered height, no magic per-mesh scale. Every designed constant
is labelled as such in the file header.

**Wiring.** Server was already done (162nd-round-era leveling): `OpLevelUp 0x0067`, payload
`NewLevel:int32, StatPoints:int32` LE, sent right behind `OpAttackResult` on a kill that crosses the
curve. Client: `CombatNet.decode_level_up` (matching 2×u32 LE) -> `NetClient.level_up` signal ->
`World3D._on_level_up`, which logs the real message and plays the burst on the player. A
`SRREVAMP_QA_LEVELUP=<level>` hook fires it a moment after spawn for renders (a real level-up needs
a leveldata CSV and enough kills). First render at HEIGHT_MULTIPLE 2.2 whited the frame out; tuned
down to 1.5 with per-layer additive intensity caps and XZ centring.

## Hundred-and-sixty-second round: why a building traps the player (diagnosis)

Chased the playtest "stuck inside a building in Alexandria" report to a root
cause. Probed the reported spot (region 90/48, local 769,205) with
`QA_COLUMNS`: two walkable surfaces there, the terrain at 863 and a raised
one at 868.5 (~5 units up, a building floor), and the landing height picks
the raised one -- so a teleport there lands the player *on the building
floor, inside its walls*.

The trap itself is the object mesh collision. `ObjectLoader` builds a
`StaticBody3D` with `create_trimesh_shape()` from each building mesh and
leaves it on the default collision layer 1; the player's mask is 17 (layers
1 + 5), so the player physically collides with building meshes. A concave
building collider cannot depenetrate a capsule that started inside it, so
move_and_slide pushes the player *further in* and barriers them. The loader's
own comment already says this physics surface "is wrong, and the real client
does not do that either -- it walks the cell/edge graph directly": the
navmesh walls (layer 5) are the intended and sufficient blocker.

**The fix, deferred until it can be verified in-game:** put the object
colliders on a scenery layer the camera collides with but the player does not
(so the camera still does not clip through buildings and clicks still target
terrain), leaving the navmesh walls as the sole player blocker. The risk is a
building the navmesh walls do not fully enclose becoming walk-through, and
that cannot be checked in a headless render (the standing verification-gap
rule) -- so it wants a live movement test, not a blind ship. Recorded in
`docs/FRONTEND_CHECKLIST.md`.

## Hundred-and-sixty-first round: the MENU wears its own icons

The underbar's MENU popup was a plain grey system list. It is now the game's:
a dark, gold-edged panel with gold text and each item's own authored icon --
the client's `interface\underbar\ub_new_icon_*` (20x20), one per function
(`ub_new_icon_pt` for Party, `_guild`, `_quest`, `_recovery` for Auto Potion,
and so on), added with `PopupMenu.add_icon_item`. Three items
(Inventory / Character / Skill) have no `ub_new_icon` in this archive -- they
are underbar buttons in the version it came from -- so they show text-only
rather than a mismatched icon, the honest choice. Rendered with a QA
`--panels menu` hook (the MENU is a popup, not a panel, so `_qa_open_panels`
grew a case for it): the framed menu reads with its icons. The ornate authored
frame around it is a later polish; the styling here is a disclosed choice.

## Hundred-and-sixtieth round: the world loaded 3.7x faster -- a re-opened archive

The ~65s world entry and the 2-6s region-crossing freeze had one dominant
cause, found by profiling each phase of a region load: the pk2 archives were
being **re-opened from scratch on every region**. `_open_pk2_if_set` (and the
map/media equivalents) called `Pk2Reader.open` every time -- and opening the
2 GB Data.pk2 reads its whole directory index, ~1s each. `_load_region_navmesh`
opened it once per region, so across a 25-region grid that was ~25s of pure
re-opening, dwarfing the actual work (the navmesh read fell from 24.8s to
52ms once the handle was reused; the parse was only 0.4s, the wall triangles
and collision shape ~0ms). Objects and NPC loading paid the same tax.

The fix is three lines: hold each archive open (`_data_pk2`, `_map_pk2`,
`_media_pk2`) and reuse it. A region load's own report went from **65s to
17.7s** on the box (terrain 37.4s -> 6.4s, objects 16.8s -> 5.3s, npcs 2.4s
-> 0.5s), and the per-cell streaming cost that causes a crossing hitch fell
from ~2.2s to ~0.5s. The earlier re-open was a null-timing workaround (a
handle not yet set when streaming began, see the comment at the NPC pass),
not a thread-safety need -- reads are all sequential on the main thread, so a
single reused handle is correct. Rendered the Jangan spawn after: same world,
loaded in a quarter of the time, the player's back to the camera (round 157's
facing fix holding). Tests 64/0.

The profiling instrumentation added to find this was removed; the load print
keeps a terrain/objects/npcs breakdown.

## Hundred-and-fifty-ninth round: the target window on its own frame

The current-target window at the top of the screen now uses the client's own
frame art -- `interface\targetwindow\tw_type1.ddj` (200x72), the same dark
frame with the gem slot and the recessed HP bar the original draws -- instead
of a plain black box. The monster's name sits in the top bar and a red HP bar
with its percent below, positioned on the frame's own slots (fractions
eyeballed from the art, tuned by a render). The real window's rank gem and
level are deliberately left off: the monster snapshot on the wire carries
neither (`CombatNet.MonsterSnapshot` is name, code, position, hp/max only), so
showing them would be inventing data. Rendered against a field Mangyang: the
framed window reads "Mangyang" over a full red bar and "100%", with the
floating damage number and the over-head bar all working together. A
plain-box fallback stays for a run with no archive.

## Hundred-and-fifty-eighth round: the loading screen covers teleports too

The playtester's call: the "NOW LOADING" screen belongs on a teleport. A zone
change (`_on_change_zone_result`) now raises the same screen before it reloads
the zone -- so even the synchronous centre-cell build is behind it -- and
drains the new zone's queued neighbour cells behind it (the shared
`_drain_initial_load`, which now reuses a screen a caller already put up). It
still shows on first world entry, which is itself a teleport into the saved
position, so "only when teleporting" holds; a QA render still loads
synchronously with no screen. Whether first entry should skip it is left as a
question in `opensropleasereview.md`.

## Hundred-and-fifty-seventh round: the body walked backwards

A playtester reported, and confirmed, that the character faced the opposite
of where it was told to move -- it moonwalked to every click. The cause: the
assembled body's own visual front is its local **-Z**, but the player node
points its local **+Z** at the movement/target direction (`rotation.y =
atan2(dir.x, dir.z)`), so the body faced 180 degrees away from its heading.
The create screen corroborates the axis -- `PaperDoll` frames its camera on
the body's -Z side and shows the body's front, so front = -Z. The fix turns
the assembled body 180 degrees when it is parented (`skeleton.rotation.y =
PI`), for both the local player and other players, aligning the visual front
with the node's forward so every facing (movement, click, combat) points the
right way. Input/facing is hard to catch in a headless render (the player
kept hiding behind Jangan's festival clutter), so this is reasoned from the
report plus the create-screen axis, to confirm in-game.

## Hundred-and-fifty-sixth round: where the load minute really goes

Chased the ~65s region load down to phases (timing added to `_load_region_cell`,
printed at entry): across 24 cells, **terrain ~37s, objects ~17s, NPCs ~2.4s**.
So NPCs were never the cost. NPC bodies are now cached per model and
duplicated per spawn anyway (a skinned `.bsr` assembled once, the repeats a
cheap node copy sharing its mesh/texture resources) -- it shaved a few
seconds and helps the streaming hitches, and a top-down Jangan render
confirms the duplicated NPCs render dressed and animated around the plaza.

But the real bottleneck is terrain, and within it
`terrain_mesh.create_trimesh_shape()` -- a concave-polygon BVH built from the
full-region mesh, per cell. The fix (a follow-up, not rushed): terrain is a
heightfield with no overhangs, so a `HeightMapShape3D` from the region's
height grid is far cheaper to build and collide; it needs careful alignment
with the visual mesh's 180-degree rotation, offset and tile scale, and a
render proving click-to-move and the camera still hit terrain. Objects
(~17s) can then be deferred to stream after entry. Recorded in
`docs/FRONTEND_CHECKLIST.md`.

## Hundred-and-fifty-fifth round: a "NOW LOADING" screen, and where the minute goes

World entry took 60-90s with no feedback -- a black, frozen window. Two
parts. First, the profile: `character/item/NPC tables` load in ~1.2s, but
the 25-region grid takes **~68s, about 2.75s a region** -- that is the whole
wait. Second, the feedback: the initial neighbourhood is now *queued* like
the streaming cells (round 154) and pumped a batch a frame behind a "NOW
LOADING" screen -- the real `loading_default.ddj` art with a gold gauge that
fills as cells build -- so entry animates instead of freezing. A QA render
(`SRREVAMP_MAPM_PATH` set) still drains the queue synchronously so a
screenshot sees the whole world; `SRREVAMP_QA_FORCE_LOADING` renders the
screen itself, which is how it was verified. The screen is added as the HUD
Control's top child (a CanvasLayer of its own did not composite in movie
mode) after the HUD is built, so the ~1s of table loading before it is a
negligible placeholder flash.

Not yet done, and the actual speed-up: 2.75s a region is almost certainly
the skinned NPC assembly in `_try_spawn_region_npcs` (a `.bsr` per NPC).
Reducing the initial radius alone just moves the per-cell hitches to
post-entry, so the lever is the per-cell cost -- defer or thread the NPC
spawns. Recorded in `docs/FRONTEND_CHECKLIST.md`.

## Hundred-and-fifty-fourth round: region cells stream a few per frame

Playtest complaint: crossing into a new region froze the game for about a
second, every time, everywhere. The cause was `_maybe_stream_regions`
building the whole leading row of new cells (five, at radius 2) synchronously
in the one frame the boundary was crossed. The cell underfoot is always
already loaded -- it was a neighbour before the crossing -- so the new cells
are ahead of the player and can arrive over the next frames instead. They
are now queued nearest-first and built `STREAM_CELLS_PER_FRAME` (1) at a
time in `_process_stream_queue`, with a stale-cell guard so a cell the
player has since turned away from is dropped rather than built. This turns
the one long freeze into a few short per-frame hitches while the player
keeps moving; it does not thread the build, so a very heavy cell can still
hitch -- threading the region build off the main thread is the next step if
it is still felt. Rendered a 400-frame walk: no script error, regions
stream, the body faces its heading (bearing on the separate "runs backwards
on click" report -- QA_WALK's facing is correct and click uses the same
math, so that one is still unreproduced; see `opensropleasereview.md`). The
initial neighbourhood load is still synchronous -- that is the 60-90s
entry, to be covered by a loading screen and its own optimisation next.

Also this round: a shared `FrontEndUi.vignette` over the login / select /
create backdrops (a dark radial gradient) so the panels read and a
letterboxed backdrop's bands frame intentionally, and the login's register
link picked up the gold. A look-better pass the user asked for.

## Hundred-and-fifty-third round: the left button walks, it does not orbit

Playtest feedback: holding the left button dragged the camera, which the
original never does -- a left drag walks the character. Only the right
button orbits the camera now; a held left button, once dragged past the
tap threshold, steers the character toward the cursor every physics frame
(`_left_steering`, refreshed from the mouse's world point via the existing
`_try_set_move_target`), and WASD still overrides it. A plain left click
(no drag) still talks to an NPC, attacks a monster, or walks to the point,
as before. Input is not headless-verifiable (the standing caveat about the
render harness never pressing real keys), so this is compiled and reasoned,
to be confirmed in-game.

Logged the same session and not yet fixed (see `docs/FRONTEND_CHECKLIST.md`):
the character runs backwards on click-to-move (a facing/model-forward
question, needs a `QA_WALK` render), the ~1s freeze crossing into a new
region (synchronous streaming on the main thread -- the same root as the
60-90s initial load), NPC facing/dialogue-options, the target window's
frame, and the EXP/level/skill/stat systems the character and skill windows
need.

## Hundred-and-fifty-second round: creating a character, with a live 3D body

The "Create" button now opens a real create screen instead of a name-and-
gender popup: a name field, a Man / Woman choice, and a live 3D preview of
the body you are about to make, over the gold-dragon `loading_charactercustom`
backdrop. The preview is the genuine assembled body -- a new `CharacterPreview`
reuses the world's own pieces (the characterdata code->`.bsr` resolution,
`SkinnedBsrAssembler`, and `PaperDoll`'s framed SubViewport) and plays the
body's own idle so it stands and breathes rather than holding the bind
(T-)pose. Loaded from the player's Data.pk2 / Media.pk2 at runtime, nothing
shipped; with no archives it says so instead of showing an empty box.

Two honest omissions, both disclosed on the screen and in
`FRONTEND_CHECKLIST.md`: the appearance sliders the original shows (figure,
height, weapon, cloth) are absent because the server stores only the gender
and the client renders from that alone -- a slider would change nothing --
and the race is Chinese only, because there are no European body assets, so
a two-statue race pick would offer an uncreatable choice. The race/region
screen is deferred for that reason, not forgotten.

## Hundred-and-fifty-first round: character select, with an honest stat panel

The bare character list becomes the original's select screen: the account's
characters down the left, a stat panel on the right, Start / Create / Delete
/ Cancel below, over the real `loading_constantinople.ddj` backdrop, with a
shared `FrontEndUi` helper carrying the gold-on-dark styling and the
Media.pk2 art loading the other front-end screens will reuse.

The interesting part is the stat panel. It shows what the server actually
tracks -- name, level, and an HP bar (cur / max) -- and nothing it does
not. There is no experience, MP or stat-point system yet, so the panel
shows none rather than an invented bar; the same rule as everywhere else
here. Making even that much honest needed a protocol change: the character
list carried only names, so it now carries a per-character summary (name,
gender, level, HP, max HP). `session.CharacterListResult` gained a
`CharacterSummary` slice in place of `Names`, encoded as name+gender
strings then three uint16s; the client's `CharacterNet.decode_list_result`
and the `character_list_result` signal carry `Summary` objects; both sides'
tests updated, all green (server) and 64/0 (client). **The client must be
v0.1.104+ to read this server's character list.**

The 3D character on the dock is a later pass; the backdrop is the
letterboxed Constantinople loading art for now. Rendered with a QA-only
`SRREVAMP_QA_FAKECHARS` hook (clearly `QA_`-named sample characters, never
shipped) since a booted-in-isolation select screen has no logged-in session
to list.

## Hundred-and-fiftieth round: the connect screen over its own art

The front-end (launcher, login, character select, create, loading) is the
next big piece -- see `docs/FRONTEND.md` for the plan and
`docs/FRONTEND_CHECKLIST.md` for the running list. First finding: unlike
the in-game HUD, the front-end has almost no authored layout. Listing a
real `Media.pk2` for `resinfo` front-end windows turns up only
`ifregionview.txt` (the race/region select), `pstitle(_europe).txt` and
`regionname.txt`; the login and character screens the retail client draws
hardcoded in C++ against textures. So those layouts are ours, disclosed,
grounded in the reference screenshots -- the same standing as the name
plates and HP bars.

The art, though, is all real and in the archive (found with
`server/cmd/pk2list`): `interface\outer\login_window.ddj` (288x140, the
gold frame with three input slots) and its europe variant,
`interface\loading\loading_login_01_2011.ddj` (1024x768, the knight-over-
Constantinople backdrop), `loading_default.ddj` (the gold-dragon loading
screen), `gauge_loading.ddj` (the progress fill), per-region loading
images, and the channel window. All loaded at runtime from the player's
own Media.pk2 through the same `UiBuilder.load_texture` /`DdjReader` path
the HUD uses -- nothing extracted into the repo.

`Login.gd` is rebuilt on that: the real frame centred over the backdrop,
ID / PW / Server laid on the frame's own slots (positions eyeballed from
the 288x140 art, tuned by rendering, disclosed as ours), gold Connect /
Exit below, and a plain-panel fallback when no Media.pk2 is present so a
dev run without game data can still log in. Every `NetClient` wiring is
unchanged. Rendered with the new `qa_shot.sh --scene res://scenes/Login.tscn`
(which boots any scene, not just the world), the fields sit on their slots
and the screen reads as the original's.

## Hundred-and-forty-ninth round: floating damage numbers

Every blow now shows its damage the way the original does: a number that
rises and fades over the thing it was dealt to. The damage the player
deals floats up over the monster in white, from its HP bar's height; the
damage the player takes floats up over the player in a warm red. Both are
fixed-size billboarded `Label3D`s -- the same trick the name plates and HP
bars use so they read at any distance and in this world's real scale (a
character is about `2 * PLAYER_SCALE_RATIO` tall, so the rise and the
fallback height are scaled by it, not left in 1.8-unit terms, or the climb
would be imperceptible). Each tweens its position up and its fill *and*
outline alpha to zero over 1.1s, then frees itself. They are on the same
clock the hit reactions already use: the dealt number lands with the
swing's hit event, the taken number with the monster's counter-swing
(round 132's `lands_after` / `strike_after`). The colours, size and rise
are a disclosed choice; nothing recovered gives the original's. Rendered
over a field Mangyang with `QA_ATTACK`: the white "1" (placeholder damage
until the round-145 refdata is imported) drifts up off the monster and the
red "8" off the player. `_floating_damage` logs each number's unprojected
screen position under the QA hook, so the frame crop was aimed at 640,347
rather than hunted for.

## Hundred-and-forty-eighth round: the target window

The current target now shows at the top of the screen, the way the
original does: the monster's name and an HP bar, centred at the top,
appearing the moment one is clicked or attacked and shrinking as it takes
damage. It is a name-plus-bar Control rather than the authored
`iftargetwindow` frame -- that layout's name, HP and level are client-drawn
over custom control types, so this shows the same information honestly and
leaves the frame art for later. Wired to every path that sets the target
(the world click, the action-tab Attack button, and the QA attack hook, so
a render shows it), updated from `_on_monster_damaged`, and cleared when
the target dies. Rendered over a field Mangyang: the top bar reads
"Mangyang" with the over-head bar of round 146 below it.

## Hundred-and-forty-seventh round: click a monster to attack it

The left-click scheme is now the original's whole set: a click on an NPC
talks to it, a click on a monster attacks it, a click on the ground walks
there. Each monster carries a click collider on its own layer (bit 6, so
it neither blocks movement nor catches the ground-snap ray) tagged with
its id; `_try_attack_monster` ray-tests that layer and, on a hit, targets
the monster and sends the attack down the same path the action-tab's
Attack button uses. It sits between the NPC-talk and ground-move checks in
the click handler. The combat behind it is still the placeholder damage
until the round-145 refdata is imported -- but the interaction is the
faithful one, and reads well with the round-146 HP bar shrinking on each
hit.

## Hundred-and-forty-sixth round: monsters get an HP bar

Monsters showed their health as text -- `Weasel (80/80)`. The original
shows a name above the monster and a red HP bar below it, so that is what
they show now: the name plate is name-only, and under it a billboarded,
fixed-size Sprite3D whose texture is drawn per HP fraction (a dark frame,
a red fill), the same fixed-size trick the name plate uses so it reads at
any distance. It shrinks the moment a hit lands (`_on_monster_damaged`
sets the fill from `remaining_hp` before the list round-trip) and is in
the same "name_plates" group, so the range slider fades it with the name.
Colours and size are a disclosed choice; nothing recovered gives the
original's. Rendered over a field Mangyang: the framed red bar sits under
the name. (The same render shows the player hitting for 1 -- combat is
still the placeholder damage until the refdata of round 145 is imported.)

## Hundred-and-forty-fifth round: the item reference data the server was missing

The server had no item reference data on the test VM -- `SELECT count(*)
FROM items` was 0 -- so its shop catalogue was empty and combat gave every
weapon a flat unarmed damage of 5 (a copper sword hitting for 5 against a
200-HP monster is why "the player dies before killing anything"). The
data to fill it is the client's own itemdata tables, and `export-refdata`
(new, `server/cmd`) turns them into the CSV `import-refdata` loads.

The column mapping is the same measurement as round 140, extended and
pinned by a test that round-trips a synthetic row through the importer's
own parser. Verified against the real Copper Sword (+5) tooltip: physical
attack at fields 96/98 (base 15/16), magical at 101/103 (25/28),
durability 64/65 (62/76), attack rate 114 (24), critical 117 (3); the
attack columns are the same for the bow and spear. What is **not** mapped,
and left as an honest default rather than a guess: `MaxStack` = 1 (the
server already treats every item as one-to-a-slot with no refdata, so this
is no change), and **armour defence = 0** -- measuring the Cotton Suit
showed armour keeps its stats in different columns (66-86) than a weapon's
attack (93-118), and with no ground-truth armour tooltip those columns
cannot be labelled phys- vs mag-defence with confidence, so they are left
empty; combat does not read defence, so the only effect is the shop
pricing armour at base.

Importing it is left to the operator (`deploy/README.md`), not the deploy
loop: it changes live gameplay (real weapon damage; the equipment rules
begin enforcing the real race/gender/level requirements) and is reversible
(`TRUNCATE items`). The exporter and its verification are shipped; whether
to apply it to a live server is a call for whoever runs it.

## Hundred-and-forty-fourth round: the paper doll breathes

A small one: the equipment window's paper doll was a still pose. It now
plays the town idle -- registered in `_animated` like every other body,
posed each physics frame by `_tick_idle_animations` on the `.ban` file's
own clock, and shown through the doll's `UPDATE_ALWAYS` SubViewport. A
stale entry from a previous equipment change is dropped there when its
skeleton is freed. Confirmed by rendering the window over 160 frames:
the pose shifts between them, in step with the body in the world.

## Hundred-and-forty-third round: the skill window's masteries

The user showed the skill window as something to represent, and it now
shows China's real masteries. `skillmasterydata.txt` names them (measured:
257 Bicheon over sword and blade, 258 Heuksal over spear and glaive, 259
Pacheon over bow, and the four force masteries 273-276), each with a
`UIIT_` name token and an icon under `icon\skillmastery\china\`.
`MasteryReader` reads them, weapon tab first, and the skill window lays
each as its real icon plus the name -- resolved through the UI text table
where the archive has it (the box's does: Bicheon, Heuksal, Pacheon,
Sorcery, Lightning, Fire, Force), and labelled by the weapon it trains
otherwise. Rendered on the box: the seven masteries with their sword,
spear, bow and elemental icons.

What it does **not** show, because this project's server tracks neither:
a mastery's trained level or a skill point total. So every mastery reads
`Lv 0 (not trained)` and the window's own bottom labels read `Skill
point 0` and `Mastery level total 0` -- the authored fields, filled with
the honest zero rather than the 5,000,000 a populated private server puts
there. The authored per-mastery skill grid (a client-drawn `CIFSkillBoard`,
not layout slots) and Level Up wait on that server side.

## Hundred-and-forty-second round: the worn slots filled

The equipment window's worn slots now show the equipped items' icons
around the paper doll. Each `CIFSlotWithHelp` the layout builds already
carries an `ItemIcon` child (the same one the inventory cells use), so
filling one is the inventory grid's own trick: the item's icon from the
table, and the hover tooltip. The slot mapping -- which
`GDR_EQUIPMENT_SLOT_10x` is which worn slot -- was **not** guessed: it is
`100 + slot index`, anchored to the user's own equipment screenshot,
where the weapon (slot 6) sits in `SLOT_106` at the top-left and the
shield (slot 7) in `SLOT_107` at the top-right, exactly where the layout
puts those two controls. Rendered with the starter kit: the sword
top-left, the mail on the left, pants and boots along the bottom, every
icon in the slot the +index run predicts. Still empty rather than
invented: the armour defence numbers a slot's tooltip would add (armour
reuses the weapon stat columns, unmeasured).

## Hundred-and-forty-first round: the paper doll

"Notice how in the inventory menu my character is rendered here." The
equipment window (`ifequipment`, its own window on `O`) now renders the
dressed character live, the way the original does. `PaperDoll` is a
`SubViewport` with its own world -- an orthographic camera framed on the
model's own bone bounds, a key light and grey ambient, so the game
world's camera and lighting do not leak in -- and World3D builds a second
copy of the assembled body (the same `_build_assembled_character` the
world uses, dressed from the same equipment) into it, posed in the town
idle, whenever the equipment changes. The equipment window shows the
viewport's texture in the central column between the two rows of worn
slots. Rendered on the box: the white Cotton set and the sword, head to
foot. The worn slots around it are still empty frames -- filling them
with the equipped icons, and the item table's armour defence block, are
the follow-ups.

## Hundred-and-forty-first round: the equipment pipeline drawn and measured, and the one accessory it mis-hangs

The character + equipment + texture path had been assembled and shipped but not
looked at in a while, so it was rendered on the box against real `Data.pk2` and
checked piece by piece. It works, with one precise exception.

**What renders correctly** (`render_dressed_character.gd`, a new tool that
assembles a body `.bsr` and hangs item `.bsr`s on it the way `World3D` dresses
the player):

- The `chinaman_fighter` body: 43 bones, 9 skinned pieces, textured (skin, hair,
  face, loincloth) — a person in T-pose, not scattered.
- The Cotton Suit worn over it — `clothes_01_{ba,la,aa,fa,ha}.bsr`, five armour
  pieces, each **type 5, no own skeleton, weighted onto the body's own bones by
  name**. All five land right: grey tunic, trousers, shoes, wristbands.
- `sword_01.bsr` in the right hand — **own skeleton hung from the hand bone**,
  blade extending correctly from the grip.
- The `chinaquest_priest` NPC, self-contained `.bsr`, in his monk robes.

So both attach modes — weighted-to-body armour and own-skeleton weapon — are
correct, and DDJ→material→skinned-mesh is sound end to end.

**The one exception, and it is measured, not guessed.** `clothes_01_sa.bsr`
renders as a small grey rectangle floating by the neck. It is NOT the weighted
kind: its `.bsr` names its own skeleton `prim\skel\item\china\clothes_sa.bsk` and
an attach bone `Bip01 Neck1`, so it takes the same own-skeleton path the sword
does. The mismatch is the transform. Measured vertex bounds:

	clothes_01_ba.bms (weighted armour):  centre (0,13,0)  — ABSOLUTE character space (torso is (0,14,0))
	clothes_01_sa.bms (own-skeleton):     centre (0,2,0), 16 verts — ITEM-LOCAL space, like a weapon

So `_sa` is an item-local accessory, correctly routed to the own-skeleton branch,
but placed by `SkinnedBsrAssembler`'s `item_skeleton.transform =
get_bone_rest(0).affine_inverse()` — a composition the code's own comment says was
"chosen by rendering" to make the **sword** hang right, not read from the client.
It does not generalise to an accessory on `Bip01 Neck1`. **Next step, grounded:**
the client's item-attach transform composition, read from the binary rather than
tuned per item — the sword and the collar need one rule, not two render-picks.
Left unfixed rather than render-tuned again, per the project rule. (Tools added:
`render_dressed_character.gd`, `measure_mesh.gd`.)

## Hundred-and-fortieth round: a weapon's stats on hover, measured off a real tooltip

"If I hover over an item it shows me the stats." Hovering an inventory
slot now shows the item's real stats, and every figure was pinned against
a Copper Sword (+5) tooltip a player sent -- the one measurement that
turns a plausible column into a certain one. The reinforce columns gave
themselves away first: 306, 342, 519, 591 in the row are 30.6 %, 34.2 %,
51.9 %, 59.1 % on screen, exactly. Attack rate 24 and critical 3 sit in
the row unchanged. The attack power took backing the +5 out through the
per-plus growth floats next to each attack: base physical 15~16 at
+5×2.4 is 27~28, base magical 25~28 at +5×4.1 is 45~48 -- both the
tooltip's numbers. ITEM_FORMAT.md has the column table; the reader parses
them and `Item.tooltip_lines` formats them, tested against these exact
values. Left out rather than guessed: the attack distance (not in these
columns) and the armour defence block (armour reuses the columns for
other stats, not yet measured), so an armour tooltip shows durability,
requirement, race and gender and no invented defence number.

## Hundred-and-thirty-ninth round: clicking an NPC talks to it

"When you click on an NPC it brings up a dialogue box." It does now. A
left click ray-tests the NPC layer first (the capsules `_npc_collider`
puts on `NAVMESH_WALL_COLLISION_LAYER`); a hit opens the authored
`if_npctalk` window titled with the NPC's name -- read off the holder,
which now carries `npc_name` as metadata -- and anything else walks
there as before. Two things the layout needed. It carries two backgrounds
one over the other, a quest parchment (`gd_paper_02`) in front of a plain
dark tile (`com_bg_tile_d`); the parchment is for quest text, and a plain
talk shows the dark tile, so the quest paper and its orange title strip
are hidden -- which is what makes it match the user's own dark dialogue
rather than the scroll the stock layout draws first. The body is a
greeting and `1. End conversation`, a link that closes; the services
behind a real NPC's other lines (storage, shop, honour) are their own
systems and come later, so this greets and lets you leave, the skeleton
the rest hangs on. `SRREVAMP_QA_TALK="<name>"` opens it for a render.

## Hundred-and-thirty-eighth round: the Escape menu

"There exist options when you hit Escape." There are now. Escape closes
the topmost open window, and with nothing open raises the authored System
window (`ifsystemwnd.txt`, built by `HudPanels` like every other window):
Option, Help, Help Request, Restart, Exit -- the operator's own layout,
so the user's four-button DuckRoad build and the stock five-button one
both come out right, each button wired by the name the layout gives it
(`GDR_SYSTEM_BTN_*`). Restart returns to the login screen, Exit quits,
Help prints the controls, and Option opens the settings panel (the F3
debug panel, which already carries the working UI scale, chat font, name
range and the three camera views). The authored Option window
(`ifoption.txt` with its Video/Audio/Camera/Game/Input sub-windows) is a
later item; its View radios are the camera views this project already has.

## Hundred-and-thirty-seventh round: the camera off the body, the sword on the hand, gear on the way in

Three from the second playtest.

**"When I click it moves the camera, jarringly."** The SpringArm3D hung
from the player's CharacterBody3D, and a click turns the body to face the
way it walks -- so the camera turned with it, every click. It now hangs
from a `CameraPivot` of its own that takes the body's position each
physics tick and nothing else, and the original's three views (the names
its Option window uses) decide the rest: *Free Movement View* (default)
-- follows position, yaw and pitch are the player's to drag and nothing
else moves them; *Third Person View* -- the pivot turns with the
character, drags do nothing; *Quarter Angle View* -- pitch locked, yaw
free. The quarter pitch (-55) and the third-person turn rate (360 a
second) are choices. Rendered: a walk east with the camera at yaw 200
keeps the camera at yaw 200.

**"He is holding the sword wrong."** The item hung from the hand with its
model origin on the bone, which let the item skeleton's own root rest
cancel out of the picture. `dump_bsk.gd` reads that rest: `sword_01.bsk`'s
Bone01 is a near-180-degree turn, `blade_01.bsk`'s exactly 180 about Y --
a rest that only means something if the root bone is what lands on the
hand. Undoing it under the attachment puts the root bone on the hand, and
the sword hangs tip-down at the side (rendered) instead of flat and
forward. The composition was chosen by rendering both, not read from the
client.

**"My pre-existing character doesn't have any gear."** The starting kit is
given at creation, and this character predates it. An enter-world hook
(`session.WorldHandlerWithHook`) now dresses a character that enters
wearing nothing with nothing in the bag -- stated: a character who took
everything off and emptied the bag is dressed again too, the cheaper
mistake on a test server.

## Hundred-and-thirty-sixth round: the black houses of Alexandria

Every `alex_minga` house drew solid black, on the player's archive and on
the box's, with the ground, stalls, walls and trees beside them textured.
Ruled out in order: the textures (every one found; `alex_minga01_wall01`
decodes as a 256x512 DXT1 sandstone panel), the mesh (`alex_minga02_arch01`
parses with its material name matching a layer), the material flags (the
same `0x0140` / `0x0341` as Jangan's). Then the colours, which
`dump_bmt.gd` did not print until tonight: **24 of the 40 layers of
`alex_minga02.bmt` carry diffuse `(0.14, 0.14, 0.14)` against ambient
`(0.59, 0.59, 0.59)`**, where every Jangan layer measured has ambient
0.59 and diffuse 0.59, 0.47 or 0.50.

The five colour fields are a `D3DMATERIAL9` in its own order, and the
fixed-function pipeline multiplies the ambient light by the ambient
colour and only the directional light by the diffuse. `ObjectLoader`
set the albedo from the diffuse -- invisible where the two are equal,
black where they are not. It now uses the ambient, and the houses
render (BMT_FORMAT.md has the measurement). Stated, not hidden: a
`StandardMaterial3D` scales the sun by the same colour, so a sunlit face
of such a layer is brighter here than in the original by
diffuse/ambient; the exact split is a shader's `light()` function, a
later round.
