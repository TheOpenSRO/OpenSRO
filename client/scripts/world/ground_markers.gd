extends Node3D
class_name GroundMarkers

## The ring on the ground: the click-to-move destination marker and the
## selection circle under the selected character, which in the retail client
## are ONE object (round 698, docs/protocol/ground_markers.md). Labels: READ =
## recovered from sro_client.exe or read out of the asset bytes, MEASURED =
## counted or probed, INFERRED = follows from what was read but was not itself
## read, OURS = this project's choice.
##
## What retail does (READ):
## - The game process creates one CIODecal at world entry (`FUN_00786f30`,
##   0x7872d8: `FUN_00ba36d0(&CIODecal's class, 0)` stored at process+0x640),
##   sets its size +0x104 to 12.0 (`0xd8ace0`) and loads four textures into
##   its slots 0..3 (`FUN_00a633a0`): `effect\select_01.ddj` .. `select_04.ddj`
##   (Media.pk2). Nothing else ever writes +0x104 on it: one size for every
##   use, not scaled by the target's model.
## - A ground click (`UI_SILKMALL::FUN_0078f8d0` -> `FUN_009ec570`) stores the
##   destination, runs the click filter (`FUN_009ec240`) and then, with no
##   branch on what the filter decided, `FUN_00a631e0(region, pos)`: follow
##   nothing (+0x138 = 0), position = the click point, texture 0, shown.
##   A sky click's heading run (`FUN_009ebec0`) does not touch the decal.
## - Selecting a character (`FUN_00778650`, from the object click
##   `FUN_00792f00` and the 0xB045 select reply `FUN_0088b200`) sets the
##   texture by class -- CICMonster or CICCos (pets, horses, transports): 3;
##   else CICUser (players): 2; else 1 (NPCs, anything else) -- and
##   `FUN_00a631c0(id)`: follow that object, shown. Selecting yourself
##   (`FUN_00780ee0`) writes the selected id only: no ring. A teleport gate
##   (CITeleportGate, not a CICharactor) is not selected by the 0xB045 reply.
## - Deselecting (`FUN_00778650(0)`) clears the selected id only. The ring
##   hides itself, every frame (`CIODecal::vslot_009`), when the object it
##   follows is gone, or is a CICharactor whose vslot 0x50 says no (stealth
##   mode +0x2c2 == 4, the hidden flags) -- otherwise it moves to the object's
##   position.
## - The local player's 0xB021 echo of a HEADING move (kind 0: the arrow keys'
##   walk `FUN_009ebf40` and the sky-click run both send one) hides it
##   (`NetProcessInNavAndSkill::FUN_008a5750`, 0x8a59b3). Arriving at the
##   destination does not: the ring stays under the player.
## - The draw (`CIODecal::vslot_010` -> `SWorld::vslot_022`, 0x9f42d0):
##   the texture projected straight down onto the TERRAIN's height-map cells
##   (an ortho size x size view from 1000 below, `D3DXMatrixLookAtLH` +
##   `D3DXMatrixOrthoLH`), the 3 x 3 cells of 20 units round the point
##   (`Map::FUN_009f3c10`: trunc(size / 20 + 1) = 1 cell each way), clamp
##   addressing, colour = texture x texture factor 0xFFFFFFFF, alpha blend
##   SRCALPHA / INVSRCALPHA. Placed objects (a bridge, a floor) get nothing:
##   the ring is on the ground under them. When the 320-unit block under the
##   point is still water (PlaneType 1 with a non-zero WaveID) a flat
##   size x size quad is also drawn at the point's height + 0.1 (`0xe1b7fc`).
## - The rotation argument is the decal's own heading +0x8c, which no decal
##   path writes (INFERRED 0): the art's transparent cross lies along the
##   region axes. Nothing animates it.
##
## OURS:
## - DRAPE_LIFT: the drape is drawn 0.05 above the terrain's own vertices.
##   Retail draws on the exact vertices with D3DCMP_LESSEQUAL; here the drape
##   and the terrain go through different transforms, so equal heights could
##   z-fight.
## - The drape splits each cell the way OUR terrain mesh does (diagonal (r, c)
##   to (r + 1, c + 1), TerrainCollision's THE DIAGONAL), so it lies on what
##   is drawn. Retail's drape alternates the diagonal by cell parity
##   (0x9f3c10's two fans); whether retail's TERRAIN does too is not read here
##   (docs/TODO.md).
## - The heading-move hide happens when this client starts the run (it sends
##   positions, not retail's 0x7021 heading, and gets no echo).
## - Culling off (the terrain group's z mirror flips the winding).

