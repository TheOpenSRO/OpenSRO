extends RefCounted
class_name ClothSim

## One mesh's cloth on one body (round 794): retail's Dynamic Animation, READ
## from sro_client.exe; docs/protocol/CLOTH.md has the addresses. The native
## twin is native/src/core/cloth.rs (SrCloth through ClothNative); this one
## steps the same rules in GDScript when the library is missing. GDScript's
## scalars are doubles where Rust's are f32, so the two agree to a tolerance,
## not bit for bit (cloth_test.gd).
##
## - **The data** (BmsReader.CLOTH_META): hdr[2] per vertex an amount and
##   pinned; hdr[3] the links (two vertices, a rest length), an order over
##   them, and the parameter block -- the use-the-file's-wind flag, the wind,
##   gravity, gravity's gain per amount, the gust's gain per amount, the
##   velocity kept, the gust divisor.
## - **skin** (FUN_00c52270): near (LOD 0) only the pinned vertices, their
##   position into the particle and their normal into the buffer; far, all.
## - **step** (CCompChar::FUN_00c0d010, one per 50 ms): position Verlet for
##   every vertex not pinned -- gravity `g * -5 * (k * a + 1)` on Y, a gust
##   when `rand() % n == 0` of `(p' + 100) * (k2 * a + 1) * wind`, then
##   `cur += kept * (cur - prev) + acc * 0.0004` -- and up to 7 passes over
##   the links in the file's order, each pulling a pair together only when it
##   is 0.01 or more past its rest, split by the two amounts.
## - **vertex_data** (FUN_00c0d610's copy out): every particle's position;
##   the normals the last skin wrote (the bind pose's at first: a free
##   vertex's normal is never recomputed).

## MSVC's rand() state (0xb44c36), the one generator every cloth rolls on, as
## retail's is the C library's global one.
static var rand_seed := 1

static func srand(seed: int) -> void:
	rand_seed = seed & 0xFFFFFFFF

static func rand() -> int:
	rand_seed = (rand_seed * 214013 + 2531011) & 0xFFFFFFFF
	return (rand_seed >> 16) & 0x7FFF

## p's shaping (FUN_00c0d010's top: 0.2, 0.2f, 900).
static func shape_p(p: float) -> float:
	if p > 0.0:
		if p >= 0.2:
			return p * 900.0 if p < 1.0 else 900.0
		return 0.2 * 900.0
	return p

var amount := PackedFloat32Array()
var pinned := PackedByteArray()
var links := PackedInt32Array()
var rest := PackedFloat32Array()
var order := PackedInt32Array()
var file_wind := false
var wind := Vector3.ZERO
var gravity := 0.0
var gravity_gain := 0.0
var gust_gain := 0.0
var retention := 0.0
var gust_div := 1
var cur := PackedVector3Array()
var prev := PackedVector3Array()
var nrm := PackedVector3Array()
var _bind_pos := PackedVector3Array()
var _bind_nrm := PackedVector3Array()
var _bones := PackedInt32Array()
var _weights := PackedFloat32Array()
var _per := 0
var _tangent := PackedByteArray()
var _error := ""

func last_error() -> String:
	return _error

## `d`: amount, pinned, links, rest, order, params (BmsReader.CLOTH_META's),
## positions, normals, bones, weights (the surface's arrays) and vertex_data
## (Godot's bytes, for the tangent words). False, with last_error(), when the
## data is not a cloth the step can run (SrCloth refuses the same).
func setup(d: Dictionary) -> bool:
	amount = d["amount"]
	pinned = d["pinned"]
	links = d["links"]
	rest = d["rest"]
	order = d["order"]
	var params: PackedFloat32Array = d["params"]
	var positions: PackedVector3Array = d["positions"]
	var normals: PackedVector3Array = d["normals"]
	_bones = d["bones"]
	_weights = d["weights"]
	var n := positions.size()
	if n == 0 or amount.size() != n or pinned.size() != n or normals.size() != n:
		_error = "vertex counts disagree"
		return false
	if rest.is_empty() or links.size() != rest.size() * 2:
		_error = "link counts disagree"
		return false
	if params.size() < 9:
		_error = "params: nine values"
		return false
	file_wind = params[0] != 0.0
	wind = Vector3(params[1], params[2], params[3])
	gravity = params[4]
	gravity_gain = params[5]
	gust_gain = params[6]
	retention = params[7]
	gust_div = int(params[8])
	if gust_div <= 0:
		_error = "gust divisor %d" % gust_div
		return false
	for i in range(rest.size()):
		var a := links[i * 2]
		var b := links[i * 2 + 1]
		if a < 0 or b < 0 or a >= n or b >= n:
			_error = "link %d out of range" % i
			return false
		if amount[a] + amount[b] == 0.0:
			_error = "link %d joins two still vertices" % i
			return false
	for k in order:
		if k < 0 or k >= rest.size():
			_error = "order out of range"
			return false
	_per = 0 if _bones.is_empty() else _bones.size() / n
	if _per > 0 and (_bones.size() != _per * n or _weights.size() != _per * n):
		_error = "skin counts disagree"
		return false
	_bind_pos = positions.duplicate()
	_bind_nrm = normals.duplicate()
	cur = positions.duplicate()
	prev = positions.duplicate()
	nrm = normals.duplicate()
	var vd: PackedByteArray = d["vertex_data"]
	_tangent.resize(n * 4)
	_tangent.fill(0)
	if vd.size() >= n * 20:
		for i in range(n):
			for k in range(4):
				_tangent[i * 4 + k] = vd[n * 12 + i * 8 + 4 + k]
	_error = ""
	return true

