extends CompositorEffect
class_name EfpDisplayPass

## Round 786 (the waterfall sparkles' second part): the objects' `ambient`
## effects blended in display values exactly, under Forward+, as Direct3D 9
## blends them.
##
## Why (MEASURED, docs/protocol/EFP_FORMAT.md "Display-value blending under
## Forward+"): Direct3D 9 blends in the values the screen shows (the original
## sets no SRGBWRITEENABLE, round 705); Forward+ blends in a linear buffer.
## Rounds 722 / 774 drew each effect node as a twin that read Godot's screen
## copy and blended against it -- but that copy is taken before the
## transparent pass, so over a waterfall's sheet or a pool the twin blended
## against the rock or the pool floor behind: the Hotan palace waterfall's
## glints and haze added a tenth of what Compatibility (display-value
## blending, exact) adds, the Jangan dragon's splashes half.
##
## How: this CompositorEffect runs after Godot's transparent pass
## (EFFECT_CALLBACK_TYPE_POST_TRANSPARENT), when the colour buffer holds
## everything the original has drawn before an effect -- the water, every
## object's blended meshes (READ, EfpEffect.RENDER_PRIORITY: an effect draws
## after its owner's meshes, the water before every above-water object).
## 1. A compute pass turns the colour under the effects into the values the
##    screen will show (Godot's tone map forward and the sRGB encoding --
##    ObjectLight's tone map vector, the twins' srr_shown) into an 8-bit
##    buffer, as the original's back buffer is.
## 2. Every registered effect node is drawn into that buffer, back to front,
##    with the node's own Direct3D blend factors (d3d_factor: the 36-byte
##    RenderState's SRCBLEND / DESTBLEND, READ, EFEffect::FUN_00cabda0) and
##    its texture-stage ops on display values, depth-tested (LESSEQUAL in the
##    original, SWorld::vslot_023; Godot's reversed depth here) against the
##    scene's depth with no depth write (ZWRITEENABLE 0, READ) -- except a
##    glow pass draw, which the original draws with ZENABLE off
##    (FUN_00c43100). A second target marks the pixels drawn.
## 3. A compute pass turns the marked pixels back into the linear values
##    Godot's tone map and encoding turn into them (srr_unshown).
##
## OURS:
## - The effects draw after every transparent surface, characters' included
##   (the original orders a placed object's effects before a later object's
##   blended meshes, and before the above-water characters); among
##   themselves back to front by their draw box's centre, as Godot sorts.
## - Link nodes (strips rebuilt each step) stay in Godot's pass with their
##   display twins (EfpEffect.display_shader).
## - Where the scene's linear value is above what the tone map shows as white,
##   the marked pixels come back clamped to it, as the original's 8-bit back
##   buffer holds no more.
## - OPENSRO_QA_FX_PASS=off: the twins of rounds 722 / 774 instead (A/B).
## - Round 807 (the user's report): every draw fades by the world's fog at its
##   vertices (the original's particles draw with FOGENABLE 0), toward what
##   its blend leaves unchanged (fog_fade_mode), so an effect deep in the fog
##   shows no more than the surfaces around it; and a glow draw, which has no
##   depth test, is not drawn while the scene's depth at its occlusion point
##   (AmbientParticles.query_point, on the GPU every frame) is nearer than the
##   point -- the original asks its occlusion query every 500 ms, so a lamp
##   behind a wall showed through it until the query and the fade caught up.

static var qa_off := OS.get_environment("OPENSRO_QA_FX_PASS") == "off"
## QA only: no depth test (a probe of the pass's geometry).
static var qa_dump := 3 if OS.get_environment("OPENSRO_QA_FX_PASS") == "dump" else 0
static var qa_no_depth := OS.get_environment("OPENSRO_QA_FX_PASS") in ["nodepth", "mask", "clip"]
## QA only: 2 paints the drawn pixels magenta, 3 also a green band (the
## write-back's own probe).
static var qa_debug := 2.0 if OS.get_environment("OPENSRO_QA_FX_PASS") in ["mask", "clip"] else (3.0 if OS.get_environment("OPENSRO_QA_FX_PASS") == "band" else 0.0)

## QA only (round 807): OPENSRO_QA_FX_FOG=off draws the pass's effects
## unfogged, as before round 807 (the A/B of the fog's fade).
static var qa_no_fog := OS.get_environment("OPENSRO_QA_FX_FOG") == "off"

## The pass on the world camera (World3D), or null.
static var active: EfpDisplayPass = null

## Main thread: the effects drawn here.
var _effects: Array = []
## The last frame handed over was empty (an empty one is not sent again).
var _frame_sent_empty := false
var _last_sig := 0
## Mesh arrays expanded to a triangle list (pos.xyz, 1, u, v, 0, 0 a
## vertex), by mesh RID, built once on the main thread.
var _mesh_data := {}

