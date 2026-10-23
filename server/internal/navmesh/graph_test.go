package navmesh

import (
	"math"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

// flatRegion is a synthetic region: flat ground at height h, the tiles left
// of column `split` in cell 0 and the rest in cell 1, and `walls` as blocking
// internal edges (flag 3).
func flatRegion(h float32, split int, walls ...[4]float32) *Region {
	r := &Region{
		Cells: []Cell{
			{MinX: 0, MinZ: 0, MaxX: float32(split) * TileSize, MaxZ: RegionSpan},
			{MinX: float32(split) * TileSize, MinZ: 0, MaxX: RegionSpan, MaxZ: RegionSpan},
		},
		Tiles:        make([]Tile, TileCount),
		Heights:      make([]float32, HeightCount),
		PlaneTypes:   make([]byte, PlaneCount),
		PlaneHeights: make([]float32, PlaneCount),
	}
	for i := range r.Tiles {
		if i%TileMapSide >= split {
			r.Tiles[i].Cell = 1
		}
	}
	for i := range r.Heights {
		r.Heights[i] = h
	}
	for _, w := range walls {
		r.InternalEdges = append(r.InternalEdges, Edge{AX: w[0], AZ: w[1], BX: w[2], BZ: w[3], Flags: 3, CellFrom: 0, CellTo: 1, RegionFrom: -1, RegionTo: -1})
	}
	return r
}

func TestTerrainWallStopsTheNoSlideWalk(t *testing.T) {
	// A wall along x = 100 between cell 0 (x < 100) and cell 1.
	g := Build(flatRegion(5, 5, [4]float32{100, 0, 100, 1920}), nil)
	r := g.StepTracked(V3{50, 5, 500}, V2{100, 0}, OnTerrain, false)
	if !r.Blocked {
		t.Fatalf("the walk through a terrain wall was not blocked: %+v", r)
	}
	// READ (FUN_009c1050): the crossing moved at most 0.2 toward the centre
	// of the cell the mover is in, cell 0's (50, 960).
	toward := V2{50 - 100, 960 - 500}.Norm().Mul(TerrainBlockNudge)
	want := V2{100, 500}.Add(toward)
	if got := r.Pos.Plan(); got.Dist(want) > 1e-6 || r.Pos.Y != 5 {
		t.Errorf("stopped at %+v, want %+v at height 5", r.Pos, want)
	}
	// A walk that stays on its side is not.
	if r := g.StepTracked(V3{50, 5, 500}, V2{-20, 30}, OnTerrain, false); r.Blocked || r.Pos.Plan().Dist(V2{30, 530}) > 1e-9 {
		t.Errorf("a clear walk: %+v", r)
	}
	// The slide walk follows the wall instead.
	if r := g.StepTracked(V3{50, 5, 500}, V2{100, 100}, OnTerrain, true); !r.Blocked || r.Pos.Z <= 500 || r.Pos.X >= 100 {
		t.Errorf("the slide walk along the wall: %+v", r)
	}
}

// A 20 x 20 box object at (500, 500): three walls (0x03) and a doorway (0)
// on its south side (z = 490), two cells.
func boxObject() *CollisionMesh {
	return &CollisionMesh{
		Vertices: []CVertex{{-10, 3, -10}, {10, 3, -10}, {10, 3, 10}, {-10, 3, 10}},
		Cells:    []CCell{{0, 1, 2}, {0, 2, 3}},
		Outline: []CEdge{
			{V0: 0, V1: 1, CellFrom: 0, CellTo: NoCell, Flags: 0}, // z = -10: the doorway
			{V0: 1, V1: 2, CellFrom: 0, CellTo: NoCell, Flags: 3},
			{V0: 2, V1: 3, CellFrom: 1, CellTo: NoCell, Flags: 3},
			{V0: 3, V1: 0, CellFrom: 1, CellTo: NoCell, Flags: 3},
		},
		Internal: []CEdge{{V0: 0, V1: 2, CellFrom: 0, CellTo: 1, Flags: 4}},
	}
}

func boxGraph() *Graph {
	r := flatRegion(0, 48)
	// The object listed by the cell under it, as a real .nvm lists it.
	r.Objects = []MapObject{{ResourceID: 7, X: 500, Z: 500}}
	r.Cells[0].Objects = []uint16{0}
	return Build(r, []*Placed{Place(boxObject(), 0, V3{500, 0, 500}, 0)})
}

func TestObjectWallsAndDoorway(t *testing.T) {
	g := boxGraph()
	// From the west, into a wall (0x03): blocked, on the terrain.
	r := g.StepTracked(V3{480, 0, 500}, V2{20, 0}, OnTerrain, false)
	if !r.Blocked || r.On != OnTerrain || r.Pos.X >= 490 {
		t.Fatalf("into the west wall: %+v", r)
	}
	// From the south through the doorway (flag 0): onto the box, at its 3.
	r = g.StepTracked(V3{500, 0, 480}, V2{0, 15}, OnTerrain, false)
	if r.Blocked || r.On != 0 || r.Entered != 0 || math.Abs(r.Pos.Y-3) > 1e-9 {
		t.Fatalf("through the doorway: %+v", r)
	}
	// On it, walking north into its own wall: blocked inside (0x02).
	r = g.StepTracked(r.Pos, V2{0, 20}, r.On, false)
	if !r.Blocked || r.On != 0 || r.Pos.Z >= 510 {
		t.Fatalf("into the north wall from inside: %+v", r)
	}
	// And back out of the doorway: off the box.
	r = g.StepTracked(V3{500, 3, 500}, V2{0, -20}, 0, false)
	if r.Blocked || r.On != OnTerrain || r.Exited != 0 || r.Pos.Y != 0 {
		t.Fatalf("out of the doorway: %+v", r)
	}
	// The yaw turns the mesh the game's way: local +X to (cos, 0, sin).
	p := Place(boxObject(), 0, V3{0, 0, 0}, math.Pi/2)
	if v := p.Vertices[1]; math.Abs(v.X-10) > 1e-9 || math.Abs(v.Z-10) > 1e-9 {
		t.Errorf("(10, -10) turned a quarter: %+v, want (10, 10)", v)
	}
}

func TestWorldWalkAcrossRegionsAndTheMirror(t *testing.T) {
	ox, oy := 97, 168
	// Two regions side by side in world X (region y drives world X): 97/168
	// and 97/169. A wall in 97/169 at local x = 300.
	a := worldmap.RegionID(97, 168)
	b := worldmap.RegionID(97, 169)
	w := NewWorld(nil, map[int]*Region{a: flatRegion(1, 48), b: flatRegion(2, 15, [4]float32{300, 0, 300, 1920})})
	// From local (1800, 960) of 97/168 east 600: into 97/169 and its wall.
	x0, z0 := worldmap.ToWorld(97, 168, 1800, 960, ox, oy)
	r := w.Walk(ox, oy, x0, math.NaN(), z0, x0+600, z0)
	if !r.Blocked || !r.Checked {
		t.Fatalf("the walk into 97/169's wall: %+v", r)
	}
	rx, ry, lx, lz := worldmap.FromWorld(r.X, r.Z, ox, oy)
	if rx != 97 || ry != 169 || math.Abs(lx-300) > 0.25 || math.Abs(lz-960) > 0.25 || r.Y != 2 {
		t.Errorf("stopped in %d/%d at local (%.2f, %.2f) height %.1f, want 97/169 at (300, 960) height 2", rx, ry, lx, lz, r.Y)
	}
	// The mirror: a world step +Z is a local step -Z.
	x1, z1 := worldmap.ToWorld(97, 168, 500, 500, ox, oy)
	r = w.Walk(ox, oy, x1, 1, z1, x1, z1+100)
	_, _, _, lz1 := worldmap.FromWorld(r.X, r.Z, ox, oy)
	if math.Abs(lz1-400) > 1e-6 || r.Blocked {
		t.Errorf("world +100 Z is local %.2f, want 400", lz1)
	}
	// Where no region has a mesh the walk is not checked.
	if r := w.Walk(ox, oy, 0, 0, 1e6, 10, 1e6); r.Checked || r.Blocked {
		t.Errorf("a walk with no mesh: %+v", r)
	}
}

func TestParseNVMRoundTripsAndRejectsTruncation(t *testing.T) {
	if _, err := ParseNVM([]byte("JMXVNVM 1000\x00")); err == nil {
		t.Error("a truncated .nvm parsed")
	}
	if _, err := ParseNVM([]byte("not a navmesh at all")); err == nil {
		t.Error("a bad magic parsed")
	}
	if c, err := ParseCollision([]byte("JMXVBMS 0110")); c != nil || err != nil {
		t.Errorf("a .bms with no section: %v %v", c, err)
	}
}
