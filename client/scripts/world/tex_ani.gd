class_name TexAni
extends RefCounted

## A material's animated texture coordinates: the TEXANI mod (round 722;
## stage 1 and the shader clock, round 786).
##
## READ, sro_client.exe (docs/protocol/BSR_FORMAT.md, "TEXANI"):
## - The data (ModDataTexAni::vslot_004, 0x00c5c5a0) is BsrReader._read_texani.
## - The runtime (CRTModTexAni; its constructor 0x00c82a00) holds a 4x4
##   matrix at +0x48, starting as the identity, a ms accumulator (+0x40), a
##   frame (+0x44), a direction (+0x8c, 1, or -1 when start > end:
##   vslot_007 0xc82930) and a running flag (+0x88). Each frame its update
##   (vslot_002, 0xc82890) calls the step its data's +0x28 picks from the
##   table the constructor fills: 0 -> the frame grid (asm 0xc82640), 1 ->
##   the matrix rates (asm 0xc82830), both with the frame's milliseconds.
## - The grid step: the period is trunc(1000.0 / fps) ms (fistp under a
##   truncating control word); trunc(acc / period) frames pass and the rest
##   is kept; the frame moves by direction x frames; past the end it loops
##   (flag bit 0), ping-pongs (bit 1) or stops; then FUN_00c825f0 sets the
##   matrix's translation to ((frame % cols) / cols, (frame / cols) / rows).
##   A first frame equal to the last stops it at once.
## - The rate step: seconds = ms / 1000.0, and six matrix entries grow by
##   rate x seconds: +0x48 (m00) by data +0x38, +0x4c (m01) by +0x3c,
##   +0x58 (m10) by +0x48, +0x5c (m11) by +0x4c, +0x68 (m20) by +0x58,
##   +0x6c (m21) by +0x5c. Nothing wraps or resets them.
## - The draw (vslot_004, 0x00c82970): for the material whose index the mod
##   names, the matrix goes to vertex-shader constants 23..25, transposed
##   (0xaa3afe is D3DXMatrixTranspose -- round 722's review), so c23 =
##   (m00, m10, m20) and c24 = (m01, m11, m21). The draw flag it sets picks the
##   object shader's UV variant (the renderer, 0xbf0f70..0xbf0f93): data +0x24
##   (`mode`) 1 sets 0x400000 -> TEXANI1, anything else 0x8000000 -> TEXANI0
##   (0xc8299f..0xc829ad). The object shader the client assembles is
##   `shader\vss0.c` / `vss2.c` (pushed at 0xbf6a5a / 0xbf6a8a, the define list
##   built at 0xbf6c3f..0xbf6d34):
##       TEXANI0   mov r1, v4 ; mov r1.z, 1.0 ; m3x3 oT0.xyz, r1.xyz, c23
##       TEXANI1   mov oT0.xy, v4.xy ; ... m3x3 oT1.xyz, r1.xyz, c23
##       TEXANI1R  m3x3 oT0.xyz, r1.xyz, c23 ; mov oT1.xy, v4.xy
##   -- u' = dot((u, v, 1), c23), v' = dot((u, v, 1), c24). TEXANI0 animates
##   texture stage 0 (the material's texture); TEXANI1 keeps stage 0 as
##   authored and animates stage 1, the second texture a MULTITEX mod puts
##   there (round 786, ObjectLoader: BsrReader.multitex_for -- every mode-1
##   mod a placed object carries is on a material with a MULTITEX mod,
##   MEASURED, client/tools/water_census.gd); TEXANI1R (a MULTITEXREV's
##   0x200000 with TEXANI0's flag, 0xbf1943..0xbf1968) animates stage 0,
##   which then holds the mod's texture, and keeps stage 1 as authored.
##   (The archive's `vertexshader0texani.c` equals TEXANI0 but is not a file
##   the client loads.)
##
## How it runs here (round 786; OURS on the READ step):
## - The rate step is linear in time, so it is not stepped: the shader
##   evaluates the matrix at the clock -- rows = start + rates x (clock - t0),
##   `srr_texani_clock` a global uniform in seconds (TexAni.clock) set once a
##   physics tick, `texani_t0` the clock when the material was bound. Every
##   placed object's water animates with no per-material CPU work (until
##   round 786 every live material had its rows stepped and uploaded each
##   tick). The grid step is not linear and stays a per-material runtime
##   stepped on the CPU (no placed object uses it, below).
## - `texani_stage` picks the coordinates the rows move: 0 stage 0 (TEXANI0
##   and TEXANI1R), 1 stage 1 (TEXANI1), -1 (the default) none -- an unbound
##   material's vertex shader skips the work (OURS: less a vertex than round
##   722's two dot products for every material).
##
## Not exercised by placed data: the frame grid (method 0). Its one user in
## the archive, `flame_adjutant`, is a set-1 mod with frames 0..0 and a 1 x 1
## grid; only tex_ani_test plays the grid step. The matrix grows with no wrap
## (READ: vslot_007 resets the frame and direction, never the matrix): the
## Constantinople fountain's water tiles about 100 times denser after an hour,
## and the fastest scroll (cj_wf_dr_01, -2.78/s) loses float32 precision
## after about ten hours (|v| ~ 10^5, a step of ~0.008 of a texture). Both as
## the original's accumulator does (here the float32 clock does the same);
## its only difference is its LOD gate, which pauses the step for undrawn
## objects.
##
## OURS:
## - Each material animates from when it was bound (the original's runtime
##   is the object's, from its creation); the clock runs whether or not the
##   object is drawn (the original's update sits behind its LOD gate,
##   0xc43780, and the object's range state).
## - The clock is the engine's delta, not truncated to a whole millisecond as
##   the original's DWORD is.

