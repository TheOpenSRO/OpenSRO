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
