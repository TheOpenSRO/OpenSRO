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
## - The mesh is rebuilt only when the 3 x 3 cell window under the ring
##   changes; inside it the art moves by a shader uniform (RING_SHADER: UV =
##   (local xz - origin) / size, the projection drape_arrays computes, so the
##   look is the same). Round 698's review measured 118 us a physics tick
##   rebuilding the mesh every tick under a moving target.
## - ON A PLACED FLOOR (round 701; THE USER'S DECISION of 2026-10-03, an
##   improvement over retail, which draws no ring on Jangan's plaza deck --
##   "That seems like a bug we should fix"): where the point stands on a
##   placed object's walkable surface, the ring is draped on that surface
##   instead of on the terrain under it. Where the point is on the terrain
##   the drape is retail's, unchanged. Every number in this branch is OURS:
##   - the floor test (floor_choice): the point more than
##     FLOOR_MIN_ABOVE_TERRAIN above the drawn terrain there, and a short ray
##     down from it (FLOOR_PROBE_UP above to FLOOR_PROBE_DOWN below, the pick
##     layers PICK_MASK) meets a body without the terrain-only bit
##     (TERRAIN_ONLY_MASK) -- placed objects collide on layer 1 alone, the
##     terrain on 0b1001;
##   - the samples: vertical rays on a FLOOR_STEP grid of the region's frame,
##     each from FLOOR_RAY_START above the point down to FLOOR_MAX_DROP below
##     it, so a roof or an awning over the point is never hit;
##   - the edges: a triangle with a corner that missed, or whose corners
##     differ by more than FLOOR_MAX_RISE, is left out, so nothing stretches
##     down a deck's side or up a wall;
##   - the look: the same shader, material and origin uniform in the
##     region's frame, so it is the terrain ring's projection;
##   - the cost: the test and the mesh run only when the point enters another
##     FLOOR_CELL x FLOOR_CELL cell or moves FLOOR_HEIGHT_TOLERANCE in height;
##     each build covers the art for anywhere in that cell, and samples are
##     kept until the height or the region changes. No still-water quad on a
##     floor.

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

## The placed-floor drape (round 701, all OURS: see the header).
const FLOOR_MIN_ABOVE_TERRAIN := 1.0
const FLOOR_PROBE_UP := 0.5
const FLOOR_PROBE_DOWN := 1.0
const FLOOR_STEP := 2.0
const FLOOR_RAY_START := 2.0
const FLOOR_MAX_DROP := 2.0
const FLOOR_MAX_RISE := 1.0
const FLOOR_CELL := 6.0
const FLOOR_HEIGHT_TOLERANCE := 0.25
## Samples kept before the cache starts over (a body walking a long deck).
const FLOOR_CACHE_MAX := 2048
## World3D.TERRAIN_COLLISION_LAYER (the ground pick's mask: placed objects on
## layer 1, the terrain on layers 1 and 4) and TERRAIN_ONLY_COLLISION_MASK.
const PICK_MASK := 0b1001
const TERRAIN_ONLY_MASK := 0b1000

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

## Whether a vertical ray's hit is a placed object rather than the terrain:
## a body on the pick layers without the terrain-only bit (OURS, round 701).
static func is_floor_hit(hit: Dictionary) -> bool:
	if hit.is_empty():
		return false
	var body := hit.get("collider") as CollisionObject3D
	return body != null and (body.collision_layer & TERRAIN_ONLY_MASK) == 0

## The floor test (OURS, round 701): `above_terrain` = the point's height less
## the drawn terrain's there; `probe` = the short ray down from the point.
static func floor_choice(above_terrain: float, probe: Dictionary) -> bool:
	return not is_nan(above_terrain) and above_terrain > FLOOR_MIN_ABOVE_TERRAIN and is_floor_hit(probe)

## Whether a floor sample at height `y` is on the floor round a point at
## `ref_y`: hit, and inside the ray's span.
static func floor_sample_ok(y: float, ref_y: float) -> bool:
	return not is_nan(y) and y >= ref_y - FLOOR_MAX_DROP and y <= ref_y + FLOOR_RAY_START

