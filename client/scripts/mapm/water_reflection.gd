extends Node
class_name WaterReflection

## The Water Reflection option (round 628): retail's `Map::FUN_00a2df70`,
## drawn in Godot's Compatibility renderer. The labels are READ (recovered
## from sro_client.exe; the addresses are in WORLD_ISSUES.md's
## six-hundred-and-twenty-eighth round), INFERRED and OURS.
##
## What retail does (READ):
## - The option is video control 4, `UIIT_STT_WATER_REFLECTION`: world
##   option 6, world+0x2e68, saved as tag 5 of Setting\SROptionSet.dat. It
##   is ON in the shipped file, so it is ON by default here too.
## - Each frame the reflection plane is the PlaneHeight of the first block in
##   the drawn-block list (nearest the camera's block) that has water
##   (PlaneType != -1, state != 0). With no such block, nothing is drawn.
## - "Underwater" (world+0x26bb) is the camera's eye below plane + 0.5 while
##   the camera's own block has water.
## - `FUN_00a2dc20` renders the landscape pass (`FUN_00a26f60`) into a 512x512
##   target with its own depth buffer, clearing depth only. Above water, the
##   camera eye is mirrored in the plane (y' = 2h - y) and its look direction's
##   y negated. Underwater, the camera is unchanged. A user clip plane at the
##   water keeps the right side. Water itself is not drawn into it (the
##   water pass checks world+0x26c3, the reflection flag).
## - The surface samples the target by projective texture coordinates from
##   camera space, which is the screen position, flipped vertically above
##   water, with a 0.02 v bias. A bump stage (BUMPENVMAPLUMINANCE)
##   perturbs those coordinates by waterbump3.ddj's gradient times a 2x2
##   matrix that turns at 4.5 rad per time unit with magnitude 0.04.
## - Above water:
##   - PlaneType 0 is the reflection x WaterColor at its shoreline alpha;
##     the water1NN frames are NOT used.
##   - PlaneType 1 is 0.784 water201 + 0.216 reflection at alpha 0.784.
##   - Underwater, every drawn block is the reflection x WaterColor x 128/255
##     at alpha 200/255.
## - Both sides are drawn, blended SRCALPHA / INVSRCALPHA.
##
## What is OURS:
## - No user clip plane. Godot 4.2 has none, so geometry below the plane is
##   kept out of the mirror only by back-face culling. The terrain culls its
##   underside, but a two-sided prop below the water still shows.
## - The target is 512 rows high and as wide as the screen's aspect needs.
##   Retail's is 512x512 stretched over its frustum; a Godot camera cannot
##   stretch.
## - The plane is chosen among the loaded water blocks by block distance
##   alone, not also by the view test.
## - The bump time is Godot's seconds. Retail's is `*(float*)(DAT_0110f7d0 +
##   0xa0)`, whose unit is INFERRED to be seconds.

const TARGET_ROWS := 512
const QA_WINDOW := 10
## READ: `_DAT_00de4f70` = 0.04 (as a double), and the angle is t * 0.5 * 9.
const BUMP_SCALE := 0.04
const BUMP_RATE := 4.5
## READ: `_DAT_00e1b7d0` = 0.5, the eye's margin below the plane.
const UNDERWATER_MARGIN := 0.5
## Visual layer the water meshes are on, so the mirror camera leaves them out
## (OURS: layer 20; READ that retail does not draw water into the target).
const WATER_LAYER_BIT := 1 << 19

const SHADER := preload("res://scripts/mapm/water_reflection.gdshader")

var _viewport: SubViewport
var _camera: Camera3D
## [WeakRef(group), PackedFloat32Array of (local_x0, local_z0, plane) per drawn block].
var _regions: Array = []
var materials: Array[ShaderMaterial] = []
var plane_height := NAN
var underwater := false
var active := false
var _qa_timing := false
var _qa_frames := 0
var _qa_main_ms := 0.0
var _qa_refl_ms := 0.0

## The option, mirroring retail's: ClientSettings [world] water_reflection,
## default ON as the shipped SROptionSet.dat has it; SRREVAMP_WATER_REFLECTION
## (0 or 1) overrides it for a run.
static func enabled() -> bool:
	var env := OS.get_environment("SRREVAMP_WATER_REFLECTION")
	if env != "":
		return env != "0"
	return bool(ClientSettings.get_value(ClientSettings.SECTION_WORLD, ClientSettings.KEY_WATER_REFLECTION, true))

