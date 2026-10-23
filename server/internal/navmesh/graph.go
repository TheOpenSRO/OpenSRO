package navmesh

import (
	"math"
	"sort"
)

// The walk's constants, as nav_graph.gd has them (its comments carry the
// READ addresses; OURS where it says so).
const (
	SurfaceReachUp        = 12.0 // OURS: a point query's reach above the reference height
	EdgeBlocksFromOutside = 0x01
	EdgeBlocksFromInside  = 0x02
	EdgeInternal          = 0x04
	EdgeLinked            = 0x08
	EdgeIgnoredFromOut    = 0x10
	ContactPush           = 0.01 // READ: the double at 0x00e1b820
	MaxSubsteps           = 8    // OURS
	OnTerrain             = -1
	cellEdgeSlotsKept     = 4 // READ: FUN_0045dcf0
	cellEdgeSlots         = 3 // READ: FUN_0044add0 reads slots 0..2
	maxCellSteps          = 512
	levelReach            = 1.0 // OURS
	TerrainBlockNudge     = 0.2 // READ: 0xb45de8 (server FUN_009c1050)
)

// Placed is one object's navigation mesh in region space
// (NavGraph.PlacedObject).
type Placed struct {
	Index          int
	Vertices       []V3
	Cells          []int32 // flat triples
	Edges          []V2    // flat pairs
	EdgeFlags      []int
	EdgeV0, EdgeV1 []int
	EdgeOutline    []bool
	EdgeInside     []V2
	EdgeCellFrom   []int
	EdgeCellTo     []int
	CellEdges      [][]int
	TerrainCollide bool
	Min, Max       V2
}

// Place is NavGraph.place: the mesh turned by the placement's yaw the game's
// way (a row-vector Y rotation, READ FUN_0043cda0: local +X to (cos, 0, sin))
// and moved to its position.
func Place(c *CollisionMesh, index int, pos V3, yaw float64) *Placed {
	p := &Placed{Index: index, Min: V2{math.Inf(1), math.Inf(1)}, Max: V2{math.Inf(-1), math.Inf(-1)}}
	cs, sn := math.Cos(yaw), math.Sin(yaw)
	p.Vertices = make([]V3, len(c.Vertices))
	for i, v := range c.Vertices {
		x, y, z := float64(v.X), float64(v.Y), float64(v.Z)
		w := V3{x*cs - z*sn + pos.X, y + pos.Y, x*sn + z*cs + pos.Z}
		p.Vertices[i] = w
		p.Min = V2{math.Min(p.Min.X, w.X), math.Min(p.Min.Y, w.Z)}
		p.Max = V2{math.Max(p.Max.X, w.X), math.Max(p.Max.Y, w.Z)}
	}
	p.Cells = make([]int32, 0, len(c.Cells)*3)
	for _, cell := range c.Cells {
		p.Cells = append(p.Cells, int32(cell.A), int32(cell.B), int32(cell.C))
	}
	nCells := len(c.Cells)
	p.CellEdges = make([][]int, nCells)
	nv := len(p.Vertices)
	for li, list := range [][]CEdge{c.Outline, c.Internal} {
		for _, e := range list {
			if int(e.V0) >= nv || int(e.V1) >= nv {
				continue
			}
			from := int(e.CellFrom)
			if from == NoCell || from >= nCells {
				from = int(e.CellTo)
			}
			if from == NoCell || from >= nCells {
				continue
			}
			a, b := p.Vertices[e.V0], p.Vertices[e.V1]
			ca, cb, cc := p.Vertices[p.Cells[from*3]], p.Vertices[p.Cells[from*3+1]], p.Vertices[p.Cells[from*3+2]]
			p.Edges = append(p.Edges, a.Plan(), b.Plan())
			p.EdgeFlags = append(p.EdgeFlags, int(e.Flags))
			p.EdgeV0 = append(p.EdgeV0, int(e.V0))
			p.EdgeV1 = append(p.EdgeV1, int(e.V1))
			p.EdgeOutline = append(p.EdgeOutline, li == 0)
			p.EdgeInside = append(p.EdgeInside, V2{(ca.X + cb.X + cc.X) / 3, (ca.Z + cb.Z + cc.Z) / 3})
			idx := len(p.EdgeFlags) - 1
			rawFrom, rawTo := -1, -1
			if int(e.CellFrom) != NoCell && int(e.CellFrom) < nCells {
				rawFrom = int(e.CellFrom)
			}
			if int(e.CellTo) != NoCell && int(e.CellTo) < nCells {
				rawTo = int(e.CellTo)
			}
			p.EdgeCellFrom = append(p.EdgeCellFrom, rawFrom)
			p.EdgeCellTo = append(p.EdgeCellTo, rawTo)
			p.slot(rawFrom, idx)
			if rawTo != rawFrom {
				p.slot(rawTo, idx)
			}
		}
	}
	for _, name := range c.Events {
		if name == "event" || name == "EVENT" {
			p.TerrainCollide = true
		}
	}
	return p
}

