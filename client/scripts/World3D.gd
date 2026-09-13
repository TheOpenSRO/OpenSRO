extends Node3D

## The one real client scene, reached directly from CharacterSelect.gd: a
## player-controlled CharacterBody3D moving over a placeholder flat ground,
## synced to the server over OpMove/OpEntityEntered/OpEntityMoved/
## OpEntityLeft. Other connected characters render as simple labeled
## capsules at their real, server-authoritative positions, or a real
## assembled character if real game data is loaded (see below). Its full
## UI (chat, monsters/combat, inventory, equipment, quests, shop, party,
## guild, duel, trade, friends) was ported here from the original 2D
## World.tscn, which has since been deleted -- see docs/PROGRESS.md.
##
## The ground is a placeholder collision box by default, but both its
## *visual* mesh and its *collision* shape are replaced by real terrain if
## you set SRREVAMP_MAPM_PATH to a real Map.pk2 region .m file (see below)
## -- .mapm's grid width (17) is now a real, mechanistically confirmed
## constant (see docs/protocol/MAPM_FORMAT.md and MapmTerrainBuilder), not
## the unresolved blocker it used to be. The real collision shape is a
## ConcavePolygonShape3D built directly from the same real triangle data as
## the visual mesh (Mesh.create_trimesh_shape() -- no separate collision
## geometry to keep in sync), so the player physically walks on the actual
## real terrain surface, not a flat box, whenever real terrain data loads.
## The terrain's real world position/scale relative to a player's actual
## spawn coordinate is still unconfirmed -- it's placed near the player for
## visibility, not at a confirmed real-world offset. Other entities are
## still labeled capsules -- there's no confirmed mapping from a
## server-side character to
## a specific real asset (this project's server doesn't track a
## race/gender/equipment loadout per character yet), so every *other*
## player shows the same placeholder regardless of who they really are.
##
## The *player's own* body is no longer a placeholder if you point this
## project at your own real game data (this project ships with none --
## BYO, see docs/LEGAL.md): set SRREVAMP_PK2_PATH to a real Data.pk2 and
## SRREVAMP_MEDIA_PK2_PATH to a real Media.pk2, and the character is
## assembled the way the game assembles it. The body is a row of
## characterdata (`CHAR_CH_MAN_FIGHTER` -> `char\china\chinaman_fighter.bsr`,
## see GENDER_BODY_CODE), a `.bsr` naming the skeleton, nine skinned body
## pieces, the material and 217 animations. What it wears is the server's
## word: each equipped slot's item id is looked up in the item table for the
## model that item is worn as (column 52, `item\china\man_item\
## clothes_01_ba.bsr` for the Cotton Suit), and that `.bsr` says how it
## hangs -- weighted onto the body's bones, or on a skeleton of its own
## under one named body bone (a blade on `Bip01 R HandMid`, a shoulder
## piece on `Bip01 Neck1`). See docs/protocol/ITEM_FORMAT.md.
##
## A newly-created character wears the starting kit the server gave it;
## an item whose id the table does not know is left undrawn rather than
## stood in for. Falls back to the placeholder capsule if the body itself
## cannot be built.
##
## Other connected players are dressed the same way from the same data:
## their gender and every worn item's id come in each EntitySnapshot
## (OpEnterWorldResult/OpEntityEntered, queried live from the equipment
## store -- see equippedItems in server/internal/session/world.go).
##
## SRREVAMP_PK2_PATH + SRREVAMP_BSR_PATH also loads one real, textured
## static scenery object nearby via ObjectLoader, and
## SRREVAMP_BSK_PATH + SRREVAMP_BAN_PATH loads a real animated decoration
## skeleton (its own separate .bsk/.ban pair, not the player's body) via
## Skeleton3DBuilder -- both accept either a loose file path or a path
## inside SRREVAMP_PK2_PATH (see AssetSource). SRREVAMP_MAPM_PATH loads real
## terrain (a real Map.pk2 region's .m file, e.g. "100\\100.m") via
## MapmTerrainBuilder -- Map.pk2 is a separate archive from Data.pk2 in a
## real retail install, so it accepts either a loose file or a path inside
## SRREVAMP_MAP_PK2_PATH (its own separate pk2 env var, not
## SRREVAMP_PK2_PATH). SRREVAMP_MAPM_TEXTURE_PATH additionally textures that
## terrain with a real per-region minimap image (e.g. "minimap\\100x100.ddj",
## matching the same region number as SRREVAMP_MAPM_PATH) -- these live in
## Media.pk2, a third separate archive, so it accepts either a loose file or
## a path inside its own SRREVAMP_MEDIA_PK2_PATH. Falls back to real
## per-tile vertex-color variation (see MapmTerrainBuilder) if unset -- no
## real-time 3D ground-texture system has been found yet (see
## docs/protocol/MAPM_FORMAT.md), so a region's own real minimap art is the
## closest real, region-accurate substitute currently available.
## SRREVAMP_MAPO_PATH loads real placed objects (a real Map.pk2 region's
## .o file, e.g. "0\\0.o", via SRREVAMP_MAP_PK2_PATH) and renders each with
## its real resolved .bsr model -- not a placeholder marker -- via a real
## type-ID-to-resource-path lookup (a real, root-level "object.ifo" file
## inside SRREVAMP_PK2_PATH's Data.pk2, see docs/protocol/MAPO_FORMAT.md
## for how this was found; it was a confirmed dead end earlier in this
## project). Any
## variable left unset is skipped gracefully (a printed hint, not an error)
## -- this scene works fine with none of them set, same as always.
##
## The server now has a real multi-zone concept: OpChangeZone/
## OpChangeZoneResult (NetClient.change_zone/change_zone_result) let a
## character warp between zone labels. This scene reacts to a successful
## change (_on_change_zone_result): it tears down whatever real
## terrain/map-object nodes are currently loaded ("RealTerrain"/
## "RealMapObjects") and reloads them for the new zone, via _zone_paths --
## a zone label shaped like this project's real Map.pk2 region naming
## ("<x>/<y>", e.g. "100/100") resolves to that region's real internal
## paths ("100\\100.m", "100\\100.o", "minimap\\100x100.ddj"), the same
## convention SRREVAMP_MAPM_PATH/SRREVAMP_MAPO_PATH's doc comments above
## already describe. The server's own default spawn zone, "jangan", is a
## special case resolved by _resolve_zone_region to the real region this
## project found Jangan actually lives in (JANGAN_ZONE_REGION, "98/168" as
## of **2026-09-01** -- see that constant's own doc comment for the real
## back-and-forth: an earlier, higher-*keyword-density* match ("89/182")
## turned out to be a real, confirmed isolated pocket surrounded by void,
## which dropped the player through an unbounded fall when walked into;
## "98/168" sits inside the same real, single, fully contiguous landmass as
## the already-verified Dunhuang region) rather than falling through to
## "nothing to load" the way it used to before Jangan was found at all. Any
## other zone not shaped like a real region still clears back to
## the placeholder ground with nothing loaded -- honest "nothing to load",
## not a guessed path. The *initial* load in _ready() still reads the raw
## env vars directly rather than going through a zone label, since the very
## first EnterWorldResult's zone isn't available yet at that point.

## **Rescaled 2026-08-26** (see docs/WORLD_ISSUES.md's "size of ants" entry):
## every player-relative constant below (movement, camera, click-to-move,
## network-send thresholds, the placeholder capsule) used to be tuned
## around a fixed, invented 1.8-unit character height that was never
## checked against the real environment's own native scale. A real
## measurement (forward-kinematics over a real chinaman_skel.bsk's real
## bind-pose bones) found the real native character height is ~138.7
## units -- the same real order of magnitude as real measured building
## features (walls ~44.5, doors ~72-76, trees ~97-140), which all already
## render unscaled. PLAYER_SCALE_RATIO (real 138.7 / old 1.8) rescales
## every one of these constants by the same factor, preserving their
## previously-tuned *feel* relative to the character's own height rather
## than guessing new values at the new scale.
## Real, confirmed bug (2026-09-01, see docs/WORLD_ISSUES.md): the placeholder
## Ground body and every real terrain patch's collision both defaulted to
## Godot's default collision_layer (bit 1), the same layer every real
## placed-object (.bsr building) collision body also defaults to in
## ObjectLoader -- nothing distinguished "the actual ground" from "the roof
## of a tall building standing on that ground" to a raycast that just takes
## whichever surface it hits first from high above. Since the real fixed
## server spawnPos (0,0,0) can land under/inside a real building (already
## known, see _avoid_spawning_under_roof's own doc comment), a tall real
## structure sitting exactly at the spawn X/Z meant the very first
## ground-snap raycast in _snap_player_onto_terrain hit that building's
## real roof, not the real ground beneath it -- spawning the player on top
## of a tower instead of on the ground, a real bug _avoid_spawning_under_roof
## can't catch (it only checks for a real ceiling *above* an
## already-landed position, not whether "landed" means "on a roof" in the
## first place). Fixed by giving terrain collision its own dedicated layer
## bit (kept alongside the default layer 1, so every other real collision
## check -- movement, click-to-move, camera collision -- is unaffected) and
## having the initial ground-snap ray target only that bit.
const TERRAIN_COLLISION_LAYER := 0b1001 # layer 1 (default) + layer 4 (terrain-only)
const TERRAIN_ONLY_COLLISION_MASK := 0b1000 # layer 4 only

## Real navmesh walls (see _try_add_navmesh_walls) get their own layer bit,
## deliberately *not* the default layer 1, because they are invisible
## gameplay boundaries rather than visible geometry. The player's own body
## masks this bit in (World3D.tscn), so they are stopped by them; the camera
## spring arm does not, because a camera shoved aside by geometry nobody can
## see reads as a bug, and it is the same class of mistake the terrain layer
## above was added to fix.
const NAVMESH_WALL_COLLISION_LAYER := 0b10000 # layer 5 only

## An NPC's own body.
##
## Standing NPCs were walk-through: they are a Skeleton3D under a Node3D and
## nothing else, so a player crossing Jangan's square passed straight
## through the merchants. The capsule below is sized from the model's own
## geometry -- these models differ enormously, and one radius that suits a
## merchant swallows a horse.
##
## **Layer 5, the same bit the navmesh walls use**, because the player's
## body masks it (`collision_mask = 17` in World3D.tscn) and the camera arm
## does not (`collision_mask = 1`). That is precisely what an NPC wants: it
## stops you walking into it, and it does not shove the camera around every
## time you stand in a crowd of them. Putting them on the default layer 1
## instead would have made Jangan's square unusable to look at.
const NPC_COLLISION_LAYER := NAVMESH_WALL_COLLISION_LAYER
## Monsters sit on their own layer so a click can pick one out to attack it
## without a monster blocking movement or catching the ground-snap ray.
const MONSTER_COLLISION_LAYER := 0b100000 # layer 6 only

## Smallest capsule an NPC gets, in world units, so a model whose bones all
## sit near the origin still stops someone.
const NPC_MIN_RADIUS := 0.25
const NPC_MIN_HEIGHT := 1.0

## How tall a real blocking navmesh edge is extruded. **A disclosed choice,
## not real data**: the real client tests an edge as an infinite 2D line
## (see docs/protocol/NVM_FORMAT.md's "Edge flag semantics" section), so
## nothing in the game gives a wall a height at all. Comfortably above the
## player capsule's own 3.19 radius so it cannot be stepped over.
const NAVMESH_WALL_HEIGHT := 40.0

## Real per-region navmesh inside Data.pk2, named by the real packed region
## ID -- this is the client's own real format string, recovered from its
## loader (`sprintf_s(buf, 0x400, "navmesh\\nv_%04x.nvm", regionId)`), and
## the real packing is `(x << 8) | y`. See docs/protocol/NVM_FORMAT.md.
const NAVMESH_PATH_FORMAT := "navmesh\\nv_%04x.nvm"

## Real region-to-zone name table. Really does live in Data.pk2's shader
## folder rather than anywhere map-shaped -- see
## docs/protocol/REGIONINFO_FORMAT.md.
const REGIONINFO_PATH := "Shader\\regioninfo.txt"

## **Corrected 2026-09-02** (see docs/WORLD_ISSUES.md's forty-eighth
## round): was `138.7 / 1.8`. The 138.7 came from an earlier claimed
## forward-kinematics measurement of the real character's native height,
## but that figure is simply wrong -- two independent runtime measurements
## of the *actually assembled* real character (its real skeleton's own
## bind-pose bone extent, and the real world-space AABB of every mesh
## attached to it) both come out at **14-16 units**, not 138.7. Everything
## derived from this ratio (camera distance, move speed, gravity,
## click-to-move thresholds, the placeholder collision capsule) was
## therefore scaled roughly 10x too large, which is what made the real
## character render as a distant speck: the camera was parked ~8 character
## heights away.
##
## Now derived from the real measured height instead of a wrong constant.
## 1.8 stays as the notional "human metres" denominator the movement/camera
## feel was originally tuned against, so those tunings keep their intended
## proportion to the character rather than being re-guessed.
##
## **Honest open question, deliberately not guessed at**: real map objects
## measured alongside this (a real chair 12.5 units, table 10.8, standing
## lamp 19.9, guardian lion statue 29.0) are self-consistent with each
## other but make a 14.3-unit character read as roughly chair-height --
## short for an adult. That suggests the real client may apply its own
## character scale factor this project hasn't found yet. No such factor is
## invented here; this constant only corrects a provably wrong measurement.
const REAL_CHARACTER_NATIVE_HEIGHT := 14.34
const PLAYER_SCALE_RATIO := REAL_CHARACTER_NATIVE_HEIGHT / 1.8
const MOVE_SPEED := 6.0 * PLAYER_SCALE_RATIO
const GRAVITY := 20.0 * PLAYER_SCALE_RATIO

## How high a step the player can walk up, as a fraction of their own real
## capsule height (so it scales with the character rather than being a bare
## number). 0.22 of the real 14.34 capsule is 3.15 units.
##
## **Sized against the real architecture, measured, not picked.** Three real
## staircase assets were loaded and their own tread heights read off:
## `guil_jang_stair01_01` (median riser 3.05), `jang_guild_buil01_stair01`
## and `cj_mili_horstair` (3.00 each, with real tread levels at 2.75, 5.75,
## 8.8, 11.8, 14.75, 17.75, 20.75...). So a **real riser is 3.0 units**, and
## this clears it with a little margin while staying well under anything
## wall-shaped. That the real risers are a fifth of the real character's own
## height also says the character is not mis-scaled against the world, which
## had been a live suspicion.
##
## That there is a step height *at all* is still a disclosed approximation.
## The real client has none, because it never collides with stair geometry:
## it walks the real navmesh cell/edge graph and takes its height from there
## (see docs/protocol/NVM_FORMAT.md). Real raised surfaces are carried by
## the real `.nvm`'s own `MapObject` entries -- per-object walkable meshes
## `NvmReader` already parses but nothing uses yet. Reproducing that is the
## faithful fix; until it exists, a physics character needs some step height
## or real stairs are simply unclimbable.
const STEP_HEIGHT_FRACTION := 0.22

## Real Silkroad-style mouse controls: right-drag orbits the camera around
## the player (independent of the player's own facing), left-click on the
## ground walks the player there, and the scroll wheel zooms. WASD/arrow
## keys (the original, still-supported controls) immediately cancel any
## active click-to-move target, matching the normal MMO convention that
## manual movement input always overrides a pending destination.
const CAMERA_ORBIT_SENSITIVITY := 0.3 # degrees of camera rotation per pixel of mouse drag
## Real, empirically-confirmed sign convention (2026-08-26, see
## docs/WORLD_ISSUES.md): SpringArm3D pushes its child to local *+Z*, not
## -Z, so a *negative* CameraArm pitch is what lifts the camera above and
## behind the player -- the previous +42 base pitch (with a compensating
## 180 yaw and a 180 yaw flip on Camera3D itself) actually pushed the
## camera down and in *front* of the player, immediately collapsing
## against the ground via the spring's own collision check. That's the
## real root cause of the reported "FPS-like camera" bug, confirmed via a
## headless SpringArm3D probe (spring pushes a child to local (0,0,+L)).
## -80 (nearly straight overhead) to -10 (nearly flat behind) is the real
## valid range for a top-down-behind view under this corrected convention.
const CAMERA_PITCH_MIN_DEGREES := -80.0
const CAMERA_PITCH_MAX_DEGREES := -10.0
## How far one scroll notch moves the camera, in world units. Sized against
## the CAMERA_ZOOM_MIN..MAX range below (20..90) so the full range takes a
## handful of notches rather than one flick or twenty. **Doc corrected
## 2026-09-02**: the previous comment here derived this from a ~139-unit
## character height, which REAL_CHARACTER_NATIVE_HEIGHT has since shown to
## be wrong by roughly 10x (the real assembled character measures ~14.3
## units), so that reasoning no longer applies.
const CAMERA_ZOOM_STEP := 15.0
## Third-person camera distance range, in world units.
##
## **Widened 2026-09-02** (see docs/WORLD_ISSUES.md's fifty-fifth round).
## These were previously derived from vertical-FOV math -- "the closest
## distance that still fits the whole character in frame" -- which answers
## a different question than "where should a third-person MMO camera sit".
## After REAL_CHARACTER_NATIVE_HEIGHT corrected the character to ~14.3
## units, that math gave a 12.4-24.8 range, i.e. under two character
## heights, so the character filled the frame and almost no world was
## visible around them.
##
## Chosen instead from real side-by-side renders of the real Dunhuang ferry
## region at several distances: ~45 units (about 3 character heights) frames
## like a real third-person MMO -- the character reads clearly while the
## surrounding real terrain, buildings and horizon stay visible. The range
## brackets that so a player can pull in close to inspect their character or
## pull back for situational awareness.
##
## Unlike the terrain and skeleton constants elsewhere in this project, this
## is an openly-declared **framing choice**, not a value recovered from real
## game data -- no real camera-distance data has been found. It is stated
## that way rather than dressed up as a measurement.
const CAMERA_ZOOM_MIN := 20.0
const CAMERA_ZOOM_MAX := 90.0
## The scene's own authored default CameraArm.rotation_degrees (see
## World3D.tscn) -- orbit-dragging (right-click) moves the arm's *local*
## yaw/pitch away from this and nothing ever moved it back, so after any
## orbit the camera stayed stuck at whatever angle it was last dragged to
## even as the player kept walking around -- the real cause of "camera
## isn't centered on my character" (2026-08-27 real user report). Recenters
## back to this default automatically while the player is moving and not
## actively orbiting, the same auto-realign behavior most third-person
## MMO cameras use.
const DEFAULT_CAMERA_PITCH_DEGREES := -42.0
## **Corrected 2026-08-31** (see docs/WORLD_ISSUES.md's thirty-first round):
## was 0.0, matching the scene's old CameraArm yaw -- both were real,
## confirmed wrong. rotation.y = atan2(dir.x, dir.z) (this file's own
## movement code) makes the player's local *+Z* face the movement
## direction, confirmed via a real textured render of the assembled
## character to be the character's real anatomical *front* (chest/abs
## texture, not spine). The old CameraArm pushed to that same local +Z with
## zero added yaw, meaning the default (non-orbited) camera sat on the
## character's *front* side, not behind them -- backwards from the
## intended over-the-shoulder third-person convention, and the real root
## cause of the "front/back texture swap" report (the user was already
## looking at the real front by default; rotating further showed the real
## back). 180.0 puts the camera on the correct side.
const DEFAULT_CAMERA_YAW_DEGREES := 180.0

## The three views the original's Option window offers, by the names it
## gives them. The camera arm hangs from a pivot that follows the player's
## *position* only (not the body's turn -- as a child of the body it swung
## round every time a click turned the character), and the view decides
## what else the pivot and the arm do:
##   free          -- follows position; yaw and pitch are the player's to
##                    drag, and nothing moves them otherwise (the default)
##   third_person  -- the pivot turns with the character, so the camera
##                    sits behind whichever way they face; drags do nothing
##   quarter       -- pitch locked, yaw free to drag
## The quarter view's pitch and how fast the third-person view turns are
## this project's choices; nothing found gives the original's numbers.
const CAMERA_VIEW_FREE := "free"
const CAMERA_VIEW_THIRD_PERSON := "third_person"
const CAMERA_VIEW_QUARTER := "quarter"
const CAMERA_VIEWS := [CAMERA_VIEW_FREE, CAMERA_VIEW_THIRD_PERSON, CAMERA_VIEW_QUARTER]
const QUARTER_VIEW_PITCH_DEGREES := -55.0
const THIRD_PERSON_TURN_DEGREES_PER_SECOND := 360.0
var _camera_view := CAMERA_VIEW_FREE
var _camera_pivot: Node3D = null

func set_camera_view(view: String) -> void:
	if not CAMERA_VIEWS.has(view):
		view = CAMERA_VIEW_FREE
	_camera_view = view
	match view:
		CAMERA_VIEW_THIRD_PERSON:
			camera_arm.rotation_degrees = Vector3(DEFAULT_CAMERA_PITCH_DEGREES, DEFAULT_CAMERA_YAW_DEGREES, 0.0)
		CAMERA_VIEW_QUARTER:
			camera_arm.rotation_degrees.x = QUARTER_VIEW_PITCH_DEGREES
			if _camera_pivot != null:
				_camera_pivot.rotation.y = 0.0
		_:
			if _camera_pivot != null:
				_camera_pivot.rotation.y = 0.0

## Keeps the pivot on the player and, in the third-person view, turned the
## way they face.
func _follow_with_camera(delta: float) -> void:
	if _camera_pivot == null:
		return
	_camera_pivot.global_position = player.global_position
	if _camera_view == CAMERA_VIEW_THIRD_PERSON:
		_camera_pivot.rotation.y = rotate_toward(
			_camera_pivot.rotation.y, player.rotation.y,
			deg_to_rad(THIRD_PERSON_TURN_DEGREES_PER_SECOND) * delta)
## How close player must get to a click-to-move target before it's
## considered reached and cleared -- without this, the player would
## oscillate forever trying to reach an exact point every physics frame.
const MOVE_TARGET_STOP_DISTANCE := 0.3 * PLAYER_SCALE_RATIO

var _camera_orbiting := false
var _right_button_held := false
var _left_button_held := false
var _left_dragging := false
var _left_press_position := Vector2.ZERO
# Holding the left button and dragging steers the character toward the
# cursor (the original's left-drag-to-walk); it never orbits the camera.
var _left_steering := false
## How far the mouse has to travel with the left button down before the
## press counts as an orbit rather than a click. Ours.
const LEFT_DRAG_THRESHOLD_PIXELS := 6.0
var _has_move_target := false
var _move_target := Vector3.ZERO
## Last position the player was standing at real, sane terrain height (see
## WORLD_FLOOR_Y's doc comment) -- updated every physics frame the player
## isn't already mid-void-fall, so it always reflects the most recent solid
## ground they were actually on, regardless of CharacterBody3D's own
## is_on_floor() (observed real, separate quirk: stays false indefinitely
## for a character that's stationary since spawn and never yet received
## real velocity, unrelated to this fix -- worth its own investigation, not
## chased here).
var _last_grounded_position := Vector3.ZERO
## Real, confirmed finding (2026-09-01): the region grid this client
## streams (_load_region_neighborhood/_maybe_stream_regions) assumes every
## adjacent region coordinate has a real Map.pk2 .m file, but a direct
## listing of the real archive (server/cmd/pk2list against a real Map.pk2)
## shows that's false even immediately around Jangan (89/182) -- e.g.
## 90/182, one REGION_SPAN east, has no .m file at all, while 91/182 two
## REGION_SPAN east does (real desert terrain). Walking into one of these
## real gaps previously dropped the player through an unbounded void
## forever (no terrain, no collision, nothing to land on) -- confirmed via
## a real physics simulation that fell for over 60 real physics frames with
## no floor found. Every real per-region height measured so far falls in
## roughly 0-250 units, so -500 is a generous floor no legitimate terrain
## should ever cross; anything below it can only be a real gap.
const WORLD_FLOOR_Y := -500.0

## Aerial-perspective haze strength. See _apply_real_environment_lighting for
## the real recovered model this feeds (real per-channel extinction
## `exp(-(beta_1+beta_2) * s)` plus additive inscattering, from the real client
## terrain shaders shipped in Data.pk2's `Shader\` folder).
##
## **A disclosed rendering choice, not real data**, the same as
## BOUNDARY_BLEND_ALPHA: the real scattering coefficients are runtime shader
## constants, and environment.ifo's own two real scalar fog channels hold
## normalized [-1, +1] values rather than world distances, so the real density
## isn't recoverable from the asset data.
##
## **Lowered 2026-09-05** from 0.00015, which was chosen to leave one region
## span (1920 units) about a quarter hazed and the far edge of the 5x5 grid
## (5760 units) about three-fifths hazed. That turned out to hide real data:
## reported from a real playtest of real Asia Minor as a "white floor", and
## confirmed by rendering the same frame with fog on and off -- the real
## ground textures are correct and richly coloured (real green grass, real
## tan sand, real brown dirt) and the haze was washing all of it out. A
## setting that erases real recovered detail at ordinary walking distance is
## the wrong disclosed choice regardless of taste.
##
## At 0.00005, with Godot's `1 - exp(-density * depth)`, the player's own
## region span is about a tenth hazed, the far edge of the streamed 5x5 grid
## about a quarter, and distant terrain still fades -- so real aerial
## perspective stays, and real ground detail survives. Still a disclosed
## choice, only now one bounded by real evidence rather than by feel.
const FOG_DENSITY := 0.00005

## How much the haze brightens toward the sun -- Godot's approximation of the
## real Henyey-Greenstein phase term in the real terrain vertex shader. Also a
## disclosed choice, not real data (see FOG_DENSITY).
const FOG_SUN_SCATTER := 0.1

## How strongly the haze takes its color from the sky behind it rather than
## from fog_light_color alone. Also a disclosed choice (see FOG_DENSITY); kept
## partial so the real per-zone FogColor still reads as itself.
const FOG_AERIAL_PERSPECTIVE := 0.5
## Minimum real-world distance moved, and minimum time elapsed, before
## sending another OpMove -- avoids flooding the connection with a packet
## every single physics frame while walking. **Raised 2026-08-26** (see
## docs/WORLD_ISSUES.md) from 0.1 (10/sec) -- a real playtest found other
## players' movement visibly stuttering, root-caused to this send rate
## combined with zero interpolation on the receiving end (see
## _other_body_targets). Interpolation is the real fix for the visual
## stutter itself; this is raised too so the interpolated target updates
## often enough to track a fast-moving real player closely, not as a claim
## about any real client's own network rate.
const MIN_SEND_INTERVAL := 0.05
const MIN_SEND_DISTANCE := 0.05 * PLAYER_SCALE_RATIO
## How quickly (per real second, exponential catch-up rate) another
## entity's visual body closes the gap to its latest known real position --
## see _other_body_targets. A real engineering tuning choice, not
## reverse-engineered client behavior: high enough to visually catch up
## well within one real MIN_SEND_INTERVAL period at typical real
## MOVE_SPEED, not a claim about real interpolation timing.
const OTHER_BODY_INTERPOLATION_SPEED := 15.0

## The body each gender is drawn with: a row of characterdata, the same
## table that names every NPC's model, by its code name. Ids 1907-1932 of
## that table are the 26 playable China classes -- adventurer, bogy,
## fighter, merchant, monk and the rest, 13 to a gender -- and each row's
## `.bsr` lists the body's skeleton, its nine skinned pieces, its material
## and its animations. Nothing about the body is guessed from a path
## layout any more.
##
## **Which class is a fixed pick.** The server stores a gender and nothing
## finer, so "fighter" is chosen here for both -- the same style the earlier
## per-gender path table already used for the face and hair. A class
## choice at character creation would replace this table, not this code.
const GENDER_BODY_CODE := {
	"china_man": "CHAR_CH_MAN_FIGHTER",
	"china_woman": "CHAR_CH_WOMAN_FIGHTER",
}
## Falls back to this real gender's assets when a requested gender's assets
## didn't load (or a peer reports an unrecognized gender string) -- matches
## character.DefaultGender server-side.
const DEFAULT_GENDER := "china_man"

## Which animation group a held weapon selects, by the weapon's TypeID4 in
## the item table: the client's own switch (`FUN_00a5a7d0`, reached from
## the equip-visual refresh with the item in the weapon slot), checked
## against the real table's weapon rows -- 215-251 rows behind every case
## (ITEM_FORMAT.md). Two of the client's rules are not in this table: while
## pulling a transport the group is `cart` whatever the weapon, and the
## fortress weapon (16) is `sword` for a China character and
## `onehand_sword` for a European one -- every body here is China.
const WEAPON_ANIMATION_GROUP := {
	2: "sword", 3: "sword",  # sword, blade
	4: "spear", 5: "spear",  # spear, glaive
	6: "bow", 12: "bow",  # bow, crossbow
	7: "onehand_sword",
	8: "twohand_sword",
	9: "dual_axe",
	10: "onehand_staff", 15: "onehand_staff",  # dark staff, cleric rod
	11: "twohand_staff",
	13: "dagger",
	14: "harf",  # the harp, as the client spells it
	16: "sword",  # fortress weapon, China
}

## The fallback for a body whose `.bsr` carries no animation groups: the
## exact files the China fighters' `default` group names, matched by name.
const BODY_ANIMATION_HINTS := {
	"idle_anim": ["_fighter_standcity.ban", "_standcity.ban", "stand"],
	"walk_anim": ["_fighter_walkforward.ban", "_walkforward.ban", "walk"],
	"run_anim": ["_fighter_runforward.ban", "_runforward.ban", "run"],
	"hit_anim": ["_a_benormalhit.ban", "benormalhit"],
	"death_anim": ["_a_diehardhit.ban", "diehardhit.ban"],
}

## Real file inside Data.pk2 (SRREVAMP_PK2_PATH) mapping a real .mapo
## placement's type ID to a real .bsr resource path -- see
## docs/protocol/MAPO_FORMAT.md and ObjidxReader for the full derivation.
## This was a confirmed dead end earlier in this project (no such mapping
## had been found); it turned up once server/internal/pk2's directory-chain
## bug was fixed, since this file lives inside a real archive folder that
## bug was silently dropping from every listing. **Corrected (2026-08-22,
## from a real live playtest against a real retail client)**: this is under
## a real `navmesh\` folder, not pk2 root as this project originally
## assumed -- MAPO_FORMAT.md's "root level" claim was wrong.
const OBJECT_INDEX_PATH := "navmesh\\object.ifo"
## Map.pk2's own object index, which is *not* the same table as Data.pk2's
## OBJECT_INDEX_PATH above. In a real client the map's has 3307 entries
## against the data one's 3268, and those extra 39 ids are exactly the ones
## real region placements were referencing and this project was silently
## dropping -- 59 skipped placements in real Jangan's town region alone
## (OBT/halloween/new-year event decorations, plus a few NPCs). Placements
## are read out of Map.pk2, so Map.pk2's table is the one that indexes
## them; Data.pk2's stays a fallback for a client that only has that
## archive. Found 2026-09-07 after a real playtest reported objects
## missing from the town.
const MAP_OBJECT_INDEX_PATH := "object.ifo"
## Real per-vertex ground-tile classification table -- see
## docs/protocol/TILE2D_FORMAT.md (TileIndexReader). Confirmed present at
## this real path (and, identically, at pk2 root) in a real Data.pk2.
const TILE_INDEX_PATH := "navmesh\\tile2d.ifo"
## How many real *placements* from SRREVAMP_MAPO_PATH's region to
## instantiate -- an arbitrary, honestly-scoped cap, not a real engine
## limit. Distinct real .bsr models are only parsed once each and
## duplicated for repeat placements (see _try_load_real_map_objects), so
## this mostly bounds real node/instance count, not real file parsing.
## **Raised from 300 (2026-08-26, see docs/WORLD_ISSUES.md)**: a real
## side-by-side comparison against a real live server screenshot of Jangan
## showed most of the real ground-cover grass and decoration missing --
## Jangan's own real region has 863 real placements (.o + .o2 combined),
## so the old 300 cap was silently dropping most of them, in placement
## order, well before reaching the grass/decoration entries. Since the
## expensive part (parsing each *distinct* real .bsr) already happens once
## per unique model regardless of this cap, and the rest is cheap
## duplication, raising it is low-cost -- not perf-verified against a real
## very dense region beyond Jangan's 863, but comfortably covers it with
## headroom.
const MAX_MAP_OBJECTS := 2000

## World-space spacing between adjacent *regions* in _load_region_neighborhood.
## **Real, confirmed value (2026-08-22)**: a real per-region world size
## decompiled directly out of a real cross-region movement function in
## `sro_client.exe` (`RegionManagerBody.cpp`) -- see
## docs/protocol/MAPM_FORMAT.md. Independent of TILE_SIZE (an earlier
## same-day version of this constant derived it from TILE_SIZE, which
## conflated "one region" with "one sub-patch" -- corrected, see
## MapmTerrainBuilder.TILE_SIZE's doc comment). Real per-region *adjacency*
## (whether the real world even lays regions out on a uniform grid at all)
## still isn't confirmed, but the *spacing magnitude* is.
const REGION_SPAN := 1920.0
## How many real regions out from the center region to try loading in each
## direction -- radius 2 means a 5x5 grid (25 regions attempted, however many
## actually exist as real files). Raised from 1 (2026-08-26, see
## docs/WORLD_ISSUES.md) now that Pk2Reader caches directory reads (this
## session's ~3-minute-load-time fix) -- the real per-region cost was
## dominated by redundant pk2 directory re-reads, not mesh building, so this
## should mostly trade a larger loaded-terrain footprint (fewer real
## "edge of loaded world" holes a player can walk to and see sky through)
## for a smaller relative load-time increase than radius 2 would have cost
## before that fix. Not yet perf-verified against a real large pk2 dataset
## in this environment -- flagged honestly, not asserted as free.
const REGION_LOAD_RADIUS := 2
## How far below the solid geometry the walkable graph may sit before a
## spot counts as one the player would walk underneath. A real surface and
## the real navigation mesh built for it are not the same surface -- the
## navigation mesh is authored a little above or below the visible floor --
## so a small disagreement is normal. Half the player's own height is not.
const STAND_UNDER_TOLERANCE := 7.0
## How far a placed object may sit off the ground under it before it counts
## as floating. Real scenery is authored a little into or above the terrain
## and a small gap is normal; a player-height gap is not.
const FLOATING_TOLERANCE := 12.0
## How many offending objects the float report lists. Enough to group them
## by model and see whether an offset is a property of the model, of the
## region, or of neither.
const QA_FLOAT_MAX_ROWS := 200

## Real region streaming (2026-08-24): the original fixed 3x3 grid only
## ever loaded once, centered on wherever a zone's initial spawn/entry
## point was -- a player who kept walking in one direction would
## eventually walk off the edge of loaded terrain into the placeholder
## void, since nothing re-triggered loading as they moved. These track
## enough state for _maybe_stream_regions() (called every
## _physics_process) to load/unload real region cells as the player
## actually moves, keeping a real REGION_LOAD_RADIUS window centered on
## wherever they are, not just where they started.
##
## _grid_origin_region/_grid_origin_world anchor the mapping between real
## region coordinates and Godot world space: _grid_origin_world is
## whatever world position the real (dx=0, dy=0) cell's own terrain_group
## ended up at (captured once, right after it loads) -- every other real
## cell's world position is `_grid_origin_world + Vector3(dx, 0, dy) *
## REGION_SPAN` by construction (see _load_region_cell), so this doesn't
## need to know the exact real per-cell placement bias (the half-REGION_SPAN
## centring offset) in closed form, just that it's identical for
## every cell. This mapping stays fixed for a zone's whole lifetime, even
## as cells stream in/out around it, so already-placed nodes never need to
## move.
var _grid_origin_region := Vector2i.ZERO
var _grid_origin_world := Vector3.ZERO
var _grid_shared_anchor_height := NAN
var _grid_has_origin := false
var _loaded_cells := {} # "dx_dy" (relative to _grid_origin_region) -> true
var _last_stream_cell := Vector2i(0x7fffffff, 0x7fffffff) # sentinel so the first real check always runs
# Region cells waiting to be built, streamed a few per frame instead of a
# whole leading row in one frame -- that synchronous row was the ~1s freeze
# on every boundary crossing (a playtest complaint). The cell underfoot is
# always already loaded (it was a neighbour before the crossing), so the
# queued cells are ahead of the player and can arrive over the next frames.
var _load_queue: Array = [] # of {rx, ry, dx, dy, anchor, key}
var _queued_cells := {} # key -> true, so a cell is not queued twice
const STREAM_CELLS_PER_FRAME := 1
# The "NOW LOADING" screen shown to a real player during world entry (never a
# QA render, whose synchronous load a screenshot depends on).
var _loading_screen: LoadingScreen
# Per-phase load timing accumulators (ms), for the entry profile.
var _load_ms_terrain := 0.0
var _load_ms_objects := 0.0
var _load_ms_npcs := 0.0

@onready var player: CharacterBody3D = $Player
@onready var player_mesh: MeshInstance3D = $Player/Mesh
## The third-person camera arm. It carries a real SphereShape3D in
## World3D.tscn rather than being left as a bare ray.
##
## **Added 2026-09-03.** With no shape, SpringArm3D sweeps a single infinitely
## thin ray from the player outward, which slips straight through any gap
## narrower than the camera's own near plane -- and the real Jangan spawn sits
## directly at the real palace gate (`cj_pal_bigdoor`), so the arm threaded the
## gate structure and parked the camera *inside* `CJ_pal_bigdoor_wall01`. A real
## headless render of the real spawn showed the bottom half of the window filled
## with an enormous blurry brick texture meeting the grass along a hard,
## perfectly straight horizontal line, which had been read for several rounds as
## a terrain texture-blending problem. It was not: raycasting from the camera
## through six widely-spread screen points returned that same wall collider at
## essentially one 3D point every time, meaning the surface was roughly a unit
## in front of the camera. Pulling the camera back to 400 units showed the real
## gate, roof, red walls, willows and stone plaza all rendering correctly the
## whole time -- the view was simply buried in a wall.
##
## Sweeping a real sphere instead cannot thread gaps narrower than its radius.
## The radius is a disclosed choice, not real data: just under the player
## capsule's own 3.19 radius, so anywhere the player themselves fits, the camera
## can follow.
@onready var camera_arm: SpringArm3D = $Player/CameraArm
@onready var camera_3d: Camera3D = $Player/CameraArm/Camera3D
@onready var ground_mesh: MeshInstance3D = $Ground/Mesh
@onready var ground_collision: CollisionShape3D = $Ground/Collision
@onready var other_entities: Node3D = $OtherEntities
@onready var world_environment: WorldEnvironment = $WorldEnvironment
## World3D.tscn's own light_energy = 0.3 (down from Godot's default 1.0,
## **2026-09-02**, see docs/WORLD_ISSUES.md's forty-third round): a real
## playtest found real desert terrain (Dunhuang) rendered as a flat,
## overexposed white/yellow wash. Root-caused with a real controlled
## render (directional light disabled entirely, flat white ambient only):
## the real sand ground texture itself is a perfectly normal tan color --
## the wash only appears once the directional light's own diffuse
## contribution stacks on top of ambient, together pushing bright real
## albedo values (sand is naturally pale) past 1.0 per channel. This
## project's Compatibility renderer doesn't apply a real HDR/filmic rolloff
## in front of that (tonemap_mode on the Environment resource is
## effectively a no-op for the reasons GL Compatibility's own startup
## warnings already state elsewhere in this codebase), so the overflow
## hard-clips to flat white instead of smoothly compressing. Lowering the
## light's own energy keeps typical real albedo x (ambient + diffuse) sums
## under 1.0 even for a naturally bright real texture, confirmed via a real
## before/after render of the same Dunhuang region -- real dune/terrain
## detail is now visible instead of a flat wash, and Jangan (a darker real
## palette that was never clipping) still looks correct at this energy too.
@onready var directional_light: DirectionalLight3D = $DirectionalLight3D
@onready var zone_label: Label = $UI/Control/ZoneLabel
@onready var character_label: Label = $UI/Control/CharacterLabel
@onready var ui_control: Control = $UI/Control
@onready var hide_ui_button: Button = $UI/HideUIButton
@onready var action_tabs: TabContainer = $UI/Control/ActionTabs
@onready var zone_input: LineEdit = $UI/Control/ZoneInput
@onready var chat_log: RichTextLabel = $UI/Control/ChatPanel/ChatLog
@onready var chat_input: LineEdit = $UI/Control/ChatPanel/ChatInputRow/ChatInput
@onready var send_button: Button = $UI/Control/ChatPanel/ChatInputRow/SendButton

## Action-tab panels, ported from the 2D World.gd HUD (see docs/PROGRESS.md)
## -- this scene is becoming the one real client, so its UI needs to cover
## everything the 2D view used to.
@onready var monster_list: ItemList = $UI/Control/ActionTabs/Monsters/MonsterList
@onready var monster_refresh_button: Button = $UI/Control/ActionTabs/Monsters/MonsterButtonRow/RefreshButton
@onready var attack_button: Button = $UI/Control/ActionTabs/Monsters/MonsterButtonRow/AttackButton
@onready var monster_status_label: Label = $UI/Control/ActionTabs/Monsters/MonsterStatusLabel

@onready var inventory_list: ItemList = $UI/Control/ActionTabs/Inventory/InventoryList
@onready var inventory_refresh_button: Button = $UI/Control/ActionTabs/Inventory/InventoryButtonRow/RefreshButton
@onready var equip_weapon_button: Button = $UI/Control/ActionTabs/Inventory/InventoryButtonRow/EquipWeaponButton
@onready var equip_armor_slot_option: OptionButton = $UI/Control/ActionTabs/Inventory/InventoryButtonRow/EquipArmorSlotOption
@onready var equip_armor_button: Button = $UI/Control/ActionTabs/Inventory/InventoryButtonRow/EquipArmorButton
@onready var inventory_status_label: Label = $UI/Control/ActionTabs/Inventory/InventoryStatusLabel

@onready var equipment_list: ItemList = $UI/Control/ActionTabs/Equipment/EquipmentList
@onready var equipment_refresh_button: Button = $UI/Control/ActionTabs/Equipment/EquipmentButtonRow/RefreshButton
@onready var unequip_weapon_button: Button = $UI/Control/ActionTabs/Equipment/EquipmentButtonRow/UnequipWeaponButton
@onready var unequip_armor_slot_option: OptionButton = $UI/Control/ActionTabs/Equipment/EquipmentButtonRow/UnequipArmorSlotOption
@onready var unequip_armor_button: Button = $UI/Control/ActionTabs/Equipment/EquipmentButtonRow/UnequipArmorButton
@onready var equipment_status_label: Label = $UI/Control/ActionTabs/Equipment/EquipmentStatusLabel

## Real, decompiler-confirmed armor slot names (see
## docs/protocol/EQUIP_SLOTS.md), shown in that same real order in both
## armor-slot pickers.
const ARMOR_SLOT_LABELS := {
	EquipmentNet.SLOT_HELM: "Helm",
	EquipmentNet.SLOT_MAIL: "Mail",
	EquipmentNet.SLOT_SHOULDER_GUARD: "Shoulder Guard",
	EquipmentNet.SLOT_GAUNTLET: "Gauntlet",
	EquipmentNet.SLOT_PANTS: "Pants",
	EquipmentNet.SLOT_BOOTS: "Boots",
}

@onready var quest_list: ItemList = $UI/Control/ActionTabs/Quests/QuestList
@onready var quest_refresh_button: Button = $UI/Control/ActionTabs/Quests/QuestButtonRow/RefreshButton
@onready var quest_accept_button: Button = $UI/Control/ActionTabs/Quests/QuestButtonRow/AcceptButton
@onready var quest_status_label: Label = $UI/Control/ActionTabs/Quests/QuestStatusLabel

@onready var skill_list: ItemList = $UI/Control/ActionTabs/Skills/SkillList
@onready var skill_refresh_button: Button = $UI/Control/ActionTabs/Skills/SkillButtonRow/SkillRefreshButton
@onready var skill_learn_button: Button = $UI/Control/ActionTabs/Skills/SkillButtonRow/SkillLearnButton
@onready var skill_use_button: Button = $UI/Control/ActionTabs/Skills/SkillButtonRow/SkillUseButton
@onready var skill_status_label: Label = $UI/Control/ActionTabs/Skills/SkillStatusLabel

@onready var shop_list: ItemList = $UI/Control/ActionTabs/Shop/ShopList
@onready var shop_refresh_button: Button = $UI/Control/ActionTabs/Shop/ShopButtonRow/RefreshButton
@onready var shop_buy_button: Button = $UI/Control/ActionTabs/Shop/ShopButtonRow/BuyButton
@onready var shop_status_label: Label = $UI/Control/ActionTabs/Shop/ShopStatusLabel

@onready var party_list: ItemList = $UI/Control/ActionTabs/Party/PartyList
@onready var party_create_button: Button = $UI/Control/ActionTabs/Party/PartyButtonRow/CreateButton
@onready var party_leave_button: Button = $UI/Control/ActionTabs/Party/PartyButtonRow/LeaveButton
@onready var party_join_id_input: LineEdit = $UI/Control/ActionTabs/Party/PartyJoinRow/JoinIdInput
@onready var party_join_button: Button = $UI/Control/ActionTabs/Party/PartyJoinRow/JoinButton
@onready var party_status_label: Label = $UI/Control/ActionTabs/Party/PartyStatusLabel

@onready var guild_list: ItemList = $UI/Control/ActionTabs/Guild/GuildList
@onready var guild_name_input: LineEdit = $UI/Control/ActionTabs/Guild/GuildCreateRow/GuildNameInput
@onready var guild_create_button: Button = $UI/Control/ActionTabs/Guild/GuildCreateRow/CreateButton
@onready var guild_join_id_input: LineEdit = $UI/Control/ActionTabs/Guild/GuildJoinRow/JoinIdInput
@onready var guild_join_button: Button = $UI/Control/ActionTabs/Guild/GuildJoinRow/JoinButton
@onready var guild_leave_button: Button = $UI/Control/ActionTabs/Guild/GuildJoinRow/LeaveButton
@onready var guild_status_label: Label = $UI/Control/ActionTabs/Guild/GuildStatusLabel

@onready var duel_target_input: LineEdit = $UI/Control/ActionTabs/Duel/ChallengeRow/TargetInput
@onready var duel_challenge_button: Button = $UI/Control/ActionTabs/Duel/ChallengeRow/ChallengeButton
@onready var duel_invite_label: Label = $UI/Control/ActionTabs/Duel/InviteRow/InviteLabel
@onready var duel_accept_button: Button = $UI/Control/ActionTabs/Duel/InviteRow/AcceptButton
@onready var duel_decline_button: Button = $UI/Control/ActionTabs/Duel/InviteRow/DeclineButton
@onready var duel_attack_button: Button = $UI/Control/ActionTabs/Duel/AttackButton
@onready var duel_status_label: Label = $UI/Control/ActionTabs/Duel/DuelStatusLabel

@onready var trade_target_input: LineEdit = $UI/Control/ActionTabs/Trade/RequestRow/TargetInput
@onready var trade_request_button: Button = $UI/Control/ActionTabs/Trade/RequestRow/RequestButton
@onready var trade_invite_label: Label = $UI/Control/ActionTabs/Trade/InviteRow/InviteLabel
@onready var trade_accept_button: Button = $UI/Control/ActionTabs/Trade/InviteRow/AcceptButton
@onready var trade_decline_button: Button = $UI/Control/ActionTabs/Trade/InviteRow/DeclineButton
@onready var trade_gold_input: LineEdit = $UI/Control/ActionTabs/Trade/OfferRow/GoldInput
@onready var trade_item_slot_input: LineEdit = $UI/Control/ActionTabs/Trade/OfferRow/ItemSlotInput
@onready var trade_quantity_input: LineEdit = $UI/Control/ActionTabs/Trade/OfferRow/QuantityInput
@onready var trade_set_offer_button: Button = $UI/Control/ActionTabs/Trade/OfferRow/SetOfferButton
@onready var trade_their_offer_label: Label = $UI/Control/ActionTabs/Trade/TheirOfferLabel
@onready var trade_confirm_button: Button = $UI/Control/ActionTabs/Trade/TradeButtonRow/ConfirmButton
@onready var trade_cancel_button: Button = $UI/Control/ActionTabs/Trade/TradeButtonRow/CancelButton
@onready var trade_status_label: Label = $UI/Control/ActionTabs/Trade/TradeStatusLabel

@onready var friend_list: ItemList = $UI/Control/ActionTabs/Friends/FriendList
@onready var friend_remove_button: Button = $UI/Control/ActionTabs/Friends/RemoveButton
@onready var friend_pending_list: ItemList = $UI/Control/ActionTabs/Friends/PendingList
@onready var friend_accept_button: Button = $UI/Control/ActionTabs/Friends/PendingButtonRow/AcceptButton
@onready var friend_decline_button: Button = $UI/Control/ActionTabs/Friends/PendingButtonRow/DeclineButton
@onready var friend_target_input: LineEdit = $UI/Control/ActionTabs/Friends/RequestRow/TargetInput
@onready var friend_request_button: Button = $UI/Control/ActionTabs/Friends/RequestRow/RequestButton
@onready var friend_refresh_button: Button = $UI/Control/ActionTabs/Friends/RefreshButton
@onready var friend_status_label: Label = $UI/Control/ActionTabs/Friends/FriendStatusLabel

# Parallel to monster_list/inventory_list's items -- ItemList doesn't carry
# structured data per row on its own, so track what each row actually is.
var _monsters: Array[CombatNet.MonsterSnapshot] = []
var _inventory_slots: Array[InventoryNet.Slot] = []
var _quests: Array[QuestNet.Entry] = []
var _skills: Array[SkillNet.SkillSnapshot] = []
var _shop_entries: Array[ShopNet.CatalogEntry] = []

# Name of whoever last challenged/requested-trade-with us, so Accept/
# Decline know who to respond to (the server needs it explicitly).
var _pending_duel_challenger := ""
var _pending_trade_requester := ""

var _friends: Array[FriendNet.FriendEntry] = []
var _pending_friend_requests: Array[FriendNet.PendingRequest] = []

# equipment_result fires for OpEquipmentList *and* equip/unequip acks (see
# NetClient.equipment_result's doc comment: a successful equip/unequip ack
# just has an empty items array, same shape as "nothing equipped"). Track
# whether we're expecting an ack so an empty response isn't misread as
# "you have nothing equipped" right after a successful equip.
var _awaiting_equip_ack := false

var _other_bodies := {} # character_id -> Node3D
## Real fix (2026-08-26, see docs/WORLD_ISSUES.md): a real playtest reported
## other players' movement stuttering at ~5-10fps. Root-caused, not guessed
## -- _on_entity_moved used to snap _other_bodies' position directly to
## each real position update the instant it arrived, and those updates
## only ever arrive as often as the sender's own MIN_SEND_INTERVAL allows
## (10/sec) -- a visible position jump every ~100ms, not smooth motion.
## This dict holds each real entity's latest known target position;
## _physics_process below smoothly interpolates each body toward its own
## target every frame instead of teleporting to it, so motion reads as
## continuous regardless of how often real updates actually arrive.
var _other_body_targets := {} # character_id -> Vector3
## character_id -> {skeleton, gender, group, moving}: what another player's
## body is playing, so its gait can follow its movement.
var _other_gaits := {}
## character_id -> {slot: item id}, as last reported: what the debug panel
## lists for another player.
var _other_equipped := {}
## How far a body may still be from its target before it counts as moving:
## a tenth of the body's height (REAL_CHARACTER_NATIVE_HEIGHT), so the tail
## of the interpolation reads as standing.
const OTHER_GAIT_THRESHOLD := 1.4
var _monster_bodies := {} # monster_id -> Node3D
var _monster_snapshots := {} # monster_id -> CombatNet.MonsterSnapshot, as last listed
var _last_sent_pos := Vector3.ZERO
var _time_since_send := 0.0

var _player_skeleton: Skeleton3D
var _player_gender := DEFAULT_GENDER
var _player_anim_time := 0.0
## A one-shot the player's body is in the middle of -- a hit reaction --
## and when it started; the tick plays it instead of stand or run until it
## has run its frames.
var _player_one_shot: BanReader.ParsedAnimation = null
var _player_one_shot_start := 0.0
var _player_one_shot_until := 0.0
## The monster the last attack was sent at, so its swing and the player's
## reaction to it can be played when the result comes back.
var _last_attack_target := -1
## Underbar quickslot index -> {"id": skill id, "code": Basic_Code} for skills
## the player has put on the hotbar from the skill window. Activating a slot
## casts its skill.
var _quickslot_skills: Dictionary = {}
## The Basic_Code of a skill the player just cast (""=none), consumed by the next
## attack result so that skill's own hit effect plays on the target (a plain
## attack does not). Set on cast, cleared when the blow lands.
var _pending_skill_hit_code := ""
## The animation-clock time of the player's last combat action (attack or cast).
## While within COMBAT_STANCE_SECONDS of it, a standing player holds the battle
## stance (STAND_BATTLE) instead of the town idle -- the real fighters carry a
## STAND_BATTLE clip (sword falls back to the body's chinaman_standbattle.ban).
var _last_combat_time := -1000.0
## How long the battle stance is held after the last combat action, in seconds.
## DISCLOSED own-design: the retail client's real revert timeout was never found
## (round 132) and combat state is server-driven, so this is a labeled stand-in,
## not a recovered value.
const COMBAT_STANCE_SECONDS := 5.0
## skilleffect.txt parsed once: Basic_Code (upper) -> hit `.efp` path. Lazy.
var _skill_hit_efp: Dictionary = {}
var _skill_hit_efp_loaded := false
## Which of the four plain attacks plays next. The four animation *types*
## are real -- the `.bsr` groups list them as types 2, 5, 16, 17
## (`sword_base_01` to `_04`, or the bare-handed straight-left,
## straight-right, hook-left, hook-right). **The order they cycle in is this
## project's own sequencing of those real types, not confirmed real client
## behaviour** -- it just plays each in turn so repeated attacks vary. If the
## real combo order is ever recovered from the client, correct it here (see
## docs/GROUNDING_AUDIT.md).
const ATTACK_SEQUENCE := [
	BsrReader.AnimationEntry.TYPE_ATTACK, BsrReader.AnimationEntry.TYPE_ATTACK_2, 16, 17]
var _attack_step := 0

var _real_skeleton: Skeleton3D
var _real_skeleton_track: BanReader.Bone
var _real_skeleton_anim: BanReader.ParsedAnimation
var _real_skeleton_time := 0.0

## Per gender: the body's `.bsr` path, its animation groups (from the
## `.bsr` itself -- see BsrReader.AnimationEntry) and a cache of the
## animations parsed so far, keyed by path -- read once by
## _load_character_assets(). A gender with no entry here means its body
## row was not found (or SRREVAMP_PK2_PATH isn't set at all) -- callers
## fall back to DEFAULT_GENDER, and to the placeholder capsule if even that
## didn't load.
var _character_assets: Dictionary = {}
## Data.pk2, held open for dressing: every character and every item on one
## is assembled out of it. All three archives are opened once and reused --
## re-opening a 2GB pk2 per region (as the open helpers used to) cost ~1s each
## and was ~25s of the ~65s world load / the region-crossing freeze.
var _data_pk2: Pk2Reader
var _map_pk2: Pk2Reader
## The player's own Particles.pk2 -- the level-up burst's real meshes and
## textures live here. Opened lazily the first time a level-up plays.
var _particles_pk2: Pk2Reader
## item id -> the `.bsr` it is worn as, from the player's own item table.
var _item_models: Dictionary = {}
## item id -> its TypeID4, for the weapons: which animation group a held
## weapon selects.
var _item_kinds: Dictionary = {}
## The animation group the player's held weapon selects, "default" when the
## hands are empty or the weapon's kind is not mapped.
var _player_weapon_group := "default"
## slot -> item id as last fetched from the server, for the debug panel:
## _real_player_equipped_items() is a coroutine that asks the server, and
## a panel refreshing twice a second must not.
var _player_equipped_last: Dictionary = {}

var _media_pk2: Pk2Reader
var _ui_text_table: UiTextTable
var _ui_builder: UiBuilder
var _hud_minimap: HudMinimap
var _hud_worldmap: HudWorldmap
var _hud_underbar: HudUnderbar
var _hud_player_info: HudPlayerInfo
## Vitals from the last EnterWorldResult. Kept because AttackResult reports
## only the player's current HP, not their maximum.
##
## Seeded from NetClient's own cached result rather than left at zero until
## the signal fires again. Entering the world happens in character select,
## before this scene exists, so the signal has already been and gone by the
## time the HUD subscribes -- which left the health bar blank on every real
## login, and on every QA run that signs in before building the world.
var _last_enter_world_hp := 0
var _last_enter_world_max_hp := 0

func _seed_vitals_from_last_enter_world() -> void:
	var entered = NetClient.last_enter_world_result
	if entered != null and entered.ok and entered.max_hp > 0:
		_last_enter_world_hp = entered.hp
		_last_enter_world_max_hp = entered.max_hp
var _hud_panels: HudPanels
var _hud_chat: HudChat

## Where the chat window sits relative to the bottom-left corner. The
## registry gives its size (399x398) and its corner; clearing the underbar
## is this project's own choice, as the underbar's own vertical anchor is.
const CHAT_MARGIN_X := 8.0
const CHAT_MARGIN_Y := 6.0

func _ready() -> void:
	# A QA run boots this scene directly, so there is no Login or character
	# select behind it. With SRREVAMP_QA_SERVER set, sign in first -- that
	# is what makes a render show real equipment, real vitals and the
	# server's own monsters rather than a client talking to nothing.
	if OS.get_environment("SRREVAMP_QA_SERVER") != "":
		await QaSignIn.run(get_tree())

	character_label.text = "Character: %s" % NetClient.current_character_name

	var _t_assets := Time.get_ticks_msec()
	_load_character_assets()
	print("World3D: character/item/NPC tables loaded in %d ms" % (Time.get_ticks_msec() - _t_assets))

	var result := NetClient.last_enter_world_result
	if result != null and result.ok:
		zone_label.text = "Zone: %s" % result.zone
		player.position = Vector3(result.x, result.y, result.z)
		_last_sent_pos = player.position
		for other in result.others:
			_spawn_or_update_other(other.character_id, other.char_name, Vector3(other.x, other.y, other.z), other.equipped, other.gender)

	NetClient.entity_entered.connect(_on_entity_entered)
	NetClient.entity_moved.connect(_on_entity_moved)
	NetClient.entity_left.connect(_on_entity_left)
	NetClient.change_zone_result.connect(_on_change_zone_result)
	NetClient.chat_message.connect(_on_chat_message)
	NetClient.chat_whisper_message.connect(_on_chat_whisper_message)
	NetClient.disconnected.connect(_on_disconnected)
	send_button.pressed.connect(_on_send_pressed)
	chat_input.text_submitted.connect(func(_text: String): _on_send_pressed())
	hide_ui_button.pressed.connect(_toggle_ui_visibility)

	NetClient.monster_list_result.connect(_on_monster_list_result)
	NetClient.attack_result.connect(_on_attack_result)
	NetClient.monster_damaged.connect(_on_monster_damaged)
	NetClient.monster_died.connect(_on_monster_died)
	NetClient.level_up.connect(_on_level_up)
	NetClient.loot_dropped.connect(_on_loot_dropped)
	NetClient.inventory_list_result.connect(_on_inventory_list_result)
	NetClient.equipment_result.connect(_on_equipment_result)
	NetClient.quest_list_result.connect(_on_quest_list_result)
	NetClient.quest_accept_result.connect(_on_quest_accept_result)
	NetClient.quest_completed.connect(_on_quest_completed)
	NetClient.skill_list_result.connect(_on_skill_list_result)
	NetClient.learn_skill_result.connect(_on_learn_skill_result)
	NetClient.shop_list_result.connect(_on_shop_list_result)
	NetClient.shop_buy_result.connect(_on_shop_buy_result)

	NetClient.party_create_result.connect(_on_party_result)
	NetClient.party_join_result.connect(_on_party_result)
	NetClient.party_leave_result.connect(_on_party_leave_result)
	NetClient.party_member_joined.connect(_on_party_member_joined)
	NetClient.party_member_left.connect(_on_party_member_left)
	NetClient.party_info_result.connect(_on_party_result)

	NetClient.guild_create_result.connect(_on_guild_result)
	NetClient.guild_join_result.connect(_on_guild_result)
	NetClient.guild_leave_result.connect(_on_guild_leave_result)
	NetClient.guild_info_result.connect(_on_guild_result)

	NetClient.duel_challenge_result.connect(_on_duel_challenge_result)
	NetClient.duel_invite.connect(_on_duel_invite)
	NetClient.duel_respond_result.connect(_on_duel_respond_result)
	NetClient.duel_started.connect(_on_duel_started)
	NetClient.duel_declined.connect(_on_duel_declined)
	NetClient.duel_attack_result.connect(_on_duel_attack_result)
	NetClient.duel_opponent_damaged.connect(_on_duel_opponent_damaged)
	NetClient.duel_ended.connect(_on_duel_ended)

	NetClient.trade_request_result.connect(_on_trade_request_result)
	NetClient.trade_invite.connect(_on_trade_invite)
	NetClient.trade_respond_result.connect(_on_trade_respond_result)
	NetClient.trade_started.connect(_on_trade_started)
	NetClient.trade_declined.connect(_on_trade_declined)
	NetClient.trade_offer_result.connect(_on_trade_offer_result)
	NetClient.trade_offer_updated.connect(_on_trade_offer_updated)
	NetClient.trade_confirm_result.connect(_on_trade_confirm_result)
	NetClient.trade_completed.connect(_on_trade_completed)
	NetClient.trade_cancelled.connect(_on_trade_cancelled)

	NetClient.friend_request_result.connect(_on_friend_request_result)
	NetClient.friend_request_received.connect(_on_friend_request_received)
	NetClient.friend_accept_result.connect(_on_friend_accept_result)
	NetClient.friend_accepted.connect(_on_friend_accepted)
	NetClient.friend_decline_result.connect(_on_friend_decline_result)
	NetClient.friend_list_result.connect(_on_friend_list_result)
	NetClient.friend_remove_result.connect(_on_friend_remove_result)
	NetClient.friend_pending_list_result.connect(_on_friend_pending_list_result)

	monster_refresh_button.pressed.connect(func(): NetClient.list_monsters())
	attack_button.pressed.connect(_on_attack_pressed)
	inventory_refresh_button.pressed.connect(func(): NetClient.list_inventory(NetClient.current_character_name))
	for slot in EquipmentNet.ARMOR_SLOTS:
		equip_armor_slot_option.add_item(ARMOR_SLOT_LABELS[slot], slot)
		unequip_armor_slot_option.add_item(ARMOR_SLOT_LABELS[slot], slot)

	equip_weapon_button.pressed.connect(func(): _on_equip_pressed(EquipmentNet.SLOT_WEAPON))
	equip_armor_button.pressed.connect(func(): _on_equip_pressed(equip_armor_slot_option.get_selected_id()))
	equipment_refresh_button.pressed.connect(func(): NetClient.list_equipment(NetClient.current_character_name))
	unequip_weapon_button.pressed.connect(func(): _on_unequip_pressed(EquipmentNet.SLOT_WEAPON))
	unequip_armor_button.pressed.connect(func(): _on_unequip_pressed(unequip_armor_slot_option.get_selected_id()))
	quest_refresh_button.pressed.connect(func(): NetClient.list_quests(NetClient.current_character_name))
	quest_accept_button.pressed.connect(_on_quest_accept_pressed)
	skill_refresh_button.pressed.connect(func(): NetClient.list_skills(NetClient.current_character_name))
	skill_learn_button.pressed.connect(_on_skill_learn_pressed)
	skill_use_button.pressed.connect(_on_skill_use_pressed)
	shop_refresh_button.pressed.connect(func(): NetClient.list_shop())
	shop_buy_button.pressed.connect(_on_shop_buy_pressed)

	party_create_button.pressed.connect(func(): NetClient.create_party(NetClient.current_character_name))
	party_leave_button.pressed.connect(func(): NetClient.leave_party(NetClient.current_character_name))
	party_join_button.pressed.connect(_on_party_join_pressed)

	guild_create_button.pressed.connect(_on_guild_create_pressed)
	guild_join_button.pressed.connect(_on_guild_join_pressed)
	guild_leave_button.pressed.connect(func(): NetClient.leave_guild(NetClient.current_character_name))

	duel_challenge_button.pressed.connect(_on_duel_challenge_pressed)
	duel_accept_button.pressed.connect(func(): _on_duel_respond_pressed(true))
	duel_decline_button.pressed.connect(func(): _on_duel_respond_pressed(false))
	duel_attack_button.pressed.connect(func(): NetClient.duel_attack(NetClient.current_character_name))

	trade_request_button.pressed.connect(_on_trade_request_pressed)
	trade_accept_button.pressed.connect(func(): _on_trade_respond_pressed(true))
	trade_decline_button.pressed.connect(func(): _on_trade_respond_pressed(false))
	trade_set_offer_button.pressed.connect(_on_trade_set_offer_pressed)
	trade_confirm_button.pressed.connect(func(): NetClient.trade_confirm(NetClient.current_character_name))
	trade_cancel_button.pressed.connect(func(): NetClient.trade_cancel(NetClient.current_character_name))

	friend_request_button.pressed.connect(_on_friend_request_pressed)
	friend_accept_button.pressed.connect(_on_friend_accept_pressed)
	friend_decline_button.pressed.connect(_on_friend_decline_pressed)
	friend_remove_button.pressed.connect(_on_friend_remove_pressed)
	friend_refresh_button.pressed.connect(_refresh_friends)

	# Guarded, unlike 2D World.gd's equivalent block: this scene doubles as a
	# standalone dev/asset-preview tool loaded with no live server connection
	# (see _real_player_equipped_items' doc comment) -- these would just
	# spam "_send called while not connected" errors otherwise.
	if NetClient.is_connected_to_server():
		NetClient.list_monsters()
		NetClient.list_inventory(NetClient.current_character_name)
		NetClient.list_equipment(NetClient.current_character_name)
		NetClient.list_quests(NetClient.current_character_name)
		NetClient.list_skills(NetClient.current_character_name)
		NetClient.list_shop()
		NetClient.party_info(NetClient.current_character_name)
		NetClient.guild_info(NetClient.current_character_name)
		_refresh_friends()

	_try_load_real_scenery()
	_try_load_real_decoration_skeleton()
	_try_apply_real_player_character()
	_try_add_real_sky()
	_apply_camera_far_plane()
	var _t_region := Time.get_ticks_msec()
	_load_initial_region_neighborhood()
	_try_initialize_pk2_ui()
	await _drain_initial_load(_t_region)

## Initializes authentic Silkroad UI components (minimap, underbar) from Media.pk2 if available.
func _try_initialize_pk2_ui() -> void:
	_media_pk2 = _open_media_pk2_if_set()
	if _media_pk2 == null:
		print("World3D: Media.pk2 not found (path='%s') -- authentic UI skipped" % Pk2Config.media_path())
		return

	# Load UI localization strings from Media.pk2
	var text_entry := ObjectLoader.find_file(_media_pk2, "server_dep\\silkroad\\textdata\\textuisystem.txt")
	if text_entry != null:
		var text_bytes := _media_pk2.read_file(text_entry)
		_ui_text_table = UiTextTable.parse(text_bytes)

	_ui_builder = UiBuilder.new(_media_pk2, _ui_text_table)

	# Setup authentic Minimap
	_hud_minimap = HudMinimap.new(_ui_builder, _media_pk2, _ui_text_table)
	_hud_minimap.name = "HudMinimap"
	ui_control.add_child(_hud_minimap)
	_hud_minimap.anchors_preset = Control.PRESET_TOP_RIGHT
	_hud_minimap.anchor_left = 1.0
	_hud_minimap.anchor_right = 1.0
	_hud_minimap.anchor_top = 0.0
	_hud_minimap.anchor_bottom = 0.0
	_hud_minimap.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_hud_minimap.grow_vertical = Control.GROW_DIRECTION_END
	_hud_minimap.offset_left = -150.0
	_hud_minimap.offset_right = -14.0
	_hud_minimap.offset_top = 10.0
	_hud_minimap.offset_bottom = 185.0
	_hud_minimap.setup()

	# The world map, opened from the minimap's own map button. It is built
	# once and kept hidden: the frame and the map table are read at build
	# time, the 363 tiles only as they come into view.
	_hud_worldmap = HudWorldmap.new(_ui_builder)
	_hud_worldmap.name = "HudWorldmap"
	ui_control.add_child(_hud_worldmap)
	if _hud_worldmap.build_worldmap():
		_hud_worldmap.centre()
		_hud_worldmap.hide()
		_hud_minimap.world_map_requested.connect(_hud_worldmap.toggle)
	else:
		# No registry entry or no map table -- this archive cannot show one.
		_hud_worldmap.queue_free()
		_hud_worldmap = null

	# Setup authentic Underbar (bottom bar)
	_hud_underbar = HudUnderbar.new(_ui_builder, _media_pk2, _ui_text_table)
	_hud_underbar.name = "HudUnderbar"
	ui_control.add_child(_hud_underbar)
	# 800x52, centred horizontally and sitting on the bottom edge. The size
	# is the bar body's authored rect (GDR_UNDERBAR in ginterface.txt), and
	# the artwork is exactly that size, so it must not be stretched.
	# Horizontal centring is authored too: the registry places the bar at
	# x=112 in the client's 1024-wide default layout, and (1024-800)/2 is
	# 112 exactly.
	#
	# The vertical anchor is a choice, not a recovered fact. The registry's
	# y=684 would leave a 32px gap under the bar at 768 tall, but the same
	# file places GDR_CHAT_BOARD's bottom at 944, past the bottom of a
	# 768-tall screen -- so those defaults are not all screen-relative and
	# can't be read as anchoring rules. Flush to the bottom is what the game
	# looks like.
	_hud_underbar.anchor_left = 0.5
	_hud_underbar.anchor_right = 0.5
	_hud_underbar.anchor_top = 1.0
	_hud_underbar.anchor_bottom = 1.0
	_hud_underbar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_hud_underbar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_hud_underbar.offset_left = -HudUnderbar.BODY_WIDTH / 2.0
	_hud_underbar.offset_right = HudUnderbar.BODY_WIDTH / 2.0
	_hud_underbar.offset_top = -float(HudUnderbar.BODY_HEIGHT)
	_hud_underbar.offset_bottom = 0.0
	_hud_underbar.setup()
	_hud_underbar.quickslot_activated.connect(_on_quickslot_activated)

	# The always-on block at the top left: portrait, name, level, HP and MP.
	# Its own registry entry places it at 4,7 in the client's default
	# layout, which is a plain top-left inset and translates directly.
	_hud_player_info = HudPlayerInfo.new(_ui_builder)
	_hud_player_info.name = "HudPlayerInfo"
	ui_control.add_child(_hud_player_info)
	_hud_player_info.position = Vector2(4, 7)
	_hud_player_info.setup()
	_hud_player_info.set_character(NetClient.current_character_name, 1)

	# Real vitals. The server reports them twice: once on entering the world
	# (EnterWorldResult carries HP and MaxHP) and again on every attack
	# (AttackResult's player_hp), so the bar is right on login and stays
	# right through combat.
	_seed_vitals_from_last_enter_world()
	if _last_enter_world_max_hp > 0:
		_hud_player_info.set_hp(_last_enter_world_hp, _last_enter_world_max_hp)
	NetClient.enter_world_result.connect(func(result) -> void:
		if result != null and result.ok and result.max_hp > 0:
			_last_enter_world_hp = result.hp
			_last_enter_world_max_hp = result.max_hp
			if _hud_player_info != null:
				_hud_player_info.set_hp(result.hp, result.max_hp)
			if _hud_panels != null:
				_hud_panels.set_character_vitals(result.hp, result.max_hp, 1))
	NetClient.attack_result.connect(func(result) -> void:
		if result != null and _last_enter_world_max_hp > 0:
			if _hud_player_info != null:
				_hud_player_info.set_hp(result.player_hp, _last_enter_world_max_hp)
			if _hud_panels != null:
				_hud_panels.set_character_vitals(result.player_hp, _last_enter_world_max_hp, 1))
	# MP has no server side at all yet -- nothing tracks or reports it -- so
	# the bar is drawn full and carries no readout. See set_mp_unknown.
	_hud_player_info.set_mp_unknown()

	# Every floating game window, created on demand.
	_hud_panels = HudPanels.new(_ui_builder)
	_hud_panels.name = "HudPanels"
	ui_control.add_child(_hud_panels)
	_hud_panels.connect_net()
	# The Escape / System menu (see HudPanels): its Option button opens the
	# settings panel (the same F3 debug panel that carries the working UI
	# scale, chat font, name range and camera view), Restart returns to the
	# login screen, Exit quits, and Help prints where to look.
	_hud_panels.system_option_requested.connect(func():
		_hud_panels.close("system")
		if _debug_panel != null:
			_debug_panel.visible = true)
	_hud_panels.system_restart_requested.connect(func():
		NetClient.disconnect_from_server()
		get_tree().change_scene_to_file("res://scenes/Login.tscn"))
	_hud_panels.system_exit_requested.connect(func(): get_tree().quit())
	_hud_panels.system_help_requested.connect(func():
		_log_system("Controls: click to move, right-drag or left-drag to orbit, mouse wheel to zoom. F1 dev tools, F3 debug panel, I inventory, K skill, M map. Type /unstuck if you get wedged in geometry."))
	_hud_panels.skill_assign_requested.connect(_on_skill_assign_requested)
	_hud_panels.npc_service_selected.connect(_on_npc_service_selected)

	# The chat window, bottom-left where its registry entry puts it. This
	# retires the developer chat box: the authored window is the same two
	# jobs -- a scrollback and an input line -- in the client's own art.
	_hud_chat = HudChat.new(_ui_builder)
	_hud_chat.name = "HudChat"
	ui_control.add_child(_hud_chat)
	_hud_chat.setup()
	# Anchored to the bottom-left corner with explicit offsets, the same way
	# the underbar is: setting `position` on an anchored Control places it
	# relative to the *parent's* top-left, not the anchor, which put the
	# whole window 456 pixels above the top of the screen.
	_hud_chat.anchor_left = 0.0
	_hud_chat.anchor_right = 0.0
	_hud_chat.anchor_top = 1.0
	_hud_chat.anchor_bottom = 1.0
	_hud_chat.grow_horizontal = Control.GROW_DIRECTION_END
	_hud_chat.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_hud_chat.offset_left = CHAT_MARGIN_X
	_hud_chat.offset_right = CHAT_MARGIN_X + _hud_chat.size.x
	# Clear of the underbar, which is flush to the bottom edge.
	_hud_chat.offset_bottom = -float(HudUnderbar.BODY_HEIGHT) - CHAT_MARGIN_Y
	_hud_chat.offset_top = _hud_chat.offset_bottom - _hud_chat.size.y
	_hud_chat.message_submitted.connect(_on_chat_submitted)
	# The panels are built after the vitals arrive, so they are seeded from
	# the same cached result rather than waiting for a signal that already
	# fired.
	if _last_enter_world_max_hp > 0:
		_hud_panels.set_character_vitals(_last_enter_world_hp, _last_enter_world_max_hp, 1)
	_hud_underbar.menu_action.connect(_on_underbar_menu_action)

	# The authentic HUD replaces the developer UI it would otherwise draw
	# on top of: the ten-tab panel is the same systems these windows now
	# show, and the corner labels duplicate the minimap's own readout. The
	# chat box and zone box stay -- chat has no authored window built yet,
	# and the zone box is still the only way to travel. See docs/UI_TODO.md.
	_hide_debug_ui_replaced_by_hud()

	print("World3D: authentic Silkroad UI initialized from Media.pk2 (minimap, underbar, player info, %d panels)" % HudPanels.PANELS.size())

## Routes the underbar's buttons to the panels. "menu" opens the popup list
## above the bar, where the reference puts it.
func _on_underbar_menu_action(action_name: String) -> void:
	if _hud_panels == null:
		return
	if action_name == "menu":
		_hud_panels.show_menu(_hud_underbar.global_position + Vector2(_hud_underbar.size.x * 0.86, 0.0))
		return
	if action_name == "option":
		return
	_hud_panels.toggle(action_name)

## Hides the parts of the developer UI the authentic HUD now covers.
## Hidden rather than deleted: the scene still owns those nodes and
## World3D's own handlers still reference them, so removing them is a
## separate change (docs/TODO.md item 5).
func _hide_debug_ui_replaced_by_hud() -> void:
	# ZoneLabel goes too: the minimap now shows the zone name and the
	# client's own X/Y readout, which is what that label was standing in
	# for, and it was drawing straight across the player block.
	# ChatPanel goes now that the authored chat window is built: it was the
	# last of the developer HUD that overlapped the real one, sitting across
	# the bottom-left corner where ifchatviewer's own window belongs.
	for path in ["ActionTabs", "CharacterLabel", "HelpLabel", "ZoneLabel", "ChatPanel"]:
		var node := ui_control.get_node_or_null(path)
		if node is CanvasItem:
			(node as CanvasItem).visible = false

	# The rest of the developer chrome is *hidden*, not retired: the zone
	# box is still the only way to travel and Log Out is still the only way
	# out. They sat over the player block and across the bottom-right corner
	# in every screenshot of this game, which is not what it should look
	# like when someone plays it.
	_set_dev_ui_visible(false)
	_log_system("Developer tools (zone travel, log out): F1")

	# The debug panel, and the three things a player asked to be able to
	# change from a couch: name range, UI scale (applied at boot) and chat
	# font, all remembered by ClientSettings.
	_debug_panel = DebugPanel.new(self)
	$UI.add_child(_debug_panel)
	_log_system("Debug panel (build, position, entities, loading, performance): F3")
	_log_system("Stuck in a wall or building? Type /unstuck to return to the zone entry.")
	_build_target_window()
	set_name_plate_range(ClientSettings.name_plate_range(NAME_PLATE_RANGE))
	var chat_font_size := ClientSettings.chat_font_size()
	if chat_font_size > 0:
		chat_log.add_theme_font_size_override("normal_font_size", chat_font_size)

	# The camera arm leaves the player's body for a pivot of its own (see
	# CAMERA_VIEW_FREE): the arm keeps its local offset and angles, the
	# pivot takes the body's position each physics tick.
	_camera_pivot = Node3D.new()
	_camera_pivot.name = "CameraPivot"
	add_child(_camera_pivot)
	_camera_pivot.global_position = player.global_position
	camera_arm.reparent(_camera_pivot, false)
	set_camera_view(ClientSettings.camera_view())

## Pushes the camera's far clipping plane out far enough to actually see
## the real terrain this scene streams in.
##
## **Added 2026-09-02** (see docs/WORLD_ISSUES.md's fifty-sixth round). The
## Camera3D never set `far`, so it used Godot's default of **4000** -- but
## the real streamed region grid is `(2 * REGION_LOAD_RADIUS + 1)` regions
## across, i.e. 9600 real units wide, reaching about 5400 units to a corner
## from the player at its centre. Real terrain past 4000 units was therefore
## clipped away with sky showing through it. Confirmed by measurement rather
## than inference: a real downward-raycast profile finds real terrain out to
## z=+3200 and the void beyond z=+4000, i.e. real ground genuinely exists
## well past where the default far plane was cutting it off.
##
## Derived from the same real constants that decide how much world is
## loaded, so it stays correct if the streaming radius or region size ever
## change, with margin to also clear the real sky dome (which sits
## SKY_DOME_HEIGHT_ABOVE_PLAYER up with SKY_DOME_RADIUS reach).
func _apply_camera_far_plane() -> void:
	camera_3d.far = REGION_SPAN * (_region_load_radius() + 1) * 2.0

## Loads real static scenery through the exact same pk2 -> BsrReader ->
## ObjectLoader pipeline client/tools/render_asset.gd verifies standalone,
## live in this scene -- if SRREVAMP_PK2_PATH and SRREVAMP_BSR_PATH are
## both set. Skips gracefully (a printed hint, not an error) otherwise,
## since this project ships with no game data.
func _try_load_real_scenery() -> void:
	var pk2_path := Pk2Config.data_path()
	var bsr_path := OS.get_environment("SRREVAMP_BSR_PATH")
	if pk2_path == "" or bsr_path == "":
		print("World3D: Data.pk2/SRREVAMP_BSR_PATH not set -- no real scenery loaded")
		return

	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("World3D: could not open pk2 archive at ", pk2_path)
		return

	var obj := ObjectLoader.load_object(archive, bsr_path)
	if obj == null:
		printerr("World3D: could not load ", bsr_path, " from ", pk2_path)
		return

	# +Z is behind the third-person camera (it sits at a +Z/+Y offset from
	# the player looking back toward -Z) -- place scenery on the -Z side
	# so it's actually in view near spawn.
	obj.position = Vector3(4, 0, -4)
	add_child(obj)
	print("World3D: loaded real scenery %s from %s" % [bsr_path, pk2_path])

## Loads a real .bsk skeleton + .ban animation through Skeleton3DBuilder
## (see client/tools/render_skeleton3d_animated.gd for the standalone
## verification of this same pipeline), live in this scene as an animated
## decoration (not the player's own body -- see _try_load_real_player_character())
## -- if SRREVAMP_BSK_PATH and SRREVAMP_BAN_PATH are both set. Each accepts
## either a loose file path or a path inside SRREVAMP_PK2_PATH (see
## AssetSource). Skips gracefully otherwise.
func _try_load_real_decoration_skeleton() -> void:
	var bsk_path := OS.get_environment("SRREVAMP_BSK_PATH")
	var ban_path := OS.get_environment("SRREVAMP_BAN_PATH")
	if bsk_path == "" or ban_path == "":
		print("World3D: SRREVAMP_BSK_PATH/SRREVAMP_BAN_PATH not set -- no real decoration skeleton loaded")
		return

	var archive := _open_pk2_if_set()
	var bsk_bytes := AssetSource.read_bytes(bsk_path, archive)
	var ban_bytes := AssetSource.read_bytes(ban_path, archive)
	if bsk_bytes.is_empty() or ban_bytes.is_empty():
		printerr("World3D: could not find .bsk/.ban at ", bsk_path, " / ", ban_path)
		return

	var skel := BskReader.parse(bsk_bytes)
	var anim := BanReader.parse(ban_bytes)
	if skel == null or anim == null or anim.bones.is_empty():
		printerr("World3D: could not parse .bsk/.ban at ", bsk_path, " / ", ban_path)
		return

	_real_skeleton = Skeleton3DBuilder.build_skeleton3d(skel)
	_real_skeleton_track = anim.bones[0]
	_real_skeleton_anim = anim
	_real_skeleton.position = Vector3(-6, 0, -6)
	# Real .bsk bind-pose data uses a much larger native scale than this
	# scene's ~2-unit-tall player capsule (position values in the hundreds
	# -- see docs/protocol/BSK_FORMAT.md) -- scale down so the whole
	# creature is visible near the player instead of dwarfing the scene.
	_real_skeleton.scale = Vector3.ONE * 0.02
	add_child(_real_skeleton)
	# A bare Skeleton3D has no visual representation of its own -- see
	# Skeleton3DBuilder.build_debug_visualization()'s doc comment.
	Skeleton3DBuilder.build_debug_visualization(_real_skeleton)
	print("World3D: loaded real skeleton %s + animation %s (%d bones, %d keyframes on track %s)" % [
		bsk_path, ban_path, skel.bones.size(), _real_skeleton_track.keyframes.size(), _real_skeleton_track.bone_name])

## Opens the real Data.pk2 -- SRREVAMP_PK2_PATH if set, else a real
## "pk2/Data.pk2" next to the running executable (see Pk2Config) -- or
## returns null if neither resolves or the open fails. Used so AssetSource
## can fall back to an in-archive path for any of the loose-file-shaped
## environment variables.
func _open_pk2_if_set() -> Pk2Reader:
	if _data_pk2 != null:
		return _data_pk2
	var pk2_path := Pk2Config.data_path()
	if pk2_path == "":
		return null
	_data_pk2 = Pk2Reader.open(pk2_path)
	return _data_pk2

var _tile_index_cache: TileIndexReader.Table

## The real terrain lighting terms from environment.ifo, remembered when a
## region's environment is applied so the terrain mesh can bake them in.
var _env_light_diffuse := Color.WHITE
var _env_terrain_ambient := Color.BLACK
var _env_light_ready := false

## The real per-tile ShadowMap from the region's own `.t`, stashed by
## _load_real_terrain_lightmap for the mesh builder.
var _last_terrain_shadow_map := PackedByteArray()
var _tile_index_load_attempted := false

## Loads and caches the real tile2d.ifo table (see TILE_INDEX_PATH) from
## SRREVAMP_PK2_PATH's Data.pk2, for MapmTerrainBuilder's real per-vertex
## ground-tile-type coloring. Only ever parsed once per scene lifetime --
## every real region shares the same real table. Returns null (logged
## once) if SRREVAMP_PK2_PATH isn't set or the file can't be found/parsed;
## callers already treat a null table as "fall back to the generic hue
## sweep," so this isn't a hard failure.
## Real parsed region-zone table, loaded once per run (it covers the whole
## real world, not one region). Null means "already tried, nothing usable".
var _regioninfo_cache: RegioninfoReader.ParsedTable = null
var _regioninfo_load_attempted := false

func _load_regioninfo() -> RegioninfoReader.ParsedTable:
	if _regioninfo_load_attempted:
		return _regioninfo_cache
	_regioninfo_load_attempted = true

	var archive := _open_pk2_if_set()
	if archive == null:
		return null
	var bytes := AssetSource.read_bytes(REGIONINFO_PATH, archive)
	if bytes.is_empty():
		print("World3D: no real region-zone table at ", REGIONINFO_PATH, " -- the zone label keeps whatever it already had")
		return null
	_regioninfo_cache = RegioninfoReader.parse(bytes)
	if _regioninfo_cache == null:
		printerr("World3D: could not parse real region-zone table at ", REGIONINFO_PATH)
	else:
		print("World3D: loaded real region-zone table (%d real zones) from %s" % [_regioninfo_cache.zones.size(), REGIONINFO_PATH])
	return _regioninfo_cache

## Names the real zone a region belongs to, in the label that has read
## "Zone: -" for want of anything real to put there.
##
## Only ever *replaces* the label when the real table names the region
## unambiguously. A region two real zones split between them resolves to
## nothing (see RegioninfoReader.sole_zone_for -- which side of the split a
## point falls on can't be decided until `RECT`'s real coordinates are
## understood), and so does a region the table never mentions. In both
## cases whatever the label already said is left alone rather than
## overwritten with a guess.

## Appends the player's real region and region-local position to the zone
## label, so a screenshot from a playtest says exactly *where* it was taken.
##
## Added 2026-09-06 after a real playtest reported parts of the world being
## "not where they should be" -- a real, credible report that could not be
## acted on, because neither a screenshot nor a description pins down which
## real region and which part of it is being looked at. The region and local
## coordinates are directly checkable against that region's own real authored
## minimap art (`Media.pk2`'s `minimap\\<y>x<x>.ddj`), which is what makes a
## report like that actionable rather than anecdotal.
## The last real zone name resolved for the player's region, kept so the
## label's position part can be refreshed as they walk without re-resolving
## the zone every frame.
var _current_zone_name := "-"
var _zone_label_tick := 0

## Refreshes the position shown in the zone label as the player moves.
## Throttled: the text only has to be readable, not per-frame accurate.
func _refresh_zone_label_position() -> void:
	_zone_label_tick += 1
	if _zone_label_tick % 10 != 0:
		return
	if zone_label != null:
		zone_label.text = "Zone: %s%s" % [_current_zone_name, _zone_label_position_suffix()]

	if _hud_minimap != null and is_instance_valid(_hud_minimap):
		var pair := _nav_graph_for(player.global_position)
		if not pair.is_empty():
			var group: Node3D = pair[1]
			var local: Vector3 = group.to_local(player.global_position)
			var parts := String(group.name).replace("RealTerrain_", "").split("_")
			if parts.size() >= 2:
				var rx: int = parts[0].to_int()
				var ry: int = parts[1].to_int()
				_hud_minimap.update_player(rx, ry, local, player.rotation_degrees.y)
				_hud_minimap.set_area_name(_current_zone_name)
				if _hud_worldmap != null and is_instance_valid(_hud_worldmap):
					_hud_worldmap.update_player(rx, ry, local)

## Bone positions of the first few animated characters, so two calls can be
## differenced. Keyed by skeleton instance id.
var _qa_anim_sample: Dictionary = {}

func _qa_animation_report() -> void:
	print("QA ANIM %d animated character(s)" % _animated.size())
	var checked := 0
	for entry in _animated:
		var skeleton: Skeleton3D = entry[0]
		if not is_instance_valid(skeleton):
			continue
		var sum := Vector3.ZERO
		for i in range(skeleton.get_bone_count()):
			sum += skeleton.get_bone_global_pose(i).origin
		# The frame this character is posed at, reported alongside the
		# movement: a short loop sampled a whole number of cycles apart is
		# genuinely on the same frame, and "moved 0.000" then says the probe
		# aliased rather than that the animation is dead.
		var frames: int = entry[2]
		var phase: float = entry[3]
		var anim: BanReader.ParsedAnimation = entry[1]
		var frame_idx := anim.key_index_at(_idle_anim_time + phase, true)
		var key := skeleton.get_instance_id()
		var previous = _qa_anim_sample.get(key)
		if previous == null:
			print("   %-22s %2d bones, %2d frames, at frame %d -- first sample" % [
				skeleton.get_parent().name, skeleton.get_bone_count(), frames, frame_idx])
		else:
			var moved: float = (sum - (previous as Vector3)).length()
			print("   %-22s %2d bones, %2d frames, at frame %d -- bones moved %.3f" % [
				skeleton.get_parent().name, skeleton.get_bone_count(), frames, frame_idx, moved])
		_qa_anim_sample[key] = sum
		checked += 1
		if checked >= 5:
			break

## Reports, for every placed object near the player, how its rendered
## footprint compares with the walkable footprint in the navigation graph.
##
## The gap is what lets a player stand inside a structure: the graph only
## knows the walkable part, so where the solid mesh reaches further, the
## graph reports the terrain underneath and puts the player there. Jangan's
## gate is the case that prompted this.
func _qa_navgap_report() -> void:
	var pair := _nav_graph_for(player.global_position)
	if pair.is_empty():
		print("QA NAVGAP: off-region")
		return
	var graph: NavGraph = pair[0]
	var group: Node3D = pair[1]
	var here := group.to_local(player.global_position)

	# Rendered footprints, from the region's own object nodes.
	# Objects hang off a container under the terrain group, not off the
	# group itself -- the same two-level walk _qa_look_report does.
	var object_nodes: Array[Node] = []
	for container in group.get_children():
		for node in container.get_children():
			if node is Node3D and String(node.name).begins_with("Obj_"):
				object_nodes.append(node)

	var rendered := {}
	for child in object_nodes:
		var box := AABB()
		var seeded := false
		var stack: Array[Node] = [child]
		while not stack.is_empty():
			var cur: Node = stack.pop_back()
			if cur is MeshInstance3D and (cur as MeshInstance3D).mesh != null:
				var mi := cur as MeshInstance3D
				var world_box: AABB = mi.global_transform * mi.get_aabb()
				if seeded:
					box = box.merge(world_box)
				else:
					box = world_box
					seeded = true
			for c in cur.get_children():
				stack.append(c)
		if seeded:
			rendered[String(child.name)] = box

	# Two independent questions, asked separately, because tying them
	# together needs a name-to-index mapping that does not exist: the render
	# nodes are numbered by a running "how many loaded" counter over the
	# .o/.o2 placement files, while the graph keys objects by their index in
	# the .nvm's own object list. An earlier version of this report matched
	# them by the node name's trailing number and confidently reported "NO
	# walkable mesh" for an object that may well have one.
	#
	# So: what does the graph offer to stand on here, and what solid
	# geometry actually covers the spot.
	print("QA NAVGAP at local %d, %d" % [here.x, here.z])

	# heights_at is every surface the graph knows here: the terrain first,
	# then any object cell covering the point.
	var offered := graph.heights_at(here.x, here.z)
	print("   graph offers %d surface(s): %s" % [offered.size(), offered])
	print("   graph objects covering this point: %s" % [graph.objects_at(here.x, here.z)])

	var covering := 0
	for name in rendered:
		var box: AABB = rendered[name]
		var lo := group.to_local(box.position)
		var hi := group.to_local(box.end)
		var x0: float = minf(lo.x, hi.x)
		var x1: float = maxf(lo.x, hi.x)
		var z0: float = minf(lo.z, hi.z)
		var z1: float = maxf(lo.z, hi.z)
		if here.x < x0 or here.x > x1 or here.z < z0 or here.z > z1:
			continue
		covering += 1
		print("   solid %-34s y %.1f..%.1f" % [name, minf(lo.y, hi.y), maxf(lo.y, hi.y)])
	if covering == 0:
		print("   nothing solid covers this spot")

## Opens the named HUD panels and tiles them across the screen, so one
## render can show several at once. Reports what opened and what didn't --
## a panel whose authored layout is missing prints rather than failing.
func _qa_open_panels(spec: String) -> void:
	if _hud_panels == null:
		print("QA PANELS: no HUD (Media.pk2 not loaded)")
		return
	var placed := 0
	for raw in spec.split(","):
		var panel_id := raw.strip_edges()
		if panel_id == "":
			continue
		# The MENU popup is not a panel -- open it where the underbar would.
		if panel_id == "menu":
			var view2 := get_viewport().get_visible_rect().size
			_hud_panels.show_menu(Vector2(view2.x * 0.62, view2.y - 40.0))
			placed += 1
			continue
		var window := _hud_panels.open(panel_id)
		if window == null:
			print("QA PANELS: %s did not open" % panel_id)
			continue
		# A single panel centres for a clean shot, clear of the left-side chat
		# log; several tile across the top.
		if spec.split(",").size() == 1:
			window.centre()
		else:
			var view := get_viewport().get_visible_rect().size
			var column := placed % 3
			var row: int = placed / 3
			window.position = Vector2(
				20.0 + column * (view.x - 40.0) / 3.0,
				90.0 + row * 200.0)
		print("QA PANELS: %s opened %dx%d at %s" % [
			panel_id, int(window.size.x), int(window.size.y), window.position])
		placed += 1
	print("QA PANELS: %d of %d opened" % [placed, spec.split(",").size()])

func _zone_label_position_suffix() -> String:
	var pair := _nav_graph_for(player.global_position)
	if pair.is_empty():
		return " @ %d, %d, %d (no region)" % [
			player.global_position.x, player.global_position.y, player.global_position.z]
	var group: Node3D = pair[1]
	var local := group.to_local(player.global_position)
	var suffix := String(group.name).replace("RealTerrain_", "")
	return " [%s] local %d, %d, %d" % [suffix, local.x, local.y, local.z]

func _update_zone_label_for_region(region_x: int, region_y: int) -> void:
	var table := _load_regioninfo()
	if table == null:
		return
	var zone_name := RegioninfoNames.display_for_region(table, region_x, region_y)
	if zone_name == "":
		return
	_current_zone_name = zone_name
	zone_label.text = "Zone: %s%s" % [zone_name, _zone_label_position_suffix()]

func _load_tile_index() -> TileIndexReader.Table:
	if _tile_index_load_attempted:
		return _tile_index_cache
	_tile_index_load_attempted = true

	var archive := _open_pk2_if_set()
	if archive == null:
		return null
	var bytes := AssetSource.read_bytes(TILE_INDEX_PATH, archive)
	if bytes.is_empty():
		print("World3D: could not find real tile index at ", TILE_INDEX_PATH, " -- terrain color falls back to a generic hue sweep")
		return null
	_tile_index_cache = TileIndexReader.parse(bytes)
	if _tile_index_cache == null:
		printerr("World3D: could not parse real tile index at ", TILE_INDEX_PATH)
	else:
		print("World3D: loaded real tile index (%d real tile types) from %s" % [_tile_index_cache.entries.size(), TILE_INDEX_PATH])
	return _tile_index_cache

## Real per-.ddj-filename texture cache, shared across every region loaded
## this run -- most real tile2d.ifo IDs a region uses (grass/dirt/stone,
## etc) repeat across many regions, so this avoids re-reading and
## re-decoding the same real Tile2D\*.ddj file over and over. A null entry
## means "already tried, no real file/decode" -- also cached, so a
## consistently-missing ID doesn't retry every region load.
static var _ground_texture_cache: Dictionary = {}

## Loads every real per-vertex ground texture `region` actually
## references, keyed by the real TextureInfo.ID MapmTerrainBuilder's
## _vertex_color already decodes -- see docs/protocol/DDJ_FORMAT.md and
## TILE2D_FORMAT.md's 2026-08-23 correction. Resolves each real ID through
## tile_table to a real tile2d.ifo filename, then loads that file from
## SRREVAMP_MAP_PK2_PATH's real `Tile2D\` folder (confirmed 2026-08-23 to
## be where these actually live -- see server/cmd/pk2list's real listing
## against a real Map.pk2). Returns {} (not an error) if tile_table is
## null or SRREVAMP_MAP_PK2_PATH isn't set -- callers already treat an
## empty lookup as "use the flat tile-type color instead."
func _load_real_ground_textures(region: MapmReader.ParsedRegion, tile_table: TileIndexReader.Table) -> Dictionary:
	var result := {}
	if tile_table == null:
		return result
	var archive := _open_map_pk2_if_set()
	if archive == null:
		return result

	var ids := {}
	for block in region.blocks:
		for vertex in block.vertices:
			if vertex.extra.size() < 2:
				continue
			ids[vertex.extra.decode_u16(0) & 0x3ff] = true

	for id in ids.keys():
		var entry := tile_table.lookup(id)
		if entry == null or entry.filename == "":
			continue
		var tex := _load_ground_texture_file(entry.filename, archive)
		if tex != null:
			result[id] = tex
	return result

## Loads and caches one real Tile2D\<filename>.ddj -- see
## _load_real_ground_textures's doc comment for the cache's purpose.
func _load_ground_texture_file(filename: String, archive: Pk2Reader) -> Texture2D:
	if _ground_texture_cache.has(filename):
		return _ground_texture_cache[filename]
	var bytes := AssetSource.read_bytes("Tile2D\\%s" % filename, archive)
	var tex: Texture2D = null
	if not bytes.is_empty():
		var parsed := DdjReader.parse(bytes)
		if parsed != null:
			tex = DdjReader.to_texture(parsed)
	_ground_texture_cache[filename] = tex
	return tex

## Real, per-run cache of the 30-frame real water animation loaded from
## Map.pk2's own real `Water\` folder (see docs/WORLD_ISSUES.md's
## 2026-08-26 asset-taxonomy entry) -- every region shares the same real
## water animation, so this is only ever built once regardless of how many
## real regions with real water tiles get loaded.
static var _water_frames_cache: Array = []
static var _water_frames_load_attempted := false

## Loads the real 30-frame water flip-book animation
## (Water\water101.ddj..water130.ddj -- a real numbered-frame sequence, not
## a shader effect) into an AnimatedTexture, or null if none of the 30 real
## frames were found (e.g. SRREVAMP_MAP_PK2_PATH unset, or a real archive
## that doesn't ship this folder). Frame duration is an honest guess (not
## reverse-engineered from any real client timing data) picked to read as
## a gentle, plausible water ripple rather than a claim about the real
## client's own exact animation speed.
const WATER_FRAME_COUNT := 30
const WATER_FRAME_FPS := 8.0

func _load_real_water_animation(archive: Pk2Reader) -> AnimatedTexture:
	if not _water_frames_load_attempted:
		_water_frames_load_attempted = true
		for i in range(WATER_FRAME_COUNT):
			var filename := "water1%02d.ddj" % (i + 1)
			var bytes := AssetSource.read_bytes("Water\\%s" % filename, archive)
			if bytes.is_empty():
				continue
			var parsed := DdjReader.parse(bytes)
			if parsed == null:
				continue
			var tex := DdjReader.to_texture(parsed)
			if tex != null:
				_water_frames_cache.append(tex)
		if _water_frames_cache.is_empty():
			print("World3D: no real water frames found under Water\\ -- water tiles render as plain ground")

	if _water_frames_cache.is_empty():
		return null

	var anim := AnimatedTexture.new()
	anim.frames = _water_frames_cache.size()
	for i in range(_water_frames_cache.size()):
		anim.set_frame_texture(i, _water_frames_cache[i])
		anim.set_frame_duration(i, 1.0 / WATER_FRAME_FPS)
	return anim

## Builds and attaches a real animated water surface (see
## MapmTerrainBuilder.build_full_region_water_mesh) to terrain_group, if
## this region has any real WATER/DEEP_WATER tiles at all -- a no-op
## (nothing added) otherwise, or if SRREVAMP_MAP_PK2_PATH isn't set / the
## real water frames can't be found, so a region with no real water (most
## of them) or a caller with no archive access isn't penalized.
## Adds this region's real navmesh walls: every real blocking edge in its
## `.nvm` cell/edge graph, extruded into a vertical quad by NvmCollision.
##
## This is real *walkability*, which the terrain mesh's own geometric
## collision does not reproduce -- it is the boundary the real game
## actually enforces, and it exists in places no geometry does.
##
## Parented to terrain_group rather than positioned itself, so it inherits
## that node's own rotation and vertical anchoring exactly. The wall
## triangles are built in the same region-local space the terrain mesh uses
## (MapmTerrainBuilder's col -> X, row -> Z): the two formats share a
## byte-identical heightmap, and the local-axis correspondence is measured
## rather than assumed -- see docs/protocol/NVM_FORMAT.md's "Real
## local-axis orientation" section.
##
## Does nothing (and says so) when Data.pk2 isn't set or the region has no
## real navmesh file -- the same honest "nothing to load" behavior as the
## rest of this scene, never a guess.
## Real per-region parsed navmesh, loaded once and shared by everything
## that needs it -- real walkability walls and real water surfaces both come
## out of the same real file, so it is not worth reading twice. A null entry
## means "already tried, nothing usable", and is cached too.
var _navmesh_cache: Dictionary = {}

func _load_region_navmesh(mapm_path: String) -> NvmReader.ParsedRegion:
	var coords := _parse_region_coords(mapm_path)
	if coords.is_empty():
		return null
	var key: int = (int(coords["x"]) << 8) | int(coords["y"])
	if _navmesh_cache.has(key):
		return _navmesh_cache[key]
	_navmesh_cache[key] = null

	var archive := _open_pk2_if_set()
	if archive == null:
		return null
	var nvm_path: String = NAVMESH_PATH_FORMAT % key
	var bytes := AssetSource.read_bytes(nvm_path, archive)
	if bytes.is_empty():
		print("World3D: no real navmesh at %s -- this region gets no real walkability or water" % nvm_path)
		return null
	var parsed := NvmReader.parse(bytes)
	if parsed == null:
		printerr("World3D: could not parse real navmesh at ", nvm_path)
		return null
	_navmesh_cache[key] = parsed
	return parsed

## Real walkable graphs, one per loaded region, keyed by the region's own
## terrain group. Each entry is [NavGraph, Node3D] -- the graph plus the node
## whose own local space *is* that region's real coordinate space, so
## converting between the two is done with the node's real transform rather
## than by re-deriving the region placement (and its mirror) by hand.
var _region_nav_graphs: Array = []

## Builds the real walkable graph for a region: its terrain `.nvm` plus every
## real object that `.nvm` lists, each resolved to its own real navigation
## mesh. See NavGraph for how objects attach to a region and why this is data
## rather than collision shapes.
func _build_region_nav_graph(terrain_group: Node3D, mapm_path: String) -> void:
	var region := _load_region_navmesh(mapm_path)
	if region == null:
		return
	var archive := _open_pk2_if_set()
	var placed: Array[NavGraph.PlacedObject] = []
	var missing := 0
	var missing_names := {}
	if archive != null and not region.objects.is_empty():
		var table := _load_object_index()
		if table != null:
			for oi in range(region.objects.size()):
				var obj: NvmReader.MapObject = region.objects[oi]
				var collision := _load_object_collision(archive, table, obj.resource_id)
				if collision == null:
					missing += 1
					# Naming them matters: an object with no navigation mesh
					# is one the player can stand *inside*, and "8 objects
					# unresolved" gives no way to tell whether those eight
					# are decorative shrubs or the plaza the town square is
					# built on.
					var missing_entry := table.lookup(obj.resource_id)
					if missing_entry != null and missing_entry.path != "":
						missing_names[missing_entry.path.get_file().get_basename()] = true
					continue
				var placed_object := NavGraph.place(collision, oi, obj.local_position, obj.yaw)
				# Tagged with the real model it came from purely so that a
				# report of what the player is standing on can name it --
				# see _qa_step's position line.
				var entry := table.lookup(obj.resource_id)
				if entry != null and entry.path != "":
					placed_object.set_meta("model", entry.path.get_file().get_basename())
				placed.append(placed_object)
	var graph := NavGraph.build(region, placed)
	_region_nav_graphs.append([graph, terrain_group])
	print("World3D: real walkable graph for %s -- %d/%d real objects placed, %d real terrain blocking edges" % [
		mapm_path, placed.size(), region.objects.size(), graph.terrain_blocking.size() / 2])
	if missing > 0:
		print("World3D:   (%d real objects in that region could not be resolved to a navigation mesh: %s)" % [
			missing, ", ".join(PackedStringArray(missing_names.keys()))])

## Cache of real object navigation meshes by real resource ID, since a region
## repeats the same handful of real object types across many placements.
var _object_collision_cache := {}

func _load_object_collision(
	archive: Pk2Reader, table: ObjidxReader.Table, resource_id: int
) -> BmsReader.CollisionMesh:
	if _object_collision_cache.has(resource_id):
		return _object_collision_cache[resource_id]
	_object_collision_cache[resource_id] = null
	var entry = table.lookup(resource_id)
	if entry == null:
		return null
	var bsr_entry := ObjectLoader.find_file(archive, entry.path)
	if bsr_entry == null:
		return null
	var bsr := BsrReader.parse(archive.read_file(bsr_entry))
	if bsr == null or bsr.mesh_path == "":
		return null

	# **Every mesh, not just the first.** An object's walkable surface is
	# one piece among many and the pieces are in alphabetical order, so
	# whether reading `mesh_path` alone found it was chance: of the 2,043
	# objects in the index that carry navigation data anywhere, **232 do not
	# carry it in their first mesh** and were reported as having none --
	# Jangan's six shops, its city wall, the palace door,
	# `cj_ferry_buil.bsr` with nineteen pieces. A player walks inside every
	# one of those. And 117 objects carry it in more than one mesh (every
	# tree does), so taking the first piece that has any would still lose
	# half of those.
	var meshes: Array[String] = [bsr.mesh_path]
	for path in bsr.sub_mesh_paths:
		meshes.append(path)
	var parts: Array = []
	for path in meshes:
		if path == "":
			continue
		var mesh_entry := ObjectLoader.find_file(archive, path)
		if mesh_entry == null:
			continue
		var part := BmsReader.parse_collision(archive.read_file(mesh_entry))
		if part != null and not part.cells.is_empty():
			parts.append(part)
	if parts.is_empty():
		return null
	var collision: BmsReader.CollisionMesh = parts[0] if parts.size() == 1 else BmsCollision.merge(parts)
	_object_collision_cache[resource_id] = collision
	return collision

## The real walkable graph covering the player, as [NavGraph, Node3D], or an
## empty Array when the player is not over any region that has one.
## The real object index that resolves a placement's type ID to its real
## .bsr path, preferring Map.pk2's own table over Data.pk2's -- see
## MAP_OBJECT_INDEX_PATH for why they differ and why the map's wins.
## Cached: every region load needs it, and it is a quarter-megabyte parse.
var _object_index_cache: ObjidxReader.Table = null
var _object_index_load_attempted := false

func _load_object_index() -> ObjidxReader.Table:
	if _object_index_load_attempted:
		return _object_index_cache
	_object_index_load_attempted = true

	var bytes := PackedByteArray()
	var source := MAP_OBJECT_INDEX_PATH
	var map_archive := _open_map_pk2_if_set()
	if map_archive != null:
		bytes = AssetSource.read_bytes(MAP_OBJECT_INDEX_PATH, map_archive)
	if bytes.is_empty():
		var data_archive := _open_pk2_if_set()
		if data_archive != null:
			bytes = AssetSource.read_bytes(OBJECT_INDEX_PATH, data_archive)
			source = OBJECT_INDEX_PATH
	if bytes.is_empty():
		printerr("World3D: could not find a real object index (tried Map.pk2's %s and Data.pk2's %s)" % [
			MAP_OBJECT_INDEX_PATH, OBJECT_INDEX_PATH])
		return null

	_object_index_cache = ObjidxReader.parse(bytes)
	if _object_index_cache == null:
		printerr("World3D: could not parse the real object index at ", source)
	else:
		print("World3D: loaded real object index (%d real entries) from %s" % [
			_object_index_cache.entries.size(), source])
	return _object_index_cache

func _nav_graph_for(world_position: Vector3) -> Array:
	for pair in _region_nav_graphs:
		var group: Node3D = pair[1]
		if group == null or not is_instance_valid(group):
			continue
		var local := group.to_local(world_position)
		if local.x < 0.0 or local.z < 0.0 or local.x > REGION_SPAN or local.z > REGION_SPAN:
			continue
		return pair
	return []

func _try_add_navmesh_walls(terrain_group: Node3D, mapm_path: String) -> void:
	var region := _load_region_navmesh(mapm_path)
	if region == null:
		return
	var faces := NvmCollision.build_wall_triangles(region, NAVMESH_WALL_HEIGHT)
	if faces.is_empty():
		return
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	var body := StaticBody3D.new()
	body.name = "NavmeshWalls"
	body.collision_layer = NAVMESH_WALL_COLLISION_LAYER
	var body_shape := CollisionShape3D.new()
	body_shape.shape = shape
	body.add_child(body_shape)
	terrain_group.add_child(body)
	if OS.get_environment("SRREVAMP_DEBUG_NAVMESH_WALLS") != "":
		_add_navmesh_wall_debug_mesh(terrain_group, faces)
	print("World3D: loaded real navmesh walls for %s (%d real blocking of %d internal + %d global edges)" % [
		mapm_path, NvmCollision.blocking_edges(region).size(), region.internal_edges.size(), region.global_edges.size()])

## Draws the walls _try_add_navmesh_walls just built, so they can actually
## be looked at. They are deliberately invisible in normal play -- they are
## walkability, not scenery -- which also means a misplaced one is
## impossible to see, and misplacement is exactly the failure this
## project's own headless checks have repeatedly missed. Gated behind
## SRREVAMP_DEBUG_NAVMESH_WALLS so it costs a normal run nothing.
func _add_navmesh_wall_debug_mesh(terrain_group: Node3D, faces: PackedVector3Array) -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = faces
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.1, 0.1, 1.0)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Walls are single-sided quads, so without this each one vanishes when
	# viewed from the far side -- which would read as a missing wall.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var debug_mesh := MeshInstance3D.new()
	debug_mesh.name = "NavmeshWallsDebug"
	debug_mesh.mesh = mesh
	debug_mesh.material_override = mat
	terrain_group.add_child(debug_mesh)
	var local_aabb := mesh.get_aabb()
	print("World3D: navmesh wall debug mesh local aabb %s .. %s, global origin %s" % [
		local_aabb.position, local_aabb.end, debug_mesh.to_global(local_aabb.position)])

## **Rebuilt 2026-09-05** (see docs/WORLD_ISSUES.md): real water used to be
## classified per *terrain tile* and each quad placed at that tile's own
## terrain height, because this project had no real reference height for a
## body of water. It therefore followed the ground instead of lying flat,
## and real ponds rendered as jagged tile-shaped sheets cutting through the
## terrain -- reported from a real playtest of the real Jangan temple
## garden.
##
## The real `.nvm`'s own 6x6 `PlaneTypeMap`/`PlaneHeightMap` is that missing
## reference: where the real plane type is water, the real plane height is
## that body of water's own flat surface level. See NvmWater, which measured
## the type across 264 real files rather than assuming it.
##
## No artificial vertical lift is applied any more either. The old one
## existed because water shared the ground's exact vertices; a real water
## plane sits at its own real level and is simply occluded by whatever
## terrain stands above it, which is what makes a real shoreline.
func _try_add_real_water(terrain_group: Node3D, mapm_path: String) -> void:
	var region := _load_region_navmesh(mapm_path)
	if region == null:
		return
	# The real per-tile water flags decide the water's shape and the real
	# plane map its level -- see NvmWater's own "Why both sources" comment.
	var tile_table := _load_tile_index()
	if tile_table == null:
		print("World3D: no real tile2d.ifo -- real water shape can't be resolved, skipping water")
		return
	var water_mesh := NvmWater.build_water_mesh(region, tile_table)
	if water_mesh == null:
		# Says so, because "this region has no water" and "this region's
		# water failed to build" look identical in a screenshot -- a real
		# playtest found a willow pond with a stone bridge over dry ground
		# and there was nothing in the log either way.
		print("World3D: %s -- no real water surface built (%d real water plane cell(s) in its navmesh)" % [
			mapm_path, NvmWater.water_plane_cell_count(region)])
		return
	print("World3D: %s -- built real water from %d real quad(s)" % [
		mapm_path, water_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() / 4])
	var archive := _open_map_pk2_if_set()
	if archive == null:
		return
	var anim := _load_real_water_animation(archive)
	if anim == null:
		return

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = anim
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1, 1, 1, 0.85)
	mat.uv1_scale = Vector3(4.0, 4.0, 1.0) # real per-quad UV already 0..1; repeats the real frame texture a few times per quad instead of stretching one tile over it, same rationale as the ground-texture uv1_scale nearby

	var water_instance := MeshInstance3D.new()
	water_instance.name = "Water"
	water_instance.mesh = water_mesh
	water_instance.material_override = mat
	terrain_group.add_child(water_instance)

## Real sky assets found under Map.pk2's own SkyBox\ folder (2026-08-28,
## see docs/WORLD_ISSUES.md and docs/NEXT_STEPS_RENDERING.md's "Terrain"
## section for the taxonomy-scan history): cloud1.ddj (512x512, DXT3, has a
## real alpha channel), cloud99.ddj (512x512, uncompressed), glow.ddj
## (128x128, uncompressed), shadowsphere.ddj (64x64, DXT3), and
## waterbump3.ddj (512x512, uncompressed) -- confirmed via a real dimension/
## format inspection on the RE box, not guessed. None of these are a single
## large panoramic/equirectangular image, so this is *not* a standard
## six-face or panorama skybox -- the real client evidently builds its sky
## from several small tileable/blended layers instead. No config file or
## mesh describing exactly how the real client combines them was found
## alongside these textures (checked -- no .ifo/.cfg/.bsr next to SkyBox\),
## and the currently-available decompiled binary is the server, not the
## client renderer, so the real exact blending algorithm isn't determinable
## from data alone without further client-side RE (a real, flagged gap, see
## docs/NEXT_STEPS_RENDERING.md).
##
## What's implemented here is therefore an honest engineering approximation
## using the *real* cloud/glow textures (not fabricated ones), not a claim
## about reproducing the original algorithm: a large inverted-hemisphere
## dome around the player textured with the real cloud1.ddj (its own real
## alpha channel gives real soft cloud edges), slowly drifting, plus a
## simple additive glow billboard aimed at the DirectionalLight's real
## direction as a stand-in sun. cloud99/shadowsphere/waterbump3 are left
## unused -- their real purpose within the sky system is still unconfirmed
## (shadowsphere's tiny 64x64 size in particular reads more like a
## soft ambient-shadow blob than a sky-color asset, but that's not
## confirmed either).
const SKY_DOME_RADIUS := 3000.0
## How far above the player the real cloud dome's centre is placed.
##
## **Added 2026-09-02** (see docs/WORLD_ISSUES.md's fifty-first round): the
## dome is a hemisphere, so centring it exactly on the player put its base
## plane at the player's own feet, where it sliced straight through real
## terrain. That intersection rendered as translucent shards fanning across
## the ground away from the player -- a real, confirmed artifact (disabling
## the sky removed it completely and left clean ground, while everything
## else was unchanged). Lifting the centre well above head height keeps the
## whole dome above real terrain, which is also where a real cloud layer
## belongs. Chosen relative to the dome's own radius rather than as a loose
## constant so the two stay in proportion if the radius is ever retuned.
const SKY_DOME_HEIGHT_ABOVE_PLAYER := SKY_DOME_RADIUS * 0.5
const CLOUD_DRIFT_UV_PER_SECOND := 0.008
const SUN_GLOW_DISTANCE := 2800.0
const SUN_GLOW_SIZE := 500.0

var _sky_dome: MeshInstance3D
var _sky_dome_material: ShaderMaterial
var _cloud_dome_shader: Shader = preload("res://scripts/assets/cloud_dome.gdshader")
var _cloud_uv_offset := Vector2.ZERO
var _sun_glow: Sprite3D
var _sun_glow_offset := Vector3.ZERO
var _sky_material: ProceduralSkyMaterial

## Real per-zone day/night lighting data (2026-08-31, see
## docs/protocol/ENVIRONMENT_FORMAT.md and docs/WORLD_ISSUES.md's
## twenty-ninth round): environment.ifo's real SkyTopColor/SkyBottomColor
## channels replace the flat-color-derived gradient _try_add_real_sky()
## builds as a fallback, once a real zone's terrain (and therefore its real
## per-block EnvironmentID) has loaded. Real per-zone checks (Jangan,
## Dunhuang) found every block in a zone shares the same EnvironmentID, so
## reading the first block's is representative, not a guess -- but that
## uniformity hasn't been checked for every zone, so a zone with mixed
## per-block IDs would still only get the first block's color (an honest
## simplification, not wrong for any zone checked so far).
##
## ENVIRONMENT_REFERENCE_TIME is a deliberate, flagged simplification: the
## real data is a full day/night color-keyframe cycle (see the format doc),
## but this project has no real day/night clock system (no confirmed real
## time-compression ratio, no server-side game-time signal) -- implementing
## one is real, separate future work. Sampling a fixed midday time gives a
## real, per-zone-accurate *snapshot* color instead of the old
## flat-color-derived guess, without pretending to reproduce the real
## dynamic cycle.
const ENVIRONMENT_REFERENCE_TIME := 0.5
static var _environment_table: EnvironmentReader.ParsedFile = null
static var _environment_load_attempted := false

func _try_add_real_sky() -> void:
	var archive := _open_map_pk2_if_set()
	if archive == null:
		print("World3D: SRREVAMP_MAP_PK2_PATH not set -- sky stays a flat placeholder color")
		return

	# Real gradient sky (Godot's own ProceduralSkyMaterial, not a real
	# extracted asset -- no real single sky-gradient image was found, see
	# this function's top comment) replacing the flat background_color the
	# scene shipped with, using that same real color as the horizon tone so
	# this doesn't introduce a new invented color, only extends it into a
	# gradient.
	var sky_material := ProceduralSkyMaterial.new()
	var flat_color: Color = world_environment.environment.background_color
	sky_material.sky_top_color = flat_color.lerp(Color(0.15, 0.25, 0.55), 0.35)
	sky_material.sky_horizon_color = flat_color
	sky_material.ground_bottom_color = flat_color.darkened(0.4)
	sky_material.ground_horizon_color = flat_color
	var sky := Sky.new()
	sky.sky_material = sky_material
	world_environment.environment.sky = sky
	world_environment.environment.background_mode = Environment.BG_SKY
	_sky_material = sky_material

	# **Re-enabled 2026-09-02** (see docs/WORLD_ISSUES.md's forty-second
	# round) -- was disabled 2026-09-01 after a real sunburst/fan artifact
	# was confirmed at the dome's pole (SphereMesh's polar UV projection
	# compresses a whole ring of the mesh to one point there). Rather than
	# fix the projection itself (no real per-pixel dome UV data to build a
	# better one from), cloud_dome.gdshader fades the real cloud texture's
	# alpha to zero before the singularity comes into view, so the
	# compressed pixels never render -- see that shader file's own comment.
	var cloud_bytes := AssetSource.read_bytes("SkyBox\\cloud1.ddj", archive)
	if not cloud_bytes.is_empty():
		var parsed := DdjReader.parse(cloud_bytes)
		if parsed != null:
			var cloud_tex := DdjReader.to_texture(parsed)
			if cloud_tex != null:
				_build_cloud_dome(cloud_tex)

	# The real character shadow: a real soft radial blob shipped as
	# SkyBox\shadowsphere.ddj. See _build_blob_shadow.
	var blob_bytes := AssetSource.read_bytes("SkyBox\\shadowsphere.ddj", archive)
	if not blob_bytes.is_empty():
		var blob_parsed := DdjReader.parse(blob_bytes)
		if blob_parsed != null:
			var blob_tex := DdjReader.to_texture(blob_parsed)
			if blob_tex != null:
				_build_blob_shadow(blob_tex)

	var glow_bytes := AssetSource.read_bytes("SkyBox\\glow.ddj", archive)
	if not glow_bytes.is_empty():
		var glow_parsed := DdjReader.parse(glow_bytes)
		if glow_parsed != null:
			var glow_tex := DdjReader.to_texture(glow_parsed)
			if glow_tex != null:
				_build_sun_glow(glow_tex)

func _build_cloud_dome(cloud_tex: Texture2D) -> void:
	var dome := SphereMesh.new()
	dome.radius = SKY_DOME_RADIUS
	dome.height = SKY_DOME_RADIUS
	dome.is_hemisphere = true
	dome.radial_segments = 32
	dome.rings = 16

	# ShaderMaterial, not StandardMaterial3D -- see cloud_dome.gdshader's own
	# comment for why a custom shader is needed (fading the real texture out
	# before the dome's real polar-UV singularity comes into view).
	_sky_dome_material = ShaderMaterial.new()
	_sky_dome_material.shader = _cloud_dome_shader
	_sky_dome_material.set_shader_parameter("cloud_tex", cloud_tex)
	_sky_dome_material.set_shader_parameter("uv_offset", Vector2.ZERO)

	_sky_dome = MeshInstance3D.new()
	_sky_dome.name = "CloudDome"
	_sky_dome.mesh = dome
	_sky_dome.material_override = _sky_dome_material
	add_child(_sky_dome)

func _build_sun_glow(glow_tex: Texture2D) -> void:
	# Real DirectionalLight3D direction (see World3D.tscn) -- the sun's
	# apparent position is the opposite of the direction the light travels.
	var light_travel_dir := -directional_light.global_transform.basis.z
	var sun_dir := -light_travel_dir

	_sun_glow = Sprite3D.new()
	_sun_glow.name = "SunGlow"
	_sun_glow.texture = glow_tex
	_sun_glow.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sun_glow.shaded = false
	_sun_glow.modulate = Color(1, 1, 0.9, 0.85)
	_sun_glow.pixel_size = SUN_GLOW_SIZE / glow_tex.get_width()
	_sun_glow_offset = sun_dir * SUN_GLOW_DISTANCE
	_sun_glow.position = _sun_glow_offset
	add_child(_sun_glow)

## Loads and caches the real environment.ifo (Map.pk2's root) once per run --
## every real zone shares the same table, only the looked-up Key differs.
func _load_environment_table(archive: Pk2Reader) -> EnvironmentReader.ParsedFile:
	if not _environment_load_attempted:
		_environment_load_attempted = true
		var bytes := AssetSource.read_bytes("environment.ifo", archive)
		if not bytes.is_empty():
			_environment_table = EnvironmentReader.parse(bytes)
		if _environment_table == null:
			print("World3D: no real environment.ifo found -- sky keeps its flat-color-derived gradient")
	return _environment_table

## Real per-zone sky color, from a real region's own EnvironmentID (see this
## file's _sky_material doc comment for the real-data justification and
## ENVIRONMENT_REFERENCE_TIME's honest scope). No-op if _sky_material was
## never built (e.g. no SRREVAMP_MAP_PK2_PATH) or no matching real record is
## found -- leaves the existing flat-color-derived gradient rather than
## guessing.
func _apply_real_environment_lighting(region: MapmReader.ParsedRegion, archive: Pk2Reader) -> void:
	if _sky_material == null or region.blocks.is_empty():
		return
	var table := _load_environment_table(archive)
	if table == null:
		return
	var env_id := region.blocks[0].environment_id
	var record: EnvironmentReader.Record = null
	for rec in table.records:
		if rec.key == env_id:
			record = rec
			break
	if record == null:
		print("World3D: region's EnvironmentID %d has no matching environment.ifo record" % env_id)
		return

	var top := EnvironmentReader.sample_color_channel(record, EnvironmentReader.CHANNEL_SKY_TOP_COLOR, ENVIRONMENT_REFERENCE_TIME)
	var bottom := EnvironmentReader.sample_color_channel(record, EnvironmentReader.CHANNEL_SKY_BOTTOM_COLOR, ENVIRONMENT_REFERENCE_TIME)
	_sky_material.sky_top_color = top
	_sky_material.sky_horizon_color = bottom
	_sky_material.ground_horizon_color = bottom
	_sky_material.ground_bottom_color = bottom.darkened(0.4)

	# Real per-zone SunColor/DiffuseColor (2026-09-02) -- same real
	# environment.ifo record the sky colors above already use, just two more
	# of its real channels that were decoded from day one but never wired to
	# anything (see docs/protocol/ENVIRONMENT_FORMAT.md). Sampled at the same
	# fixed ENVIRONMENT_REFERENCE_TIME as the sky, for the same honest reason
	# (no real day/night clock exists yet). Real sample data confirms these
	# genuinely differ per zone at midday -- Jangan's SunColor is ~white,
	# Dunhuang's DiffuseColor is a warm tan -- not a no-op recoloring.
	# DirectionalLight3D's real per-zone *angle* has no confirmed real source
	# (only color channels exist in this format) and stays a hand-set
	# constant, unchanged.
	var sun_color := EnvironmentReader.sample_color_channel(record, EnvironmentReader.CHANNEL_SUN_COLOR, ENVIRONMENT_REFERENCE_TIME)
	var diffuse_color := EnvironmentReader.sample_color_channel(record, EnvironmentReader.CHANNEL_DIFFUSE_COLOR, ENVIRONMENT_REFERENCE_TIME)
	var ambient_color := EnvironmentReader.sample_color_channel(record, EnvironmentReader.CHANNEL_OBJECT_AMBIENT_COLOR, ENVIRONMENT_REFERENCE_TIME)

	# **Channel roles corrected 2026-09-07 from the real client's own shader**
	# (see docs/RE_MAP_ENGINE.md). The real terrain vertex shader
	# (`Shader\vertexshader0splatting.c`) lights a vertex as
	#
	#     mad oD0, N.L, c[VSC_DLIGHT_DIFFUSE], c[VSC_DLIGHT_AMBIENT]
	#
	# so the real *diffuse* channel is the directional light's own colour --
	# the term multiplied by N.L -- and the real *ambient* channels are the
	# additive ambient term. This code had those two the other way round: it
	# put SunColor on the directional light and DiffuseColor into ambient.
	#
	# That mattered, and the real data shows why: real SunColor is (1,1,1) in
	# most real records -- it is the sun *disc's* own colour, which is why it
	# now tints the real sun glow sprite below instead -- while real
	# DiffuseColor carries the actual per-zone tint (a real warm
	# 0.70/0.60/0.50, a real cold 0.70/0.53/0.93). Driving the directional
	# light from SunColor therefore threw that per-zone character away and
	# lit every zone with plain white, while pushing the tint into ambient,
	# where it flattened shading instead of directing it.
	directional_light.light_color = diffuse_color
	world_environment.environment.ambient_light_color = ambient_color

	# Kept so the terrain mesh built moments later can bake the real client's
	# own per-vertex terrain lighting -- see MapmTerrainBuilder's
	# _lit_vertex_color. TerrainAmbientColor is a *separate* real channel from
	# the object ambient above, and genuinely differs (often (1,1,1) against
	# the object ambient's 0.58), which is exactly why baking terrain lighting
	# lets both be honoured where one global ambient cannot.
	_env_light_diffuse = diffuse_color
	_env_terrain_ambient = EnvironmentReader.sample_color_channel(record, EnvironmentReader.CHANNEL_TERRAIN_AMBIENT_COLOR, ENVIRONMENT_REFERENCE_TIME)
	_env_light_ready = true

	# Real per-zone aerial-perspective haze (2026-09-03). The real client's
	# own terrain shaders were found shipped as readable source inside
	# Data.pk2's `Shader\` folder (see docs/protocol/SHADER_FINDINGS.md), and
	# they show the real distance model is not a simple linear near/far fog at
	# all -- it's atmospheric scattering. `scattervsdetail10.vsh` computes a
	# per-channel extinction `E = exp(-(beta_1 + beta_2) * s)` over view-space
	# distance s, and `terrainps14.psh` combines it as
	# `final = surf_color * extinction + inscattering`.
	#
	# That is structurally the same operation as Godot's own exponential fog
	# (surface blended toward a fog color by `1 - exp(-density * depth)`), so
	# the model here is real and recovered, not invented -- and the *color* is
	# real per-zone data: environment.ifo's own FogColor channel, sampled at
	# the same fixed ENVIRONMENT_REFERENCE_TIME as the sky and sun above.
	#
	# The density is NOT real data and is not presented as such. The real
	# beta_1/beta_2 scattering coefficients are runtime shader constants the
	# client computes; environment.ifo's two real scalar fog channels
	# (CHANNEL_FOG_NEAR_PLANE/CHANNEL_FOG_FAR_PLANE) hold normalized values in
	# [-1, +1] in every real record checked -- not world distances -- so how
	# they map onto real scattering coefficients isn't recoverable from the
	# asset data alone. FOG_DENSITY is therefore a disclosed rendering choice,
	# the same way BOUNDARY_BLEND_ALPHA is.
	var fog_color := EnvironmentReader.sample_color_channel(record, EnvironmentReader.CHANNEL_FOG_COLOR, ENVIRONMENT_REFERENCE_TIME)
	var env := world_environment.environment
	env.fog_enabled = true
	env.fog_light_color = fog_color
	env.fog_density = FOG_DENSITY
	# The real model's inscattering is strongest looking toward the sun (the
	# Henyey-Greenstein phase term in the real vertex shader), which is exactly
	# what Godot's fog_sun_scatter approximates.
	env.fog_sun_scatter = FOG_SUN_SCATTER
	env.fog_aerial_perspective = FOG_AERIAL_PERSPECTIVE

	# The real sun-disc colour belongs on the real sun sprite. Its alpha stays
	# a disclosed rendering choice (see _build_sun_glow); only the real colour
	# is taken from real data.
	if _sun_glow != null:
		_sun_glow.modulate = Color(sun_color.r, sun_color.g, sun_color.b, _sun_glow.modulate.a)

	print("World3D: applied real environment.ifo lighting (%s, EnvironmentID=%d) -- sky_top=%s sky_bottom=%s sun_disc=%s light_diffuse=%s ambient=%s fog=%s" % [record.name1, env_id, top, bottom, sun_color, diffuse_color, ambient_color, fog_color])

## Opens the real Map.pk2 -- SRREVAMP_MAP_PK2_PATH if set, else a real
## "pk2/Map.pk2" next to the running executable (see Pk2Config) -- or
## returns null if neither resolves or the open fails. Map.pk2 is a separate
## archive from Data.pk2 in a real retail install (confirmed from the
## user's own real client file listing: Data.pk2, Media.pk2, Map.pk2,
## Particles.pk2 are all separate files) -- so terrain resolves its own real
## pk2 path rather than reusing Data.pk2's.
func _open_map_pk2_if_set() -> Pk2Reader:
	if _map_pk2 != null:
		return _map_pk2
	var map_pk2_path := Pk2Config.map_path()
	if map_pk2_path == "":
		return null
	_map_pk2 = Pk2Reader.open(map_pk2_path)
	return _map_pk2

## Opens the real Media.pk2 -- SRREVAMP_MEDIA_PK2_PATH if set, else a real
## "pk2/Media.pk2" next to the running executable (see Pk2Config) -- or
## returns null if neither resolves or the open fails. A real client's
## per-map-region minimap image (see SRREVAMP_MAPM_TEXTURE_PATH below) lives
## in Media.pk2, a third separate archive from both Data.pk2 and Map.pk2 in
## a real retail install.
func _open_media_pk2_if_set() -> Pk2Reader:
	if _media_pk2 != null:
		return _media_pk2
	var media_pk2_path := Pk2Config.media_path()
	if media_pk2_path == "":
		return null
	_media_pk2 = Pk2Reader.open(media_pk2_path)
	return _media_pk2

## The player's Particles.pk2, cached (same lazy-open pattern as the others).
## Returns null when no Particles.pk2 is configured -- the level-up effect
## then plays no visual rather than a fabricated one.
func _open_particles_pk2_if_set() -> Pk2Reader:
	if _particles_pk2 != null:
		return _particles_pk2
	var particles_pk2_path := Pk2Config.particles_path()
	if particles_pk2_path == "":
		return null
	_particles_pk2 = Pk2Reader.open(particles_pk2_path)
	return _particles_pk2

## Loads a real per-region minimap image (SRREVAMP_MAPM_TEXTURE_PATH, e.g.
## "minimap\100x100.ddj") as the terrain's real ground texture, if set.
## Accepts either a loose file path or a path inside SRREVAMP_MEDIA_PK2_PATH
## (see AssetSource) -- a real client's minimap images live in Media.pk2,
## confirmed via this project's own real-file search tooling
## (server/cmd/pk2list) against a real client install.
##
## This is an honest substitution, not a claim that this is the literal
## real-time 3D ground texture: no real-time multi-layer terrain-texture
## system (nor a lookup from a per-tile byte to a specific real texture
## file) has been found anywhere in this project's available real data --
## see docs/protocol/MAPM_FORMAT.md for that search. A region's own real
## minimap art is genuine, region-specific real game data (grass/dirt/rock
## color baked from that exact region), and looks far closer to the real
## game than the flat/procedural fallback color this function returns null
## for -- but it's a real top-down painted image, not sampled per-tile 3D
## terrain texture data.
## path_override lets a zone reload (see _reload_zone_assets) pass a
## specific real path instead of reading SRREVAMP_MAPM_TEXTURE_PATH -- empty
## string (the default) means "use the env var", same as every call site
## before zone reloading existed.
func _load_real_terrain_texture(path_override: String = "") -> Texture2D:
	var tex_path := path_override if path_override != "" else OS.get_environment("SRREVAMP_MAPM_TEXTURE_PATH")
	if tex_path == "":
		return null

	var archive := _open_media_pk2_if_set()
	var bytes := AssetSource.read_bytes(tex_path, archive)
	if bytes.is_empty():
		printerr("World3D: could not find terrain texture at ", tex_path)
		return null

	var parsed := DdjReader.parse(bytes)
	if parsed == null:
		printerr("World3D: could not parse terrain texture at ", tex_path)
		return null

	return DdjReader.to_texture(parsed)

## Loads a region's real .t file (the same base path as mapm_path, with
## its extension swapped) as a real ambient-occlusion-style lightmap --
## see docs/protocol/MAPT_FORMAT.md for the real structure and how this
## project confirmed it (public documentation, verified byte-for-byte
## against a real sample, cross-decoded two independent ways). The real
## embedded texture is a genuine grayscale shadow map (white = fully lit,
## gray = shadowed) -- a natural fit for Godot's built-in AO darkening,
## unlike an earlier same-day attempt to show a *different*, wrongly-
## decoded payload as literal detail-albedo color (reverted after live
## testing looked wrong -- see MAPT_FORMAT.md's own account). Not every
## region has a `.t` file (only newer-generation "Shape B" regions do --
## see MAPM_FORMAT.md's Shape A/B split), so a missing file here is the
## normal, expected case, not an error.
func _load_real_terrain_lightmap(mapm_path: String, archive: Pk2Reader) -> Texture2D:
	if mapm_path == "" or not mapm_path.ends_with(".m"):
		return null
	var mapt_path := mapm_path.substr(0, mapm_path.length() - 1) + "t"
	var bytes := AssetSource.read_bytes(mapt_path, archive)
	if bytes.is_empty():
		return null
	var region := MapTReader.parse(bytes)
	if region == null:
		return null
	# The same real `.t` also carries the real per-tile ShadowMap, which is the
	# self-shadow term of the real terrain equation. Kept here so the terrain
	# mesh built moments later can apply it without re-reading the file.
	_last_terrain_shadow_map = region.shadow_map
	return region.texture

## The real Jangan region. **Corrected again 2026-09-01** (see
## docs/WORLD_ISSUES.md's thirty-ninth round): "89/182" (found 2026-08-26 by
## raw keyword density alone -- 279 real "jangan"-named placements, the
## single densest region in all 4,050) turned out to be a real, confirmed
## *isolated* pocket -- a direct listing of the real Map.pk2 archive shows
## every region touching it in any direction is void (no `.m` file at all),
## with the nearest other real terrain 2+ REGION_SPAN away. Walking into
## that gap dropped the player through an unbounded void (see this file's
## WORLD_FLOOR_Y fix, same round). "98/168" -- the *original*
## 2026-08-24 discovery, set aside at the time for having "only" 32 matches
## against 89/182's 279 -- sits inside a real, single, fully contiguous
## landmass of 500+ populated regions (y=145-175 x=85-108 all real terrain,
## confirmed via the same archive listing) that already includes the
## already-verified real Dunhuang region ("98/157", 11 rows away, no gaps
## between them) plus real "greenfield" (open fields/lake gardens),
## "jangan04" (military camp), "jangan05" (temple), and "jangan02/03"
## (pub/market/palace-substructure) districts -- exactly the open,
## walkable, populated-but-not-just-palace world this project was missing.
## A fuller keyword rescan (2026-09-01, server/cmd's ad hoc topregions_scratch,
## deleted after use) found 98/168 actually has 277 real "jangan" matches
## (almost tied with 89/182's 279) and *more* real palace-lion-statue
## matches (`cj3`, 50 vs 47) -- the original 32-match figure undercounted it,
## most likely from scanning too small a subset of the real archive at the
## time. Real-rendered and verified (779/779 real map objects resolved,
## real stone walls/willow trees/festival banners, no load errors).
## **Corrected 2026-09-07**, in a real playtest. 98/168 is real Jangan
## architecture, but it is specifically the *palace*: every building placed
## in it is a `cj_pal_*` model from `Res\Bldg\China\Jangan03\` -- the big
## door, the main and guard buildings, the lion statues, the stairs -- and
## it contains no shop at all. Spawning there meant a player walked around
## a walled palace compound looking for the town they remembered.
##
## The town is one region west, 97/168: scanning every real region's
## placements for the town's own shop and gate models (server/cmd's
## findregionassets) puts `cj_acce.bsr` (accessory shop) and
## `cj_jang_gate_dragon.bsr` in exactly one region, and that region is
## 97/168. Its centre is the real town square with the dragon statue, at
## local (1002, 917) -- see ZONE_SPAWN_LOCAL.
const JANGAN_ZONE_REGION := "97/168"

## Where a named zone's own real landing spot is, in that region's local
## coordinates, keyed by the resolved region string.
##
## The server has no map data whatsoever -- every character enters the
## world at a single fixed spawnPos of (0, 0, 0) (see
## server/internal/session/world.go), which is the geometric centre of
## whatever region the zone resolves to, and is a recognisable place only
## by accident. Jangan's real entrance is its town square, so that is
## where a real login lands.
## The square's own centre is the dragon statue's plinth, so the landing
## spot sits a little north of it -- the scene's camera looks along -Z, so
## this puts the statue straight ahead on arrival instead of inside the
## balustrade around it.
const ZONE_SPAWN_LOCAL := {
	"97/168": Vector2(1002.0, 1020.0),
}

## The real Dunhuang region, found 2026-08-26 the same way as
## JANGAN_ZONE_REGION (server/cmd/scanlandmarks scanning for real
## "Res\Bldg\China\Dunhuang\..." resource paths across all 4,050 real
## regions) -- "98/157" has 279 matching real placements, the densest real
## match found.
const DUNHUANG_ZONE_REGION := "98/157"

## Three more real named regions, found 2026-08-24 by the same real
## technique as Jangan/Dunhuang (server/cmd/findregionassets, scanning every
## real object placement across all 4,050 real regions for a path
## containing the candidate name, then picking the densest real cluster --
## see docs/PROGRESS.md's 2026-08-24 "cont'd 79"/"cont'd 80" entries for the
## full real render verification each one already got). Confirmed real,
## distinct architecture for each at the time: Constantinople (European
## drawbridge/gate, cobblestone streets, a real 23-piece merchant stall),
## Hotan (Middle-Eastern/oasis castellated stone walls, a real domed
## building with carved lattice screens), Samarkand (smaller real cluster,
## real sand-to-grass biome transition terrain). These were real, confirmed
## finds that simply never got wired into this lookup table until now --
## not new RE work, just real data that existed and wasn't connected yet.
const CONSTANTINOPLE_ZONE_REGION := "104/80"
const HOTAN_ZONE_REGION := "92/135"
const SAMARKAND_ZONE_REGION := "106/107"

## Resolves a zone label to a real region coordinate string ("<x>/<y>").
## The server's own symbolic default spawn zone, "jangan" (case-
## insensitive, see server/internal/session/world.go's spawnZone), maps to
## JANGAN_ZONE_REGION -- previously this project had no known real region
## coordinate for it at all (an honest gap, before this project had found
## where Jangan actually is). The other real named zones below map the same
## way, for manual zone-change testing (typing the name into the zone-change
## box, see ZoneInput/ChangeZoneButton). Any other zone label is returned
## unchanged, for _zone_paths/_parse_region_coords to interpret (a raw
## "<x>/<y>" coordinate, matching any of this client's real 4,050 regions,
## already works today without a name -- see _zone_paths) or reject as usual.
static func _resolve_zone_region(zone: String) -> String:
	var lower := zone.to_lower()
	if lower == "jangan":
		return JANGAN_ZONE_REGION
	if lower == "dunhuang":
		return DUNHUANG_ZONE_REGION
	if lower == "constantinople":
		return CONSTANTINOPLE_ZONE_REGION
	if lower == "hotan":
		return HOTAN_ZONE_REGION
	if lower == "samarkand":
		return SAMARKAND_ZONE_REGION
	return zone

## Splits a zone label shaped like this project's real Map.pk2 region
## naming (an (x, y) folder/filename pair -- see docs/protocol/
## MAPM_FORMAT.md/MAPO_FORMAT.md, e.g. "100/100", "102/101") into the real
## internal paths those regions live at, after resolving it via
## _resolve_zone_region. Returns {} for anything not shaped "<x>/<y>" with
## both parts non-empty.
static func _zone_paths(zone: String) -> Dictionary:
	var parts := _resolve_zone_region(zone).split("/")
	if parts.size() != 2 or parts[0] == "" or parts[1] == "":
		return {}
	var x := parts[0]
	var y := parts[1]
	return {
		"m": "%s\\%s.m" % [x, y],
		"o": "%s\\%s.o" % [x, y],
		# **Corrected 2026-09-08.** The real minimap filename is
		# `<y>x<x>.ddj`, not `<x>x<y>.ddj`: real Jangan is region x=97,
		# y=168, real `minimap\\97x168.ddj` does not exist in a real
		# Media.pk2 at all, and real `minimap\\168x97.ddj` does -- and
		# decoding it shows the real Jangan town square, octagonal plaza
		# and dragon statue included. This was latent rather than visible
		# because the minimap is only used to texture terrain in the
		# fallback path taken when real per-tile textures are
		# unavailable; where it does bite, both spellings can name real
		# files, so a region could be painted with a *different*
		# region's minimap. `client/tools/audit_terrain_fidelity.gd` had
		# the order right all along.
		"minimap": "minimap\\%sx%s.ddj" % [y, x],
	}

## Parses a real region coordinate pair out of either a zone label ("100/100")
## or a loose/env-var-style file path ("100\100.m", "100/100.m") -- accepts
## either separator and strips a trailing extension if present. Returns {}
## for anything not shaped "<int>/<int>[.ext]", same convention as
## _zone_paths, so a non-region path (e.g. a loose dev file with no real
## coordinate meaning) is left alone rather than guessed at.
static func _parse_region_coords(path: String) -> Dictionary:
	var parts := path.replace("/", "\\").split("\\")
	if parts.size() < 2:
		return {}
	var x_part := parts[-2]
	var y_part := parts[-1].get_basename()
	if not x_part.is_valid_int() or not y_part.is_valid_int():
		return {}
	return {"x": int(x_part), "y": int(y_part)}

## Removes every previously-loaded region grid node (see
## _load_region_neighborhood) so a zone change or a fresh load doesn't leave
## stale terrain/objects from a different region behind.
##
## Takes the nodes out of the tree *immediately* rather than only calling
## queue_free(), which defers the removal to the end of the frame. That
## deferral was a real bug, found in a real playtest (2026-09-07): changing
## zone from 98/168 to 97/168 rebuilds a grid that overlaps the old one --
## a REGION_LOAD_RADIUS window around 98/168 already contains 97/168 --
## so the new `RealTerrain_97_168` was added while the old node of that
## exact name was still in the tree. Godot resolves the collision by
## renaming the newcomer, which broke everything that finds a region by
## node name. The visible symptom was a city with no buildings in it:
## _try_load_real_map_objects parents a region's objects to its terrain
## node found by name, so every object in the arrived-at region was
## parented to the *outgoing* node and was deleted along with it at the
## end of that same frame. The zone label read `[@Node3D@4862]` instead of
## `[97_168]` for the same reason, and both _load_region_neighborhood's
## grid-origin lookup and _maybe_stream_regions' per-cell lookup resolved
## to the stale node too.
##
## _region_nav_graphs is cleared here too -- it holds a reference to every
## terrain group, so leaving it populated kept the old regions' walkable
## graphs answering position queries for regions that no longer exist.
func _clear_region_grid() -> void:
	_region_nav_graphs.clear()
	# NPCs are parented to their region's terrain group, so tearing the grid
	# down takes them with it. Without clearing this, every region still
	# counts as "already populated" and a zone change leaves a world with
	# nobody in it -- which is exactly what a zone-changed render showed.
	_npc_regions_done.clear()
	for child in get_children():
		if child.name.begins_with("RealTerrain") or child.name.begins_with("RealMapObjects"):
			remove_child(child)
			child.queue_free()

## Loads a real (2*radius+1)x(2*radius+1) grid of regions centered on
## (center_x, center_y), one real Map.pk2 .m/.o pair per cell, tiled using
## REGION_SPAN as the grid spacing -- REGION_SPAN's own doc comment notes
## real per-region *adjacency* (whether the real world lays regions out on
## a uniform grid at all) isn't independently confirmed, but a real,
## live-verified consistency check now backs it up: since MapmReader's
## deterministic full-region parsing (2026-08-23), a region's own real
## mesh footprint (97 vertices x TILE_SIZE = exactly 1920 world units) now
## matches REGION_SPAN's real 1920.0 value *exactly* -- and a real 3x3
## grid of these regions, live-rendered from a top-down debug view,
## tiles together with zero visible gaps or overlaps between neighbors.
## That's a real, positive signal for uniform-grid adjacency (an
## unrelated real per-tile size and a real per-region spacing constant,
## both independently decompiled from different functions, wouldn't
## coincidentally match this exactly if regions weren't meant to tile
## this way) -- still not a hard confirmation of the real game's true
## spatial layout, but no longer just "this project's own design" either.
## Missing neighbor files (very likely near a real world's edge, or simply
## because this project only has a handful of real regions to test with) are
## skipped the same honest way a single missing region already was --
## _try_load_real_terrain/_try_load_real_map_objects print and move on
## rather than treating it as fatal. Only the center cell (0,0) snaps the
## player onto its terrain (see _snap_player_onto_terrain) -- that's real
## spawn-adjacent ground, not any of the speculative neighbors.
##
## Loads the center cell first and reuses its own real near_height as every
## other cell's shared_vertical_anchor (see _try_load_real_terrain's doc
## comment on why -- without this, every tile independently resets its own
## near edge to Y=0, guaranteeing a cliff at *every* seam and trapping the
## camera in overlapping geometry, confirmed live 2026-08-22). If the center
## cell itself fails to load (missing file, bad data), neighbors fall back
## to each calibrating themselves independently (NAN anchor) -- the original
## behavior -- since there's no real center reference to share in that case.
func _load_region_neighborhood(center_x: int, center_y: int, radius: int = REGION_LOAD_RADIUS, texture_override: String = "") -> void:
	var center_near_height := _try_load_real_terrain("%d\\%d.m" % [center_x, center_y], texture_override, Vector3.ZERO, "_%d_%d" % [center_x, center_y], true)
	_try_load_real_map_objects("%d\\%d.o" % [center_x, center_y], Vector3.ZERO, "_%d_%d" % [center_x, center_y])
	# The centre cell is loaded here rather than through _load_region_cell,
	# so it needs its own NPC pass -- without this the one region the player
	# is actually standing in is the only one with nobody in it.
	_try_spawn_region_npcs(center_x, center_y)

	_update_zone_label_for_region(center_x, center_y)
	_grid_origin_region = Vector2i(center_x, center_y)
	_grid_shared_anchor_height = center_near_height
	_grid_has_origin = true
	_loaded_cells.clear()
	_loaded_cells["0_0"] = true
	# The centre cell is (0,0); the neighbours stream in from here. Set the
	# stream cell to it (not the sentinel) so the queue's stale-guard keeps
	# the neighbours we are about to enqueue, and so a later _maybe_stream_regions
	# does not redundantly re-scan the same centre.
	_last_stream_cell = Vector2i(0, 0)
	var center_node := get_node_or_null("RealTerrain_%d_%d" % [center_x, center_y])
	_grid_origin_world = center_node.position if center_node != null else Vector3.ZERO

	# The neighbours are queued nearest-first and built a few per frame (see
	# _process_stream_queue and, at world entry, the loading screen's pump),
	# instead of all at once here -- that synchronous grid was most of the
	# minute-long, no-feedback entry.
	_load_queue.clear()
	_queued_cells.clear()
	var neighbours: Array = []
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if dx == 0 and dy == 0:
				continue # center cell already loaded above
			neighbours.append({
				"rx": center_x + dx, "ry": center_y + dy, "dx": dx, "dy": dy,
				"key": "%d_%d" % [dx, dy], "dist": absi(dx) + absi(dy),
			})
	neighbours.sort_custom(func(a, b): return a["dist"] < b["dist"])
	for cell in neighbours:
		_queued_cells[cell["key"]] = true
		_load_queue.append(cell)

## Loads one real region cell (terrain + objects) at grid position (dx, dy)
## relative to _grid_origin_region, and marks it loaded in _loaded_cells.
## Shared by the initial neighborhood load and _maybe_stream_regions --
## dx/dy must always be relative to the fixed _grid_origin_region, never
## to wherever the player currently is, so every cell's real world
## position stays consistent as the player moves and more cells stream in
## around them (see _grid_origin_world's own doc comment).
func _load_region_cell(region_x: int, region_y: int, dx: int, dy: int, shared_anchor: float) -> void:
	var suffix := "_%d_%d" % [region_x, region_y]
	# **Axes corrected 2026-09-02** (see docs/WORLD_ISSUES.md's forty-sixth
	# round) -- this was Vector3(dx * REGION_SPAN, 0.0, dy * REGION_SPAN),
	# i.e. region_x -> world X and region_y -> world Z. That was wrong, and
	# it was the real root cause of the hard straight-line seams at every
	# region boundary: it placed entirely unrelated real regions next to
	# each other, so neighbouring terrain never lined up in height *or*
	# texture. Real, exact proof (server/cmd's ad hoc findneighbor_scratch,
	# deleted after use): for a target region, every one of its four real
	# edge vertex rows matches exactly one other real region's opposite
	# edge with a mean absolute difference of **exactly 0.000000** -- and
	# the matching partners are region_x±1 on the north/south (world Z)
	# axis and region_y±1 on the west/east (world X) axis, the opposite of
	# what this code assumed. Verified on two unrelated real regions
	# (96/169 and 98/157), same rule both times. So: region_x -> world Z,
	# region_y -> world X.
	var offset := Vector3(dy * REGION_SPAN, 0.0, dx * REGION_SPAN)
	var t0 := Time.get_ticks_usec()
	_try_load_real_terrain("%d\\%d.m" % [region_x, region_y], "", offset, suffix, false, shared_anchor, false)
	var t1 := Time.get_ticks_usec()
	_try_load_real_map_objects("%d\\%d.o" % [region_x, region_y], offset, suffix)
	var t2 := Time.get_ticks_usec()
	_try_spawn_region_npcs(region_x, region_y)
	var t3 := Time.get_ticks_usec()
	_load_ms_terrain += (t1 - t0) / 1000.0
	_load_ms_objects += (t2 - t1) / 1000.0
	_load_ms_npcs += (t3 - t2) / 1000.0
	_loaded_cells["%d_%d" % [dx, dy]] = true

## Streams additional real region cells in as the player moves, keeping a
## real REGION_LOAD_RADIUS window centered on whichever real region
## they're currently standing over rather than the fixed spot they
## started at -- see _grid_origin_region's own doc comment for why this
## exists. Cheap to call every physics frame: the real region-coordinate
## check is trivial, and the expensive part (loading/unloading real
## regions) only runs on the real cell boundary crossings that actually
## need it, which happen roughly once per REGION_SPAN (1920 units)
## traveled, not every frame.
func _maybe_stream_regions() -> void:
	if not _grid_has_origin:
		return
	var rel := player.position - _grid_origin_world
	# cur.x is a region_x (folder) delta and cur.y a region_y (file) delta --
	# and region_x maps to world Z while region_y maps to world X, so these
	# read from the opposite world axes (see _load_region_cell's own comment
	# for the real, exactly-verified adjacency rule this follows).
	# The real world is mirrored in Z (see _try_load_real_terrain's own
	# **Un-mirrored** comment), so region_x now grows toward -Z and the
	# cell test has to follow it. Getting this wrong streams the
	# neighbouring regions in on the wrong side of the player.
	# **floor, not round** (fixed 2026-09-06, see docs/WORLD_ISSUES.md's
	# sixty-fifth round). `_grid_origin_world` is the origin region's own
	# *corner*, not its centre, so `rel` runs 0 -> REGION_SPAN across the
	# region the player is standing in. Rounding therefore flipped to the
	# next cell at the halfway point: from the middle of their own region
	# onward the player was treated as being in the neighbouring one, so the
	# loaded block was shifted a full region -- terrain ahead never streamed
	# in, terrain still underfoot behind them was unloaded, and the zone
	# label changed a half-region early. Flooring puts the boundary where the
	# real region boundary actually is.
	var cur := Vector2i(int(floorf(-rel.z / REGION_SPAN)), int(floorf(rel.x / REGION_SPAN)))
	if cur == _last_stream_cell:
		return
	_last_stream_cell = cur
	_update_zone_label_for_region(_grid_origin_region.x + cur.x, _grid_origin_region.y + cur.y)

	var radius := _region_load_radius()
	# Nearest-first, so the cells the player is about to reach build before the
	# far corners of the window.
	var new_cells: Array = []
	for dy in range(cur.y - radius, cur.y + radius + 1):
		for dx in range(cur.x - radius, cur.x + radius + 1):
			var key := "%d_%d" % [dx, dy]
			if _loaded_cells.has(key) or _queued_cells.has(key):
				continue
			new_cells.append({
				"rx": _grid_origin_region.x + dx, "ry": _grid_origin_region.y + dy,
				"dx": dx, "dy": dy, "key": key,
				"dist": absi(dx - cur.x) + absi(dy - cur.y),
			})
	new_cells.sort_custom(func(a, b): return a["dist"] < b["dist"])
	for cell in new_cells:
		_queued_cells[cell["key"]] = true
		_load_queue.append(cell)

	# Unload real cells now well outside the real load radius, so a player
	# walking through a real, large world doesn't accumulate every region
	# they've ever passed through as permanently-loaded nodes.
	var unload_margin := _region_load_radius() + 1
	for key in _loaded_cells.keys().duplicate():
		var parts := (key as String).split("_")
		var kdx := int(parts[0])
		var kdy := int(parts[1])
		if absi(kdx - cur.x) <= unload_margin and absi(kdy - cur.y) <= unload_margin:
			continue
		var suffix := "_%d_%d" % [_grid_origin_region.x + kdx, _grid_origin_region.y + kdy]
		var terrain_node := get_node_or_null("RealTerrain" + suffix)
		if terrain_node != null:
			terrain_node.queue_free()
		var objects_node := get_node_or_null("RealMapObjects" + suffix)
		if objects_node != null:
			objects_node.queue_free()
		_loaded_cells.erase(key)

## Builds up to STREAM_CELLS_PER_FRAME queued cells a frame, so a boundary
## crossing streams over several frames rather than freezing for one long
## one. A cell the player has since moved away from is dropped, not built.
func _process_stream_queue() -> void:
	if _load_queue.is_empty() or not _grid_has_origin:
		return
	var margin := _region_load_radius() + 1
	var built := 0
	while built < STREAM_CELLS_PER_FRAME and not _load_queue.is_empty():
		var cell: Dictionary = _load_queue.pop_front()
		_queued_cells.erase(cell["key"])
		if _loaded_cells.has(cell["key"]):
			continue
		if absi(cell["dx"] - _last_stream_cell.x) > margin or absi(cell["dy"] - _last_stream_cell.y) > margin:
			continue # the player left this cell's window before it built
		_load_region_cell(cell["rx"], cell["ry"], cell["dx"], cell["dy"], _grid_shared_anchor_height)
		built += 1

## Whether world entry shows the "NOW LOADING" screen: a real player does; a
## QA/dev render (SRREVAMP_MAPM_PATH set) does not, because its synchronous
## load is what the screenshot depends on -- unless SRREVAMP_QA_FORCE_LOADING
## asks for it, to render the screen itself.
func _should_show_loading_screen() -> bool:
	return OS.get_environment("SRREVAMP_MAPM_PATH") == "" or OS.get_environment("SRREVAMP_QA_FORCE_LOADING") != ""

# Cells built per frame while the loading screen is up: the player is not
# moving yet, so a bigger batch than the in-play stream is fine.
const LOADING_CELLS_PER_FRAME := 2

## Finishes the initial region load that `_load_region_neighborhood` queued.
## With no loading screen (a QA render) the queue is drained at once, so the
## first frames show the whole world. With one, the queue is pumped a batch a
## frame and the gauge filled, so a real entry has feedback instead of a black
## freeze.
func _drain_initial_load(region_started_ms: int) -> void:
	# No screen wanted (a QA render): build the queue at once so the first
	# frames show the whole world.
	if _loading_screen == null and not _should_show_loading_screen():
		while not _load_queue.is_empty():
			_build_one_queued_cell()
		print("World3D: region grid loaded in %d ms (terrain %.0f, objects %.0f, npcs %.0f)" % [Time.get_ticks_msec() - region_started_ms, _load_ms_terrain, _load_ms_objects, _load_ms_npcs])
		return
	# Reuse a screen a caller already put up (a teleport does, so even its
	# centre-cell load is covered), else make one now.
	if _loading_screen == null:
		_loading_screen = LoadingScreen.new()
		ui_control.add_child(_loading_screen)
		await get_tree().process_frame
	var total := maxi(_load_queue.size(), 1)
	while not _load_queue.is_empty():
		for _i in range(LOADING_CELLS_PER_FRAME):
			if _load_queue.is_empty():
				break
			_build_one_queued_cell()
		_loading_screen.set_progress(1.0 - float(_load_queue.size()) / float(total))
		await get_tree().process_frame
	print("World3D: region grid loaded in %d ms" % (Time.get_ticks_msec() - region_started_ms))
	_loading_screen.set_progress(1.0)
	_loading_screen.set_caption("Entering the world...")
	await get_tree().process_frame
	_loading_screen.queue_free()
	_loading_screen = null

## Puts the "NOW LOADING" screen up (a real player only), so a caller can
## cover a load whose first, synchronous part runs before the drain -- a
## teleport's centre cell. A no-op under QA or if one is already up.
func _show_loading_screen() -> void:
	if _loading_screen != null or not _should_show_loading_screen():
		return
	_loading_screen = LoadingScreen.new()
	ui_control.add_child(_loading_screen)
	await get_tree().process_frame

## Builds the next queued cell, if it is still wanted. Shared by the in-play
## stream and the entry-time drain.
func _build_one_queued_cell() -> void:
	if _load_queue.is_empty():
		return
	var cell: Dictionary = _load_queue.pop_front()
	_queued_cells.erase(cell["key"])
	if not _loaded_cells.has(cell["key"]):
		_load_region_cell(cell["rx"], cell["ry"], cell["dx"], cell["dy"], _grid_shared_anchor_height)

## _ready()'s own entry point into the region grid: reads SRREVAMP_MAPM_PATH
## the same way this scene always has, but now treats it as the *center* of
## a real multi-region neighborhood (see _load_region_neighborhood) instead
## of the one and only region loaded. Falls back to the original
## single-region behavior for a path that isn't shaped like a real region
## coordinate (e.g. a loose dev file with no real (x, y) meaning).
## How many regions out from the player to load, as an override of
## REGION_LOAD_RADIUS.
##
## The default 2 means a 5x5 grid -- 25 regions of terrain and objects
## parsed on every start. Measured on the render box, that fixed cost is
## about 65 seconds of a 94-second screenshot run, against 0.33 seconds a
## frame once it is up. Most checks only ever look at one region, so being
## able to ask for fewer is most of the wait.
func _region_load_radius() -> int:
	var override := OS.get_environment("SRREVAMP_QA_RADIUS")
	if override != "" and override.is_valid_int():
		return maxi(int(override), 0)
	return REGION_LOAD_RADIUS

func _load_initial_region_neighborhood() -> void:
	var mapm_path := OS.get_environment("SRREVAMP_MAPM_PATH")
	if mapm_path != "":
		var coords := _parse_region_coords(mapm_path)
		if coords.is_empty():
			_try_load_real_terrain()
			_try_load_real_map_objects()
			return
		_load_region_neighborhood(coords["x"], coords["y"], _region_load_radius(), OS.get_environment("SRREVAMP_MAPM_TEXTURE_PATH"))
		return

	# No dev/testing env var set -- the real, normal path for an actual
	# logged-in player: load whatever real zone the server itself already
	# placed them in (NetClient.last_enter_world_result.zone), the exact
	# same resolution _reload_zone_assets uses for a later zone change.
	# Without this, a real downloaded client with real pk2 files in its
	# local pk2/ folder (see Pk2Config) and no env vars set at all would
	# never load any terrain/objects on a normal login -- the env-var path
	# above was the only one ever wired to real region loading, which only
	# ever exercised this project's own dev/testing workflow, never a real
	# player's actual first spawn.
	var result := NetClient.last_enter_world_result
	if result != null and result.ok and result.zone != "":
		_reload_zone_assets(result.zone)
		_place_at_zone_spawn(result.zone)
	else:
		print("World3D: no real zone to load (no SRREVAMP_MAPM_PATH set and no real logged-in session) -- ground stays a placeholder")

## Tears down whatever real terrain/map-object nodes are currently loaded
## and reloads them for zone, resolving real per-zone paths via _zone_paths
## instead of the fixed SRREVAMP_MAPM_PATH/SRREVAMP_MAPO_PATH env vars this
## scene's initial _ready() load still uses. If zone isn't shaped like a
## real region coordinate (see _zone_paths), this just clears back to the
## placeholder ground with no objects -- same honest "nothing to load"
## behavior as an unset env var, not a guess.
func _reload_zone_assets(zone: String) -> void:
	_clear_region_grid()
	ground_mesh.visible = true
	ground_collision.disabled = false

	var region := _resolve_zone_region(zone)
	var coords := _parse_region_coords(region)
	if coords.is_empty():
		print("World3D: zone %s isn't shaped like a real region (x/y) -- no per-zone assets to load" % zone)
		# _clear_region_grid() above already removed every real region node
		# -- also drop the real streaming state that referenced them, so
		# _maybe_stream_regions doesn't keep trying to grow a grid around a
		# real origin cell that no longer exists.
		_grid_has_origin = false
		_loaded_cells.clear()
		return

	var paths := _zone_paths(zone)
	_load_region_neighborhood(coords["x"], coords["y"], _region_load_radius(), paths.get("minimap", ""))

## Reacts to a successful real zone change (see NetClient.change_zone/
## OpChangeZoneResult): updates the zone label and reloads this scene's
## terrain/map objects for the new real zone. A failed zone change (bad
## request, already in that zone, ...) is left to whatever UI triggered it
## to report -- this scene doesn't render its own error text for that.
func _on_change_zone_result(result: WorldNet.ChangeZoneResult) -> void:
	if not result.ok:
		return
	# A teleport shows the "NOW LOADING" screen (the playtester's call: the
	# loading screen belongs on a teleport). Up before the zone assets load so
	# even the synchronous centre-cell build is behind it; the queued
	# neighbours then pump behind it in _drain_initial_load below.
	await _show_loading_screen()
	zone_label.text = "Zone: %s" % result.zone
	player.position = Vector3(result.x, result.y, result.z)
	_last_sent_pos = player.position

	# Whoever was rendered as an "other" belonged to the *old* zone -- the
	# server only broadcasts OpEntityLeft to people left behind, never back
	# to the mover, so without this their stale capsules/bodies would keep
	# showing here even though this player can no longer interact with them
	# (see docs/PROGRESS.md for this bug, caught right after the initial
	# OpChangeZone implementation shipped).
	for character_id in _other_bodies.keys():
		_other_bodies[character_id].queue_free()
	_other_bodies.clear()
	_other_gaits.clear()
	for other in result.others:
		_spawn_or_update_other(other.character_id, other.char_name, Vector3(other.x, other.y, other.z), other.equipped, other.gender)

	# Same stale-body bug as _other_bodies above, for monsters -- the old
	# zone's monster list result never gets superseded on its own, so
	# without this their capsules would keep showing here too.
	for monster_id in _monster_bodies.keys():
		_monster_bodies[monster_id].queue_free()
	_monster_bodies.clear()
	NetClient.list_monsters()

	_reload_zone_assets(result.zone)

	# Only now, with the new region's terrain and walkable graph actually
	# built, can an `@x,z` from the zone box be honoured -- see
	# _split_zone_target.
	if _pending_zone_local != null:
		var spot: Vector2 = _pending_zone_local
		_pending_zone_local = null
		var coords := _parse_region_coords(_resolve_zone_region(result.zone))
		if not coords.is_empty() and _place_at_region_local(coords["x"], coords["y"], spot.x, spot.y):
			_refresh_zone_label_position()
		else:
			print("World3D: zone %s has no loaded region to stand at local %s, %s -- left at the server's own landing spot" % [
				result.zone, spot.x, spot.y])
	else:
		_place_at_zone_spawn(result.zone)

	# Pump the new zone's queued neighbour cells behind the loading screen (if
	# one is up), then drop it -- the same drain the first entry uses.
	await _drain_initial_load(Time.get_ticks_msec())

## Everything in the world that plays an animation -- NPCs and monsters.
## Each entry is [Skeleton3D, ParsedAnimation, frame count, phase, loops,
## started at, resume]: a looping idle, or a one-shot (a hit, a death) that
## holds its last frame and then goes back to `resume` -- an idle entry, or
## null to stay on the last frame, which is what a corpse does.
##
## Phase matters: without it every Mangyang in a field steps in perfect
## unison, which reads as a bug rather than as a crowd. Each character gets
## a fixed offset from its own instance count, so it is stable across frames
## rather than jittering.
var _animated: Array = []
# Assembled NPC bodies kept as detached templates, one per model path, and
# duplicated per spawn. Assembling a skinned .bsr is what made each region
# take seconds; most NPCs in a region share a model, and duplicating a node
# (sharing its mesh/texture resources) is far cheaper than re-assembling. The
# template is never parented, so unloading a region frees the duplicates, not
# it. See _try_spawn_region_npcs.
var _npc_model_cache := {} # model path -> SkinnedBsrAssembler.AssembledCharacter

## Registers an assembled character for idle animation, if it has one.
##
## **Enabled by default since real skinning landed.** This was off for one
## round, because animating a rigidly-attached model tore it apart: with
## every mesh piece bound to a single bone, rotating that bone swung a whole
## dress or torso, and a measured pair of renders showed the same NPC as a
## stretched spike with animation on and correct with it off.
##
## The cause was not animation. `.bms` carries real per-vertex skinning --
## a bone palette and two weighted influences per vertex, in its own section
## rather than in the vertex record -- and reading it makes these models
## deform properly. The same NPC in the same spot now stands in a red dress
## holding a fan, animated.
##
## `SRREVAMP_NO_IDLE_ANIM=1` turns it off again, which is how that A/B was
## run and how the next one can be.
func _animate(assembled: SkinnedBsrAssembler.AssembledCharacter) -> void:
	if assembled == null:
		return
	_animate_skeleton(assembled.skeleton, assembled.idle_animation)

## Registers a skeleton to play `anim` as its looping idle. Split from
## _animate so a duplicated NPC body (which is not the cached template's own
## skeleton) can be registered with the template's animation.
func _animate_skeleton(skeleton: Skeleton3D, anim: BanReader.ParsedAnimation) -> void:
	if skeleton == null or anim == null:
		return
	if OS.get_environment("SRREVAMP_NO_IDLE_ANIM") != "":
		return
	var frames := _frame_count(anim)
	if frames <= 1:
		return
	_animated.append([skeleton, anim, frames, float(_animated.size()) * 0.37, true, _idle_anim_time, null])

static func _frame_count(anim: BanReader.ParsedAnimation) -> int:
	var frames := 0
	if anim == null:
		return 0
	for track in anim.bones:
		frames = maxi(frames, track.keyframes.size())
	return frames

## Plays anim once on skeleton -- a hit reaction, a death -- in place of
## whatever it was playing, and afterwards returns to that (or holds the
## last frame if `hold` is set, which a death does). Returns how long the
## one-shot runs, in seconds, so a caller can wait for it.
func _play_once(skeleton: Skeleton3D, anim: BanReader.ParsedAnimation, hold: bool = false) -> float:
	var frames := _frame_count(anim)
	if skeleton == null or frames <= 1:
		return 0.0
	var resume = null
	for i in range(_animated.size()):
		var entry: Array = _animated[i]
		if entry[0] == skeleton:
			# Resume the idle it was on, not a one-shot it was in the
			# middle of.
			resume = entry if entry[4] else entry[6]
			_animated.remove_at(i)
			break
	_animated.append([skeleton, anim, frames, 0.0, false, _idle_anim_time, null if hold else resume])
	return anim.duration_seconds()

## Advances every idle animation. Entries whose skeleton has gone (a region
## streamed out, a monster died) are dropped as they are found, which keeps
## this from holding freed nodes alive.
func _tick_idle_animations(delta: float) -> void:
	if _animated.is_empty():
		return
	_idle_anim_time += delta
	var alive: Array = []
	for entry in _animated:
		var skeleton: Skeleton3D = entry[0]
		if not is_instance_valid(skeleton) or not skeleton.is_inside_tree():
			continue
		var anim: BanReader.ParsedAnimation = entry[1]
		var phase: float = entry[3]
		var loops: bool = entry[4]
		if loops:
			Skeleton3DBuilder.apply_ban_pose_at(skeleton, anim, _idle_anim_time + phase, true)
		else:
			# A one-shot runs from when it started, on the clip's own clock,
			# and holds its last keyframe; once there, hand back to what it
			# interrupted.
			var elapsed := _idle_anim_time - float(entry[5])
			if elapsed >= anim.duration_seconds() and entry[6] != null:
				var resume: Array = entry[6]
				resume[5] = _idle_anim_time
				alive.append(resume)
				Skeleton3DBuilder.apply_ban_pose_at(skeleton, resume[1], _idle_anim_time + float(resume[3]), true)
				continue
			Skeleton3DBuilder.apply_ban_pose_at(skeleton, anim, elapsed, false)
		alive.append(entry)
	if alive.size() != _animated.size():
		_animated = alive

var _idle_anim_time := 0.0
## monster id -> the assembled character behind its body, for playing its
## own hit and death animations by type.
var _monster_assembled: Dictionary = {}
## monster id -> the _idle_anim_time until which its death animation runs.
var _dying_until: Dictionary = {}

## Every NPC the client knows how to place, grouped by region, and the
## id -> model table that goes with them. Both come out of the player's own
## Media.pk2 (see NpcTableReader), so nothing is shipped and no server has
## to supply them. Loaded once, on the first region that asks.
var _npc_spawns_by_region: Dictionary = {}
var _npc_models: Dictionary = {}
## npc id -> the name the game calls it, from characterdata joined with
## textdata_object.
var _npc_names: Dictionary = {}
## npc id -> codename (NPC_CH_SMITH), the key the shop/greeting tables use.
var _npc_codes: Dictionary = {}
## Upper-cased NPC codenames that run a shop (refshopgroup) -> the "Buy" service.
var _npc_shop_set: Dictionary = {}
## NPC codename (upper) -> [greeting msg1 SN_ id, msg2 SN_ id] from npcchat.txt.
var _npc_greetings: Dictionary = {}
## textdata_object table, kept to resolve NPC greeting SN_ strings.
var _npc_text_table: UiTextTable = null
## The shop tables (ShopReader), so the Buy option can open the NPC's real
## goods. Built lazily with the NPC tables.
var _shop_reader: ShopReader = null
var _npc_tables_loaded := false
## The NPC whose talk box is open, so a chosen service (Buy, ...) knows who it
## is for.
var _talk_npc_name := ""
var _talk_npc_code := ""
## Regions whose NPCs have already been placed, so streaming back into a
## region doesn't stack a second copy of everyone in it.
var _npc_regions_done: Dictionary = {}

func _load_npc_tables() -> void:
	if _npc_tables_loaded:
		return
	_npc_tables_loaded = true
	# Opened here rather than reusing _media_pk2: region streaming starts
	# before _try_initialize_pk2_ui() runs, so that handle is still null the
	# first time a region asks for its NPCs.
	if _media_pk2 == null:
		_media_pk2 = _open_media_pk2_if_set()
	if _media_pk2 == null:
		return
	var pos_entry := ObjectLoader.find_file(_media_pk2, NpcTableReader.POSITION_TABLE_PATH)
	if pos_entry == null:
		print("World3D: no npcpos.txt in Media.pk2 -- no NPCs")
		return
	for spawn in NpcTableReader.parse_positions(_media_pk2.read_file(pos_entry)):
		var key := "%d_%d" % [spawn.region_x, spawn.region_y]
		if not _npc_spawns_by_region.has(key):
			_npc_spawns_by_region[key] = []
		_npc_spawns_by_region[key].append(spawn)
	# The same characterdata parts give the model and the name: a row
	# carries an id, an `SN_` key and a `.bsr`, and textdata_object turns
	# the key into what the game calls the NPC. Read once, joined twice.
	var names_entry := ObjectLoader.find_file(_media_pk2, NpcTableReader.OBJECT_NAME_TABLE_PATH)
	var names: UiTextTable = null
	if names_entry != null:
		names = UiTextTable.parse(_media_pk2.read_file(names_entry))
	# NPC greetings resolve through a different table than names: npcchat's SN_
	# ids live in textquest_speechname.txt (with the English in a later column,
	# which UiTextTable picks by content).
	var greet_entry := ObjectLoader.find_file(_media_pk2, "server_dep\\silkroad\\textdata\\textquest_speechname.txt")
	if greet_entry != null:
		_npc_text_table = UiTextTable.parse(_media_pk2.read_file(greet_entry))
	for path in NpcTableReader.MODEL_TABLE_PATHS:
		var entry := ObjectLoader.find_file(_media_pk2, path)
		if entry != null:
			var bytes := _media_pk2.read_file(entry)
			_npc_models = NpcTableReader.parse_models(bytes, _npc_models)
			_npc_codes = NpcTableReader.parse_codes(bytes, _npc_codes)
			if names != null:
				_npc_names = NpcTableReader.parse_names(bytes, names, _npc_names)
	# What each NPC offers: shops (refshopgroup) and greetings (npcchat).
	var shop_entry := ObjectLoader.find_file(_media_pk2, NpcServiceReader.SHOP_TABLE)
	if shop_entry != null:
		_npc_shop_set = NpcServiceReader.parse_shop_npcs(_media_pk2.read_file(shop_entry))
	var chat_entry := ObjectLoader.find_file(_media_pk2, NpcServiceReader.CHAT_TABLE)
	if chat_entry != null:
		_npc_greetings = NpcServiceReader.parse_greetings(_media_pk2.read_file(chat_entry))
	# The shop goods chain (refshopgroup -> ... -> item codename), so Buy shows
	# the NPC's real wares. Reads through _media_pk2 by archive path.
	_shop_reader = ShopReader.new().load(func(archive_path: String) -> PackedByteArray:
		var e := ObjectLoader.find_file(_media_pk2, archive_path)
		return _media_pk2.read_file(e) if e != null else PackedByteArray())
	print("World3D: NPC tables -- %d spawn(s) across %d region(s), %d model(s), %d name(s), %d shop, %d greetings" % [
		_npc_spawn_total(), _npc_spawns_by_region.size(), _npc_models.size(), _npc_names.size(), _npc_shop_set.size(), _npc_greetings.size()])

## A floating name over an NPC's head.
##
## Height comes from the assembled skeleton's own bones rather than a fixed
## offset: NPC models vary a great deal in size (the same reason the monster
## labels measure their skeleton), and one number puts a label through a
## tall NPC's face and far above a short one.
func _name_plate(text: String, above: float) -> Label3D:
	var label := Label3D.new()
	label.name = "Name"
	label.text = text
	label.position = Vector3(0.0, above * (1.0 + NAME_PLATE_CLEARANCE_FRACTION), 0.0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	# **Fixed size, not world size.** The real client draws a name plate in
	# screen space from the entity's position, so it reads the same however
	# far away the entity is. A world-scaled Label3D instead shrinks with
	# distance, and at this world's scale -- a character is
	# REAL_CHARACTER_NATIVE_HEIGHT units tall, not 1.8 -- the default 0.005
	# pixel size made every plate a smear a few pixels high. That is why the
	# monster labels have never shown up in a render either.
	label.fixed_size = true
	label.pixel_size = NAME_PLATE_PIXEL_SIZE
	label.modulate = NAME_PLATE_COLOUR
	label.outline_size = NAME_PLATE_OUTLINE
	label.outline_modulate = NAME_PLATE_OUTLINE_COLOUR
	# Names read over whatever they stand in front of, which is what makes a
	# crowd of NPCs legible.
	label.no_depth_test = true
	label.render_priority = 1
	label.add_to_group("name_plates")
	_apply_name_plate_range(label)
	return label

## Where a name sits over a model, how large it draws, and in what colour.
##
## Ours, not recovered: nothing in the archive places a name plate, because
## the client draws them in screen space rather than as scene geometry.
## The clearance is a fraction of the model's own height, so it works for a
## creature of any size rather than only for a human-sized one.
const NAME_PLATE_CLEARANCE_FRACTION := 0.12
const NAME_PLATE_PIXEL_SIZE := 0.0004
const NAME_PLATE_COLOUR := Color(1.0, 0.94, 0.72)
const NAME_PLATE_OUTLINE := 8
const NAME_PLATE_OUTLINE_COLOUR := Color(0.0, 0.0, 0.0, 0.85)
## How near an entity has to be before its name shows, in world units (a
## character is about 16 tall), with the plate fading in over the last
## tenth of that. A project choice, not a recovered value: nothing found
## says where the original starts drawing names. Every plate is in the
## "name_plates" group so set_name_plate_range can change it live.
const NAME_PLATE_RANGE := 80.0
var _name_plate_range := NAME_PLATE_RANGE

## A monster's HP bar, the way the original shows one over its head: a name
## above and a red bar below it. The bar is a single fixed-size billboarded
## Sprite3D whose texture is drawn per fraction (a dark frame, a red fill),
## so there is no two-sprite alignment to get wrong and it reads the same at
## any distance -- the same reason the name plate is fixed-size. Colours and
## size are a disclosed choice; nothing recovered gives the original's.
const HP_BAR_TEX_W := 64
const HP_BAR_TEX_H := 8
const HP_BAR_PIXEL_SIZE := 0.006
const HP_BAR_FILL := Color(0.78, 0.12, 0.10)
const HP_BAR_BG := Color(0.05, 0.05, 0.05, 0.85)
const HP_BAR_FRAME := Color(0.0, 0.0, 0.0, 0.95)

func _hp_bar_texture(fraction: float) -> ImageTexture:
	var img := Image.create(HP_BAR_TEX_W, HP_BAR_TEX_H, false, Image.FORMAT_RGBA8)
	img.fill(HP_BAR_FRAME)
	var frac := clampf(fraction, 0.0, 1.0)
	var inner_w := HP_BAR_TEX_W - 2
	var filled := int(round(inner_w * frac))
	for y in range(1, HP_BAR_TEX_H - 1):
		for x in range(1, HP_BAR_TEX_W - 1):
			img.set_pixel(x, y, HP_BAR_FILL if (x - 1) < filled else HP_BAR_BG)
	return ImageTexture.create_from_image(img)

## A billboarded HP bar sitting `above` the model's feet, fixed screen size,
## in the name-plate group so it fades in over the same range.
func _hp_bar(above: float) -> Sprite3D:
	var bar := Sprite3D.new()
	bar.name = "HpBar"
	bar.texture = _hp_bar_texture(1.0)
	bar.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	bar.fixed_size = true
	bar.pixel_size = HP_BAR_PIXEL_SIZE
	bar.no_depth_test = true
	bar.render_priority = 2
	bar.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	bar.position = Vector3(0.0, above, 0.0)
	bar.add_to_group("name_plates")
	_apply_name_plate_range(bar)
	return bar

func _set_hp_bar(body: Node3D, hp: int, max_hp: int) -> void:
	var bar := body.get_node_or_null("HpBar") as Sprite3D
	if bar != null and max_hp > 0:
		bar.texture = _hp_bar_texture(float(hp) / float(max_hp))

## The target window: the current target's name and HP bar at the top of
## the screen, the way the original shows whatever the player has clicked.
## A name-plus-bar rather than the authored iftargetwindow frame (whose
## name/HP/level are client-drawn over it, so this shows the same
## information honestly); shown on click/attack, updated on damage, hidden
## on death or when nothing is targeted.
# The current-target window at the top of the screen, built on the client's
# own frame art (interface\targetwindow\tw_type1.ddj, 200x72). Name, the real
# level (grounded from characterdata _RefObjChar col 57, carried in the monster
# snapshot), and an HP bar with its percent -- all data the server sends. The
# real window's rank gem is still left off: rank isn't grounded/on the wire yet,
# and inventing it is against the rules. See docs/WORLD_ISSUES.md.
const TARGET_FRAME_DDJ := "interface\\targetwindow\\tw_type1.ddj"
const TARGET_WINDOW_WIDTH := 320.0
const TARGET_WINDOW_HEIGHT := 115.0
# Slot rects [x, y, w, h] as fractions of the frame, eyeballed from the real
# 200x72 art and tuned by rendering -- a disclosed layout choice.
const TARGET_NAME_RECT := [0.15, 0.10, 0.80, 0.26]
const TARGET_HP_RECT := [0.08, 0.56, 0.85, 0.18]
var _target_window: Control = null
var _target_name_label: Label = null
var _target_hp_fill: ColorRect = null
var _target_hp_pct: Label = null
var _target_rank_icon: TextureRect = null
var _target_hp_full := 0.0

func _build_target_window() -> void:
	_target_window = Control.new()
	_target_window.name = "TargetWindow"
	_target_window.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_target_window.anchor_left = 0.5
	_target_window.anchor_right = 0.5
	_target_window.offset_left = -TARGET_WINDOW_WIDTH / 2.0
	_target_window.offset_right = TARGET_WINDOW_WIDTH / 2.0
	_target_window.offset_top = 12.0
	_target_window.offset_bottom = 12.0 + TARGET_WINDOW_HEIGHT
	_target_window.visible = false

	# The authored frame, or a plain box if no archive is loaded.
	var frame_tex: Texture2D = _ui_builder.load_texture(TARGET_FRAME_DDJ) if _ui_builder != null else null
	if frame_tex != null:
		var frame := TextureRect.new()
		frame.texture = frame_tex
		frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		frame.stretch_mode = TextureRect.STRETCH_SCALE
		frame.set_anchors_preset(Control.PRESET_FULL_RECT)
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_target_window.add_child(frame)
	else:
		var bg := ColorRect.new()
		bg.color = Color(0.0, 0.0, 0.0, 0.55)
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_target_window.add_child(bg)

	_target_name_label = Label.new()
	_target_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_target_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_target_name_label.position = Vector2(TARGET_WINDOW_WIDTH * TARGET_NAME_RECT[0], TARGET_WINDOW_HEIGHT * TARGET_NAME_RECT[1])
	_target_name_label.size = Vector2(TARGET_WINDOW_WIDTH * TARGET_NAME_RECT[2], TARGET_WINDOW_HEIGHT * TARGET_NAME_RECT[3])
	_target_name_label.add_theme_color_override("font_color", NAME_PLATE_COLOUR)
	_target_name_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_target_name_label.add_theme_constant_override("outline_size", 3)
	if _ui_builder != null:
		var font := _ui_builder.font_at(0)
		if font != null:
			_target_name_label.add_theme_font_override("font", font)
		_target_name_label.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
	_target_window.add_child(_target_name_label)

	var hp_x := TARGET_WINDOW_WIDTH * TARGET_HP_RECT[0]
	var hp_y := TARGET_WINDOW_HEIGHT * TARGET_HP_RECT[1]
	_target_hp_full = TARGET_WINDOW_WIDTH * TARGET_HP_RECT[2]
	var hp_h := TARGET_WINDOW_HEIGHT * TARGET_HP_RECT[3]

	var hp_bg := ColorRect.new()
	hp_bg.color = HP_BAR_BG
	hp_bg.position = Vector2(hp_x, hp_y)
	hp_bg.size = Vector2(_target_hp_full, hp_h)
	hp_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_target_window.add_child(hp_bg)

	_target_hp_fill = ColorRect.new()
	_target_hp_fill.color = HP_BAR_FILL
	_target_hp_fill.position = Vector2(hp_x, hp_y)
	_target_hp_fill.size = Vector2(_target_hp_full, hp_h)
	_target_hp_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_target_window.add_child(_target_hp_fill)

	_target_hp_pct = Label.new()
	_target_hp_pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_target_hp_pct.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_target_hp_pct.position = Vector2(hp_x, hp_y - 1.0)
	_target_hp_pct.size = Vector2(_target_hp_full, hp_h + 2.0)
	_target_hp_pct.add_theme_color_override("font_color", Color(1, 1, 1))
	_target_hp_pct.add_theme_color_override("font_outline_color", Color.BLACK)
	_target_hp_pct.add_theme_constant_override("outline_size", 3)
	_target_hp_pct.add_theme_font_size_override("font_size", 11)
	_target_hp_pct.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_target_window.add_child(_target_hp_pct)

	# The rank gem (top-left), set per target from its rarity. Position is a
	# disclosed layout choice like the name/HP rects; the gem art and the
	# rarity->gem mapping are grounded (see _rank_icon_path).
	_target_rank_icon = TextureRect.new()
	_target_rank_icon.position = Vector2(10, 8)
	_target_rank_icon.size = Vector2(22, 22)
	_target_rank_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_target_rank_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_target_rank_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_target_window.add_child(_target_rank_icon)

	ui_control.add_child(_target_window)

## The target-window rank gem for a monster's rarity (characterdata _RefObjChar
## col 15). The mapping is recovered from the retail client (FUN_0069b4c0's
## switch): 0/7 normal, 1 champion, 3/8 unique, 4 giant, 5 titan, 6 elite; any
## other value shows no gem. Returns "" for no gem.
func _rank_icon_path(rarity: int) -> String:
	match rarity:
		0, 7:
			return "interface\\targetwindow\\tw_icon_normal.ddj"
		1:
			return "interface\\targetwindow\\tw_icon_champion.ddj"
		3, 8:
			return "interface\\targetwindow\\tw_icon_unique.ddj"
		4:
			return "interface\\targetwindow\\tw_icon_giant.ddj"
		5:
			return "interface\\targetwindow\\tw_icon_titan.ddj"
		6:
			return "interface\\targetwindow\\tw_icon_elite.ddj"
	return ""

## Shows the target window for a monster id, or hides it if the id is not a
## known live monster.
func _show_target(monster_id: int) -> void:
	if _target_window == null:
		return
	var snap = _monster_snapshots.get(monster_id)
	if snap == null:
		_target_window.visible = false
		return
	# Name plus the monster's real level (from characterdata, sent in the
	# snapshot). Rank is still omitted -- it isn't grounded/on the wire yet.
	if snap.level > 0:
		_target_name_label.text = "%s  Lv %d" % [snap.monster_name, snap.level]
	else:
		_target_name_label.text = snap.monster_name
	# The rank gem, from the monster's rarity (grounded mapping).
	if _target_rank_icon != null:
		var gem := _rank_icon_path(snap.rarity)
		_target_rank_icon.texture = _ui_builder.load_texture(gem) if (gem != "" and _ui_builder != null) else null
	_set_target_hp(snap.hp, snap.max_hp)
	_target_window.visible = true

func _set_target_hp(hp: int, max_hp: int) -> void:
	if _target_hp_fill == null or max_hp <= 0:
		return
	var fraction := clampf(float(hp) / float(max_hp), 0.0, 1.0)
	_target_hp_fill.size.x = _target_hp_full * fraction
	if _target_hp_pct != null:
		_target_hp_pct.text = "%d%%" % roundi(fraction * 100.0)

func _clear_target() -> void:
	if _target_window != null:
		_target_window.visible = false

# How far the number climbs while it fades, in world units. Scaled by
# PLAYER_SCALE_RATIO like every other height here (a character is about
# 2 * PLAYER_SCALE_RATIO tall, not 1.8), or the rise would be imperceptible
# in this world's real scale. About three-quarters of a character height.
const FLOAT_TEXT_RISE := 1.5 * PLAYER_SCALE_RATIO
const FLOAT_TEXT_SECONDS := 1.1
const DAMAGE_DEALT_COLOUR := Color(1.0, 1.0, 0.95)
const DAMAGE_TAKEN_COLOUR := Color(1.0, 0.45, 0.35)

## A damage number that rises and fades over the thing it was dealt to, the
## way the original shows combat damage. White for damage the player deals,
## a warm red for damage the player takes. Fixed-size and billboarded like
## the name plates so it reads at any distance; it frees itself when done.
func _floating_damage(anchor: Node3D, height: float, amount: int, colour: Color) -> void:
	if anchor == null or not is_instance_valid(anchor):
		return
	var label := Label3D.new()
	label.text = str(amount)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.fixed_size = true
	label.pixel_size = NAME_PLATE_PIXEL_SIZE * 1.8
	label.modulate = colour
	label.outline_size = NAME_PLATE_OUTLINE
	label.outline_modulate = NAME_PLATE_OUTLINE_COLOUR
	label.no_depth_test = true
	label.render_priority = 3
	label.position = Vector3(0.0, height, 0.0)
	anchor.add_child(label)
	# During a QA attack render, log where the number landed on screen, so a
	# frame crop can be aimed at it rather than hunted for. Off in real play.
	if _qa_attacking:
		var cam := get_viewport().get_camera_3d()
		if cam != null:
			var sp := cam.unproject_position(anchor.global_position + Vector3(0.0, height, 0.0))
			print("World3D: FLOAT %d over %s at screen %.0f,%.0f" % [amount, anchor.name, sp.x, sp.y])
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position:y", height + FLOAT_TEXT_RISE, FLOAT_TEXT_SECONDS)
	tween.tween_property(label, "modulate:a", 0.0, FLOAT_TEXT_SECONDS)
	# The outline carries its own alpha, so fade it with the fill or a black
	# ghost of the number lingers after the text has gone.
	tween.tween_property(label, "outline_modulate:a", 0.0, FLOAT_TEXT_SECONDS)
	tween.finished.connect(label.queue_free)

## The height a floating number starts at over a monster -- its HP bar's,
## or a default when it has no bar.
func _monster_text_height(monster_id: int) -> float:
	var body = _monster_bodies.get(monster_id)
	if body != null and is_instance_valid(body):
		var bar := (body as Node3D).get_node_or_null("HpBar") as Sprite3D
		if bar != null:
			return bar.position.y
	# Every spawned monster gets an HP bar, so this fallback is rare; human
	# head height (same PLAYER_SCALE_RATIO calibration) beats an unscaled
	# constant that would sit at the monster's feet in this world's scale.
	return 2.0 * PLAYER_SCALE_RATIO

## Changes how near an entity has to be before its name shows, for every
## plate already in the scene and every one made from now on.
func set_name_plate_range(distance: float) -> void:
	_name_plate_range = maxf(distance, 0.0)
	for node in get_tree().get_nodes_in_group("name_plates"):
		_apply_name_plate_range(node as GeometryInstance3D)

## Takes a GeometryInstance3D so it works for both the Label3D name plates
## and the Sprite3D HP bars, which share the "name_plates" group and fade
## over the same range.
func _apply_name_plate_range(label: GeometryInstance3D) -> void:
	if label == null:
		return
	label.visibility_range_end = _name_plate_range
	label.visibility_range_end_margin = _name_plate_range * 0.1
	label.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF

## The top of an assembled skeleton, in its own local space.
func _skeleton_top(skeleton: Skeleton3D) -> float:
	return _skeleton_bounds(skeleton).y

## An assembled skeleton's own extent, as (horizontal radius, height).
##
## Height is the highest bone. **Radius is half the model's shallower
## horizontal axis**, not its wider one and not the furthest bone: these
## models stand in a bind pose with their arms out, so the widest bone is a
## hand and the furthest-bone radius came out 5 to 9 units on NPCs 10 to 17
## units tall -- a capsule as wide as the NPC is tall, which stops a player
## well short of touching one. The shallower axis is the model's own
## front-to-back thickness, which is what a body is.
##
## Measured from the mesh AABBs rather than the bones for the same reason:
## the bones say where the arms reach, the geometry says how thick the
## torso is.
func _skeleton_bounds(skeleton: Skeleton3D) -> Vector2:
	var aabb := AABB()
	var have := false
	for child in skeleton.get_children():
		if not (child is VisualInstance3D):
			continue
		var box := (child as VisualInstance3D).get_aabb()
		aabb = box if not have else aabb.merge(box)
		have = true
	if not have:
		# No geometry to measure -- fall back to the bones, which at least
		# say how tall the thing is.
		var top := 0.0
		for i in range(skeleton.get_bone_count()):
			top = maxf(top, skeleton.get_bone_global_pose(i).origin.y)
		return Vector2(NPC_MIN_RADIUS, top * skeleton.scale.y)
	var depth: float = minf(aabb.size.x, aabb.size.z) * skeleton.scale.x
	return Vector2(depth * 0.5, aabb.end.y * skeleton.scale.y)

## A body that stops the player walking through an NPC.
func _npc_collider(bounds: Vector2) -> StaticBody3D:
	var shape := CapsuleShape3D.new()
	shape.radius = maxf(bounds.x, NPC_MIN_RADIUS)
	shape.height = maxf(bounds.y, NPC_MIN_HEIGHT)
	var body := StaticBody3D.new()
	body.name = "Body"
	body.collision_layer = NPC_COLLISION_LAYER
	# An NPC is something to walk into, not something to stand on or to
	# aim the ground-snap ray at, so it stays off the terrain layer.
	body.collision_mask = 0
	var collider := CollisionShape3D.new()
	collider.shape = shape
	# A capsule is centred on its own origin; the NPC's is at its feet.
	collider.position = Vector3(0.0, shape.height * 0.5, 0.0)
	body.add_child(collider)
	return body

## Reports, for every placed NPC within QA_NPCBODY_RANGE, the capsule it
## was given and whether a ray aimed at its middle actually hits it.
const QA_NPCBODY_RANGE := 400.0

func _qa_npc_body_report() -> void:
	var space := get_world_3d().direct_space_state
	var checked := 0
	var blocked := 0
	for group in get_children():
		if not (group is Node3D) or not group.name.begins_with("RealTerrain_"):
			continue
		for holder in group.get_children():
			if not holder.name.begins_with("Npc_"):
				continue
			var origin: Vector3 = (holder as Node3D).global_position
			if origin.distance_to(player.global_position) > QA_NPCBODY_RANGE:
				continue
			var body := holder.get_node_or_null("Body") as StaticBody3D
			var shape: CapsuleShape3D = null
			if body != null:
				var cs := body.get_node_or_null("CollisionShape3D") as CollisionShape3D
				if cs == null:
					for child in body.get_children():
						if child is CollisionShape3D:
							cs = child as CollisionShape3D
							break
				if cs != null:
					shape = cs.shape as CapsuleShape3D
			checked += 1
			if shape == null:
				print("QA NPCBODY %s: no collider" % holder.name)
				continue
			# From just outside the capsule, aimed at its middle.
			var mid := origin + Vector3(0.0, shape.height * 0.5, 0.0)
			var from := mid + Vector3(shape.radius * 4.0, 0.0, 0.0)
			var query := PhysicsRayQueryParameters3D.create(from, mid)
			query.exclude = [player.get_rid()]
			var hit := space.intersect_ray(query)
			# Any NPC's body counts: two NPCs stand within half a unit of
			# each other on Jangan's square, so a ray aimed at one is
			# legitimately stopped by the other.
			var stopped := false
			if not hit.is_empty():
				var collider: Object = hit["collider"]
				stopped = collider == body or (collider is Node
					and (collider as Node).get_parent() != null
					and (collider as Node).get_parent().name.begins_with("Npc_"))
			if stopped:
				blocked += 1
			print("QA NPCBODY %s: capsule r=%.2f h=%.2f -> %s" % [
				holder.name, shape.radius, shape.height,
				"blocks" if stopped else "ray passed through (hit %s)" % (
					str(hit.get("collider", "nothing")))])
	print("QA NPCBODY: %d of %d NPC(s) within %.0f units stop a ray" % [
		blocked, checked, QA_NPCBODY_RANGE])

func _npc_spawn_total() -> int:
	var n := 0
	for key in _npc_spawns_by_region:
		n += (_npc_spawns_by_region[key] as Array).size()
	return n

## Places every NPC that stands in one region, assembling each from its own
## .bsr the way the player's body is assembled.
##
## Height comes from the walkable graph rather than from npcpos.txt's own Y:
## that column is authored against the real client's terrain, and this
## project's terrain is rebuilt from the same heightmaps but anchored per
## region, so standing them on the graph is what actually puts their feet on
## this ground. The authored Y is kept as the fallback when a region has no
## graph.
func _try_spawn_region_npcs(region_x: int, region_y: int) -> void:
	if _npc_regions_done.has("%d_%d" % [region_x, region_y]):
		return
	_load_npc_tables()
	if _npc_spawns_by_region.is_empty():
		return
	var archive := _open_pk2_if_set()
	if archive == null:
		return
	var group := get_node_or_null("RealTerrain_%d_%d" % [region_x, region_y]) as Node3D
	if group == null:
		return
	_npc_regions_done["%d_%d" % [region_x, region_y]] = true

	var spawns: Array = _npc_spawns_by_region.get("%d_%d" % [region_x, region_y], [])
	if spawns.is_empty():
		return
	var placed := 0
	var skipped := 0
	var named := 0
	for spawn in spawns:
		var model: String = _npc_models.get(spawn.npc_id, "")
		if model == "":
			skipped += 1
			continue
		# Assemble a model once into a detached template, then duplicate it for
		# each NPC that uses it -- the repeat spawns skip the expensive .bsr
		# assembly and just copy a node (sharing its mesh/texture resources).
		var template: SkinnedBsrAssembler.AssembledCharacter = _npc_model_cache.get(model)
		if template == null:
			template = SkinnedBsrAssembler.assemble_from_archive(archive, model, true)
			if template == null:
				skipped += 1
				continue
			_npc_model_cache[model] = template
		var skeleton := template.skeleton.duplicate() as Skeleton3D
		if skeleton == null:
			skipped += 1
			continue
		var idle_anim: BanReader.ParsedAnimation = template.idle_animation
		var holder := Node3D.new()
		holder.name = "Npc_%d_%d" % [spawn.npc_id, placed]
		var local: Vector3 = spawn.local_position
		var height: float = local.y
		for pair in _region_nav_graphs:
			if pair[1] == group:
				# The authored Y is passed as the mover's height, not
				# discarded: height_at resolves several stacked walkable
				# surfaces by picking the one nearest the mover, and asking
				# from 0 puts anyone standing on a raised deck underneath it.
				# Jangan's octagonal plaza is a placed object, so every NPC
				# on the town square came out buried in it.
				height = (pair[0] as NavGraph).landing_height_at(local.x, local.z)
				break
		holder.position = Vector3(local.x, height, local.z)
		holder.add_child(skeleton)
		var bounds := _skeleton_bounds(skeleton)
		holder.add_child(_npc_collider(bounds))
		var npc_name: String = _npc_names.get(spawn.npc_id, "")
		# Tagged so a click on the collider can name the NPC it talks to
		# (see _try_talk_to_npc) -- the plate is a Label3D, no use for that.
		holder.set_meta("npc_id", spawn.npc_id)
		holder.set_meta("npc_name", npc_name if npc_name != "" else "")
		holder.set_meta("npc_code", _npc_codes.get(spawn.npc_id, ""))
		if npc_name != "":
			holder.add_child(_name_plate(npc_name, bounds.y))
			named += 1
		group.add_child(holder)
		_animate_skeleton(skeleton, idle_anim)
		placed += 1
	print("World3D: %d/%d NPC(s) placed in %d/%d (%d had no model, %d named)" % [
		placed, spawns.size(), region_x, region_y, skipped, named])

## Loads real terrain from a real Map.pk2 region .m file via MapmReader +
## MapmTerrainBuilder, replacing both the placeholder ground's visual mesh
## and its collision shape (see this file's top comment) -- if
## SRREVAMP_MAPM_PATH is set. Accepts either a loose file path or a path
## inside SRREVAMP_MAP_PK2_PATH (see AssetSource). Skips gracefully
## otherwise. path_override/texture_override let _reload_zone_assets pass
## real per-zone paths it resolved itself instead of reading the env vars --
## empty (the default) preserves the original env-var-only behavior for
## _ready()'s own call. world_offset/node_suffix/snap_player let
## _load_region_neighborhood place multiple of these side by side as a real
## multi-region grid instead of always the one env-var-driven region at the
## scene origin -- defaults preserve the original single-region behavior.
##
## shared_vertical_anchor (NAN by default) is the fix for a real bug found
## live (2026-08-22): without it, *every* tile independently forces its own
## near-row-middle vertex to world Y=0 (see the vertical-offset comment
## below), which guarantees a cliff at *every* seam between two tiles in the
## grid, since neighboring tiles' real height data has no known relationship
## to begin with -- confirmed live to trap the camera inside overlapping
## geometry. Passing the center tile's own near_height as every other
## tile's anchor instead means only the center tile still calibrates itself
## to Y=0; every neighbor renders at whatever height its own real data
## implies *relative to that one shared reference* rather than each also
## independently resetting to zero. This doesn't (and can't, without real
## cross-region alignment data this project doesn't have) make neighboring
## tiles seamlessly continuous -- real per-tile terrain remains genuinely
## steep on its own (confirmed live even for a single region, see
## MAPM_FORMAT.md) -- it just stops the grid from *compounding* that with a
## guaranteed reset at every single seam. Returns the near_height this call
## used (NAN on any failure path) so a caller building a grid can capture
## the center tile's value and pass it to every other cell.
func _try_load_real_terrain(path_override: String = "", texture_override: String = "", world_offset: Vector3 = Vector3.ZERO, node_suffix: String = "", snap_player: bool = true, shared_vertical_anchor: float = NAN, apply_environment_lighting: bool = true) -> float:
	var mapm_path := path_override if path_override != "" else OS.get_environment("SRREVAMP_MAPM_PATH")
	if mapm_path == "":
		print("World3D: SRREVAMP_MAPM_PATH not set -- ground stays a placeholder")
		return NAN

	var archive := _open_map_pk2_if_set()
	var bytes := AssetSource.read_bytes(mapm_path, archive)
	if bytes.is_empty():
		printerr("World3D: could not find terrain at ", mapm_path)
		return NAN

	var region := MapmReader.parse(bytes)
	if region == null:
		printerr("World3D: could not parse terrain at ", mapm_path)
		return NAN

	# Only the player's own (center) region drives the real sky color -- a
	# neighboring streamed-in region's own EnvironmentID (which hasn't been
	# confirmed to always match its neighbors') would otherwise overwrite it
	# with whichever cell happened to load last, unrelated to where the
	# player actually is. See _load_region_cell's call below.
	if apply_environment_lighting:
		_apply_real_environment_lighting(region, archive)

	# Real .t lightmap, loaded up front so it's available to whichever mesh
	# builder runs below -- see _load_real_terrain_lightmap's doc comment
	# and docs/protocol/MAPT_FORMAT.md. Corrects an earlier same-day
	# attempt that decoded the wrong bytes entirely (before .t's real
	# structure -- a ShadowMap plus a properly-headered embedded DDS --
	# was found via public documentation) and applied the result as direct
	# detail-albedo color, which looked like broken color-noise static and
	# was reverted. The real embedded texture is a genuine grayscale
	# shadow map (white = fully lit), which Godot's ao_texture consumes
	# directly with no custom shader needed.
	var lightmap := _load_real_terrain_lightmap(mapm_path, archive)
	var tile_table := _load_tile_index()

	# Real per-quad ground textures (2026-08-23) -- see
	# docs/protocol/DDJ_FORMAT.md and MapmTerrainBuilder's top comment for
	# the correction: these actually live in Map.pk2's real Tile2D\
	# folder, an archive/folder an earlier search never checked. Only
	# used if at least one of this region's real texture IDs actually
	# resolved to a real file -- otherwise the flat tile-type color
	# (build_full_region_mesh) is a strictly better fallback than a
	# multi-surface mesh where every single surface is the color fallback
	# anyway.
	var ground_textures := _load_real_ground_textures(region, tile_table)
	var textured := not ground_textures.is_empty()

	# Real, fully deterministic full-region assembly (2026-08-23) -- see
	# MapmTerrainBuilder.build_full_region_mesh's doc comment and
	# MAPM_FORMAT.md. MapmReader now parses a region's real, confirmed 6x6
	# block grid directly (no more row/column guessing), so this always
	# produces the complete real 97x97 mesh on a successful parse.
	var terrain_mesh: ArrayMesh
	if textured:
		# Real per-vertex terrain lighting, baked the way the real client does
		# (see MapmTerrainBuilder._lit_vertex_color). The light direction is
		# converted into the region's own local space, where the mesh is built:
		# a terrain group carries scale.z = -1 for the world mirror and no
		# rotation, so a world direction's Z simply flips.
		var light_dir := Vector3.ZERO
		if _env_light_ready and directional_light != null:
			var to_light := directional_light.global_transform.basis.z.normalized()
			light_dir = Vector3(to_light.x, to_light.y, -to_light.z)
		terrain_mesh = MapmTerrainBuilder.build_full_region_mesh_textured(
			region, ground_textures, lightmap, light_dir, _env_light_diffuse, _env_terrain_ambient,
			_last_terrain_shadow_map)
	else:
		terrain_mesh = MapmTerrainBuilder.build_full_region_mesh(region)
	if terrain_mesh == null:
		printerr("World3D: parsed ", region.blocks.size(), " real blocks from ", mapm_path, " but couldn't build a mesh from them")
		return NAN

	var terrain_group := Node3D.new()
	terrain_group.name = "RealTerrain" + node_suffix

	# Real per-quad textures (see above) already carry their own
	# per-surface materials (including the real .t lightmap) from
	# MapmTerrainBuilder -- material_override would apply one material to
	# every surface uniformly and stomp that, so it's left null and the
	# mesh's own per-surface materials show through. The single-flat-
	# material path below is unchanged for the untextured fallback.
	var aabb := terrain_mesh.get_aabb()
	var mat: StandardMaterial3D = null
	if not textured:
		mat = StandardMaterial3D.new()
		var real_texture := _load_real_terrain_texture(texture_override)
		var row_count_estimate := aabb.size.z / MapmTerrainBuilder.TILE_SIZE + 1
		if real_texture != null:
			mat.albedo_texture = real_texture
			# The mesh's own UVs (see MapmTerrainBuilder) stretch 0..1 across
			# the whole recovered strip, which can be dozens of real rows long
			# -- squishing one square minimap image over that whole length
			# reads as heavy streaking rather than ground detail. Repeating it
			# roughly once per GRID_WIDTH rows (a real, confirmed value -- see
			# MapmTerrainBuilder) keeps each repeat closer to the image's own
			# roughly-square real aspect ratio instead of one giant stretch.
			mat.uv1_scale = Vector3(1.0, max(row_count_estimate / float(MapmTerrainBuilder.GRID_WIDTH), 1.0), 1.0)
		else:
			mat.vertex_color_use_as_albedo = true
		if lightmap != null:
			mat.ao_enabled = true
			mat.ao_texture = lightmap
			mat.ao_light_affect = 1.0
	# Real world-space alignment with the player's own spawn position isn't
	# confirmed (see top comment) -- centered near the player purely for
	# visibility, same as the scenery/decoration-skeleton placement choices
	# elsewhere in this file. The vertical offset uses the real height of
	# the mesh's own first-row, middle-column vertex (the part of the mesh
	# that ends up nearest the player/camera once placed) rather than the
	# whole mesh's average -- terrain height varies enormously row to row,
	# so a global average can land nowhere near where the player actually
	# is; this keeps the offset tied to the specific real vertex the player
	# spawns next to.
	#
	# MapmTerrainBuilder lays successive rows out along local +Z, but this
	# scene's third-person camera looks down -Z (+Z is behind it -- see the
	# scenery-placement comment in _try_load_real_scenery()), so an
	# unrotated terrain mesh would extend almost entirely behind the
	# camera. Rotating 180 degrees around Y flips both axes consistently
	# (a pure rotation, so front-face winding/normals stay correct) so
	# successive rows extend further *into* view instead.
	# Read directly from the parsed region rather than the built mesh --
	# see near_row_middle_height's doc comment: the textured mesh path
	# above can split row 0 across several surfaces, so surface 0 alone
	# no longer reliably holds this vertex the way the old single-surface
	# mesh did.
	var near_height := MapmTerrainBuilder.near_row_middle_height(region)
	var anchor_height := near_height if is_nan(shared_vertical_anchor) else shared_vertical_anchor
	# **Corrected 2026-09-05** (see docs/WORLD_ISSUES.md): this was
	# `rotation.y = PI` plus an `aabb.size.x / 2.0` X offset, which placed
	# every real region *individually rotated 180 degrees* inside a grid
	# whose own offsets ran the other way. Each real region was internally
	# fine -- and objects (parented here) and navmesh walls inherited the
	# same transform, so everything agreed with everything else -- but the
	# regions were assembled against each other backwards, building a world
	# that is not a real place. Reported from a real playtest ("I have never
	# seen this place"), which self-consistency had hidden.
	#
	# The real world space is contiguous: crossing a region's local
	# x = 1920 edge continues at local x = 0 of region_y + 1 (the real
	# global edges' own AssocRegionIdTo says so, see NVM_FORMAT.md), so
	# real world X is `region_y * 1920 + local_x` and real world Z is
	# `region_x * 1920 + local_z`. Local coordinates therefore have to run
	# *forwards*, with no per-region rotation at all.
	#
	# Measured directly on the real heightmaps: a region's own high edge
	# matches its neighbour's low edge exactly (98/168's col 96 against
	# 98/169's col 0: mean difference 0.000000; the reversed pairing the old
	# transform produced: 18.2). Across a real 3x3 neighbourhood the mean
	# height step over every region seam falls from 34.28 to 2.40.
	#
	# The half-span shift keeps each real region *centred* on its own grid
	# offset, exactly as the old transform did on X, so _maybe_stream_regions'
	# own `round(rel / REGION_SPAN)` cell test still names the right cell.
	# **Un-mirrored 2026-09-05** (see docs/WORLD_ISSUES.md's sixty-first
	# round). The real client is Direct3D and left-handed; Godot is
	# right-handed. Feeding real coordinates straight through mirrors the
	# whole world, which is why `BmsReader` had to reverse every real
	# triangle's winding to stop objects rendering inside-out -- that made
	# faces visible again without addressing the cause. Proved with real
	# signage: the real Jangan restaurant carries 長安酒 on two
	# perpendicular *exterior* tower faces, and both rendered with 酒's
	# water radical on the wrong side until this mirror was applied.
	#
	# `scale.z = -1` alone would mirror each real region about its *own*
	# origin, which is the same per-region mistake the sixtieth round fixed.
	# Negating the group's world Z as well composes the two into a single
	# global `z -> -z` about the world origin, so every region stays in the
	# right place relative to its neighbours.
	#
	# Godot flips face culling itself for a negative-determinant transform
	# (verified: the real building renders solid, not inside-out, under this
	# mirror), so `BmsReader`'s existing winding reversal stays exactly as
	# it is and no mesh data needs rewriting.
	var placement := Vector3(
		-REGION_SPAN / 2.0, -anchor_height, -REGION_SPAN / 2.0) + world_offset
	terrain_group.position = Vector3(placement.x, placement.y, -placement.z)
	terrain_group.scale.z = -1.0
	add_child(terrain_group)
	ground_mesh.visible = false
	ground_collision.disabled = true

	# History, kept for context: an earlier same-day attempt tiled a single
	# parsed sub-patch's data across a synthetic 6x6 grid of *copies* to
	# fill a region's real footprint (see git history / PROGRESS.md), and
	# was reverted after live testing showed it made the camera-in-geometry
	# problem worse (a steep boundary every 320 units instead of every
	# 1920). That approach is now obsolete: terrain_mesh above is already
	# the real stitched multi-sub-patch mesh (build_full_region_mesh), not
	# one repeated patch, so there is exactly one real node to build here.
	var patch_body := StaticBody3D.new()
	patch_body.collision_layer = TERRAIN_COLLISION_LAYER
	var patch_shape := CollisionShape3D.new()
	patch_shape.shape = terrain_mesh.create_trimesh_shape()
	patch_body.add_child(patch_shape)
	var single_patch := MeshInstance3D.new()
	single_patch.name = "SubPatch"
	single_patch.mesh = terrain_mesh
	single_patch.material_override = mat
	single_patch.add_child(patch_body)
	terrain_group.add_child(single_patch)

	_try_add_navmesh_walls(terrain_group, mapm_path)
	_try_add_real_water(terrain_group, mapm_path)
	_build_region_nav_graph(terrain_group, mapm_path)

	# The vertical calibration above only guarantees one specific mesh vertex
	# lines up near world Y=0 -- it says nothing about the height of whatever
	# real terrain happens to sit under the player's actual server-given
	# spawn X/Z, which can be wildly different (see this function's own doc
	# comment on why real spawn/terrain alignment isn't confirmed yet). Left
	# alone, the player can end up embedded in or floating above the mesh.
	# Deferred one frame so the collision shape above is actually registered
	# with the physics server before the raycast below queries it. Only the
	# grid's center region (see _load_region_neighborhood) does this --
	# snapping onto every speculative neighbor as it loads would fight over
	# the player's position for no reason.
	if snap_player:
		call_deferred("_snap_player_onto_terrain")

	print("World3D: loaded real terrain from %s (%d real blocks, %d rows stitched, real collision shape built)" % [
		mapm_path, region.blocks.size(), terrain_mesh.get_aabb().size.z / MapmTerrainBuilder.TILE_SIZE + 1])
	return near_height

## Practical safety net for the real terrain-alignment gap noted where this
## is called: raycasts straight down (and up, to cover an embedded start)
## through the player's current X/Z and snaps them onto whatever real
## surface it hits, so movement always starts from solid, walkable ground
## regardless of how far off the terrain's heuristic placement is from the
## player's real spawn point. Not a fix for the underlying alignment
## question -- just keeps the game playable until that's reverse-engineered.
## Distance above the player's feet the buried-player probe in
## _recover_if_below_terrain starts from. One full region span, so the probe
## reaches any terrain plausibly overhead: real measured region meshes in the
## Jangan neighborhood span at most ~1350 units vertically end to end (see
## docs/WORLD_ISSUES.md), and a player buried by more than a whole region span
## is the WORLD_FLOOR_Y case, which the void-fall recovery already handles.
const BURIED_PROBE_HEIGHT := REGION_SPAN

## Lifts the player back onto the surface when they end up *underneath* the
## terrain rather than on top of it.
##
## Measured 2026-09-03: the initial _snap_player_onto_terrain runs once, while
## the 5x5 region neighborhood is still streaming in, so it can only snap the
## player onto whichever regions happen to have finished loading. Instrumenting
## a real headless run of the real Jangan spawn region (98/168) showed the
## player at y=0.00 on physics frame 0 with the terrain surface beneath them at
## y=1.04 -- i.e. a metre *below* the map -- with 25 region nodes loaded; by
## frame 1, with 30 loaded, the snap had put them at y=64.70. Walking from a
## spawn during that same streaming window measured the player 41 units below
## the terrain surface. Nothing re-checked the player's placement once the
## remaining regions arrived, so a player who was under a region's terrain when
## it streamed in simply stayed under it, seeing the world from below (where
## back-face culling makes the ground invisible and the sky shows straight
## through it).
##
## The existing ground/void check above cannot catch this: its probe starts
## only 10 units above the player, below a 14.34-unit character's own head, so
## terrain overhead is out of its reach entirely.
##
## Safe to apply unconditionally because real .m terrain is a heightmap -- one
## height per grid vertex (see MapmReader) -- so it cannot overhang itself, and
## any terrain strictly above the player's feet therefore means the feet are
## below the surface. Terrain-only (see TERRAIN_ONLY_COLLISION_MASK) keeps real
## objects the player can legitimately stand under -- bridges, building
## interiors, arches -- from being mistaken for ground overhead.
func _recover_if_below_terrain() -> void:
	var feet := player.position
	var query := PhysicsRayQueryParameters3D.create(
		feet + Vector3(0.0, BURIED_PROBE_HEIGHT, 0.0), feet)
	query.exclude = [player.get_rid()]
	query.collision_mask = TERRAIN_ONLY_COLLISION_MASK
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	# A player standing correctly *on* the ground still registers a hit here,
	# at their own feet -- only a hit meaningfully above them means buried.
	var surface_y: float = hit.position.y
	if surface_y <= feet.y + BURIED_EPSILON * PLAYER_SCALE_RATIO:
		return
	player.position.y = surface_y + 0.05 * PLAYER_SCALE_RATIO
	player.velocity.y = 0.0

## Slack, in unscaled (1.8-unit-tall-character) units, allowed between the
## player's feet and terrain found overhead before they count as buried --
## absorbs the ordinary sub-unit jitter of resting on a collision surface.
const BURIED_EPSILON := 0.25

func _snap_player_onto_terrain() -> void:
	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		player.position + Vector3(0.0, 1000.0, 0.0),
		player.position + Vector3(0.0, -1000.0, 0.0))
	query.exclude = [player.get_rid()]
	# Terrain-only (see TERRAIN_ONLY_COLLISION_MASK's doc comment) -- without
	# this, a real building standing at the spawn X/Z (its collision defaults
	# to the same layer terrain used to) is whatever this ray hits first from
	# 1000 units up, landing the player on its roof instead of the ground.
	query.collision_mask = TERRAIN_ONLY_COLLISION_MASK
	var hit := space_state.intersect_ray(query)
	if hit.is_empty():
		return
	var surface: float = hit.position.y + 0.05 * PLAYER_SCALE_RATIO
	# **Lift only.** This is a safety net for a player the region stream
	# buried, which is what it was written for -- but because it looks at
	# terrain alone, dropping the player to whatever it finds also pulls
	# them off anything they are legitimately standing *on*.
	#
	# Measured in Jangan: a zone change places the player correctly on the
	# gate's deck at local y -32.6, and this snap -- running deferred as the
	# centre region finishes loading -- then dragged them down to the bare
	# terrain 13.8 below, inside the gate's own stonework. Every "the player
	# sinks into the town square" render was this line.
	#
	# Lifting still does its job; dropping never was its job.
	if surface <= player.position.y:
		return
	player.position.y = surface
	player.velocity = Vector3.ZERO
	_avoid_spawning_under_roof()

## Real, general safety net (2026-08-26, see docs/WORLD_ISSUES.md): a real
## fixed server spawnPos of (0,0,0) can genuinely land inside a real
## building's interior in a densely-built real zone (confirmed for Jangan's
## own real region, 863 real placements in one region) -- this isn't
## something a fixed spawn coordinate can reliably avoid on its own, since
## "the most open point" in a real palace complex still isn't very open.
## Rather than try to precompute a real building-free spawn point (would
## need real per-object footprint data this project doesn't have, not just
## placement anchors), this checks *after* landing on real terrain whether
## there's a real low ceiling directly overhead (a real room, not open sky)
## and, if so, tries nearby real ground positions in a widening ring until
## one has clear sky above, snapping there instead. Bounded and best-effort:
## if every tried position is still covered, leaves the player at the
## original terrain-snapped position rather than searching forever.
## **Corrected 2026-08-26** (see docs/WORLD_ISSUES.md): a real playtest
## found the original 30.0 never triggered the escape search at all --
## real placed objects render at their own native scale (unlike the
## player's own body, deliberately rescaled to a fixed 1.8-unit height in
## _build_assembled_character), and a direct check of real Jangan-region
## meshes found real building pieces up to ~44.5 real units tall
## (`jangan03\cj_pal_dam_left02.bsr`) and real trees up to ~140 -- 30.0
## couldn't even clear a single real wall piece, let alone a real room.
## Raised with real margin above the tallest real piece measured.
const ROOF_CHECK_HEIGHT := 200.0
## Also raised in proportion -- a real building tall enough to need the
## new ROOF_CHECK_HEIGHT plausibly has a footprint on a similar real
## scale, not the old, much smaller assumption.
const ROOF_ESCAPE_STEP := 60.0
const ROOF_ESCAPE_RINGS := 10
const ROOF_ESCAPE_DIRECTIONS := 8

func _avoid_spawning_under_roof() -> void:
	if not _has_roof_overhead(player.position):
		return
	var space_state := get_world_3d().direct_space_state
	for ring in range(1, ROOF_ESCAPE_RINGS + 1):
		var radius := ring * ROOF_ESCAPE_STEP
		for i in range(ROOF_ESCAPE_DIRECTIONS):
			var angle := TAU * i / ROOF_ESCAPE_DIRECTIONS
			var candidate_xz := player.position + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
			var query := PhysicsRayQueryParameters3D.create(
				candidate_xz + Vector3(0.0, 1000.0, 0.0),
				candidate_xz + Vector3(0.0, -1000.0, 0.0))
			query.exclude = [player.get_rid()]
			# Terrain-only (see TERRAIN_ONLY_COLLISION_MASK's doc comment) --
			# without this, a candidate ring position could land on a
			# *different* real building's roof, which also has clear sky
			# above it, so _has_roof_overhead(candidate) below would wrongly
			# accept it as "escaped" -- moved off one roof, onto another.
			query.collision_mask = TERRAIN_ONLY_COLLISION_MASK
			var hit := space_state.intersect_ray(query)
			if hit.is_empty():
				continue
			var candidate: Vector3 = hit.position + Vector3(0.0, 0.05 * PLAYER_SCALE_RATIO, 0.0)
			if not _has_roof_overhead(candidate):
				player.position = candidate
				player.velocity = Vector3.ZERO
				return
	# Every tried ring was still covered -- a real, honest "couldn't find
	# open ground nearby" outcome (e.g. deep inside a real dense palace
	# complex), not silently pretending success.
	printerr("World3D: spawn point has a real roof overhead and no nearby open ground was found within %d real units -- leaving the player here" % (ROOF_ESCAPE_RINGS * ROOF_ESCAPE_STEP))

## True if a real raycast straight up from pos hits something within
## ROOF_CHECK_HEIGHT real units -- a real low ceiling/roof, not open sky.
func _has_roof_overhead(pos: Vector3) -> bool:
	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		pos + Vector3(0.0, 0.5 * PLAYER_SCALE_RATIO, 0.0),
		pos + Vector3(0.0, ROOF_CHECK_HEIGHT, 0.0))
	query.exclude = [player.get_rid()]
	var hit := space_state.intersect_ray(query)
	return not hit.is_empty()

## Reads, once, everything dressing needs and nothing it does not:
## Data.pk2 stays open, each gender's body row is looked up in
## characterdata by code name and its animations parsed, and the item
## table is read for id -> worn model. Leaves _character_assets empty if
## SRREVAMP_PK2_PATH isn't set at all, and a gender whose row is missing
## simply gets no entry.
func _load_character_assets() -> void:
	_data_pk2 = _open_pk2_if_set()
	if _data_pk2 == null:
		print("World3D: SRREVAMP_PK2_PATH not set -- characters stay placeholders")
		return
	if _media_pk2 == null:
		_media_pk2 = _open_media_pk2_if_set()
	if _media_pk2 == null:
		print("World3D: no Media.pk2 -- no character or item tables, characters stay placeholders")
		return

	var bodies := {}
	for path in NpcTableReader.MODEL_TABLE_PATHS:
		var entry := ObjectLoader.find_file(_media_pk2, path)
		if entry != null:
			bodies = NpcTableReader.parse_models_by_code(_media_pk2.read_file(entry), bodies)
	for path in ItemTableReader.TABLE_PATHS:
		var entry := ObjectLoader.find_file(_media_pk2, path)
		if entry == null:
			continue
		for item in ItemTableReader.parse(_media_pk2.read_file(entry)).values():
			if item.model_path != "":
				_item_models[item.id] = item.model_path
				if item.type_ids.size() >= 4:
					_item_kinds[item.id] = item.type_ids[3]

	for gender in GENDER_BODY_CODE:
		var code: String = GENDER_BODY_CODE[gender]
		var bsr_path: String = bodies.get(code, "")
		if bsr_path == "":
			printerr("World3D: characterdata has no %s row for the %s body" % [code, gender])
			continue
		var bsr_data := AssetSource.read_bytes(bsr_path, _data_pk2)
		if bsr_data.is_empty():
			bsr_data = AssetSource.read_bytes("res\\" + bsr_path, _data_pk2)
		var parsed := BsrReader.parse(bsr_data) if not bsr_data.is_empty() else null
		if parsed == null or not parsed.is_character:
			printerr("World3D: %s body %s is not a character .bsr" % [gender, bsr_path])
			continue
		var assets := {
			"bsr_path": bsr_path,
			"parsed": parsed,
			"animations": {},
		}
		_character_assets[gender] = assets
		var groups: Array = parsed.animation_groups.keys()
		print("World3D: %s body is %s (%d pieces, %d animations, groups %s)" % [
			gender, bsr_path, parsed.all_mesh_paths().size(), parsed.animation_paths.size(), str(groups)])
	print("World3D: %d item model(s) known from the item table" % _item_models.size())

## The animation a gender's body plays for one action, in the animation
## group a held weapon selects -- the file's own table, with its own
## fallback to `default` (see BsrReader.ParsedObject.animation_for). Parsed
## on first use and cached per gender. Null when the body has no animation
## for it, which the caller treats as "hold the pose".
##
## A body whose `.bsr` carries no groups at all falls back to matching the
## animation file names against BODY_ANIMATION_HINTS.
func _body_animation_for(gender: String, action_type: int, group: String = "default") -> BanReader.ParsedAnimation:
	var assets: Dictionary = _character_assets.get(gender, _character_assets.get(DEFAULT_GENDER, {}))
	if assets.is_empty():
		return null
	var parsed: BsrReader.ParsedObject = assets["parsed"]
	var path := parsed.animation_for(action_type, group)
	if path == "" and parsed.animation_groups.is_empty():
		path = _hinted_animation_path(parsed.animation_paths, action_type)
	if path == "":
		return null
	var cache: Dictionary = assets["animations"]
	if cache.has(path):
		return cache[path]
	var bytes := AssetSource.read_bytes(path, _data_pk2)
	if bytes.is_empty():
		bytes = AssetSource.read_bytes("res\\" + path, _data_pk2)
	var anim: BanReader.ParsedAnimation = BanReader.parse(bytes) if not bytes.is_empty() else null
	if anim != null and anim.bones.is_empty():
		anim = null
	cache[path] = anim
	return anim

## The name-hint fallback: the first animation path matching the earliest
## hint for an action, or "".
func _hinted_animation_path(paths: Array, action_type: int) -> String:
	var key := ""
	match action_type:
		BsrReader.AnimationEntry.TYPE_STAND:
			key = "idle_anim"
		BsrReader.AnimationEntry.TYPE_WALK:
			key = "walk_anim"
		BsrReader.AnimationEntry.TYPE_RUN:
			key = "run_anim"
		BsrReader.AnimationEntry.TYPE_HIT:
			key = "hit_anim"
		BsrReader.AnimationEntry.TYPE_DIE:
			key = "death_anim"
	if key == "":
		return ""
	for hint in BODY_ANIMATION_HINTS[key]:
		for path in paths:
			var lower := (path as String).to_lower()
			if lower.ends_with(hint) or lower.contains(hint):
				return path
	return ""

## The animation group the weapon in a set of equipped items selects.
func _weapon_group_for(equipped: Dictionary) -> String:
	var weapon_id: int = int(equipped.get(EquipmentNet.SLOT_WEAPON, 0))
	if weapon_id == 0:
		return "default"
	return WEAPON_ANIMATION_GROUP.get(int(_item_kinds.get(weapon_id, 0)), "default")

## Builds one fresh character: the gender's body assembled from its own
## `.bsr` with real skinning, then every worn item hung on it the way its
## own `.bsr` says (see SkinnedBsrAssembler.attach_item_from_archive).
##
## `equipped` is slot -> item id, straight from the server. Each id is
## looked up in the item table for the model it is worn as, so the
## character wears exactly what the server says it does -- the Cotton Suit
## when the server says 4842, not a suit of this client's choosing. An id
## the table does not know is skipped with a line in the log, and the
## character is drawn without it rather than with a stand-in.
##
## Falls back to DEFAULT_GENDER if gender's assets never loaded (or gender
## is empty/unrecognized -- an older peer, or an EnterWorldResult without
## one). Returns null only if even the default's body could not be built.
func _build_assembled_character(equipped: Dictionary = {}, gender: String = DEFAULT_GENDER) -> Skeleton3D:
	var assets: Dictionary = _character_assets.get(gender, _character_assets.get(DEFAULT_GENDER, {}))
	if assets.is_empty() or _data_pk2 == null:
		return null
	var assembled := SkinnedBsrAssembler.assemble_from_archive(_data_pk2, assets["bsr_path"], false)
	if assembled == null:
		return null
	var worn := 0
	for slot in equipped:
		var item_id: int = int(equipped[slot])
		if item_id == 0:
			continue
		var model: String = _item_models.get(item_id, "")
		if model == "":
			print("World3D: item %d in slot %d has no worn model in the item table -- not drawn" % [item_id, slot])
			continue
		var attached := SkinnedBsrAssembler.attach_item_from_archive(_data_pk2, assembled.skeleton, model)
		if attached != null:
			worn += 1
	if not equipped.is_empty():
		print("World3D: %s wears %d/%d item(s)" % [gender, worn, equipped.size()])
	return assembled.skeleton

## Attaches a freshly-built assembled character (see
## _build_assembled_character()) to the player node, hiding the
## placeholder capsule -- if the shared character assets loaded. Leaves
## the placeholder capsule visible otherwise.
##
## What the character wears is the server's word: the equipment list
## (EquipmentNet/OP_LIST via NetClient.list_equipment) says which item is
## in which slot, and each is drawn from its own model. A newly-created
## character wears the starting kit the server gave it.
func _try_apply_real_player_character() -> void:
	var equipped := await _real_player_equipped_items()
	_player_equipped_last = equipped
	var gender := DEFAULT_GENDER
	if NetClient.last_enter_world_result != null and NetClient.last_enter_world_result.gender != "":
		gender = NetClient.last_enter_world_result.gender

	# Worth a log line: "the character renders bare" has had two different
	# causes so far -- the server not dressing them, and the client not
	# asking -- and this says which side to look at.
	print("World3D: player equipment %s" % str(equipped))

	var skeleton := _build_assembled_character(equipped, gender)
	if skeleton == null:
		return
	# The assembled body's visual front is its own local -Z, but the player
	# node points its local +Z at the movement/target direction (rotation.y =
	# atan2(dir.x, dir.z)). Without correcting for that the body faced away
	# from wherever it was walking -- the "runs backwards on click" playtest
	# bug. Turning the body 180deg aligns its front with the node's forward,
	# so every facing (movement, click, combat) now points the right way.
	skeleton.rotation.y = PI
	player.add_child(skeleton)
	player_mesh.visible = false
	_player_skeleton = skeleton
	_player_gender = gender
	_player_weapon_group = _weapon_group_for(equipped)
	print("World3D: player animation group %s (stand %s, run %s)" % [
		_player_weapon_group,
		_body_animation_path(gender, BsrReader.AnimationEntry.TYPE_STAND, _player_weapon_group),
		_body_animation_path(gender, BsrReader.AnimationEntry.TYPE_RUN, _player_weapon_group)])
	_refresh_paper_doll(equipped, gender)

## Builds a fresh dressed character (a second copy, not the one on the
## player) into the PaperDoll so the equipment window can show it, the way
## the original renders the character in that window. Rebuilt whenever the
## equipment changes.
var _paper_doll: PaperDoll = null

func _refresh_paper_doll(equipped: Dictionary, gender: String) -> void:
	if _hud_panels == null:
		return
	if _paper_doll == null:
		_paper_doll = PaperDoll.new()
		_paper_doll.name = "PaperDoll"
		add_child(_paper_doll)
	var doll_skeleton := _build_assembled_character(equipped, gender)
	if doll_skeleton == null:
		return
	_paper_doll.set_character(doll_skeleton)
	# The doll breathes in the town idle, the same animation and the same
	# clock the body in the world runs on: registered in _animated, it is
	# posed every physics frame by _tick_idle_animations, and the doll's
	# SubViewport (UPDATE_ALWAYS) shows it. A stale entry from a previous
	# equipment change is dropped there when its skeleton is freed.
	var idle := _body_animation_for(gender, BsrReader.AnimationEntry.TYPE_STAND, _weapon_group_for(equipped))
	if idle != null and _frame_count(idle) > 1:
		Skeleton3DBuilder.apply_ban_pose_at(doll_skeleton, idle, 0.0, true)
		_animated.append([doll_skeleton, idle, _frame_count(idle), 0.0, true, _idle_anim_time, null])
	_hud_panels.set_paper_doll_texture(_paper_doll.get_texture())

## Switches another player's looping animation between stand and run as
## their body starts and stops moving. The entry keeps its phase so a
## crowd stays out of step.
func _set_other_gait(character_id: int, moving: bool) -> void:
	var gait: Dictionary = _other_gaits.get(character_id, {})
	if gait.is_empty() or bool(gait["moving"]) == moving:
		return
	gait["moving"] = moving
	var action := BsrReader.AnimationEntry.TYPE_RUN if moving else BsrReader.AnimationEntry.TYPE_STAND
	var anim := _body_animation_for(gait["gender"], action, gait["group"])
	var frames := _frame_count(anim)
	if frames <= 1:
		return
	var skeleton: Skeleton3D = gait["skeleton"]
	for entry in _animated:
		if entry[0] == skeleton and entry[4]:
			entry[1] = anim
			entry[2] = frames
			return
	_animated.append([skeleton, anim, frames, float(_animated.size()) * 0.37, true, _idle_anim_time, null])

## Plays anim once on the player's body, over stand or run, and returns
## how long it runs.
func _play_player_once(anim: BanReader.ParsedAnimation) -> float:
	var frames := _frame_count(anim)
	if frames <= 1:
		return 0.0
	_player_one_shot = anim
	_player_one_shot_start = _player_anim_time
	return anim.duration_seconds()

## Plays a skill's cast animation as a one-shot. The clip is named after the
## skill's Basic_Code (anim_base, e.g. "skill_ch_sword_smash_a") and lives at
## Prim\Ani\Char\China\<man|woman>\<anim_base>.ban in Data.pk2 -- a grounded
## name-based mapping (see the skill-animations note). Returns the clip length
## in seconds, or 0 if it could not be found/parsed (caller falls back).
func _play_skill_cast_anim(anim_base: String) -> float:
	if anim_base == "" or _data_pk2 == null or _player_skeleton == null:
		return 0.0
	var gender_dir := "woman" if _player_gender == "china_woman" else "man"
	var path := "Prim\\Ani\\Char\\China\\%s\\%s.ban" % [gender_dir, anim_base]
	var bytes := AssetSource.read_bytes(path, _data_pk2)
	if bytes.is_empty():
		print("World3D: no cast animation at %s" % path)
		return 0.0
	var anim := BanReader.parse(bytes)
	if anim == null or anim.bones.is_empty():
		print("World3D: could not parse cast animation %s" % path)
		return 0.0
	return _play_player_once(anim)

## A learned skill in the window was clicked: assign it to the next free
## underbar quickslot (its icon shown there). Activating that quickslot is what
## casts it -- the authentic Silkroad flow (the window never casts directly).
func _on_skill_assign_requested(skill_id: int, basic_code: String, icon: Texture2D) -> void:
	for slot in range(HudUnderbar.SLOTS_PER_PAGE):
		if not _quickslot_skills.has(slot):
			_quickslot_skills[slot] = {"id": skill_id, "code": basic_code}
			_hud_underbar.set_slot_item(slot, icon)
			_log_system("Assigned skill to quickslot %d -- click it (or its key) to cast." % (slot + 1))
			return
	_log_system("Quickslots are full.")

## A quickslot was activated (clicked): cast the skill assigned to it.
func _on_quickslot_activated(slot_index: int) -> void:
	var entry = _quickslot_skills.get(slot_index)
	if entry != null:
		_cast_skill(int(entry["id"]), String(entry["code"]))

## Casts a skill: plays its real cast animation (from basic_code) and sends the
## use-skill request against the current target. The animation plays regardless
## (the swing is visible even with no target); the server applies the skill's
## real cooldown and, for now, plain-attack damage.
func _cast_skill(skill_id: int, basic_code: String) -> void:
	# basic_code carries the level suffix; derive the clip name the same way the
	# reader's BaseSkill.cast_anim_name does (lowercase, drop trailing _NN).
	var anim_base := basic_code.to_lower()
	var us := anim_base.rfind("_")
	if us > 0 and anim_base.substr(us + 1).is_valid_int():
		anim_base = anim_base.substr(0, us)
	_last_combat_time = _player_anim_time
	_play_skill_cast_anim(anim_base)
	if _last_attack_target != -1:
		_show_target(_last_attack_target)
		_pending_skill_hit_code = basic_code
		NetClient.use_skill(NetClient.current_character_name, skill_id, _last_attack_target)

## The group entry behind _body_animation_for, for its events.
func _body_animation_entry(gender: String, action_type: int, group: String) -> BsrReader.AnimationEntry:
	var assets: Dictionary = _character_assets.get(gender, _character_assets.get(DEFAULT_GENDER, {}))
	if assets.is_empty():
		return null
	return (assets["parsed"] as BsrReader.ParsedObject).animation_entry_for(action_type, group)

## The path _body_animation_for would parse, for a log line.
func _body_animation_path(gender: String, action_type: int, group: String) -> String:
	var assets: Dictionary = _character_assets.get(gender, _character_assets.get(DEFAULT_GENDER, {}))
	if assets.is_empty():
		return ""
	return (assets["parsed"] as BsrReader.ParsedObject).animation_for(action_type, group).get_file()

## Queries the real server for the local player's equipped items (the same
## EquipmentNet protocol the equipment HUD uses) and reports them as
## slot -> item id. Returns nothing without querying if there's no live
## server connection -- the standalone dev-tool/screenshot contexts used
## throughout this project's asset work, which load World3D.tscn directly
## with SRREVAMP_* env vars set but no real login/enter-world flow, so a
## query would otherwise await a signal that can never fire.
func _real_player_equipped_items() -> Dictionary:
	if not NetClient.is_connected_to_server() or NetClient.current_character_name == "":
		return {}
	NetClient.list_equipment(NetClient.current_character_name)
	var answer: Array = await NetClient.equipment_result
	var items: Array = answer[0]
	print("World3D: server reports %d equipped item(s) for %s (error: %s)" % [
		items.size(), NetClient.current_character_name, str(answer[1])])
	var equipped := {}
	for item in items:
		equipped[item.slot] = item.item_id
	return equipped

## Loads a real Map.pk2 region's real object placements (SRREVAMP_MAPO_PATH,
## e.g. "0\\0.o", via SRREVAMP_MAP_PK2_PATH -- same archive as
## SRREVAMP_MAPM_PATH) and renders up to MAX_MAP_OBJECTS of them with their
## real resolved .bsr models, via a real type-ID lookup
## (OBJECT_INDEX_PATH, from SRREVAMP_PK2_PATH's Data.pk2) -- see
## docs/protocol/MAPO_FORMAT.md for how this real mapping was found (it was
## a confirmed dead end earlier in this project). Skips gracefully if
## either env var is unset, or if a specific placement's type ID isn't in
## the index (real, expected -- not every real object type is necessarily
## resolvable, and this project doesn't try to hide that by falling back
## to a placeholder marker here). path_override lets _reload_zone_assets
## pass a real per-zone path it resolved itself instead of reading
## SRREVAMP_MAPO_PATH -- empty (the default) preserves the original
## env-var-only behavior for _ready()'s own call. world_offset/node_suffix
## let _load_region_neighborhood place multiple of these side by side --
## defaults preserve the original single-region behavior. Also tries the
## same region's real .o2 file (mapo_path + "2") and merges its real
## placements in, if present -- .o2 only exists for newer-generation
## ("Shape B") regions alongside .o (see docs/protocol/MAPO2_FORMAT.md and
## MAPM_FORMAT.md's Shape A/B split), so a missing .o2 is the normal,
## expected case for Shape A regions, not an error.
func _try_load_real_map_objects(path_override: String = "", world_offset: Vector3 = Vector3.ZERO, node_suffix: String = "") -> void:
	var mapo_path := path_override if path_override != "" else OS.get_environment("SRREVAMP_MAPO_PATH")
	if mapo_path == "":
		print("World3D: SRREVAMP_MAPO_PATH not set -- no real map objects loaded")
		return

	var map_archive := _open_map_pk2_if_set()
	var mapo_bytes := AssetSource.read_bytes(mapo_path, map_archive)
	if mapo_bytes.is_empty():
		printerr("World3D: could not find map objects at ", mapo_path)
		return
	var region := MapoReader.parse(mapo_bytes)
	if region == null:
		printerr("World3D: could not parse map objects at ", mapo_path)
		return

	# Real .o2 placements are collected the same way as .o's: same type ID
	# + world position shape (see docs/protocol/MAPO2_FORMAT.md), just
	# indexed into a real 6x6 sector grid of 3 lists each rather than one
	# flat resync-scanned list. .o2 only exists for newer-generation
	# ("Shape B") regions -- see docs/protocol/MAPM_FORMAT.md's Shape A/B
	# split -- so a missing .o2 here (Shape A, or no real objects/sectors
	# unpopulated) is the normal, expected case, not an error.
	var placements: Array = []
	for obj in region.objects:
		placements.append({"type_id": obj.type_id, "position": obj.position, "rotation": obj.rotation})
	var mapo2_path := mapo_path + "2"
	var mapo2_bytes := AssetSource.read_bytes(mapo2_path, map_archive)
	var o2_count := 0
	if not mapo2_bytes.is_empty():
		var region2 := MapO2Reader.parse(mapo2_bytes)
		if region2 != null:
			# Only the third of each sector's three stored lists is treated
			# as this region's own objects.
			#
			# A real playtest found the town's gateway arches bricked up.
			# The arches are real -- reading `cj_s_wall01.bms`'s own
			# triangles and firing a ray through the wall at head height
			# finds three clear openings, exactly where the gate's arches
			# are -- but five different real regions (96/167, 96/168,
			# 97/167, 97/168, 97/169) each place that same real
			# `cj_s.bsr` at the *identical* local position
			# (860.64, -1.76, 1764.43). Since each region's objects are
			# placed relative to that region, this drew five copies of a
			# 5,559-unit-long city wall at five different world positions,
			# and a neighbour's solid section landed across this region's
			# archways.
			#
			# The three lists are not interchangeable, and which one an
			# entry sits in is the signal that separates a region's own
			# objects from these cross-references. A real `.o2` files its
			# entries into a 6x6 sector grid, so an entry's position
			# implies which sector it should be in -- and measured across
			# real regions, **list 2's entries are in their implied sector
			# about 91% of the time against list 1's 46%** (real 97/168:
			# 145/159 vs 129/273; real 98/168: 106/116 vs 180/390). List 2
			# is where a region's own objects live; the others are
			# references to objects that belong somewhere else. That is
			# also exactly how the gate falls out: 97/168, the region the
			# arches actually line up with, is the only one of the five
			# that lists it in list 2.
			#
			# What this gives up: the entries only lists 0/1 carry and the
			# region's own `.o` does not repeat -- 22 in real 97/168, 47
			# in real 98/168, nearly all edge vegetation, which is the
			# same cross-reference pattern in miniature. Drawing a
			# neighbour's tree in the wrong place is the same bug as
			# drawing its wall in the wrong place.
			for sector in region2.sectors:
				if sector.lists.size() < 3:
					continue
				for entry in sector.lists[2]:
					# Real yaw rotation -- see MapO2Reader.Entry.rotation's
					# doc comment for how this was confirmed (same
					# real-range empirical check as .o's own rotation
					# field, against a live region).
					placements.append({
						"type_id": entry.type_id, "position": entry.position,
						"rotation": entry.rotation, "from_o2": true})
					o2_count += 1

	# **De-duplicated 2026-09-07** (see docs/WORLD_ISSUES.md's seventy-fifth
	# round). A real `.o2` is organised into *sectors*, and a real object
	# overlapping more than one sector is listed **in each of them**. Reading
	# every sector and appending them all therefore places big structures --
	# real gates, real walls, real grass groups -- several times over.
	#
	# Measured on real Jangan: real `98\168.o2` holds 506 entries of which 456
	# exactly repeat (position and yaw to 4dp) one of the real 273 entries in
	# its own `.o`, so the same object is listed up to several times; real
	# `97\168.o2` repeats a real `cj_jang_gate` 24 times. A real playtest saw
	# exactly that: far more gates along the walls than the real city has, and
	# a wall standing a little past a gate the player had just walked through.
	#
	# Both files genuinely carry unique placements too (a real `97\168.o` has
	# 128 entries absent from its `.o2`), so neither can simply be dropped in
	# favour of the other -- they are merged, and exact repeats removed.
	var deduped: Array = []
	var seen_placements := {}
	for p in placements:
		var pos: Vector3 = p["position"]
		var k := "%d@%.4f,%.4f,%.4f,%.5f" % [p["type_id"], pos.x, pos.y, pos.z, p["rotation"]]
		if seen_placements.has(k):
			continue
		seen_placements[k] = true
		deduped.append(p)
	var dropped := placements.size() - deduped.size()
	if dropped > 0:
		print("World3D: %s -- dropped %d duplicate real placements (%d -> %d)" % [
			mapo_path, dropped, placements.size(), deduped.size()])
	placements = _placements_belonging_here(deduped, mapo_path)

	if placements.is_empty():
		printerr("World3D: no real objects parsed from ", mapo_path)
		return

	var data_archive := _open_pk2_if_set()
	if data_archive == null:
		printerr("World3D: SRREVAMP_PK2_PATH not set -- can't resolve real object type IDs")
		return
	var table := _load_object_index()
	if table == null:
		return

	var container := Node3D.new()
	container.name = "RealMapObjects" + node_suffix

	# Real world-space alignment: SOLVED (2026-08-24) via a real, public,
	# non-reverse-engineered source -- JellyBitz's xSROMap
	# (https://github.com/JellyBitz/xSROMap), whose own real coordinate-
	# conversion JS confirms a region's local coordinates span exactly
	# [0, 1920) and a region ID packs as `(ySector << 8) | xSector` --
	# exactly the real REGION_SPAN (1920.0) and region-folder-name
	# convention ("98\168.m" = xSector 98, ySector 168) this project's own
	# region-streaming grid already uses for real terrain, confirming that
	# grid's math is really correct, not just internally consistent. So a
	# `.o` object's raw position is already real, absolute-within-its-
	# region data needing no artificial recentering -- it only needs the
	# exact same offset transform `_try_load_real_terrain` already
	# applies to that region's terrain (the half-REGION_SPAN centring
	# offset, and no rotation -- see its own **Corrected 2026-09-05**
	# comment for why there used to be one), so parenting this container
	# under that exact terrain node (found by its real, shared node-name
	# convention) inherits that transform automatically instead of
	# duplicating it. Falls back to the old world_offset-only placement if
	# that terrain node isn't loaded (e.g. a real `.o` with no matching
	# `.m`, or this function's own standalone/env-var call path where no
	# node_suffix was given) -- better than dropping the objects entirely.
	var terrain_node := get_node_or_null("RealTerrain" + node_suffix) if node_suffix != "" else null
	if terrain_node != null:
		terrain_node.add_child(container)
	else:
		container.position = world_offset
		add_child(container)

	var loaded := 0
	var skipped_unresolved := 0
	# A real region repeats the same handful of real object types across
	# dozens/hundreds of placements (see docs/PROGRESS.md -- a real 58-
	# object region had only 4 distinct types) -- load each distinct real
	# .bsr once and duplicate the built node for repeat placements, rather
	# than re-parsing the same real .bms/.bmt/.ddj chain per placement.
	var templates := {} # resolved .bsr path -> loaded template Node3D
	for placement in placements:
		if loaded >= MAX_MAP_OBJECTS:
			break
		var entry := table.lookup(placement["type_id"])
		if entry == null:
			skipped_unresolved += 1
			continue

		var node: Node3D
		if templates.has(entry.path):
			node = templates[entry.path].duplicate()
		else:
			var template := ObjectLoader.load_object(data_archive, entry.path)
			if template == null:
				continue
			templates[entry.path] = template
			node = template.duplicate()
		# Real, absolute-within-its-region position -- see this function's
		# own doc comment above (container placement) for how this is now
		# known correct rather than an artificial recentering.
		node.position = placement["position"]
		# Real yaw rotation -- see MapoReader.ObjectPlacement.rotation's doc
		# comment for how this was confirmed (decompiled cos/sin construction
		# plus a 100%-real-range empirical check against a live region).
		node.rotation.y = placement["rotation"]
		# Named after the real model it came from, so that a node in the
		# scene tree says *which* real object it is. Without this every
		# placed object was an anonymous Node3D and the only way to work
		# out what a piece of geometry in front of the camera was, was to
		# match it against placement coordinates by hand -- see
		# _qa_look_report, which reads these names straight back.
		node.name = "Obj_%s_%d" % [entry.path.get_file().get_basename(), loaded]
		container.add_child(node)
		loaded += 1

	print("World3D: loaded %d/%d real map objects from %s (%d real .o + %d real .o2, %d unresolved type IDs skipped, %d distinct real models)" % [
		loaded, placements.size(), mapo_path, region.objects.size(), o2_count, skipped_unresolved, templates.size()])

## Keeps only the `.o2` placements that belong to this region, by asking
## which region's ground each one actually stands on.
##
## A real `.o2` cross-references objects belonging to neighbouring regions,
## and drawing those here puts them at the wrong place and the wrong
## height. The seventy-eighth round filtered them by which per-sector list
## they sit in, which helps but is not decisive. The heightmap is: an
## object's own placement Y and its region's own terrain are two
## independently authored numbers, and they agree only for the region the
## object really belongs to.
##
## Measured on real data (see docs/WORLD_ISSUES.md's eighty-fifth round):
## four real objects drawn against real 96/167's east edge sit 60-odd
## units above that region's ground at -52.98, -59.24, -50.13 and -49.09,
## and land on real **96/166**'s ground at 14.49, 8.09, 16.13 and 16.17 --
## against their own placement heights of 14.5, 7.8, 16.1 and 16.2.
##
## The test is *comparative*, not a tolerance, which is what keeps
## genuinely elevated scenery: a real `x_mas_wreath02` authored 167 units
## over real 96/168's ground still matches 96/168 better than any
## neighbour, so it stays. Only an entry that some neighbour explains
## better is dropped. `.o` placements are never filtered -- that file is
## the region's own list.
func _placements_belonging_here(placements: Array, mapo_path: String) -> Array:
	var coords := _parse_region_coords(mapo_path)
	if coords.is_empty():
		return placements
	var here := _parsed_region_heightmap(coords["x"], coords["y"])
	if here == null:
		return placements

	var kept: Array = []
	var moved := 0
	for p in placements:
		if not p.get("from_o2", false):
			kept.append(p)
			continue
		var pos: Vector3 = p["position"]
		var own := MapmTerrainBuilder.height_at(here, pos.x, pos.z)
		if is_nan(own):
			kept.append(p)
			continue
		var own_error := absf(pos.y - own)
		var better := false
		for dy in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				if dx == 0 and dy == 0:
					continue
				var neighbour := _parsed_region_heightmap(
					coords["x"] + (dx as int), coords["y"] + (dy as int))
				if neighbour == null:
					continue
				var h := MapmTerrainBuilder.height_at(neighbour, pos.x, pos.z)
				if is_nan(h):
					continue
				if absf(pos.y - h) < own_error - PLACEMENT_OWNERSHIP_MARGIN:
					better = true
					break
			if better:
				break
		if better:
			moved += 1
		else:
			kept.append(p)
	if moved > 0:
		print("World3D: %s -- dropped %d real .o2 placement(s) that stand on a neighbouring region's ground" % [
			mapo_path, moved])
	return kept

## How much better a neighbouring region has to explain a placement's own
## height before the placement is treated as that neighbour's rather than
## this region's. Small, because the real matches are exact to a few
## hundredths while the mismatches run to tens of units -- it only guards
## against handing an object away on rounding.
const PLACEMENT_OWNERSHIP_MARGIN := 1.0

## Parsed `.m` heightmaps by region, so the ownership test above can sample
## a neighbour's terrain without rebuilding it. Parsing is the expensive
## part and every region in the grid gets parsed for its own terrain
## anyway, so this is a second reference rather than a second parse of
## anything new.
var _parsed_region_heightmaps := {}

func _parsed_region_heightmap(region_x: int, region_y: int) -> MapmReader.ParsedRegion:
	var key := "%d_%d" % [region_x, region_y]
	if _parsed_region_heightmaps.has(key):
		return _parsed_region_heightmaps[key]
	var bytes := AssetSource.read_bytes("%d\\%d.m" % [region_x, region_y], _open_map_pk2_if_set())
	var parsed: MapmReader.ParsedRegion = null
	if not bytes.is_empty():
		parsed = MapmReader.parse(bytes)
	_parsed_region_heightmaps[key] = parsed
	return parsed

## The real player capsule's own height, read from the real shape rather
## than duplicated as a number here, so rescaling the character in the
## scene keeps the step height (see STEP_HEIGHT_FRACTION) in proportion.
func _player_capsule_height() -> float:
	var collision := player.get_node_or_null("Collision") as CollisionShape3D
	if collision != null and collision.shape is CapsuleShape3D:
		return (collision.shape as CapsuleShape3D).height
	return 0.0

## Set to "1" to move the player with Godot physics (gravity, capsule,
## move_and_slide and the _try_step_up assist) instead of on the real walkable
## graph. Kept so the two models can be compared directly within one build.
##
## The graph is the default because it is verified end to end, in a real
## running world, against the exact failure it was built to fix:
##
##   * the graph itself is verified against real data (see NavGraph);
##   * it builds correctly for every streamed region -- a real Jangan load
##     places 122/122 real objects with 411 real terrain blocking edges;
##   * and a real character climbs a real staircase with it. Dropped at the
##     foot of the real Jangan palace stairs (a real 22.1-unit ramp) with the
##     _try_step_up assist disabled, the player walked region-local y=2.12 ->
##     10.74 -> 19.64 -> 21.94, arriving at the ramp's own real top height and
##     then holding that height for 450 further frames while continuing to
##     move -- so it neither stalls on the ramp nor falls through at the top.
##     Partway along, X stops changing while Z keeps rising: a real blocking
##     edge being slid along rather than stuck to.
##   * The same harness, on the same stairs, with the reverted
##     collision-shape approach produced *zero* displacement
##     (docs/WORLD_ISSUES.md's sixty-third round).
const NAV_MOVEMENT_DISABLE_ENV := "SRREVAMP_NO_NAVMESH_MOVEMENT"

## Moves the player on the real walkable graph, the way the real client does:
## the ground's height comes from the real cell underfoot, and a move is
## refused when it crosses a real blocking edge -- an edge being a 2D line,
## never geometry.
##
## Returns false when no real graph covers the player, in which case the
## caller falls back to physics. That happens legitimately: a region with no
## `.nvm`, or the moment before one streams in.
##
## There is no gravity here and no capsule, which is not a simplification --
## the real client has neither. The previous attempt expressed this same data
## as collision shapes and failed precisely because a capsule against a
## two-sided surface pins itself against the very ramp it stands on (see
## docs/WORLD_ISSUES.md's sixty-third round).
func _move_on_nav_graph(delta: float) -> bool:
	if OS.get_environment(NAV_MOVEMENT_DISABLE_ENV) == "1":
		return false
	var pair := _nav_graph_for(player.global_position)
	if pair.is_empty():
		return false
	var graph: NavGraph = pair[0]
	var group: Node3D = pair[1]

	# The move is expressed in the region's own space, via the terrain group's
	# own transform, so the world mirror cannot skew it -- and the decision
	# itself lives in NavGraph.step, where it can be unit tested.
	var world_step := Vector3(player.velocity.x, 0.0, player.velocity.z) * delta
	var local := group.to_local(player.global_position)
	var target := group.to_local(player.global_position + world_step)
	local = graph.step(local, Vector2(target.x - local.x, target.z - local.z))
	player.global_position = group.to_global(local)
	player.velocity.y = 0.0
	return true

## How wide the real character shadow blob is drawn, in world units.
##
## A disclosed rendering choice, not real data: the real texture is a plain
## radial gradient with no scale baked into it, and nothing found so far says
## how large the real client draws it. Sized here a little wider than the real
## player capsule (radius 2) so it reads as a shadow under the feet.
const BLOB_SHADOW_SIZE := 9.0

## How far above the real ground the blob sits, to keep it from z-fighting the
## terrain it lies on. Also a disclosed choice.
const BLOB_SHADOW_LIFT := 0.15

var _blob_shadow: MeshInstance3D

## Builds the real character shadow.
##
## The real client does not shadow-map its terrain -- it lights terrain per
## vertex (see MapmTerrainBuilder._lit_vertex_color) and draws a character's
## shadow as a real soft radial blob, shipped as `SkyBox\shadowsphere.ddj` in
## a real Map.pk2: a real 64x64 DXT3 gradient, black at the centre fading to
## a real 64x64 DXT3 texture whose RGB is solid black and whose **alpha** is the
## radial gradient, so it draws as a soft alpha-blended black disc.
##
## Added 2026-09-07 because baking real terrain lighting made terrain unshaded,
## which removed the engine's own dynamic shadow from the ground. This restores
## a shadow the way the real client actually draws one, rather than putting the
## engine's back.
func _build_blob_shadow(blob_tex: Texture2D) -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(BLOB_SHADOW_SIZE, BLOB_SHADOW_SIZE)

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = blob_tex
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# The real texture's shape lives entirely in its **alpha**: measured, its
	# RGB is solid black (mean 0, standard deviation 0) while its alpha is the
	# radial gradient (mean 0.33, standard deviation 0.34). So it is drawn as
	# an ordinary alpha-blended black quad, and the gradient does the shaping.
	#
	# Two earlier attempts got this wrong by trusting a converted preview of
	# the texture, which composited that alpha over white and so *looked* like
	# a black-centre-to-white-edge multiply map. Both drew a hard black square.
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED

	_blob_shadow = MeshInstance3D.new()
	_blob_shadow.name = "CharacterShadow"
	_blob_shadow.mesh = quad
	_blob_shadow.material_override = mat
	# A QuadMesh faces +Z; lay it flat on the ground.
	_blob_shadow.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	_blob_shadow.visible = false
	add_child(_blob_shadow)

## Keeps the real character shadow under the player, on the real ground.
##
## The height comes from the real walkable graph rather than a raycast, so the
## shadow lands on whatever the player is actually standing on -- real terrain,
## or a real object's own navigation mesh such as a staircase or bridge.
func _update_blob_shadow() -> void:
	if _blob_shadow == null:
		return
	var pair := _nav_graph_for(player.global_position)
	if pair.is_empty():
		_blob_shadow.visible = false
		return
	var graph: NavGraph = pair[0]
	var group: Node3D = pair[1]
	var local := group.to_local(player.global_position)
	local.y = graph.height_at(local.x, local.z, local.y) + BLOB_SHADOW_LIFT
	_blob_shadow.global_position = group.to_global(local)
	_blob_shadow.visible = true

## ---------------------------------------------------------------------------
## QA screenshot harness
##
## Lets a run be pointed at a specific place and framed a specific way, without
## anyone driving the client by hand. Every hook below is off unless its
## environment variable is set, so a normal run is untouched.
##
##   SRREVAMP_QA_AT="x,z"   teleport to that region-local spot, standing on
##                          whatever the real walkable graph says is there
##   SRREVAMP_QA_YAW=deg    camera yaw (0 looks along +Z)
##   SRREVAMP_QA_PITCH=deg  camera pitch (-90 is straight down)
##   SRREVAMP_QA_DIST=n     camera distance from the player
##   SRREVAMP_QA_WALK=deg   walk continuously on that heading
##   SRREVAMP_QA_FREE=1     let the camera pass through geometry
##   SRREVAMP_QA_NOFOG=1    disable fog (for high overview shots)
##   SRREVAMP_QA_NOUI=1     hide the HUD (for comparison shots)
##   SRREVAMP_QA_WORLDMAP=1 open the world map window over the world
##   SRREVAMP_QA_ATTACK=1   attack the nearest monster every second, so a
##                          hit reaction and a death can be rendered
##   SRREVAMP_QA_FLOAT=r     report placed objects within r that sit clear
##                          of their own region's ground
##   SRREVAMP_QA_THROUGH=z0,z1,y[,step]
##                          fire horizontal rays through that band and
##                          report which X spans are clear through it
##   SRREVAMP_QA_SHOTS=...   visit several viewpoints in one run, as
##                          `name@x,z:yaw,pitch,dist` separated by `;` --
##                          each prints the movie frame it landed on
##   SRREVAMP_QA_RADIUS=n   load an n-region radius instead of the default
##   SRREVAMP_QA_ANIM=1     play the real character animation (off by
##                          default -- it still renders wrongly, see
##                          docs/WORLD_ISSUES.md's ninetieth round)
##   SRREVAMP_QA_RIG=1      report where each assembled character piece is
##                          against where its own bone is
##   SRREVAMP_QA_SCAN=n     sweep the region on an n x n grid and report
##                          where the walkable graph sits below the solid
##                          geometry (i.e. where a player walks underneath)
##   SRREVAMP_QA_COLUMNS="x,z;x,z"  what the walkable graph knows at these
##                          region-local columns: every surface, the
##                          objects it considers, and any it does not index
##   SRREVAMP_QA_HIDE=a,b    hide every mesh whose own real mesh name
##                          contains one of these fragments
##   SRREVAMP_QA_LOOK=1     print which real placed objects the camera is
##                          pointing at (model name, distance, placement)
##   SRREVAMP_QA_DEBUG=1    open the debug panel (F3) as soon as the first
##                          region has loaded, so a render shows it
##   SRREVAMP_QA_ZONE=z     after the first region loads, reload assets for
##                          this zone -- accepts the zone box's own
##                          `x/y@localX,localZ` form. Reproduces a real
##                          zone change's *sequence* (build a grid, then
##                          rebuild it for somewhere else) with no server
##                          in the loop, which is how the stale-node bug
##                          in _clear_region_grid was caught and checked.
##
## Position is reported every 60 physics frames as `QA <tick> local x, y, z`,
## so a run's log says exactly where each frame was taken. See
## `client/tools/qa_shot.sh` for the runner that drives this and collects the
## frames.
var _qa_done := false
var _qa_tick := 0
## SRREVAMP_QA_WALK, read once: a heading in degrees to keep walking on,
## driven from _physics_process like a held key so the run plays.
var _qa_walk := OS.get_environment("SRREVAMP_QA_WALK")

## Puts the player at a region-local spot in the region they stand in,
## landing on the highest walkable surface there -- what SRREVAMP_QA_AT
## and the debug panel's teleport both do. False when no region has
## streamed in yet.
func _teleport_local(lx: float, lz: float) -> bool:
	var pair := _nav_graph_for(player.global_position)
	if pair.is_empty():
		return false
	var graph: NavGraph = pair[0]
	var group: Node3D = pair[1]
	# An arrival, not a step: land on the highest surface here.
	var ly := graph.landing_height_at(lx, lz)
	player.global_position = group.to_global(Vector3(lx, ly, lz))
	player.velocity = Vector3.ZERO
	return true

func _qa_step() -> void:
	var pair := _nav_graph_for(player.global_position)
	if not _qa_done:
		var at := OS.get_environment("SRREVAMP_QA_AT")
		if at != "" and pair.is_empty():
			return # region not streamed in yet; try again next frame
		_qa_done = true
		if at != "":
			var parts := at.split(",")
			if parts.size() >= 2:
				_teleport_local(float(parts[0]), float(parts[1]))
		if OS.get_environment("SRREVAMP_QA_DEBUG") != "" and _debug_panel != null:
			_debug_panel.toggle()
		if OS.get_environment("SRREVAMP_QA_FREE") != "":
			camera_arm.collision_mask = 0
		if OS.get_environment("SRREVAMP_QA_DIST") != "":
			camera_arm.spring_length = float(OS.get_environment("SRREVAMP_QA_DIST"))
		var yaw := OS.get_environment("SRREVAMP_QA_YAW")
		var pitch := OS.get_environment("SRREVAMP_QA_PITCH")
		if yaw != "" or pitch != "":
			camera_arm.rotation_degrees = Vector3(
				float(pitch) if pitch != "" else camera_arm.rotation_degrees.x,
				float(yaw) if yaw != "" else camera_arm.rotation_degrees.y, 0.0)
		if OS.get_environment("SRREVAMP_QA_NOUI") != "":
			# Comparing a render against the authored minimap is a lot
			# easier without a chat box across the bottom of it.
			for node in [$UI/Control, $UI/HideUIButton]:
				(node as CanvasItem).visible = false
		if OS.get_environment("SRREVAMP_QA_ATTACK") != "" and NetClient.is_connected_to_server():
			_qa_attacking = true
		# SRREVAMP_QA_LEVELUP=<level> fires the real level-up burst a moment
		# after the player is placed, so a movie render catches it mid-play
		# (it lasts LevelUpEffect.LIFE). Movie mode advances 1/60 a frame, so
		# 15 frames is a quarter second -- enough for the camera to settle.
		var qa_levelup := OS.get_environment("SRREVAMP_QA_LEVELUP")
		if qa_levelup != "":
			var lvl: int = int(qa_levelup) if qa_levelup.is_valid_int() else 10
			get_tree().create_timer(15.0 / 60.0).timeout.connect(_on_level_up.bind(lvl, 0))
		var qa_worldmap := OS.get_environment("SRREVAMP_QA_WORLDMAP")
		if qa_worldmap != "" and _hud_worldmap != null:
			# The window only builds its tiles for what can be seen, so it
			# has to be opened *after* the player is in place -- otherwise
			# it centres on nowhere and loads the map's top-left corner.
			_hud_worldmap.open()
			if qa_worldmap == "world":
				_hud_worldmap.show_world()
			elif qa_worldmap == "both":
				# One boot, both of the window's modes: the city map first
				# and the whole world part way through the run.
				#
				# In seconds, not frames, but movie-writing mode advances
				# scene time by a fixed 1/60 a frame regardless of how long
				# the frame really took -- so a six-second timer needs 360
				# rendered frames and a 60-frame run never reaches it. A
				# third of a second is frame 20.
				get_tree().create_timer(20.0 / 60.0).timeout.connect(_hud_worldmap.show_world)
		if OS.get_environment("SRREVAMP_QA_NOFOG") != "":
			if world_environment != null and world_environment.environment != null:
				var env := world_environment.environment
				env.fog_enabled = false
				# The aerial-perspective haze is a separate term from the
				# fog toggle, and at the altitude an overview shot needs it
				# washes the whole city out -- which defeats the point of
				# taking one to compare against authored art.
				env.fog_aerial_perspective = 0.0
				env.fog_density = 0.0
			camera_3d.far = 40000.0
			# So is the cloud layer, and for a more interesting reason: the
			# dome is a hemisphere of SKY_DOME_RADIUS centred
			# SKY_DOME_HEIGHT_ABOVE_PLAYER overhead, so a camera far enough
			# up to frame a region ends up *above* the clouds looking down
			# through them. That is the pale veil over the city in every
			# overview shot this project has taken -- correct rendering of
			# a real cloud layer, mistaken for a defect in the world for
			# long enough to be written up as one.
			if _sky_dome != null:
				_sky_dome.visible = false
			if _sun_glow != null:
				_sun_glow.visible = false
		var hide := OS.get_environment("SRREVAMP_QA_HIDE")
		if hide != "":
			_qa_hide_meshes(hide.split(","))
		var floating := OS.get_environment("SRREVAMP_QA_FLOAT")
		if floating != "":
			_qa_float_report(float(floating))
		var through := OS.get_environment("SRREVAMP_QA_THROUGH")
		if through != "":
			# Several bands in one run: the useful height is rarely known
			# in advance, and each run costs minutes.
			for spec in through.split(";"):
				if spec.strip_edges() != "":
					_qa_through_report(spec.strip_edges())
		var shots := OS.get_environment("SRREVAMP_QA_SHOTS")
		if shots != "":
			for spec in shots.split(";"):
				var parsed := _parse_shot(spec.strip_edges())
				if not parsed.is_empty():
					_qa_shots.append(parsed)
		var scan := OS.get_environment("SRREVAMP_QA_SCAN")
		if scan != "":
			_qa_scan_report(maxi(int(scan), 2))
		var columns := OS.get_environment("SRREVAMP_QA_COLUMNS")
		if columns != "":
			_qa_columns_report(columns)
		var qa_zone := OS.get_environment("SRREVAMP_QA_ZONE")
		if qa_zone != "":
			var target := _split_zone_target(qa_zone)
			var zone: String = target["zone"]
			_reload_zone_assets(zone)
			var coords := _parse_region_coords(_resolve_zone_region(zone))
			if target.has("local") and not coords.is_empty():
				var spot: Vector2 = target["local"]
				_place_at_region_local(coords["x"], coords["y"], spot.x, spot.y)
			_refresh_zone_label_position()

	# SRREVAMP_QA_PANELS opens named HUD windows so a render can show them.
	# Comma-separated panel ids from HudPanels.PANELS, e.g.
	# "inventory,character,skill". Opened once the world has settled, and
	# tiled rather than centred so several are visible in one shot.
	if OS.get_environment("SRREVAMP_QA_PANELS") != "" and _qa_tick == 30:
		_qa_open_panels(OS.get_environment("SRREVAMP_QA_PANELS"))

	# SRREVAMP_QA_CASTANIM="<anim_base>" plays a skill's cast animation on the
	# player at tick 90 (and replays it), so a render can verify the grounded
	# Basic_Code -> .ban mapping. QA only, no target/server needed.
	if OS.get_environment("SRREVAMP_QA_CASTANIM") != "" and _qa_tick % 90 == 0 and _qa_tick > 0:
		_play_skill_cast_anim(OS.get_environment("SRREVAMP_QA_CASTANIM"))

	# SRREVAMP_QA_TARGET=1 opens the target window on the first known monster so a
	# render can verify its real level (from characterdata) shows. QA only.
	if OS.get_environment("SRREVAMP_QA_TARGET") != "" and _qa_tick == 90 and not _monsters.is_empty():
		var m: CombatNet.MonsterSnapshot = _monsters[0]
		_monster_snapshots[m.monster_id] = m
		_show_target(m.monster_id)

	# SRREVAMP_QA_STANCE=1 keeps the player "recently in combat" so a render shows
	# the battle stance (STAND_BATTLE) instead of the town idle. QA only.
	if OS.get_environment("SRREVAMP_QA_STANCE") != "":
		_last_combat_time = _player_anim_time

	# SRREVAMP_QA_HITFX=1 plays the critical-hit slash burst on the player every
	# 90 ticks, so a render can verify the recovered hit_3_critical layers.
	if OS.get_environment("SRREVAMP_QA_HITFX") != "" and _qa_tick >= 15 and _qa_tick % 15 == 0 and player != null:
		# Exercise the real per-skill path: look the effect up in skilleffect.txt
		# by Basic_Code and play it via the generic .efp loader.
		_play_skill_hit_effect_on(player, _player_world_height(), OS.get_environment("SRREVAMP_QA_HITFX"))

	# SRREVAMP_QA_HOTBAR=1 assigns two real skills to the hotbar (the same path a
	# window click takes) so a render can show their icons in the quickslots.
	if OS.get_environment("SRREVAMP_QA_HOTBAR") != "" and _qa_tick == 60 and _ui_builder != null:
		_on_skill_assign_requested(3, "SKILL_CH_SWORD_SMASH_A_01",
			_ui_builder.load_texture("icon\\skill\\china\\sword_smash_a.ddj"))
		_on_skill_assign_requested(177, "SKILL_CH_SWORD_CHAIN_A_01",
			_ui_builder.load_texture("icon\\skill\\china\\sword_chain_a.ddj"))

	# SRREVAMP_QA_FAKEITEMS fills the bag with sample items (real IDs) a little
	# after it opens -- past the server's empty-inventory reply -- so a render
	# can show a populated inventory. QA only.
	if OS.get_environment("SRREVAMP_QA_FAKEITEMS") != "" and _qa_tick == 50 and _hud_panels != null:
		_hud_panels.qa_fill_sample_inventory()

	# SRREVAMP_QA_TALK="<name>" opens the NPC dialogue for a render, standing
	# in for a click on an NPC (which a render cannot make).
	if OS.get_environment("SRREVAMP_QA_TALK") != "" and _qa_tick == 30 and _hud_panels != null:
		# The env value is an NPC codename (e.g. NPC_CH_SMITH) so a render shows
		# its real greeting + services; falls back to using it as a display name.
		_load_npc_tables()
		var code := OS.get_environment("SRREVAMP_QA_TALK")
		_talk_npc_name = code
		_talk_npc_code = code
		_hud_panels.open_npc_talk(code, _npc_greeting_text(code), _npc_services(code))

	# SRREVAMP_QA_SHOP="<NPC_CODE>" opens that NPC's store window for a render,
	# standing in for talk -> Buy. Shows the real goods grid + tabs.
	if OS.get_environment("SRREVAMP_QA_SHOP") != "" and _qa_tick == 40 and _hud_panels != null:
		_load_npc_tables()
		var scode := OS.get_environment("SRREVAMP_QA_SHOP")
		_talk_npc_name = scode
		_talk_npc_code = scode
		if _shop_reader != null:
			_hud_panels.open_shop(scode, _shop_reader.tabs_for(scode))

	# SRREVAMP_QA_SHOP_BUY exercises the buy flow for a render: show the confirm
	# popup (proving the price + purse loaded), then actually buy (proving the
	# transaction; the purse drops and the server logs it).
	if OS.get_environment("SRREVAMP_QA_SHOP_BUY") != "" and _hud_panels != null:
		# Buy a stack, then sell part of it back -- the whole shop loop. The bag
		# opens with the shop, so the stack and the sell dialog both show.
		if _qa_tick == 55:
			_hud_panels.qa_buy_first_item()
		elif _qa_tick == 75:
			_hud_panels.qa_confirm_sell_first()
		elif _qa_tick == 90:
			_hud_panels.qa_sell_first(5)

	# SRREVAMP_QA_STORAGE (with SRREVAMP_QA_SHOP set to a shop) exercises the
	# warehouse: buy a stack into the bag, open storage, then deposit part of it.
	if OS.get_environment("SRREVAMP_QA_STORAGE") != "" and _hud_panels != null:
		if _qa_tick == 52:
			_hud_panels.qa_buy_first_item()
		elif _qa_tick == 66:
			_hud_panels.close("store")
			_hud_panels.open_storage("Warehouse Keeper")
		elif _qa_tick == 80:
			_hud_panels.qa_deposit_first()
		elif _qa_tick == 92:
			_hud_panels.qa_do_deposit_first(8)

	# SRREVAMP_QA_NAVGAP compares each nearby object's *solid* footprint
	# against its *walkable* one. A player can stand inside anything where
	# the first is bigger than the second, so this says which objects those
	# are rather than leaving it to be discovered by falling into one.
	if OS.get_environment("SRREVAMP_QA_NAVGAP") != "" and _qa_tick == 60:
		_qa_navgap_report()

	# SRREVAMP_QA_NPCBODY fires a short horizontal ray at each nearby NPC
	# and reports whether anything stops it. "The player walks through the
	# merchants" is not something a still frame can answer, and walking into
	# one on camera to find out is exactly the kind of check this project
	# has been wrong with before.
	if OS.get_environment("SRREVAMP_QA_NPCBODY") != "" and _qa_tick == 60:
		_qa_npc_body_report()

	# Whether the idle animations are actually moving anything. A still
	# frame cannot answer that, so this samples the same skeletons at two
	# ticks and prints how far their bones travelled between them: zero
	# means the pose is being applied but nothing is changing, which is what
	# a broken animation looks like from the outside.
	if OS.get_environment("SRREVAMP_QA_ANIM") != "" and (_qa_tick == 60 or _qa_tick == 130):
		_qa_animation_report()

	if OS.get_environment("SRREVAMP_QA_LOOK") != "" and (_qa_tick == 60 or _qa_tick == 120):
		_qa_look_report()

	# Reported from a later tick, not the one-time setup block: the
	# animation is applied during the movement update, so a report taken on
	# the first frame measures the character before it has been posed at
	# all -- which it did, and produced identical output with playback on
	# and off.
	# Sampled at several ticks, so "is anything moving at all" can be read
	# off the numbers rather than inferred from a still image.
	if OS.get_environment("SRREVAMP_QA_RIG") != "" and _qa_tick in [30, 60, 90]:
		_qa_rig_report()
	if _qa_attacking and _qa_tick % 60 == 0:
		_qa_attack_nearest()

	if not _qa_shots.is_empty():
		_qa_advance_shots()

	_qa_tick += 1
	if _qa_tick % 60 == 0:
		var where := "off-region"
		var standing := ""
		if not pair.is_empty():
			var l := (pair[1] as Node3D).to_local(player.global_position)
			where = "%d, %d, %d" % [l.x, l.y, l.z]
			# What the walkable graph thinks is underfoot, and how far the
			# player actually is from it -- the question when someone
			# reports walking *underneath* something they should be on top
			# of.
			var graph: NavGraph = pair[0]
			var surface := graph.surface_at(l.x, l.z, l.y)
			var what := "terrain"
			if not surface.is_terrain:
				what = "object %d" % surface.object_index
				var placed: NavGraph.PlacedObject = graph.objects[surface.object_index]
				if placed != null and placed.has_meta("model"):
					what = "object %s" % placed.get_meta("model")
			standing = "  on %s at %.1f (%.1f below feet)" % [what, surface.height, l.y - surface.height]

			# What the walkable graph says and what is actually *drawn*
			# there are two different questions, and this project has been
			# caught by that before -- an earlier float report measured the
			# navmesh and called it the terrain. A ray straight down through
			# the real collision answers the second one, so a disagreement
			# between them shows up as a number instead of as a player
			# standing waist-deep in a plaza.
			var space := get_world_3d().direct_space_state
			var from := player.global_position + Vector3(0, 200, 0)
			var query := PhysicsRayQueryParameters3D.create(from, from + Vector3(0, -800, 0))
			query.collision_mask = TERRAIN_COLLISION_LAYER
			query.exclude = [player.get_rid()]
			var hit := space.intersect_ray(query)
			if hit.is_empty():
				standing += "  drawn surface: none found"
			else:
				var drawn_local: float = (pair[1] as Node3D).to_local(hit.position).y
				# Name what was hit. "Something is 13.8 above the graph" is
				# not actionable; "cj_jang_square is 13.8 above the graph"
				# says whether the walkable graph is missing that object's
				# navigation mesh or the object is simply overhead.
				var what_drawn := "?"
				var collider = hit.get("collider")
				if collider is Node:
					var n: Node = collider
					while n != null and not (n.name as String).begins_with("Obj_"):
						n = n.get_parent()
					what_drawn = String(n.name) if n != null else String((collider as Node).name)
				standing += "  drawn %s at %.1f (%.1f above the graph's)" % [
					what_drawn, drawn_local, drawn_local - surface.height]
		print("QA %4d local %s%s" % [_qa_tick, where, standing])

## Viewpoints still to visit this run, and where the current one is up to.
## See _qa_advance_shots.
var _qa_shots: Array = []
var _qa_shot_index := -1
var _qa_shot_frames := 0

## How many frames a viewpoint is held before and after its frame is
## announced -- enough for streaming and the camera arm to settle.
const QA_SHOT_SETTLE := 12
const QA_SHOT_HOLD := 16

## Parses one `name@x,z:yaw,pitch,dist` viewpoint. Everything after the
## position is optional.
static func _parse_shot(spec: String) -> Dictionary:
	if spec == "":
		return {}
	var name := "shot"
	var rest := spec
	var at := spec.find("@")
	if at >= 0:
		name = spec.substr(0, at).strip_edges()
		rest = spec.substr(at + 1)
	var camera := ""
	var colon := rest.find(":")
	if colon >= 0:
		camera = rest.substr(colon + 1)
		rest = rest.substr(0, colon)
	var pos := rest.split(",")
	if pos.size() < 2 or not pos[0].strip_edges().is_valid_float() or not pos[1].strip_edges().is_valid_float():
		return {}
	var out := {"name": name, "x": float(pos[0]), "z": float(pos[1])}
	var cam := camera.split(",") if camera != "" else PackedStringArray()
	var keys := ["yaw", "pitch", "dist"]
	for i in range(mini(cam.size(), keys.size())):
		if cam[i].strip_edges().is_valid_float():
			out[keys[i]] = float(cam[i])
	return out

## Walks a run through several viewpoints, announcing the movie frame each
## one lands on.
##
## Startup dominates a screenshot run -- about 65 seconds of loading
## against 0.33 seconds a frame -- so taking six pictures as six runs pays
## that cost six times. This pays it once: the run visits each viewpoint in
## turn, holds it long enough to settle, and prints
## `QA SHOT <name> frame <n>`, so the caller pulls frame n from the movie
## sequence for each. No separate capture path is needed, which matters
## because manual viewport capture has its own history of returning blank
## images in this project.
func _qa_advance_shots() -> void:
	# Announce once the camera has had QA_SHOT_SETTLE frames to arrive, so
	# the frame named is one worth pulling.
	if _qa_shot_index >= 0 and _qa_shot_frames == QA_SHOT_HOLD:
		print("QA SHOT %s frame %d" % [
			_qa_shots[_qa_shot_index]["name"], Engine.get_frames_drawn()])
	_qa_shot_frames -= 1
	if _qa_shot_frames > 0:
		return

	_qa_shot_index += 1
	if _qa_shot_index >= _qa_shots.size():
		print("QA SHOT: all %d viewpoints visited" % _qa_shots.size())
		_qa_shots.clear()
		return

	var shot: Dictionary = _qa_shots[_qa_shot_index]
	var pair := _nav_graph_for(player.global_position)
	if not pair.is_empty():
		var graph: NavGraph = pair[0]
		var group: Node3D = pair[1]
		var lx: float = shot["x"]
		var lz: float = shot["z"]
		# Same as the initial placement: a viewpoint jump is an arrival.
		player.global_position = group.to_global(Vector3(lx, graph.landing_height_at(lx, lz), lz))
		player.velocity = Vector3.ZERO
	if shot.has("dist"):
		camera_arm.spring_length = shot["dist"]
	if shot.has("yaw") or shot.has("pitch"):
		camera_arm.rotation_degrees = Vector3(
			shot.get("pitch", camera_arm.rotation_degrees.x),
			shot.get("yaw", camera_arm.rotation_degrees.y), 0.0)
	_qa_shot_frames = QA_SHOT_SETTLE + QA_SHOT_HOLD

## Reports where each piece of the assembled character actually is,
## against where its own bone is.
##
## The skeleton itself is known to pose correctly -- see
## client/tools/check_ban_pose.gd, which puts the hands below the head
## after a frame -- while the assembled character renders with its arms
## overhead. That can only be the attachment, and the attachment's
## arithmetic looks right on paper, so this measures it instead of
## reasoning about it: for every piece, where the bone is, where the piece
## ended up, and how far apart they are.
var _qa_attacking := false

## Attacks whichever live monster is nearest the player -- the same
## request the Attack button sends -- so the combat animations can be
## rendered without a hand on the mouse.
func _qa_attack_nearest() -> void:
	var nearest_id := -1
	var nearest := INF
	for monster_id in _monster_bodies:
		if _dying_until.has(monster_id):
			continue
		var body: Node3D = _monster_bodies[monster_id]
		if not is_instance_valid(body):
			continue
		var d := body.global_position.distance_to(player.global_position)
		if d < nearest:
			nearest = d
			nearest_id = monster_id
	if nearest_id == -1:
		return
	print("QA ATTACK: monster %d at %.0f" % [nearest_id, nearest])
	_last_attack_target = nearest_id
	_show_target(nearest_id)
	NetClient.attack(NetClient.current_character_name, nearest_id)

func _qa_rig_report() -> void:
	if _player_skeleton == null:
		print("QA RIG: no assembled player skeleton")
		return
	var skeleton := _player_skeleton
	print("QA RIG tick %d: %d bone(s), skeleton at %s" % [
		_qa_tick, skeleton.get_bone_count(), skeleton.global_position.round()])
	# Where the body stands against the ground: the player node, the
	# lowest and highest bone, every drawn mesh's world-space box, and the
	# walkable height under the player. A character buried to the waist
	# shows here as feet well below the landing height.
	var lowest := INF
	var highest := -INF
	var lowest_bone := ""
	var highest_bone := ""
	for i in range(skeleton.get_bone_count()):
		var y: float = (skeleton.global_transform * skeleton.get_bone_global_pose(i).origin).y
		if y < lowest:
			lowest = y
			lowest_bone = skeleton.get_bone_name(i)
		if y > highest:
			highest = y
			highest_bone = skeleton.get_bone_name(i)
	var mesh_min := INF
	var mesh_max := -INF
	for node in skeleton.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		var box: AABB = mi.global_transform * mi.get_aabb()
		mesh_min = minf(mesh_min, box.position.y)
		mesh_max = maxf(mesh_max, box.end.y)
	var ground := NAN
	var pair := _nav_graph_for(player.global_position)
	if not pair.is_empty():
		var group: Node3D = pair[1]
		var local: Vector3 = group.to_local(player.global_position)
		ground = group.global_position.y + (pair[0] as NavGraph).landing_height_at(local.x, local.z)
	print("QA RIG   player at y %.2f; bones %.2f (%s) .. %.2f (%s); meshes %.2f .. %.2f; ground %.2f" % [
		player.global_position.y, lowest, lowest_bone, highest, highest_bone, mesh_min, mesh_max, ground])
	# What is physically above and below the feet: a ray straight down from
	# well overhead says which collider is the first surface under this
	# column, and whether it sits above the feet -- which is the difference
	# between standing on the plaza and standing inside it.
	var space_state := get_world_3d().direct_space_state
	var from := player.global_position + Vector3(0.0, 60.0, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from, player.global_position - Vector3(0.0, 20.0, 0.0))
	query.exclude = [player.get_rid()]
	var hit := space_state.intersect_ray(query)
	if hit.is_empty():
		print("QA RIG   nothing under the column from %.1f above the feet" % 60.0)
	else:
		var who: Node = hit.collider
		print("QA RIG   first surface down from overhead: y %.2f (%.2f from the feet) on %s" % [
			hit.position.y, hit.position.y - player.global_position.y, who.get_path() if who != null else "?"])
	var every := PackedFloat32Array()
	if not pair.is_empty():
		var group: Node3D = pair[1]
		var local: Vector3 = group.to_local(player.global_position)
		every = (pair[0] as NavGraph).heights_at(local.x, local.z)
		for i in range(every.size()):
			every[i] += group.global_position.y
	print("QA RIG   walkable heights in this column: %s" % str(every))
	var rows: Array = []
	for child in skeleton.get_children():
		if not (child is BoneAttachment3D):
			continue
		var attachment := child as BoneAttachment3D
		var bone_idx := skeleton.find_bone(attachment.bone_name)
		if bone_idx == -1:
			continue
		var bone_world: Vector3 = skeleton.global_transform \
			* skeleton.get_bone_global_pose(bone_idx).origin
		for piece in attachment.get_children():
			if not (piece is MeshInstance3D):
				continue
			var mesh_node := piece as MeshInstance3D
			var centre: Vector3 = mesh_node.global_transform * mesh_node.get_aabb().get_center()
			rows.append([bone_world.distance_to(centre), attachment.bone_name, bone_world, centre])
	rows.sort_custom(func(a, b): return a[0] > b[0])
	# Printed to two decimals in the skeleton's own space, not rounded to
	# whole units in world space: the question is whether a piece moves
	# between frames at all, and rounding hid that.
	for row in rows:
		if String(row[1]) in ["Bip01 L Forearm", "Bip01 L UpperArm", "Bip01 L Calf"]:
			var local_centre: Vector3 = skeleton.global_transform.affine_inverse() * (row[3] as Vector3)
			print("QA RIG   %-18s mesh at %8.3f, %8.3f, %8.3f" % [
				row[1], local_centre.x, local_centre.y, local_centre.z])

## Reports placed objects standing clear of the ground under them, worst
## first -- scenery hanging in mid-air.
##
## Each object is measured against the terrain of the region it is
## actually parented to, so a neighbouring region's own vertical placement
## is judged on its own terms rather than against the region the player
## happens to be standing in.
func _qa_float_report(radius: float) -> void:
	var origin := player.global_position
	var found: Array = []
	for group in get_children():
		if not String(group.name).begins_with("RealTerrain"):
			continue
		var region_group := group as Node3D
		var graph: NavGraph = null
		for entry in _region_nav_graphs:
			if entry[1] == region_group:
				graph = entry[0]
				break
		if graph == null:
			continue
		for container in region_group.get_children():
			if not String(container.name).begins_with("RealMapObjects"):
				continue
			for node in container.get_children():
				var node3d := node as Node3D
				if origin.distance_to(node3d.global_position) > radius:
					continue
				var local := node3d.position
				# Against the *rendered* ground, not the navigation mesh:
				# the two are different surfaces, and what a player sees
				# scenery hanging over is the rendered one.
				var space := get_viewport().world_3d.direct_space_state
				var from_above := node3d.global_position + Vector3.UP * 400.0
				var to_below := node3d.global_position - Vector3.UP * 400.0
				var query := PhysicsRayQueryParameters3D.create(from_above, to_below)
				query.collision_mask = TERRAIN_COLLISION_LAYER
				query.exclude = [player.get_rid()]
				var hit := space.intersect_ray(query)
				if hit.is_empty():
					continue
				# Only the object's *own* region counts. Each region node
				# carries its own vertical anchor, so measuring an object
				# against a neighbour's terrain and then expressing that in
				# this region's local space reports the difference between
				# two anchors as if it were scenery floating -- which is
				# what an earlier version of this report did, producing
				# gaps of hundreds of units that clustered by region and
				# meant nothing.
				# Only the object's own region's *terrain* counts, and
				# terrain is specifically the body under this region's
				# SubPatch. Two ways this went wrong before: measuring
				# against a neighbouring region reports the difference
				# between two vertical anchors as if it were floating
				# scenery, and placed objects carry collision on the
				# default layer -- which TERRAIN_COLLISION_LAYER includes --
				# so a ray dropped near a tree lands on its canopy 350
				# units up and calls everything beneath it buried.
				var hit_collider = hit["collider"]
				if hit_collider == null:
					continue
				var collider_parent := (hit_collider as Node).get_parent()
				if collider_parent == null or String(collider_parent.name) != "SubPatch":
					continue
				if not region_group.is_ancestor_of(hit_collider as Node):
					continue
				var ground := region_group.to_local(hit["position"] as Vector3).y
				var gap := local.y - ground
				if absf(gap) < FLOATING_TOLERANCE:
					continue
				found.append([gap, String(node.name), String(region_group.name), local, ground])
	found.sort_custom(func(a, b): return absf(a[0]) > absf(b[0]))
	print("QA FLOAT: %d placed object(s) within %.0f sit more than %.0f off their own region's ground" % [
		found.size(), radius, FLOATING_TOLERANCE])
	for i in range(mini(found.size(), QA_FLOAT_MAX_ROWS)):
		var where: Vector3 = found[i][3]
		print("QA FLOAT   %+7.1f  %-30s %-20s local (%.0f, %.0f) placed y %.1f, ground %.1f" % [
			found[i][0], found[i][1], found[i][2], where.x, where.z, where.y, found[i][4]])

## Fires horizontal rays through a band of the region and reports which
## X positions are clear through it -- "is this arch a way through, or a
## recess in a solid wall?"
##
## Argument is "z0,z1,y[,step]", all region-local: the band to shoot
## through, the height to shoot at, and the sampling step. Reading a
## mesh file's own triangles answers this for one mesh; this answers it
## for what was actually built there, every overlapping copy included,
## which is the thing the player walks into.
func _qa_through_report(spec: String) -> void:
	var parts := spec.split(",")
	if parts.size() < 3:
		print("QA THROUGH: expected \"z0,z1,y[,step]\", got \"%s\"" % spec)
		return
	var pair := _nav_graph_for(player.global_position)
	if pair.is_empty():
		print("QA THROUGH: not standing in any loaded region")
		return
	var group: Node3D = pair[1]
	var z0 := float(parts[0])
	var z1 := float(parts[1])
	var y := float(parts[2])
	var step_span := float(parts[3]) if parts.size() > 3 else 10.0
	var space := get_viewport().world_3d.direct_space_state

	var open_from := NAN
	var runs: Array = []
	var x := 0.0
	while x <= REGION_SPAN:
		var query := PhysicsRayQueryParameters3D.create(
			group.to_global(Vector3(x, y, z0)), group.to_global(Vector3(x, y, z1)))
		query.collision_mask = 0xFFFFFFFF
		query.exclude = [player.get_rid()]
		var clear := space.intersect_ray(query).is_empty()
		if clear and is_nan(open_from):
			open_from = x
		elif not clear and not is_nan(open_from):
			runs.append([open_from, x - step_span])
			open_from = NAN
		x += step_span
	if not is_nan(open_from):
		runs.append([open_from, REGION_SPAN])

	print("QA THROUGH z %.0f..%.0f at height %.0f: %d clear span(s) across the region" % [
		z0, z1, y, runs.size()])
	for r in runs:
		print("QA THROUGH   local x %.0f .. %.0f  (%.0f wide)" % [r[0], r[1], r[1] - r[0]])

## Sweeps the player's region on a grid and reports every spot where the
## walkable graph disagrees with the solid geometry actually built there.
##
## "You can walk underneath things" is a whole-region property, and
## walking around looking for it finds one instance an hour. For each
## sample this drops a physics ray from high above and compares what it
## lands on with the height the graph would stand a player at. The graph
## being *below* the geometry is the reported failure: it means a player
## walking there ends up under a floor they should be on top of. The
## graph being above is normal and not reported -- that is a bridge, a
## roof, or an upper storey with the ray having hit the ground beneath it.
## SRREVAMP_QA_COLUMNS="x,z;x,z": for each region-local column, every
## surface the walkable graph knows there, which placed objects it
## considers and their footprints, and any object whose footprint holds
## the column but which the graph's index does not return there -- so
## "under the deck here, on it 85 units away" can be read off the graph.
func _qa_columns_report(spec: String) -> void:
	var pair := _nav_graph_for(player.global_position)
	if pair.is_empty():
		print("QA COLUMNS: not standing in any loaded region")
		return
	var graph: NavGraph = pair[0]
	for item in spec.split(";"):
		var parts := item.split(",")
		if parts.size() < 2:
			continue
		var x := float(parts[0])
		var z := float(parts[1])
		var world_here := (pair[1] as Node3D).to_global(Vector3(x, 0.0, z))
		print("QA COLUMN (%d, %d): terrain %.1f, surfaces %s, landing %.1f | world (%.0f, %.0f) -- the server's coordinates for this spot" % [
			int(x), int(z), NvmCollision.sample_height(graph.region, x, z),
			str(graph.heights_at(x, z)), graph.landing_height_at(x, z), world_here.x, world_here.z])
		# The real file's own answer first: which objects the navmesh cell
		# under this column lists, whether or not the graph could place them.
		var ci := graph.cell_index_at(x, z)
		if ci >= 0 and ci < graph.region.cells.size():
			var listed := PackedStringArray()
			for oi in graph.region.cells[ci].object_indices:
				var model := "?"
				if graph.objects.has(oi) and (graph.objects[oi] as Object).has_meta("model"):
					model = str((graph.objects[oi] as Object).get_meta("model"))
				elif oi < graph.region.objects.size():
					model = "resource %d, NOT placed" % (graph.region.objects[oi] as NvmReader.MapObject).resource_id
				listed.append("%d (%s)" % [oi, model])
			print("   the navmesh cell here lists objects: %s" % (", ".join(listed) if not listed.is_empty() else "none"))
		var considered: Array[int] = graph.objects_at(x, z)
		for oi in considered:
			var placed: NavGraph.PlacedObject = graph.objects[oi]
			var h := NavGraph.surface_height_of(placed, x, z)
			var model := str(placed.get_meta("model", "?"))
			print("   considers object %d (%s): footprint (%.0f, %.0f)-(%.0f, %.0f), %d cells, surface here %s" % [
				oi, model, placed.bounds_min.x, placed.bounds_min.y, placed.bounds_max.x, placed.bounds_max.y,
				placed.cells.size() / 3, "none" if is_nan(h) else "%.1f" % h])
			# Its navigation cells against its drawn pieces, both in region
			# space: if the two footprints disagree the placement is wrong;
			# if they agree, the navigation mesh has a hole the drawn deck
			# does not.
			var cell_lo := Vector3.INF
			var cell_hi := -Vector3.INF
			for v in placed.vertices:
				cell_lo = _vec_min(cell_lo, v)
				cell_hi = _vec_max(cell_hi, v)
			print("      cells span (%.0f, %.0f, %.0f)-(%.0f, %.0f, %.0f)" % [cell_lo.x, cell_lo.y, cell_lo.z, cell_hi.x, cell_hi.y, cell_hi.z])
			var nearest := []
			var i := 0
			while i + 2 <= placed.cells.size() - 1:
				var a: Vector3 = placed.vertices[placed.cells[i]]
				var b: Vector3 = placed.vertices[placed.cells[i + 1]]
				var c: Vector3 = placed.vertices[placed.cells[i + 2]]
				i += 3
				var centre := (a + b + c) / 3.0
				nearest.append([Vector2(centre.x - x, centre.z - z).length(), a, b, c])
			nearest.sort_custom(func(p, q): return p[0] < q[0])
			for k in range(mini(3, nearest.size())):
				var tri: Array = nearest[k]
				print("      cell %.0f away: (%.0f, %.0f, %.0f) (%.0f, %.0f, %.0f) (%.0f, %.0f, %.0f)" % [
					tri[0], tri[1].x, tri[1].y, tri[1].z, tri[2].x, tri[2].y, tri[2].z, tri[3].x, tri[3].y, tri[3].z])
			var drawn_lo := Vector3.INF
			var drawn_hi := -Vector3.INF
			var pieces := 0
			for node in (pair[1] as Node3D).find_children("Obj_%s_*" % model, "Node3D", true, false):
				for mesh_node in (node as Node).find_children("*", "MeshInstance3D", true, false):
					var mi := mesh_node as MeshInstance3D
					if mi.mesh == null:
						continue
					pieces += 1
					var aabb := mi.global_transform * mi.mesh.get_aabb()
					for corner in range(8):
						var p := (pair[1] as Node3D).to_local(aabb.get_endpoint(corner))
						drawn_lo = _vec_min(drawn_lo, p)
						drawn_hi = _vec_max(drawn_hi, p)
			if pieces > 0:
				print("      drawn as %d piece(s) spanning (%.0f, %.0f, %.0f)-(%.0f, %.0f, %.0f)" % [
					pieces, drawn_lo.x, drawn_lo.y, drawn_lo.z, drawn_hi.x, drawn_hi.y, drawn_hi.z])
			# Its blocking edges within 40 units: what would stop a walk here.
			var near_edges := PackedStringArray()
			var e := 0
			while e + 1 < placed.blocking.size():
				var p0: Vector2 = placed.blocking[e]
				var p1: Vector2 = placed.blocking[e + 1]
				e += 2
				if Geometry2D.get_closest_point_to_segment(Vector2(x, z), p0, p1).distance_to(Vector2(x, z)) <= 40.0:
					near_edges.append("(%.0f, %.0f)-(%.0f, %.0f)" % [p0.x, p0.y, p1.x, p1.y])
			print("      %d blocking edge(s), %d within 40: %s" % [placed.blocking.size() / 2, near_edges.size(), " ".join(near_edges)])
		var near_terrain := PackedStringArray()
		var t := 0
		while t + 1 < graph.terrain_blocking.size():
			var p0: Vector2 = graph.terrain_blocking[t]
			var p1: Vector2 = graph.terrain_blocking[t + 1]
			t += 2
			if Geometry2D.get_closest_point_to_segment(Vector2(x, z), p0, p1).distance_to(Vector2(x, z)) <= 40.0:
				near_terrain.append("(%.0f, %.0f)-(%.0f, %.0f)" % [p0.x, p0.y, p1.x, p1.y])
		print("   terrain blocking edges within 40: %s" % (" ".join(near_terrain) if not near_terrain.is_empty() else "none"))
		for oi in graph.objects:
			if considered.has(oi):
				continue
			var placed: NavGraph.PlacedObject = graph.objects[oi]
			if x < placed.bounds_min.x or x > placed.bounds_max.x or z < placed.bounds_min.y or z > placed.bounds_max.y:
				continue
			var h := NavGraph.surface_height_of(placed, x, z)
			print("   NOT indexed here, footprint holds it: object %d (%.0f, %.0f)-(%.0f, %.0f), surface here %s" % [
				oi, placed.bounds_min.x, placed.bounds_min.y, placed.bounds_max.x, placed.bounds_max.y,
				"none" if is_nan(h) else "%.1f" % h])

## Component-wise min and max; Godot 4.2's Vector3 has neither.
static func _vec_min(a: Vector3, b: Vector3) -> Vector3:
	return Vector3(minf(a.x, b.x), minf(a.y, b.y), minf(a.z, b.z))

static func _vec_max(a: Vector3, b: Vector3) -> Vector3:
	return Vector3(maxf(a.x, b.x), maxf(a.y, b.y), maxf(a.z, b.z))

func _qa_scan_report(samples: int) -> void:
	var pair := _nav_graph_for(player.global_position)
	if pair.is_empty():
		print("QA SCAN: not standing in any loaded region")
		return
	var graph: NavGraph = pair[0]
	var group: Node3D = pair[1]
	var space := get_viewport().world_3d.direct_space_state

	var step_span := REGION_SPAN / float(samples)
	var worst: Array = []
	var checked := 0
	var under := 0
	for iz in range(samples):
		for ix in range(samples):
			var lx := (ix + 0.5) * step_span
			var lz := (iz + 0.5) * step_span
			# Probe from a little over head height above where the graph
			# would stand a player, not from the sky: a ray dropped from
			# far above lands on a tree canopy or a roof, neither of which
			# says anything about the floor underfoot.
			var walkable := graph.height_at(lx, lz, 0.0)
			var head := walkable + _player_capsule_height() * 2.0
			var top := group.to_global(Vector3(lx, head, lz))
			var bottom := group.to_global(Vector3(lx, walkable - 1.0, lz))
			var query := PhysicsRayQueryParameters3D.create(top, bottom)
			query.collision_mask = 0xFFFFFFFF
			query.exclude = [player.get_rid()]
			var hit := space.intersect_ray(query)
			if hit.is_empty():
				continue
			checked += 1
			var solid_local := group.to_local(hit["position"] as Vector3)
			var drop := solid_local.y - walkable
			if drop <= STAND_UNDER_TOLERANCE:
				continue
			under += 1
			var collider = hit["collider"]
			var what := "?"
			if collider != null:
				var owner_node: Node = (collider as Node)
				while owner_node != null and not String(owner_node.name).begins_with("Obj_"):
					owner_node = owner_node.get_parent()
				what = String(owner_node.name) if owner_node != null else String((collider as Node).name)
			worst.append([drop, lx, lz, walkable, solid_local.y, what])

	worst.sort_custom(func(a, b): return a[0] > b[0])
	print("QA SCAN: %d of %d sampled spots put the player under the solid geometry there (%.0f-unit grid)" % [
		under, checked, step_span])
	for i in range(mini(worst.size(), 15)):
		print("QA SCAN   %6.1f under  local (%.0f, %.0f)  graph stands at %.1f, geometry at %.1f  %s" % [
			worst[i][0], worst[i][1], worst[i][2], worst[i][3], worst[i][4], worst[i][5]])

## Hides every mesh under a placed object whose own real mesh name
## contains one of the given fragments, and reports what it hid.
##
## A real object is assembled from several real .bms pieces (a gate is its
## walls, its roof, its stairs, its door), and when the assembled result
## looks wrong the question is always *which piece*. Rendering the pieces
## separately does not answer it, because a piece only means anything in
## the place the others put it. Switching one off in the built world does.
func _qa_hide_meshes(fragments: PackedStringArray) -> void:
	var hidden := 0
	var names := {}
	for group in get_children():
		if not String(group.name).begins_with("RealTerrain"):
			continue
		for container in (group as Node3D).get_children():
			if not String(container.name).begins_with("RealMapObjects"):
				continue
			for node in container.get_children():
				var stack: Array[Node] = [node]
				while not stack.is_empty():
					var current: Node = stack.pop_back()
					if current is MeshInstance3D:
						var lower := String(current.name).to_lower()
						for fragment in fragments:
							if fragment != "" and lower.contains(fragment.strip_edges().to_lower()):
								(current as MeshInstance3D).visible = false
								names[String(current.name)] = true
								hidden += 1
								break
					for child in current.get_children():
						stack.append(child)
	print("QA HIDE: hid %d real mesh instance(s), %d distinct name(s): %s" % [
		hidden, names.size(), names.keys()])

## Prints which real placed objects the camera is actually pointing at,
## nearest first: their real model name, how far away they are, and where
## they are placed in region-local coordinates.
##
## Exists because "what is that wall in front of me?" had no cheap answer.
## Placed objects carry no physics collision of their own -- movement uses
## the navigation graph, not the meshes -- so a physics raycast finds
## nothing, and a big model like a city gate has its origin hundreds of
## units from the piece of it you are standing in front of, which makes
## matching by placement coordinate alone actively misleading. This walks
## the real placed nodes instead and intersects the ray against each
## one's own visual bounds.
func _qa_look_report() -> void:
	var origin := camera_3d.global_position
	var direction := -camera_3d.global_transform.basis.z
	var pair := _nav_graph_for(player.global_position)
	if pair.is_empty():
		print("QA LOOK: not standing in any loaded region")
		return
	var group: Node3D = pair[1]

	# Only the region the player is standing in. Walking all 25 loaded
	# regions' object trees allocated enough to take the process down.
	var hits: Array = []
	for container in group.get_children():
		if not String(container.name).begins_with("RealMapObjects"):
			continue
		for node in container.get_children():
			var bounds := _visual_bounds(node as Node3D)
			if not bounds.has_volume():
				continue
			var hit = bounds.intersects_ray(origin, direction)
			if hit == null:
				continue
			hits.append([origin.distance_to(hit), String(node.name), (node as Node3D).position])
	hits.sort_custom(func(a, b): return a[0] < b[0])
	print("QA LOOK from %s facing %s -- %d real object(s) under the crosshair" % [
		origin.round(), direction.round(), hits.size()])
	for i in range(mini(hits.size(), 10)):
		print("QA LOOK   %7.1f away  %s  placed at local %s" % [
			hits[i][0], hits[i][1], (hits[i][2] as Vector3).round()])

	# Everything standing near the camera, whichever region it belongs to,
	# with the size of the geometry actually built for it. A ray answers
	# "what is directly ahead"; this answers "is there anything tall here
	# at all", which is the question when the thing in front of you turns
	# out not to be a placed object.
	var near: Array = []
	for other in get_children():
		if not String(other.name).begins_with("RealTerrain"):
			continue
		for container in (other as Node3D).get_children():
			if not String(container.name).begins_with("RealMapObjects"):
				continue
			for node in container.get_children():
				var node3d := node as Node3D
				var d := origin.distance_to(node3d.global_position)
				if d > 2500.0:
					continue
				var b := _visual_bounds(node3d)
				if not b.has_volume():
					continue
				near.append([d, String(node.name), String(other.name), b])
	# Tallest first: the thing being looked for is usually the big piece of
	# architecture, and sorting by distance buries it under scenery.
	near.sort_custom(func(a, b): return (a[3] as AABB).size.y > (b[3] as AABB).size.y)
	print("QA LOOK nearby: %d real object(s) within 2500, tallest first" % near.size())
	for i in range(mini(near.size(), 14)):
		var box: AABB = near[i][3]
		var group_node := get_node_or_null(NodePath(near[i][2])) as Node3D
		var lo := box.position
		var hi := box.position + box.size
		if group_node != null:
			lo = group_node.to_local(box.position)
			hi = group_node.to_local(box.position + box.size)
		print("QA LOOK   %7.1f  %-30s %-20s size %s  local %s .. %s" % [
			near[i][0], near[i][1], near[i][2], box.size.round(),
			lo.round(), hi.round()])

## One placed object's visual bounds in world space, merged over every
## mesh under it -- a real placed object is a tree of MeshInstance3Ds, not
## one mesh. Walks the tree with an explicit stack and merges in place, so
## reporting on a dense region does not allocate an array per object.
func _visual_bounds(node: Node3D) -> AABB:
	var merged := AABB()
	var seeded := false
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		if current is MeshInstance3D:
			var mesh_node := current as MeshInstance3D
			if mesh_node.mesh != null:
				var box: AABB = mesh_node.global_transform * mesh_node.get_aabb()
				if seeded:
					merged = merged.merge(box)
				else:
					merged = box
					seeded = true
		for child in current.get_children():
			stack.append(child)
	return merged

## Lifts the player over a real step they would otherwise walk straight
## into.
##
## Godot's CharacterBody3D does not climb ledges at all -- a vertical riser
## stops it outright -- so every real staircase in the world was
## unclimbable. Found in a real playtest at the real Jangan temple: the
## steps blocked movement outright while the sloped edges beside them could
## be finagled up, which is exactly this failure's signature.
##
## Only lifts when the move is genuinely blocked at foot level, there is
## headroom to rise, *and* the same move is clear one step higher -- so a
## real wall still stops the player rather than being walked up.
func _try_step_up(delta: float) -> void:
	if not player.is_on_floor():
		return
	var horizontal := Vector3(player.velocity.x, 0.0, player.velocity.z)
	if horizontal.length_squared() < 0.01:
		return
	var motion := horizontal * delta
	if not player.test_move(player.global_transform, motion):
		return # not blocked -- nothing to climb
	var step := Vector3.UP * (_player_capsule_height() * STEP_HEIGHT_FRACTION)
	if step.y <= 0.0 or player.test_move(player.global_transform, step):
		return # no headroom to rise
	if player.test_move(player.global_transform.translated(step), motion):
		return # still blocked a step up -- a real wall, not a step
	player.global_position += step

func _physics_process(delta: float) -> void:
	if _sky_dome != null:
		_sky_dome.global_position = player.global_position + Vector3(0.0, SKY_DOME_HEIGHT_ABOVE_PLAYER, 0.0)
		_cloud_uv_offset.x += CLOUD_DRIFT_UV_PER_SECOND * delta
		_sky_dome_material.set_shader_parameter("uv_offset", _cloud_uv_offset)
	if _sun_glow != null:
		_sun_glow.global_position = player.global_position + _sun_glow_offset

	var input_dir := Vector3.ZERO
	# Real, dedicated move_* actions (WASD + arrow keys both bound, see
	# project.godot) -- previously used Godot's built-in ui_left/ui_right/
	# ui_up/ui_down actions, which only bind arrow keys by default. That
	# silently left WASD non-functional in every real exported build (a
	# real playtest bug, 2026-08-26 -- see docs/WORLD_ISSUES.md) despite
	# every prior headless verification pass looking correct, since none
	# of those ever pressed a real W/A/S/D key.
	#
	# Not read at all while the player is typing: `Input.get_axis` polls the
	# raw key state, which a focused LineEdit does not affect, so every "w"
	# in a chat message also walked the character. Only the input is
	# suppressed -- gravity, region streaming and the position updates below
	# all still run, which an early return here would have skipped.
	var typing := _hud_chat != null and _hud_chat.is_typing()
	if typing:
		_has_move_target = false
	else:
		input_dir.x = Input.get_axis("move_left", "move_right")
		input_dir.z = Input.get_axis("move_forward", "move_back")
	var manual_input := input_dir.length() > 0.0
	# Holding the left button walks the character toward the cursor, refreshed
	# every frame so it follows the pointer while held. WASD still overrides.
	if _left_steering and not typing and not manual_input:
		_try_set_move_target(get_viewport().get_mouse_position())
	if manual_input:
		input_dir = input_dir.normalized()
		_has_move_target = false # manual movement always cancels a pending click-to-move
		# Relative to the camera, as in the original: W walks away from the
		# camera whichever way it has been orbited, not along a world axis.
		var yaw := deg_to_rad(camera_arm.rotation_degrees.y)
		var forward := Vector3(0.0, 0.0, 1.0).rotated(Vector3.UP, yaw)
		var right := forward.cross(Vector3.UP)
		var dir := (forward * -input_dir.z + right * input_dir.x).normalized()
		player.velocity.x = dir.x * MOVE_SPEED
		player.velocity.z = dir.z * MOVE_SPEED
		player.rotation.y = atan2(dir.x, dir.z)
	elif _has_move_target:
		var to_target := _move_target - player.position
		to_target.y = 0.0
		if to_target.length() <= MOVE_TARGET_STOP_DISTANCE:
			_has_move_target = false
			player.velocity.x = 0.0
			player.velocity.z = 0.0
		else:
			var dir := to_target.normalized()
			player.velocity.x = dir.x * MOVE_SPEED
			player.velocity.z = dir.z * MOVE_SPEED
			player.rotation.y = atan2(dir.x, dir.z)
	elif _qa_walk != "":
		# SRREVAMP_QA_WALK: walk on a fixed world heading, as a held key
		# would, so a render shows the run and the log the path.
		var ang := deg_to_rad(float(_qa_walk))
		player.velocity.x = sin(ang) * MOVE_SPEED
		player.velocity.z = cos(ang) * MOVE_SPEED
		player.rotation.y = ang
	else:
		player.velocity.x = 0.0
		player.velocity.z = 0.0

	var is_moving := manual_input or _has_move_target or _qa_walk != ""
	# The camera keeps whatever orbit it was given (see CAMERA_VIEW_FREE).
	# It used to swing back to the default yaw and pitch whenever the
	# character moved, and, hanging from the body, turned with every click.
	_follow_with_camera(delta)

	_qa_step()
	if not _move_on_nav_graph(delta):
		if not player.is_on_floor():
			player.velocity.y -= GRAVITY * delta
		else:
			player.velocity.y = 0.0
		_try_step_up(delta)
		player.move_and_slide()

	# CharacterBody3D.is_on_floor() was observed real, unreliable here (stays
	# false indefinitely for a character resting motionless since spawn, a
	# separate quirk not chased this round) -- a direct raycast is used
	# instead to tell "resting on real ground" from "still falling" for
	# _last_grounded_position's purposes.
	var ground_check := PhysicsRayQueryParameters3D.create(
		player.position + Vector3(0.0, 10.0, 0.0), player.position + Vector3(0.0, -3000.0, 0.0))
	ground_check.exclude = [player.get_rid()]
	ground_check.collision_mask = TERRAIN_ONLY_COLLISION_MASK
	var ground_hit := get_world_3d().direct_space_state.intersect_ray(ground_check)
	if not ground_hit.is_empty() and player.position.y - ground_hit.position.y < 20.0:
		_last_grounded_position = player.position
	elif player.position.y < WORLD_FLOOR_Y:
		# Fell into a real gap in the streamed region grid (see
		# WORLD_FLOOR_Y's doc comment) -- no terrain exists here at all, so
		# rather than let the player fall through an unbounded void, return
		# them to the last real ground they stood on.
		player.position = _last_grounded_position
		player.velocity = Vector3.ZERO
		_has_move_target = false

	_recover_if_below_terrain()

	_maybe_stream_regions()
	_process_stream_queue()
	_refresh_zone_label_position()
	_update_blob_shadow()

	_time_since_send += delta
	if _time_since_send >= MIN_SEND_INTERVAL and player.position.distance_to(_last_sent_pos) >= MIN_SEND_DISTANCE:
		NetClient.move_to(player.position.x, player.position.y, player.position.z)
		_last_sent_pos = player.position
		_time_since_send = 0.0

	# Smooths every other real entity toward its latest known position
	# instead of teleporting the instant an update arrives -- see
	# _other_body_targets' own doc comment for the real stutter this fixes.
	# OTHER_BODY_INTERPOLATION_SPEED is a real engineering choice (how
	# quickly a body catches up to its target each frame), not a claim
	# about real client behavior -- tuned so a body visually arrives at
	# its target well within one real MIN_SEND_INTERVAL period.
	for character_id in _other_body_targets:
		if not _other_bodies.has(character_id):
			continue
		var body: Node3D = _other_bodies[character_id]
		var target: Vector3 = _other_body_targets[character_id]
		# Still catching up to the last update means the player is on the
		# move; arrived means standing. The threshold is a fraction of the
		# body's own height, so a settled body does not flicker between the
		# two on the last inch of the lerp.
		_set_other_gait(character_id, body.position.distance_to(target) > OTHER_GAIT_THRESHOLD)
		body.position = body.position.lerp(target, minf(OTHER_BODY_INTERPOLATION_SPEED * delta, 1.0))

	if _real_skeleton != null and _real_skeleton_track.keyframes.size() > 1:
		_real_skeleton_time += delta
		var frame_idx := _real_skeleton_anim.key_index_at(_real_skeleton_time, true)
		Skeleton3DBuilder.apply_ban_keyframe(_real_skeleton, _real_skeleton_track, frame_idx)
		Skeleton3DBuilder.update_debug_visualization(_real_skeleton.get_node("DebugVisualization"), _real_skeleton)

	# RE-ENABLED (2026-08-28, see docs/WORLD_ISSUES.md's twenty-eighth round)
	# -- was disabled 2026-08-26 after a real playtest found the assembled
	# player body's limbs flying apart the instant this ran, root-caused to
	# Skeleton3DBuilder.build_skeleton3d using Basis.IDENTITY for every
	# bone's rest instead of its real .bsk bind rotation. That's now fixed
	# (see Skeleton3DBuilder's own top comment) and visually re-verified via
	# real rendered screenshots showing a coherent walking stride, not
	# exploded limbs -- safe to re-enable. Picks walk_anim/idle_anim (see
	# is_moving, computed above) the same way _real_skeleton's separate
	# dev-only demo path already picks its one fixed animation, using the
	# same BAN_FPS playback-rate engineering guess (not reverse-engineered
	# real timing).
	# **Disabled 2026-09-02** (see docs/WORLD_ISSUES.md's forty-eighth
	# round). Fixing CharacterAssembler.attach_rigid made the real
	# assembled character render correctly for the first time -- but only
	# in its real bind pose. With this real .ban playback driving the
	# skeleton it still comes out distorted (arms and legs splayed
	# outward), so `apply_ban_pose` has its own separate real bug. That
	# earlier "coherent walking stride" check only ever looked at a bare
	# skeleton's bone positions, never at real attached body meshes, which
	# is why it read as fine.
	#
	# **One hypothesis tested and disproven (2026-09-02)**: that real .ban
	# rotations are in the same global/world space this project already had
	# to convert out of for .bsk bind rotations (see
	# Skeleton3DBuilder.build_skeleton3d), and that applying them as *local*
	# pose rotations compounds error down the bone chain. Implemented the
	# global-to-parent-relative conversion and rendered it against real
	# data: the result is dramatically *worse* (the character scatters
	# completely, rather than merely splaying), so real .ban rotations are
	# not global-space and that is not the bug. The existing delta-against-
	# keyframe-0 approach is closer to correct than that alternative.
	# What the real encoding actually is remains genuinely unknown -- it
	# needs real evidence, not another guess.
	#
	# Left disabled rather than shipped visibly broken (same call this
	# project already made for the sky cloud dome), so the real character
	# renders correctly, just statically.
	# **Enabled 2026-09-08.** Two real bugs stood between this and a correct
	# character, and both were invisible in the bind pose: the skeleton's
	# root bone was given an identity rest instead of its own (see
	# Skeleton3DBuilder), and every paired body part was attached to the
	# wrong side's bone (see CharacterAssembler._attach_paired). With both
	# fixed the character stands correctly, arms at its sides, and moves
	# with the real animation.
	# NPCs and monsters, playing their own standing animations.
	_tick_idle_animations(delta)

	if _player_skeleton != null and _character_assets.has(_player_gender):
		# The game's default gait is a run -- `chinaman_fighter_runforward`
		# is the type-7 entry, and it is the one a held sword replaces with
		# its own (`_runforward_sword`) -- so moving plays the run of the
		# weapon's group and standing plays its town idle.
		var action: int
		if is_moving:
			action = BsrReader.AnimationEntry.TYPE_RUN
		elif _player_anim_time - _last_combat_time < COMBAT_STANCE_SECONDS:
			# Recently in combat: hold the battle stance rather than the town idle.
			action = BsrReader.AnimationEntry.TYPE_STAND_BATTLE
		else:
			action = BsrReader.AnimationEntry.TYPE_STAND
		var anim := _body_animation_for(_player_gender, action, _player_weapon_group)
		_player_anim_time += delta
		if _player_one_shot != null:
			var elapsed := _player_anim_time - _player_one_shot_start
			if elapsed >= _player_one_shot.duration_seconds():
				_player_one_shot = null
			else:
				Skeleton3DBuilder.apply_ban_pose_at(_player_skeleton, _player_one_shot, elapsed, false)
		if _player_one_shot == null and anim != null and not anim.bones.is_empty():
			var ref_track: BanReader.Bone = anim.bones[0]
			if not ref_track.keyframes.is_empty():
				# Pinnable, so the in-world pose can be held against the same
				# frame applied offline by check_ban_pose.gd -- which is how
				# the two were shown to agree exactly.
				var pinned := OS.get_environment("SRREVAMP_QA_ANIM_FRAME")
				if pinned != "" and pinned.is_valid_int():
					Skeleton3DBuilder.apply_ban_pose(_player_skeleton, anim, int(pinned) % ref_track.keyframes.size())
				else:
					# On the clip's own clock: every keyframe at the time the
					# file gives it, blended in between. See BAN_FORMAT.md --
					# a fixed 30 keyframes a second ran the idle five times
					# too fast.
					Skeleton3DBuilder.apply_ban_pose_at(_player_skeleton, anim, _player_anim_time, true)

func _spawn_or_update_other(character_id: int, char_name: String, pos: Vector3, equipped: Dictionary = {}, gender: String = DEFAULT_GENDER) -> void:
	if not equipped.is_empty():
		_other_equipped[character_id] = equipped
	if _other_bodies.has(character_id):
		# Sets the real interpolation *target* only -- see
		# _other_body_targets' own doc comment for why this replaced a
		# direct position snap.
		_other_body_targets[character_id] = pos
		return

	var body := Node3D.new()
	body.position = pos

	# The same body and the same dressing as the local player: their
	# Gender and every worn item's id come in the snapshot (see genderOf
	# and equippedItems in server/internal/session/world.go, both queried
	# live), and each item is drawn from its own model. Falls back to the
	# labeled placeholder capsule if the bodies never loaded.
	var skeleton := _build_assembled_character(equipped, gender)
	if skeleton != null:
		# Same 180deg front correction as the local player (see
		# _try_apply_real_player_character) -- the body's own front is -Z, and
		# the node points +Z where it moves/faces.
		skeleton.rotation.y = PI
		body.add_child(skeleton)
		# Another player stands in the town idle of the group their weapon
		# selects, and runs while their body is still catching up to a
		# position update (see _set_other_gait). Without this they stood
		# in the bind pose, arms out, which no character in the game does.
		var group := _weapon_group_for(equipped)
		_other_gaits[character_id] = {"skeleton": skeleton, "gender": gender, "group": group, "moving": false}
		var idle := _body_animation_for(gender, BsrReader.AnimationEntry.TYPE_STAND, group)
		var frames := _frame_count(idle)
		if frames > 1:
			_animated.append([skeleton, idle, frames, float(_animated.size()) * 0.37, true, _idle_anim_time, null])
	else:
		var mesh := MeshInstance3D.new()
		var capsule := CapsuleMesh.new()
		capsule.radius = 0.4 * PLAYER_SCALE_RATIO
		capsule.height = 1.8 * PLAYER_SCALE_RATIO
		mesh.mesh = capsule
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.9, 0.3, 0.3)
		mesh.material_override = mat
		mesh.position.y = 0.9 * PLAYER_SCALE_RATIO
		body.add_child(mesh)

	# The same plate as an NPC's -- fixed screen size, outlined, shown only
	# within range -- over the assembled body's own height.
	var top := _skeleton_top(skeleton) if skeleton != null else 1.8 * PLAYER_SCALE_RATIO
	body.add_child(_name_plate(char_name, top))

	other_entities.add_child(body)
	_other_bodies[character_id] = body
	_other_body_targets[character_id] = pos

func _on_entity_entered(snapshot: WorldNet.EntitySnapshot) -> void:
	_spawn_or_update_other(snapshot.character_id, snapshot.char_name, Vector3(snapshot.x, snapshot.y, snapshot.z), snapshot.equipped, snapshot.gender)
	_log_system("%s entered the zone." % snapshot.char_name)

func _on_entity_moved(moved: WorldNet.EntityMoved) -> void:
	if _other_bodies.has(moved.character_id):
		_other_body_targets[moved.character_id] = Vector3(moved.x, moved.y, moved.z)

func _on_entity_left(character_id: int) -> void:
	_other_gaits.erase(character_id)
	if _other_bodies.has(character_id):
		var body: Node3D = _other_bodies[character_id]
		var departing_name := "Someone"
		for child in body.get_children():
			if child is Label3D:
				departing_name = child.text
				break
		body.queue_free()
		_other_bodies.erase(character_id)
		_other_body_targets.erase(character_id)
		_log_system("%s left the zone." % departing_name)

func _on_disconnect_pressed() -> void:
	NetClient.disconnect_from_server()

## Sends a real OpChangeZone for whatever's typed in zone_input.
## _on_change_zone_result (connected in _ready()) handles the reply --
## success updates zone_label and reloads real terrain/objects for the new
## zone, failure is silently ignored here (no dedicated error UI for this
## yet, same honest scope as the rest of this scene's dev-facing controls).
## The region-local spot a zone change should land on, parsed out of the
## zone box's optional `@x,z` suffix and consumed by
## _on_change_zone_result once the new region has actually loaded. null
## means "wherever the server puts us", the original behavior.
var _pending_zone_local: Variant = null

## Splits what was typed into the zone box into the zone the server is
## asked for and an optional region-local spot to stand on afterwards:
## `97/168` keeps the server's own landing position, `97/168@1002,917`
## additionally walks the player to that spot in the new region.
##
## The suffix exists because the server has no map data at all (see
## ChangeZoneRequest in server/internal/session/world.go) -- it can only
## put an arriving player at one fixed position per zone, which in a
## region 1920 units across is rarely anywhere near what someone wanted to
## look at. Typing the coordinates the zone label already prints is the
## shortest path from "I want to see that" to standing there.
static func _split_zone_target(text: String) -> Dictionary:
	var at := text.find("@")
	if at < 0:
		return {"zone": text}
	var zone := text.substr(0, at).strip_edges()
	var parts := text.substr(at + 1).split(",")
	if parts.size() != 2:
		return {"zone": zone}
	var lx := parts[0].strip_edges()
	var lz := parts[1].strip_edges()
	if not lx.is_valid_float() or not lz.is_valid_float():
		return {"zone": zone}
	return {"zone": zone, "local": Vector2(float(lx), float(lz))}

## How far above the walkable graph's answer to look for a surface that is
## actually drawn there.
##
## The graph and the rendered world do not always agree: measured in Jangan
## town at local 985,1000, the graph reports terrain at -46.4 while the
## drawn surface is at -32.6, because the octagonal plaza is a placed object
## whose navigation mesh was never resolved into the graph. Standing on the
## graph's answer puts the player 13.8 units inside the plaza, which is what
## a zone change looked like.
##
## Bounded deliberately. An earlier probe cast from 200 units up and came
## back with 119.9 at one spot -- it had hit a gate roof, because
## TERRAIN_COLLISION_LAYER includes the default layer that map objects also
## use. Casting from just above the graph's answer finds the deck underfoot
## without finding the building over it.
const DRAWN_SURFACE_CLEARANCE := 30.0

## The height actually drawn at a region-local (x, z), if something is drawn
## within DRAWN_SURFACE_CLEARANCE of graph_height. Returns graph_height
## unchanged when nothing is, so a region whose graph and geometry agree is
## untouched.
func _drawn_surface_height(group: Node3D, local_x: float, local_z: float, graph_height: float) -> float:
	var space := get_world_3d().direct_space_state
	if space == null:
		return graph_height
	var top := group.to_global(Vector3(local_x, graph_height + DRAWN_SURFACE_CLEARANCE, local_z))
	var bottom := group.to_global(Vector3(local_x, graph_height - DRAWN_SURFACE_CLEARANCE, local_z))
	var query := PhysicsRayQueryParameters3D.create(top, bottom)
	query.collision_mask = TERRAIN_COLLISION_LAYER
	query.exclude = [player.get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return graph_height
	var drawn: float = group.to_local(hit.position).y
	# Only ever lift, never drop: dropping would undo the graph's own answer
	# in the cases it gets right, and the failure being fixed is always
	# "standing inside something".
	return maxf(graph_height, drawn)

## Stands the player at a region-local (x, z) in one loaded region cell,
## at whatever height the real walkable graph reports there -- the same
## real signal ordinary movement stands on, so this lands on a staircase
## or a bridge deck rather than in the terrain under it.
func _place_at_region_local(region_x: int, region_y: int, local_x: float, local_z: float) -> bool:
	var group := get_node_or_null("RealTerrain_%d_%d" % [region_x, region_y]) as Node3D
	if group == null:
		return false
	for pair in _region_nav_graphs:
		if pair[1] != group:
			continue
		var graph: NavGraph = pair[0]
		# Landing, not walking: someone placed into the world arrives from
		# above and comes to rest on the highest surface here.
		player.global_position = group.to_global(
			Vector3(local_x, graph.landing_height_at(local_x, local_z), local_z))
		player.velocity = Vector3.ZERO
		_last_sent_pos = player.position
		return true
	return false

## Moves the player to a zone's own landing spot (see ZONE_SPAWN_LOCAL) if
## one is known, once that zone's region has actually loaded. Zones with
## no entry keep the server's fixed spawn position.
func _place_at_zone_spawn(zone: String) -> bool:
	var region := _resolve_zone_region(zone)
	if not ZONE_SPAWN_LOCAL.has(region):
		return false
	var coords := _parse_region_coords(region)
	if coords.is_empty():
		return false
	var spot: Vector2 = ZONE_SPAWN_LOCAL[region]
	if not _place_at_region_local(coords["x"], coords["y"], spot.x, spot.y):
		return false
	_refresh_zone_label_position()
	return true

func _on_change_zone_pressed() -> void:
	var typed := zone_input.text.strip_edges()
	if typed == "":
		return
	var target := _split_zone_target(typed)
	var zone: String = target["zone"]
	if zone == "":
		return
	_pending_zone_local = target.get("local", null)
	NetClient.change_zone(zone)

## Chat panel, ported from the 2D World.gd HUD (see docs/PROGRESS.md) --
## this scene is becoming the one real client, so its UI needs to cover
## everything the 2D view used to.
func _on_chat_message(message: ChatNet.Message) -> void:
	if message == null:
		return
	if _hud_chat != null:
		_hud_chat.add_message(message.sender_name, message.message_text)
	chat_log.add_text("%s: %s\n" % [message.sender_name, message.message_text])

func _on_chat_whisper_message(message: ChatNet.Message) -> void:
	if message == null:
		return
	if _hud_chat != null:
		_hud_chat.add_whisper(message.sender_name, message.message_text)
	chat_log.add_text("[%s whispers]: %s\n" % [message.sender_name, message.message_text])

func _log_system(text: String) -> void:
	if _hud_chat != null:
		_hud_chat.add_message("", "* " + text)
	chat_log.add_text("* %s\n" % text)

## Toggles the whole hideable UI panel (character/zone labels, chat, action
## tabs, etc.) -- see HideUIButton's own doc-free scene node and the
## "toggle_ui" (F10) input action wired in _unhandled_input. HideUIButton
## itself lives outside ui_control (a sibling under the UI CanvasLayer, not
## a child of Control) specifically so it stays clickable to toggle the UI
## back on even while everything else is hidden.
## The developer chrome that has no authored equivalent yet: the zone travel
## box, Log Out, and the Hide UI button. Shown with F1.
const DEV_UI_NODES := ["ZoneInput", "ChangeZoneButton", "DisconnectButton"]
var _dev_ui_visible := true
## The F3 panel: build, server, position, entities, loading failures,
## frame times, and the sliders for UI scale, chat font and name range.
var _debug_panel: DebugPanel = null

func _set_dev_ui_visible(shown: bool) -> void:
	_dev_ui_visible = shown
	for path in DEV_UI_NODES:
		var node := ui_control.get_node_or_null(path)
		if node is CanvasItem:
			(node as CanvasItem).visible = shown
	if hide_ui_button != null:
		hide_ui_button.visible = shown

func _toggle_dev_ui() -> void:
	_set_dev_ui_visible(not _dev_ui_visible)
	_log_system("Developer tools %s" % ("shown" if _dev_ui_visible else "hidden"))

func _toggle_ui_visibility() -> void:
	ui_control.visible = not ui_control.visible
	hide_ui_button.text = "Show UI" if not ui_control.visible else "Hide UI"

## Toggles the tabbed panel holding inventory, equipment, skills, shop, party
## and the rest.
##
## It used to be a permanently visible strip spanning the full window width and
## 220 pixels tall, sitting directly above an equally full-width chat panel. A
## real headless render of the real Jangan spawn measured the two of them, plus
## the log-out row beneath, covering roughly 70% of the window -- the world was
## reduced to a letterbox strip along the top. Real Silkroad keeps inventory,
## skills and shop in windows the player opens and closes, and leaves the view
## itself clear, so the panel is now hidden until asked for. Chat stays visible
## (it is, as in the real client, a running log rather than a window) but is
## narrowed to the bottom-left corner instead of spanning the full width.
func _toggle_action_panels() -> void:
	action_tabs.visible = not action_tabs.visible

func _unhandled_input(event: InputEvent) -> void:
	# A direct keycode rather than an input action: this is a developer
	# toggle, not a control anyone plays with, and adding it to
	# project.godot would put it in the exported key list.
	if event is InputEventKey and (event as InputEventKey).pressed \
			and (event as InputEventKey).keycode == KEY_F1:
		_toggle_dev_ui()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and (event as InputEventKey).pressed \
			and (event as InputEventKey).keycode == KEY_F3 and _debug_panel != null:
		_debug_panel.toggle()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("toggle_ui"):
		_toggle_ui_visibility()

	if event.is_action_pressed("toggle_panels"):
		_toggle_action_panels()

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_right_button_held = event.pressed
		elif event.button_index == MOUSE_BUTTON_LEFT:
			# Either button orbits when dragged. A left press only becomes a
			# destination if it is released without having dragged, so a
			# look around does not also send the character somewhere.
			if event.pressed:
				_left_press_position = event.position
				_left_dragging = false
			elif not _left_dragging:
				# A click on an NPC talks to it, on a monster attacks it, and
				# anywhere else walks there -- the original's left-click scheme.
				if not _try_talk_to_npc(_left_press_position) \
						and not _try_attack_monster(_left_press_position):
					_try_set_move_target(_left_press_position)
			_left_button_held = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			camera_arm.spring_length = clampf(camera_arm.spring_length - CAMERA_ZOOM_STEP, CAMERA_ZOOM_MIN, CAMERA_ZOOM_MAX)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			camera_arm.spring_length = clampf(camera_arm.spring_length + CAMERA_ZOOM_STEP, CAMERA_ZOOM_MIN, CAMERA_ZOOM_MAX)
		# Only the right button orbits the camera. A held left button steers
		# the character toward the cursor instead (see _physics_process) --
		# the original never orbits on a left drag.
		_camera_orbiting = _right_button_held
		if not _left_button_held:
			_left_steering = false
	elif event is InputEventMouseMotion and _left_button_held and not _left_dragging \
			and (event as InputEventMouseMotion).position.distance_to(_left_press_position) > LEFT_DRAG_THRESHOLD_PIXELS:
		_left_dragging = true
		_left_steering = true
	elif event is InputEventMouseMotion and _camera_orbiting and _camera_view != CAMERA_VIEW_THIRD_PERSON:
		camera_arm.rotation_degrees.y -= event.relative.x * CAMERA_ORBIT_SENSITIVITY
		if _camera_view == CAMERA_VIEW_FREE:
			camera_arm.rotation_degrees.x = clampf(
				camera_arm.rotation_degrees.x - event.relative.y * CAMERA_ORBIT_SENSITIVITY,
				CAMERA_PITCH_MIN_DEGREES, CAMERA_PITCH_MAX_DEGREES)

## Real Silkroad-style click-to-move: raycasts from the camera through the
## real clicked screen position into the 3D world (real terrain/object
## collision -- both now real, solid bodies, see ObjectLoader's own real
## collision fix) and, on a hit, sets that as the player's real destination
## for _physics_process to walk toward every subsequent frame until reached
## or cancelled by manual WASD/arrow input.
## A click on an NPC opens the authored talk window titled with its name,
## the way the original does. Ray-tests the NPC layer only (the colliders
## _npc_collider puts on NAVMESH_WALL_COLLISION_LAYER); returns true when it
## opened a dialogue, so the caller does not also walk there. The holder the
## collider hangs under carries the NPC's name (set where it is placed).
func _try_talk_to_npc(screen_pos: Vector2) -> bool:
	if _hud_panels == null:
		return false
	var from := camera_3d.project_ray_origin(screen_pos)
	var dir := camera_3d.project_ray_normal(screen_pos)
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 2000.0)
	query.exclude = [player.get_rid()]
	query.collision_mask = NPC_COLLISION_LAYER
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return false
	var node := hit["collider"] as Node
	while node != null and not node.has_meta("npc_name"):
		node = node.get_parent()
	if node == null:
		return false
	var npc_name := str(node.get_meta("npc_name"))
	if npc_name == "":
		npc_name = "..."
	var code := str(node.get_meta("npc_code")) if node.has_meta("npc_code") else ""
	_talk_npc_name = npc_name
	_talk_npc_code = code
	_hud_panels.open_npc_talk(npc_name, _npc_greeting_text(code), _npc_services(code))
	return true

## The NPC's real greeting, resolved from npcchat.txt's SN_ id through the
## text table; "" when the NPC has none (the talk window then shows "...").
func _npc_greeting_text(code: String) -> String:
	if code == "" or _npc_text_table == null:
		return ""
	var pair: Array = _npc_greetings.get(code.to_upper(), [])
	for strid in pair:
		var s := str(strid)
		if s != "" and s != "xxx":
			var resolved := _npc_text_table.get_text(s)
			if resolved != "" and resolved != s:
				return resolved
	return ""

## The services the NPC offers (grounded detection; see NpcServiceReader), as
## Service objects (key + label) for the talk window's clickable options.
func _npc_services(code: String) -> Array:
	if code == "":
		return []
	return NpcServiceReader.services_for(code, _npc_shop_set)

## Acts on a service chosen in the talk box. Buy opens the NPC's real shop; the
## others (repair, storage, guild) are their own systems, still to come, so
## they say so rather than doing nothing silently.
func _on_npc_service_selected(key: String) -> void:
	match key:
		"shop":
			if _shop_reader != null and _talk_npc_code != "":
				_hud_panels.open_shop(_talk_npc_name, _shop_reader.tabs_for(_talk_npc_code))
		"storage":
			_hud_panels.open_storage(_talk_npc_name)
		_:
			_log_system("%s is not available yet." % key.capitalize())

func _try_set_move_target(screen_pos: Vector2) -> void:
	var from := camera_3d.project_ray_origin(screen_pos)
	var dir := camera_3d.project_ray_normal(screen_pos)
	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 2000.0)
	# Only the ground and placed objects can be a destination. Left to the
	# default mask the ray also hit the player's own capsule, the invisible
	# navmesh walls (NAVMESH_WALL_COLLISION_LAYER) and NPC capsules, and a
	# click across the plaza landed on the nearest of those instead -- "the
	# character does not move to the direction you click".
	query.exclude = [player.get_rid()]
	query.collision_mask = TERRAIN_COLLISION_LAYER
	var hit := space_state.intersect_ray(query)
	if hit.is_empty():
		return
	_move_target = hit["position"]
	_has_move_target = true

func _on_send_pressed() -> void:
	var text := chat_input.text.strip_edges()
	chat_input.text = ""
	_send_chat(text)

## The authored chat window's input line, which does the same thing.
func _on_chat_submitted(text: String) -> void:
	_send_chat(text)

func _send_chat(text: String) -> void:
	if text.is_empty():
		return

	if text.begins_with("/w "):
		var rest := text.substr(3)
		var space_index := rest.find(" ")
		if space_index == -1:
			_log_system("Usage: /w <name> <message>")
			return
		var target_name := rest.substr(0, space_index)
		var whisper_text := rest.substr(space_index + 1)
		NetClient.whisper(target_name, whisper_text)
		return

	if text == "/unstuck" or text == "/stuck":
		_unstuck_player()
		return

	NetClient.say(text)

## Frees a player wedged into geometry: teleports them back to the zone's own
## entry spawn (a known-open point the server placed them at) and clears any
## velocity. A stopgap until movement is navmesh-constrained -- free-physics
## movement lets the capsule wedge into a concave building corner. F1 zone
## travel does the same the heavy way; this stays in the zone. The move sync in
## _process sends the new position (it differs from _last_sent_pos).
func _unstuck_player() -> void:
	var result = NetClient.last_enter_world_result
	if result == null or not result.ok:
		_log_system("Unstuck: no spawn point known yet -- try F1 zone travel.")
		return
	player.velocity = Vector3.ZERO
	player.position = Vector3(result.x, result.y, result.z)
	_log_system("Unstuck: returned to the zone entry point.")

func _on_disconnected() -> void:
	get_tree().change_scene_to_file("res://scenes/Login.tscn")

# --- Monsters tab ---------------------------------------------------------

## Raycasts straight down (and up, to cover terrain that loaded after this
## was called) through pos's X/Z and returns the real surface height found,
## or pos.y unchanged if nothing was hit -- the same practical safety net
## _snap_player_onto_terrain uses for the player, reused here so monsters
## don't spawn embedded in or floating above the real terrain grid either.
func _terrain_height_at(pos: Vector3) -> float:
	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		pos + Vector3(0.0, 1000.0, 0.0),
		pos + Vector3(0.0, -1000.0, 0.0))
	query.collision_mask = TERRAIN_ONLY_COLLISION_MASK # see its own doc comment -- same "landed on a roof" bug applies to monster placement
	var hit := space_state.intersect_ray(query)
	if hit.is_empty():
		return pos.y
	return hit.position.y + 0.05 * PLAYER_SCALE_RATIO

## Creates or moves the real 3D body representing one live server-tracked
## monster (see CombatNet.MonsterSnapshot's real X/Y/Z -- this project's own
## placeholder spawn positions, not real per-monster coordinate data; see
## combat.Hub.Spawn). A plain colored capsule for now, same honest
## "placeholder until a real per-species model mapping exists" approach
## World3D already uses for other players before a real character loads --
## no real monster model/skeleton mapping has been found or attempted yet
## (a real next step, not this one).
## Superseded 2026-09-09. Two species were hand-wired here -- a golem and a
## scorpion -- each with its own skeleton path, mesh directory, piece list,
## material path, material layer and a hand-derived piece-to-bone table in
## MonsterAssembler. All of it is replaced by reading the species' own .bsr:
## it names its skeleton and mesh pieces, and the bone mapping is computed
## (SkinnedBsrAssembler). What was seven constants and a table per creature
## is now a name lookup that covers 642 species.

## Species -> model, built once from the player's own Media.pk2, two ways:
## {code name -> .bsr path} (`MOB_CH_MANGNYANG`, the row's own key, the same
## in every archive) and {lowercased display name -> .bsr path} for a
## server that sends no code. The code comes first: a display name is
## whatever language column an archive carries, and on one archive the
## name join drew a Mangyang as a treasure chest and a Weasel as nothing.
## See NpcTableReader.parse_models_by_code / parse_models_by_name.
var _monster_models_by_code: Dictionary = {}
var _monster_models_by_name: Dictionary = {}
var _monster_models_loaded := false
## The object name table as parsed from the player's archive, kept so the
## debug panel can show what language its columns yield.
var _object_name_table: UiTextTable = null

func _monster_model_path(code_name: String, species_name: String) -> String:
	if not _monster_models_loaded:
		_monster_models_loaded = true
		if _media_pk2 == null:
			_media_pk2 = _open_media_pk2_if_set()
		if _media_pk2 != null:
			var names_entry := ObjectLoader.find_file(_media_pk2, NpcTableReader.OBJECT_NAME_TABLE_PATH)
			var names: UiTextTable = null
			if names_entry != null:
				names = UiTextTable.parse(_media_pk2.read_file(names_entry))
			_object_name_table = names
			for path in NpcTableReader.MODEL_TABLE_PATHS:
				var entry := ObjectLoader.find_file(_media_pk2, path)
				if entry == null:
					continue
				var bytes := _media_pk2.read_file(entry)
				_monster_models_by_code = NpcTableReader.parse_models_by_code(bytes, _monster_models_by_code, "")
				if names != null:
					_monster_models_by_name = NpcTableReader.parse_models_by_name(bytes, names, _monster_models_by_name)
			print("World3D: %d species resolvable by code, %d by name" % [
				_monster_models_by_code.size(), _monster_models_by_name.size()])
	if code_name != "" and _monster_models_by_code.has(code_name):
		return _monster_models_by_code[code_name]
	return _monster_models_by_name.get(species_name.to_lower(), "")

func _spawn_or_update_monster(monster: CombatNet.MonsterSnapshot) -> void:
	_monster_snapshots[monster.monster_id] = monster
	var pos := Vector3(monster.x, monster.y, monster.z)
	pos.y = _terrain_height_at(pos)

	if _monster_bodies.has(monster.monster_id):
		var existing: Node3D = _monster_bodies[monster.monster_id]
		existing.position = pos
		var existing_label: Label3D = existing.get_node("Label")
		existing_label.text = monster.monster_name
		_set_hp_bar(existing, monster.hp, monster.max_hp)
		return

	var body := Node3D.new()
	body.position = pos

	# The species' own model, resolved from the real tables by the name the
	# server calls it. Nothing is hardcoded per creature: characterdata
	# carries each row's SN_ name key and its .bsr, textdata_object resolves
	# that key to a display name, and joining the two gives 642 species by
	# name. A species the tables do not know still gets the labelled capsule.
	#
	# This replaces two hand-built species (a golem and a scorpion), each
	# with its own skeleton path, mesh directory, piece list, material and a
	# hand-derived piece-to-bone table. All of that is superseded:
	# SkinnedBsrAssembler reads the .bsr's own skeleton and meshes, and
	# computes the bone mapping.
	var monster_skeleton: Skeleton3D = null
	var monster_model := _monster_model_path(monster.code_name, monster.monster_name)
	if monster_model != "":
		if _data_pk2 == null:
			_data_pk2 = _open_pk2_if_set()
		if _data_pk2 != null:
			var assembled := SkinnedBsrAssembler.assemble_from_archive(_data_pk2, monster_model, true)
			if assembled != null:
				monster_skeleton = assembled.skeleton
				_monster_assembled[monster.monster_id] = assembled
				_animate(assembled)
	# Says which of the three ways a monster can come out wrong happened:
	# the species not in the tables, the model not assembling, or a real
	# model placed somewhere the player will never be.
	print("World3D: monster %s (%s) -> model '%s' skeleton=%s at %.0f,%.0f,%.0f (%.0f from the player)" % [
		monster.monster_name, monster.code_name if monster.code_name != "" else "no code",
		monster_model, "yes" if monster_skeleton != null else "NO",
		pos.x, pos.y, pos.z, pos.distance_to(player.global_position)])

	# Real model height varies a lot by species/asset (real monster
	# skeletons are nowhere near the human PLAYER_SCALE_RATIO-derived
	# height, unscaled real native units) -- computed directly from the
	# real assembled skeleton's own bone bounds rather than reusing the
	# capsule-calibrated label offset, which would float the label wildly
	# too high (or low) above a real model of very different real size.
	var label_height := 2.0 * PLAYER_SCALE_RATIO
	if monster_skeleton != null:
		body.add_child(monster_skeleton)
		var max_y := 0.0
		for i in range(monster_skeleton.get_bone_count()):
			max_y = max(max_y, monster_skeleton.get_bone_global_pose(i).origin.y)
		label_height = max_y + max_y * 0.15
	else:
		var mesh := MeshInstance3D.new()
		var capsule := CapsuleMesh.new()
		capsule.radius = 0.5 * PLAYER_SCALE_RATIO
		capsule.height = 1.6 * PLAYER_SCALE_RATIO
		mesh.mesh = capsule
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.55, 0.15, 0.1) # dark red -- visually distinct from other players' capsules
		mesh.material_override = mat
		mesh.position.y = 0.8 * PLAYER_SCALE_RATIO
		body.add_child(mesh)

	var label := _name_plate(monster.monster_name,
		label_height / (1.0 + NAME_PLATE_CLEARANCE_FRACTION))
	label.name = "Label"
	body.add_child(label)
	# The HP bar sits just under the name, at the model's own top.
	var bar := _hp_bar(label_height * 0.9)
	body.add_child(bar)
	_set_hp_bar(body, monster.hp, monster.max_hp)
	# A clickable collider so a left click on the monster attacks it (see
	# _try_attack_monster), tagged with the id the attack is sent for.
	body.set_meta("monster_id", monster.monster_id)
	body.add_child(_monster_collider(label_height))

	other_entities.add_child(body)
	_monster_bodies[monster.monster_id] = body

## A click-target collider for a monster: a capsule as tall as the model,
## on the monster layer only, so a ray can pick it out for an attack while
## it neither blocks movement nor catches the ground-snap ray.
func _monster_collider(height: float) -> StaticBody3D:
	var shape := CapsuleShape3D.new()
	shape.height = maxf(height, 1.0)
	shape.radius = maxf(height * 0.3, 1.0)
	var sb := StaticBody3D.new()
	sb.name = "ClickBody"
	sb.collision_layer = MONSTER_COLLISION_LAYER
	sb.collision_mask = 0
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = Vector3(0.0, shape.height * 0.5, 0.0)
	sb.add_child(cs)
	return sb

## A left click on a monster attacks it, the way clicking one does in the
## original. Ray-tests the monster layer only; on a hit, targets that
## monster and sends the attack, returning true so the click does not also
## walk there.
func _try_attack_monster(screen_pos: Vector2) -> bool:
	if not NetClient.is_connected_to_server():
		return false
	var from := camera_3d.project_ray_origin(screen_pos)
	var dir := camera_3d.project_ray_normal(screen_pos)
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 2000.0)
	query.exclude = [player.get_rid()]
	query.collision_mask = MONSTER_COLLISION_LAYER
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return false
	var node := hit["collider"] as Node
	while node != null and not node.has_meta("monster_id"):
		node = node.get_parent()
	if node == null:
		return false
	_last_attack_target = int(node.get_meta("monster_id"))
	_show_target(_last_attack_target)
	NetClient.attack(NetClient.current_character_name, _last_attack_target)
	return true

## Reconciles _monster_bodies against live, the authoritative full monster
## list for the player's current zone (see _on_monster_list_result) --
## creates/updates a body for everything in live, removes any tracked body
## no longer present (dead, or the player changed zones), the same
## snapshot-driven approach world.Hub's own zone-change teardown uses rather
## than trying to diff individual damaged/died events.
func _sync_monster_bodies(live: Array) -> void:
	var live_ids := {}
	for m in live:
		live_ids[m.monster_id] = true
		_spawn_or_update_monster(m)

	for monster_id in _monster_bodies.keys():
		if not live_ids.has(monster_id):
			# A monster still playing its death is left where it fell
			# until the animation has run; the timer _on_monster_died set
			# asks for another list then, and this removes it.
			if _dying_until.has(monster_id) and _idle_anim_time < float(_dying_until[monster_id]):
				continue
			_monster_bodies[monster_id].queue_free()
			_monster_bodies.erase(monster_id)
			_monster_assembled.erase(monster_id)
			_dying_until.erase(monster_id)

func _on_monster_list_result(monsters: Array, error: String) -> void:
	if error != "":
		monster_status_label.text = "Error: %s" % error
		push_warning("World3D: monster list refused: %s" % error)
		return
	print("World3D: server reports %d monster(s)" % monsters.size())
	for m in monsters:
		print("  %s at %.0f, %.0f, %.0f (%d/%d hp)" % [
			m.monster_name, m.x, m.y, m.z, m.hp, m.max_hp])
	_monsters.assign(monsters)
	monster_list.clear()
	for m in _monsters:
		monster_list.add_item("%s (HP %d/%d)" % [m.monster_name, m.hp, m.max_hp])
	_sync_monster_bodies(_monsters)

func _on_attack_pressed() -> void:
	var selected := monster_list.get_selected_items()
	if selected.is_empty():
		monster_status_label.text = "Select a monster first."
		return
	var target: CombatNet.MonsterSnapshot = _monsters[selected[0]]
	_last_attack_target = target.monster_id
	_show_target(target.monster_id)
	NetClient.attack(NetClient.current_character_name, target.monster_id)

func _on_attack_result(result: CombatNet.AttackResult) -> void:
	if result == null:
		return
	if result.error != "":
		monster_status_label.text = "Attack failed: %s" % result.error
		print("World3D: attack refused: %s" % result.error)
		return
	# One line per exchange, so a render's log says what the fight did
	# without reading it off a label.
	print("World3D: attack hit for %d (%d left%s), took %d (HP %d)" % [
		result.monster_damage, result.monster_remaining_hp,
		", died" if result.monster_died else "", result.player_damage_taken, result.player_hp])
	# A combat exchange keeps the player in the battle stance while idle.
	_last_combat_time = _player_anim_time
	# The player's swing: the next plain attack in the weapon group's
	# chain, once. Its hit event says when the blow lands, and that is
	# when the monster's own hit reaction plays.
	var swing_type: int = ATTACK_SEQUENCE[_attack_step % ATTACK_SEQUENCE.size()]
	_attack_step += 1
	var swing_entry := _body_animation_entry(_player_gender, swing_type, _player_weapon_group)
	if swing_entry == null:
		swing_entry = _body_animation_entry(_player_gender, BsrReader.AnimationEntry.TYPE_ATTACK, _player_weapon_group)
	var lands_after := 0.0
	if swing_entry != null:
		var swing := _body_animation_for(_player_gender, swing_entry.action_type, _player_weapon_group)
		if swing != null:
			_play_player_once(swing)
		var hit_ms := swing_entry.first_event_time(BsrReader.AnimationEntry.EVENT_HIT)
		lands_after = float(hit_ms) / 1000.0 if hit_ms > 0 else 0.0
	# The monster this result is about: attack results carry no monster id,
	# so it is the target the attack was sent for. Captured now because a
	# killing blow may clear _last_attack_target before the blow lands, and
	# the floating damage number still has to appear over the dying body.
	var damage_target := _last_attack_target
	# A skill cast (not a plain attack) plays that skill's own hit effect on the
	# target when the blow lands. Consumed here so the next plain attack doesn't
	# inherit it.
	var skill_hit_code := _pending_skill_hit_code
	_pending_skill_hit_code = ""
	if _last_attack_target != -1:
		var dealt := result.monster_damage
		_after(lands_after, func() -> void:
			# _last_attack_target (not the captured id) so a monster that died
			# in the meantime keeps its die animation instead of a hit reaction.
			_play_monster_action(_last_attack_target, BsrReader.AnimationEntry.TYPE_HIT)
			var hit_body = _monster_bodies.get(damage_target)
			if hit_body != null and is_instance_valid(hit_body):
				_floating_damage(hit_body, _monster_text_height(damage_target), dealt, DAMAGE_DEALT_COLOUR)
				if skill_hit_code != "":
					_play_skill_hit_effect_on(hit_body, _monster_text_height(damage_target), skill_hit_code))
	if result.player_damage_taken > 0 and _player_skeleton != null:
		# The monster strikes back: its own attack, and the player's hit
		# reaction (type 3) when that swing's hit event falls.
		var strike_after := 0.0
		if _last_attack_target != -1:
			var assembled: SkinnedBsrAssembler.AssembledCharacter = _monster_assembled.get(_last_attack_target)
			if assembled != null and assembled.parsed != null:
				var strike := assembled.parsed.animation_entry_for(BsrReader.AnimationEntry.TYPE_ATTACK)
				if strike != null:
					var ms := strike.first_event_time(BsrReader.AnimationEntry.EVENT_HIT)
					strike_after = float(ms) / 1000.0 if ms > 0 else 0.0
			_after(lands_after, func() -> void:
				_play_monster_action(_last_attack_target, BsrReader.AnimationEntry.TYPE_ATTACK))
		_after(lands_after + strike_after, func() -> void:
			var hit := _body_animation_for(_player_gender, BsrReader.AnimationEntry.TYPE_HIT, _player_weapon_group)
			if hit != null:
				_player_one_shot_until = _player_anim_time + _play_player_once(hit)
			# The damage the player took, over the player's own head (human
			# head height from the same PLAYER_SCALE_RATIO calibration the
			# monster fallback uses), timed to when the counter-blow lands.
			_floating_damage(player, 2.0 * PLAYER_SCALE_RATIO, result.player_damage_taken, DAMAGE_TAKEN_COLOUR))
	if result.monster_died:
		monster_status_label.text = "Hit for %d -- it died!" % result.monster_damage
		# A kill may have progressed a quest's kill count even without
		# completing it (OpQuestCompleted only fires on completion), so
		# refresh here rather than only on _on_quest_completed.
		NetClient.list_quests(NetClient.current_character_name)
	else:
		monster_status_label.text = "Hit for %d (%d HP left). Took %d damage (HP %d)." % [
			result.monster_damage, result.monster_remaining_hp, result.player_damage_taken, result.player_hp
		]
	NetClient.list_monsters()
	# OpUseSkill's response reuses this same OpAttackResult (see
	# SkillNet's doc comment) -- refresh here too so a just-used skill's
	# updated cooldown shows up in the Skills tab. Harmless no-op extra
	# traffic for a plain (non-skill) attack, same tradeoff the quest
	# refresh above already makes.
	NetClient.list_skills(NetClient.current_character_name)

func _on_monster_damaged(damaged: CombatNet.MonsterDamaged) -> void:
	# Someone else's hit on a monster: play its reaction now. The local
	# player's own hits are timed to the swing in _on_attack_result.
	if damaged != null and damaged.monster_id != _last_attack_target:
		_play_monster_action(damaged.monster_id, BsrReader.AnimationEntry.TYPE_HIT)
	# Shrink the HP bar at once, before the list round-trip, so it tracks
	# each hit. The max comes from the last snapshot of this monster.
	if damaged != null and _monster_bodies.has(damaged.monster_id):
		var snap = _monster_snapshots.get(damaged.monster_id)
		var max_hp: int = snap.max_hp if snap != null else damaged.remaining_hp
		_set_hp_bar(_monster_bodies[damaged.monster_id], damaged.remaining_hp, max_hp)
		if damaged.monster_id == _last_attack_target:
			_set_target_hp(damaged.remaining_hp, max_hp)
	NetClient.list_monsters()

## Runs `what` after `seconds` of scene time -- at once when zero.
func _after(seconds: float, what: Callable) -> void:
	if seconds <= 0.0:
		what.call()
		return
	get_tree().create_timer(seconds).timeout.connect(what)

## A monster's death plays its own die animation (type 4 of its `default`
## group) and the body stays on its last frame until that has run; only
## then is the list refreshed and the body removed.
func _on_monster_died(monster_id: int) -> void:
	if monster_id == _last_attack_target:
		_clear_target()
		_last_attack_target = -1
	var seconds := _play_monster_action(monster_id, BsrReader.AnimationEntry.TYPE_DIE, true)
	if seconds > 0.0:
		_dying_until[monster_id] = _idle_anim_time + seconds
		get_tree().create_timer(seconds).timeout.connect(NetClient.list_monsters)
	NetClient.list_monsters()

## The player has advanced a level (server's OpLevelUp, only ever sent to
## the character that levelled). Announces it with the client's own recovered
## message and plays the real level-up burst on the player.
##
## stat_points is the character's total unspent points now (3 per level, see
## docs/LEVELING.md); the character window reads it when opened, so this
## handler does not need to push it anywhere -- it is here so the signal's
## full payload is on record at the call site.
func _on_level_up(new_level: int, _stat_points: int) -> void:
	var msg := "You have advanced to level %d." % new_level
	if _ui_text_table != null:
		# The real string is UIIT_MSG_STRGERR_LEVEL "You have advanced to
		# level [%d]." -- recovered from textuisystem.txt. Substitute the
		# level into its own placeholder rather than hardcoding the English.
		var template := _ui_text_table.get_text("UIIT_MSG_STRGERR_LEVEL", "")
		if template != "":
			msg = template.replace("[%d]", str(new_level))
	_log_system(msg)
	_play_level_up_effect()

## Spawns the real level-up burst on the player, sized to the player's own
## rendered height. Does nothing (beyond the message already logged) when the
## player has no Particles.pk2 -- no fabricated stand-in.
func _play_level_up_effect() -> void:
	if player == null or not is_instance_valid(player):
		return
	var particles := _open_particles_pk2_if_set()
	if particles == null:
		return
	var fx := LevelUpEffect.create(particles, _player_world_height())
	if fx == null:
		return
	player.add_child(fx)

## Plays a specific skill's own hit effect on a body: looks up the skill's hit
## `.efp` in skilleffect.txt (by Basic_Code) and plays it, falling back to the
## generic critical-hit burst if the skill has no mapped effect.
func _play_skill_hit_effect_on(body: Node3D, world_height: float, basic_code: String) -> void:
	if body == null or not is_instance_valid(body):
		return
	var particles := _open_particles_pk2_if_set()
	if particles == null:
		return
	var efp := SkillEffectReader.hit_efp_for(_skill_effects(), basic_code)
	var fx: HitEffect = null
	if efp != "":
		fx = HitEffect.create_from_efp(particles, efp, world_height)
	if fx == null:
		fx = HitEffect.create(particles, world_height)
	if fx == null:
		return
	fx.position = Vector3(0, world_height * 0.5, 0)
	body.add_child(fx)

## skilleffect.txt parsed once (from the player's own Media.pk2): Basic_Code ->
## hit `.efp`. Empty when the archive has no table.
func _skill_effects() -> Dictionary:
	if _skill_hit_efp_loaded:
		return _skill_hit_efp
	_skill_hit_efp_loaded = true
	if _media_pk2 != null:
		var bytes := AssetSource.read_bytes(SkillEffectReader.TABLE, _media_pk2)
		if not bytes.is_empty():
			_skill_hit_efp = SkillEffectReader.parse(bytes)
			print("World3D: skilleffect.txt -> %d skill hit effects" % _skill_hit_efp.size())
	return _skill_hit_efp

## The player's rendered height in world units -- measured from the assembled
## skeleton when one is up, else the file's standing yardstick (a character is
## about 2 * PLAYER_SCALE_RATIO tall, the same one the floating-text heights
## use).
func _player_world_height() -> float:
	if _player_skeleton != null and is_instance_valid(_player_skeleton):
		var h := _skeleton_top(_player_skeleton) * _player_skeleton.scale.y
		if h > 0.1:
			return h
	return 2.0 * PLAYER_SCALE_RATIO

## Plays one of a monster's own animations by action type, once. Returns
## its length in seconds, 0 if the monster has no such animation.
func _play_monster_action(monster_id: int, action_type: int, hold: bool = false) -> float:
	var assembled: SkinnedBsrAssembler.AssembledCharacter = _monster_assembled.get(monster_id)
	if assembled == null or _data_pk2 == null:
		return 0.0
	var anim := SkinnedBsrAssembler.animation_for(_data_pk2, assembled, action_type)
	if anim == null:
		return 0.0
	return _play_once(assembled.skeleton, anim, hold)

func _on_loot_dropped(dropped: CombatNet.LootDropped) -> void:
	if dropped == null:
		return
	for d in dropped.drops:
		_log_system("Looted %dx item #%d." % [d.quantity, d.item_id])
	NetClient.list_inventory(NetClient.current_character_name)

# --- Inventory tab ---------------------------------------------------------

func _on_inventory_list_result(slots: Array, error: String) -> void:
	if error != "":
		inventory_status_label.text = "Error: %s" % error
		return
	_inventory_slots.assign(slots)
	inventory_list.clear()
	for s in _inventory_slots:
		inventory_list.add_item("Slot %d: item #%d x%d" % [s.slot_index, s.item_id, s.quantity])

func _on_equip_pressed(slot: int) -> void:
	var selected := inventory_list.get_selected_items()
	if selected.is_empty():
		inventory_status_label.text = "Select an item first."
		return
	var chosen: InventoryNet.Slot = _inventory_slots[selected[0]]
	_awaiting_equip_ack = true
	NetClient.equip(NetClient.current_character_name, slot, chosen.slot_index)

# --- Equipment tab ---------------------------------------------------------

func _on_equipment_result(items: Array, error: String) -> void:
	if error != "":
		equipment_status_label.text = "Error: %s" % error
		_awaiting_equip_ack = false
		return

	if _awaiting_equip_ack:
		# This empty-items response is the equip/unequip ack, not a real
		# "nothing equipped" list -- re-request the real list, and refresh
		# inventory since equip/unequip moves an item between the two.
		_awaiting_equip_ack = false
		equipment_status_label.text = "Equipment updated."
		NetClient.list_equipment(NetClient.current_character_name)
		NetClient.list_inventory(NetClient.current_character_name)
		return

	equipment_list.clear()
	for e in items:
		var slot_name: String = "Weapon" if e.slot == EquipmentNet.SLOT_WEAPON else ARMOR_SLOT_LABELS.get(e.slot, "Slot %d" % e.slot)
		equipment_list.add_item("%s: item #%d" % [slot_name, e.item_id])

func _on_unequip_pressed(slot: int) -> void:
	_awaiting_equip_ack = true
	NetClient.unequip(NetClient.current_character_name, slot)

# --- Quests tab --------------------------------------------------------

func _on_quest_list_result(entries: Array, error: String) -> void:
	if error != "":
		quest_status_label.text = "Error: %s" % error
		return
	_quests.assign(entries)
	quest_list.clear()
	for q in _quests:
		var state := "completed" if q.completed else ("accepted" if q.accepted else "available")
		quest_list.add_item("%s: kill %s (%d/%d) for %dg [%s]" % [
			q.quest_name, q.monster_name, q.kills, q.target_kills, q.gold_reward, state
		])

func _on_quest_accept_pressed() -> void:
	var selected := quest_list.get_selected_items()
	if selected.is_empty():
		quest_status_label.text = "Select a quest first."
		return
	var chosen: QuestNet.Entry = _quests[selected[0]]
	NetClient.accept_quest(NetClient.current_character_name, chosen.quest_id)

func _on_quest_accept_result(ok: bool, reason: String) -> void:
	quest_status_label.text = "Quest accepted." if ok else "Accept failed: %s" % reason
	NetClient.list_quests(NetClient.current_character_name)

func _on_quest_completed(completed: QuestNet.Completed) -> void:
	if completed == null:
		return
	_log_system("Quest complete! +%dg" % completed.gold_reward)
	NetClient.list_quests(NetClient.current_character_name)

# --- Skills tab ------------------------------------------------------------

func _on_skill_list_result(skills: Array, error: String) -> void:
	if error != "":
		skill_status_label.text = "Error: %s" % error
		return
	_skills.assign(skills)
	skill_list.clear()
	for s in _skills:
		var state: String
		if not s.known:
			state = "not learned"
		elif s.ready_seconds > 0:
			state = "cooldown %ds" % s.ready_seconds
		else:
			state = "ready"
		skill_list.add_item("%s (+%d dmg, %ds cooldown) [%s]" % [s.skill_name, s.damage_bonus, s.cooldown_seconds, state])

func _on_skill_learn_pressed() -> void:
	var selected := skill_list.get_selected_items()
	if selected.is_empty():
		skill_status_label.text = "Select a skill first."
		return
	var chosen: SkillNet.SkillSnapshot = _skills[selected[0]]
	NetClient.learn_skill(NetClient.current_character_name, chosen.skill_id)

func _on_learn_skill_result(ok: bool, reason: String) -> void:
	skill_status_label.text = "Skill learned." if ok else "Learn failed: %s" % reason
	NetClient.list_skills(NetClient.current_character_name)

## Uses the selected skill on whichever monster is currently selected in the
## Monsters tab -- reuses that tab's own selection/target list rather than
## duplicating a second monster picker just for skills.
func _on_skill_use_pressed() -> void:
	var selected := skill_list.get_selected_items()
	if selected.is_empty():
		skill_status_label.text = "Select a skill first."
		return
	var target_selected := monster_list.get_selected_items()
	if target_selected.is_empty():
		skill_status_label.text = "Select a target in the Monsters tab first."
		return
	var chosen: SkillNet.SkillSnapshot = _skills[selected[0]]
	var target: CombatNet.MonsterSnapshot = _monsters[target_selected[0]]
	NetClient.use_skill(NetClient.current_character_name, chosen.skill_id, target.monster_id)

# --- Shop tab ------------------------------------------------------------

func _on_shop_list_result(entries: Array, error: String) -> void:
	if error != "":
		shop_status_label.text = "Error: %s" % error
		return
	_shop_entries.assign(entries)
	shop_list.clear()
	for e in _shop_entries:
		shop_list.add_item("Item #%d (class %d, atk %.1f/def %.1f) -- %dg" % [
			e.item_id, e.item_class, e.phys_attack_max, e.phys_defense_max, e.price
		])

func _on_shop_buy_pressed() -> void:
	var selected := shop_list.get_selected_items()
	if selected.is_empty():
		shop_status_label.text = "Select an item first."
		return
	var chosen: ShopNet.CatalogEntry = _shop_entries[selected[0]]
	NetClient.shop_buy(NetClient.current_character_name, chosen.item_id, 1)

func _on_shop_buy_result(ok: bool, reason: String) -> void:
	shop_status_label.text = "Purchased." if ok else "Purchase failed: %s" % reason
	if ok:
		NetClient.list_inventory(NetClient.current_character_name)

# --- Party tab -------------------------------------------------------------

func _refresh_party_list(result: PartyNet.Result) -> void:
	party_list.clear()
	for m in result.members:
		party_list.add_item(m.member_name)

func _on_party_result(result: PartyNet.Result) -> void:
	if result == null:
		return
	if result.error != "":
		party_status_label.text = "Error: %s" % result.error
		return
	if result.party_id == 0:
		party_status_label.text = "Not in a party."
		party_list.clear()
		return
	party_status_label.text = "Party #%d (%d member(s))." % [result.party_id, result.members.size()]
	_refresh_party_list(result)

func _on_party_join_pressed() -> void:
	var id_text := party_join_id_input.text.strip_edges()
	if not id_text.is_valid_int():
		party_status_label.text = "Enter a numeric party ID."
		return
	NetClient.join_party(NetClient.current_character_name, id_text.to_int())

func _on_party_leave_result(ok: bool, reason: String) -> void:
	if ok:
		party_status_label.text = "Left the party."
		party_list.clear()
	else:
		party_status_label.text = "Leave failed: %s" % reason

func _on_party_member_joined(member: PartyNet.MemberJoined) -> void:
	if member == null:
		return
	_log_system("%s joined your party." % member.member_name)
	NetClient.party_info(NetClient.current_character_name)

func _on_party_member_left(character_id: int) -> void:
	_log_system("A party member left (character #%d)." % character_id)
	NetClient.party_info(NetClient.current_character_name)

# --- Guild tab -------------------------------------------------------------

func _refresh_guild_list(result: GuildNet.Result) -> void:
	guild_list.clear()
	for m in result.members:
		var role_name := "Leader" if m.role == GuildNet.ROLE_LEADER else "Member"
		guild_list.add_item("%s [%s]" % [m.member_name, role_name])

func _on_guild_result(result: GuildNet.Result) -> void:
	if result == null:
		return
	if result.error != "":
		guild_status_label.text = "Error: %s" % result.error
		return
	if result.guild_id == 0:
		guild_status_label.text = "Not in a guild."
		guild_list.clear()
		return
	guild_status_label.text = "%s (#%d, %d member(s))." % [result.guild_name, result.guild_id, result.members.size()]
	_refresh_guild_list(result)

func _on_guild_create_pressed() -> void:
	var guild_name := guild_name_input.text.strip_edges()
	if guild_name.is_empty():
		guild_status_label.text = "Enter a guild name first."
		return
	NetClient.create_guild(NetClient.current_character_name, guild_name)

func _on_guild_join_pressed() -> void:
	var id_text := guild_join_id_input.text.strip_edges()
	if not id_text.is_valid_int():
		guild_status_label.text = "Enter a numeric guild ID."
		return
	NetClient.join_guild(NetClient.current_character_name, id_text.to_int())

func _on_guild_leave_result(ok: bool, reason: String) -> void:
	if ok:
		guild_status_label.text = "Left the guild."
		guild_list.clear()
	else:
		guild_status_label.text = "Leave failed: %s" % reason

# --- Duel tab --------------------------------------------------------------

func _on_duel_challenge_pressed() -> void:
	var target := duel_target_input.text.strip_edges()
	if target.is_empty():
		duel_status_label.text = "Enter a target name first."
		return
	NetClient.duel_challenge(NetClient.current_character_name, target)

func _on_duel_challenge_result(ok: bool, reason: String) -> void:
	duel_status_label.text = "Challenge sent." if ok else "Challenge failed: %s" % reason

func _on_duel_invite(invite: DuelNet.Invite) -> void:
	if invite == null:
		return
	_pending_duel_challenger = invite.challenger_name
	duel_invite_label.text = "%s challenges you to a duel!" % invite.challenger_name

func _on_duel_respond_pressed(accept: bool) -> void:
	if _pending_duel_challenger.is_empty():
		duel_status_label.text = "No pending challenge to respond to."
		return
	NetClient.duel_respond(NetClient.current_character_name, _pending_duel_challenger, accept)
	_pending_duel_challenger = ""
	duel_invite_label.text = "(no pending challenge)"

func _on_duel_respond_result(ok: bool, reason: String) -> void:
	if not ok:
		duel_status_label.text = "Respond failed: %s" % reason

func _on_duel_started(started: DuelNet.Started) -> void:
	if started == null:
		return
	duel_status_label.text = "Dueling %s! Attack away." % started.opponent_name

func _on_duel_declined(declined: DuelNet.Declined) -> void:
	if declined == null:
		return
	duel_status_label.text = "%s declined your challenge." % declined.target_name

func _on_duel_attack_result(result: DuelNet.AttackResult) -> void:
	if result == null:
		return
	if result.error != "":
		duel_status_label.text = "Attack failed: %s" % result.error
		return
	if result.opponent_died:
		duel_status_label.text = "Hit for %d -- you won!" % result.damage
	else:
		duel_status_label.text = "Hit for %d (opponent HP %d)." % [result.damage, result.opponent_hp]

func _on_duel_opponent_damaged(damaged: DuelNet.OpponentDamaged) -> void:
	if damaged == null:
		return
	duel_status_label.text = "Took %d damage (HP %d)." % [damaged.damage, damaged.remaining_hp]

func _on_duel_ended(ended: DuelNet.Ended) -> void:
	if ended == null:
		return
	duel_status_label.text = "Duel over -- %s won." % ended.winner_name

# --- Trade tab ---------------------------------------------------------

func _on_trade_request_pressed() -> void:
	var target := trade_target_input.text.strip_edges()
	if target.is_empty():
		trade_status_label.text = "Enter a target name first."
		return
	NetClient.trade_request(NetClient.current_character_name, target)

func _on_trade_request_result(ok: bool, reason: String) -> void:
	trade_status_label.text = "Trade request sent." if ok else "Request failed: %s" % reason

func _on_trade_invite(invite: TradeNet.Invite) -> void:
	if invite == null:
		return
	_pending_trade_requester = invite.requester_name
	trade_invite_label.text = "%s wants to trade with you!" % invite.requester_name

func _on_trade_respond_pressed(accept: bool) -> void:
	if _pending_trade_requester.is_empty():
		trade_status_label.text = "No pending request to respond to."
		return
	NetClient.trade_respond(NetClient.current_character_name, _pending_trade_requester, accept)
	_pending_trade_requester = ""
	trade_invite_label.text = "(no pending request)"

func _on_trade_respond_result(ok: bool, reason: String) -> void:
	if not ok:
		trade_status_label.text = "Respond failed: %s" % reason

func _on_trade_started(started: TradeNet.Started) -> void:
	if started == null:
		return
	trade_status_label.text = "Trading with %s. Set your offer below." % started.partner_name
	trade_their_offer_label.text = "Their offer: (none yet)"

func _on_trade_declined(declined: TradeNet.Declined) -> void:
	if declined == null:
		return
	trade_status_label.text = "%s declined your trade request." % declined.target_name

func _on_trade_set_offer_pressed() -> void:
	var gold_text := trade_gold_input.text.strip_edges()
	var slot_text := trade_item_slot_input.text.strip_edges()
	var qty_text := trade_quantity_input.text.strip_edges()
	var gold := int(gold_text) if gold_text.is_valid_int() else 0
	var item_slot := int(slot_text) if slot_text.is_valid_int() else TradeNet.ITEM_SLOT_NONE
	var quantity := int(qty_text) if qty_text.is_valid_int() else 0
	NetClient.trade_set_offer(NetClient.current_character_name, gold, item_slot, quantity)

func _on_trade_offer_result(ok: bool, reason: String) -> void:
	if not ok:
		trade_status_label.text = "Offer failed: %s" % reason

func _on_trade_confirm_result(ok: bool, reason: String) -> void:
	trade_status_label.text = "Confirmed. Waiting on the other side." if ok else "Confirm failed: %s" % reason

func _on_trade_offer_updated(updated: TradeNet.OfferUpdated) -> void:
	if updated == null:
		return
	var item_desc := "no item" if updated.offer.item_slot < 0 else "slot %d x%d" % [updated.offer.item_slot, updated.offer.quantity]
	trade_their_offer_label.text = "Their offer: %dg, %s" % [updated.offer.gold, item_desc]

func _on_trade_completed(completed: TradeNet.Completed) -> void:
	if completed == null:
		return
	_log_system("Trade complete! Received %dg%s" % [
		completed.received_gold,
		(" and %dx item #%d" % [completed.received_quantity, completed.received_item_id]) if completed.received_item_id != 0 else ""
	])
	NetClient.list_inventory(NetClient.current_character_name)

func _on_trade_cancelled(cancelled: TradeNet.Cancelled) -> void:
	if cancelled == null:
		return
	var by_whom := cancelled.cancelled_by_name if cancelled.cancelled_by_name != "" else "the system"
	trade_status_label.text = "Trade cancelled by %s." % by_whom
	trade_their_offer_label.text = "Their offer: (none yet)"

# --- Friends tab -----------------------------------------------------------

func _refresh_friends() -> void:
	NetClient.friend_list(NetClient.current_character_name)
	NetClient.friend_pending_list(NetClient.current_character_name)

func _on_friend_request_pressed() -> void:
	var target := friend_target_input.text.strip_edges()
	if target.is_empty():
		friend_status_label.text = "Enter a target name first."
		return
	NetClient.friend_request(NetClient.current_character_name, target)

func _on_friend_request_result(ok: bool, reason: String) -> void:
	friend_status_label.text = "Request sent." if ok else "Request failed: %s" % reason

func _on_friend_request_received(received: FriendNet.RequestReceived) -> void:
	if received == null:
		return
	_log_system("%s sent you a friend request." % received.requester_name)
	_refresh_friends()

func _on_friend_accept_pressed() -> void:
	var selected := friend_pending_list.get_selected_items()
	if selected.is_empty():
		friend_status_label.text = "Select a pending request first."
		return
	var chosen: FriendNet.PendingRequest = _pending_friend_requests[selected[0]]
	NetClient.friend_accept(NetClient.current_character_name, chosen.requester_id)

func _on_friend_accept_result(ok: bool, reason: String) -> void:
	friend_status_label.text = "Friend added." if ok else "Accept failed: %s" % reason
	if ok:
		_refresh_friends()

func _on_friend_accepted(accepted: FriendNet.Accepted) -> void:
	if accepted == null:
		return
	_log_system("%s accepted your friend request." % accepted.accepter_name)
	_refresh_friends()

func _on_friend_decline_pressed() -> void:
	var selected := friend_pending_list.get_selected_items()
	if selected.is_empty():
		friend_status_label.text = "Select a pending request first."
		return
	var chosen: FriendNet.PendingRequest = _pending_friend_requests[selected[0]]
	NetClient.friend_decline(NetClient.current_character_name, chosen.requester_id)

func _on_friend_decline_result(ok: bool, reason: String) -> void:
	friend_status_label.text = "Declined." if ok else "Decline failed: %s" % reason
	if ok:
		_refresh_friends()

func _on_friend_list_result(friends: Array, error: String) -> void:
	if error != "":
		friend_status_label.text = "Error: %s" % error
		return
	_friends.assign(friends)
	friend_list.clear()
	for f in _friends:
		friend_list.add_item("%s [%s]" % [f.friend_name, "online" if f.online else "offline"])

func _on_friend_remove_pressed() -> void:
	var selected := friend_list.get_selected_items()
	if selected.is_empty():
		friend_status_label.text = "Select a friend first."
		return
	var chosen: FriendNet.FriendEntry = _friends[selected[0]]
	NetClient.friend_remove(NetClient.current_character_name, chosen.character_id)

func _on_friend_remove_result(ok: bool, reason: String) -> void:
	friend_status_label.text = "Removed." if ok else "Remove failed: %s" % reason
	if ok:
		_refresh_friends()

func _on_friend_pending_list_result(requests: Array, error: String) -> void:
	if error != "":
		return
	_pending_friend_requests.assign(requests)
	friend_pending_list.clear()
	for r in _pending_friend_requests:
		friend_pending_list.add_item(r.requester_name)
