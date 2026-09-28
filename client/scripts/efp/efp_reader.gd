extends RefCounted
class_name EfpReader

## Reads .efp (JMXVEFF) particle effects, the format of Particles.pk2.
## Mirrors server/internal/efp (tree.go, efp.go); keep the two in step. The
## layouts are the client's own loader, read from sro_client.exe with the
## addresses in docs/protocol/EFP_FORMAT.md (round 619).
##
## == Two entry points ==
##
## `EfpReader.decode(bytes) -> EfpReader.EfpFile` (v2) reads the typed tree:
## every node, controller, command and value, byte for byte as the client
## does. It returns null on bytes that do not follow the layout, with the
## reason in `EfpReader.last_error`. Over the retail Particles.pk2 it reads
## 4,103 of 4,170 files (the rest are 58 encrypted F8FILE containers, 7
## "0000" files in another format and 2 empty files).
##
## `EfpReader.parse(bytes) -> ParsedEffect` is the older flat walk of
## (name, raw bytes) pairs, kept for callers that only want names.
##
## == The tree, and what a renderer reads from it (round 620) ==
##
## EfpFile: version, header_0012 (f32, OPEN), header_0013 (3 ints, OPEN),
##   root: EfpNode, trailing (bytes after the root the client never reads).
##
## EfpNode, one emitter. Everything below is per node; children nest.
##   name, head_len (the byte length of name + controllers; NOT an id),
##   children: Array[EfpNode]; walk(fn) visits the subtree.
##   Lifetime / loop:
##     frames            program length N, in frames. Every command's frame
##                       range and every Frame* value is counted in these.
##                       The frame duration in seconds is OPEN.
##     extinct.name      "NormalTimeExtinct" (dies after N frames),
##                       "NormalTimeLoop" (restarts: loops()), or
##                       "NeverExtinct" (never_extinct()).
##   Emission:
##     emission()        {delay, duration, interval, max_live, per_trigger}
##                       or null. READ (FUN_00c84e70, FUN_00c87a20): after
##                       `delay` frames, for `duration` frames, every
##                       `interval` frames a trigger adds `per_trigger` to a
##                       live-particle accumulator clamped to `max_live`;
##                       int(new) - int(old) particles spawn, and each dying
##                       particle subtracts 1.0. emit_tick() runs one frame.
##   Per-particle program, `commands` (and command(name) for the first by name):
##     spawn shape       SetPosition (Vector), SetSpherePos (Vector), SetConePos
##                       (AngleVector1). The roles are INFERRED from the names;
##                       what each Vector component means is OPEN.
##     velocity          SetVelocity (Vector), SetConeVel (AngleVector1)
##     forces            Force (Vector), ConeForce (AngleVector1),
##                       Attraction (float)
##     rotation          SetRotation / SetRVelocity (RotVector), SetShapeRot /
##                       SetShapeRotVel (AxisVector4), SetRotationMat /
##                       SetRVelocityMat (Matrix), SetBANRot / SetBANPos
##     graphs over life  SetGraphScale (FrameScale: one Vector3 per key),
##                       SetGraphDiffuse (FrameDiffuse: one colour per key),
##                       SetGraphRandomScale (BlendScaleGraphPointer)
##     texture slide     TextureSlide (FrameTextureSlide)
##     Each EfpCommand has space (u8, OPEN), and time_flags/start/step/end
##     which frame_range(frames) turns into {start, end, step, ok, keys} (READ,
##     FUN_00ca0f40). A Frame* value holds `keys` baked values, value i at frame
##     start + i * step (MEASURED: 132,666 of 132,668 retail Frame* commands).
##   Look:
##     view_mode()       "ViewNone" | "ViewBillboard" | "ViewYBillboard" |
##                       "ViewVBillboard"
##     render_mode()     "RenderNone" | "RenderPlate" (a textured quad) |
##                       "RenderMesh" | "RenderLinkPipe" | "RenderLinkDPipe" |
##                       "RenderLinkObj"
##     meshes            Array[EfpMeshRef]: mesh ("" for a plate) + textures
##     state             EfpRenderState: the D3D9 states the client sets
##                       verbatim (READ, EFEffect::FUN_00cabda0). src_blend /
##                       dest_blend are D3DBLEND values; is_additive() is
##                       dest == ONE. 3,879 retail files use additive, 2,007
##                       alpha (SRCALPHA/INVSRCALPHA).
##     vars              the node program's typed variables: BlendScaleGraph,
##                       BlendDiffuseGraph, BSAnimation (.ban names).
##   Source blocks: `controllers` are the editor's inputs (NormalTimeLife,
##   StaticEmit, Program, LinkMode, BAN, ViewMode, Shape, ScaleGraph,
##   DiffuseGraph); the client compiles them into the fields above, so render
##   from the node fields.
##
## Values are Dictionaries with a "type" key (the registry's own type name):
##   float {value}; Vector {value: Vector3}; Matrix {matrix}; AxisVector4
##   {axis: Vector4, matrix}; RotVector {rot: Vector3, matrix}; AngleVector1
##   {a: Vector3, b: Vector3}; SEFStaticEmit {delay, duration, interval,
##   max_live, per_trigger}; FrameScale {frames: PackedVector3Array}; FrameDiffuse {colors:
##   PackedInt64Array}; FrameBANRotation {head, matrices: Array}; FrameBANPosition
##   {head, positions: PackedVector3Array}; BSAnimation {names:
##   PackedStringArray}; FrameTextureSlide {head: Vector3, keys: Array[Vector4]};
##   BlendScaleGraph {a, b, times: PackedFloat32Array, scales:
##   PackedVector3Array}; BlendScaleGraphPointer {value}; BlendDiffuseGraph
##   {a, b, times, colors: PackedInt64Array}.
## Matrices are PackedFloat32Array(16) as stored (row-major, D3D row vectors,
## INFERRED). Colours are raw u32; d3dcolor(c) reads one as 0xAARRGGBB
## (INFERRED: D3DCOLOR).