func (p *Placed) slot(cell, edge int) {
	if cell < 0 || len(p.CellEdges[cell]) >= cellEdgeSlotsKept {
		return
	}
	p.CellEdges[cell] = append(p.CellEdges[cell], edge)
}

func (p *Placed) tri(cell int) (V3, V3, V3) {
	return p.Vertices[p.Cells[cell*3]], p.Vertices[p.Cells[cell*3+1]], p.Vertices[p.Cells[cell*3+2]]
}

func (p *Placed) cellCount() int { return len(p.Cells) / 3 }

// Graph is one region's walkable surface (NavGraph, the field case).
type Graph struct {
	Region          *Region
	Objects         map[int]*Placed
	objectTiles     map[int][]int
	TerrainBlocking []V2
}

// Build is NavGraph.build.
func Build(r *Region, placed []*Placed) *Graph {
	g := &Graph{Region: r, Objects: map[int]*Placed{}, objectTiles: map[int][]int{}}
	for _, p := range placed {
		g.Objects[p.Index] = p
		if p.Min.X > p.Max.X {
			continue
		}
		c0 := clampi(int(math.Floor(p.Min.X/TileSize)), 0, TileMapSide-1)
		c1 := clampi(int(math.Floor(p.Max.X/TileSize)), 0, TileMapSide-1)
		r0 := clampi(int(math.Floor(p.Min.Y/TileSize)), 0, TileMapSide-1)
		r1 := clampi(int(math.Floor(p.Max.Y/TileSize)), 0, TileMapSide-1)
		for row := r0; row <= r1; row++ {
			for col := c0; col <= c1; col++ {
				k := row*TileMapSide + col
				g.objectTiles[k] = append(g.objectTiles[k], p.Index)
			}
		}
	}
	for _, list := range [][]Edge{r.InternalEdges, r.GlobalEdges} {
		for _, e := range list {
			if e.Blocking() {
				g.TerrainBlocking = append(g.TerrainBlocking, V2{float64(e.AX), float64(e.AZ)}, V2{float64(e.BX), float64(e.BZ)})
			}
		}
	}
	return g
}

func clampi(v, lo, hi int) int { return max(lo, min(hi, v)) }

// CellIndexAt is NavGraph.cell_index_at: the terrain cell over a point, -1
// outside the region.
func (g *Graph) CellIndexAt(x, z float64) int {
	if g.Region == nil || len(g.Region.Tiles) == 0 {
		return -1
	}
	col, row := int(math.Floor(x/TileSize)), int(math.Floor(z/TileSize))
	if col < 0 || row < 0 || col >= TileMapSide || row >= TileMapSide {
		return -1
	}
	return int(g.Region.Tiles[row*TileMapSide+col].Cell)
}

// ObjectsAt is NavGraph.objects_at: the cell's own object list, then the
// footprint index.
func (g *Graph) ObjectsAt(x, z float64) []int {
	var out []int
	seen := map[int]bool{}
	if ci := g.CellIndexAt(x, z); ci >= 0 && ci < len(g.Region.Cells) {
		for _, o := range g.Region.Cells[ci].Objects {
			oi := int(o)
			if _, ok := g.Objects[oi]; ok && !seen[oi] {
				seen[oi] = true
				out = append(out, oi)
			}
		}
	}
	col, row := int(math.Floor(x/TileSize)), int(math.Floor(z/TileSize))
	if col < 0 || row < 0 || col >= TileMapSide || row >= TileMapSide {
		return out
	}
	for _, oi := range g.objectTiles[row*TileMapSide+col] {
		if !seen[oi] {
			seen[oi] = true
			out = append(out, oi)
		}
	}
	return out
}