## Render thread state.
var _rd: RenderingDevice
var _frame: Array = []
var _tonemap := Vector4(1, 1, 0, 0)
var _rect := Rect2(0, 0, 1, 1)
var _shader_draw: RID
var _shader_in: RID
var _shader_out: RID
var _pipe_in: RID
var _pipe_out: RID
var _pipelines := {}
var _sampler: RID
var _depth_sampler: RID
## The fog the draws fade by (WorldFog.last_params, last_height; round 807).
var _fog_ubo: RID
var _fog := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0])
var _disp: RID
var _mask: RID
var _fb: RID
var _size := Vector2i.ZERO
var _mesh_buffers := {}
## Draw uniform sets by their resources' RIDs.
var _sets := {}
## The current list's draws resolved (pipeline, uniform set, push constants,
## instances, vertices), reused until the list or the targets change.
var _prepared: Array = []
var _set_depth: RID
var _set_ubo: RID
var _fb_format := -1
## The last frame's cost, microseconds (QA): the main thread's list, the
## render thread's pass.
var main_usec := 0
var render_usec := 0
var _ready_rd := false
## The last frame's draw count (QA; the render thread's), and the items the
## main thread handed over last.
var drawn_nodes := 0
var last_items := 0

## The QA line.
func describe() -> String:
	var n := maxf(float(_main_frames), 1.0)
	var r := maxf(float(_render_frames), 1.0)
	var out := "display pass: %d effect(s), %d draw(s) handed over, %d drawn; mean main %.1f us, render %.1f us a frame" % [_effects.size(), last_items, drawn_nodes, _main_sum / n, _render_sum / r]
	_main_sum = 0
	_main_frames = 0
	_render_sum = 0
	_render_frames = 0
	return out

var _main_sum := 0
var _main_frames := 0
var _render_sum := 0
var _render_frames := 0

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd != null:
		var rids: Array = []
		rids.append_array(_pipelines.values())
		rids.append_array([_pipe_in, _pipe_out, _shader_in, _shader_out, _shader_draw, _disp, _mask, _sampler, _depth_sampler, _fog_ubo])
		rids.append_array(_mesh_buffers.values())
		var rd := _rd
		RenderingServer.call_on_render_thread(func() -> void:
			for r in rids:
				if (r as RID).is_valid():
					rd.free_rid(r))

## Tests only: make `p` the active pass with no RenderingDevice.
static func pass_headless_active(p: EfpDisplayPass) -> void:
	active = p

## Whether effects should go through this pass now.
static func on() -> bool:
	return active != null and not qa_off and VideoOptions.forward_plus_running()

func register(fx: EfpEffect) -> void:
	if not _effects.has(fx):
		_effects.append(fx)

func unregister(fx: EfpEffect) -> void:
	_effects.erase(fx)

func count() -> int:
	return _effects.size()

# ------------------------------------------------------------------ main thread

## Once a frame, after the effects stepped: what to draw, culled to the
## camera's frustum and sorted back to front, handed to the render thread in
## the RenderingServer's own command order.
func submit(camera: Camera3D) -> void:
	var t0 := Time.get_ticks_usec()
	# Nothing to rebuild when no effect redrew, faded, came or went and the
	# camera kept still: the render thread keeps drawing the last list (the
	# particles themselves are in the MultiMeshes' own buffers).
	var sig := _signature(camera)
	if sig == _last_sig and not _effects.is_empty():
		main_usec = Time.get_ticks_usec() - t0
		_main_sum += main_usec
		_main_frames += 1
		return
	_last_sig = sig
	var items: Array = []
	if camera != null and not _effects.is_empty():
		var planes := camera.get_frustum()
		var eye := camera.global_position
		var alive: Array = []
		for fx_v in _effects:
			if not is_instance_valid(fx_v):
				continue
			var fx := fx_v as EfpEffect
			alive.append(fx)
			if not fx.is_inside_tree() or not fx.is_visible_in_tree():
				continue
			fx.pass_items(items, planes, eye, self)
		if alive.size() != _effects.size():
			_effects = alive
	items.sort_custom(func(a, b): return float(a[3]) > float(b[3]))
	last_items = items.size()
	if items.is_empty() and _frame_sent_empty:
		main_usec = Time.get_ticks_usec() - t0
		return
	var rect := Rect2(0, 0, 1, 1)
	if not items.is_empty():
		var all: AABB = items[0][4]
		for it in items:
			all = all.merge(it[4])
		rect = screen_rect(all, camera)
	_frame_sent_empty = items.is_empty()
	var fog := PackedFloat32Array([WorldFog.last_params.x, WorldFog.last_params.y, WorldFog.last_params.z * (0.0 if qa_no_fog else 1.0), WorldFog.last_params.w,
		WorldFog.last_height.x, WorldFog.last_height.y, WorldFog.last_height.z, WorldFog.last_height.w])
	RenderingServer.call_on_render_thread(_set_frame.bind(items, ObjectLight.current_tonemap, rect, fog))
	main_usec = Time.get_ticks_usec() - t0
	_main_sum += main_usec
	_main_frames += 1

## What the frame's list depends on, as one hash: each effect's draw count
## of updates, glow alpha and visibility, and the camera.
func _signature(camera: Camera3D) -> int:
	var parts: Array = [_effects.size(), WorldFog.last_params, WorldFog.last_height]
	if camera != null:
		parts.append(camera.global_transform)
		parts.append(camera.fov)
		parts.append(camera.get_viewport().get_visible_rect().size)
	for fx_v in _effects:
		if not is_instance_valid(fx_v):
			parts.append(-1)
			continue
		var fx := fx_v as EfpEffect
		parts.append(fx.draw_updates)
		parts.append(fx._glow_alpha)
		parts.append(fx.is_visible_in_tree())
	return hash(parts)

