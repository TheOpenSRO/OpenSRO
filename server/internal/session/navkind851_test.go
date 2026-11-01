package session

import (
	"math"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/navmesh"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

// treeWorld is a synthetic 97/168 (never real data): flat ground at 0 and a
// "tree" -- a 4 x 4 object whose outline blocks from both sides (flag 3, the
// 81% of real outline edges, and every real tree trunk's in Jangan, MEASURED
// round 851) -- placed at local (1000, 960), world (40, 0) in Jangan's frame.
func treeWorld() *navmesh.World {
	r := wallRegion(1900)
	r.Objects = []navmesh.MapObject{{ResourceID: 851, X: 1000, Z: 960}}
	r.Cells[0].Objects = []uint16{0}
	trunk := &navmesh.CollisionMesh{
		Vertices: []navmesh.CVertex{{X: -2, Z: -2}, {X: 2, Z: -2}, {X: 2, Z: 2}, {X: -2, Z: 2}},
		Cells:    []navmesh.CCell{{A: 0, B: 1, C: 2}, {A: 0, B: 2, C: 3}},
		Outline: []navmesh.CEdge{
			{V0: 0, V1: 1, CellFrom: 0, CellTo: navmesh.NoCell, Flags: 3},
			{V0: 1, V1: 2, CellFrom: 0, CellTo: navmesh.NoCell, Flags: 3},
			{V0: 2, V1: 3, CellFrom: 1, CellTo: navmesh.NoCell, Flags: 3},
			{V0: 3, V1: 0, CellFrom: 1, CellTo: navmesh.NoCell, Flags: 3},
		},
		Internal: []navmesh.CEdge{{V0: 0, V1: 2, CellFrom: 0, CellTo: 1, Flags: 4}},
	}
	return navmesh.NewWorld(map[uint32]*navmesh.CollisionMesh{851: trunk}, map[int]*navmesh.Region{worldmap.RegionID(97, 168): r})
}

// READ (s:0x485740, s:0x48492a): the collision query's two inputs from a
// mover are IsPC || IsCOS and its +0x38, 1 on every object.
func TestRound851ColliderPerKind(t *testing.T) {
	for _, c := range []struct {
		k       MoverKind
		recheck bool
	}{{MoverPlayer, true}, {MoverCOS, true}, {MoverMonster, false}, {MoverNPC, false}} {
		got := c.k.Collider()
		if got.RecheckObjects != c.recheck || !got.ObjectWalls {
			t.Errorf("%v: %+v, want recheck %v and object walls", c.k, got, c.recheck)
		}
	}
}

// A trade transport, a horse or a pet stops at a tree where a player on foot
// does: the same edge, the same point (no radius, no slide).
func TestRound851TreeStopsEveryKindAlike(t *testing.T) {
	SetNavmesh(treeWorld())
	t.Cleanup(func() { SetNavmesh(nil) })
	from, to := world.Position{X: 0, Y: 0, Z: 0}, world.Position{X: 80, Y: 0, Z: 0}
	var ends []world.Position
	for _, k := range []MoverKind{MoverPlayer, MoverCOS, MoverMonster, MoverNPC} {
		leg := moverLeg(k, "jangan", from, to)
		if !leg.Walked || !leg.Wall || leg.Stuck {
			t.Fatalf("%v: %+v, want walked and stopped by the trunk", k, leg)
		}
		// The trunk's west face is world x 38; the stop is ContactPush short.
		if math.Abs(leg.End.X-(38-navmesh.ContactPush)) > 1e-6 || math.Abs(leg.End.Z) > 1e-9 {
			t.Fatalf("%v stops at (%.4f, %.4f), want (%.4f, 0)", k, leg.End.X, leg.End.Z, 38-navmesh.ContactPush)
		}
		ends = append(ends, leg.End)
	}
	for _, e := range ends[1:] {
		if e != ends[0] {
			t.Fatalf("the kinds stop apart: %+v", ends)
		}
	}
	// Past the trunk's side: clear, the destination.
	if leg := moverLeg(MoverCOS, "jangan", world.Position{Z: 5}, world.Position{X: 80, Z: 5}); leg.Wall || leg.End.X != 80 {
		t.Fatalf("a leg beside the trunk: %+v, want clear", leg)
	}
	// Right at the trunk: stuck, no leg.
	if leg := moverLeg(MoverCOS, "jangan", ends[0], to); !leg.Stuck {
		t.Fatalf("a leg from the trunk's face: %+v, want stuck", leg)
	}
	// No mesh: the straight leg.
	SetNavmesh(nil)
	if leg := moverLeg(MoverCOS, "jangan", from, to); leg.Walked || leg.Wall || leg.End != to {
		t.Fatalf("no mesh: %+v, want the destination", leg)
	}
}

// A following COS's leg (the cosRuntime hook): it ends at the tree; a
// re-aim toward the same tree while walking there makes no new leg; and one
// standing at the trunk does not move.
func TestRound851FollowingCOSStopsAtTheTree(t *testing.T) {
	SetNavmesh(treeWorld())
	t.Cleanup(func() { SetNavmesh(nil) })
	o := &cosObj{zone: "jangan"}
	owner := world.Position{X: 80, Y: 0, Z: 0}
	end := cosLegEnd(o, world.Position{}, owner)
	if end == nil || math.Abs(end.X-(38-navmesh.ContactPush)) > 1e-6 {
		t.Fatalf("the leg ends at %+v, want the trunk's face", end)
	}
	o.moving, o.to = true, *end
	if again := cosLegEnd(o, world.Position{X: 10}, world.Position{X: 85, Z: 0.1}); again != nil {
		t.Fatalf("a re-aim to the same trunk: %+v, want no new leg", again)
	}
	o.moving, o.pos = false, *end
	if stuck := cosLegEnd(o, *end, owner); stuck != nil {
		t.Fatalf("at the trunk: %+v, want no leg (stuck)", stuck)
	}
	// Owner moved to the side: a clear line, the leg goes there.
	if side := cosLegEnd(o, *end, world.Position{X: 20, Z: -20}); side == nil || side.X != 20 {
		t.Fatalf("a clear line from the trunk: %+v, want the destination", side)
	}
}
