package session

import (
	"math"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/grounditem"
	"github.com/TheOpenSRO/OpenSRO/server/internal/navmesh"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

// Round 879: the Wrecked Ship's decks, the monsters on them and the doors
// across them, on synthetic meshes (no game data).

// deckRegion is a region whose terrain lies at seaFloor (the Wrecked Ship's
// sea floor, -1800 region-local) with one object listed over every cell: a
// 200 x 200 deck centred on local (960, 960), walled all round (0x03), at
// deckY.
func deckRegion(seaFloor float32) *navmesh.Region {
	r := &navmesh.Region{
		Cells:        []navmesh.Cell{{MinX: 0, MinZ: 0, MaxX: navmesh.RegionSpan, MaxZ: navmesh.RegionSpan, Objects: []uint16{0}}},
		Tiles:        make([]navmesh.Tile, navmesh.TileCount),
		Heights:      make([]float32, navmesh.HeightCount),
		PlaneTypes:   make([]byte, navmesh.PlaneCount),
		PlaneHeights: make([]float32, navmesh.PlaneCount),
		Objects:      []navmesh.MapObject{{ResourceID: 879, X: 960, Y: -842, Z: 960}},
	}
	for i := range r.Heights {
		r.Heights[i] = seaFloor
	}
	return r
}

func deckMesh() *navmesh.CollisionMesh {
	return &navmesh.CollisionMesh{
		Vertices: []navmesh.CVertex{{X: -100, Y: 0, Z: -100}, {X: 100, Y: 0, Z: -100}, {X: 100, Y: 0, Z: 100}, {X: -100, Y: 0, Z: 100}},
		Cells:    []navmesh.CCell{{A: 0, B: 1, C: 2}, {A: 0, B: 2, C: 3}},
		Outline: []navmesh.CEdge{
			{V0: 0, V1: 1, CellFrom: 0, CellTo: navmesh.NoCell, Flags: 3},
			{V0: 1, V1: 2, CellFrom: 0, CellTo: navmesh.NoCell, Flags: 3},
			{V0: 2, V1: 3, CellFrom: 1, CellTo: navmesh.NoCell, Flags: 3},
			{V0: 3, V1: 0, CellFrom: 1, CellTo: navmesh.NoCell, Flags: 3},
		},
		Internal: []navmesh.CEdge{{V0: 0, V1: 2, CellFrom: 0, CellTo: 1, Flags: 4}},
	}
}

// TestHatchFootingOnTheDeck: a hatch walked from its nest on the deck stands
// on the deck (-842), not at the nest's 0 (which the client drew on the sea
// floor's terrain, ~960 below the player: "one I couldn't see"); a hatch
// point past the deck's wall fails, as the original's line test does
// (READ s:0x5f704f, s:0x5f712e).
func TestHatchFootingOnTheDeck(t *testing.T) {
	SetNavmesh(navmesh.NewWorld(map[uint32]*navmesh.CollisionMesh{879: deckMesh()},
		map[int]*navmesh.Region{worldmap.RegionID(97, 168): deckRegion(-1800)}))
	t.Cleanup(func() { SetNavmesh(nil) })
	// Jangan's frame: world (0, 0) is region 97/168's local (960, 960).
	y, blocked := HatchFooting("jangan", 0, -800, 0, 60, -40)
	if blocked || math.Abs(y+842) > 1e-6 {
		t.Fatalf("a hatch on the deck: y %.2f blocked %v, want -842 and placed", y, blocked)
	}
	if _, blocked := HatchFooting("jangan", 0, -800, 0, 150, 0); !blocked {
		t.Fatal("a hatch past the deck's wall was placed (on the sea floor)")
	}
	if h := SurfaceNear("jangan", 10, -760, 10); math.Abs(h+842) > 1e-6 {
		t.Fatalf("a load at a player on the deck: %.2f, want -842", h)
	}
	if h := SurfaceNear("jangan", 500, -760, 500); math.Abs(h+1800) > 1e-6 {
		t.Fatalf("off the deck: %.2f, want the sea floor -1800", h)
	}
	// A monster's leg on the deck ends on it: the height a list then names.
	if _, _, ey, clipped := navLegEnd("jangan", 0, -842, 0, 50, 50); clipped || math.Abs(ey+842) > 1e-6 {
		t.Fatalf("leg end height %.2f clipped %v", ey, clipped)
	}
	SetNavmesh(nil)
	if y, blocked := HatchFooting("jangan", 0, -800, 0, 60, -40); blocked || y != -800 {
		t.Fatalf("no mesh: y %.2f blocked %v, want the nest's -800", y, blocked)
	}
}

// TestDoorSegmentsInTheFrame: a door's footprint is its model's navigation
// mesh placed as a map object at its named position and turned into the
// layer's frame -- the frame point of the door, not its region-local point,
// which round 869's block compared with the mover's frame position.
func TestDoorSegmentsInTheFrame(t *testing.T) {
	// A 153.6 x 31.2 slab of blocking edges (the shape MEASURED for the
	// Wrecked Ship's door; the numbers here are the test's own).
	door := &navmesh.CollisionMesh{
		Vertices: []navmesh.CVertex{{X: -76, Y: 0, Z: -15}, {X: 77, Y: 0, Z: -15}, {X: 77, Y: 0, Z: 15}, {X: -76, Y: 0, Z: 15}},
		Cells:    []navmesh.CCell{{A: 0, B: 1, C: 2}, {A: 0, B: 2, C: 3}},
		Outline: []navmesh.CEdge{
			{V0: 0, V1: 3, CellFrom: 0, CellTo: navmesh.NoCell, Flags: 3},
			{V0: 3, V1: 2, CellFrom: 0, CellTo: navmesh.NoCell, Flags: 3},
			{V0: 1, V1: 2, CellFrom: 1, CellTo: navmesh.NoCell, Flags: 3},
			{V0: 0, V1: 1, CellFrom: 1, CellTo: navmesh.NoCell, Flags: 3},
		},
		Internal: []navmesh.CEdge{{V0: 0, V1: 2, CellFrom: 0, CellTo: 1, Flags: 4}},
	}
	// Region 111/243 in the frame of 114/243 (the Wrecked Ship's inside),
	// the door at local (840, 759), yaw 0: across a passage running along z.
	segs := doorSegments(door, worldmap.RegionID(111, 243), 840, -910, 759, 0, 114, 243)
	if len(segs) != 4 {
		t.Fatalf("%d segments, want the 4 outline edges", len(segs))
	}
	fx, fz := worldmap.ToWorld(111, 243, 840, 759, 114, 243)
	for _, s := range segs {
		for _, p := range [][2]float64{{s[0], s[1]}, {s[2], s[3]}} {
			if math.Abs(p[0]-fx) > 80 || math.Abs(p[1]-fz) > 20 {
				t.Fatalf("segment end %v is not around the door's frame point (%.1f, %.1f)", p, fx, fz)
			}
		}
	}
	if math.Abs(fz-759) < 1000 {
		t.Fatalf("frame z %.1f should be far from the local 759 (the bug's coordinates)", fz)
	}
}

// TestDropsStayOnTheDeck: a kill's stacks beside the deck's edge. The ring
// (8 to 20 units from the corpse) reaches past the edge; a stack whose walk
// from the corpse meets the edge lies on the corpse (READ s:0x48fdf0, the
// second placement), every other on the deck at the deck's height. Before:
// the stack kept the ring's point whatever lay there, and the client drew it
// on the sea floor (MEASURED: 2 of 203 stacks of a run).
func TestDropsStayOnTheDeck(t *testing.T) {
	SetNavmesh(navmesh.NewWorld(map[uint32]*navmesh.CollisionMesh{879: deckMesh()},
		map[int]*navmesh.Region{worldmap.RegionID(97, 168): deckRegion(-1800)}))
	t.Cleanup(func() { SetNavmesh(nil) })
	ground := grounditem.NewHub()
	corpse := combat.Monster{ID: 1, Zone: "jangan", X: 92, Y: -842, Z: 0, HasHeight: true}
	onCorpse := 0
	for i := 0; i < 300; i++ {
		for _, it := range dropKillLoot(ground, nil, corpse, 7, 100, nil) {
			if math.Abs(float64(it.X)) > 100 || math.Abs(float64(it.Z)) > 100 {
				t.Fatalf("stack %d at (%.1f, %.1f): off the deck", i, it.X, it.Z)
			}
			if math.Abs(float64(it.Y)+842) > 1e-3 {
				t.Fatalf("stack %d at height %.2f, want the deck's -842", i, it.Y)
			}
			if it.X == 92 && it.Z == 0 {
				onCorpse++
			}
		}
	}
	if onCorpse == 0 || onCorpse == 300 {
		t.Errorf("%d of 300 stacks on the corpse: want some (the ring past the edge) and not all", onCorpse)
	}
	// A monster that carries no height (the open world) keeps the ring.
	field := combat.Monster{ID: 2, Zone: "jangan", X: 92, Z: 0}
	past := 0
	for i := 0; i < 300; i++ {
		for _, it := range dropKillLoot(ground, nil, field, 7, 100, nil) {
			if math.Abs(float64(it.X)) > 100 {
				past++
			}
			if it.Y != 0 {
				t.Fatalf("an open-world stack at height %.2f, want 0", it.Y)
			}
		}
	}
	if past == 0 {
		t.Errorf("no open-world stack past the edge in 300: the ring is unchanged there")
	}
}
