class_name TexAni
extends RefCounted

## A material's animated texture coordinates: the TEXANI mod (round 722).
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
##   built at 0xbf6c3f..0xbf6d34): TEXANI0 does
##       mov r1, v4 ; mov r1.z, 1.0 ; m3x3 oT0.xyz, r1.xyz, c23
##   -- u' = dot((u, v, 1), c23), v' = dot((u, v, 1), c24) on texture stage 0
##   -- while TEXANI1 passes oT0 through as authored and animates oT1, the
##   second stage's coordinates. (The archive's `vertexshader0texani.c` equals
##   TEXANI0 but is not a file the client loads.) So a mode-1 mod never moves
##   the base texture; what its second stage holds is not read here, so a
##   mode-1 mod is not bound (bind) and draws still: OPEN.
##
## Not exercised by placed data: the frame grid (method 0). Its one user in
## the archive, `flame_adjutant`, is a set-1 mod with frames 0..0 and a 1 x 1
## grid; only tex_ani_test plays the grid step. The matrix grows with no wrap
## (READ: vslot_007 resets the frame and direction, never the matrix): the
## Constantinople fountain's water tiles about 100 times denser after an hour,
## and the fastest scroll (cj_wf_dr_01, -2.78/s) loses float32 precision
## after about ten hours (|v| ~ 10^5, a step of ~0.008 of a texture). Both as
## the original's accumulator does; its only difference is its LOD gate,
## which pauses the step for undrawn objects.
##
## OURS:
## - One runtime per material, and a placement's materials are its own, so
##   each placed object animates from when it was built (the original's
##   runtime is the object's too); the step runs every frame whether or not
##   the object is drawn (the original's update sits behind its LOD gate,
##   0xc43780, INFERRED open for a placed building).
## - The frame's milliseconds are the engine's delta, not truncated to a
##   whole millisecond as the original's DWORD is.

## The vertex line that applies the two uniforms object.gdshaderinc and the
## MTRL mod shader declare (texani_u, texani_v; the identity by default, so a
## material without a TEXANI mod draws its own coordinates).
const SHADER_LINE := "UV = vec2(dot(vec3(UV, 1.0), texani_u), dot(vec3(UV, 1.0), texani_v));"

const METHOD_GRID := 0
const METHOD_RATES := 1
const FLAG_LOOP := 1
const FLAG_PINGPONG := 2

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

## The live materials: one runtime each (weakly held, so a freed region's
## materials leave on the next tick).
static var _live: Array = []

## Starts animating `mat` with `data` (a TEXANI mod for its layer).
static func bind(mat: Material, data: Dictionary) -> void:
	var sm := mat as ShaderMaterial
	if sm == null or data.is_empty() or not animates_base(data):
		return
	var t := TexAni.create(data)
	t.apply_to(sm)
	_live.append([weakref(sm), t])
	var front = sm.get_meta(ObjectLoader.FRONT_PASS_META) if sm.has_meta(ObjectLoader.FRONT_PASS_META) else null
	if front is ShaderMaterial:
		t.apply_to(front)
		_live.append([weakref(front), t])

## One frame for every live material (World3D, once a frame).
static func tick(ms: float) -> void:
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

static func live_count() -> int:
	return _live.size()

## For the QA log (round 722): how many materials animate, and the first
## few one's rows.
static func describe(n: int = 3) -> String:
	var parts: Array[String] = ["%d live" % _live.size()]
	for i in range(mini(n, _live.size())):
		var mat = (_live[i][0] as WeakRef).get_ref()
		var t: TexAni = _live[i][1]
		var r := t.rows()
		parts.append("%s u%s v%s" % [(mat as Resource).resource_name if mat != null else "?", str(r[0]), str(r[1])])
	return ", ".join(parts)