// Surface is what SurfaceAt found.
type Surface struct {
	Height float64
	Object int // OnTerrain or an object index
}

// SurfaceAt is NavGraph.surface_at: the highest surface no more than
// SurfaceReachUp above refY.
func (g *Graph) SurfaceAt(x, z, refY float64) Surface {
	best := Surface{Height: g.Region.TerrainHeight(x, z), Object: OnTerrain}
	found := false
	for _, oi := range g.ObjectsAt(x, z) {
		p := g.Objects[oi]
		if x < p.Min.X || x > p.Max.X || z < p.Min.Y || z > p.Max.Y {
			continue
		}
		for c := 0; c < p.cellCount(); c++ {
			a, b, cc := p.tri(c)
			h := triangleHeight(a, b, cc, x, z)
			if math.IsNaN(h) || h > refY+SurfaceReachUp {
				continue
			}
			if !found || h > best.Height {
				found = true
				best = Surface{h, oi}
			}
		}
	}
	if !found && best.Height > refY+SurfaceReachUp {
		best.Height = math.Min(best.Height, refY)
	}
	return best
}

// LandingHeightAt is NavGraph.landing_height_at (the field): the highest
// walkable surface over the point.
func (g *Graph) LandingHeightAt(x, z float64) float64 {
	best := g.Region.TerrainHeight(x, z)
	for _, oi := range g.ObjectsAt(x, z) {
		p := g.Objects[oi]
		if x < p.Min.X || x > p.Max.X || z < p.Min.Y || z > p.Max.Y {
			continue
		}
		for c := 0; c < p.cellCount(); c++ {
			a, b, cc := p.tri(c)
			if h := triangleHeight(a, b, cc, x, z); !math.IsNaN(h) && h > best {
				best = h
			}
		}
	}
	return best
}

// StepResult is what one StepTracked did.
type StepResult struct {
	Pos       V3
	On        int
	Entered   int
	Exited    int
	Blocked   bool
	Cancelled bool
}

type event struct {
	kind   byte // 'b' block, 'e' enter, 'x' exit
	point  V2
	a, b   V2
	object int
	edge   int
}

// StepTracked is NavGraph.step_tracked (the field): the move walked edge by
// edge from `from` by `motion` with the footing `on`; slide false stops at
// the first blocking edge (the no-slide walk every order uses, READ round
// 653: CRegionManagerBody::vslot_012 -> the terrain walk answers a block
// with the crossing point nudged at most 0.2 and bit 0).
func (g *Graph) StepTracked(from V3, motion V2, on int, slide bool) StepResult {
	res := StepResult{Entered: -1, Exited: -1}
	pos := from
	if on != OnTerrain {
		p, ok := g.Objects[on]
		if !ok || math.IsNaN(surfaceNear(p, pos.X, pos.Z, pos.Y)) {
			on = OnTerrain
		}
	}
	remaining := motion
	source := V2{pos.X, pos.Z}
	for sub := 0; sub < MaxSubsteps; sub++ {
		if remaining.Len2() <= 1e-10 {
			break
		}
		from2 := V2{pos.X, pos.Z}
		to2 := from2.Add(remaining)
		hit, ok := g.firstEvent(from2, to2, on, pos.Y)
		if !ok {
			pos.X, pos.Z = to2.X, to2.Y
			remaining = V2{}
			break
		}
		length := remaining.Len()
		dir := remaining.Mul(1 / length)
		contact := hit.point
		switch hit.kind {
		case 'e':
			p := g.Objects[hit.object]
			landed := contact.Add(dir.Mul(ContactPush))
			pos.X, pos.Z = landed.X, landed.Y
			edgeH := edgeHeightAt(p, hit.edge, contact)
			h := surfaceNear(p, pos.X, pos.Z, pos.Y)
			if math.IsNaN(h) || math.Abs(h-edgeH) > levelReach {
				h = edgeH
			}
			pos.Y = h
			on = hit.object
			res.Entered = hit.object
			source = landed
			remaining = onward(to2.Sub(landed), dir)
		case 'x':
			left := on
			landed := contact.Add(dir.Mul(ContactPush))
			pos.X, pos.Z = landed.X, landed.Y
			on = OnTerrain
			res.Exited = left
			reach := g.seamObjectAt(pos.X, pos.Z, pos.Y, left)
			if reach != OnTerrain {
				on = reach
				res.Entered = reach
				pos.Y = surfaceNear(g.Objects[reach], pos.X, pos.Z, pos.Y)
			} else {
				pos.Y = g.Region.TerrainHeight(pos.X, pos.Z)
			}
			source = landed
			remaining = onward(to2.Sub(landed), dir)
		case 'b':
			res.Blocked = true
			short := math.Max(from2.Dist(contact)-ContactPush, 0)
			stopped := from2.Add(dir.Mul(short))
			pos.X, pos.Z = stopped.X, stopped.Y
			if !slide {
				if hit.object == OnTerrain && on == OnTerrain {
					stop, cancelled := g.terrainBlockStop(source, contact, dir)
					pos.X, pos.Z = stop.X, stop.Y
					res.Cancelled = cancelled
				}
				remaining = V2{}
				sub = MaxSubsteps
				continue
			}
			along := hit.b.Sub(hit.a).Norm()
			rest := to2.Sub(stopped)
			remaining = along.Mul(rest.Dot(along))
			if remaining.Len() < 1e-4 {
				remaining = V2{}
			}
		}
	}
	if on != OnTerrain {
		if h := surfaceNear(g.Objects[on], pos.X, pos.Z, pos.Y); math.IsNaN(h) {
			on = OnTerrain
		} else {
			pos.Y = h
		}
	}
	if on == OnTerrain {
		pos.Y = g.Region.TerrainHeight(pos.X, pos.Z)
	}
	res.Pos = pos
	res.On = on
	return res
}