## The floor drape (OURS, round 701): the `count` x `count` grid points from
## index `lo`, point (i, j) at local (i * step, heights[(j - lo.y) * count +
## i - lo.x], j * step), each cell split on the terrain's diagonal (i, j)-(i +
## 1, j + 1). A triangle is left out when a corner fails floor_sample_ok or
## its corners differ by more than FLOOR_MAX_RISE. Corners at height + `lift`.
## Returns {"vertices": PackedVector3Array}, three a triangle, in the same
## frame.
static func floor_drape_arrays(lo: Vector2i, count: int, step: float, hs: PackedFloat32Array, ref_y: float, lift: float) -> Dictionary:
	if hs.size() != count * count:
		return {"vertices": PackedVector3Array()}
	var verts := PackedVector3Array()
	verts.resize((count - 1) * (count - 1) * 6)
	var n := 0
	for j in count - 1:
		for i in count - 1:
			var h00 := hs[j * count + i]
			var h10 := hs[j * count + i + 1]
			var h01 := hs[(j + 1) * count + i]
			var h11 := hs[(j + 1) * count + i + 1]
			var x0 := float(lo.x + i) * step
			var z0 := float(lo.y + j) * step
			var first := _floor_triangle_ok(h00, h10, h11, ref_y)
			var second := _floor_triangle_ok(h00, h11, h01, ref_y)
			if not (first or second):
				continue
			var p00 := Vector3(x0, h00 + lift, z0)
			var p11 := Vector3(x0 + step, h11 + lift, z0 + step)
			if first:
				verts[n] = p00
				verts[n + 1] = Vector3(x0 + step, h10 + lift, z0)
				verts[n + 2] = p11
				n += 3
			if second:
				verts[n] = p00
				verts[n + 1] = p11
				verts[n + 2] = Vector3(x0, h01 + lift, z0 + step)
				n += 3
	verts.resize(n)
	return {"vertices": verts}

## The heights floor_drape_arrays takes, from `sample.call(i, j)` (the tests).
static func floor_heights(lo: Vector2i, count: int, sample: Callable) -> PackedFloat32Array:
	var hs := PackedFloat32Array()
	hs.resize(count * count)
	for j in count:
		for i in count:
			hs[j * count + i] = float(sample.call(lo.x + i, lo.y + j))
	return hs

static func _floor_triangle_ok(a: float, b: float, c: float, ref_y: float) -> bool:
	if not (floor_sample_ok(a, ref_y) and floor_sample_ok(b, ref_y) and floor_sample_ok(c, ref_y)):
		return false
	return maxf(a, maxf(b, c)) - minf(a, minf(b, c)) <= FLOOR_MAX_RISE

## READ: a ground click within this squared distance (double 0xd878a8 =
## 400.0, so 20 units, `FUN_009ed1e0`'s 3-D squared distance) of a CICNPC
## (class link 0xef1ac4: NPCs and guards, not monsters, players or gates)
## whose +0xc4 is not 0 returns from `FUN_009ec570` (0x9ec5a0..0x9ec5eb)
## before the destination, the click filter and FUN_00a631e0: no walk, no
## ring. +0xc4 is the object's model scale (READ: its writer `FUN_009c4510`
## takes the spawn's scale -- CICNPC::vslot_025 0x9d487d, CICMonster's
## rarity x ref scale at 0x9d3a53 -- and resizes the model's box with it;
## the CIObject constructor sets 1.0), so the test is "an NPC drawn at a
## non-zero scale".
const NPC_CLICK_BLOCK_SQ := 400.0

## The NPC (from `npcs`, each a Node3D at its feet) that blocks a ground click
## at `point`, or null: the first within NPC_CLICK_BLOCK_SQ whose scale is
## not zero (READ: the list walk returns at the first hit).
static func npc_blocking(point: Vector3, npcs: Array) -> Node3D:
	for n in npcs:
		var npc := n as Node3D
		if npc == null or not is_instance_valid(npc):
			continue
		if npc.global_transform.basis.get_scale().is_zero_approx():
			continue
		if npc.global_position.distance_squared_to(point) < NPC_CLICK_BLOCK_SQ:
			return npc
	return null