## waterbump3.ddj as the bump stage reads it (READ, `Map::FUN_009f2050`):
## - du = (left - right) / 2 and dv = (row above - row below) / 2 on byte 0
##   (blue), wrapping at the edges, C division (toward zero);
## - stored V8U8.
## Returned as RG8 with 128 meaning 0.
static func bump_image(src: Image) -> Image:
	if src == null or src.is_empty():
		return null
	var img := src.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var px := img.get_data()
	var rg := PackedByteArray()
	rg.resize(w * h * 2)
	for y in range(h):
		var up := ((y - 1 + h) % h) * w
		var down := ((y + 1) % h) * w
		var row := y * w
		for x in range(w):
			# RGBA8: blue is byte 2 -- D3D's A8R8G8B8 byte 0.
			var left: int = px[(row + (x - 1 + w) % w) * 4 + 2]
			var right: int = px[(row + (x + 1) % w) * 4 + 2]
			var above: int = px[(up + x) * 4 + 2]
			var below: int = px[(down + x) * 4 + 2]
			var o := (row + x) * 2
			rg[o] = _c_half(left - right) + 128
			rg[o + 1] = _c_half(above - below) + 128
	return Image.create_from_data(w, h, false, Image.FORMAT_RG8, rg)

## C's `int / 2`: truncates toward zero.
static func _c_half(v: int) -> int:
	return v / 2 if v >= 0 else -((-v) / 2)

## D3DTSS_BUMPENVMAT00, 01, 10, 11 at time t (READ, `SWorld::vslot_004` at 0x00a2cf60 writes
## world+0x2c10/0x2c14/0x2c20/0x2c24): [[0.04 cos, -0.04 sin], [0.04 sin,
## 0.04 cos]] of t * 4.5.
static func bump_matrix(t: float) -> Vector4:
	var a := t * BUMP_RATE
	return Vector4(BUMP_SCALE * cos(a), -BUMP_SCALE * sin(a), BUMP_SCALE * sin(a), BUMP_SCALE * cos(a))

## The camera mirrored in the plane y = h (READ: eye y' = 2h - y, look y
## negated). The mirror has determinant -1; a camera needs a rotation, so the
## up axis is negated too, which renders the reflection upside down -- the
## shader's 1 - v undoes it.
static func mirror_transform(t: Transform3D, h: float) -> Transform3D:
	var b := t.basis
	var x := Vector3(b.x.x, -b.x.y, b.x.z)
	var y := Vector3(b.y.x, -b.y.y, b.y.z)
	var z := Vector3(b.z.x, -b.z.y, b.z.z)
	var o := t.origin
	return Transform3D(Basis(x, -y, z), Vector3(o.x, 2.0 * h - o.y, o.z))

## The reflection plane (READ): the plane of the water block nearest the
## camera's block by squared block distance, ties to the first found. Blocks
## are (world block col, world block row, plane) triples. NAN when none.
static func pick_plane(blocks: Array, cam_col: int, cam_row: int) -> float:
	var best := NAN
	var best_d := 0x7fffffff
	for b in blocks:
		var dc: int = int(b[0]) - cam_col
		var dr: int = int(b[1]) - cam_row
		var d := dc * dc + dr * dr
		if d < best_d:
			best_d = d
			best = float(b[2])
	return best

## world+0x26bb (READ): eye - 0.5 below the plane, over a water block.
static func is_underwater(eye_y: float, plane: float, camera_block_has_water: bool) -> bool:
	return camera_block_has_water and eye_y - UNDERWATER_MARGIN < plane

func _ready() -> void:
	_viewport = SubViewport.new()
	_viewport.name = "WaterReflectionTarget"
	_viewport.size = Vector2i(TARGET_ROWS, TARGET_ROWS)
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.handle_input_locally = false
	_viewport.gui_disable_input = true
	add_child(_viewport)
	_camera = Camera3D.new()
	_camera.cull_mask = 0xFFFFF & ~WATER_LAYER_BIT
	_viewport.add_child(_camera)
	_qa_timing = OS.get_environment("SRREVAMP_QA_WATER_TIMING") != ""
	if _qa_timing:
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
		RenderingServer.viewport_set_measure_render_time(_viewport.get_viewport_rid(), true)

