extends RefCounted
class_name MapAnimation

## Map objects that move (round 645): the swaying trees and reeds, the
## Taklamakan tentacles (`ruin_takla_edimmu1_1`), the lanterns, boats,
## grazing sheep and the rest -- played the way the retail client plays
## them. Everything below is READ from sro_client.exe unless it says
## otherwise; docs/protocol/BSR_FORMAT.md, "How a map object animates", has
## the addresses.
##
## - **What animates.** A compound builds its AniMixer only when its `.bsr`
##   has a skeleton AND at least one animation (`CCompChar::FUN_00c2b930`),
##   and every type -- tree, building, NPC -- shares that one path.
## - **Which clip.** The map starts each sector's objects with
##   `Map::FUN_00a38dc0(obj, "default", 0)`: animation group `default`,
##   action type 0, looked up by `AniMixer::FUN_00c551a0`. **No fallback**:
##   a model whose `default` group has no type-0 entry does not move
##   (`rok_key03_01`, `euro_esteuro_viking20` and others carry only a
##   type-60 entry). Two type-0 entries: the LAST wins -- the group reader
##   (`ResObject::FUN_00c0f500` -> `FUN_00c0f470`, asm 0xc0f4e6) overwrites
##   an existing type's clip in place; a file index below 0 leaves it null
##   (asm 0xc0f58d), so nothing plays.
## - **Looping.** The clip's own `.ban` IsCyclic word picks CRTAniCyclic or
##   CRTAniOneShot. A one-shot plays once; at its end the mixer unlinks it
##   (`AniMixer::FUN_00c53e80`), and with no clip left the pose evaluation
##   (`AniMixer::FUN_00c54200`) only clears the bones' blend weights
##   (`CRTBone::vslot_004`, asm 0xc47a20) -- neither the apply (vslot_005)
##   nor the skeleton update (`FUN_00c4c320`) runs -- so the body keeps its
##   last evaluated pose (READ). Here it holds the clip's last key.
## - **Speed and clock.** 1.0, in the `.ban`'s milliseconds, wrapping at its
##   Duration (`CRTAniCyclic::vslot_002`). The authored FPS is not used.
## - **Phase.** No random phase: a clip starts at t = 0 when its sector's
##   objects are started, so one sector's objects move in step. Here the
##   clock starts at 0 when the region's objects are placed (OURS: region,
##   not sector, granularity).
## - **Range, and drawing.** `SWorld::vslot_004` visits only the sectors the
##   view frustum touches, and there runs each list-2 object's fade state
##   (`SWorld::FUN_00a38a50`): in range while `dist - radius < range`,
##   strictly, where `dist` is the 3D distance from the camera to the
##   object's placement origin (asm 0xa2d92a: camera +0x20a6.. minus obj
##   +0x57..), `radius` half its mesh bounds' X-Z diagonal (asm 0xa389f0)
##   and `range` = `DAT_00ec54b0 - 480.0` (asm 0xa2d961/0xa2d967: 2500 -
##   the double at 0xde4f58) = **2020**. The object is updated (its clock
##   runs) and drawn (`Map::FUN_00a1e530`) only while that state is not 0;
##   out of range the clock PAUSES. Objects whose object.ifo flag has bit 0
##   (the region-level list) are updated every frame regardless.
##   Here: the camera distance from the placement origin with its X-Z
##   radius, the sector's 320-unit cell against the view frustum, the
##   clock paused and the object HIDDEN out of range. OURS: retail fades an
##   object in and out over 255/512 s of alpha (and pops it straight in
##   within two thirds of the range); here it is switched.
##
## How it is built, efficiently: ObjectLoader's prepare reads the `.bsk` and
## the one `.ban` off the main thread; the commit adds a Skeleton3D, a Skin
## per skinned piece and an AnimationPlayer whose Animation is built once
## per model template. Every placement is a duplicate() of the template, so
## all instances share the Animation, the Skins and the meshes; each owns
## only its skeleton and player. Tracks whose keys never change are baked
## into the template skeleton's pose instead of played.

## The group and action type the map starts (READ, above).
const GROUP := "default"
const ACTION_TYPE := 0

## The object range the fade state is tested against (READ, asm
## 0xa2d961/0xa2d967): `DAT_00ec54b0` minus the double 480.0 at 0xde4f58.
## DAT_00ec54b0 starts at 2500; the Background Sight Range option sets it to
## min(0.8 x far plane, 2500) -- 1200 / 2000 / 2500 / 2500 / 2500 -- so the
## range is 720 / 1520 / 2020 per setting (round 694: the Option window's
## row, VideoOptions.view_distance; `object_range` below follows it).
const OBJECT_RANGE_SETTING := 2500.0
const OBJECT_RANGE_MARGIN := 480.0
const OBJECT_RANGE := OBJECT_RANGE_SETTING - OBJECT_RANGE_MARGIN
## The range in force: OBJECT_RANGE until set_view_distance is called.
static var object_range := OBJECT_RANGE