## The world's NPC bodies (the RealTerrain_ groups' holders tagged npc_name;
## a teleport gate, tagged gate_point_id, is not a CICNPC).
func npcs() -> Array:
	var out := []
	if _terrain_root == null or not is_instance_valid(_terrain_root):
		return out
	for group in _terrain_root.get_children():
		if not (group is Node3D) or not String(group.name).begins_with("RealTerrain_"):
			continue
		for holder in group.get_children():
			if holder is Node3D and holder.has_meta("npc_name") and not holder.has_meta("gate_point_id"):
				out.append(holder)
	return out

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
var _materials: Dictionary = {} ## texture index -> ShaderMaterial, or null when the art did not load
## What the mesh was built for: the group, the window's first cell, the water
## quad's height (NAN: none). A centre moving inside the window only moves the
## shader's origin.
var _built_group: Node3D = null
var _built_window := Vector2i(1 << 30, 1 << 30)
var _built_water_y := NAN
var _dirty := true
## The placed-floor branch (round 701): what the floor test last ran for (the
## group, the FLOOR_CELL cell, the height), its answer, and whether the mesh
## is a floor drape. The samples: grid index -> region-local height (NAN: a
## miss), valid for one group and one reference height.
var on_floor := false
var _floor_key_group: Node3D = null
## The key's cell as its lower corner (region-local x, z) -- float compares
## are what a tick pays on the terrain path.
var _floor_key_x0 := INF
var _floor_key_z0 := INF
var _floor_key_y := NAN
var _built_is_floor := false
var _floor_samples: Dictionary = {}
var _floor_samples_group: Node3D = null
var _floor_samples_ref_y := NAN
## Rays fired for floor samples, for the cost note and the tests.
var floor_rays := 0
var _floor_query: PhysicsRayQueryParameters3D = null
## group name -> [WeakRef to the ParsedRegion, PackedFloat32Array heights]:
## only the heights are held, so a region RegionGridState prunes is freed
## (round 698's review); an entry whose region left the grid is dropped.
var _heights_cache: Dictionary = {}
var _qa_log := false
var _qa_rebuilds := 0
## A place or attach since the last QA line: measure the next draw.
var _qa_pending := false
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
	_qa_frame_view()
	_qa_pending = _qa_log
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
	_qa_frame_view()
	_qa_pending = _qa_log
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

## A zone change: hidden, and the terrain it was draped on forgotten.
func zone_changed() -> void:
	hide_marker("zone change")
	_heights_cache.clear()
	_floor_samples.clear()
	_floor_samples_group = null
	_floor_key_group = null
	_built_group = null
	_dirty = true

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
	if not _heights_cache.is_empty():
		_prune_heights()
	_refresh()

## Drops cached heights whose region is no longer in the grid (or was parsed
## again).
func _prune_heights() -> void:
	for name in _heights_cache.keys():
		var entry: Array = _heights_cache[name]
		var held: Object = (entry[0] as WeakRef).get_ref()
		if held == null or _grid == null or _grid.parsed_heightmaps.get(_region_key_of(String(name))) != held:
			_heights_cache.erase(name)

## How many regions' heights are cached (the review's test).
func cached_regions() -> int:
	return _heights_cache.size()

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
	if group == null:
		# READ: no height-map block under the point (FUN_009ef640 fails): no drape.
		_mesh_instance.mesh = null
		_mesh_instance.visible = false
		_built_group = null
		last_drape = {}
		return
	var local := group.to_local(center)
	# The placed-floor branch (round 701, OURS): the test and the floor mesh
	# run only when the point enters another FLOOR_CELL cell or moves in
	# height.
	if _dirty or group != _floor_key_group or local.x < _floor_key_x0 or local.z < _floor_key_z0 \
			or local.x >= _floor_key_x0 + FLOOR_CELL or local.z >= _floor_key_z0 + FLOOR_CELL \
			or not (absf(local.y - _floor_key_y) <= FLOOR_HEIGHT_TOLERANCE):
		var cell := Vector2i(floori(local.x / FLOOR_CELL), floori(local.z / FLOOR_CELL))
		_floor_key_group = group
		_floor_key_x0 = cell.x * FLOOR_CELL
		_floor_key_z0 = cell.y * FLOOR_CELL
		_floor_key_y = local.y
		on_floor = _floor_test(group, local)
		if on_floor:
			_rebuild_floor(group, local, cell)
	if not on_floor:
		var reach := cell_reach(SIZE)
		var window := Vector2i(int(floor(local.x / CELL)) - reach, int(floor(local.z / CELL)) - reach)
		var water_y := local.y + WATER_QUAD_LIFT if block_has_still_water(_block_at(group, local)) else NAN
		var water_changed := is_nan(water_y) != is_nan(_built_water_y) or (not is_nan(water_y) and absf(water_y - _built_water_y) > 1e-4)
		if _dirty or _built_is_floor or group != _built_group or window != _built_window or water_changed:
			_rebuild(group, local, window, water_y)
	if _mesh_instance.global_transform != group.global_transform:
		_mesh_instance.global_transform = group.global_transform
	if _mesh_instance.material_override != material:
		_mesh_instance.material_override = material
	material.set_shader_parameter("origin", Vector2(local.x, local.z) - Vector2(SIZE, SIZE) * 0.5)
	if not last_drape.is_empty():
		last_drape["local"] = local
		if _qa_pending:
			_qa_pending = false
			_qa_measure(group, local, last_drape["arrays"], bool(last_drape["water"]))
	_mesh_instance.visible = _mesh_instance.mesh != null