// terrainBlockStop is NavGraph._terrain_block_stop.
func (g *Graph) terrainBlockStop(source, contact, dir V2) (V2, bool) {
	k := g.CellIndexAt(contact.X-dir.X*0.001, contact.Y-dir.Y*0.001)
	if k < 0 || k >= len(g.Region.Cells) {
		return contact.Sub(dir.Mul(ContactPush)), false
	}
	cell := g.Region.Cells[k]
	centre := V2{float64(cell.MinX+cell.MaxX) * 0.5, float64(cell.MinZ+cell.MaxZ) * 0.5}
	toward := centre.Sub(contact)
	stop := contact
	if toward.Len() <= TerrainBlockNudge {
		stop = contact.Add(toward)
	} else {
		stop = contact.Add(toward.Norm().Mul(TerrainBlockNudge))
	}
	entry := g.terrainBlockSource(source, contact, dir)
	for _, o := range cell.Objects {
		if g.meetsOutline(int(o), entry, stop) {
			return entry, true
		}
	}
	return stop, false
}

// terrainBlockSource is NavGraph._terrain_block_source.
func (g *Graph) terrainBlockSource(source, contact, dir V2) V2 {
	k := g.CellIndexAt(contact.X-dir.X*0.001, contact.Y-dir.Y*0.001)
	if k < 0 || k >= len(g.Region.Cells) {
		return source
	}
	c := g.Region.Cells[k]
	lo := V2{float64(c.MinX), float64(c.MinZ)}
	hi := V2{float64(c.MaxX), float64(c.MaxZ)}
	if source.X >= lo.X && source.X <= hi.X && source.Y >= lo.Y && source.Y <= hi.Y {
		return source
	}
	d := contact.Sub(source)
	tIn := 0.0
	for axis := 0; axis < 2; axis++ {
		s0, dd, l, h := source.X, d.X, lo.X, hi.X
		if axis == 1 {
			s0, dd, l, h = source.Y, d.Y, lo.Y, hi.Y
		}
		if math.Abs(dd) < 1e-9 {
			continue
		}
		t1, t2 := (l-s0)/dd, (h-s0)/dd
		tIn = math.Max(tIn, math.Min(t1, t2))
	}
	return source.Add(d.Mul(clamp(tIn, 0, 1)))
}

func (g *Graph) meetsOutline(oi int, a, b V2) bool {
	p, ok := g.Objects[oi]
	if !ok {
		return false
	}
	for e := range p.EdgeFlags {
		if p.EdgeOutline[e] && p.EdgeFlags[e]&EdgeIgnoredFromOut == 0 {
			if _, hit := segmentHit(a, b, p.Edges[e*2], p.Edges[e*2+1]); hit {
				return true
			}
		}
	}
	return false
}

