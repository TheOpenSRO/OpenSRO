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
## Layer 19: drawn by the main camera AND the mirror (the sky's cloud layer,
## the scenery objects).
const REFLECTED_BIT := 1 << 18
## Layer 18: the mirror-only copies of the terrain with the clip; the main
## camera leaves this layer out.
const MIRROR_TERRAIN_BIT := 1 << 17

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
## SRREVAMP_QA_WATER_DUMP=<dir>:<frame> saves the target and the screen at
## that process frame; SRREVAMP_QA_WATER_NOBUMP=1 zeroes the bump, for a
## pixel fit.
var _qa_dump_dir := ""
var _qa_dump_frame := 0
var _qa_nobump := false
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

## The mirror's clip plane (READ: FUN_00a2dc20 builds it with the
## three-point `FUN_0045e0d0`, the points' order swapped between the two
## cases): above water keep y >= h, underwater keep y <= h. As a vec4 (n, d)
## with a point kept when dot(n, p) + d >= 0.
static func clip_plane(h: float, under: bool) -> Vector4:
	return Vector4(0.0, -1.0, 0.0, h) if under else Vector4(0.0, 1.0, 0.0, -h)

## No clipping.
const CLIP_NONE := Vector4(0.0, 1.0, 0.0, 1.0e9)

## The global uniform every mirror-only material clips against. Added at run
## time, before any shader that names it compiles.
const CLIP_GLOBAL := "water_clip_plane"

static var _globals_added := false

## Once per process (the list/get calls that could ask are editor-only).
static func ensure_globals() -> void:
	if _globals_added:
		return
	_globals_added = true
	RenderingServer.global_shader_parameter_add(CLIP_GLOBAL, RenderingServer.GLOBAL_VAR_TYPE_VEC4, CLIP_NONE)

## Marks every visual under `root` as drawn into the reflection too
## (REFLECTED_BIT) -- the scenery objects, which retail's reflection render
## keeps (the landscape pass), unclipped here (OPEN: their materials are
## ObjectLoader's).
static func mark_reflected(root: Node) -> void:
	if root == null:
		return
	for n in root.find_children("*", "VisualInstance3D", true, false):
		(n as VisualInstance3D).layers |= REFLECTED_BIT

## The mirror-only copy of a terrain surface material: the same texture,
## vertex colour, shading, blending, detail (lightmap) layer, the untextured
## fallback's AO lightmap and render priority, plus the clip against
## CLIP_GLOBAL.
##
## Not cached (rounds 623-628 integration review): the terrain's materials
## are new per region, so a cache keyed by them only grew -- it held every
## streamed region's lightmap and ground textures for ever (MEASURED: 323
## MB of texture memory against 111 MB with the reflection off after one
## tour). Each copy now lives and dies with its MirrorTerrain node. The
## shaders (four variants) are shared.
var _clip_shaders := {}

func clip_material(src: Material) -> Material:
	var std := src as StandardMaterial3D
	if std == null:
		return src
	var unshaded := std.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED
	var blend := std.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED
	var variant := "%d%d" % [int(unshaded), int(blend)]
	if not _clip_shaders.has(variant):
		var sh := Shader.new()
		sh.code = terrain_clip_code(unshaded, blend)
		_clip_shaders[variant] = sh
	var m := ShaderMaterial.new()
	m.shader = _clip_shaders[variant]
	m.render_priority = std.render_priority
	m.set_shader_parameter("albedo_tex", std.albedo_texture)
	m.set_shader_parameter("use_albedo_tex", std.albedo_texture != null)
	m.set_shader_parameter("use_vertex_color", std.vertex_color_use_as_albedo)
	m.set_shader_parameter("albedo_color", std.albedo_color)
	m.set_shader_parameter("uv1_scale", Vector2(std.uv1_scale.x, std.uv1_scale.y))
	m.set_shader_parameter("detail_tex", std.detail_albedo if std.detail_enabled else null)
	m.set_shader_parameter("use_detail", std.detail_enabled and std.detail_albedo != null)
	var ao := std.ao_enabled and std.ao_texture != null
	m.set_shader_parameter("ao_tex", std.ao_texture if ao else null)
	m.set_shader_parameter("use_ao", ao)
	m.set_shader_parameter("ao_light_affect", std.ao_light_affect)
	return m