## The mesh for one 3 x 3 window, in the group's own frame (the instance takes
## the group's transform, so the shader's VERTEX.xz is region-local).
func _rebuild(group: Node3D, local: Vector3, window: Vector2i, water_y: float) -> void:
	_dirty = false
	_built_is_floor = false
	_built_group = group
	_built_window = window
	_built_water_y = water_y
	var lc := Vector2(local.x, local.z)
	var drape := drape_arrays(lc, SIZE, func(c: int, r: int) -> float: return _vertex_height(group, c, r), DRAPE_LIFT)
	var verts: PackedVector3Array = (drape["vertices"] as PackedVector3Array).duplicate()
	var water := not is_nan(water_y)
	if water:
		# The still-water quad over the whole window at the point's height + 0.1:
		# with clamp addressing and the art's transparent border this draws
		# exactly the READ size x size quad round the point, and it need not be
		# rebuilt as the point moves across the water.
		var reach := cell_reach(SIZE)
		var span := float(2 * reach + 1) * CELL
		var q := water_quad_arrays(Vector2(window) * CELL + Vector2(span, span) * 0.5, span, water_y)
		verts.append_array(q["vertices"])
	last_drape = {"arrays": drape, "group": group, "local": local, "water": water, "floor": false}
	_mesh_instance.global_transform = group.global_transform
	if verts.is_empty():
		_mesh_instance.mesh = null
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_instance.mesh = mesh
	if _qa_log and not _qa_pending:
		_qa_rebuilds += 1
		if _qa_rebuilds % 120 == 0:
			_qa_measure(group, local, drape, water)

## The floor test at region-local `local` of `group` (round 701, OURS;
## floor_choice).
func _floor_test(group: Node3D, local: Vector3) -> bool:
	var terrain := TerrainCollision.mesh_height_at(_heights_for(group), local.x, local.z)
	if is_nan(terrain) or local.y - terrain <= FLOOR_MIN_ABOVE_TERRAIN or not is_inside_tree():
		return false
	var world := group.global_transform * local
	var probe := TerrainCollision.vertical_ray(get_world_3d().direct_space_state, world.x, world.z,
		world.y + FLOOR_PROBE_UP, world.y - FLOOR_PROBE_DOWN, PICK_MASK)
	return floor_choice(local.y - terrain, probe)