## The uniforms object.gdshaderinc and the MTRL mod shader declare (no
## stage, -1, by default: a material without a TEXANI mod does no texture-
## coordinate work at all). object_light_test / tex_ani_test hold the include
## to this text.
const SHADER_UNIFORMS := """// A TEXANI mod's texture-coordinate matrix, rows c23 and c24 (TexAni, rounds
// 722 and 786): its start rows, their rates a second, the clock it was
// bound at, and the stage whose coordinates it moves (0 TEXANI0 / TEXANI1R,
// 1 TEXANI1, -1 none: every other material).
global uniform float srr_texani_clock;
uniform vec3 texani_u = vec3(1.0, 0.0, 0.0);
uniform vec3 texani_v = vec3(0.0, 1.0, 0.0);
uniform vec3 texani_du = vec3(0.0);
uniform vec3 texani_dv = vec3(0.0);
uniform float texani_t0 = 0.0;
uniform int texani_stage = -1;
"""

## Texture stage 1's coordinates (a MULTITEX mod's texture, round 786): only
## a shader with a stage 1 declares it (the MTRL mod shader; the object
## shader's MULTITEX variant).
const SHADER_VARYING := "varying vec2 srr_uv1;\n"

## The vertex lines of a shader with a stage 1: stage 0's coordinates in UV,
## stage 1's in srr_uv1, the rows evaluated at the clock.
const SHADER_LINE := "srr_uv1 = UV; if (texani_stage >= 0) { float srr_ta = srr_texani_clock - texani_t0; vec3 srr_tu = texani_u + texani_du * srr_ta; vec3 srr_tv = texani_v + texani_dv * srr_ta; vec2 srr_ta_uv = vec2(dot(vec3(UV, 1.0), srr_tu), dot(vec3(UV, 1.0), srr_tv)); if (texani_stage == 1) { srr_uv1 = srr_ta_uv; } else { UV = srr_ta_uv; } }"

## The same for a shader with no stage 1 (the object shader without
## MULTITEX): only a stage-0 mod moves anything.
const SHADER_LINE_STAGE0 := "if (texani_stage == 0) { float srr_ta = srr_texani_clock - texani_t0; vec3 srr_tu = texani_u + texani_du * srr_ta; vec3 srr_tv = texani_v + texani_dv * srr_ta; UV = vec2(dot(vec3(UV, 1.0), srr_tu), dot(vec3(UV, 1.0), srr_tv)); }"

## The global uniform the clock is uploaded to (project.godot).
const CLOCK_GLOBAL := &"srr_texani_clock"

const METHOD_GRID := 0
const METHOD_RATES := 1
const FLAG_LOOP := 1
const FLAG_PINGPONG := 2

## The meta a bound material carries its mod under (bind_like, describe).
const META := "opensro_texani"

## The data (BsrReader._read_texani).
var spec: Dictionary
## The matrix, row-major 4x4 (index r * 4 + c), +0x48 onward.
var m := PackedFloat32Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
var acc_ms := 0
var frame := 0
var direction := 1
var running := true
var _frac_ms := 0.0

static func create(data: Dictionary) -> TexAni:
	var t := TexAni.new()
	t.spec = data
	t.reset()
	return t

## vslot_007 (0xc82930): running, direction 1 (or -1 when the first frame is
## after the last), the first frame, and the grid's translation for it.
func reset() -> void:
	running = true
	direction = 1
	frame = int(spec.get("start", 0))
	if int(spec.get("start", 0)) > int(spec.get("end", 0)):
		direction = -1
	if method() == METHOD_GRID:
		_grid_offset()