## The part of the screen `box` can touch, as fractions of it (0..1): its
## corners projected, or the whole screen when it reaches behind the camera.
## The two compute passes cover only this.
static func screen_rect(box: AABB, camera: Camera3D) -> Rect2:
	var vp := camera.get_viewport().get_visible_rect().size
	if vp.x <= 0.0 or vp.y <= 0.0:
		return Rect2(0, 0, 1, 1)
	var lo := Vector2(INF, INF)
	var hi := -lo
	for k in 8:
		var c := box.get_endpoint(k)
		if camera.is_position_behind(c):
			return Rect2(0, 0, 1, 1)
		var p := camera.unproject_position(c)
		lo = lo.min(p)
		hi = hi.max(p)
	lo = (lo / vp).clamp(Vector2.ZERO, Vector2.ONE)
	hi = (hi / vp).clamp(Vector2.ZERO, Vector2.ONE)
	return Rect2(lo, (hi - lo).max(Vector2.ZERO))

## A pipeline's key: the blend pair, culling and winding.
static func pipeline_key(src: int, dest: int, cull: bool, mirrored: bool) -> int:
	return src * 1024 + dest * 4 + (2 if cull else 0) + (1 if mirrored else 0)

## A node's world transform as three rows of four floats (the push
## constants' head).
static func transform_bytes(xf: Transform3D) -> PackedByteArray:
	var b := xf.basis
	return PackedFloat32Array([b.x.x, b.y.x, b.z.x, xf.origin.x, b.x.y, b.y.y, b.z.y, xf.origin.y,
		b.x.z, b.y.z, b.z.z, xf.origin.z]).to_byte_array()

## The mesh's first surface as a plain triangle list, two vec4 a vertex
## (position, 1; u, v, 0, 0).
func mesh_data(mesh: Mesh) -> PackedFloat32Array:
	var key := mesh.get_rid()
	if _mesh_data.has(key):
		return _mesh_data[key]
	var out := PackedFloat32Array()
	if mesh.get_surface_count() > 0:
		var arrays := mesh.surface_get_arrays(0)
		var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var uvs = arrays[Mesh.ARRAY_TEX_UV]
		var idx = arrays[Mesh.ARRAY_INDEX]
		var order := PackedInt32Array()
		if idx is PackedInt32Array and not (idx as PackedInt32Array).is_empty():
			order = idx
		else:
			for i in pos.size():
				order.append(i)
		out.resize(order.size() * 8)
		for k in order.size():
			var i := order[k]
			var p := pos[i]
			var t := (uvs as PackedVector2Array)[i] if uvs is PackedVector2Array and i < (uvs as PackedVector2Array).size() else Vector2.ZERO
			var o := k * 8
			out[o] = p.x
			out[o + 1] = p.y
			out[o + 2] = p.z
			out[o + 3] = 1.0
			out[o + 4] = t.x
			out[o + 5] = t.y
	_mesh_data[key] = out
	return out

# ---------------------------------------------------------------- render thread

func _set_frame(items: Array, tonemap: Vector4, rect: Rect2, fog: PackedFloat32Array) -> void:
	_frame = items
	_prepared.clear()
	_tonemap = tonemap
	_rect = rect
	_fog = fog

func _init_rd() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return
	var vs := DRAW_VERTEX
	if OS.get_environment("OPENSRO_QA_FX_PASS") == "clip":
		vs = vs.replace("gl_Position = scene.projection_matrix * vec4(v, 1.0);", "gl_Position = vec4(p.xy + vec2(float(gl_InstanceIndex) * 0.05, 0.0), 0.5, 1.0);")
	_shader_draw = _compile({"vertex": vs, "fragment": DRAW_FRAGMENT})
	_shader_in = _compile({"compute": ENCODE_COMPUTE})
	_shader_out = _compile({"compute": DECODE_COMPUTE})
	if not (_shader_draw.is_valid() and _shader_in.is_valid() and _shader_out.is_valid()):
		push_error("EfpDisplayPass: a shader did not compile")
		return
	_pipe_in = _rd.compute_pipeline_create(_shader_in)
	_pipe_out = _rd.compute_pipeline_create(_shader_out)
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_sampler = _rd.sampler_create(ss)
	var dss := RDSamplerState.new()
	dss.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	dss.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	_depth_sampler = _rd.sampler_create(dss)
	_fog_ubo = _rd.uniform_buffer_create(32)
	_ready_rd = true

func _compile(stages: Dictionary) -> RID:
	var src := RDShaderSource.new()
	src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	if stages.has("vertex"):
		src.source_vertex = stages["vertex"]
	if stages.has("fragment"):
		src.source_fragment = stages["fragment"]
	if stages.has("compute"):
		src.source_compute = stages["compute"]
	var spirv := _rd.shader_compile_spirv_from_source(src)
	for st in ["vertex", "fragment", "compute"]:
		var err := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_VERTEX if st == "vertex" else (RenderingDevice.SHADER_STAGE_FRAGMENT if st == "fragment" else RenderingDevice.SHADER_STAGE_COMPUTE))
		if err != "":
			push_error("EfpDisplayPass %s: %s" % [st, err])
			return RID()
	return _rd.shader_create_from_spirv(spirv)