const MAGIC := "JMXVEFF"
const MAGIC_LEN := 7
const VERSION_LEN := 4
const MAX_NAME_LEN := 40
const MAX_SCAN_SKIP := 100000 # bound on how far the "find the next name" scan looks

# Limits against corrupt input. 1000 controllers is the client's own cap
# (FUN_00cc3a40); the others are ours, far above any retail file.
const MAX_CONTROLLERS := 1000
const MAX_STRING_LEN := 4096
const MAX_LIST_LEN := 1 << 20
const MAX_DEPTH := 64

## The 16 registry value types, in registration order (CGame::FUN_00ca0500).
const VALUE_TYPES := ["float", "Vector", "Matrix", "SEFStaticEmit", "AxisVector4",
	"RotVector", "AngleVector1", "FrameScale", "BlendScaleGraph",
	"BlendScaleGraphPointer", "FrameDiffuse", "BlendDiffuseGraph",
	"FrameBANRotation", "FrameBANPosition", "BSAnimation", "FrameTextureSlide"]

## Command name -> parameter value type ("" = none), the FUN_00ca8140 calls.
const COMMAND_TYPES := {
	"NeverExtinct": "", "NormalTimeExtinct": "", "NormalTimeLoop": "",
	"StaticEmit": "SEFStaticEmit", "ProgramUpdate": "",
	"SetRotationMat": "Matrix", "SetRVelocityMat": "Matrix",
	"SetRotation": "RotVector", "SetBANRot": "FrameBANRotation",
	"SetRVelocity": "RotVector", "SetRotationAxis": "AxisVector4",
	"SetRVelocityAxis": "AxisVector4", "SetPosition": "Vector",
	"SetConePos": "AngleVector1", "SetBANPos": "FrameBANPosition",
	"SetSpherePos": "Vector", "SetVelocity": "Vector",
	"SetConeVel": "AngleVector1", "Force": "Vector",
	"ConeForce": "AngleVector1", "Attraction": "float",
	"TextureSlide": "FrameTextureSlide", "SetGraphScale": "FrameScale",
	"SetGraphRandomScale": "BlendScaleGraphPointer",
	"SetGraphDiffuse": "FrameDiffuse", "SetShapeRot": "AxisVector4",
	"SetShapeRotVel": "AxisVector4",
	"ViewNone": "", "ViewBillboard": "", "ViewYBillboard": "", "ViewVBillboard": "",
	"RenderNone": "", "RenderPlate": "", "RenderMesh": "",
	"RenderLinkDPipe": "", "RenderLinkPipe": "", "RenderLinkObj": "",
}

## The ten controller keys (FUN_00ca0180 calls); the file spells the tenth "BAN".
const CONTROLLERS := ["NormalTimeLife", "NormalTimeLoopLife", "StaticEmit", "Program",
	"LinkMode", "BAN", "ViewMode", "Shape", "ScaleGraph", "DiffuseGraph"]

## Why the last decode() returned null.
static var last_error := ""

# ---------------------------------------------------------------- v2 tree