## The four textures, slot = texture index (READ, 0x787300..0x78733c).
const TEXTURE_PATHS: Array[String] = [
	"effect\\select_01.ddj", "effect\\select_02.ddj", "effect\\select_03.ddj", "effect\\select_04.ddj"]
## Texture indices (READ: FUN_00a631e0 writes 0; FUN_00778650 writes 1/2/3).
const INDEX_GROUND := 0
const INDEX_OTHER := 1
const INDEX_PLAYER := 2
const INDEX_HOSTILE := 3
## READ: +0x104, 0xd8ace0.
const SIZE := 12.0
## READ: a height-map cell, 0xe1b830.
const CELL := 20.0
## READ: the still-water quad's lift, 0xe1b7fc.
const WATER_QUAD_LIFT := 0.1
## READ: PlaneType 1, the still surface (MapmWater.PLANE_STILL).
const STILL_WATER := 1
## READ: a block's span (MapmWater.BLOCK_SPAN).
const BLOCK_SPAN := 320.0
## OURS: see the header.
const DRAPE_LIFT := 0.05

## What was selected, for the texture (READ: the IsKindOf chain at 0x7786b7).
enum Kind { MONSTER, COS, PLAYER, NPC, ITEM }

## The texture index retail picks for a selected object's class.
static func texture_index_for(kind: int) -> int:
	match kind:
		Kind.MONSTER, Kind.COS:
			return INDEX_HOSTILE
		Kind.PLAYER:
			return INDEX_PLAYER
	return INDEX_OTHER

## Cells each way round the centre cell (READ: 0x9f3ccd, trunc(size / 20 + 1)).
static func cell_reach(size: float) -> int:
	return int(size / CELL + 1.0)

## The drape: the cells within cell_reach of the one under `center` (local
## x, z), each split into two triangles, every corner at `height.call(col,
## row)` + `lift`, its UV the vertical projection of a size x size square
## centred on `center`. A cell with a corner the callable cannot answer (NAN)
## is left out. Returns {"vertices": PackedVector3Array, "uvs":
## PackedVector2Array} in the same local frame, three vertices a triangle.
static func drape_arrays(center: Vector2, size: float, height: Callable, lift: float) -> Dictionary:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var reach := cell_reach(size)
	var c0 := int(floor(center.x / CELL))
	var r0 := int(floor(center.y / CELL))
	var origin := center - Vector2(size, size) * 0.5
	for row in range(r0 - reach, r0 + reach + 1):
		for col in range(c0 - reach, c0 + reach + 1):
			var h00: float = height.call(col, row)
			var h10: float = height.call(col + 1, row)
			var h01: float = height.call(col, row + 1)
			var h11: float = height.call(col + 1, row + 1)
			if is_nan(h00) or is_nan(h10) or is_nan(h01) or is_nan(h11):
				continue
			var p00 := Vector3(col * CELL, h00 + lift, row * CELL)
			var p10 := Vector3((col + 1) * CELL, h10 + lift, row * CELL)
			var p01 := Vector3(col * CELL, h01 + lift, (row + 1) * CELL)
			var p11 := Vector3((col + 1) * CELL, h11 + lift, (row + 1) * CELL)
			for p in [p00, p10, p11, p00, p11, p01]:
				var v: Vector3 = p
				verts.append(v)
				uvs.append(Vector2((v.x - origin.x) / size, (v.z - origin.y) / size))
	return {"vertices": verts, "uvs": uvs}

## The flat quad over still water (READ: 0x9f4a96's six corners), at `y`.
static func water_quad_arrays(center: Vector2, size: float, y: float) -> Dictionary:
	var h := size * 0.5
	var a := Vector3(center.x - h, y, center.y - h)
	var b := Vector3(center.x + h, y, center.y - h)
	var c := Vector3(center.x + h, y, center.y + h)
	var d := Vector3(center.x - h, y, center.y + h)
	return {"vertices": PackedVector3Array([a, b, c, a, c, d]),
		"uvs": PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)])}

## Whether a block draws the still-water quad (READ: 0x9f492e's two tests).
static func block_has_still_water(block: MapmReader.Block) -> bool:
	return block != null and block.plane_type == STILL_WATER and block.wave_id != 0

