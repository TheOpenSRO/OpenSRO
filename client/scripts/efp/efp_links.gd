extends RefCounted
class_name EfpLinks

## The three "Link" render modes of a .efp node (round 621): RenderLinkDPipe,
## RenderLinkPipe and RenderLinkObj. Each draws ONE triangle strip through a
## chain of particles. Pure geometry over packed buffers -- no nodes, no
## per-point objects -- so the headless tests drive it with synthetic chains
## and a frame's strips cost no allocations beyond the buffers' growth.
## EfpEffect feeds it and draws the result. docs/protocol/EFP_FORMAT.md
## "Link render modes" has the addresses.
##
## == The chain (READ) ==
## Every emitter keeps its particles in an intrusive list: the emitter
## constructor FUN_00c88320 sets the list at emitter+0x30 with prev offset
## 0x34 and next offset 0x38, and the particle init FUN_00c88490 appends the
## new particle at the tail (FUN_00c87360 on emitter+0x30, at 0x00c88769);
## a death unlinks it (CEFElement::FUN_00c873a0). So particle+0x34 is the
## particle the same emitter spawned before it that is still alive, and
## +0x38 the one after. Each Link routine returns at once unless +0x34 is 0,
## so only the oldest live particle draws, and it walks the list through
## +0x38 to the newest: one strip per emitter, oldest first.
##
## == Points and the dedupe (READ) ==
## A point is (position +0x1b0, colour +0x228, width = scale.x +0x1c8). A
## particle closer than 1e-6 (the float at 0x00e1b848) on every axis to the
## last TAKEN position is a near-duplicate:
## - LinkDPipe and LinkPipe (0x00c8df3f-0x00c8dfdd, and the same loop in
##   FUN_00c8e020) write each particle into the next free slot and advance
##   only when it is taken, so a near-duplicate is DROPPED and the older
##   point kept.
## - LinkObj (0x00c8c433-0x00c8c4c7) advances first and writes after, so a
##   near-duplicate OVERWRITES the last taken pair; the comparison stays
##   against the position that was taken (local_48 is updated only when a
##   particle is taken), not the one that overwrote it.
## - LinkPipe's first particle is compared against local_58 before anything
##   was stored in it (its counter starts at 1, so the "first point" test
##   never fires): retail reads uninitialised stack there. This client takes
##   the first particle always (OURS; a match within 1e-6 of stack garbage
##   is not reproducible).
##
## == LinkDPipe (READ, EFEffect::FUN_00c8de80) ==
## The points as they are, into the pipe ribbon below. Needs 2 points.
##
## == LinkPipe (READ, EFEffect::FUN_00c8e020) ==
## The points P1..Pm with P0 = P1 and P(m+1) = Pm added, then a uniform cubic
## B-spline: each segment i = 0..m-2 over P(i)..P(i+3) is sampled at
## t = 0, 1/3, 2/3 (the step is the double 0.3333333432674408 at 0x00e0ec60,
## 3 samples: the loop count is literal) with weights (1-t)^3/6,
## (3t^3 - 6t^2 + 4)/6, (-3t^3 + 3t^2 + 3t + 1)/6 and t^3/6 (the doubles 3.0
## at 0x00e1b808, 6.0 at 0x00d99a68, 4.0 at 0x00e1b860, 1.0 at 0x00e1b7f0).
## The sample's colour is P(i+1)'s to P(i+2)'s, each byte lerped by t and
## rounded (fistp); its width P(i+1)'s plus k*(P(i+2) - P(i+1))/3. Pm is
## appended as the last point. So m points give 3(m-1)+1. Needs m >= 2.
##
## == The pipe ribbon (READ, EFEffect::FUN_00c8d0e0) ==
## Given N >= 2 points, each is projected (thunk_FUN_00aa30f0 with
## (out, in, NULL, 0x00edbea8, 0x00edbe68, NULL): the argument shape of
## D3DXVec3Project(out, v, viewport, projection, view, world), INFERRED; with
## no viewport the result is in normalised device coordinates). At point i the
## screen direction is d = C(i-1) - C(i+1) (C0 - C1 at the first point,
## C(N-2) - C(N-1) at the last); (d.y, -d.x, 0) is turned by the matrix at
## 0x00edbde8 (FUN_00854e30, a row-vector transform) and normalised
## (FUN_00410cd0). 0x00edbde8 is the billboard matrix, whose rows are the
## inverse view's right, up and look (READ, round 620's review follow-up:
## CEFSystem::FUN_00cb0ee0), so the side is right*d.y - up*d.x. The two
## vertices are P + n*w (v = 0) and P - n*w (v = 1), both with the point's
## colour; u is 0 at the first point, i/(N-1) between, 1 at the last. The
## strip is D3DPT_TRIANGLESTRIP (5, pushed at 0x00c8d0c1), flushed at once
## (FUN_00cafa70), so strips never join.
##
## == LinkObj (READ, EFEffect::FUN_00c8c3a0) ==
## Each taken particle gives two edge points, pos + s*Y and pos - s*Y, where
## Y is the second row of its rotation (+0xc0, +0xc4, +0xc8) and s its
## scale.x. The pairs are A1..Ak, with A0 = A1 and A(k+1) = Ak (the copies at
## 0x00c8c6e5..0x00c8c735). Segments j = 0..k-3 -- k-2 of them, so the last
## pair is only a control point -- are sampled at t = 0, 1/3, 2/3 (the loop
## runs while t < 1.0) with the same B-spline, each edge on its own; the
## colour is A(j+1)'s to A(j+2)'s, lerped by byte. A(k-1) closes the strip.
## u runs from 1.0 at the first pair down by 2.0 (the double at 0x00e1b898)
## over the sample-vertex count, so it is 0 at the closing pair; v is 0 on the
## + edge and 1 on the - edge. Needs k >= 3 to make a triangle.
##
## == Drawing ==
## Every triangle of a chain's strip is drawn with its orientation REVERSED
## against D3D's -- the convention BmsReader uses for .bms triangles so that
## Godot's front face is D3D's (INFERRED from that fix, as for the plate and
## mesh nodes). The node's cull (render block +0x1a4: 1 none, 3 ccw) then
## applies as for any node. All of a node's chains go into one strip (Out).