class EfpFile:
	var version: String
	var header_0012: float = 0.0 ## f32 read when version >= "0012"; OPEN
	var header_0013: PackedInt64Array = PackedInt64Array([0, 0, 0]) ## 3 u32 when >= "0013"; OPEN
	var root: EfpNode
	var trailing: int = 0 ## bytes after the root node, never read by the client

class EfpRenderState:
	## D3D9 values, set verbatim by the client (EFEffect::FUN_00cabda0).
	var cull: int ## D3DRS_CULLMODE (1 none, 3 ccw; the loader turns 2 into 3)
	var src_blend: int ## D3DRS_SRCBLEND (5 = SRCALPHA)
	var dest_blend: int ## D3DRS_DESTBLEND (2 = ONE, 6 = INVSRCALPHA)
	var color_arg1: int ## D3DTSS_COLORARG1 (2 = TEXTURE)
	var color_arg2: int ## D3DTSS_COLORARG2 (0 = DIFFUSE)
	var color_op: int ## D3DTSS_COLOROP (4 MODULATE, 5 MODULATE2X, 6 MODULATE4X, 2 SELECTARG1)
	var alpha_arg1: int ## D3DTSS_ALPHAARG1
	var alpha_arg2: int ## D3DTSS_ALPHAARG2
	var alpha_op: int ## D3DTSS_ALPHAOP

	func is_additive() -> bool:
		return dest_blend == 2

class EfpMeshRef:
	var mesh: String ## "" for a plate
	var textures: PackedStringArray = PackedStringArray()

class EfpCommand:
	var name: String
	var space: int ## u8 at command+0x1c; OPEN
	var time_flags: int ## see frame_range
	var start: float
	var step: float
	var end: float
	var value = null ## Dictionary, or null when the command has no parameter

	## The command's frame range over a program of n frames, exactly as
	## FUN_00ca0f40: {start, end, step, ok}; ok false where the client skips it.
	func frame_range(n: int) -> Dictionary:
		# Single-precision float arithmetic, 32-bit integer products and the
		# client's _ftol, as Go's Command.FrameRange (see there).
		var s: int
		var st: float
		var e: int = 0
		if time_flags & 1 == 0:
			s = EfpReader.ftol(start)
		else:
			s = EfpReader.i32(EfpReader.ftol(EfpReader.f32(start / 100.0)) * n)
		if time_flags & 2 == 0:
			st = step
		else:
			st = EfpReader.f32(EfpReader.f32(float(n) * step) / 100.0)
		match (time_flags >> 2) % 5:
			0:
				e = EfpReader.ftol(end)
			1:
				e = EfpReader.i32(EfpReader.ftol(EfpReader.f32(end / 100.0)) * n)
			2:
				e = EfpReader.i32(s + EfpReader.ftol(end))
			3:
				# the double -100.0 at 0x00db9a38 (READ): start + int(End/100)*N
				e = EfpReader.i32(s - EfpReader.i32(EfpReader.ftol(EfpReader.f32(end / -100.0)) * n))
			4:
				if end < 1.0:
					return {"start": 0, "end": 0, "step": 0.0, "ok": false, "keys": 0}
				e = EfpReader.i32(s + EfpReader.ftol(EfpReader.f32(end * st)))
		if e >= n:
			e = n - 1
		var ok := e <= n and s <= e and st >= EfpReader.f32(0.000001)
		# keys: FUN_00ca0f40's return, ftol((end-start)/step)+1 -- the number
		# of values a Frame* parameter holds (MEASURED, 132,666 of 132,668).
		# A negative (overflowed) count is reported as 0 (OURS).
		var keys := 0
		if ok:
			keys = maxi(EfpReader.i32(EfpReader.ftol(EfpReader.f32(float(e - s) / st)) + 1), 0)
		return {"start": s, "end": e, "step": st, "ok": ok, "keys": keys}

class EfpController:
	var key: String
	## Per key: StaticEmit {emit}; LinkMode {link: PackedInt64Array(4)};
	## Program {commands}; BAN {names}; ViewMode {view}; Shape {render, state,
	## meshes}; ScaleGraph {axes: Array of 3 {a, b, times, values}, tail1,
	## tail2}; DiffuseGraph {alpha: {a, b, times, values}, color}; the two
	## lifetime keys carry nothing.
	var data: Dictionary = {}