func reset() -> void:
	cur = _bind_pos.duplicate()
	prev = _bind_pos.duplicate()
	nrm = _bind_nrm.duplicate()

## FUN_00c52270. `mats`: 12 floats a bind -- the basis's columns, then the
## origin -- of the bone's pose times the bind pose.
func skin(mats: PackedFloat32Array, near: bool) -> void:
	if _per == 0:
		return
	var nb := mats.size() / 12
	for i in range(cur.size()):
		if near and pinned[i] == 0:
			continue
		var v := _bind_pos[i]
		var nv := _bind_nrm[i]
		var p := Vector3.ZERO
		var q := Vector3.ZERO
		var ws := 0.0
		for k in range(_per):
			var w := _weights[i * _per + k]
			var b := _bones[i * _per + k]
			if w <= 0.0 or b < 0 or b >= nb:
				continue
			var o := b * 12
			var cx := Vector3(mats[o], mats[o + 1], mats[o + 2])
			var cy := Vector3(mats[o + 3], mats[o + 4], mats[o + 5])
			var cz := Vector3(mats[o + 6], mats[o + 7], mats[o + 8])
			var t := Vector3(mats[o + 9], mats[o + 10], mats[o + 11])
			p += (cx * v.x + cy * v.y + cz * v.z + t) * w
			q += (cx * nv.x + cy * nv.y + cz * nv.z) * w
			ws += w
		if ws <= 0.0:
			continue
		cur[i] = p
		nrm[i] = q

func step(steps: int, w: Vector3, p: float) -> void:
	for _s in range(maxi(steps, 0)):
		step_once(w, p)

## CCompChar::FUN_00c0d010.
func step_once(w: Vector3, p: float) -> void:
	p = shape_p(p)
	for i in range(cur.size()):
		if pinned[i] != 0:
			continue
		var a := amount[i]
		var acc := Vector3(0.0, gravity * -5.0 * (gravity_gain * a + 1.0), 0.0)
		if rand() % gust_div == 0:
			acc += w * ((p + 100.0) * (gust_gain * a + 1.0))
		var old := prev[i]
		var c := cur[i]
		prev[i] = c
		cur[i] = c + (c - old) * retention + acc * 0.0004
	var passes := 0
	while true:
		var clean := true
		for k in order:
			var v0 := links[k * 2]
			var v1 := links[k * 2 + 1]
			var d := cur[v1] - cur[v0]
			var length := d.length()
			var err := length - rest[k]
			if err >= 0.01:
				clean = false
				var a0 := amount[v0]
				var a1 := amount[v1]
				var corr := (d / length) * err
				cur[v0] += corr * (a0 / (a1 + a0))
				cur[v1] -= corr * (a1 / (a1 + a0))
		if clean:
			break
		passes += 1
		if passes >= 7:
			break

## Godot 4.7's vertex stream for an uncompressed surface (MEASURED on the
## box): every position, 12 bytes; then per vertex the normal and the tangent,
## octahedral u16 pairs.
func vertex_data() -> PackedByteArray:
	var n := cur.size()
	var out := PackedByteArray()
	out.resize(n * 20)
	for i in range(n):
		var p := cur[i]
		out.encode_float(i * 12, p.x)
		out.encode_float(i * 12 + 4, p.y)
		out.encode_float(i * 12 + 8, p.z)
	for i in range(n):
		var o := octahedral_u16(nrm[i])
		var at := n * 12 + i * 8
		out.encode_u16(at, o.x)
		out.encode_u16(at + 2, o.y)
		for k in range(4):
			out[at + 4 + k] = _tangent[i * 4 + k]
	return out

func positions() -> PackedVector3Array:
	return cur

func bounds() -> AABB:
	if cur.is_empty():
		return AABB()
	var box := AABB(cur[0], Vector3.ZERO)
	for p in cur:
		box = box.expand(p)
	return box

## Godot's Vector3.octahedron_encode (normalised first) and the surface's
## `(uint16_t)CLAMP(x * 65535, 0, 65535)`.
static func octahedral_u16(v: Vector3) -> Vector2i:
	var n := v.normalized() if v.length_squared() > 0.0 else Vector3(0, 0, 1)
	var o := n.octahedron_encode()
	return Vector2i(int(clampf(o.x * 65535.0, 0.0, 65535.0)), int(clampf(o.y * 65535.0, 0.0, 65535.0)))
