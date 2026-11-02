extends RefCounted
class_name CharacterLight

## A character's object colour, as the original keeps it (round 706).
##
## READ (ObjectLight has the addresses): every character's position setter
## (`GlobalDataManager::FUN_009cf530`, CIObject slot 37) sets its compound
## object's colour -- the factor on the light's ambient in c10 -- to 0.6
## unless it stands on a terrain cell, and then to the byte of its region's
## .t ShadowMap under it divided by 384 (`SWorld::vslot_041`): 153..255 ->
## 0.398..0.664, 1.0 where no region is found. A placed object keeps the
## constructor's 0.6 (ObjectLight.OBJECT_COLOR, the shaders' default).
##
## Here (OURS method): every character body is already in CharacterBlobs'
## group; a few of them a frame are visited, the tile and footing under each
## read (World3D's `_nav_graph_for`, NavGraph.surface_at -- on the terrain or
## on an object -- and the ShadowMap the terrain commit leaves on the region's
## group), and every mesh under it switched to its material's copy at that
## level (ObjectLight.with_object_color: one copy per material and level,
## shared by every body there; the material itself at 0.6). World3D also
## visits a body when it is placed, before its fade starts, so the fade's
## twins are made from the right copy. The original updates it with every
## position; here a character is revisited every couple of frames, and
## skipped while it has not moved (MOVE_EPSILON). A mesh added to a body (a
## new piece of equipment) takes the value at the body's next full rescan
## (RESCAN_VISITS). Meshes drawing a fade twin (AppearFade) or a pulse's copy
## (BodyPulse: a state's or berserk's colour) are left to those; they put the
## mesh's own material back when they end, BodyPulse at the body's level then.
## Round 855: before, a state's pulse copy was swapped for the shared level
## copy here and the pulse then painted that shared material (MEASURED).
## Both renderers (round 706 review: a per-instance uniform overflowed
## Godot's instance buffer, and Compatibility has none).

## The ShadowMap a terrain group carries (World3D._terrain_commit).
const SHADOW_META := &"opensro_shadow_map"
## Per-body memory.
const META_VALUE := &"opensro_obj_color"
const META_POS := &"opensro_obj_color_at"
const META_MESHES := &"opensro_obj_color_meshes"
const META_VISITS := &"opensro_obj_color_visits"

## BodyPulse.ORIGINAL_META: a mesh drawing a pulse's own tinted copy (spelled
## out so this script does not name BodyPulse, which names it;
## object_light_test holds the two equal).
const PULSE_META := "body_pulse_original_material"

## OURS: bodies visited a frame, the distance a body must move before its
## tile is read again, and how many visits between rescans of its meshes.
const PER_FRAME := 12
const MOVE_EPSILON := 1.0
const RESCAN_VISITS := 8

## (Vector3 world position) -> [NavGraph, Node3D group] or [].
var lookup: Callable = Callable()
var _queue: Array = []
var _i := 0
## Bodies whose colour was (re)applied, for the log and the tests.
var applied := 0
## QA only: OPENSRO_QA_CHARLIGHT=1 prints every change (`QA CHARLIGHT`).
var _qa := OS.get_environment("OPENSRO_QA_CHARLIGHT") != ""
## QA only: OPENSRO_QA_CHARLIGHT_VALUE=<f> draws every character at <f>
## (the round 706 review's A/B of copies against their base).
var _qa_value := OS.get_environment("OPENSRO_QA_CHARLIGHT_VALUE").to_float() if OS.get_environment("OPENSRO_QA_CHARLIGHT_VALUE").is_valid_float() else -1.0

func _init(region_lookup: Callable = Callable()) -> void:
	lookup = region_lookup

## Visits up to PER_FRAME bodies of `tree`'s CharacterBlobs group. Returns
## how many were visited.
func step(tree: SceneTree) -> int:
	if tree == null:
		return 0
	if _i >= _queue.size():
		_queue = tree.get_nodes_in_group(CharacterBlobs.GROUP)
		_i = 0
	var n := 0
	while n < PER_FRAME and _i < _queue.size():
		var node = _queue[_i]
		_i += 1
		if not is_instance_valid(node) or not (node is Node3D) or not (node as Node3D).is_inside_tree():
			continue
		visit(node as Node3D)
		n += 1
	return n