// Blocked is NavGraph.blocked: does the move from -> to run into a wall?
func (g *Graph) Blocked(from, to V2, on int, y float64) bool {
	hit, ok := g.firstEvent(from, to, on, y)
	return ok && hit.kind == 'b'
}

// firstEvent is NavGraph._first_event.
func (g *Graph) firstEvent(from, to V2, on int, fromY float64) (event, bool) {
	var best event
	found := false
	bestD := math.Inf(1)
	cur, onObject := g.Objects[on]
	onObject = onObject && on != OnTerrain
	if !onObject || cur.TerrainCollide {
		if t := firstCrossing(g.TerrainBlocking, from, to); t >= 0 {
			a, b := g.TerrainBlocking[t], g.TerrainBlocking[t+1]
			if hit, ok := segmentIntersect(from, to, a, b); ok {
				if d := from.Dist2(hit); d < bestD {
					bestD, found = d, true
					best = event{'b', hit, a, b, OnTerrain, t / 2}
				}
			}
		}
		for _, oi := range g.candidateObjects(from, to) {
			if oi == on {
				continue
			}
			p, ok := g.Objects[oi]
			if !ok {
				continue
			}
			if math.Max(from.X, to.X) < p.Min.X || math.Min(from.X, to.X) > p.Max.X {
				continue
			}
			if math.Max(from.Y, to.Y) < p.Min.Y || math.Min(from.Y, to.Y) > p.Max.Y {
				continue
			}
			for e := range p.EdgeFlags {
				flags := p.EdgeFlags[e]
				if !p.EdgeOutline[e] || flags&EdgeIgnoredFromOut != 0 {
					continue
				}
				a, b := p.Edges[e*2], p.Edges[e*2+1]
				hit, ok := segmentHit(from, to, a, b)
				if !ok {
					continue
				}
				d := from.Dist2(hit)
				if d >= bestD {
					continue
				}
				if onFromSide(a, b, from, p.EdgeInside[e]) {
					// OURS (nav_graph.gd): a terrain mover already inside an
					// outline is let out.
					continue
				}
				bestD, found = d, true
				if flags&EdgeBlocksFromOutside != 0 {
					best = event{'b', hit, a, b, oi, e}
				} else {
					best = event{'e', hit, a, b, oi, e}
				}
			}
		}
	}
	if onObject {
		if hit, ok := g.objectWalk(on, from, to, fromY); ok {
			if d := from.Dist2(hit.point); d < bestD {
				best, found = hit, true
			}
		}
	}
	return best, found
}

// objectWalk is NavGraph._object_walk (READ CRTNavMeshObj::FUN_0044add0).
func (g *Graph) objectWalk(oi int, from, to V2, fromY float64) (event, bool) {
	p := g.Objects[oi]
	if to.Sub(from).Len2() <= 0 {
		return event{}, false
	}
	starts := startCells(p, from, fromY)
	if len(starts) == 0 {
		return event{}, false
	}
	for _, cell := range starts {
		hit, ok, end := g.walkCells(p, oi, cell, from, to)
		if ok {
			return hit, true
		}
		if inCell(p, end, to) {
			return event{}, false
		}
	}
	return stopInCell(p, oi, starts[0], from, to), true
}

func startCells(p *Placed, from V2, fromY float64) []int {
	under := cellsUnder(p, from.X, from.Y, fromY)
	if len(under) > 0 {
		bestY := cellHeightAt(p, under[0], from)
		if math.IsNaN(fromY) || math.Abs(bestY-fromY) <= SurfaceReachUp {
			var level []int
			for _, c := range under {
				if math.Abs(cellHeightAt(p, c, from)-bestY) <= levelReach {
					level = append(level, c)
				}
			}
			return level
		}
	}
	return nearestCells(p, from, fromY)
}