## Round 763: native/src/core/efp_links.rs builds the camera-free strips
## (LinkObj, pipe_turn after spline) of a natively simulated effect the same
## way, bit for bit; a change here is a change there.

const EPS := 1e-6 ## READ: the float at 0x00e1b848
const T_STEP := 0.3333333432674408 ## READ: the double at 0x00e0ec60
const SAMPLES := 3 ## READ: the pipe's literal loop count

## The B-spline weights at the three sample times (t = 0, T_STEP, 2*T_STEP),
## four each, precomputed once.
static var _w: PackedFloat64Array = _weights()

static func _weights() -> PackedFloat64Array:
	var out := PackedFloat64Array()
	var t := 0.0
	for _k in range(SAMPLES):
		out.append_array(bspline(t))
		t += T_STEP
	return out

## The uniform cubic B-spline weights at t (READ constants, see the header).
static func bspline(t: float) -> PackedFloat64Array:
	var t2 := t * t
	var t3 := t2 * t
	var u := 1.0 - t
	return PackedFloat64Array([u * u * u / 6.0, (3.0 * t3 - 6.0 * t2 + 4.0) / 6.0,
		(-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) / 6.0, t3 / 6.0])

## Round half to even, as fistp does under the default FPU control word.
static func fround(x: float) -> int:
	var f := floorf(x)
	var r := x - f
	if r > 0.5:
		return int(f) + 1
	if r < 0.5:
		return int(f)
	return int(f) + (int(f) & 1)