## The mirror terrain's shader: StandardMaterial3D's own code for what the
## terrain uses (Godot 4.2 BaseMaterial3D: albedo texture on UV, vertex
## colour, a MUL detail layer on UV2 blended by the detail texel's alpha --
## `mix(albedo, albedo * detail, detail.a)`, the mask unset (white) -- the
## red channel of an AO texture on UV with its light affect, default
## lighting), and a discard below the clip plane.
static func terrain_clip_code(unshaded: bool, blend: bool) -> String:
	var modes := ["cull_back"]
	if unshaded:
		modes.append("unshaded")
	if blend:
		modes.append("blend_mix")
		modes.append("depth_draw_never")
	var ao_lines := "" if unshaded else """	if (use_ao) {
		AO = texture(ao_tex, UV * uv1_scale).r;
		AO_LIGHT_AFFECT = ao_light_affect;
	}
"""
	return """shader_type spatial;
render_mode %s;
global uniform vec4 water_clip_plane;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D ao_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform bool use_albedo_tex = false;
uniform bool use_vertex_color = true;
uniform bool use_detail = false;
uniform bool use_ao = false;
uniform float ao_light_affect = 0.0;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform vec2 uv1_scale = vec2(1.0);
varying vec3 world_pos;
%s
void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// The terrain's vertex colour is sRGB (vertex_color_is_srgb, round 693):
	// decoded where the output is linear, as StandardMaterial3D does.
	%s
}
void fragment() {
	if (dot(world_pos, water_clip_plane.xyz) + water_clip_plane.w < 0.0) {
		discard;
	}
	vec4 c = albedo_color;
	if (use_albedo_tex) {
		c *= texture(albedo_tex, UV * uv1_scale);
	}
	if (use_vertex_color) {
		c *= COLOR;
	}
	if (use_detail) {
		vec4 d = texture(detail_tex, UV2);
		c.rgb = mix(c.rgb, c.rgb * d.rgb, d.a);
	}
	ALBEDO = c.rgb;
%s%s}
""" % [", ".join(modes), ShaderColour.DECODE_FN, ShaderColour.DECODE_COLOR, ao_lines, "\tALPHA = c.a;\n" if blend else ""]

func _ready() -> void:
	ensure_globals()
	_viewport = SubViewport.new()
	_viewport.name = "WaterReflectionTarget"
	_viewport.size = Vector2i(TARGET_ROWS, TARGET_ROWS)
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.handle_input_locally = false
	_viewport.gui_disable_input = true
	add_child(_viewport)
	_camera = Camera3D.new()
	# READ (round 628 review): while world+0x26c3 is set the reflection
	# render skips the game's draw callbacks (LAB_0084c700: stage 1 draws the
	# object at [0xeecea4]+0x120, stage 2 two world managers -- INFERRED the
	# characters and the effects), so the mirror keeps the landscape pass:
	# sky, terrain, scenery.
	_camera.cull_mask = MIRROR_TERRAIN_BIT | REFLECTED_BIT
	_viewport.add_child(_camera)
	_qa_timing = OS.get_environment("SRREVAMP_QA_WATER_TIMING") != ""
	_qa_nobump = OS.get_environment("SRREVAMP_QA_WATER_NOBUMP") != ""
	var dump := OS.get_environment("SRREVAMP_QA_WATER_DUMP")
	if dump.contains(":"):
		_qa_dump_dir = dump.get_slice(":", 0)
		_qa_dump_frame = dump.get_slice(":", 1).to_int()
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
	m.set_shader_parameter("qa_output_mode", OS.get_environment("SRREVAMP_QA_WATER_OUTMODE").to_int())
	materials.append(m)
	return m

func set_water_color(c: Color) -> void:
	for m in materials:
		m.set_shader_parameter("water_color", Vector3(clampf(c.r, 0, 1), clampf(c.g, 0, 1), clampf(c.b, 0, 1)))

## A region's drawn water blocks, for choosing the plane.
func register_region(group: Node3D, blocks: PackedFloat32Array) -> void:
	_regions.append([weakref(group), blocks, Transform3D()])
	_cache_dirty = true

var _cache_dirty := true
## [col, row, centre] per drawn water block in world space, rebuilt only
## when a region registers, leaves or moves.
var _cache: Array = []
var _cache_cells := {}

