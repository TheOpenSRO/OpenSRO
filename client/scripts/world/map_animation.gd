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
##   type-60 entry).
## - **Looping.** The clip's own `.ban` IsCyclic word picks CRTAniCyclic or
##   CRTAniOneShot. A one-shot plays once. What retail shows after it ends
##   is OPEN; this holds its last keyframe (OURS).
## - **Speed and clock.** 1.0, in the `.ban`'s milliseconds, wrapping at its
##   Duration (`CRTAniCyclic::vslot_002`). The authored FPS is not used.
## - **Phase.** No random phase: a clip starts at t = 0 when its sector's
##   objects are started, so one sector's objects move in step. Here the
##   clock starts at 0 when the region's objects are placed (OURS: region,
##   not sector, granularity).
## - **Cull.** `SWorld::vslot_004` updates an object only while its fade
##   state is not 0 -- `dist - radius < range` (`SWorld::FUN_00a38a50`),
##   the 3D distance from the camera, the radius half the object's X-Z
##   bounds diagonal, range `DAT_00ec54b0`, 2500 at start -- and only in
##   sectors the view frustum touches. Outside, the clock is PAUSED, not
##   skipped; a state-0 object is not drawn either, so the pause cannot be
##   seen. Objects whose object.ifo flag has bit 0 (the region-level list)
##   are updated every frame regardless. The frustum test here is on the
##   object's own bounding sphere, not its 320-unit sector: an in-range
##   object just off screen in a visible sector runs in retail and is
##   paused here (OURS: it is not drawn in either, so only its phase
##   differs).
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

## DAT_00ec54b0's initial value: the object range (READ). The view-distance
## option can lower it to 1200 or 2000; this client has no such option.
const OBJECT_RANGE := 2500.0

## Node names in a template, and the meta keys that mark one.
const SKELETON_NODE := "MapSkeleton"
const PLAYER_NODE := "MapAnimation"
const CLIP_NAME := "default"
const META_ANIMATED := "srrevamp_map_animated"
const META_CENTER := "srrevamp_map_anim_center"
const META_RADIUS := "srrevamp_map_anim_radius"
const META_BOUND := "srrevamp_map_anim_bound"

## The entry the map plays for `obj`, or null when it does not move: no
## skeleton, no animation, or no `default` type-0 entry.
static func clip_entry(obj: BsrReader.ParsedObject) -> BsrReader.AnimationEntry:
	if obj == null or obj.skeleton_path == "" or obj.animation_paths.is_empty():
		return null
	for entry in obj.animation_groups.get(GROUP, []):
		var e := entry as BsrReader.AnimationEntry
		if e.action_type == ACTION_TYPE and e.path != "":
			return e
	return null

## The PREPARE half, on the objects job's worker (THE PREPARE-THREAD RULE:
## readers' structs only). Adds `node["anim"] = {"skeleton": ParsedSkeleton,
## "clip": ParsedAnimation, "clip_path": String}` when `obj` animates and
## both files read; `node` is ObjectLoader's `.bsr` description, whose
## pieces carry "bones" and "object_space". What could not be read goes in
## `missing`, and the object is then drawn still, as before.
static func prepare(archive: Pk2Reader, obj: BsrReader.ParsedObject, node: Dictionary, missing: Array) -> void:
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
## bone is OPEN). Returns false, leaving the object still, when nothing
## could be bound.
static func commit(root: Node3D, anim: Dictionary, pieces: Array) -> bool:
	var skeleton := Skeleton3DBuilder.build_skeleton3d(anim["skeleton"])
	if skeleton == null or skeleton.get_bone_count() == 0:
		return false
	skeleton.name = SKELETON_NODE
	root.add_child(skeleton)
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
		var skin := Skeleton3DBuilder.build_skin(skeleton, bones, bool(piece.get("object_space", false)))
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
	root.set_meta(META_CENTER, box.get_center())
	root.set_meta(META_RADIUS, xz_radius(box))
	# The frustum test's sphere takes the whole box (OURS: the client tests
	# sectors, not objects).
	root.set_meta(META_BOUND, box.size.length() * 0.5)
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
	skeleton.force_update_all_bone_transforms()
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

