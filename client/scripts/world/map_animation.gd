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
## DAT_00ec54b0 starts at 2500; the view-distance option can set it to
## min(0.8 x view, 2500) -- 1200 / 2000 / 2500 -- which this client has no
## option for, so the range is 2020 (720 / 1520 / 2020 per setting).
const OBJECT_RANGE_SETTING := 2500.0
const OBJECT_RANGE_MARGIN := 480.0
const OBJECT_RANGE := OBJECT_RANGE_SETTING - OBJECT_RANGE_MARGIN

## A region's `.o2` sector: its 6 x 6 grid over 1920 units (MAPO2_FORMAT.md).
## The frame's sector list (+0x2783) is taken to be this grid (INFERRED).
const SECTOR_SIZE := 1920.0 / 6.0

## SRREVAMP_NO_MAP_ANIM=1: every model is built as before round 645, still,
## with no skeleton, skin or player -- the A/B baseline. Not a player option.
static var disabled := OS.get_environment("SRREVAMP_NO_MAP_ANIM") != ""

## Node names in a template, and the meta keys that mark one.
const SKELETON_NODE := "MapSkeleton"
const PLAYER_NODE := "MapAnimation"
const CLIP_NAME := "default"
const META_ANIMATED := "srrevamp_map_animated"
const META_RADIUS := "srrevamp_map_anim_radius"

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

## The client's fade-state test (SWorld::FUN_00a38a50, READ): in range while
## `dist - radius < range`, strictly -- `dist` from the camera `eye` to the
## placement `origin`, `radius` the object's X-Z radius (xz_radius).
static func in_range(origin: Vector3, radius: float, eye: Vector3, object_range: float = OBJECT_RANGE) -> bool:
	return origin.distance_to(eye) - radius < object_range

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

## The world's animated map objects, run as the client runs them: each frame
## a sector the view touches has its objects' fade state tested; an object in
## range runs its clock and is drawn, one out of range is paused and hidden.
## A sector out of view is not visited: its objects' clocks stop and their
## fade state (here, whether they are drawn) stays as it was -- READ, the
## update loop only walks the sectors whose +0xba2 flag is set. object.ifo
## flag bit 0 objects always run and are always drawn. One per World3D;
## entries whose object has gone (a region streamed out) are dropped as
## they are found.
##
## Cost: the placement never moves, so its origin and sector are taken once,
## at add, and the view is tested once per sector, not per object.
class Driver:
	extends RefCounted
	## sector key -> [cell centre, [[player, object root, world origin,
	## X-Z radius], ..], in view last frame] for the range-tested objects.
	var _sectors := {}
	## [player, object root] of the object.ifo flag bit 0 objects: always on.
	var _always: Array = []
	var _count := 0
	## Clips running, and the time the last tick took (us), for the QA line
	## and the frame-cost measurement.
	var running := 0
	var tick_usec := 0
	## Set by MapAnimationProbe (SRREVAMP_QA_MAPANIM_SPLIT): the driver stops
	## testing, leaving the probe's state in place. Never set in play.
	var halted := false

	## Every registered entry, [player, object root, ..] -- for the probe.
	func entries() -> Array:
		var out: Array = []
		for key in _sectors:
			out.append_array(_sectors[key][1])
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
		var sector := MapAnimation.sector_of(node.position, to_world)
		for player in MapAnimation.players_of(node):
			var root: Node3D = (player as Node).get_parent()
			MapAnimation.start(player)
			added += 1
			if always:
				(player as AnimationPlayer).active = true
				running += 1
				_always.append([player, root])
				continue
			# Hidden until its sector is first visited, as the client's fade
			# state starts at 0.
			root.visible = false
			if not _sectors.has(sector[0]):
				_sectors[sector[0]] = [sector[1], [], false]
			var scale := absf(root.global_transform.basis.get_scale().x)
			(_sectors[sector[0]][1] as Array).append([player, root, node.global_position,
				float(root.get_meta(MapAnimation.META_RADIUS, 0.0)) * scale])
		_count += added
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
		var dead := false
		for key in _sectors:
			var sector: Array = _sectors[key]
			if not MapAnimation.sector_in_view(sector[0], planes):
				if sector[2]:
					# Just left the view: the clocks stop, the drawing stays.
					sector[2] = false
					for entry in sector[1]:
						if is_instance_valid(entry[0]) and (entry[0] as AnimationPlayer).active:
							(entry[0] as AnimationPlayer).active = false
							running -= 1
				continue
			sector[2] = true
			for entry in sector[1]:
				# Test the raw Variant first: a freed player raises on a typed
				# assignment (World3D._tick_idle_animations, round 214).
				if not is_instance_valid(entry[0]) or not is_instance_valid(entry[1]):
					dead = true
					continue
				var player: AnimationPlayer = entry[0]
				var root: Node3D = entry[1]
				var on := MapAnimation.in_range(entry[2], entry[3], eye)
				if root.visible != on:
					root.visible = on
				if player.active != on:
					player.active = on
					running += 1 if on else -1
		if dead:
			_prune()
		tick_usec = Time.get_ticks_usec() - sw

	## Drops every entry whose object has been freed, everywhere, and
	## recounts.
	func _prune() -> void:
		running = 0
		_count = 0
		for key in _sectors.keys():
			var alive: Array = []
			for entry in _sectors[key][1]:
				if is_instance_valid(entry[0]) and is_instance_valid(entry[1]):
					alive.append(entry)
					running += 1 if (entry[0] as AnimationPlayer).active else 0
			if alive.is_empty():
				_sectors.erase(key)
			else:
				_sectors[key][1] = alive
			_count += alive.size()
		var still: Array = []
		for entry in _always:
			if is_instance_valid(entry[0]) and is_instance_valid(entry[1]):
				still.append(entry)
				running += 1
		_always = still
		_count += still.size()