func _refresh_cache() -> void:
	var keep: Array = []
	for entry in _regions:
		var g = (entry[0] as WeakRef).get_ref()
		if g == null or not is_instance_valid(g) or not (g as Node3D).is_inside_tree():
			_cache_dirty = true
			continue
		var gt := (g as Node3D).global_transform
		if gt != entry[2]:
			entry[2] = gt
			_cache_dirty = true
		keep.append(entry)
	_regions = keep
	if not _cache_dirty:
		return
	_cache_dirty = false
	_cache = []
	_cache_cells = {}
	for entry in _regions:
		var group := (entry[0] as WeakRef).get_ref() as Node3D
		var list: PackedFloat32Array = entry[1]
		for i in range(0, list.size(), 3):
			var centre := group.to_global(Vector3(list[i] + MapmWater.BLOCK_SPAN * 0.5, list[i + 2], list[i + 1] + MapmWater.BLOCK_SPAN * 0.5))
			var cell := Vector2i(int(floorf(centre.x / MapmWater.BLOCK_SPAN)), int(floorf(centre.z / MapmWater.BLOCK_SPAN)))
			_cache.append([cell.x, cell.y, centre.y, centre])
			_cache_cells[cell] = true

## Half a block's diagonal: a block's bounding sphere at its plane.
const BLOCK_RADIUS := 226.3

## The drawn water blocks in the camera's view (READ: the drawn-block list is
## view-tested), as (col, row, plane) triples. OURS: a bounding sphere per
## block against the frustum's planes.
func _visible_blocks(frustum: Array) -> Array:
	var out: Array = []
	for b in _cache:
		var c: Vector3 = b[3]
		var inside := true
		for pl in frustum:
			if (pl as Plane).distance_to(c) > BLOCK_RADIUS:
				inside = false
				break
		if inside:
			out.append(b)
	return out

func _process(_delta: float) -> void:
	if _qa_timing:
		_qa_time()
	var main := get_viewport().get_camera_3d()
	if main == null or materials.is_empty():
		_set_active(false)
		return
	_refresh_cache()
	var eye := main.global_position
	var cam_col := int(floorf(eye.x / MapmWater.BLOCK_SPAN))
	var cam_row := int(floorf(eye.z / MapmWater.BLOCK_SPAN))
	plane_height = pick_plane(_visible_blocks(main.get_frustum()), cam_col, cam_row)
	if is_nan(plane_height):
		_set_active(false)
		RenderingServer.global_shader_parameter_set(CLIP_GLOBAL, CLIP_NONE)
		return
	_set_active(true)
	underwater = is_underwater(eye.y, plane_height, _cache_cells.has(Vector2i(cam_col, cam_row)))
	RenderingServer.global_shader_parameter_set(CLIP_GLOBAL, clip_plane(plane_height, underwater))
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
	var env: Environment = main.environment if main.environment != null else main.get_world_3d().environment
	var exposure := env.tonemap_exposure if env != null else 1.0
	var white := env.tonemap_white if env != null else 1.0
	var filmic := env != null and env.tonemap_mode == Environment.TONE_MAPPER_FILMIC
	var bm := bump_matrix(Time.get_ticks_msec() / 1000.0)
	if _qa_nobump:
		bm = Vector4.ZERO
	for m in materials:
		m.set_shader_parameter("underwater", underwater)
		m.set_shader_parameter("bump_mat", bm)
		m.set_shader_parameter("tonemap_exposure", exposure)
		m.set_shader_parameter("tonemap_white", white)
		m.set_shader_parameter("tonemap_filmic", filmic)
	if _qa_dump_frame > 0 and Engine.get_process_frames() == _qa_dump_frame:
		_qa_dump(main)

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

## SRREVAMP_QA_WATER_DUMP: the target and the screen as PNGs, and what a
## pixel fit needs to map one onto the other.
func _qa_dump(main: Camera3D) -> void:
	_viewport.get_texture().get_image().save_png("%s/refl.png" % _qa_dump_dir)
	get_viewport().get_texture().get_image().save_png("%s/main.png" % _qa_dump_dir)
	var wc: Vector3 = materials[0].get_shader_parameter("water_color")
	print("QA WATER DUMP %s" % JSON.stringify({"plane": plane_height, "underwater": underwater,
		"wc": [wc.x, wc.y, wc.z], "fov": main.fov, "refl_size": [_viewport.size.x, _viewport.size.y],
		"main_size": [get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y]}))