## The floor mesh for the FLOOR_CELL cell `cell` round a point at `local`:
## the grid points whose 12 x 12 art can reach from anywhere in the cell.
func _rebuild_floor(group: Node3D, local: Vector3, cell: Vector2i) -> void:
	_dirty = false
	_built_is_floor = true
	_built_group = group
	_built_window = Vector2i(1 << 30, 1 << 30)
	_built_water_y = NAN
	if _floor_samples_group != group or not (absf(local.y - _floor_samples_ref_y) <= FLOOR_HEIGHT_TOLERANCE) \
			or _floor_samples.size() > FLOOR_CACHE_MAX:
		_floor_samples.clear()
		_floor_samples_group = group
		_floor_samples_ref_y = local.y
	var ref_y := _floor_samples_ref_y
	var per_cell := int(FLOOR_CELL / FLOOR_STEP)
	var reach := int(ceil(SIZE * 0.5 / FLOOR_STEP))
	var lo := Vector2i(cell.x * per_cell - reach, cell.y * per_cell - reach)
	var count := per_cell + 2 * reach + 1
	var space := get_world_3d().direct_space_state
	var xf := group.global_transform
	if _floor_query == null:
		_floor_query = PhysicsRayQueryParameters3D.new()
		_floor_query.collision_mask = PICK_MASK
	var query := _floor_query
	# A terrain group is translated and mirrored on z only
	# (TerrainCollision.place_group), so a local height is world y less its y.
	var y0 := xf.origin.y
	# One query object reused (OURS, the cost); each column nudged off a
	# terrain grid line as TerrainCollision.vertical_ray does, where a vertical
	# ray can slip through the heightfield.
	var hs := PackedFloat32Array()
	hs.resize(count * count)
	var top := ref_y + y0 + FLOOR_RAY_START
	var bottom := ref_y + y0 - FLOOR_MAX_DROP - 0.01
	for j in count:
		for i in count:
			var key := Vector2i(lo.x + i, lo.y + j)
			var known: Variant = _floor_samples.get(key)
			if known == null:
				var w := xf * Vector3(float(key.x) * FLOOR_STEP, 0.0, float(key.y) * FLOOR_STEP)
				var x := TerrainCollision.ray_columns(w.x)[0]
				var z := TerrainCollision.ray_columns(w.z)[0]
				query.from = Vector3(x, top, z)
				query.to = Vector3(x, bottom, z)
				var hit := space.intersect_ray(query)
				floor_rays += 1
				known = NAN if hit.is_empty() else (hit["position"] as Vector3).y - y0
				_floor_samples[key] = known
			hs[j * count + i] = known
	var drape := floor_drape_arrays(lo, count, FLOOR_STEP, hs, ref_y, DRAPE_LIFT)
	last_drape = {"arrays": drape, "group": group, "local": local, "water": false, "floor": true}
	_mesh_instance.global_transform = group.global_transform
	var verts: PackedVector3Array = drape["vertices"]
	if verts.is_empty():
		_mesh_instance.mesh = null
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_instance.mesh = mesh
	if _qa_log:
		print("QA MARKER floor: cell %s, %d grid points from %s, %d triangles, %d floor rays so far" % [
			str(cell), count * count, str(lo), verts.size() / 3, floor_rays])

## The QA measurement (SRREVAMP_QA_MARKER=1): the ring's centre against the
## point it was put at, the drape's own height there against a vertical ray
## at the terrain-only layer (a different probe: the physics heightfield),
## the cells and triangles drawn. On a placed floor (round 701) the ray is the
## pick layers' from FLOOR_RAY_START above the point, and the drape is also
## held against rays at the art's edges (+-5 on x and z); the drape's highest
## and lowest corners against the point say whether anything went up onto a
## roof or down a deck's side.
func _qa_measure(group: Node3D, local: Vector3, drape: Dictionary, water: bool) -> void:
	var floor_mode := bool(last_drape.get("floor", false))
	var drape_h := drape_height_at(drape, local.x, local.z)
	var ray_h := _qa_ray_height(group, local, floor_mode)
	var drape_world := (group.global_transform * Vector3(local.x, drape_h, local.z)).y if not is_nan(drape_h) else NAN
	var verts: PackedVector3Array = drape["vertices"]
	var tri := verts.size() / 3
	if floor_mode:
		var edges := PackedStringArray()
		for off in [Vector2(5, 0), Vector2(-5, 0), Vector2(0, 5), Vector2(0, -5)]:
			var o: Vector2 = off
			var p := Vector3(local.x + o.x, local.y, local.z + o.y)
			var dh := drape_height_at(drape, p.x, p.z)
			var rh := _qa_ray_height(group, p, true)
			edges.append("%+.0f,%+.0f: drape - ray %.3f" % [o.x, o.y, (dh + group.global_position.y) - rh] if not is_nan(dh) and not is_nan(rh)
				else "%+.0f,%+.0f: %s" % [o.x, o.y, "no triangle" if is_nan(dh) else "ray missed"])
		var hi := -INF
		var lo := INF
		for v in verts:
			hi = maxf(hi, v.y)
			lo = minf(lo, v.y)
		print("QA MARKER drape: FLOOR texture %d follow '%s' centre world (%.2f, %.2f, %.2f) in %s local (%.2f, %.2f); %d triangles; drape at centre %.3f, floor ray %.3f, drape - ray %.3f (lift %.2f); corners from point %+.3f..%+.3f; edges [%s]" % [
			texture_index, follow_key, center.x, center.y, center.z, group.name, local.x, local.z, tri,
			drape_world, ray_h, drape_world - ray_h, DRAPE_LIFT, lo - local.y, hi - local.y, ", ".join(edges)])
		return
	var reach := cell_reach(SIZE)
	var c0 := int(floor(local.x / CELL))
	var r0 := int(floor(local.z / CELL))
	print("QA MARKER drape: texture %d follow '%s' centre world (%.2f, %.2f, %.2f) in %s local (%.2f, %.2f); cells x %d..%d z %d..%d; %d triangles; drape at centre %.3f, terrain ray %.3f, drape - ray %.3f (lift %.2f); point y - terrain %.3f; water quad %s" % [
		texture_index, follow_key, center.x, center.y, center.z, group.name, local.x, local.z,
		c0 - reach, c0 + reach, r0 - reach, r0 + reach, tri,
		drape_world, ray_h, drape_world - ray_h, DRAPE_LIFT, center.y - ray_h, str(water)])