## A D3DCOLOR lerped byte by byte and rounded (READ, both spline routines).
static func lerp_color(a: int, b: int, t: float) -> int:
	if a == b:
		return a
	var s := 1.0 - t
	var out := 0
	var sh := 0
	while sh < 32:
		var ca: int = (a >> sh) & 0xFF
		var cb: int = (b >> sh) & 0xFF
		out |= (clampi(fround(s * ca + t * cb), 0, 255) & 0xFF) << sh
		sh += 8
	return out

## A chain's points: packed and reused. `y` is only filled for LinkObj.
class Buf:
	var pos := PackedVector3Array()
	var col := PackedInt64Array()
	var w := PackedFloat32Array()
	var y := PackedVector3Array()
	var n := 0

	func reserve(k: int) -> void:
		if pos.size() < k:
			var c := maxi(k, pos.size() * 2)
			pos.resize(c)
			col.resize(c)
			w.resize(c)
			y.resize(c)

	## Appends a point (the tests' way in).
	func add(p: Vector3, c: int = 0xFFFFFFFF, width: float = 1.0, yaxis: Vector3 = Vector3.UP) -> void:
		reserve(n + 1)
		pos[n] = p
		col[n] = c
		w[n] = width
		y[n] = yaxis
		n += 1

## The vertices one node draws this frame, as ONE triangle strip: packed and
## reused. Each chain's strip is stitched to the previous one with repeated
## vertices, so every triangle between strips is degenerate (zero area,
## never drawn) and a node is one draw of PRIMITIVE_TRIANGLE_STRIP with no
## index buffer. Each chain's first vertex is placed at an ODD position of
## the joined strip, so its triangles take the strip's reversed orientation
## -- the reversal described in the header (OURS: the stitching).
class Out:
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var nv := 0
	var _pre := 0
	var _prefix := 0
	var _stitch := false
	## Round 741, a shared-turn pipe (pipe_turn): every vertex is its point's
	## centre, and these carry what the shader needs to build the side --
	## c0 the previous point and the signed width, c1 the next point (4
	## floats a vertex each).
	var turn := false
	var c0 := PackedFloat32Array()
	var c1 := PackedFloat32Array()

	func clear() -> void:
		nv = 0

	func reserve(v: int) -> void:
		if verts.size() < nv + v:
			var c := maxi(nv + v, verts.size() * 2)
			verts.resize(c)
			colors.resize(c)
			uvs.resize(c)
		if turn and c0.size() < 4 * verts.size():
			c0.resize(4 * verts.size())
			c1.resize(4 * verts.size())

	## Upper bound of the triangles drawn (degenerate ones included).
	func triangles() -> int:
		return maxi(nv - 2, 0)

	## Opens a chain's strip of `count` vertices: leaves room for the
	## stitching vertices, filled by end_strip.
	func begin_strip(count: int) -> void:
		_stitch = nv > 0
		_prefix = (1 if _stitch else 0) + 1
		if (nv + _prefix) % 2 == 0:
			_prefix += 1
		reserve(_prefix + count)
		_pre = nv
		nv += _prefix

	## Fills the stitching vertices: the previous strip's last vertex once,
	## then this strip's first vertex until the strip starts.
	func end_strip() -> void:
		var at := _pre
		if _stitch:
			verts[at] = verts[at - 1]
			colors[at] = colors[at - 1]
			uvs[at] = uvs[at - 1]
			if turn:
				_copy_custom(at - 1, at)
			at += 1
		var first := _pre + _prefix
		while at < first:
			verts[at] = verts[first]
			colors[at] = colors[first]
			uvs[at] = uvs[first]
			if turn:
				_copy_custom(first, at)
			at += 1

	func _copy_custom(from: int, to: int) -> void:
		for k in 4:
			c0[4 * to + k] = c0[4 * from + k]
			c1[4 * to + k] = c1[4 * from + k]

	## Two vertices of a strip step.
	func pair(a: Vector3, b: Vector3, c: int, u: float) -> void:
		var col := Color(((c >> 16) & 0xFF) / 255.0, ((c >> 8) & 0xFF) / 255.0, (c & 0xFF) / 255.0,
			((c >> 24) & 0xFF) / 255.0)
		verts[nv] = a
		verts[nv + 1] = b
		colors[nv] = col
		colors[nv + 1] = col
		uvs[nv] = Vector2(u, 0.0)
		uvs[nv + 1] = Vector2(u, 1.0)
		nv += 2

	## The drawn triangles as index triples in their rendered orientation
	## (strip triangle t is (t, t+1, t+2) for even t, (t+1, t, t+2) for odd
	## t), degenerate ones left out (tests).
	func expand() -> Array:
		var out: Array = []
		for t in range(nv - 2):
			var a := t
			var b := t + 1
			if t % 2 == 1:
				a = t + 1
				b = t
			var c := t + 2
			if verts[a] == verts[b] or verts[b] == verts[c] or verts[a] == verts[c]:
				continue
			out.append([a, b, c])
		return out

	## The finished arrays for a strip surface (sliced to the used length).
	func arrays() -> Array:
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = verts.slice(0, nv)
		a[Mesh.ARRAY_COLOR] = colors.slice(0, nv)
		a[Mesh.ARRAY_TEX_UV] = uvs.slice(0, nv)
		if turn:
			a[Mesh.ARRAY_CUSTOM0] = c0.slice(0, 4 * nv)
			a[Mesh.ARRAY_CUSTOM1] = c1.slice(0, 4 * nv)
		return a

	## The surface format flags arrays() needs (the two custom channels of a
	## shared-turn pipe are RGBA floats).
	func format_flags() -> int:
		if not turn:
			return 0
		return (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
			| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)