func method() -> int:
	return int(spec.get("method", METHOD_RATES))

## One frame of `ms` milliseconds (vslot_002 -> the method's step).
func step(ms: float) -> void:
	if method() == METHOD_GRID:
		_frac_ms += ms
		var whole := int(_frac_ms)
		_frac_ms -= whole
		step_grid(whole)
	elif method() == METHOD_RATES:
		step_rates(ms)

## The rate step, asm 0xc82830.
func step_rates(ms: float) -> void:
	var s := ms / 1000.0
	var r: PackedFloat32Array = spec.get("rates", PackedFloat32Array())
	if r.size() < 16:
		return
	m[0] += r[0] * s
	m[1] += r[1] * s
	m[4] += r[4] * s
	m[5] += r[5] * s
	m[8] += r[8] * s
	m[9] += r[9] * s

## The grid step, asm 0xc82640..0xc8281d.
func step_grid(dt: int) -> void:
	if dt <= 0 or not running:
		return
	acc_ms += dt
	var fps := int(spec.get("fps", 0))
	if fps <= 0:
		return
	var period := int(1000.0 / float(fps))
	if period <= 0:
		return
	var frames := int(float(acc_ms) / float(period))
	acc_ms -= frames * period
	if frames == 0:
		return
	var start := int(spec.get("start", 0))
	var last := int(spec.get("end", 0))
	if start == last:
		running = false
		return
	frame += direction * frames
	var flags := int(spec.get("flags", 0))
	if flags & FLAG_PINGPONG:
		# 0xc8272a: the near and far ends in the direction of travel.
		var near := start
		var far := last
		var reversed := false
		if (start - last) * direction > 0:
			near = last
			far = start
			reversed = true
		if (frame - far) * direction > 0:
			if flags & FLAG_LOOP == 0 and reversed:
				frame = start
				running = false
			else:
				var back := 2 * far - frame
				direction = -direction
				frame = back
				if (back - near) * direction > 0:
					direction = -direction
					frame = near
	else:
		if (frame - last) * direction > 0:
			if flags & FLAG_LOOP:
				frame += start - last - direction
				if (frame - last) * direction > 0:
					frame = start
			else:
				frame = last
				running = false
	_grid_offset()

## FUN_00c825f0: the translation for the current frame.
func _grid_offset() -> void:
	var rows := int(spec.get("rows", 1))
	var cols := int(spec.get("cols", 1))
	if rows == 0 or cols == 0:
		return
	# C's idiv: the remainder and the quotient truncate toward zero, as
	# GDScript's integer % and / do.
	m[8] = (1.0 / float(cols)) * float(frame % cols)
	m[9] = float(frame / cols) * (1.0 / float(rows))

## The shader's two rows (c23, c24).
func rows() -> Array[Vector3]:
	return [Vector3(m[0], m[4], m[8]), Vector3(m[1], m[5], m[9])]

func apply_to(mat: ShaderMaterial) -> void:
	var r := rows()
	mat.set_shader_parameter("texani_u", r[0])
	mat.set_shader_parameter("texani_v", r[1])

## Whether a mod animates texture stage 0, the base texture: mode 0
## (TEXANI0). Mode 1 (TEXANI1) animates stage 1 and leaves stage 0 as
## authored (READ, above).
static func animates_base(data: Dictionary) -> bool:
	return int(data.get("mode", 0)) != 1

## The stage whose coordinates a mod moves (texani_stage): 1 for mode 1
## (TEXANI1), else 0 -- TEXANI0, and TEXANI1R under a MULTITEXREV, whose
## stage 0 holds the mod's texture (READ, above).
static func stage_of(data: Dictionary) -> int:
	return 0 if animates_base(data) else 1

## The rate rows a second (c23's and c24's growth): (m00, m10, m20) and
## (m01, m11, m21) of the data's +0x38 matrix (READ, the rate step).
static func rate_rows(data: Dictionary) -> Array[Vector3]:
	var r: PackedFloat32Array = data.get("rates", PackedFloat32Array())
	if r.size() < 16:
		return [Vector3.ZERO, Vector3.ZERO]
	return [Vector3(r[0], r[4], r[8]), Vector3(r[1], r[5], r[9])]

## What the shader evaluates for a rate mod `seconds` after it was bound: the
## identity plus the rates times the seconds -- the rate step summed (tests).
static func rows_at(data: Dictionary, seconds: float) -> Array[Vector3]:
	var d := rate_rows(data)
	return [Vector3(1, 0, 0) + d[0] * seconds, Vector3(0, 1, 0) + d[1] * seconds]