## A vertical ray's height (world) under region-local `p` of `group`: the
## terrain-only layer from 1000 above, or on a floor the pick layers from
## FLOOR_RAY_START above the point. NAN on a miss.
func _qa_ray_height(group: Node3D, p: Vector3, floor_mode: bool) -> float:
	if not is_inside_tree():
		return NAN
	var w := group.global_transform * p
	var top := center.y + (FLOOR_RAY_START if floor_mode else 1000.0)
	var bottom := center.y - (FLOOR_MAX_DROP if floor_mode else 1000.0)
	var hit := TerrainCollision.vertical_ray(get_world_3d().direct_space_state, w.x, w.z, top, bottom,
		PICK_MASK if floor_mode else TERRAIN_ONLY_MASK)
	return NAN if hit.is_empty() else (hit["position"] as Vector3).y

## READ: colour and alpha = texture x factor 0xFFFFFFFF, unlit, SRCALPHA /
## INVSRCALPHA, clamp addressing (0x9f4508..0x9f468c); the UV is the vertical
## projection of a size x size square at `origin` (region-local), what
## drape_arrays' UVs are. The settings StandardMaterial3D had in round 698's
## first version: unshaded, alpha blend, depth drawn for opaque only, no
## culling, linear filter without mipmaps, no repeat, the art as sRGB colour.
const RING_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_opaque, cull_disabled, shadows_disabled;
uniform sampler2D art : source_color, filter_linear, repeat_disable;
uniform vec2 origin;
uniform float size = 12.0;
void vertex() {
	UV = (VERTEX.xz - origin) / size;
}
void fragment() {
	vec4 c = texture(art, UV);
	ALBEDO = c.rgb;
	ALPHA = c.a;
}
"""
static var _ring_shader: Shader = null

func _material_for(index: int) -> ShaderMaterial:
	if _materials.has(index):
		return _materials[index]
	var tex: Texture2D = null
	if _texture_loader.is_valid():
		tex = _texture_loader.call(TEXTURE_PATHS[index])
	var mat: ShaderMaterial = null
	if tex != null:
		if _ring_shader == null:
			_ring_shader = Shader.new()
			_ring_shader.code = RING_SHADER
		mat = ShaderMaterial.new()
		mat.shader = _ring_shader
		mat.set_shader_parameter("art", tex)
		mat.set_shader_parameter("size", SIZE)
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

## "RealTerrain_97_168" -> "97_168" (RegionGridState.region_key), or "".
## Remembered per name (round 701: the floor test asks on every 6-unit cell a
## followed body enters, and the split cost the terrain path 2 us a tick).
static func _region_key_of(group_name: String) -> String:
	var known: Variant = _region_keys.get(group_name)
	if known != null:
		return known
	var parts := group_name.trim_prefix("RealTerrain_").split("_")
	var key := ""
	if parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int():
		key = RegionGridState.region_key(int(parts[0]), int(parts[1]))
	_region_keys[group_name] = key
	return key
static var _region_keys: Dictionary = {}

func _parsed_for(group: Node3D) -> MapmReader.ParsedRegion:
	if _grid == null:
		return null
	return _grid.parsed_heightmaps.get(_region_key_of(String(group.name)))

func _heights_for(group: Node3D) -> PackedFloat32Array:
	var parsed := _parsed_for(group)
	if parsed == null:
		return PackedFloat32Array()
	var cached: Array = _heights_cache.get(group.name, [])
	if cached.size() == 2 and (cached[0] as WeakRef).get_ref() == parsed:
		return cached[1]
	var heights := TerrainCollision.heights_from_region(parsed)
	_heights_cache[group.name] = [weakref(parsed), heights]
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