## A chain's particles from its head along next_link into `b`, with the
## mode's dedupe (see the header). `head` is the emitter's oldest live
## particle (link == null).
static func gather_from(head: EfpSim.Particle, obj: bool, b: Buf) -> void:
	b.n = 0
	var pos := b.pos
	var col := b.col
	var w := b.w
	var y := b.y
	b.pos = PackedVector3Array()
	b.col = PackedInt64Array()
	b.w = PackedFloat32Array()
	b.y = PackedVector3Array()
	var n := 0
	var cap := pos.size()
	var last := Vector3.ZERO
	var p := head
	while p != null:
		var at := p.pos
		if n > 0:
			var d := at - last
			if absf(d.x) <= EPS and absf(d.y) <= EPS and absf(d.z) <= EPS:
				if obj:
					pos[n - 1] = at
					col[n - 1] = p.color
					w[n - 1] = p.scale.x
					y[n - 1] = p.rot.y
				p = p.next_link
				continue
		if n >= cap:
			cap = maxi(16, cap * 2)
			pos.resize(cap)
			col.resize(cap)
			w.resize(cap)
			y.resize(cap)
		pos[n] = at
		col[n] = p.color
		w[n] = p.scale.x
		if obj:
			y[n] = p.rot.y
		n += 1
		last = at
		p = p.next_link
	b.pos = pos
	b.col = col
	b.w = w
	b.y = y
	b.n = n

## The same dedupe over points already in `src` (the tests' way in).
static func dedupe(src: Buf, obj: bool, dst: Buf) -> void:
	dst.n = 0
	dst.reserve(src.n)
	var last := Vector3.ZERO
	for i in range(src.n):
		if dst.n > 0:
			var d := src.pos[i] - last
			if absf(d.x) <= EPS and absf(d.y) <= EPS and absf(d.z) <= EPS:
				if obj:
					var k := dst.n - 1
					dst.pos[k] = src.pos[i]
					dst.col[k] = src.col[i]
					dst.w[k] = src.w[i]
					dst.y[k] = src.y[i]
				continue
		dst.pos[dst.n] = src.pos[i]
		dst.col[dst.n] = src.col[i]
		dst.w[dst.n] = src.w[i]
		dst.y[dst.n] = src.y[i]
		dst.n += 1
		last = src.pos[i]