## The coordinates a mod's rows give (u, v) (tests; the shader's dot).
static func uv_at(rows_uv: Array[Vector3], uv: Vector2) -> Vector2:
	var p := Vector3(uv.x, uv.y, 1.0)
	return Vector2(p.dot(rows_uv[0]), p.dot(rows_uv[1]))

## The shader clock in seconds (srr_texani_clock): advanced by tick().
static var clock := 0.0
## The grid runtimes still stepped on the CPU (weakly held, so a freed
## region's materials leave on the next tick).
static var _live: Array = []
## Every material bound (weakly held): describe() and the QA log.
static var _bound: Array = []
static var _prune_at := 2048
## QA only (round 747, QaCrowdProbe's `ab` step): every animation held.
static var hold := false

## Starts animating `mat` with `data` (a TEXANI mod for its layer): a rate mod
## through the shader clock, a grid mod through a runtime stepped here. Its
## two-pass front twin (ObjectLoader.FRONT_PASS_META) is bound the same.
static func bind(mat: Material, data: Dictionary) -> void:
	var sm := mat as ShaderMaterial
	if sm == null or data.is_empty():
		return
	var mats: Array = [sm]
	var front = sm.get_meta(ObjectLoader.FRONT_PASS_META) if sm.has_meta(ObjectLoader.FRONT_PASS_META) else null
	if front is ShaderMaterial:
		mats.append(front)
	var t := TexAni.create(data)
	# The weak list is only read by the QA line: kept from growing with every
	# region streamed in.
	if _bound.size() > _prune_at:
		_prune_at = maxi(2048, 2 * live_count())
	for target in mats:
		var tm := target as ShaderMaterial
		tm.set_meta(META, data)
		tm.set_shader_parameter("texani_stage", stage_of(data))
		tm.set_shader_parameter("texani_t0", clock)
		_bound.append(weakref(tm))
		if t.method() == METHOD_RATES:
			var d := rate_rows(data)
			tm.set_shader_parameter("texani_u", Vector3(1, 0, 0))
			tm.set_shader_parameter("texani_v", Vector3(0, 1, 0))
			tm.set_shader_parameter("texani_du", d[0])
			tm.set_shader_parameter("texani_dv", d[1])
		else:
			t.apply_to(tm)
			_live.append([weakref(tm), t])

## Animates `twin` as `src` is animated, if it is (round 747: a far body's
## GPU twin, CrowdGpu._twin). Returns whether it was.
static func bind_like(twin: ShaderMaterial, src: Material) -> bool:
	if twin == null or src == null or not src.has_meta(META):
		return false
	var s := src as ShaderMaterial
	if s == null:
		return false
	for k in ["texani_u", "texani_v", "texani_du", "texani_dv", "texani_t0", "texani_stage"]:
		twin.set_shader_parameter(k, s.get_shader_parameter(k))
	twin.set_meta(META, src.get_meta(META))
	for pair in _live:
		if (pair[0] as WeakRef).get_ref() == src:
			_live.append([weakref(twin), pair[1]])
			break
	_bound.append(weakref(twin))
	return true

## One frame (World3D, once a physics tick): the clock advances and is
## uploaded once, and every grid runtime steps.
static func tick(ms: float) -> void:
	if hold:
		return
	clock += ms / 1000.0
	RenderingServer.global_shader_parameter_set(CLOCK_GLOBAL, clock)
	if _live.is_empty():
		return
	var keep: Array = []
	var stepped := {}
	for pair in _live:
		var mat = (pair[0] as WeakRef).get_ref()
		if mat == null:
			continue
		var t: TexAni = pair[1]
		if not stepped.has(t):
			t.step(ms)
			stepped[t] = true
		t.apply_to(mat)
		keep.append(pair)
	_live = keep

## How many materials are bound and still alive (drops the freed ones).
static func live_count() -> int:
	var keep: Array = []
	for w in _bound:
		if (w as WeakRef).get_ref() != null:
			keep.append(w)
	_bound = keep
	return _bound.size()

## For the QA log (round 722): how many materials animate, the clock, and the
## first few ones' rows at the clock.
static func describe(n: int = 3) -> String:
	var parts: Array[String] = ["%d live, clock %.2f s" % [live_count(), clock]]
	for i in range(mini(n, _bound.size())):
		var mat = (_bound[i] as WeakRef).get_ref()
		if mat == null:
			continue
		var sm := mat as ShaderMaterial
		var t0 := float(sm.get_shader_parameter("texani_t0"))
		var r := rows_at(sm.get_meta(META), clock - t0)
		parts.append("%s stage %d u%s v%s" % [sm.resource_name, int(sm.get_shader_parameter("texani_stage")), str(r[0]), str(r[1])])
	return ", ".join(parts)
