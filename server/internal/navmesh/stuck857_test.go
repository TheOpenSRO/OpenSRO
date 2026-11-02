package navmesh

import (
	"math"
	"os"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

// Round 857: the ways a mover got inside an object and could not get out.
//
// The shape is Tarim's oas_tarim_rock_l_03 (MEASURED, cmd/navstuck on the
// user's export, region 90/143): the rock's navigation mesh is its footprint,
// flat cells 9 units UNDER the terrain round it, every outline edge 0x03
// (blocks entering and leaving). A mover walking into it stops ContactPush
// (0.01) short of the outline, on the terrain; that point is within the
// footprint cells' own 0.0001 barycentric tolerance of a long cell
// (altitude over 100), and the old settle at the next leg's start
// (SurfaceAt: any object cell under the point won over the terrain, however
// far below) put the mover on the rock: every way out blocked (0x02), every
// way in open.

// buriedRock is a 240 x 240 footprint at (960, 960), its cells at -9 under
// terrain at 0, every outline edge 0x03.
func buriedRock() *CollisionMesh {
	return &CollisionMesh{
		Vertices: []CVertex{{-120, 0, -120}, {120, 0, -120}, {120, 0, 120}, {-120, 0, 120}},
		Cells:    []CCell{{0, 1, 2}, {0, 2, 3}},
		Outline: []CEdge{
			{V0: 0, V1: 1, CellFrom: 0, CellTo: NoCell, Flags: 3},
			{V0: 1, V1: 2, CellFrom: 0, CellTo: NoCell, Flags: 3},
			{V0: 2, V1: 3, CellFrom: 1, CellTo: NoCell, Flags: 3},
			{V0: 3, V1: 0, CellFrom: 1, CellTo: NoCell, Flags: 3},
		},
		Internal: []CEdge{{V0: 0, V1: 2, CellFrom: 0, CellTo: 1, Flags: 4}},
	}
}

func buriedRockWorld() (*World, int, int) {
	r := flatRegion(0, 48)
	r.Objects = []MapObject{{ResourceID: 9, X: 960, Y: -9, Z: 960}}
	r.Cells[0].Objects = []uint16{0}
	r.Cells[1].Objects = []uint16{0}
	ox, oy := 97, 168
	w := &World{graphs: map[int]*Graph{}}
	w.graphs[worldmap.RegionID(ox, oy)] = Build(r, []*Placed{Place(buriedRock(), 0, V3{960, -9, 960}, math.Pi/4)})
	return w, ox, oy
}

// TestRound857TheSettleIsTheNearestSurface: READ c:0x403dd0
// (CRTNavMeshTerrain::vslot_003, the point resolve CRegionManagerBody slot 11
// runs): the terrain first, an object's cell only when strictly nearer the
// mover's height.
func TestRound857TheSettleIsTheNearestSurface(t *testing.T) {
	w, ox, oy := buriedRockWorld()
	g := w.Graph(worldmap.RegionID(ox, oy))
	// Over the footprint at the terrain's height: the terrain.
	if s := g.SurfaceAt(960, 960, 0); s.Object != OnTerrain || s.Height != 0 {
		t.Errorf("at the terrain's height over the buried footprint: %+v, want the terrain", s)
	}
	// At the footprint's own height: the footprint.
	if s := g.SurfaceAt(960, 960, -9); s.Object != 0 || s.Height != -9 {
		t.Errorf("at the footprint's height: %+v, want the object at -9", s)
	}
	// A tie keeps the terrain (the object must be strictly nearer).
	if s := g.SurfaceAt(960, 960, -4.5); s.Object != OnTerrain {
		t.Errorf("half way: %+v, want the terrain", s)
	}
	// A deck over the terrain, walked at the deck's height: the deck.
	deck := flatRegion(0, 48)
	deck.Objects = []MapObject{{ResourceID: 9, X: 960, Y: 20, Z: 960}}
	deck.Cells[0].Objects = []uint16{0}
	deck.Cells[1].Objects = []uint16{0}
	dg := Build(deck, []*Placed{Place(boxObject(), 0, V3{960, 17, 960}, 0)})
	if s := dg.SurfaceAt(960, 960, 20); s.Object != 0 || s.Height != 20 {
		t.Errorf("on a deck: %+v, want the deck at 20", s)
	}
	if s := dg.SurfaceAt(960, 960, 0); s.Object != OnTerrain {
		t.Errorf("under a deck: %+v, want the terrain", s)
	}
}

// TestRound857AWallStopNeverPutsTheMoverInside walks into the buried rock
// from every side, each leg a separate World.Walk as the server walks a
// player's or a COS's legs, and then away and along: the mover stays on the
// terrain outside and every way back out is open. NEGATIVE: against the old
// settle the second leg started on the rock and the walk away was blocked at
// zero length.
func TestRound857AWallStopNeverPutsTheMoverInside(t *testing.T) {
	w, ox, oy := buriedRockWorld()
	g := w.Graph(worldmap.RegionID(ox, oy))
	for _, c := range []struct{ fx, fz, dx, dz float64 }{
		{960, 1200, 0, -1}, // from the north (local +z), heading south
		{960, 720, 0, 1},
		{700, 950, 1, 0},
		{1220, 970, -1, 0},
		{700, 700, 1, 1},
	} {
		x0, z0 := worldmap.ToWorld(ox, oy, c.fx, c.fz, ox, oy)
		// A world step is a local step with z mirrored.
		r := w.Walk(ox, oy, x0, math.NaN(), z0, x0+c.dx*200, z0-c.dz*200)
		if !r.Blocked {
			t.Fatalf("from (%.0f, %.0f): the walk into the rock was not blocked: %+v", c.fx, c.fz, r)
		}
		_, _, lx, lz := worldmap.FromWorld(r.X, r.Z, ox, oy)
		if s := g.SurfaceAt(lx, lz, r.Y); s.Object != OnTerrain {
			t.Errorf("from (%.0f, %.0f): the stop at (%.3f, %.3f, %.3f) settles on object %d", c.fx, c.fz, lx, lz, r.Y, s.Object)
		}
		// The next leg: straight back out.
		back := w.Walk(ox, oy, r.X, r.Y, r.Z, r.X-c.dx*30, r.Z+c.dz*30)
		if back.Blocked || math.Hypot(back.X-r.X, back.Z-r.Z) < 29.9 {
			t.Errorf("from (%.0f, %.0f): the walk back out of the stop: %+v (moved %.2f)", c.fx, c.fz, back, math.Hypot(back.X-r.X, back.Z-r.Z))
		}
		// And in again: blocked at once, not let in.
		again := w.Walk(ox, oy, r.X, r.Y, r.Z, r.X+c.dx*30, r.Z-c.dz*30)
		if !again.Blocked || math.Hypot(again.X-r.X, again.Z-r.Z) > 0.05 || again.Y != 0 {
			t.Errorf("from (%.0f, %.0f): the walk in again from the stop: %+v", c.fx, c.fz, again)
		}
	}
}

// TestRound857PainsRock replays the way in on the user's own data (it needs
// the export, so it runs only when pointed at it: NAVMESH_DIR=<export dir>):
// region 90/143's oas_tarim_rock_l_03 (object 3), the north outline edge 5
// that the prod save of Pain stood 0.01 from at the footprint's -73.165.
func TestRound857PainsRock(t *testing.T) {
	dir := os.Getenv("NAVMESH_DIR")
	if dir == "" {
		t.Skip("NAVMESH_DIR unset: no data")
	}
	w, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	rx, ry := 90, 143
	g := w.Graph(worldmap.RegionID(rx, ry))
	if g == nil || g.Objects[3] == nil {
		t.Fatal("no 90/143 or no object 3 in it")
	}
	in, out := 0, 0
	// Walk at the rock from 60 units out in 72 directions, then a second leg
	// from each stop straight back.
	for a := 0; a < 72; a++ {
		ang := float64(a) * math.Pi / 36
		cx, cz := 835.14, 349.54
		fx, fz := cx+math.Cos(ang)*170, cz+math.Sin(ang)*170
		if s := g.SurfaceAt(fx, fz, g.Region.TerrainHeight(fx, fz)); s.Object != OnTerrain {
			continue
		}
		x0, z0 := worldmap.ToWorld(rx, ry, fx, fz, rx, ry)
		x1, z1 := worldmap.ToWorld(rx, ry, cx, cz, rx, ry)
		r := w.Walk(rx, ry, x0, math.NaN(), z0, x1, z1)
		if !r.Blocked {
			continue
		}
		_, _, lx, lz := worldmap.FromWorld(r.X, r.Z, rx, ry)
		if s := g.SurfaceAt(lx, lz, r.Y); s.Object != OnTerrain {
			in++
			t.Errorf("direction %d: the stop (%.3f, %.3f, %.3f) settles on object %d", a, lx, lz, r.Y, s.Object)
		}
		back := w.Walk(rx, ry, r.X, r.Y, r.Z, x0, z0)
		if back.Blocked && math.Hypot(back.X-r.X, back.Z-r.Z) < 1 {
			t.Errorf("direction %d: from the stop (%.3f, %.3f) the walk back out is blocked at once", a, lx, lz)
		}
		out++
	}
	if out == 0 {
		t.Fatal("no walk met the rock")
	}
	t.Logf("%d walks met the rock, %d stops settled inside", out, in)
	// The prod save itself, at the footprint's height: on the rock, as the
	// original's point resolve puts a mover named at that height (READ
	// c:0x403dd0: the nearest surface). Named at the terrain's height: off.
	if s := g.SurfaceAt(806.875, 474.141, -73.165); s.Object != 3 {
		t.Errorf("the save at -73.165: %+v", s)
	}
	if s := g.SurfaceAt(806.875, 474.141, g.Region.TerrainHeight(806.875, 474.141)); s.Object != OnTerrain {
		t.Errorf("the save at the terrain's height: %+v", s)
	}
}