## The view distance (DAT_00ec54b0) in force; the range is it less the
## margin (READ, above). A Driver re-tests every sector on its next tick.
static func set_view_distance(view: float) -> void:
	object_range = maxf(view - OBJECT_RANGE_MARGIN, 0.0)

## A region's `.o2` sector: its 6 x 6 grid over 1920 units (MAPO2_FORMAT.md).
## The frame's sector list (+0x2783) is taken to be this grid (INFERRED).
const SECTOR_SIZE := 1920.0 / 6.0

## OPENSRO_NO_MAP_ANIM=1: every model is built as before round 645, still,
## with no skeleton, skin or player -- the A/B baseline. Not a player option.
static var disabled := OS.get_environment("OPENSRO_NO_MAP_ANIM") != ""

## Node names in a template, and the meta keys that mark one.
const SKELETON_NODE := "MapSkeleton"
const PLAYER_NODE := "MapAnimation"
const CLIP_NAME := "default"
const META_ANIMATED := "opensro_map_animated"
const META_RADIUS := "opensro_map_anim_radius"

## The entry the map plays for `obj`, or null when it does not move: no
## skeleton, no animation, or no `default` type-0 entry.
static func clip_entry(obj: BsrReader.ParsedObject) -> BsrReader.AnimationEntry:
	if obj == null or obj.skeleton_path == "" or obj.animation_paths.is_empty():
		return null
	var last: BsrReader.AnimationEntry = null
	for entry in obj.animation_groups.get(GROUP, []):
		var e := entry as BsrReader.AnimationEntry
		if e.action_type == ACTION_TYPE:
			last = e
	if last == null or last.path == "":
		return null
	return last

## The PREPARE half, on the objects job's worker (THE PREPARE-THREAD RULE:
## readers' structs only). Adds `node["anim"] = {"skeleton": ParsedSkeleton,
## "clip": ParsedAnimation, "clip_path": String}` when `obj` animates and
## both files read; `node` is ObjectLoader's `.bsr` description, whose
## pieces carry "bones" and "object_space". What could not be read goes in
## `missing`, and the object is then drawn still, as before.
static func prepare(archive: Pk2Reader, obj: BsrReader.ParsedObject, node: Dictionary, missing: Array) -> void:
	if disabled:
		return
	var entry := clip_entry(obj)
	if entry == null:
		return
	var skinned := false
	for piece in node["pieces"]:
		if not (piece.get("bones", PackedStringArray()) as PackedStringArray).is_empty():
			skinned = true
	if not skinned:
		return
	var bsk_entry := ObjectLoader.find_file(archive, obj.skeleton_path)
	var ban_entry := ObjectLoader.find_file(archive, entry.path)
	if bsk_entry == null or ban_entry == null:
		missing.append("%s: skeleton %s or clip %s not found in archive" % [obj.object_name, obj.skeleton_path, entry.path])
		return
	var skel := BskReader.parse(archive.read_file(bsk_entry))
	var clip := BanReader.parse(archive.read_file(ban_entry))
	if skel == null or clip == null or clip.bones.is_empty() or clip.key_times.is_empty():
		missing.append("%s: skeleton %s or clip %s did not parse" % [obj.object_name, obj.skeleton_path, entry.path])
		return
	node["anim"] = {"skeleton": skel, "clip": clip, "clip_path": entry.path}