class EfpNode:
	## The node's opening u32: the byte length of its name (with the length
	## prefix) plus its controllers (MEASURED 95,801 of 95,801 retail nodes;
	## the loader's cache mode seeks past that span). Was misread as an id.
	var head_len: int
	var head_span: int ## the bytes the reader consumed for that span
	var name: String
	var controllers: Array[EfpController] = []
	var frames: int ## program length N
	var vars: Array = [] ## [{type, value}]
	var list_90: Array[EfpCommand] = [] ## always empty in retail
	var emit: Array[EfpCommand] = [] ## StaticEmit
	var list_d8: Array[EfpCommand] = [] ## always empty in retail
	var extinct: EfpCommand ## NormalTimeExtinct | NeverExtinct | NormalTimeLoop
	var update: Array[EfpCommand] = [] ## ProgramUpdate
	var flags: Dictionary = {} ## the 20-byte block, OPEN: b0 b1 u2 u3 u4 b5 u6 b7
	var view: EfpCommand
	var state: EfpRenderState
	var meshes: Array[EfpMeshRef] = []
	var render: EfpCommand
	var list_20c: Array[EfpCommand] = [] ## always empty in retail
	var commands: Array[EfpCommand] = [] ## the per-particle program
	var children: Array[EfpNode] = []

	func head_len_matches() -> bool:
		return head_len == head_span

	func loops() -> bool:
		return extinct != null and extinct.name == "NormalTimeLoop"

	func never_extinct() -> bool:
		return extinct != null and extinct.name == "NeverExtinct"

	func emission():
		for c in emit:
			if c.value is Dictionary and c.value.get("type", "") == "SEFStaticEmit":
				return c.value
		return null

	func view_mode() -> String:
		return view.name if view != null else ""

	func render_mode() -> String:
		return render.name if render != null else ""

	func command(cmd_name: String) -> EfpCommand:
		for c in commands:
			if c.name == cmd_name:
				return c
		return null

	func walk(fn: Callable) -> void:
		fn.call(self)
		for k in children:
			k.walk(fn)

## One emitter frame, exactly as FUN_00c84e70 (mirrors Go's StaticEmit.Tick):
## returns {spawn, acc, stopped}. `acc` is the live accumulator (start at 0;
## subtract 1.0 per dying particle). The globals are DAT_01114d54
## (interval_mul) and DAT_01114d58 (threshold); {0, 0}, full quality, is their
## .bss start value and our default (the option's retail default is OPEN).
static func emit_tick(emit: Dictionary, age: int, acc: float, interval_mul: int = 0, threshold: int = 0) -> Dictionary:
	var t := i32(age - int(emit["delay"]))
	if t >= int(emit["duration"]):
		return {"spawn": 0, "acc": acc, "stopped": true}
	var interval := i32(int(emit["interval"]))
	if interval <= 0 or t < 0:
		return {"spawn": 0, "acc": acc, "stopped": false}
	if interval_mul > 1:
		var m := i32(interval * interval_mul)
		if m < i32(int(emit["duration"])):
			interval = m
	if t % interval != 0:
		return {"spawn": 0, "acc": acc, "stopped": false}
	var cap := i32(int(emit["max_live"]))
	var per: float = emit["per_trigger"]
	if threshold > 0 and float(threshold) < per and cap > 0:
		cap = maxi(ftol(f32(float(cap) * 0.5)), 1)
	var old := ftol(acc)
	var nxt := f32(per + acc)
	var capf := f32(float(cap))
	if capf < nxt:
		nxt = capf
	return {"spawn": i32(ftol(nxt) - old), "acc": nxt, "stopped": false}

