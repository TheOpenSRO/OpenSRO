extends Node3D
class_name Footprints

## Footprints in sand and snow (round 808's follow-up; docs/protocol/
## animation_mixer.md, "Footprints"). READ, sro_client.exe:
##
## - **When.** The move state's animation-event handler (state 9's, 0xa5a3f0)
##   on a footstep key (event type 2) of a walk or run, while the body's
##   navigation cell is known: the cell's material (the high 16 bits of the
##   ground query, the tile2d type -- the footstep sounds' MATERIALS) 1 SAND
##   lays `effect\footstep_sand.ddj`, 9 SNOW `effect\footstep_snow.ddj`;
##   anything else nothing. The key's second parameter (+0xc) picks the foot:
##   0 `Bip01 L Toe0`, otherwise `Bip01 R Toe0`. The state's exit (0xa5a6b0)
##   lays both feet's at once when the body stops -- for a player character
##   only (the TypeID test of FUN_00504ed0).
## - **What.** SWorld::vslot_026 (0x9f2c20; the world 0x1101950's vtable
##   0xde4fb4 + 0x68) with (texture, 20000 ms, the toe's position, 2.0, 3.5,
##   the heading + 0.0785 (left) / - 0.0785 (right) rad, 0xffffffff, 0)
##   (constants 0xd86ecc, 0xde5b40, the double 0xde5b48): a 2.0 x 3.5
##   rectangle projected onto the ground within +-50 (0xd851a0) of the point
##   (Map::FUN_009f6040), the 2.0 across the angle's direction (cos a, sin a
##   -- 0xb44a10 is cos, 0xb44b40 sin) and the 3.5 along the facing, its
##   texture spread u across, v from heel to toe.
## - **How it draws** (Map::FUN_00a1fdb0): alpha-blended (SRCALPHA /
##   INVSRCALPHA), texture x a factor colour whose RGB the footprint flag
##   (+0x4c = 1, set by the caller) replaces with the world's object ambient
##   (world +0x6853.., environment channel 3) and whose alpha is 255 until the
##   last 0x3fc = 1020 ms, then falls linearly to 0.
##
## OURS: the print is a grid of 3 x 4 vertices on the terrain's height (the
## client clips the ground's own triangles); it is lifted 0.1 and depth-tested
## (the client draws it with depth off, before the objects); a body's keys are
## seen only within the sounds' 600 of the listener (AnimSounds), so a body
## farther away leaves none.

const LIFETIME_MS := 20000.0
const FADE_MS := 1020.0
const WIDTH := 2.0
const LENGTH := 3.5
const TOE_ANGLE := 0.07853981852531433
const SAND := 1
const SNOW := 9
const TEXTURES := {SAND: "effect\\footstep_sand.ddj", SNOW: "effect\\footstep_snow.ddj"}
const LIFT := 0.1
## The cap on prints alive at once (OURS: the client's list has none).
const MAX_PRINTS := 400

## func(path) -> Texture2D, and func(Vector3) -> float (the ground's height
## there, the point's own when unknown).
var load_texture: Callable = Callable()
var ground_height: Callable = Callable()
## The world's object ambient, the prints' colour.
var tint := Color(1, 1, 1)

var _prints: Array = []
var _textures := {}

class Print:
	var node: MeshInstance3D
	var material: StandardMaterial3D
	var left_ms := LIFETIME_MS

## Whether a material lays prints.
static func lays(material: int) -> bool:
	return material == SAND or material == SNOW

## The print's angle for heading `h` and the foot (`left`).
static func angle_for(h: float, left: bool) -> float:
	return h + TOE_ANGLE if left else h - TOE_ANGLE

## The print's alpha `left_ms` before its end.
static func alpha_at(left_ms: float) -> float:
	if left_ms >= FADE_MS:
		return 1.0
	return clampf(left_ms / FADE_MS, 0.0, 1.0)

## The rectangle's two axes in the world (x, z) for angle `a`: across (the
## 2.0, the angle's own direction) and along (the 3.5, the facing).
static func axes(a: float) -> Array:
	return [Vector2(cos(a), -sin(a)), RemoteFacing.facing_of(a)]

## Lays a print at the world point `at` (a toe) for heading `h`; false when
## the material lays none or its texture is missing.
func add(at: Vector3, h: float, left: bool, material: int) -> bool:
	if not lays(material):
		return false
	var tex := _texture(material)
	if tex == null:
		return false
	var a := angle_for(h, left)
	var ax: Array = axes(a)
	var across: Vector2 = ax[0]
	var along: Vector2 = ax[1]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cols := 3
	var rows := 4
	var verts: Array = []
	for r in rows:
		for c in cols:
			var u := float(c) / float(cols - 1)
			var v := float(r) / float(rows - 1)
			var off := across * (u - 0.5) * WIDTH + along * (v - 0.5) * LENGTH
			var p := Vector3(at.x + off.x, at.y, at.z + off.y)
			var y: float = float(ground_height.call(p)) if ground_height.is_valid() else at.y
			if absf(y - at.y) > 50.0:
				y = at.y
			verts.append([Vector3(off.x, y + LIFT - at.y, off.y), Vector2(u, v)])
	for r in rows - 1:
		for c in cols - 1:
			var i := r * cols + c
			for k in [i, i + 1, i + cols, i + 1, i + cols + 1, i + cols]:
				st.set_uv(verts[k][1])
				st.add_vertex(verts[k][0])
	var node := MeshInstance3D.new()
	node.mesh = st.commit()
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.albedo_texture = tex
	mat.albedo_color = Color(tint.r, tint.g, tint.b, 1.0)
	node.material_override = mat
	add_child(node)
	node.global_position = at
	var p := Print.new()
	p.node = node
	p.material = mat
	_prints.append(p)
	while _prints.size() > MAX_PRINTS:
		var old: Print = _prints.pop_front()
		if is_instance_valid(old.node):
			old.node.queue_free()
	return true

## Ages every print by `dt_ms`: the last 1020 ms fade, then it goes.
func step(dt_ms: float) -> void:
	if _prints.is_empty():
		return
	var keep: Array = []
	for p in _prints:
		var pr := p as Print
		pr.left_ms -= dt_ms
		if pr.left_ms <= 0.0 or not is_instance_valid(pr.node):
			if is_instance_valid(pr.node):
				pr.node.queue_free()
			continue
		if pr.left_ms < FADE_MS:
			pr.material.albedo_color = Color(tint.r, tint.g, tint.b, alpha_at(pr.left_ms))
		keep.append(pr)
	_prints = keep

## The world's object ambient changed (the zone, the time of day).
func set_tint(c: Color) -> void:
	tint = Color(clampf(c.r, 0.0, 1.0), clampf(c.g, 0.0, 1.0), clampf(c.b, 0.0, 1.0))
	for p in _prints:
		var pr := p as Print
		pr.material.albedo_color = Color(tint.r, tint.g, tint.b, alpha_at(pr.left_ms))

## Every print gone (a zone change).
func clear() -> void:
	for p in _prints:
		if is_instance_valid((p as Print).node):
			(p as Print).node.queue_free()
	_prints.clear()

func count() -> int:
	return _prints.size()

func _texture(material: int) -> Texture2D:
	if _textures.has(material):
		return _textures[material]
	var tex: Texture2D = load_texture.call(String(TEXTURES[material])) if load_texture.is_valid() else null
	_textures[material] = tex
	return tex