## Direct3D 9's D3DBLEND (READ, d3d9types.h) as the RenderingDevice factor
## for the colour channels. BOTHSRCALPHA (12) and BOTHINVSRCALPHA (13) set the
## destination too (`pair`); BLENDFACTOR / INVBLENDFACTOR take the device's
## factor, white unless set (the client never sets D3DRS_BLENDFACTOR in the
## effect draw -- READ, EFEffect::FUN_00cabda0's states).
static func d3d_factor(d3d: int) -> int:
	match d3d:
		1: return RenderingDevice.BLEND_FACTOR_ZERO
		2: return RenderingDevice.BLEND_FACTOR_ONE
		3: return RenderingDevice.BLEND_FACTOR_SRC_COLOR
		4: return RenderingDevice.BLEND_FACTOR_ONE_MINUS_SRC_COLOR
		5: return RenderingDevice.BLEND_FACTOR_SRC_ALPHA
		6: return RenderingDevice.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
		7: return RenderingDevice.BLEND_FACTOR_DST_ALPHA
		8: return RenderingDevice.BLEND_FACTOR_ONE_MINUS_DST_ALPHA
		9: return RenderingDevice.BLEND_FACTOR_DST_COLOR
		10: return RenderingDevice.BLEND_FACTOR_ONE_MINUS_DST_COLOR
		11: return RenderingDevice.BLEND_FACTOR_SRC_ALPHA_SATURATE
		14: return RenderingDevice.BLEND_FACTOR_ONE
		15: return RenderingDevice.BLEND_FACTOR_ZERO
	return RenderingDevice.BLEND_FACTOR_ONE

## The (source, destination) factors for a node's SRCBLEND / DESTBLEND.
static func d3d_pair(src: int, dest: int) -> Vector2i:
	if src == 12:
		return Vector2i(RenderingDevice.BLEND_FACTOR_SRC_ALPHA, RenderingDevice.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA)
	if src == 13:
		return Vector2i(RenderingDevice.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA, RenderingDevice.BLEND_FACTOR_SRC_ALPHA)
	return Vector2i(d3d_factor(src), d3d_factor(dest))

func _pipeline(fb_format: int, src: int, dest: int, cull: bool, mirrored: bool) -> RID:
	var raster := RDPipelineRasterizationState.new()
	var qa := OS.get_environment("OPENSRO_QA_FX_PASS")
	raster.cull_mode = RenderingDevice.POLYGON_CULL_BACK if cull and qa != "nocull" else RenderingDevice.POLYGON_CULL_DISABLED
	var front := RenderingDevice.POLYGON_FRONT_FACE_COUNTER_CLOCKWISE if qa == "ccw" else FRONT_FACE
	if mirrored:
		# A mirroring transform turns the winding over (Godot flips its cull
		# test the same way, World3D's place_group comment).
		front = RenderingDevice.POLYGON_FRONT_FACE_COUNTER_CLOCKWISE if front == RenderingDevice.POLYGON_FRONT_FACE_CLOCKWISE else RenderingDevice.POLYGON_FRONT_FACE_CLOCKWISE
	raster.front_face = front
	var ds := RDPipelineDepthStencilState.new()
	# The scene's depth is no attachment of this pass (Godot's buffer carries
	# no attachment use for it here): the fragment shader tests it.
	ds.enable_depth_test = false
	ds.enable_depth_write = false
	var a0 := RDPipelineColorBlendStateAttachment.new()
	var f := d3d_pair(src, dest)
	a0.enable_blend = true
	a0.src_color_blend_factor = f.x
	a0.dst_color_blend_factor = f.y
	a0.color_blend_op = RenderingDevice.BLEND_OP_ADD
	# The back buffer's alpha stays 1 (an X8R8G8B8 buffer reads as 1).
	a0.src_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ZERO
	a0.dst_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
	a0.alpha_blend_op = RenderingDevice.BLEND_OP_ADD
	var a1 := RDPipelineColorBlendStateAttachment.new()
	var blend := RDPipelineColorBlendState.new()
	blend.attachments = [a0, a1]
	return _rd.render_pipeline_create(_shader_draw, fb_format, RenderingDevice.INVALID_FORMAT_ID,
		RenderingDevice.RENDER_PRIMITIVE_TRIANGLES, raster, RDPipelineMultisampleState.new(), ds, blend)

## Which winding is a front face in the pass's clip space for a transform that
## does not mirror. INFERRED (not measured: of the world's 170 ambient effect
## files only map\guild\light_gate_blue.efp has mesh nodes with Direct3D
## culling on -- its three sujunglight03 nodes, MEASURED; every plate is
## billboarded, drawn both sides).
const FRONT_FACE := RenderingDevice.POLYGON_FRONT_FACE_CLOCKWISE

func _ensure_targets(size: Vector2i) -> bool:
	if size == _size and _fb.is_valid() and _rd.framebuffer_is_valid(_fb):
		return true
	if _disp.is_valid():
		_rd.free_rid(_disp)
	if _mask.is_valid():
		_rd.free_rid(_mask)
	_fb = RID()
	_size = size
	var tf := RDTextureFormat.new()
	tf.width = size.x
	tf.height = size.y
	tf.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_disp = _rd.texture_create(tf, RDTextureView.new())
	_mask = _rd.texture_create(tf, RDTextureView.new())
	_fb = _rd.framebuffer_create([_disp, _mask])
	return _fb.is_valid()