## The height of the drape's triangles at local (x, z), or NAN outside them --
## the measurement's side of the QA line (a drape triangle's own plane).
static func drape_height_at(arrays: Dictionary, x: float, z: float) -> float:
	var v: PackedVector3Array = arrays.get("vertices", PackedVector3Array())
	for i in range(0, v.size() - 2, 3):
		var a := v[i]
		var b := v[i + 1]
		var c := v[i + 2]
		var d := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
		if absf(d) < 1e-9:
			continue
		var w0 := ((b.z - c.z) * (x - c.x) + (c.x - b.x) * (z - c.z)) / d
		var w1 := ((c.z - a.z) * (x - c.x) + (a.x - c.x) * (z - c.z)) / d
		var w2 := 1.0 - w0 - w1
		if w0 >= -1e-6 and w1 >= -1e-6 and w2 >= -1e-6:
			return w0 * a.y + w1 * b.y + w2 * c.y
	return NAN

# --- The state: CIODecal's +0x108 (shown), +0x134 (texture), +0x138 (the
# followed object), +0x7c/+0x80 (where). ---------------------------------

var shown := false
var texture_index := INDEX_GROUND
## The followed object's key ("monster:<id>", "player:<id>", "npc:<instance>"),
## "" when the ring sits at a point.
var follow_key := ""
## Where the ring is, world space.
var center := Vector3.ZERO

## Where a followed key is now: (key) -> Vector3 world position, or null when
## the object is gone or hidden (vslot_009's two hide tests).
var _resolver: Callable
## Where the terrain groups (RealTerrain_<x>_<y>) are.
var _terrain_root: Node
var _grid: RegionGridState
## Loads a Media.pk2 texture: (path) -> Texture2D or null.
var _texture_loader: Callable

var _mesh_instance: MeshInstance3D
var _materials: Dictionary = {} ## texture index -> StandardMaterial3D, or null when the art did not load
var _built_center := Vector3.INF
var _built_index := -1
var _built_group: Node3D = null
var _dirty := true
## group name -> [ParsedRegion, PackedFloat32Array heights]
var _heights_cache: Dictionary = {}
var _qa_log := false
var _qa_rebuilds := 0
## SRREVAMP_QA_MARKER_VIEW="<pitch>,<length>" (QA only): each place / attach
## turns the camera arm to that pitch and length, so a frame shows the ring
## rather than the QA click's shallow aim. Vector2.ZERO: off.
var _qa_view := Vector2.ZERO
## The last drape built, for the QA line and the tests (local arrays, the
## group they are local to, whether the water quad was drawn).
var last_drape: Dictionary = {}

func setup(terrain_root: Node, grid: RegionGridState, texture_loader: Callable, resolver: Callable) -> void:
	_terrain_root = terrain_root
	_grid = grid
	_texture_loader = texture_loader
	_resolver = resolver
	_qa_log = OS.get_environment("SRREVAMP_QA_MARKER") != ""
	var view := OS.get_environment("SRREVAMP_QA_MARKER_VIEW").split(",")
	if view.size() == 2 and view[0].is_valid_float() and view[1].is_valid_float():
		_qa_view = Vector2(float(view[0]), float(view[1]))

func _ready() -> void:
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "Ring"
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh_instance.visible = false
	add_child(_mesh_instance)

## The mesh goes before the node does: freed with it, Godot 4.2.2's renderer
## asked for the freed mesh's surface count (`Parameter "m" is null`,
## mesh_get_surface_count, MEASURED in ground_markers_test under the dummy
## renderer).
func _exit_tree() -> void:
	if _mesh_instance != null:
		_mesh_instance.mesh = null
	_built_group = null
	_dirty = true

## A ground click (READ: FUN_00a631e0): the ring goes to the point with the
## ground texture, following nothing.
func place_at(point: Vector3) -> void:
	follow_key = ""
	center = point
	texture_index = INDEX_GROUND
	shown = true
	_dirty = true
	_qa_frame_view()
	if _qa_log:
		print("QA MARKER place: click point (%.2f, %.2f, %.2f), texture %d (%s)" % [point.x, point.y, point.z, texture_index, TEXTURE_PATHS[texture_index]])

## A selection (READ: FUN_00778650 + FUN_00a631c0): the ring follows `key`
## with the texture of its class. `at`, when given, is where it stands now.
func attach(key: String, kind: int, at: Variant = null) -> void:
	follow_key = key
	texture_index = texture_index_for(kind)
	shown = true
	if at is Vector3:
		center = at
	elif _resolver.is_valid():
		var p: Variant = _resolver.call(key)
		if p is Vector3:
			center = p
	_dirty = true
	_qa_frame_view()
	if _qa_log:
		print("QA MARKER attach: %s kind %d -> texture %d (%s) at (%.2f, %.2f, %.2f)" % [key, kind, texture_index, TEXTURE_PATHS[texture_index], center.x, center.y, center.z])