## A material for one kind of surface, fed every frame by this node.
func make_material(still: bool, bump: Texture2D, still_tex: Texture2D, water_color: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter("still", still)
	m.set_shader_parameter("bump_tex", bump)
	m.set_shader_parameter("still_tex", still_tex)
	m.set_shader_parameter("reflection_tex", _viewport.get_texture())
	m.set_shader_parameter("water_color", Vector3(water_color.r, water_color.g, water_color.b))
	materials.append(m)
	return m

func set_water_color(c: Color) -> void:
	for m in materials:
		m.set_shader_parameter("water_color", Vector3(clampf(c.r, 0, 1), clampf(c.g, 0, 1), clampf(c.b, 0, 1)))

## A region's drawn water blocks, for choosing the plane.
func register_region(group: Node3D, blocks: PackedFloat32Array) -> void:
	_regions.append([weakref(group), blocks])

## The drawn water blocks around, as world (col, row, plane_y) triples, and
## whether the camera's own block is one of them.
func _world_blocks(cam_pos: Vector3) -> Array:
	var out: Array = []
	var cam_col := int(floorf(cam_pos.x / MapmWater.BLOCK_SPAN))
	var cam_row := int(floorf(cam_pos.z / MapmWater.BLOCK_SPAN))
	var own := false
	var keep: Array = []
	for entry in _regions:
		var g = (entry[0] as WeakRef).get_ref()
		if g == null or not is_instance_valid(g) or not (g as Node3D).is_inside_tree():
			continue
		keep.append(entry)
		var group := g as Node3D
		var list: PackedFloat32Array = entry[1]
		for i in range(0, list.size(), 3):
			var centre := group.to_global(Vector3(list[i] + MapmWater.BLOCK_SPAN * 0.5, list[i + 2], list[i + 1] + MapmWater.BLOCK_SPAN * 0.5))
			var col := int(floorf(centre.x / MapmWater.BLOCK_SPAN))
			var row := int(floorf(centre.z / MapmWater.BLOCK_SPAN))
			out.append([col, row, centre.y])
			if col == cam_col and row == cam_row:
				own = true
	_regions = keep
	return [out, cam_col, cam_row, own]

func _process(_delta: float) -> void:
	if _qa_timing:
		_qa_time()
	var main := get_viewport().get_camera_3d()
	if main == null or materials.is_empty():
		_set_active(false)
		return
	var eye := main.global_position
	var found: Array = _world_blocks(eye)
	plane_height = pick_plane(found[0], found[1], found[2])
	if is_nan(plane_height):
		_set_active(false)
		return
	_set_active(true)
	underwater = is_underwater(eye.y, plane_height, found[3])
	var aspect := 1.0
	var vs := get_viewport().get_visible_rect().size
	if vs.y > 0:
		aspect = vs.x / vs.y
	var size := Vector2i(maxi(1, int(roundf(TARGET_ROWS * aspect))), TARGET_ROWS)
	if _viewport.size != size:
		_viewport.size = size
	_camera.fov = main.fov
	_camera.near = main.near
	_camera.far = main.far
	_camera.keep_aspect = main.keep_aspect
	_camera.environment = main.environment
	_camera.global_transform = main.global_transform if underwater else mirror_transform(main.global_transform, plane_height)
	var bm := bump_matrix(Time.get_ticks_msec() / 1000.0)
	for m in materials:
		m.set_shader_parameter("underwater", underwater)
		m.set_shader_parameter("bump_mat", bm)

## SRREVAMP_QA_WATER_TIMING: every QA_WINDOW frames, the main viewport's and the
## reflection target's measured render time (CPU + GPU), averaged.
func _qa_time() -> void:
	_qa_frames += 1
	_qa_main_ms += RenderingServer.viewport_get_measured_render_time_cpu(get_viewport().get_viewport_rid()) + RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
	_qa_refl_ms += RenderingServer.viewport_get_measured_render_time_cpu(_viewport.get_viewport_rid()) + RenderingServer.viewport_get_measured_render_time_gpu(_viewport.get_viewport_rid())
	if _qa_frames % QA_WINDOW == 0:
		print("QA WATER TIMING frame %d main %.2f ms reflection %.2f ms per frame, reflection %s plane %.1f underwater %s target %s" % [
			Engine.get_frames_drawn(), _qa_main_ms / QA_WINDOW, _qa_refl_ms / QA_WINDOW, "on" if active else "off", plane_height, str(underwater), str(_viewport.size)])
		_qa_main_ms = 0.0
		_qa_refl_ms = 0.0

func _set_active(on: bool) -> void:
	if on == active:
		return
	active = on
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