## The COMMIT half, on the main thread: gives the template `root` its
## Skeleton3D, binds each skinned piece in `pieces` (MeshInstance3D ->
## the prepared piece dictionary) to it, and adds the AnimationPlayer.
## Unskinned pieces stay where they are (whether retail hangs them on a
## bone is OPEN). Each skin binds to the `.bsk`'s stored inverse binds when
## they are the composed chain with only the root re-seated (round 721; the
## client's palette is the file's inverse bind times the bone's world, READ,
## but the client takes them ALWAYS -- the condition is OURS, see
## Skeleton3DBuilder.consistent_stored_binds). Returns false, leaving the object still, when nothing
## could be bound.
static func commit(root: Node3D, anim: Dictionary, pieces: Array) -> bool:
	var skeleton := Skeleton3DBuilder.build_skeleton3d(anim["skeleton"])
	if skeleton == null or skeleton.get_bone_count() == 0:
		return false
	skeleton.name = SKELETON_NODE
	root.add_child(skeleton)
	# Round 721: the skins bind to the file's stored inverse binds, as the
	# client does, where those are the composed chain with only the root
	# re-seated (Skeleton3DBuilder.consistent_stored_binds; the Alexandria
	# gate portal). Any other disagreement keeps the composed bind (OPEN).
	var binds := Skeleton3DBuilder.consistent_stored_binds(skeleton, anim["skeleton"])
	var bound := 0
	var box := AABB()
	var have_box := false
	for pair in pieces:
		var mi: MeshInstance3D = pair[0]
		var piece: Dictionary = pair[1]
		if mi.mesh != null:
			box = mi.mesh.get_aabb() if not have_box else box.merge(mi.mesh.get_aabb())
			have_box = true
		var bones: PackedStringArray = piece.get("bones", PackedStringArray())
		if bones.is_empty():
			continue
		var skin := Skeleton3DBuilder.build_skin(skeleton, bones, bool(piece.get("object_space", false)), false, binds)
		if skin == null:
			continue
		mi.skin = skin
		mi.skeleton = NodePath("../" + SKELETON_NODE)
		bound += 1
	if bound == 0:
		root.remove_child(skeleton)
		skeleton.free()
		return false
	var animation := build_animation(skeleton, anim["clip"])
	var library := AnimationLibrary.new()
	library.add_animation(CLIP_NAME, animation)
	var player := AnimationPlayer.new()
	player.name = PLAYER_NODE
	player.add_animation_library("", library)
	root.add_child(player)
	player.root_node = NodePath("..")
	root.set_meta(META_ANIMATED, true)
	# The radius the range test uses, as the client's obj+0x1f (READ, asm
	# 0xa389f0): half the X-Z diagonal of the union of the object's mesh
	# bounds, height ignored. The client takes a skinned mesh's bounds in
	# its pose at creation; this takes the bind pose (INFERRED close: a
	# sway moves a tree's leaves a few units).
	root.set_meta(META_RADIUS, xz_radius(box))
	return true

## The clip as a Godot Animation over `skeleton`'s bones, on the `.ban`'s
## own key times (ms -> s), looping when the file says it is cyclic. A bone
## the skeleton lacks is skipped, as the character path skips it. A track
## whose keys are all equal is not played: its one value is set as the
## bone's pose in `skeleton` (the template), which every placed copy
## inherits -- the same pose at every moment, for no per-frame cost.
static func build_animation(skeleton: Skeleton3D, clip: BanReader.ParsedAnimation) -> Animation:
	var animation := Animation.new()
	animation.length = maxf(float(clip.duration_ms) / 1000.0, 0.001)
	animation.loop_mode = Animation.LOOP_LINEAR if clip.cyclic else Animation.LOOP_NONE
	var times := clip.key_times
	for track in clip.bones:
		var bone := skeleton.find_bone(track.bone_name)
		if bone == -1 or track.keyframes.is_empty():
			continue
		var count := mini(track.keyframes.size(), times.size())
		if count == 0:
			continue
		var rot_const := true
		var pos_const := true
		var r0 := track.keyframes[0].rotation.normalized()
		var p0 := track.keyframes[0].position
		for k in range(1, count):
			if not track.keyframes[k].rotation.normalized().is_equal_approx(r0):
				rot_const = false
			if not track.keyframes[k].position.is_equal_approx(p0):
				pos_const = false
		var path := NodePath("%s:%s" % [SKELETON_NODE, track.bone_name])
		if rot_const:
			skeleton.set_bone_pose_rotation(bone, r0)
		else:
			var t := animation.add_track(Animation.TYPE_ROTATION_3D)
			animation.track_set_path(t, path)
			animation.track_set_interpolation_type(t, Animation.INTERPOLATION_LINEAR)
			animation.track_set_interpolation_loop_wrap(t, true)
			for k in range(count):
				animation.rotation_track_insert_key(t, float(times[k]) / 1000.0, track.keyframes[k].rotation.normalized())
		if pos_const:
			skeleton.set_bone_pose_position(bone, p0)
		else:
			var t := animation.add_track(Animation.TYPE_POSITION_3D)
			animation.track_set_path(t, path)
			animation.track_set_interpolation_type(t, Animation.INTERPOLATION_LINEAR)
			animation.track_set_interpolation_loop_wrap(t, true)
			for k in range(count):
				animation.position_track_insert_key(t, float(times[k]) / 1000.0, track.keyframes[k].position)
	Skeleton3DBuilder.refresh_global_poses(skeleton)
	return animation