func _qa_frame_view() -> void:
	if _qa_view == Vector2.ZERO or not is_inside_tree():
		return
	var cam := get_viewport().get_camera_3d()
	var arm := cam.get_parent() as SpringArm3D if cam != null else null
	if arm != null:
		arm.rotation_degrees.x = _qa_view.x
		arm.spring_length = _qa_view.y

## Hidden, following nothing (+0x108 = 0, +0x138 = 0).
func hide_marker(why: String = "") -> void:
	if shown and _qa_log:
		print("QA MARKER hide (%s)" % why)
	shown = false
	follow_key = ""
	_dirty = true

## The local player's heading move (READ: 0x8a59b3 hides on its echo).
func heading_move() -> void:
	hide_marker("heading move")

## Once a frame (READ: CIODecal::vslot_009, then vslot_010's draw).
func step() -> void:
	if shown and follow_key != "":
		var p: Variant = _resolver.call(follow_key) if _resolver.is_valid() else null
		if not (p is Vector3):
			hide_marker("%s gone or hidden" % follow_key)
		elif (p as Vector3).distance_squared_to(center) > 1e-6:
			center = p
			_dirty = true
	_refresh()

func _refresh() -> void:
	if _mesh_instance == null:
		return
	if not shown:
		_mesh_instance.visible = false
		return
	var material := _material_for(texture_index)
	if material == null:
		# READ: vslot_010 draws only with the slot's texture loaded.
		_mesh_instance.visible = false
		return
	var group := _group_at(center)
	if _dirty or group != _built_group or texture_index != _built_index or center != _built_center:
		_rebuild(group, material)
	_mesh_instance.visible = _mesh_instance.mesh != null

func _rebuild(group: Node3D, material: Material) -> void:
	_dirty = false
	_built_group = group
	_built_index = texture_index
	_built_center = center
	last_drape = {}
	if group == null:
		# READ: no height-map block under the point (FUN_009ef640 fails): no drape.
		_mesh_instance.mesh = null
		return
	var local := group.to_local(center)
	var lc := Vector2(local.x, local.z)
	var drape := drape_arrays(lc, SIZE, func(c: int, r: int) -> float: return _vertex_height(group, c, r), DRAPE_LIFT)
	var water := false
	var verts: PackedVector3Array = (drape["vertices"] as PackedVector3Array).duplicate()
	var uvs: PackedVector2Array = (drape["uvs"] as PackedVector2Array).duplicate()
	var block := _block_at(group, local)
	if block_has_still_water(block):
		water = true
		var q := water_quad_arrays(lc, SIZE, local.y + WATER_QUAD_LIFT)
		verts.append_array(q["vertices"])
		uvs.append_array(q["uvs"])
	last_drape = {"arrays": drape, "group": group, "local": local, "water": water}
	if verts.is_empty():
		_mesh_instance.mesh = null
		return
	var world := PackedVector3Array()
	world.resize(verts.size())
	var xf := group.global_transform
	var to_self := global_transform.affine_inverse()
	for i in verts.size():
		world[i] = to_self * (xf * verts[i])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = world
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	_mesh_instance.mesh = mesh
	if _qa_log:
		_qa_rebuilds += 1
		if _qa_rebuilds <= 8 or _qa_rebuilds % 120 == 0:
			_qa_measure(group, local, drape, water)

## The QA measurement (SRREVAMP_QA_MARKER=1): the ring's centre against the
## point it was put at, the drape's own height there against a vertical ray
## at the terrain-only layer (a different probe: the physics heightfield),
## the cells and triangles drawn.
func _qa_measure(group: Node3D, local: Vector3, drape: Dictionary, water: bool) -> void:
	var drape_h := drape_height_at(drape, local.x, local.z)
	var ray_h := NAN
	if is_inside_tree():
		var hit := TerrainCollision.vertical_ray(get_world_3d().direct_space_state, center.x, center.z,
			center.y + 1000.0, center.y - 1000.0, 0b1000)
		if not hit.is_empty():
			ray_h = (hit["position"] as Vector3).y
	var drape_world := (group.global_transform * Vector3(local.x, drape_h, local.z)).y if not is_nan(drape_h) else NAN
	var reach := cell_reach(SIZE)
	var c0 := int(floor(local.x / CELL))
	var r0 := int(floor(local.z / CELL))
	print("QA MARKER drape: texture %d follow '%s' centre world (%.2f, %.2f, %.2f) in %s local (%.2f, %.2f); cells x %d..%d z %d..%d; %d triangles; drape at centre %.3f, terrain ray %.3f, drape - ray %.3f (lift %.2f); point y - terrain %.3f; water quad %s" % [
		texture_index, follow_key, center.x, center.y, center.z, group.name, local.x, local.z,
		c0 - reach, c0 + reach, r0 - reach, r0 + reach, (drape["vertices"] as PackedVector3Array).size() / 3,
		drape_world, ray_h, drape_world - ray_h, DRAPE_LIFT, center.y - ray_h, str(water)])