func _mesh_buffer(key: RID, data: PackedFloat32Array) -> RID:
	if _mesh_buffers.has(key):
		return _mesh_buffers[key]
	var b := _rd.storage_buffer_create(data.size() * 4, data.to_byte_array())
	_mesh_buffers[key] = b
	return b

func _render_callback(type: int, render_data: RenderData) -> void:
	drawn_nodes = 0
	if type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT or _frame.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	if not _ready_rd:
		# Built on the first frame with something to draw, on this thread
		# (a RenderingDevice call), not while the world loads.
		if _rd == null:
			_init_rd()
		if not _ready_rd:
			return
	var rsb := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var rsd := render_data.get_render_scene_data() as RenderSceneDataRD
	if rsb == null or rsd == null or rsb.get_view_count() != 1:
		return
	var size := rsb.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	var color := rsb.get_color_layer(0)
	var depth := rsb.get_depth_layer(0)
	if not _ensure_targets(size):
		return
	var x0 := clampi(int(floor(_rect.position.x * size.x)) - 2, 0, size.x)
	var y0 := clampi(int(floor(_rect.position.y * size.y)) - 2, 0, size.y)
	var x1 := clampi(int(ceil(_rect.end.x * size.x)) + 2, 0, size.x)
	var y1 := clampi(int(ceil(_rect.end.y * size.y)) + 2, 0, size.y)
	if qa_debug > 2.5:
		x0 = 0
		y0 = 0
		x1 = size.x
		y1 = size.y
	if x1 <= x0 or y1 <= y0:
		return
	var groups := Vector2i((x1 - x0 + 7) / 8, (y1 - y0 + 7) / 8)
	_rd.buffer_update(_fog_ubo, 0, 32, _fog.to_byte_array())
	var tm := PackedFloat32Array([_tonemap.x, _tonemap.y, _tonemap.z, qa_debug]).to_byte_array()
	tm.append_array(PackedInt32Array([x0, y0, x1, y1]).to_byte_array())
	# 1. The colour under the effects, as the screen will show it.
	_compute(_pipe_in, _image_set(_shader_in, color), tm, groups)
	# 2. The effects, back to front.
	var fb_format := _rd.framebuffer_get_format(_fb)
	var scene_ubo := rsd.get_uniform_buffer()
	var dl := _rd.draw_list_begin(_fb, RenderingDevice.DRAW_DEFAULT_ALL)
	if fb_format != _fb_format:
		_pipelines.clear()
		_fb_format = fb_format
		_prepared.clear()
	if depth != _set_depth or scene_ubo != _set_ubo:
		_sets.clear()
		_set_depth = depth
		_set_ubo = scene_ubo
		_prepared.clear()
	if not _prepared.is_empty():
		for d_v in _prepared:
			var d: Array = d_v
			_rd.draw_list_bind_render_pipeline(dl, d[0])
			_rd.draw_list_bind_uniform_set(dl, d[1], 0)
			var dpc: PackedByteArray = d[2]
			_rd.draw_list_set_push_constant(dl, dpc, dpc.size())
			_rd.draw_list_draw(dl, false, d[3], d[4])
		drawn_nodes = _prepared.size()
		_rd.draw_list_end()
		_compute(_pipe_out, _image_set(_shader_out, color), tm, groups)
		render_usec = Time.get_ticks_usec() - t0
		_render_sum += render_usec
		_render_frames += 1
		return
	for it_v in _frame:
		var it: Array = it_v
		var st: Dictionary = it[0]
		var mm: MultiMesh = st["mm"]
		var tex: Texture2D = st["tex"]
		var n: int = it[1]
		if n <= 0:
			continue
		var inst := RenderingServer.multimesh_get_buffer_rd_rid(mm.get_rid())
		var trd := RenderingServer.texture_get_rd_texture(tex.get_rid())
		if not inst.is_valid() or not trd.is_valid():
			continue
		if qa_dump > 0:
			qa_dump -= 1
			var ubo := _rd.buffer_get_data(scene_ubo, 0, 320).to_float32_array()
			print("QA FXPASS ubo %s; inst %s" % [str(ubo), str(_rd.buffer_get_data(inst, 0, 160).to_float32_array())])
		var mesh: PackedFloat32Array = st["mesh"]
		var mesh_b := _mesh_buffer(st["mesh_key"], mesh)
		var ukey := Vector3i(inst.get_id(), mesh_b.get_id(), trd.get_id())
		var uset: RID = _sets.get(ukey, RID())
		if not uset.is_valid() or not _rd.uniform_set_is_valid(uset):
			uset = _uniform_set(scene_ubo, inst, mesh_b, trd, depth)
			if _sets.size() > 1024:
				_sets.clear()
			_sets[ukey] = uset
		var pk: int = st["pipe"]
		var pipe: RID = _pipelines.get(pk, RID())
		if not pipe.is_valid():
			pipe = _pipeline(fb_format, st["src"], st["dest"], st["cull"], st["mirrored"])
			_pipelines[pk] = pipe
		_rd.draw_list_bind_render_pipeline(dl, pipe)
		_rd.draw_list_bind_uniform_set(dl, uset, 0)
		var pc: PackedByteArray = it[2]
		_rd.draw_list_set_push_constant(dl, pc, pc.size())
		_rd.draw_list_draw(dl, false, n, mesh.size() / 8)
		_prepared.append([pipe, uset, pc, n, mesh.size() / 8])
		drawn_nodes += 1
	_rd.draw_list_end()
	# 3. The marked pixels back to linear.
	_compute(_pipe_out, _image_set(_shader_out, color), tm, groups)
	render_usec = Time.get_ticks_usec() - t0
	_render_sum += render_usec
	_render_frames += 1