## `sqrt((dx/2)^2 + (dz/2)^2)` of `box` -- the client's object radius
## (READ, asm 0xa389f0, 0.5 = DAT_00e1b7d0).
static func xz_radius(box: AABB) -> float:
	return Vector2(box.size.x * 0.5, box.size.z * 0.5).length()

## The AnimationPlayers of a placed object (a `.cpd` may hold several
## animated children), or [] for a still one.
static func players_of(node: Node3D) -> Array:
	var out: Array = []
	if node.has_meta(META_ANIMATED):
		var p := node.get_node_or_null(PLAYER_NODE)
		if p != null:
			out.append(p)
	for child in node.get_children():
		if child is Node3D and child.has_meta(META_ANIMATED):
			var p := child.get_node_or_null(PLAYER_NODE)
			if p != null:
				out.append(p)
	return out

## Starts a placed copy's clip at t = 0 (READ: no random phase), paused
## until the driver finds it in range. Call once it is in the tree.
static func start(player: AnimationPlayer) -> void:
	player.play(CLIP_NAME)
	player.seek(0.0, true)
	player.active = false

## The client's fade-state test (SWorld::FUN_00a38a50, READ): in range while
## `dist - radius < range`, strictly -- `dist` from the camera `eye` to the
## placement `origin`, `radius` the object's X-Z radius (xz_radius).
static func in_range(origin: Vector3, radius: float, eye: Vector3, range_: float = -1.0) -> bool:
	return origin.distance_to(eye) - radius < (range_ if range_ >= 0.0 else object_range)

## The sector cell holding a placement at region-local `local`: its key and
## the centre of the cell (at the placement's height) in the space
## `to_world` maps region-local coordinates into.
static func sector_of(local: Vector3, to_world: Transform3D) -> Array:
	var cx := floori(local.x / SECTOR_SIZE)
	var cz := floori(local.z / SECTOR_SIZE)
	var centre := to_world * Vector3((cx + 0.5) * SECTOR_SIZE, local.y, (cz + 0.5) * SECTOR_SIZE)
	return ["%d:%d:%d" % [roundi(centre.x), roundi(centre.z), cx * 8 + cz], centre]

## Half the X-Z diagonal of a sector cell: the sphere sector_in_view tests.
const SECTOR_RADIUS := SECTOR_SIZE * 0.7071068

## Whether a sector's cell touches the view (the client's per-sector flag,
## set by rasterising the frustum onto the sector grid, `Map::FUN_00a2b370`):
## here the cell's X-Z circle, at its object's height, against the frustum
## planes (Camera3D.get_frustum(), normals outward). OURS: a sphere, not the
## ground footprint. Empty `planes` passes everything.
static func sector_in_view(centre: Vector3, planes: Array) -> bool:
	for plane in planes:
		if (plane as Plane).distance_to(centre) > SECTOR_RADIUS:
			return false
	return true

## A margin (world units) on the per-sector range bounds below: a sector is
## decided "every object in range" or "every object out" only when that holds
## with this much to spare, so float rounding in the bound can never decide
## an object the per-object test would decide the other way. OURS (a guard
## band, not a retail value); inside the band every object is tested.
const BOUND_MARGIN := 1.0

## OPENSRO_MAP_ANIM_NO_SHARE=1: every running clip keeps its own player and
## skeleton (round 645's path) -- the A/B for the shared poses' saving, and
## what MapAnimationProbe's cost modes need. Not a player option.
static var no_share := OS.get_environment("OPENSRO_MAP_ANIM_NO_SHARE") != ""

## One registered clip: a placed object's player, skeleton and skinned
## pieces, where it stands, and whose pose it is drawn with.
class Obj:
	extends RefCounted
	var player: AnimationPlayer
	var root: Node3D
	var skeleton: Skeleton3D
	## [MeshInstance3D, its own skeleton NodePath] of each piece skinned to
	## `skeleton` (front-pass twins included).
	var meshes: Array = []
	var clip: Animation
	var origin := Vector3.ZERO
	var radius := 0.0
	## Its clock runs this frame (its own player's, or its pose group's).
	var running := false
	## The pose group it is drawn from while it runs, or null for its own.
	var group: PoseGroup = null
	var sector: Sector = null
	var always := false

