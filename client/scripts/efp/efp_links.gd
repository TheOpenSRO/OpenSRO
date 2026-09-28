extends RefCounted
class_name EfpLinks

## The three "Link" render modes of a .efp node (round 621): RenderLinkDPipe,
## RenderLinkPipe and RenderLinkObj. Each draws ONE triangle strip through a
## chain of particles. Pure geometry -- no nodes -- so the headless tests
## drive it with synthetic chains. EfpEffect feeds it and draws the result.
## docs/protocol/EFP_FORMAT.md "Link render modes" has the addresses.
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
## == Points (READ, all three routines) ==
## A point is (position +0x1b0, colour +0x228, width = scale.x +0x1c8). A
## particle is taken only if it is the first, or if its position differs
## from the last TAKEN one by more than 1e-6 (the float at 0x00e1b848) on
## some axis; a particle within that of the last taken one replaces it.
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
## (FUN_00410cd0): a world direction across the screen-space line, INFERRED
## from that matrix being the camera-facing billboard (round 620). The two
## vertices are P + n*w (v = 0) and P - n*w (v = 1), both with the point's
## colour; u is 0 at the first point, i/(N-1) between, 1 at the last. The
## strip is drawn as D3DPT_TRIANGLESTRIP (5, pushed at 0x00c8d0c1) and
## flushed at once (FUN_00cafa70), so strips never join.
##
## == LinkObj (READ, EFEffect::FUN_00c8c3a0) ==
## Each taken particle gives two edge points, pos + s*Y and pos - s*Y, where
## Y is the second row of its rotation (+0xc0, +0xc4, +0xc8) and s its
## scale.x; the dedupe is on the position. The pairs are A1..Ak, with
## A0 = A1 and A(k+1) = Ak (the copies at 0x00c8c6e5..0x00c8c735). Segments
## j = 0..k-3 -- k-2 of them, so the last pair is only a control point --
## are sampled at t = 0, 1/3, 2/3 (the loop runs while t < 1.0) with the same
## B-spline, each edge on its own; the colour is A(j+1)'s to A(j+2)'s, lerped
## by byte. A(k-1) closes the strip. u runs from 1.0 at the first pair down by
## 2.0 (the double at 0x00e1b898) over the sample-vertex count, so it is 0 at
## the closing pair; v is 0 on the + edge and 1 on the - edge. Needs k >= 3
## to make a triangle (k = 2 gives a 2-vertex strip).
##
## == Drawing (OURS) ==
## A strip becomes a triangle list, winding alternated as a strip's is. Both
## faces are drawn: the game's handedness is mirrored on the way into Godot,
## and which face of a generated ribbon D3D would cull was not checked.

const EPS := 1e-6 ## READ: the float at 0x00e1b848
const T_STEP := 0.3333333432674408 ## READ: the double at 0x00e0ec60
const SAMPLES := 3 ## READ: the pipe's literal loop count

## A point of a chain: position, D3DCOLOR and width.
class Pt:
	var pos: Vector3
	var color: int
	var width: float
	func _init(p: Vector3 = Vector3.ZERO, c: int = 0xFFFFFFFF, w: float = 1.0) -> void:
		pos = p
		color = c
		width = w

## A strip ready to draw: two vertices per step, in strip order.
class Strip:
	var verts := PackedVector3Array()
	var colors := PackedInt64Array()
	var uvs := PackedVector2Array()
	func size() -> int:
		return verts.size()

## The dedupe every Link routine applies: a point is taken when it is the
## first or differs from the last taken one by more than EPS on an axis;
## otherwise it replaces the last taken one (READ).
static func take(pts: Array) -> Array:
	var out: Array = []
	for p in pts:
		if out.is_empty():
			out.append(p)
			continue
		var last: Pt = out[out.size() - 1]
		var d: Vector3 = (p as Pt).pos - last.pos
		if absf(d.x) > EPS or absf(d.y) > EPS or absf(d.z) > EPS:
			out.append(p)
		else:
			out[out.size() - 1] = p
	return out

## The uniform cubic B-spline weights at t (READ constants, see the header).
static func bspline(t: float) -> Array:
	var t2 := t * t
	var t3 := t2 * t
	var u := 1.0 - t
	return [u * u * u / 6.0, (3.0 * t3 - 6.0 * t2 + 4.0) / 6.0,
		(-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) / 6.0, t3 / 6.0]

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
	var out := 0
	for sh in [0, 8, 16, 24]:
		var ca: int = (a >> sh) & 0xFF
		var cb: int = (b >> sh) & 0xFF
		out |= (clampi(fround((1.0 - t) * ca + t * cb), 0, 255) & 0xFF) << sh
	return out

## LinkDPipe's points: the taken points, as they are.
static func dpipe_points(pts: Array) -> Array:
	return take(pts)

