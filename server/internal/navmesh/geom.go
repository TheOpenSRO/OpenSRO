package navmesh

import "math"

// V2 is a point or vector in a region's plan (x, z).
type V2 struct{ X, Y float64 }

// V3 is a point in a region's local space (x, height, z).
type V3 struct{ X, Y, Z float64 }

func (a V2) Add(b V2) V2        { return V2{a.X + b.X, a.Y + b.Y} }
func (a V2) Sub(b V2) V2        { return V2{a.X - b.X, a.Y - b.Y} }
func (a V2) Mul(k float64) V2   { return V2{a.X * k, a.Y * k} }
func (a V2) Dot(b V2) float64   { return a.X*b.X + a.Y*b.Y }
func (a V2) Cross(b V2) float64 { return a.X*b.Y - a.Y*b.X }
func (a V2) Len() float64       { return math.Hypot(a.X, a.Y) }
func (a V2) Len2() float64      { return a.X*a.X + a.Y*a.Y }
func (a V2) Dist(b V2) float64  { return a.Sub(b).Len() }
func (a V2) Dist2(b V2) float64 { return a.Sub(b).Len2() }
func (a V2) Norm() V2 {
	l := a.Len()
	if l == 0 {
		return V2{}
	}
	return a.Mul(1 / l)
}
func (a V3) Dist(b V3) float64 {
	return math.Sqrt((a.X-b.X)*(a.X-b.X) + (a.Y-b.Y)*(a.Y-b.Y) + (a.Z-b.Z)*(a.Z-b.Z))
}
func (a V3) Plan() V2 { return V2{a.X, a.Z} }

const cmpEpsilon = 0.00001

func isEqualApprox(a, b float64) bool {
	if a == b {
		return true
	}
	tol := cmpEpsilon * math.Abs(a)
	if tol < cmpEpsilon {
		tol = cmpEpsilon
	}
	return math.Abs(a-b) < tol
}

// segmentIntersect is Godot's Geometry2D.segment_intersects_segment, which
// the client's walk calls: the crossing of from->to with a->b, or false.
func segmentIntersect(fromA, toA, fromB, toB V2) (V2, bool) {
	B := toA.Sub(fromA)
	C := fromB.Sub(fromA)
	D := toB.Sub(fromA)
	abLen := B.Dot(B)
	if abLen <= 0 {
		return V2{}, false
	}
	bn := B.Mul(1 / abLen)
	C = V2{C.X*bn.X + C.Y*bn.Y, C.Y*bn.X - C.X*bn.Y}
	D = V2{D.X*bn.X + D.Y*bn.Y, D.Y*bn.X - D.X*bn.Y}
	if (C.Y < -cmpEpsilon && D.Y < -cmpEpsilon) || (C.Y > cmpEpsilon && D.Y > cmpEpsilon) {
		return V2{}, false
	}
	if isEqualApprox(C.Y, D.Y) {
		return V2{}, false
	}
	abPos := D.X + (C.X-D.X)*D.Y/(D.Y-C.Y)
	if abPos < 0 || abPos > 1 {
		return V2{}, false
	}
	return fromA.Add(B.Mul(abPos)), true
}

// segmentHit is NavGraph._segment_hit: a bounding test, then the crossing.
func segmentHit(from, to, a, b V2) (V2, bool) {
	if math.Max(a.X, b.X) < math.Min(from.X, to.X) || math.Min(a.X, b.X) > math.Max(from.X, to.X) {
		return V2{}, false
	}
	if math.Max(a.Y, b.Y) < math.Min(from.Y, to.Y) || math.Min(a.Y, b.Y) > math.Max(from.Y, to.Y) {
		return V2{}, false
	}
	return segmentIntersect(from, to, a, b)
}

// closestOnSegment is Geometry2D.get_closest_point_to_segment.
func closestOnSegment(p, a, b V2) V2 {
	ab := b.Sub(a)
	l2 := ab.Len2()
	if l2 <= 0 {
		return a
	}
	t := p.Sub(a).Dot(ab) / l2
	if t <= 0 {
		return a
	}
	if t >= 1 {
		return b
	}
	return a.Add(ab.Mul(t))
}

// pointInTriangle is Geometry2D.point_is_inside_triangle.
func pointInTriangle(s, a, b, c V2) bool {
	an, bn, cn := a.Sub(s), b.Sub(s), c.Sub(s)
	orient := an.Cross(bn) > 0
	if (bn.Cross(cn) > 0) != orient {
		return false
	}
	return (cn.Cross(an) > 0) == orient
}

func closestInTriangle(a, b, c, p V2) V2 {
	if pointInTriangle(p, a, b, c) {
		return p
	}
	best := closestOnSegment(p, a, b)
	for _, q := range []V2{closestOnSegment(p, b, c), closestOnSegment(p, c, a)} {
		if q.Dist2(p) < best.Dist2(p) {
			best = q
		}
	}
	return best
}

// planeHeight is NavGraph._plane_height: the triangle's plane at (x, z),
// NaN for a triangle that is a line in plan.
func planeHeight(a, b, c V3, x, z float64) float64 {
	v0x, v0z := c.X-a.X, c.Z-a.Z
	v1x, v1z := b.X-a.X, b.Z-a.Z
	den := v0x*v1z - v1x*v0z
	if math.Abs(den) < 0.000001 {
		return math.NaN()
	}
	u := ((x-a.X)*v1z - v1x*(z-a.Z)) / den
	v := (v0x*(z-a.Z) - (x-a.X)*v0z) / den
	return a.Y + u*(c.Y-a.Y) + v*(b.Y-a.Y)
}

// triangleHeight is NavGraph._triangle_height: NaN outside the triangle in
// plan (a 0.0001 tolerance so a shared edge belongs to one).
func triangleHeight(a, b, c V3, x, z float64) float64 {
	v0x, v0z := c.X-a.X, c.Z-a.Z
	v1x, v1z := b.X-a.X, b.Z-a.Z
	v2x, v2z := x-a.X, z-a.Z
	den := v0x*v1z - v1x*v0z
	if math.Abs(den) < 0.000001 {
		return math.NaN()
	}
	u := (v2x*v1z - v1x*v2z) / den
	v := (v0x*v2z - v2x*v0z) / den
	const eps = 0.0001
	if u < -eps || v < -eps || u+v > 1+eps {
		return math.NaN()
	}
	return a.Y + u*(c.Y-a.Y) + v*(b.Y-a.Y)
}

// triangleMargin is NavGraph._triangle_margin.
func triangleMargin(a, b, c V3, x, z float64) float64 {
	v0x, v0z := c.X-a.X, c.Z-a.Z
	v1x, v1z := b.X-a.X, b.Z-a.Z
	den := v0x*v1z - v1x*v0z
	if math.Abs(den) < 0.000001 {
		return math.Inf(-1)
	}
	u := ((x-a.X)*v1z - v1x*(z-a.Z)) / den
	v := ((v0x)*(z-a.Z) - (x-a.X)*v0z) / den
	return math.Min(math.Min(u, v), 1-u-v)
}

func snapped(x, step float64) float64 { return math.Floor(x/step+0.5) * step }

func sign(x float64) float64 {
	switch {
	case x > 0:
		return 1
	case x < 0:
		return -1
	}
	return 0
}