## Running clips of one Animation whose clocks are equal, drawn from one
## pose: `player` plays the clip on `skeleton`, and every member's skinned
## pieces are bound to `skeleton`. A group only forms from clips that START
## in the same frame at the same clock (see Driver._start_all), so its
## members' clocks are equal by construction, and a member leaves it the
## frame its own clock stops.
class PoseGroup:
	extends RefCounted
	var clip: Animation
	var node: Node3D
	var skeleton: Skeleton3D
	var player: AnimationPlayer
	var members: Array = []

## A `.o2` sector's registered objects, with bounds for the per-sector range
## decision: `rho` the farthest origin from `centre`, `rmin`/`rmax` the
## smallest and largest radius.
class Sector:
	extends RefCounted
	var centre := Vector3.ZERO
	var objs: Array = []
	var in_view := false
	## 0: its objects were tested one by one (or not yet), 1: all in range,
	## 2: all out -- as decided the last frame it was in view.
	var state := 0
	## Every object hidden and paused: true as registered (fade state 0),
	## and after a frame that switched them all off.
	var quiet := true
	var rho := 0.0
	var rmin := INF
	var rmax := 0.0

## The world's animated map objects, run as the client runs them: each frame
## a sector the view touches has its objects' fade state tested; an object in
## range runs its clock and is drawn, one out of range is paused and hidden.
## A sector out of view is not visited: its objects' clocks stop and their
## fade state (here, whether they are drawn) stays as it was -- READ, the
## update loop only walks the sectors whose +0xba2 flag is set. object.ifo
## flag bit 0 objects always run and are always drawn. One per World3D.
##
## Cost (round 647): the placement never moves, so its origin and sector are
## taken once, at add, and the view is tested once per sector, not per object.
## A sector whose bounds put every object in range (or every one out) is
## decided without visiting its objects, and one decided the same way last
## frame is not visited at all. Clips that start in the same frame at the
## same clock share one pose (PoseGroup): one player and one skeleton for
## all of them, so the players, skeleton updates and bone uploads a frame
## scale with the distinct clocks, not the objects. Retail pauses each object
## on its own (SWorld::FUN_00a38a50's fade state is per object, READ), so a
## member whose clock stops leaves its group, keeping the pose it had.
class Driver:
	extends RefCounted
	## sector key -> Sector, for the range-tested objects.
	var _sectors := {}
	## The object.ifo flag bit 0 objects: always on, each on its own pose.
	var _always: Array = []
	var _count := 0
	## Clips whose clock runs (objects), the players actually advancing for
	## them (poses), the pose groups alive, and the time the last tick took
	## (us) -- for the QA line and the frame-cost measurement.
	var running := 0
	var poses := 0
	var groups := 0
	var tick_usec := 0
	## The last tick's work, for the QA line: sectors whose view was tested,
	## and objects tested one by one.
	var sectors_viewed := 0
	var objects_tested := 0
	## Set by MapAnimationProbe (OPENSRO_QA_MAPANIM_SPLIT): the driver stops
	## testing, leaving the probe's state in place. Never set in play.
	var halted := false
	## Round 680 (OURS, the title's backdrop only): an object out of range
	## stays DRAWN, its clock paused at its last pose, instead of hidden --
	## the title's camera flies toward scenery, and switching it on at 2020
	## units is a pop in view. Off in play, where the retail rule stands.
	var keep_drawn := false
	## Where pose groups' nodes live (World3D's own holder). null: no sharing.
	var pose_parent: Node = null
	## Share poses (no_share unset). A test flips it per driver.
	var share := not MapAnimation.no_share
	## Pose-group nodes by clip, idle, for reuse; and the ones released this
	## tick, pooled only at the next -- a node whose player was processing
	## this frame, reused the same frame, would advance a frame early.
	var _pool := {}
	var _released: Array = []
	var _live_groups: Array = []
	## The last tick's camera, and whether an object came or went since.
	var _last_eye := Vector3.INF
	var _last_planes: Array = []
	var _changed := true
	## The object range the last tick tested against (MapAnimation.object_range).
	var _range_ticked := MapAnimation.OBJECT_RANGE

	## Every registered entry, [player, object root, world origin, radius] --
	## for the probe and the tests.
	func entries() -> Array:
		var out: Array = []
		for o in objects():
			out.append([o.player, o.root, o.origin, o.radius])
		return out

	## Every registered Obj.
	func objects() -> Array:
		var out: Array = []
		for key in _sectors:
			out.append_array((_sectors[key] as Sector).objs)
		out.append_array(_always)
		return out

	## Registers `node`'s clips (players_of), started at t = 0. `node` must
	## be placed (in the tree, at its final transform, its `position` the
	## region-local placement and its parent the region's container).
	## `always`: object.ifo flag bit 0. Returns how many were registered.
	func add(node: Node3D, always: bool) -> int:
		var added := 0
		var parent := node.get_parent() as Node3D
		var to_world := parent.global_transform if parent != null else Transform3D.IDENTITY
		var where := MapAnimation.sector_of(node.position, to_world)
		for player in MapAnimation.players_of(node):
			var o := Obj.new()
			o.player = player
			o.root = (player as Node).get_parent()
			o.skeleton = o.root.get_node_or_null(MapAnimation.SKELETON_NODE) as Skeleton3D
			o.clip = (player as AnimationPlayer).get_animation(MapAnimation.CLIP_NAME)
			if o.skeleton != null:
				for mi in o.root.find_children("*", "MeshInstance3D", true, false):
					var m := mi as MeshInstance3D
					if m.skin != null and m.get_node_or_null(m.skeleton) == o.skeleton:
						o.meshes.append([m, m.skeleton])
			MapAnimation.start(player)
			added += 1
			if always:
				o.always = true
				o.running = true
				(player as AnimationPlayer).active = true
				running += 1
				poses += 1
				_always.append(o)
				continue
			# Hidden until its sector is first visited, as the client's fade
			# state starts at 0 (drawn, paused, under keep_drawn).
			o.root.visible = keep_drawn
			var s: Sector = _sectors.get(where[0])
			if s == null:
				s = Sector.new()
				s.centre = where[1]
				_sectors[where[0]] = s
			var scale := absf(o.root.global_transform.basis.get_scale().x)
			o.origin = node.global_position
			o.radius = float(o.root.get_meta(MapAnimation.META_RADIUS, 0.0)) * scale
			o.sector = s
			s.objs.append(o)
			s.rho = maxf(s.rho, o.origin.distance_to(s.centre))
			s.rmin = minf(s.rmin, o.radius)
			s.rmax = maxf(s.rmax, o.radius)
			# A newcomer is hidden and paused: the sector is tested whole again.
			s.state = 0
		_count += added
		_changed = true
		return added

	func size() -> int:
		return _count

	## One frame: `eye` is the camera's position, `planes` its frustum
	## (Camera3D.get_frustum(), [] for none). Every sector in view has its
	## objects tested; a sector out of view is left as it was.
	func tick(eye: Vector3, planes: Array) -> void:
		var sw := Time.get_ticks_usec()
		if _count == 0 or halted:
			tick_usec = 0
			return
		if not _released.is_empty():
			_pool_released()
		if MapAnimation.object_range != _range_ticked:
			# The range changed (the Background Sight Range option): every
			# sector's quiet shortcut was taken against the old one.
			_range_ticked = MapAnimation.object_range
			_changed = true
			for key in _sectors:
				(_sectors[key] as Sector).quiet = false
		# The same camera as the last tick, and nothing added or dropped
		# since: every decision below would come out as it did, and the
		# last tick already applied them.
		if not _changed and eye == _last_eye and planes == _last_planes:
			sectors_viewed = 0
			objects_tested = 0
			tick_usec = Time.get_ticks_usec() - sw
			return
		_changed = false
		_last_eye = eye
		_last_planes = planes.duplicate()
		var starting: Array = []
		var stopping: Array = []
		var dead := false
		var near := MapAnimation.object_range - BOUND_MARGIN
		var far := MapAnimation.object_range + BOUND_MARGIN
		var object_range := MapAnimation.object_range
		var reach := MapAnimation.SECTOR_RADIUS
		var view: Array[Plane] = []
		for plane in planes:
			view.append(plane)
		var viewed := 0
		var tested := 0
		for key in _sectors:
			var s: Sector = _sectors[key]
			# The bounds: every origin lies within rho of the centre, so an
			# object's `dist - radius` is at most d + rho - rmin and at least
			# d - rho - rmax.
			var d := s.centre.distance_to(eye)
			if s.quiet and d - s.rho - s.rmax >= far:
				# Every object out of range and already paused and hidden:
				# in view or not, nothing about them changes (in view they
				# are hidden and paused, out of view they keep that).
				continue
			# MapAnimation.sector_in_view, inlined.
			viewed += 1
			var seen := true
			for plane in view:
				if plane.distance_to(s.centre) > reach:
					seen = false
					break
			if not seen:
				if s.in_view:
					# Just left the view: the clocks stop, the drawing stays.
					s.in_view = false
					for o in s.objs:
						if o.running:
							stopping.append(o)
				continue
			var was := s.in_view
			s.in_view = true
			var all := 0
			if d + s.rho - s.rmin < near:
				all = 1
			elif d - s.rho - s.rmax >= far:
				all = 2
			if all != 0 and was and s.state == all:
				continue
			s.state = all
			tested += s.objs.size()
			var quiet := true
			for o in s.objs:
				# Test the raw Variant first: a freed player raises on a typed
				# assignment (World3D._tick_idle_animations, round 214).
				if not is_instance_valid(o.player) or not is_instance_valid(o.root):
					dead = true
					continue
				# MapAnimation.in_range, inlined: the same expression.
				var on: bool = all == 1 or (all == 0 and o.origin.distance_to(eye) - o.radius < object_range)
				if on:
					quiet = false
				var drawn: bool = on or keep_drawn
				if o.root.visible != drawn:
					o.root.visible = drawn
				if o.running != on:
					if on:
						starting.append(o)
					else:
						stopping.append(o)
			s.quiet = quiet
		for o in stopping:
			_stop(o)
		if not starting.is_empty():
			_start_all(starting)
		if dead:
			_prune()
		sectors_viewed = viewed
		objects_tested = tested
		tick_usec = Time.get_ticks_usec() - sw

	## `o`'s clock stops this frame: its own player pauses, or it leaves its
	## pose group holding the group's pose -- its own player set to the
	## group's clock, which is its own clock, and its pieces bound back.
	func _stop(o: Obj) -> void:
		o.running = false
		running -= 1
		if o.group == null:
			if is_instance_valid(o.player):
				o.player.active = false
			poses -= 1
			return
		_leave(o, true)

	func _leave(o: Obj, restore: bool) -> void:
		var g := o.group
		o.group = null
		if restore and is_instance_valid(o.player) and is_instance_valid(g.player):
			# Before this frame's advance: the group's clock is the one `o`
			# ran to, so the seek puts `o` at its own clock (a seek needs an
			# active player; it is paused again at once, before the tree's
			# process list reaches it).
			o.player.active = true
			o.player.seek(g.player.current_animation_position, true)
			o.player.active = false
			_bind(o, null)
		g.members.erase(o)
		if g.members.is_empty():
			_release(g)

	## Starts the clocks of `starting` (each paused until now, its own player
	## at its own clock). Shareable clips with the same Animation and the
	## same clock start as one pose group; any other runs on its own player.
	## A start never joins a group already running: its clock would have to
	## equal the group's exactly, which this conservative rule (OURS) avoids
	## having to prove. (Not because of the tree's process-list copy, as
	## first written: the driver ticks from _physics_process, so a clip
	## started in the tick advances in that same frame -- the release
	## review, 2026-09-30.)
	func _start_all(starting: Array) -> void:
		var buckets := {}
		for o in starting:
			o.running = true
			running += 1
			if not _shareable(o):
				o.player.active = true
				poses += 1
				continue
			var key := [o.clip, o.player.current_animation_position]
			if buckets.has(key):
				(buckets[key] as Array).append(o)
			else:
				buckets[key] = [o]
		for key in buckets:
			var same: Array = buckets[key]
			poses += 1
			if same.size() == 1:
				(same[0] as Obj).player.active = true
				continue
			var g := _group(same[0], float(key[1]))
			for o in same:
				o.group = g
				g.members.append(o)
				_bind(o, g.skeleton)

	func _shareable(o: Obj) -> bool:
		return share and pose_parent != null and is_instance_valid(pose_parent) and pose_parent.is_inside_tree() and o.skeleton != null \
			and not o.meshes.is_empty() and o.clip != null and o.clip.loop_mode != Animation.LOOP_NONE

	## A pose group for `o`'s clip at `pos`: an idle node of that clip, or a
	## new one -- a copy of `o`'s skeleton (its held poses included) and
	## player (the same Animation) under pose_parent.
	func _group(o: Obj, pos: float) -> PoseGroup:
		var g := PoseGroup.new()
		g.clip = o.clip
		var idle: Array = _pool.get(o.clip, [])
		if not idle.is_empty():
			g.node = idle.pop_back()
		else:
			g.node = Node3D.new()
			g.node.name = "Pose"
			var sk := o.skeleton.duplicate() as Skeleton3D
			sk.name = MapAnimation.SKELETON_NODE
			var pl := o.player.duplicate() as AnimationPlayer
			pl.name = MapAnimation.PLAYER_NODE
			g.node.add_child(sk)
			g.node.add_child(pl)
			pl.root_node = NodePath("..")
			pose_parent.add_child(g.node)
		g.skeleton = g.node.get_node(MapAnimation.SKELETON_NODE)
		g.player = g.node.get_node(MapAnimation.PLAYER_NODE)
		g.player.active = true
		if g.player.current_animation != MapAnimation.CLIP_NAME:
			g.player.play(MapAnimation.CLIP_NAME)
		g.player.seek(pos, true)
		_live_groups.append(g)
		groups += 1
		return g

	## `g` has no member left: its player stops now; its node is pooled at
	## the next tick.
	func _release(g: PoseGroup) -> void:
		if is_instance_valid(g.player):
			g.player.active = false
		poses -= 1
		groups -= 1
		_live_groups.erase(g)
		if is_instance_valid(g.node):
			_released.append(g)

	func _pool_released() -> void:
		for g in _released:
			if is_instance_valid(g.node):
				if not _pool.has(g.clip):
					_pool[g.clip] = []
				(_pool[g.clip] as Array).append(g.node)
		_released.clear()

	## Binds `o`'s skinned pieces to `skeleton`, or back to their own when null.
	func _bind(o: Obj, skeleton: Skeleton3D) -> void:
		for pair in o.meshes:
			if not is_instance_valid(pair[0]):
				continue
			var mi: MeshInstance3D = pair[0]
			mi.skeleton = pair[1] if skeleton == null else skeleton.get_path()

	## Drops `o`: its clock stops and it leaves its group, bound back to its
	## own skeleton while its object is still there.
	func _remove(o: Obj) -> void:
		_changed = true
		if o.running:
			o.running = false
			running -= 1
			if o.group != null:
				_leave(o, is_instance_valid(o.root) and o.root.is_inside_tree())
			else:
				poses -= 1
		if o.sector != null:
			o.sector.objs.erase(o)
			if o.sector.objs.is_empty():
				for key in _sectors.keys():
					if _sectors[key] == o.sector:
						_sectors.erase(key)
						break
		else:
			_always.erase(o)
		_count -= 1

	## Drops every entry whose object has been freed.
	func _prune() -> void:
		for o in objects():
			if not is_instance_valid(o.player) or not is_instance_valid(o.root):
				_remove(o)

	## A region streaming out (round 647): drops every object under
	## `container` -- what World3D._release_region_objects did not hand to
	## a region still loaded, and which goes with the container -- and any
	## already freed. Returns how many were dropped.
	func drop_under(container: Node) -> int:
		var dropped := 0
		for o in objects():
			var gone: bool = not is_instance_valid(o.player) or not is_instance_valid(o.root)
			if gone or (is_instance_valid(container) and container.is_ancestor_of(o.root)):
				_remove(o)
				dropped += 1
		return dropped

	## Forgets everything (round 647): the grid was cleared (a zone change,
	## which moves the world's origin, so no sector key or centre carries
	## over). The objects go with their containers; the pose nodes go now.
	func reset() -> void:
		_break_cycles()
		for g in _live_groups:
			if is_instance_valid(g.node):
				g.node.queue_free()
		for g in _released:
			if is_instance_valid(g.node):
				g.node.queue_free()
		for clip in _pool:
			for n in _pool[clip]:
				if is_instance_valid(n):
					(n as Node).queue_free()
		_sectors = {}
		_always = []
		_pool = {}
		_released = []
		_live_groups = []
		_count = 0
		running = 0
		poses = 0
		groups = 0
		_changed = true

	## Round 685: each Obj names its Sector and its PoseGroup and they list it
	## back -- RefCounted cycles, which outlive the driver. MEASURED: every
	## World3D freed left its animated objects behind (+559 objects and
	## +1.3 MB a front-end backdrop of 98/168, client/tools/
	## measure_create_cycles.gd, 0 with OPENSRO_NO_MAP_ANIM), and so does
	## every reset (a zone change). The links are cut here.
	func _break_cycles() -> void:
		for key in _sectors:
			var s: Sector = _sectors[key]
			for o in s.objs:
				(o as Obj).sector = null
				(o as Obj).group = null
			s.objs = []
		for o in _always:
			(o as Obj).group = null
		for g in _live_groups + _released:
			(g as PoseGroup).members = []

	## The same, when the driver itself goes (its World3D freed). Inline: a
	## RefCounted's own methods cannot be called while it is being deleted
	## (MEASURED in round 683, CharacterAppearance).
	func _notification(what: int) -> void:
		if what != NOTIFICATION_PREDELETE:
			return
		for key in _sectors:
			var s: Sector = _sectors[key]
			for o in s.objs:
				(o as Obj).sector = null
				(o as Obj).group = null
			s.objs = []
		for o in _always:
			(o as Obj).group = null
		for g in _live_groups:
			(g as PoseGroup).members = []
		for g in _released:
			(g as PoseGroup).members = []
