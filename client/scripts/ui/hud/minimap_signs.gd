extends Control
class_name MinimapSigns

## Round 757: the minimap's entity signs (HudMinimap.update_signs, round 630),
## drawn as one MultiMesh per kind -- one draw call a kind -- instead of one
## TextureRect per sign.
##
## MEASURED (round 757, the 7,000-body lineup at the Jangan spawn): every body
## of the crowd lands inside the sign circle, so the minimap held 7,005
## TextureRects. Placing them cost 8.45 ms of the main thread a frame
## (`p_minimap`: the fill over every body's global_position plus a position
## and visibility set per sign), and Godot 4.2.2's canvas renderer draws each
## TextureRect with a draw call of its own (RD has no 2D batching before 4.4,
## READ), all inside the main view's render.
##
## The look is the same rule (READ, vslot_013, see HudMinimap): a sign is an
## 8 x 8 quad of its kind's artwork centred on `sign_offset`, drawn only while
## that offset is under SIGN_RADIUS. Here the GPU applies it: each instance
## carries its entity's world (x, z) in INSTANCE_CUSTOM, and the shader takes
## it to the aperture with the player's position and the map scale (uniforms),
## and drops it past the radius. So a frame with nothing moving writes nothing:
## the player's move and the zoom are four uniforms.
##
## OURS: the kinds are drawn in a fixed order (npc, monster, other), where the
## TextureRects drew in the order their pools grew; two signs of different
## kinds that overlap may stack the other way round.

static var KINDS: Array = ["npc", "monster", "other"]
const FLOATS := 12  # a 2D transform (8) and the custom data (4)

const SHADER_CODE := "shader_type canvas_item;
uniform vec2 player_world = vec2(0.0);
uniform float px_per_unit = 0.0;
uniform vec2 centre = vec2(0.0);
uniform float radius = 0.0;
void vertex() {
	vec2 off = (INSTANCE_CUSTOM.xy - player_world) * px_per_unit;
	if (INSTANCE_CUSTOM.z < 0.5 || length(off) >= radius) {
		VERTEX = vec2(-100000.0);
	} else {
		VERTEX = centre + off + VERTEX;
	}
}
"

class Kind:
	var texture: Texture2D
	var mm: MultiMesh
	var buf := PackedFloat32Array()
	var cap := 0
	var used := 0          # instances in use (the high-water mark for keyed kinds)
	var dirty := false
	## Keyed kinds only (`other`): id -> slot, and the free slots.
	var slot_of := {}
	var free: Array[int] = []
	var ids := PackedInt64Array()

var _kinds := {}
var _quad: ArrayMesh
var _material: ShaderMaterial
## Sign quad size (HudMinimap.SIGN_SIZE).
var sign_size := Vector2(8, 8)

static var _shader: Shader = null

func _init() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER_CODE
	_material = ShaderMaterial.new()
	_material.shader = _shader
	material = _material

## The artwork of `kind` (no artwork: the kind draws nothing).
func set_texture(kind: String, tex: Texture2D) -> void:
	var k := _kind(kind)
	k.texture = tex
	queue_redraw()

func has_texture(kind: String) -> bool:
	return _kinds.has(kind) and (_kinds[kind] as Kind).texture != null

func _kind(kind: String) -> Kind:
	var k: Kind = _kinds.get(kind)
	if k == null:
		k = Kind.new()
		_kinds[kind] = k
	return k

func _ensure_quad() -> void:
	if _quad != null:
		return
	var h := sign_size / 2.0
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector2Array([Vector2(-h.x, -h.y), Vector2(h.x, -h.y), Vector2(h.x, h.y), Vector2(-h.x, h.y)])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	_quad = ArrayMesh.new()
	_quad.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

func _grow(k: Kind, need: int) -> void:
	if need <= k.cap:
		return
	_ensure_quad()
	var cap := maxi(64, k.cap)
	while cap < need:
		cap *= 2
	var old := k.cap
	k.buf.resize(cap * FLOATS)
	for i in range(old, cap):
		_write(k, i, 0.0, 0.0, 0.0)
	if k.mm == null:
		k.mm = MultiMesh.new()
		k.mm.transform_format = MultiMesh.TRANSFORM_2D
		k.mm.use_custom_data = true
		k.mm.mesh = _quad
	k.cap = cap
	k.mm.instance_count = cap
	k.dirty = true
	queue_redraw()

