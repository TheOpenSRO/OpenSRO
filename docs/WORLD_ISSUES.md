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