## One byte of a lerped colour: (1-t)*a + t*b rounded half to even (fistp),
## the inline form of lerp_color used by the builders below.
static func _lerp_byte(a: int, b: int, s: float, t: float) -> int:
	var x := s * a + t * b
	var r := int(x + 0.5)
	if r & 1 and float(r) - x == 0.5:
		r -= 1
	return r

## LinkPipe's B-spline through the points in `src`, into `dst`. Empty below
## 2 points.
static func spline(src: Buf, dst: Buf) -> void:
	var m := src.n
	dst.n = 0
	if m < 2:
		return
	dst.reserve(3 * (m - 1) + 1)
	# Take the buffers out of `dst` while writing, so no copy-on-write.
	var op := dst.pos
	var oc := dst.col
	var ow := dst.w
	dst.pos = PackedVector3Array()
	dst.col = PackedInt64Array()
	dst.w = PackedFloat32Array()
	var sp := src.pos
	var sc := src.col
	var sw := src.w
	var w := _w
	var w00 := w[0]; var w01 := w[1]; var w02 := w[2]; var w03 := w[3]
	var w10 := w[4]; var w11 := w[5]; var w12 := w[6]; var w13 := w[7]
	var w20 := w[8]; var w21 := w[9]; var w22 := w[10]; var w23 := w[11]
	var t1 := T_STEP
	var t2 := T_STEP + T_STEP
	var n := 0
	for i in range(m - 1):
		# Control points P(i)..P(i+3) of the padded list P0 = P1, P(m+1) = Pm.
		var p0: Vector3 = sp[i - 1 if i > 0 else 0]
		var p1: Vector3 = sp[i]
		var p2: Vector3 = sp[i + 1]
		var p3: Vector3 = sp[i + 2 if i + 2 < m else m - 1]
		op[n] = p0 * w00 + p1 * w01 + p2 * w02 + p3 * w03
		op[n + 1] = p0 * w10 + p1 * w11 + p2 * w12 + p3 * w13
		op[n + 2] = p0 * w20 + p1 * w21 + p2 * w22 + p3 * w23
		var ca: int = sc[i]
		var cb: int = sc[i + 1]
		oc[n] = ca
		if ca == cb:
			oc[n + 1] = ca
			oc[n + 2] = ca
		else:
			oc[n + 1] = _lerp4(ca, cb, t1)
			oc[n + 2] = _lerp4(ca, cb, t2)
		var wa: float = sw[i]
		var dw: float = (sw[i + 1] - wa) / 3.0
		ow[n] = wa
		ow[n + 1] = wa + dw
		ow[n + 2] = wa + dw * 2.0
		n += 3
	op[n] = sp[m - 1]
	oc[n] = sc[m - 1]
	ow[n] = sw[m - 1]
	n += 1
	dst.pos = op
	dst.col = oc
	dst.w = ow
	dst.n = n

## lerp_color unrolled (the same READ rounding, no inner loop).
static func _lerp4(a: int, b: int, t: float) -> int:
	var s := 1.0 - t
	var out := 0
	var x := s * (a & 0xFF) + t * (b & 0xFF)
	var r := int(x + 0.5)
	if r & 1 and float(r) - x == 0.5:
		r -= 1
	out = r
	x = s * ((a >> 8) & 0xFF) + t * ((b >> 8) & 0xFF)
	r = int(x + 0.5)
	if r & 1 and float(r) - x == 0.5:
		r -= 1
	out |= r << 8
	x = s * ((a >> 16) & 0xFF) + t * ((b >> 16) & 0xFF)
	r = int(x + 0.5)
	if r & 1 and float(r) - x == 0.5:
		r -= 1
	out |= r << 16
	x = s * ((a >> 24) & 0xFF) + t * ((b >> 24) & 0xFF)
	r = int(x + 0.5)
	if r & 1 and float(r) - x == 0.5:
		r -= 1
	return out | (r << 24)