func _compute(pipe: RID, uset: RID, pc: PackedByteArray, groups: Vector2i) -> void:
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, pipe)
	_rd.compute_list_bind_uniform_set(cl, uset, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, groups.x, groups.y, 1)
	_rd.compute_list_end()

## The compute passes' images: the scene's colour, the display buffer, the
## mask.
func _image_set(shader: RID, color: RID) -> RID:
	var us: Array[RDUniform] = []
	var ids := [color, _disp, _mask]
	for b in 3:
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u.binding = b
		u.add_id(ids[b])
		us.append(u)
	return UniformSetCacheRD.get_cache(shader, 0, us)

## A draw's uniform set: the scene's data, the instances, the mesh, the
## texture and the scene's depth (UniformSetCacheRD keeps it while its
## resources live; _sets keys it by their RIDs).
func _uniform_set(scene_ubo: RID, inst: RID, mesh_b: RID, trd: RID, depth: RID) -> RID:
	var u0 := RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	u0.binding = 0
	u0.add_id(scene_ubo)
	var u1 := RDUniform.new()
	u1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u1.binding = 1
	u1.add_id(inst)
	var u2 := RDUniform.new()
	u2.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u2.binding = 2
	u2.add_id(mesh_b)
	var u3 := RDUniform.new()
	u3.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u3.binding = 3
	u3.add_id(_sampler)
	u3.add_id(trd)
	var u4 := RDUniform.new()
	u4.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u4.binding = 4
	u4.add_id(_depth_sampler)
	u4.add_id(depth)
	var u5 := RDUniform.new()
	u5.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	u5.binding = 5
	u5.add_id(_fog_ubo)
	return UniformSetCacheRD.get_cache(_shader_draw, 0, [u0, u1, u2, u3, u4, u5])

## One draw's push constants (112 bytes): the effect node's world transform
## as three rows, the stage ops, the glow alpha and the instance stride
## (vec4s); then (round 807) the glow's occlusion anchor -- the effect's
## place and its bias toward the camera, (byte - 1), w below 0 for none --
## and the fog fade mode (fog_fade_mode).
static func push_constants(xf: Transform3D, ops: PackedInt32Array, glow_alpha: int, stride: int,
		anchor: Vector4 = NO_ANCHOR, fade: int = 0) -> PackedByteArray:
	var out := transform_bytes(xf)
	out.append_array(tail_bytes(ops, glow_alpha, stride, anchor, fade))
	return out

## No glow occlusion test (a draw that is not a glow's).
const NO_ANCHOR := Vector4(0, 0, 0, -1)

## The push constants after the transform (push_constants).
static func tail_bytes(ops: PackedInt32Array, glow_alpha: int, stride: int, anchor: Vector4, fade: int) -> PackedByteArray:
	var out := PackedInt32Array([ops[0], ops[1], ops[2], ops[3], ops[4], ops[5], glow_alpha, stride]).to_byte_array()
	out.append_array(PackedFloat32Array([anchor.x, anchor.y, anchor.z, anchor.w]).to_byte_array())
	out.append_array(PackedInt32Array([fade, 0, 0, 0]).to_byte_array())
	return out

## How a draw fades by the fog (round 807, OURS): toward the source that its
## Direct3D blend pair leaves the destination unchanged with, scaled by the
## share of the fog kept. 0: the source's alpha (SRCALPHA / INVSRCALPHA
## sources, ZERO / INVSRCALPHA's darkening, anything else); 1: the colour and
## the alpha (a ONE source, which adds or is premultiplied); 2: the colour
## toward white (the multiplying pairs ZERO / SRCCOLOR and DESTCOLOR / ZERO);
## 3: the alpha toward 1 (BOTHINVSRCALPHA).
static func fog_fade_mode(src: int, dest: int) -> int:
	if src == 13:
		return 3
	if src == 2:
		return 1
	if (src == 1 and dest == 3) or (src == 9 and dest == 1):
		return 2
	return 0

# ---------------------------------------------------------------- shaders