func _material_for(index: int) -> StandardMaterial3D:
	if _materials.has(index):
		return _materials[index]
	var tex: Texture2D = null
	if _texture_loader.is_valid():
		tex = _texture_loader.call(TEXTURE_PATHS[index])
	var mat: StandardMaterial3D = null
	if tex != null:
		mat = StandardMaterial3D.new()
		mat.albedo_texture = tex
		# READ: colour and alpha = texture x factor 0xFFFFFFFF, unlit,
		# SRCALPHA / INVSRCALPHA, clamp addressing (0x9f4508..0x9f468c).
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.texture_repeat = false
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_materials[index] = mat
	return mat

## The terrain group whose 1920 x 1920 contains a world point, or null.
func _group_at(p: Vector3) -> Node3D:
	if _terrain_root == null or not is_instance_valid(_terrain_root):
		return null
	for child in _terrain_root.get_children():
		if not (child is Node3D) or not String(child.name).begins_with("RealTerrain_"):
			continue
		var g := child as Node3D
		if g.is_queued_for_deletion():
			continue
		var l := g.to_local(p)
		if l.x >= 0.0 and l.z >= 0.0 and l.x < RegionGridState.REGION_SPAN and l.z < RegionGridState.REGION_SPAN:
			return g
	return null

func _parsed_for(group: Node3D) -> MapmReader.ParsedRegion:
	if _grid == null:
		return null
	var parts := String(group.name).trim_prefix("RealTerrain_").split("_")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return null
	return _grid.parsed_heightmaps.get(RegionGridState.region_key(int(parts[0]), int(parts[1])))

func _heights_for(group: Node3D) -> PackedFloat32Array:
	var parsed := _parsed_for(group)
	if parsed == null:
		return PackedFloat32Array()
	var cached: Array = _heights_cache.get(group.name, [])
	if cached.size() == 2 and cached[0] == parsed:
		return cached[1]
	var heights := TerrainCollision.heights_from_region(parsed)
	_heights_cache[group.name] = [parsed, heights]
	return heights

## The terrain's height at vertex (col, row) of `group`'s grid, which may lie
## in a neighbouring region; NAN where no loaded region has it.
func _vertex_height(group: Node3D, col: int, row: int) -> float:
	var side := TerrainCollision.SIDE
	if col >= 0 and row >= 0 and col < side and row < side:
		var h := _heights_for(group)
		if h.size() == side * side:
			return h[(side - 1 - row) * side + col]
		return NAN
	var world := group.global_transform * Vector3(col * CELL, 0.0, row * CELL)
	var other := _group_at(world)
	if other == null or other == group:
		return NAN
	var l := other.to_local(world)
	var oc := roundi(l.x / CELL)
	var orow := roundi(l.z / CELL)
	var oh := _heights_for(other)
	if oh.size() != side * side or oc < 0 or orow < 0 or oc >= side or orow >= side:
		return NAN
	var y := oh[(side - 1 - orow) * side + oc]
	return group.to_local(other.global_transform * Vector3(l.x, y, l.z)).y

func _block_at(group: Node3D, local: Vector3) -> MapmReader.Block:
	var parsed := _parsed_for(group)
	if parsed == null or parsed.blocks.size() != MapmReader.BLOCK_COUNT:
		return null
	var col := clampi(int(floor(local.x / BLOCK_SPAN)), 0, MapmReader.BLOCKS_PER_SIDE - 1)
	var row := clampi(int(floor(local.z / BLOCK_SPAN)), 0, MapmReader.BLOCKS_PER_SIDE - 1)
	return parsed.blocks[col + row * MapmReader.BLOCKS_PER_SIDE]