## LinkPipe's points: the B-spline through the taken points (see the header).
static func pipe_points(pts: Array) -> Array:
	var p := take(pts)
	var m := p.size()
	if m < 2:
		return []
	var c: Array = [p[0]]
	c.append_array(p)
	c.append(p[m - 1])
	var out: Array = []
	for i in range(m - 1):
		var a: Pt = c[i + 1]
		var b: Pt = c[i + 2]
		var dw := (b.width - a.width) / 3.0
		var t := 0.0
		for k in range(SAMPLES):
			var w := bspline(t)
			var pos: Vector3 = (c[i] as Pt).pos * w[0] + a.pos * w[1] + b.pos * w[2] + (c[i + 3] as Pt).pos * w[3]
			out.append(Pt.new(pos, lerp_color(a.color, b.color, t), a.width + dw * k))
			t += T_STEP
	out.append(p[m - 1])
	return out

## The pipe ribbon through N points (see the header). `ndc` holds each point
## projected to normalised device coordinates; `right` and `up` are the
## camera's axes in the points' space. Empty below 2 points.
static func pipe_ribbon(pts: Array, ndc: PackedVector2Array, right: Vector3, up: Vector3) -> Strip:
	var s := Strip.new()
	var n := pts.size()
	if n < 2 or ndc.size() < n:
		return s
	for i in range(n):
		var d: Vector2
		if i == 0:
			d = ndc[0] - ndc[1]
		elif i == n - 1:
			d = ndc[n - 2] - ndc[n - 1]
		else:
			d = ndc[i - 1] - ndc[i + 1]
		var side := right * d.y + up * (-d.x)
		if side.length_squared() > 0.0:
			side = side.normalized()
		else:
			side = Vector3.ZERO # FUN_00410cd0 leaves a zero vector at zero
		var p: Pt = pts[i]
		var u := 0.0 if i == 0 else (1.0 if i == n - 1 else float(i) / float(n - 1))
		s.verts.append(p.pos + side * p.width)
		s.verts.append(p.pos - side * p.width)
		s.colors.append(p.color)
		s.colors.append(p.color)
		s.uvs.append(Vector2(u, 0.0))
		s.uvs.append(Vector2(u, 1.0))
	return s

## LinkObj's strip from a chain of (position, colour, scale.x, rotation Y
## axis) given as Pt plus a parallel array of Y axes.
static func obj_ribbon(pts: Array, yaxes: Array) -> Strip:
	var s := Strip.new()
	# Dedupe on the position, keeping each taken particle's own axis.
	var tp: Array = []
	var ty: Array = []
	for i in range(pts.size()):
		var p: Pt = pts[i]
		if not tp.is_empty():
			var d: Vector3 = p.pos - (tp[tp.size() - 1] as Pt).pos
			if not (absf(d.x) > EPS or absf(d.y) > EPS or absf(d.z) > EPS):
				tp[tp.size() - 1] = p
				ty[ty.size() - 1] = yaxes[i]
				continue
		tp.append(p)
		ty.append(yaxes[i])
	var k := tp.size()
	if k < 2:
		return s
	# Pairs A0..A(k+1): A0 = A1, A(k+1) = Ak.
	var ea: Array = [] # + edge
	var eb: Array = [] # - edge
	var col: Array = []
	for i in range(k):
		var p: Pt = tp[i]
		var off: Vector3 = (ty[i] as Vector3) * p.width
		ea.append(p.pos + off)
		eb.append(p.pos - off)
		col.append(p.color)
	ea.push_front(ea[0])
	eb.push_front(eb[0])
	col.push_front(col[0])
	ea.append(ea[ea.size() - 1])
	eb.append(eb[eb.size() - 1])
	col.append(col[col.size() - 1])
	var sa := PackedVector3Array()
	var sb := PackedVector3Array()
	var sc := PackedInt64Array()
	for j in range(k - 2):
		var t := 0.0
		while t < 1.0:
			var w := bspline(t)
			sa.append((ea[j] as Vector3) * w[0] + (ea[j + 1] as Vector3) * w[1] + (ea[j + 2] as Vector3) * w[2] + (ea[j + 3] as Vector3) * w[3])
			sb.append((eb[j] as Vector3) * w[0] + (eb[j + 1] as Vector3) * w[1] + (eb[j + 2] as Vector3) * w[2] + (eb[j + 3] as Vector3) * w[3])
			sc.append(lerp_color(int(col[j + 1]), int(col[j + 2]), t))
			t += T_STEP
	var sample_verts := sa.size() * 2
	sa.append(ea[k - 1])
	sb.append(eb[k - 1])
	sc.append(int(col[k - 1]))
	var u := 1.0
	var du := 2.0 / float(sample_verts) if sample_verts > 0 else 0.0
	for i in range(sa.size()):
		s.verts.append(sa[i])
		s.verts.append(sb[i])
		s.colors.append(sc[i])
		s.colors.append(sc[i])
		s.uvs.append(Vector2(u, 0.0))
		s.uvs.append(Vector2(u, 1.0))
		u -= du
	return s

## The triangles a strip of `n` vertices draws, as index triples in a list
## (strip winding: even triangles i, i+1, i+2; odd ones i+1, i, i+2).
static func strip_triangles(n: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in range(maxi(n - 2, 0)):
		if i % 2 == 0:
			out.append_array([i, i + 1, i + 2])
		else:
			out.append_array([i + 1, i, i + 2])
	return out