## A D3DCOLOR as a Godot colour (EfpReader.d3dcolor, inline).
static func _color(c: int) -> Color:
	return Color(((c >> 16) & 0xFF) / 255.0, ((c >> 8) & 0xFF) / 255.0, (c & 0xFF) / 255.0,
		((c >> 24) & 0xFF) / 255.0)

## The pipe ribbon through the points in `b`, appended to `out`. `vp` maps a
## point to clip space (the camera's projection * view * the effect's
## transform); an identity Projection gives the headless orthographic view.
## `right` and `up` are the camera's axes in the points' space.
static func pipe_ribbon(b: Buf, vp: Projection, right: Vector3, up: Vector3, out: Out) -> void:
	var n := b.n
	if n < 2:
		return
	out.begin_strip(2 * n)
	var bp := b.pos
	var bc := b.col
	var bw := b.w
	# Clip-space rows 0, 1 and 3 of vp: x, y and w of a point.
	var cxx := vp.x.x; var cxy := vp.y.x; var cxz := vp.z.x; var cxw := vp.w.x
	var cyx := vp.x.y; var cyy := vp.y.y; var cyz := vp.z.y; var cyw := vp.w.y
	var cwx := vp.x.w; var cwy := vp.y.w; var cwz := vp.z.w; var cww := vp.w.w
	var ndc := _ndc
	_ndc = PackedVector2Array()
	if ndc.size() < n:
		ndc.resize(maxi(n, ndc.size() * 2))
	for i in range(n):
		var p := bp[i]
		var hx := cxx * p.x + cxy * p.y + cxz * p.z + cxw
		var hy := cyx * p.x + cyy * p.y + cyz * p.z + cyw
		var hw := cwx * p.x + cwy * p.y + cwz * p.z + cww
		if absf(hw) > 1e-12:
			ndc[i] = Vector2(hx / hw, hy / hw)
		else:
			ndc[i] = Vector2(hx, hy)
	var verts := out.verts
	var cols := out.colors
	var uvs := out.uvs
	out.verts = PackedVector3Array()
	out.colors = PackedColorArray()
	out.uvs = PackedVector2Array()
	var v := out.nv
	var inv := 1.0 / float(n - 1)
	var last_c := -1
	var col := Color()
	var last := n - 1
	for i in range(n):
		var d: Vector2 = ndc[i - 1 if i > 0 else 0] - ndc[i + 1 if i < last else last]
		var side := right * d.y - up * d.x
		var l2 := side.length_squared()
		if l2 > 0.0:
			side *= bw[i] / sqrt(l2)
		var p := bp[i]
		var c: int = bc[i]
		if c != last_c:
			last_c = c
			col = Color(((c >> 16) & 0xFF) / 255.0, ((c >> 8) & 0xFF) / 255.0, (c & 0xFF) / 255.0,
				((c >> 24) & 0xFF) / 255.0)
		var u := 0.0 if i == 0 else (1.0 if i == last else float(i) * inv)
		verts[v] = p + side
		verts[v + 1] = p - side
		cols[v] = col
		cols[v + 1] = col
		uvs[v] = Vector2(u, 0.0)
		uvs[v + 1] = Vector2(u, 1.0)
		v += 2
	_ndc = ndc
	out.verts = verts
	out.colors = cols
	out.uvs = uvs
	out.nv = v
	out.end_strip()

## The projected points' scratch (reused, see pipe_ribbon).
static var _ndc := PackedVector2Array()