## Reads a raw colour as D3DCOLOR 0xAARRGGBB (INFERRED).
static func d3dcolor(c: int) -> Color:
	return Color8((c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF, (c >> 24) & 0xFF)

## Cuts at the first NUL (the client's c_str) and maps each byte to the code
## point of the same value, exactly as Go's latin1, so both readers give the
## same strings (EUC-KR names keep their raw byte values; OURS).
static func latin1(raw: PackedByteArray) -> String:
	var nul := raw.find(0)
	if nul >= 0:
		raw = raw.slice(0, nul)
	var ascii := true
	for c in raw:
		if c >= 0x80:
			ascii = false
			break
	if ascii:
		return raw.get_string_from_ascii()
	var out := ""
	for c in raw:
		out += String.chr(c)
	return out

## Rounds a float to single precision, as the client's float32 arithmetic.
static func f32(x: float) -> float:
	var a := PackedFloat32Array([x])
	return a[0]

## The client's _ftol: truncation, and 0x80000000 (as a signed int32) for NaN
## or anything outside the int32 range.
static func ftol(x: float) -> int:
	if is_nan(x) or x >= 2147483648.0 or x < -2147483648.0:
		return -2147483648
	return int(x)

## Wraps an integer to int32, as the client's imul/add do.
static func i32(v: int) -> int:
	return ((v + 0x80000000) & 0xFFFFFFFF) - 0x80000000

## Bytes between the magic and the root node for a version (FUN_00cb8d70:
## an f32 when >= "0012", three u32 more when >= "0013"), or -1 to reject.
## "0000" files are not the node format (see EFP_FORMAT.md) and are rejected.
static func header_size(version: String) -> int:
	match version:
		"0010", "0011":
			return 0
		"0012":
			return 4
		"0013":
			return 16
	return -1

# A bounds-checked cursor with a sticky error: after the first failure every
# read returns 0/"" and counts return 0, so loops end and decode returns null.
class _Cur:
	var b: PackedByteArray
	var off: int = 0
	var err: String = ""

	func _init(data: PackedByteArray, start: int) -> void:
		b = data
		off = start

	func fail(msg: String) -> void:
		if err == "":
			err = "%s at offset %d" % [msg, off]

	func need(n: int) -> bool:
		if err != "":
			return false
		if n < 0 or off + n > b.size():
			fail("truncated: need %d bytes" % n)
			return false
		return true

	func u8() -> int:
		if not need(1):
			return 0
		off += 1
		return b[off - 1]

	func u32() -> int:
		if not need(4):
			return 0
		off += 4
		return b.decode_u32(off - 4)

	func f32() -> float:
		if not need(4):
			return 0.0
		off += 4
		return b.decode_float(off - 4)

	func count(limit: int) -> int:
		var n := u32()
		if n > limit:
			fail("count %d above %d" % [n, limit])
			return 0
		return n

	func text() -> String:
		var n := u32()
		if n > 4096: # MAX_STRING_LEN
			fail("string length %d" % n)
			return ""
		if not need(n):
			return ""
		off += n
		return EfpReader.latin1(b.slice(off - n, off))

	func vec3() -> Vector3:
		if not need(12):
			return Vector3.ZERO
		var v := Vector3(b.decode_float(off), b.decode_float(off + 4), b.decode_float(off + 8))
		off += 12
		return v

	func mat4() -> PackedFloat32Array:
		var m := PackedFloat32Array()
		if not need(64):
			return m
		m.resize(16)
		for i in range(16):
			m[i] = b.decode_float(off + 4 * i)
		off += 64
		return m

	func strs() -> PackedStringArray:
		var out := PackedStringArray()
		var n := count(1 << 20) # MAX_LIST_LEN
		for i in range(n):
			out.append(text())
			if err != "":
				break
		return out

## Decodes a whole .efp into its typed tree, or returns null (see last_error).
static func decode(data: PackedByteArray) -> EfpFile:
	last_error = ""
	if data.size() < MAGIC_LEN + 1 + VERSION_LEN:
		last_error = "file too small to contain a header"
		return null
	if data.slice(0, MAGIC_LEN + 1).get_string_from_ascii() != MAGIC + " ":
		last_error = "bad magic"
		return null
	var f := EfpFile.new()
	f.version = data.slice(MAGIC_LEN + 1, MAGIC_LEN + 1 + VERSION_LEN).get_string_from_ascii()
	var hs := header_size(f.version)
	if hs < 0:
		last_error = "unrecognized version %s" % f.version
		return null
	var r := _Cur.new(data, MAGIC_LEN + 1 + VERSION_LEN)
	if hs >= 4:
		f.header_0012 = r.f32()
	if hs >= 16:
		for i in range(3):
			f.header_0013[i] = r.u32()
	f.root = _node(r, 0)
	if r.err != "":
		last_error = r.err
		return null
	f.trailing = data.size() - r.off
	return f

static func _value(r: _Cur, typ: String):
	match typ:
		"float":
			return {"type": typ, "value": r.f32()}
		"Vector":
			return {"type": typ, "value": r.vec3()}
		"Matrix":
			return {"type": typ, "matrix": r.mat4()}
		"AxisVector4":
			var ax := _vec4(r)
			return {"type": typ, "axis": ax, "matrix": r.mat4()}
		"RotVector":
			var rot := r.vec3()
			return {"type": typ, "rot": rot, "matrix": r.mat4()}
		"AngleVector1":
			var a := r.vec3()
			return {"type": typ, "a": a, "b": r.vec3()}
		"SEFStaticEmit":
			var d := r.u32()
			var du := r.u32()
			var iv := r.u32()
			var c := r.u32()
			return {"type": typ, "delay": d, "duration": du, "interval": iv, "max_live": c, "per_trigger": r.f32()}
		"FrameScale":
			var n := r.count(MAX_LIST_LEN)
			var fs := PackedVector3Array()
			if r.need(12 * n):
				for i in range(n):
					fs.append(r.vec3())
			return {"type": typ, "frames": fs}
		"FrameDiffuse":
			var n := r.count(MAX_LIST_LEN)
			var cs := PackedInt64Array()
			if r.need(4 * n):
				for i in range(n):
					cs.append(r.u32())
			return {"type": typ, "colors": cs}
		"FrameBANRotation":
			var head := r.f32()
			var n := r.count(MAX_LIST_LEN)
			var ms := []
			if r.need(64 * n):
				for i in range(n):
					ms.append(r.mat4())
			return {"type": typ, "head": head, "matrices": ms}
		"FrameBANPosition":
			var head := r.f32()
			var n := r.count(MAX_LIST_LEN)
			var ps := PackedVector3Array()
			if r.need(12 * n):
				for i in range(n):
					ps.append(r.vec3())
			return {"type": typ, "head": head, "positions": ps}
		"BSAnimation":
			return {"type": typ, "names": r.strs()}
		"FrameTextureSlide":
			var head := r.vec3()
			var n := r.count(MAX_LIST_LEN)
			var ks := []
			if r.need(16 * n):
				for i in range(n):
					ks.append(_vec4(r))
			return {"type": typ, "head": head, "keys": ks}
		"BlendScaleGraph":
			var a := r.f32()
			var bb := r.f32()
			var n := r.count(MAX_LIST_LEN)
			var ts := PackedFloat32Array()
			var ss := PackedVector3Array()
			if r.need(16 * n):
				for i in range(n):
					ts.append(r.f32())
					ss.append(r.vec3())
			var order := _map_order(ts)
			var ts2 := PackedFloat32Array()
			var ss2 := PackedVector3Array()
			for i in order:
				ts2.append(ts[i])
				ss2.append(ss[i])
			return {"type": typ, "a": a, "b": bb, "times": ts2, "scales": ss2}
		"BlendScaleGraphPointer":
			return {"type": typ, "value": r.u32()}
		"BlendDiffuseGraph":
			return _diffuse_graph(r)
	r.fail("unknown value type %s" % typ)
	return null

# Four floats in order (kept out of a constructor call so the read order is
# explicit).
static func _vec4(r: _Cur) -> Vector4:
	var x := r.f32()
	var y := r.f32()
	var z := r.f32()
	return Vector4(x, y, z, r.f32())

static func _diffuse_graph(r: _Cur) -> Dictionary:
	var a := r.f32()
	var bb := r.f32()
	var n := r.count(MAX_LIST_LEN)
	var ts := PackedFloat32Array()
	var cs := PackedInt64Array()
	if r.need(8 * n):
		for i in range(n):
			ts.append(r.f32())
			cs.append(r.u32())
	var order := _map_order(ts)
	var ts2 := PackedFloat32Array()
	var cs2 := PackedInt64Array()
	for i in order:
		ts2.append(ts[i])
		cs2.append(cs[i])
	return {"type": "BlendDiffuseGraph", "a": a, "b": bb, "times": ts2, "colors": cs2}

## Graph keys live in a std::map keyed by time (READ: FUN_00c9f420,
## FUN_00c9e2b0, FUN_00cbf880, FUN_00cbf970 insert with map[time] = value):
## the indices of the keys in ascending time, a repeated time keeping the one
## read last. Mirrors Go's mapKeys.
static func _map_order(ts: PackedFloat32Array) -> Array:
	var idx := []
	for i in range(ts.size()):
		idx.append(i)
	idx.sort_custom(func(x, y): return ts[x] < ts[y] or (ts[x] == ts[y] and x < y))
	var out := []
	for k in range(idx.size()):
		if k + 1 < idx.size() and ts[idx[k + 1]] == ts[idx[k]]:
			continue
		out.append(idx[k])
	return out

# One FUN_00ca5460 entry; null for an absent slot (u8 0) or on error.
static func _command(r: _Cur) -> EfpCommand:
	if r.u8() == 0:
		return null
	var c := EfpCommand.new()
	c.name = r.text()
	if not r.need(14):
		return null
	c.space = r.u8()
	c.time_flags = r.u8()
	c.start = r.f32()
	c.step = r.f32()
	c.end = r.f32()
	if not COMMAND_TYPES.has(c.name):
		r.fail("unknown command %s" % c.name)
		return null
	var typ: String = COMMAND_TYPES[c.name]
	if typ != "":
		c.value = _value(r, typ)
	return c

static func _command_list(r: _Cur) -> Array[EfpCommand]:
	var out: Array[EfpCommand] = []
	var n := r.count(MAX_CONTROLLERS)
	for i in range(n):
		var c := _command(r)
		if r.err != "":
			break
		if c != null:
			out.append(c)
	return out

static func _render_state(r: _Cur) -> EfpRenderState:
	var s := EfpRenderState.new()
	if not r.need(36):
		return s
	s.cull = r.u32()
	if s.cull == 2:
		s.cull = 3 # the loader's own rewrite (FUN_00cc3400)
	s.src_blend = r.u32()
	s.dest_blend = r.u32()
	s.color_arg1 = r.u32()
	s.color_arg2 = r.u32()
	s.color_op = r.u32()
	s.alpha_arg1 = r.u32()
	s.alpha_arg2 = r.u32()
	s.alpha_op = r.u32()
	return s

static func _meshes(r: _Cur) -> Array[EfpMeshRef]:
	var out: Array[EfpMeshRef] = []
	var n := r.count(MAX_LIST_LEN)
	for i in range(n):
		var m := EfpMeshRef.new()
		m.mesh = r.text()
		m.textures = r.strs()
		if r.err != "":
			break
		out.append(m)
	return out

# A controller-side graph: f32 a, f32 b, u32 n, n x (f32 time, value) where
# the value is a 4-byte float (value_size 4) or a byte (1).
static func _key_graph(r: _Cur, value_size: int) -> Dictionary:
	var a := r.f32()
	var bb := r.f32()
	var n := r.count(MAX_LIST_LEN)
	var ts := PackedFloat32Array()
	var vs := PackedFloat32Array()
	if r.need((4 + value_size) * n):
		for i in range(n):
			ts.append(r.f32())
			vs.append(r.f32() if value_size == 4 else float(r.u8()))
	var order := _map_order(ts)
	var ts2 := PackedFloat32Array()
	var vs2 := PackedFloat32Array()
	for i in order:
		ts2.append(ts[i])
		vs2.append(vs[i])
	return {"a": a, "b": bb, "times": ts2, "values": vs2}

static func _controller(r: _Cur, key: String) -> EfpController:
	var c := EfpController.new()
	c.key = key
	match key:
		"NormalTimeLife", "NormalTimeLoopLife":
			pass
		"StaticEmit":
			c.data["emit"] = _value(r, "SEFStaticEmit")
		"LinkMode":
			var l := PackedInt64Array()
			for i in range(4):
				l.append(r.u32())
			c.data["link"] = l
		"Program":
			c.data["commands"] = _command_list(r)
		"BAN":
			c.data["names"] = r.strs()
		"ViewMode":
			c.data["view"] = r.text()
		"Shape":
			c.data["render"] = r.text()
			c.data["state"] = _render_state(r)
			c.data["meshes"] = _meshes(r)
		"ScaleGraph":
			var axes := []
			for i in range(3):
				axes.append(_key_graph(r, 4))
			c.data["axes"] = axes
			c.data["tail1"] = r.u32()
			c.data["tail2"] = r.f32()
		"DiffuseGraph":
			c.data["alpha"] = _key_graph(r, 1)
			c.data["color"] = _diffuse_graph(r)
		_:
			r.fail("unknown controller %s" % key)
	return c

static func _node(r: _Cur, depth: int) -> EfpNode:
	if depth > MAX_DEPTH:
		r.fail("nodes nested deeper than %d" % MAX_DEPTH)
		return null
	var n := EfpNode.new()
	n.head_len = r.u32()
	var head_start := r.off
	n.name = r.text()
	var nc := r.count(MAX_CONTROLLERS)
	for i in range(nc):
		var key := r.text()
		if r.err != "":
			return null
		n.controllers.append(_controller(r, key))
		if r.err != "":
			return null
	n.head_span = r.off - head_start
	# The body, FUN_00cc3500, field by field.
	n.frames = r.u32()
	var nv := r.count(MAX_CONTROLLERS)
	for i in range(nv):
		var typ := r.text()
		if r.err != "":
			return null
		n.vars.append({"type": typ, "value": _value(r, typ)})
		if r.err != "":
			return null
	n.list_90 = _command_list(r)
	n.emit = _command_list(r)
	n.list_d8 = _command_list(r)
	n.extinct = _command(r)
	n.update = _command_list(r)
	if r.need(20):
		for k in ["b0", "b1", "u2", "u3", "u4", "b5", "u6", "b7"]:
			n.flags[k] = r.u8() if k.begins_with("b") else r.u32()
	n.view = _command(r)
	n.state = _render_state(r)
	n.meshes = _meshes(r)
	n.render = _command(r)
	n.list_20c = _command_list(r)
	n.commands = _command_list(r)
	var kids := r.count(MAX_LIST_LEN)
	for i in range(kids):
		if r.err != "":
			return null
		var k := _node(r, depth + 1)
		if r.err != "":
			return null
		n.children.append(k)
	if r.err != "":
		return null
	return n

# ---------------------------------------------------------------- flat walk

class Entry:
	var entry_name: String
	## Raw, unparsed bytes -- see the flat-walk notes in EFP_FORMAT.md.
	var value: PackedByteArray

class ParsedEffect:
	## "0010", "0011", "0012" or "0013".
	var version: String
	var effect_name: String
	## The root node's controller count (READ, FUN_00cc3a40).
	var count: int
	var entries: Array[Entry] = []

## Parses a .efp file's raw bytes into the flat walk. Returns null (and pushes
## an error) on failure. The header is the client's (header_size), then the
## root node's u32 head length (name + controllers) and its name, which may be any string without control
## characters.
static func parse(data: PackedByteArray) -> ParsedEffect:
	if data.size() < MAGIC_LEN + 1 + VERSION_LEN:
		push_error("efp: file too small to contain a header")
		return null
	var magic := data.slice(0, MAGIC_LEN + 1).get_string_from_ascii()
	if magic != MAGIC + " ":
		push_error("efp: bad magic %s, want %s" % [magic, MAGIC])
		return null

	var e := ParsedEffect.new()
	e.version = data.slice(MAGIC_LEN + 1, MAGIC_LEN + 1 + VERSION_LEN).get_string_from_ascii()

	var hs := header_size(e.version)
	if hs < 0:
		push_error("efp: unrecognized version %s" % e.version)
		return null
	var off := MAGIC_LEN + 1 + VERSION_LEN + hs + 4 # version header, root head length

	var name_result = _read_effect_name(data, off)
	if name_result == null:
		push_error("efp: reading effect name")
		return null
	e.effect_name = name_result[0]
	off = name_result[1]

	if off + 4 > data.size():
		push_error("efp: truncated before top-level count")
		return null
	e.count = _le_u32(data, off)
	off += 4

	while off < data.size():
		var entry_result = _read_name(data, off)
		if entry_result == null:
			break # the file's small trailer, or truncation
		var entry_name: String = entry_result[0]
		var value_start: int = entry_result[1]

		var value_end := _find_next_name(data, value_start)
		if value_end == -1:
			var entry := Entry.new()
			entry.entry_name = entry_name
			entry.value = data.slice(value_start, data.size())
			e.entries.append(entry)
			off = data.size()
			break

		var entry := Entry.new()
		entry.entry_name = entry_name
		entry.value = data.slice(value_start, value_end)
		e.entries.append(entry)
		off = value_end

	if e.entries.is_empty():
		push_error("efp: no entries parsed")
		return null

	return e

## The root name: any u32-length-prefixed run of 1-255 bytes without control
## characters. Bytes above 0x7f are allowed: system\system_levelup.efp and its
## three copies name their root in EUC-KR.
static func _read_effect_name(data: PackedByteArray, off: int):
	if off + 4 > data.size():
		return null
	var n := _le_u32(data, off)
	off += 4
	if n <= 0 or n > 255 or off + n > data.size():
		return null
	var s := data.slice(off, off + n)
	for c in s:
		if c < 0x20 or c == 0x7f:
			return null
	return [latin1(s), off + n]

static func _find_next_name(data: PackedByteArray, off: int) -> int:
	var limit := data.size()
	if off + MAX_SCAN_SKIP < limit:
		limit = off + MAX_SCAN_SKIP
	var scan := off
	while scan < limit:
		if _read_name(data, scan) != null:
			return scan
		scan += 1
	return -1

## Reads a uint32-length-prefixed name at off: 1-40 ASCII
## letters/digits/underscores, starting with a letter -- the flat walk's
## boundary rule.
static func _read_name(data: PackedByteArray, off: int):
	if off + 4 > data.size():
		return null
	var n := _le_u32(data, off)
	off += 4
	if n <= 0 or n > MAX_NAME_LEN or off + n > data.size():
		return null
	var s := data.slice(off, off + n)
	if not _is_alpha(s[0]):
		return null
	for c in s:
		if not (_is_alpha(c) or _is_digit(c) or c == 95):
			return null
	return [s.get_string_from_ascii(), off + n]

static func _is_alpha(c: int) -> bool:
	return (c >= 97 and c <= 122) or (c >= 65 and c <= 90)

static func _is_digit(c: int) -> bool:
	return c >= 48 and c <= 57

static func _le_u32(b: PackedByteArray, off: int) -> int:
	return b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24)