## The tone map and the encoding both ways: the twins' srr_shown / srr_unshown
## (EfpEffect.DISPLAY_FN; ObjectLight's filmic curve and its inverse).
const TONEMAP_GLSL := """
layout(push_constant, std430) uniform Params { vec4 tm; ivec4 rect; } params;
float filmic_raw(float x) {
	return (x * (0.88 * x + 0.1 * 0.6) + 0.2 * 0.01) / (x * (0.88 * x + 0.6) + 0.2 * 0.3) - 0.01 / 0.3;
}
float filmic_inverse(float t, float white) {
	float u = clamp(t, 0.0, 0.999) * filmic_raw(white) + 0.01 / 0.3;
	float a = 0.88 * (u - 1.0);
	float b = 0.6 * (u - 0.1);
	float c = 0.2 * (0.3 * u - 0.01);
	float disc = max(b * b - 4.0 * a * c, 0.0);
	return max((-b - sqrt(disc)) / (2.0 * a), 0.0);
}
vec3 to_srgb(vec3 v) {
	vec3 c = max(v, vec3(0.0));
	return mix(1.055 * pow(c, vec3(1.0 / 2.4)) - vec3(0.055), c * 12.92, lessThan(c, vec3(0.0031308)));
}
vec3 to_linear(vec3 v) {
	vec3 c = max(v, vec3(0.0));
	return mix(pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), c * (1.0 / 12.92), lessThan(c, vec3(0.04045)));
}
vec3 shown(vec3 l) {
	vec3 v = l * params.tm.x;
	if (params.tm.z > 0.5) {
		float w = filmic_raw(params.tm.y);
		v = vec3(filmic_raw(v.r), filmic_raw(v.g), filmic_raw(v.b)) / w;
	}
	return to_srgb(clamp(v, vec3(0.0), vec3(1.0)));
}
vec3 unshown(vec3 d) {
	vec3 l = to_linear(clamp(d, vec3(0.0), vec3(1.0)));
	if (params.tm.z > 0.5) {
		l = vec3(filmic_inverse(l.r, params.tm.y), filmic_inverse(l.g, params.tm.y), filmic_inverse(l.b, params.tm.y));
	}
	return l / max(params.tm.x, 0.0001);
}
"""

const ENCODE_COMPUTE := """#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D color_image;
layout(rgba8, set = 0, binding = 1) uniform restrict writeonly image2D disp_image;
layout(rgba8, set = 0, binding = 2) uniform restrict writeonly image2D mask_image;
""" + TONEMAP_GLSL + """
void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy) + params.rect.xy;
	if (p.x >= params.rect.z || p.y >= params.rect.w) {
		return;
	}
	vec4 c = imageLoad(color_image, p);
	imageStore(disp_image, p, vec4(shown(c.rgb), 1.0));
	imageStore(mask_image, p, vec4(0.0));
}
"""

const DECODE_COMPUTE := """#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform restrict image2D color_image;
layout(rgba8, set = 0, binding = 1) uniform restrict readonly image2D disp_image;
layout(rgba8, set = 0, binding = 2) uniform restrict readonly image2D mask_image;
""" + TONEMAP_GLSL + """
void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy) + params.rect.xy;
	if (p.x >= params.rect.z || p.y >= params.rect.w) {
		return;
	}
	if (params.tm.w > 2.5 && p.x < 100) {
		imageStore(color_image, p, vec4(0.0, 1.0, 0.0, 1.0));
		return;
	}
	if (imageLoad(mask_image, p).r < 0.5) {
		return;
	}
	if (params.tm.w > 1.5) {
		imageStore(color_image, p, vec4(1.0, 0.0, 1.0, 1.0));
		return;
	}
	vec4 c = imageLoad(color_image, p);
	imageStore(color_image, p, vec4(unshown(imageLoad(disp_image, p).rgb), c.a));
}
"""

const DRAW_VERTEX := """#version 450
// The head of Godot 4.7's SceneData (servers/rendering/renderer_rd/shaders/
// scene_data_inc.glsl, MEASURED by reading the buffer back): the corrected
// projection, its inverse, then the inverse view and the view as three rows
// each (a 3x4, row-major).
layout(set = 0, binding = 0, std140) uniform SceneDataBlock {
	mat4 projection_matrix;
	mat4 inv_projection_matrix;
	vec4 inv_view_rows[3];
	vec4 view_rows[3];
} scene;
layout(set = 0, binding = 1, std430) restrict readonly buffer Instances { vec4 d[]; } inst;
layout(set = 0, binding = 2, std430) restrict readonly buffer MeshData { vec4 v[]; } mesh;
layout(set = 0, binding = 5, std140) uniform FogBlock { vec4 params; vec4 height; } fog;
layout(push_constant, std430) uniform Draw { vec4 m0; vec4 m1; vec4 m2; ivec4 ops0; ivec4 ops1; vec4 anchor; ivec4 ops2; } pc;
layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec4 v_color;
layout(location = 2) out float v_kept;
layout(location = 3) flat out vec4 v_anchor;
// The share of the colour the world's fog keeps (WorldFog.SHADER_FN, the
// same arithmetic on the same values; round 807).
float fog_kept(vec3 view_v, float world_y) {
	float amount;
	if (fog.params.w > 0.5) {
		float zd = -view_v.z * fog.params.x;
		float kept = exp2(-(zd * zd));
		if (fog.height.w > 0.0) {
			kept = min(kept, 1.0 - fog.height.w * (abs(world_y - fog.height.x) - fog.height.y) * fog.height.z);
		}
		amount = fog.params.z * (1.0 - clamp(kept, 0.0, 1.0));
	} else {
		float span = max(fog.params.y - fog.params.x, 0.001);
		amount = fog.params.z * clamp((-view_v.z - fog.params.x) / span, 0.0, 1.0);
	}
	return 1.0 - amount;
}
vec3 to_view(vec3 w) {
	return vec3(dot(scene.view_rows[0].xyz, w) + scene.view_rows[0].w, dot(scene.view_rows[1].xyz, w) + scene.view_rows[1].w, dot(scene.view_rows[2].xyz, w) + scene.view_rows[2].w);
}
void main() {
	int base = gl_InstanceIndex * abs(pc.ops1.w);
	vec4 r0 = inst.d[base];
	vec4 r1 = inst.d[base + 1];
	vec4 r2 = inst.d[base + 2];
	vec4 col = inst.d[base + 3];
	vec4 cu = inst.d[base + 4];
	vec3 p = mesh.v[gl_VertexIndex * 2].xyz;
	vec2 t = mesh.v[gl_VertexIndex * 2 + 1].xy;
	vec3 e = vec3(dot(r0.xyz, p) + r0.w, dot(r1.xyz, p) + r1.w, dot(r2.xyz, p) + r2.w);
	vec3 w = vec3(dot(pc.m0.xyz, e) + pc.m0.w, dot(pc.m1.xyz, e) + pc.m1.w, dot(pc.m2.xyz, e) + pc.m2.w);
	vec3 v = to_view(w);
	gl_Position = scene.projection_matrix * vec4(v, 1.0);
	v_uv = cu.xy + t * cu.zw;
	v_color = col;
	v_kept = fog_kept(v, w.y);
	// A glow's occlusion point (AmbientParticles.query_point): its place moved
	// toward the eye by the bias, in clip space; w 0 when there is none or it
	// lies behind the eye.
	v_anchor = vec4(0.0);
	if (pc.anchor.w >= 0.0) {
		vec3 eye = vec3(scene.inv_view_rows[0].w, scene.inv_view_rows[1].w, scene.inv_view_rows[2].w);
		vec3 to_eye = eye - pc.anchor.xyz;
		vec3 q = pc.anchor.xyz + (dot(to_eye, to_eye) > 1e-12 ? normalize(to_eye) * pc.anchor.w : vec3(0.0));
		vec4 c = scene.projection_matrix * vec4(to_view(q), 1.0);
		if (c.w > 0.0) {
			v_anchor = vec4(c.xyz / c.w, 1.0);
		}
	}
}
"""