func nearestCells(p *Placed, pt V2, refY float64) []int {
	type f struct {
		d       float64
		atLevel bool
		c       int
	}
	var found []f
	anyLevel := false
	for c := 0; c < p.cellCount(); c++ {
		a, b, d := p.tri(c)
		q := closestInTriangle(a.Plan(), b.Plan(), d.Plan(), pt)
		h := planeHeight(a, b, d, q.X, q.Y)
		at := math.IsNaN(refY) || math.Abs(h-refY) <= SurfaceReachUp
		anyLevel = anyLevel || at
		found = append(found, f{snapped(q.Dist(pt), 0.001), at, c})
	}
	sort.Slice(found, func(i, j int) bool {
		if found[i].d != found[j].d {
			return found[i].d < found[j].d
		}
		return found[i].c < found[j].c
	})
	var out []int
	for _, x := range found {
		if anyLevel && !x.atLevel {
			continue
		}
		out = append(out, x.c)
		if len(out) >= cellEdgeSlots {
			break
		}
	}
	return out
}

func cellHeightAt(p *Placed, cell int, pt V2) float64 {
	a, b, c := p.tri(cell)
	return planeHeight(a, b, c, pt.X, pt.Y)
}

func cellCentroid(p *Placed, cell int) V2 {
	a, b, c := p.tri(cell)
	return V2{(a.X + b.X + c.X) / 3, (a.Z + b.Z + c.Z) / 3}
}

// walkCells is NavGraph._walk_cells: (event, found, the cell it ended in).
func (g *Graph) walkCells(p *Placed, oi, cell int, from, to V2) (event, bool, int) {
	d := to.Sub(from)
	len2 := d.Len2()
	cameBy := -1
	tAt := 0.0
	for step := 0; step < maxCellSteps; step++ {
		centre := cellCentroid(p, cell)
		slots := p.CellEdges[cell]
		bestE, bestT := -1, math.Inf(1)
		var bestP V2
		for k := 0; k < min(cellEdgeSlots, len(slots)); k++ {
			e := slots[k]
			if e == cameBy {
				continue
			}
			a, b := p.Edges[e*2], p.Edges[e*2+1]
			along := b.Sub(a)
			if sign(along.Cross(d)) == sign(along.Cross(centre.Sub(a))) {
				continue
			}
			hit, ok := segmentHit(from, to, a, b)
			if !ok {
				continue
			}
			t := hit.Sub(from).Dot(d) / len2
			if t < tAt-1e-6 || t >= bestT {
				continue
			}
			bestE, bestT, bestP = e, t, hit
		}
		if bestE < 0 {
			return event{}, false, cell
		}
		flags := p.EdgeFlags[bestE]
		a2, b2 := p.Edges[bestE*2], p.Edges[bestE*2+1]
		if p.EdgeOutline[bestE] {
			kind := byte('x')
			if flags&(EdgeBlocksFromInside|EdgeIgnoredFromOut) != 0 {
				kind = 'b'
			}
			return event{kind, bestP, a2, b2, oi, bestE}, true, cell
		}
		cf, ct := p.EdgeCellFrom[bestE], p.EdgeCellTo[bestE]
		if (flags&EdgeBlocksFromInside != 0 && cf == cell) || (flags&EdgeBlocksFromOutside != 0 && ct == cell) {
			return event{'b', bestP, a2, b2, oi, bestE}, true, cell
		}
		next := cf
		if cf == cell {
			next = ct
		}
		if next < 0 || next >= len(p.CellEdges) {
			return event{}, false, cell
		}
		cell, cameBy, tAt = next, bestE, bestT
	}
	return event{}, false, cell
}

func stopInCell(p *Placed, oi, cell int, from, to V2) event {
	slots := p.CellEdges[cell]
	bestE, bestD := -1, math.Inf(1)
	for k := 0; k < min(cellEdgeSlots, len(slots)); k++ {
		e := slots[k]
		q := closestOnSegment(to, p.Edges[e*2], p.Edges[e*2+1])
		if d := q.Dist2(to); d < bestD {
			bestD, bestE = d, e
		}
	}
	if bestE < 0 {
		return event{'b', from, from, from.Add(V2{1, 0}), oi, -1}
	}
	return event{'b', from, p.Edges[bestE*2], p.Edges[bestE*2+1], oi, bestE}
}