## Whether an object at `center` is updated this frame: the client's
## fade-state test `dist - radius < range` from the camera `eye`
## (SWorld::FUN_00a38a50, `radius` its X-Z radius) and, standing in for its
## frustum-touched sectors, a sphere of `bound` against the view `planes`
## (Camera3D.get_frustum(), normals outward; empty skips the test).
## `always` is object.ifo flag bit 0: updated every frame.
static func in_range(center: Vector3, radius: float, bound: float, eye: Vector3, planes: Array, always: bool, object_range: float = OBJECT_RANGE) -> bool:
	if always:
		return true
	if center.distance_to(eye) - radius >= object_range:
		return false
	for plane in planes:
		if (plane as Plane).distance_to(center) > bound:
			return false
	return true

## The world's animated map objects: registers each placed copy and runs
## the clock of those in range, pausing the rest (`in_range`). One per
## World3D; entries whose object has gone (a region streamed out) are
## dropped as they are found.
##
## Cost (round 645, MEASURED in Jangan's 25 regions, 456 clips): testing
## every clip every frame took about 1.05 ms of GDScript. A placed map
## object never moves, so its world centre is taken once, at add; and each
## frame tests one SLICE_FRAMES-th of the list, so a clip's run/pause state
## follows the camera within SLICE_FRAMES frames (OURS: retail tests every
## object every frame; a 4-frame lag at an edge the object is invisible
## beyond -- a state-0 object is not drawn -- shifts only its phase).
class Driver:
	extends RefCounted
	const SLICE_FRAMES := 4
	## [player, object root, world centre, X-Z radius, bound, always] per clip.
	var _entries: Array = []
	var _cursor := 0
	## Clips running, and the time the last tick took (us), for the QA line
	## and the frame-cost measurement.
	var running := 0
	var tick_usec := 0

	## Registers `node`'s clips (players_of), started at t = 0. `node` must
	## be placed (in the tree, at its final transform). `always`: object.ifo
	## flag bit 0. Returns how many were registered.
	func add(node: Node3D, always: bool) -> int:
		var added := 0
		for player in MapAnimation.players_of(node):
			var root: Node3D = (player as Node).get_parent()
			MapAnimation.start(player)
			var xf := root.global_transform
			var scale := absf(xf.basis.get_scale().x)
			_entries.append([player, root, xf * (root.get_meta(MapAnimation.META_CENTER, Vector3.ZERO) as Vector3),
				float(root.get_meta(MapAnimation.META_RADIUS, 0.0)) * scale,
				float(root.get_meta(MapAnimation.META_BOUND, 0.0)) * scale, always])
			added += 1
		return added

	func size() -> int:
		return _entries.size()

	## One frame: `eye` is where the range is measured from (the camera),
	## `planes` the view frustum (Camera3D.get_frustum(), [] for none). Tests
	## the next slice of the list; `all` tests every entry (the tests).
	func tick(eye: Vector3, planes: Array, all: bool = false) -> void:
		var sw := Time.get_ticks_usec()
		var n := _entries.size()
		if n == 0:
			tick_usec = 0
			return
		var count := n if all else ceili(float(n) / SLICE_FRAMES)
		var dead := false
		for _k in range(count):
			if _cursor >= n:
				_cursor = 0
			var entry: Array = _entries[_cursor]
			_cursor += 1
			# Test the raw Variant first: a freed player raises on a typed
			# assignment (World3D._tick_idle_animations, round 214).
			if not is_instance_valid(entry[0]) or not is_instance_valid(entry[1]):
				dead = true
				continue
			var player: AnimationPlayer = entry[0]
			var on := MapAnimation.in_range(entry[2], entry[3], entry[4], eye, planes, entry[5])
			if player.active != on:
				player.active = on
				running += 1 if on else -1
		if dead:
			var alive: Array = []
			running = 0
			for entry in _entries:
				if is_instance_valid(entry[0]) and is_instance_valid(entry[1]):
					alive.append(entry)
					if (entry[0] as AnimationPlayer).active:
						running += 1
			_entries = alive
			_cursor = 0
		tick_usec = Time.get_ticks_usec() - sw