## Stage 0 as EfpEffect.SHADER_TEMPLATE has it (D3DTOP: 2 SELECTARG1,
## 3 SELECTARG2, 4 MODULATE, 5 MODULATE2X, 6 MODULATE4X, 7 ADD; D3DTA 0
## DIFFUSE, 2 TEXTURE), on display values, and the glow's alpha scale
## (EfpEffect.glow_shader; READ there).
const DRAW_FRAGMENT := """#version 450
layout(set = 0, binding = 3) uniform sampler2D tex;
layout(set = 0, binding = 4) uniform sampler2D scene_depth;
layout(push_constant, std430) uniform Draw { vec4 m0; vec4 m1; vec4 m2; ivec4 ops0; ivec4 ops1; vec4 anchor; ivec4 ops2; } pc;
layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec4 v_color;
layout(location = 2) in float v_kept;
layout(location = 3) flat in vec4 v_anchor;
layout(location = 0) out vec4 o_color;
layout(location = 1) out vec4 o_mask;
vec4 arg(int which, vec4 t, vec4 d) {
	return which == 2 ? t : d;
}
vec4 op(int o, vec4 a, vec4 b) {
	if (o == 2) return a;
	if (o == 3) return b;
	if (o == 5) return a * b * 2.0;
	if (o == 6) return a * b * 4.0;
	if (o == 7) return a + b;
	return a * b;
}
void main() {
	// The depth test (LESSEQUAL in the original; Godot's depth is reversed:
	// nearer is larger). A glow draw has none (stride negative).
	if (pc.ops1.w > 0 && gl_FragCoord.z < texelFetch(scene_depth, ivec2(gl_FragCoord.xy), 0).r) {
		discard;
	}
	// A glow's occlusion point on the screen behind the scene's depth: the
	// glow is hidden (round 807, OURS: the original's query, every frame).
	// Off the screen it is left to the glow pass's fade, as before.
	if (v_anchor.w > 0.5 && abs(v_anchor.x) <= 1.0 && abs(v_anchor.y) <= 1.0) {
		ivec2 size = textureSize(scene_depth, 0);
		ivec2 at = clamp(ivec2((v_anchor.xy * 0.5 + 0.5) * vec2(size)), ivec2(0), size - ivec2(1));
		if (texelFetch(scene_depth, at, 0).r > v_anchor.z) {
			discard;
		}
	}
	vec4 t = texture(tex, v_uv);
	vec4 d = v_color;
	int glow = pc.ops1.z;
	if (glow < 255) {
		d.a = floor(floor(d.a * 255.0 + 0.5) * float(glow) / 256.0) / 255.0;
	}
	vec3 c = op(pc.ops0.x, arg(pc.ops0.y, t, d), arg(pc.ops0.z, t, d)).rgb;
	float a = op(pc.ops0.w, arg(pc.ops1.x, t, d), arg(pc.ops1.y, t, d)).a;
	// The fog's fade (fog_fade_mode, round 807).
	float k = clamp(v_kept, 0.0, 1.0);
	if (pc.ops2.x == 1) {
		c *= k;
		a *= k;
	} else if (pc.ops2.x == 2) {
		c = mix(vec3(1.0), c, k);
	} else if (pc.ops2.x == 3) {
		a = 1.0 - (1.0 - a) * k;
	} else {
		a *= k;
	}
	o_color = vec4(clamp(c, 0.0, 1.0), clamp(a, 0.0, 1.0));
	o_mask = vec4(1.0);
}
"""
