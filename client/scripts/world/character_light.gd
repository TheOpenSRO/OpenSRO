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
## group), and the value set as the `object_color` instance uniform of every
## mesh under it. The original updates it with every position; here a
## character is revisited every couple of frames, and skipped while it has
## not moved (MOVE_EPSILON). A mesh added to a body (a new piece of
## equipment) takes the value at the body's next full rescan (RESCAN_VISITS).

## The ShadowMap a terrain group carries (World3D._terrain_commit).
const SHADOW_META := &"opensro_shadow_map"
## Per-body memory.
const META_VALUE := &"opensro_obj_color"
const META_POS := &"opensro_obj_color_at"
const META_MESHES := &"opensro_obj_color_meshes"
const META_VISITS := &"opensro_obj_color_visits"

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
	var visits := int(body.get_meta(META_VISITS, 0)) + 1
	body.set_meta(META_VISITS, visits)
	var rescan := visits % RESCAN_VISITS == 1
	var pos := body.global_position
	var had := body.has_meta(META_VALUE)
	if had and not rescan and (body.get_meta(META_POS, Vector3.INF) as Vector3).distance_to(pos) < MOVE_EPSILON:
		return
	body.set_meta(META_POS, pos)
	var value := color_at(pos)
	if had and not rescan and is_equal_approx(float(body.get_meta(META_VALUE)), value):
		return
	body.set_meta(META_VALUE, value)
	set_on(body, value, rescan or not had)
	applied += 1
	if _qa:
		print("QA CHARLIGHT %s at %s: %s" % [body.name, str(pos), describe(pos)])

## The object colour at a world position (ObjectLight.character_color).
func color_at(pos: Vector3) -> float:
	var pair: Array = lookup.call(pos) if lookup.is_valid() else []
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

## Sets `value` on every mesh under `body` (rescanning them when `rescan`).
static func set_on(body: Node3D, value: float, rescan: bool = true) -> void:
	var meshes: Array = body.get_meta(META_MESHES, [])
	if rescan or meshes.is_empty():
		meshes = body.find_children("*", "MeshInstance3D", true, false)
		if body is MeshInstance3D:
			meshes.append(body)
		body.set_meta(META_MESHES, meshes)
	var v := Vector3(value, value, value)
	for m in meshes:
		if is_instance_valid(m):
			(m as MeshInstance3D).set_instance_shader_parameter(ObjectLight.INSTANCE_OBJECT_COLOR, v)