## Instance `i` of `k`: the identity transform and (x, z, shown, 0).
static func _write(k: Kind, i: int, x: float, z: float, shown: float) -> void:
	var o := i * FLOATS
	k.buf[o] = 1.0
	k.buf[o + 1] = 0.0
	k.buf[o + 2] = 0.0
	k.buf[o + 3] = 0.0
	k.buf[o + 4] = 0.0
	k.buf[o + 5] = 1.0
	k.buf[o + 6] = 0.0
	k.buf[o + 7] = 0.0
	k.buf[o + 8] = x
	k.buf[o + 9] = z
	k.buf[o + 10] = shown
	k.buf[o + 11] = 0.0

## A whole kind from a list of world positions (npc, monster: a few dozen,
## refilled each frame as before).
func set_list(kind: String, positions: Array) -> void:
	var k := _kind(kind)
	if k.texture == null:
		return
	_grow(k, positions.size())
	var n := 0
	for p in positions:
		var v: Vector3 = p
		_write(k, n, v.x, v.z, 1.0)
		n += 1
	for i in range(n, k.used):
		k.buf[i * FLOATS + 10] = 0.0
	k.used = n
	k.dirty = true

## A keyed sign (`other`: one per other player, written when it moves).
func put(kind: String, id: int, world: Vector3, shown: bool = true) -> void:
	var k := _kind(kind)
	if k.texture == null:
		return
	var slot: int = k.slot_of.get(id, -1)
	if slot < 0:
		if not k.free.is_empty():
			slot = k.free.pop_back()
		else:
			slot = k.used
			k.used += 1
			_grow(k, k.used)
			k.ids.resize(k.cap)
		k.slot_of[id] = slot
		k.ids[slot] = id
	var o := slot * FLOATS
	var on := 1.0 if shown else 0.0
	# Only a change goes up (World3D's spread re-read finds most signs where
	# they were).
	if k.buf[o + 8] == world.x and k.buf[o + 9] == world.z and k.buf[o + 10] == on and k.buf[o] == 1.0:
		return
	_write(k, slot, world.x, world.z, on)
	k.dirty = true

func drop(kind: String, id: int) -> void:
	var k: Kind = _kinds.get(kind)
	if k == null or not k.slot_of.has(id):
		return
	var slot: int = k.slot_of[id]
	k.slot_of.erase(id)
	k.buf[slot * FLOATS + 10] = 0.0
	k.free.append(slot)
	k.dirty = true

func clear_kind(kind: String) -> void:
	var k: Kind = _kinds.get(kind)
	if k == null:
		return
	for i in range(k.used):
		k.buf[i * FLOATS + 10] = 0.0
	k.slot_of.clear()
	k.free.clear()
	k.used = 0
	k.dirty = true

## The ids a keyed kind holds (the caller's spread check for departed ids).
func keyed_ids(kind: String) -> Array:
	var k: Kind = _kinds.get(kind)
	return k.slot_of.keys() if k != null else []

func keyed_count(kind: String) -> int:
	var k: Kind = _kinds.get(kind)
	return k.slot_of.size() if k != null else 0

## The frame's place: the player (world), the map's pixels a region, the
## aperture centre and the sign radius. Then every changed kind goes up.
func place(player_world: Vector3, tile_px: float, centre: Vector2, radius: float, region_span: float) -> void:
	_material.set_shader_parameter("player_world", Vector2(player_world.x, player_world.z))
	_material.set_shader_parameter("px_per_unit", tile_px / region_span)
	_material.set_shader_parameter("centre", centre)
	_material.set_shader_parameter("radius", radius)
	for kind in _kinds:
		var k: Kind = _kinds[kind]
		if k.dirty and k.mm != null:
			k.dirty = false
			RenderingServer.multimesh_set_buffer(k.mm.get_rid(), k.buf)
			k.mm.visible_instance_count = k.used

## How many signs of `kind` the rule draws now (the log line; O(n)).
func drawn(kind: String, player_world: Vector3, tile_px: float, radius: float, region_span: float) -> int:
	var k: Kind = _kinds.get(kind)
	if k == null or k.texture == null:
		return 0
	var n := 0
	var s := tile_px / region_span
	for i in range(k.used):
		var o := i * FLOATS
		if k.buf[o + 10] < 0.5:
			continue
		var off := Vector2(k.buf[o + 8] - player_world.x, k.buf[o + 9] - player_world.z) * s
		if off.length() < radius:
			n += 1
	return n

func _draw() -> void:
	for kind in KINDS:
		var k: Kind = _kinds.get(kind)
		if k != null and k.mm != null and k.texture != null:
			draw_multimesh(k.mm, k.texture)