## pipe_ribbon for a shared-turn effect (round 741; EfpEffect.use_shared_turn):
## one effect simulated once, drawn by holders each turned by its own bone, so
## the camera -- and with it the side of the ribbon -- differs per holder.
## Instead of the two side vertices this writes the point itself twice, with
## the neighbours pipe_ribbon projects (i - 1 and i + 1, clamped at the ends,
## READ) and the width signed +w / -w in the custom channels; the shader
## (EfpEffect.PIPE_TURN_VERTEX) projects the neighbours with the camera that
## draws the holder and builds the same side, right * d.y - up * d.x, scaled
## to w. Colour and u as pipe_ribbon. `out.turn` must be set.
static func pipe_turn(b: Buf, out: Out) -> void:
	var n := b.n
	if n < 2:
		return
	out.begin_strip(2 * n)
	var bp := b.pos
	var bc := b.col
	var bw := b.w
	var v := out.nv
	var inv := 1.0 / float(n - 1)
	var last := n - 1
	var c0 := out.c0
	var c1 := out.c1
	out.c0 = PackedFloat32Array()
	out.c1 = PackedFloat32Array()
	var last_c := -1
	var col := Color()
	for i in range(n):
		var p := bp[i]
		var pa := bp[i - 1 if i > 0 else 0]
		var pb := bp[i + 1 if i < last else last]
		var c: int = bc[i]
		if c != last_c:
			last_c = c
			col = Color(((c >> 16) & 0xFF) / 255.0, ((c >> 8) & 0xFF) / 255.0, (c & 0xFF) / 255.0,
				((c >> 24) & 0xFF) / 255.0)
		var u := 0.0 if i == 0 else (1.0 if i == last else float(i) * inv)
		for k in 2:
			var at := v + k
			out.verts[at] = p
			out.colors[at] = col
			out.uvs[at] = Vector2(u, float(k))
			c0[4 * at] = pa.x
			c0[4 * at + 1] = pa.y
			c0[4 * at + 2] = pa.z
			c0[4 * at + 3] = bw[i] if k == 0 else -bw[i]
			c1[4 * at] = pb.x
			c1[4 * at + 1] = pb.y
			c1[4 * at + 2] = pb.z
			c1[4 * at + 3] = 0.0
		v += 2
	out.c0 = c0
	out.c1 = c1
	out.nv = v
	out.end_strip()

## LinkObj's strip from the taken particles in `b` (with their Y axes),
## appended to `out`.
static func obj_ribbon(b: Buf, out: Out) -> void:
	var k := b.n
	if k < 2:
		return
	var samples := 3 * (k - 2)
	out.begin_strip(2 * (samples + 1))
	var w := _w
	var ea := PackedVector3Array()
	var eb := PackedVector3Array()
	ea.resize(k)
	eb.resize(k)
	for i in range(k):
		var off := b.y[i] * b.w[i]
		ea[i] = b.pos[i] + off
		eb[i] = b.pos[i] - off
	var u := 1.0
	var du := 2.0 / float(samples * 2) if samples > 0 else 0.0
	for j in range(k - 2):
		# Pairs A(j)..A(j+3) of the padded list A0 = A1 (A(k+1) = Ak is never
		# reached: j + 3 <= k).
		var i0 := j - 1 if j > 0 else 0
		var a0 := ea[i0]; var a1 := ea[j]; var a2 := ea[j + 1]; var a3 := ea[j + 2]
		var e0 := eb[i0]; var e1 := eb[j]; var e2 := eb[j + 1]; var e3 := eb[j + 2]
		var ca: int = b.col[j]
		var cb: int = b.col[j + 1]
		var t := 0.0
		for s in range(SAMPLES):
			var o := s * 4
			var c := ca if (s == 0 or ca == cb) else _lerp4(ca, cb, t)
			out.pair(a0 * w[o] + a1 * w[o + 1] + a2 * w[o + 2] + a3 * w[o + 3],
				e0 * w[o] + e1 * w[o + 1] + e2 * w[o + 2] + e3 * w[o + 3], c, u)
			u -= du
			t += T_STEP
	# The closing pair is A(k-1), the particle before the newest.
	var c2 := k - 2
	out.pair(ea[c2], eb[c2], b.col[c2], u)
	out.end_strip()