func cellsUnder(p *Placed, x, z, refY float64) []int {
	type f struct {
		gap, margin float64
		c           int
	}
	var found []f
	for c := 0; c < p.cellCount(); c++ {
		a, b, cc := p.tri(c)
		h := triangleHeight(a, b, cc, x, z)
		if math.IsNaN(h) {
			continue
		}
		gap := -h
		if !math.IsNaN(refY) {
			gap = math.Abs(h - refY)
		}
		found = append(found, f{snapped(gap, 0.01), -triangleMargin(a, b, cc, x, z), c})
	}
	sort.Slice(found, func(i, j int) bool {
		if found[i].gap != found[j].gap {
			return found[i].gap < found[j].gap
		}
		if found[i].margin != found[j].margin {
			return found[i].margin < found[j].margin
		}
		return found[i].c < found[j].c
	})
	out := make([]int, len(found))
	for i, x := range found {
		out[i] = x.c
	}
	return out
}

func inCell(p *Placed, cell int, pt V2) bool {
	if cell < 0 || cell*3+2 >= len(p.Cells) {
		return false
	}
	a, b, c := p.tri(cell)
	return !math.IsNaN(triangleHeight(a, b, c, pt.X, pt.Y))
}

func onward(rest, dir V2) V2 {
	if rest.Dot(dir) > 0 {
		return rest
	}
	return V2{}
}

func (g *Graph) seamObjectAt(x, z, y float64, except int) int {
	best, bestGap := OnTerrain, math.Inf(1)
	for _, oi := range g.ObjectsAt(x, z) {
		if oi == except {
			continue
		}
		h := surfaceNear(g.Objects[oi], x, z, y)
		if math.IsNaN(h) {
			continue
		}
		if gap := math.Abs(h - y); gap <= SurfaceReachUp && gap < bestGap {
			best, bestGap = oi, gap
		}
	}
	return best
}

// SurfaceHeightOf is NavGraph.surface_height_of: the highest point of the
// object's own surface at (x, z), NaN where it has none.
func SurfaceHeightOf(p *Placed, x, z float64) float64 {
	best := math.NaN()
	for c := 0; c < p.cellCount(); c++ {
		a, b, cc := p.tri(c)
		if h := triangleHeight(a, b, cc, x, z); !math.IsNaN(h) && (math.IsNaN(best) || h > best) {
			best = h
		}
	}
	return best
}

// surfaceNear is NavGraph._surface_near.
func surfaceNear(p *Placed, x, z, refY float64) float64 {
	best := math.NaN()
	for c := 0; c < p.cellCount(); c++ {
		a, b, cc := p.tri(c)
		h := triangleHeight(a, b, cc, x, z)
		if math.IsNaN(h) {
			continue
		}
		if math.IsNaN(best) || math.Abs(h-refY) < math.Abs(best-refY) {
			best = h
		}
	}
	return best
}

func edgeHeightAt(p *Placed, edge int, at V2) float64 {
	a, b := p.Vertices[p.EdgeV0[edge]], p.Vertices[p.EdgeV1[edge]]
	a2, b2 := a.Plan(), b.Plan()
	span := a2.Dist(b2)
	if span < 1e-6 {
		return a.Y
	}
	s := clamp(a2.Dist(at)/span, 0, 1)
	return a.Y + s*(b.Y-a.Y)
}

func (g *Graph) candidateObjects(from, to V2) []int {
	seen := map[int]bool{}
	var out []int
	steps := max(1, int(math.Ceil(from.Dist(to)/TileSize))+1)
	for s := 0; s <= steps; s++ {
		t := float64(s) / float64(steps)
		p := from.Add(to.Sub(from).Mul(t))
		for _, oi := range g.ObjectsAt(p.X, p.Y) {
			if !seen[oi] {
				seen[oi] = true
				out = append(out, oi)
			}
		}
	}
	return out
}

func onFromSide(a, b, p, inside V2) bool {
	dir := b.Sub(a)
	sp := dir.Cross(p.Sub(a))
	si := dir.Cross(inside.Sub(a))
	if sp == 0 {
		return true
	}
	return (sp > 0) == (si > 0)
}

// firstCrossing is NavGraph._first_crossing: the index into the flat pairs
// of the segment crossed first, or -1.
func firstCrossing(segs []V2, from, to V2) int {
	best, bestD := -1, math.Inf(1)
	for i := 0; i+1 < len(segs); i += 2 {
		if hit, ok := segmentHit(from, to, segs[i], segs[i+1]); ok {
			if d := from.Dist2(hit); d < bestD {
				best, bestD = i, d
			}
		}
	}
	return best
}