## One body: its colour read and, if it changed or the meshes are due a
## rescan, set on its meshes.
func visit(body: Node3D) -> void:
	if body == null or not is_instance_valid(body) or not body.is_inside_tree():
		return
	var visits := int(body.get_meta(META_VISITS, 0)) + 1
	body.set_meta(META_VISITS, visits)
	# Each body's rescans fall on its own visits (round 748): counted from 1
	# alone, every body of a crowd that arrived together rescanned in the
	# same pass of the queue -- 12 rescans a frame for one pass in eight, the
	# rest none (MEASURED at 1000 standing: 0.05 to 1.8 ms a frame between
	# 6-second steps). The same one rescan in RESCAN_VISITS visits per body;
	# the offset is the id hashed, as consecutive bodies' ids step by their
	# node count (28 a body: two offsets in eight, MEASURED no better).
	var rescan := posmod(visits + hash(body.get_instance_id()), RESCAN_VISITS) == 1
	var pos := body.global_position
	var had := body.has_meta(META_VALUE)
	if had and not rescan and (body.get_meta(META_POS, Vector3.INF) as Vector3).distance_to(pos) < MOVE_EPSILON:
		return
	# No loaded region under it yet (a body placed while its region builds):
	# left as it is and visited again, not drawn at the original's "no region"
	# 1.0 -- the original always has the region a character stands in.
	if lookup.is_valid() and (lookup.call(pos) as Array).is_empty():
		return
	body.set_meta(META_POS, pos)
	var value := color_at(pos)
	if _qa_value >= 0.0:
		value = _qa_value
	if had and not rescan and is_equal_approx(float(body.get_meta(META_VALUE)), value):
		return
	body.set_meta(META_VALUE, value)
	set_on(body, value, rescan or not had)
	if on_value.is_valid():
		on_value.call(body, value)
	applied += 1
	if _qa:
		var meshes: Array = body.get_meta(META_MESHES, [])
		var copies := 0
		for m in meshes:
			if is_instance_valid(m) and (m as MeshInstance3D).material_override != null and (m as MeshInstance3D).material_override.has_meta(ObjectLight.VARIANT_BASE_META):
				copies += 1
		print("QA CHARLIGHT %s at %s: %s; %d of %d meshes on a copy" % [body.name, str(pos), describe(pos), copies, meshes.size()])

## The object colour at a world position (ObjectLight.character_color).
func color_at(pos: Vector3) -> float:
	return color_at_pair(pos, lookup.call(pos) if lookup.is_valid() else [])

## color_at with the region lookup's answer already in hand (round 756: a
## ghost asks whether a region is there and its colour with one lookup).
func color_at_pair(pos: Vector3, pair: Array) -> float:
	if pair.is_empty():
		return ObjectLight.character_color(-1, true)
	var graph: NavGraph = pair[0]
	var group: Node3D = pair[1]
	var local := group.to_local(pos)
	var on_terrain := true
	if graph != null:
		on_terrain = graph.surface_at(local.x, local.z, local.y).is_terrain
	var bytes: PackedByteArray = group.get_meta(SHADOW_META, PackedByteArray())
	return ObjectLight.character_color(ObjectLight.shadow_byte_at(bytes, local.x, local.z), on_terrain)

## What color_at read at `pos`, for the QA line.
func describe(pos: Vector3) -> String:
	var pair: Array = lookup.call(pos) if lookup.is_valid() else []
	if pair.is_empty():
		return "no region -> 1.0"
	var graph: NavGraph = pair[0]
	var group: Node3D = pair[1]
	var local := group.to_local(pos)
	var surf := graph.surface_at(local.x, local.z, local.y) if graph != null else null
	var bytes: PackedByteArray = group.get_meta(SHADOW_META, PackedByteArray())
	var b := ObjectLight.shadow_byte_at(bytes, local.x, local.z)
	return "%s local %.0f,%.0f %s byte %d -> %.3f" % [group.name, local.x, local.z,
		"terrain" if surf == null or surf.is_terrain else "object %d" % surf.object_index, b, color_at(pos)]

## Round 747: called with a body whose meshes set_on gave other materials
## (World3D: a far body's instances follow, CrowdGpu.refresh). Unset in tests.
static var on_changed: Callable = Callable()

## Round 756: called with every body whose colour visit() set, so a body drawn
## with no meshes of its own (a ghost, CrowdGpu.add_ghost) takes it too.
## Unset in tests.
static var on_value: Callable = Callable()

## Draws every mesh under `body` at object colour `value` (rescanning them
## when `rescan`): each object material, override or surface override, swapped
## for its copy at that level.
static func set_on(body: Node3D, value: float, rescan: bool = true) -> void:
	var changed := false
	var meshes: Array = body.get_meta(META_MESHES, [])
	if rescan or meshes.is_empty():
		meshes = body.find_children("*", "MeshInstance3D", true, false)
		if body is MeshInstance3D:
			meshes.append(body)
		body.set_meta(META_MESHES, meshes)
	for m in meshes:
		if not is_instance_valid(m):
			continue
		var mi := m as MeshInstance3D
		if mi.has_meta(PULSE_META):
			continue
		if ObjectLight.is_object_material(mi.material_override):
			var want := ObjectLight.with_object_color(mi.material_override, value)
			if want != mi.material_override:
				mi.material_override = want
				changed = true
		if mi.mesh == null:
			continue
		for i in mi.get_surface_override_material_count():
			var sm := mi.get_surface_override_material(i)
			if ObjectLight.is_object_material(sm):
				var want_s := ObjectLight.with_object_color(sm, value)
				if want_s != sm:
					mi.set_surface_override_material(i, want_s)
					changed = true
	if changed and on_changed.is_valid():
		on_changed.call(body)
