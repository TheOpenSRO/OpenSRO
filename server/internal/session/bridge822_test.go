package session

import (
	"math"
	"sync/atomic"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/navmesh"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

// Round 822: "sometimes when I cross a bridge I teleport underneath it". The
// server's height for a mover was Mover.At's guess -- a heading run keeps
// its start's height for the whole run -- and the navigation-mesh walk of the
// next click was seeded from it (SurfaceAt: the highest surface no more than
// 12 above it). On a deck more than 12 above that guess the walk started on
// the ground under the bridge, met the river bank's wall there, and the
// leg's wall stop (0xB023, to the mover too) put the rider under the bridge.
// MEASURED on the real mesh (Jangan's west bridge, region 97/165 object 15:
// deck 82-107 over a river bed at 6-57): from the deck's middle with the
// run's height the walk west stops at world (-5339.8, 24.3, -108.0); with
// the deck's own height it crosses.

// bridgeWorld is a synthetic 97/168 (never real data): flat ground at 0, a
// wall (flag 3) along local x 1060 -- world x 100, the river bank -- and an
// arched bridge over it, local x 1000..1120 (y 0 at its open ends, 40 at
// 1060), z 950..970 (world z 10..-10), its sides 0x10 (a wall on the deck,
// passed beneath from the ground).
func bridgeWorld() *navmesh.World {
	r := wallRegion(1060)
	r.Objects = []navmesh.MapObject{{ResourceID: 822, X: 1060, Z: 960}}
	r.Cells[0].Objects = []uint16{0}
	r.Cells[1].Objects = []uint16{0}
	// Local to the placement (1060, 0, 960): two quads, the west half rising
	// and the east half falling.
	deck := &navmesh.CollisionMesh{
		Vertices: []navmesh.CVertex{
			{X: -60, Y: 0, Z: -10}, {X: 0, Y: 40, Z: -10}, {X: 60, Y: 0, Z: -10},
			{X: -60, Y: 0, Z: 10}, {X: 0, Y: 40, Z: 10}, {X: 60, Y: 0, Z: 10},
		},
		Cells: []navmesh.CCell{{A: 0, B: 1, C: 4}, {A: 0, B: 4, C: 3}, {A: 1, B: 2, C: 5}, {A: 1, B: 5, C: 4}},
		Outline: []navmesh.CEdge{
			{V0: 3, V1: 0, CellFrom: 1, CellTo: navmesh.NoCell, Flags: 0}, // the west end, open
			{V0: 2, V1: 5, CellFrom: 2, CellTo: navmesh.NoCell, Flags: 0}, // the east end, open
			{V0: 0, V1: 1, CellFrom: 0, CellTo: navmesh.NoCell, Flags: 0x10},
			{V0: 1, V1: 2, CellFrom: 2, CellTo: navmesh.NoCell, Flags: 0x10},
			{V0: 5, V1: 4, CellFrom: 3, CellTo: navmesh.NoCell, Flags: 0x10},
			{V0: 4, V1: 3, CellFrom: 1, CellTo: navmesh.NoCell, Flags: 0x10},
		},
		Internal: []navmesh.CEdge{
			{V0: 0, V1: 4, CellFrom: 0, CellTo: 1, Flags: 4},
			{V0: 1, V1: 4, CellFrom: 0, CellTo: 3, Flags: 4},
			{V0: 1, V1: 5, CellFrom: 2, CellTo: 3, Flags: 4},
		},
	}
	return navmesh.NewWorld(map[uint32]*navmesh.CollisionMesh{822: deck}, map[int]*navmesh.Region{worldmap.RegionID(97, 168): r})
}

// The deck's height at world x on the bridge's line (world z 0).
func deckAt(x float64) float64 { return 40 - math.Abs(x-100)*40/60 }

// bridgeRun puts Aria on a heading run east from world (0, 0, 0) onto the
// bridge, `run` long, with the hub on a test clock.
func bridgeRun(t *testing.T, run time.Duration) (*deadWorldFixture, *atomic.Int64) {
	t.Helper()
	SetNavmesh(bridgeWorld())
	t.Cleanup(func() { SetNavmesh(nil) })
	f := startDeadWorldFixture(t)
	var now atomic.Int64
	now.Store(time.Now().UnixNano())
	f.hub.SetClock(func() time.Time { return time.Unix(0, now.Load()) })
	t.Cleanup(func() { f.hub.SetClock(nil) })
	// A sky click east: heading pi/2 is wire angle 0.
	f.send(t, f.connA, proto.OpMovementRequest, []byte{0, 1, 0, 0})
	readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
	now.Add(int64(run))
	return f, &now
}

// The synthetic bridge is what the real one MEASURED: from the deck's top with
// the run's start height the walk east is on the ground and meets the bank;
// with the deck's it crosses.
func TestRound822TheBridgeFixture(t *testing.T) {
	SetNavmesh(bridgeWorld())
	t.Cleanup(func() { SetNavmesh(nil) })
	if w, ok := navWalk(spawnZone, 95, 0, 0, 200, 0); !ok || !w.Blocked || w.Y != 0 {
		t.Fatalf("from the deck's top at the ground's height: %+v, want the bank's wall on the ground", w)
	}
	if w, ok := navWalk(spawnZone, 95, deckAt(95), 0, 200, 0); !ok || w.Blocked {
		t.Fatalf("from the deck's top at its height: %+v, want across", w)
	}
	if y, ok := navGround(spawnZone, world.Position{}, 95, 0); !ok || math.Abs(y-deckAt(95)) > 0.01 {
		t.Fatalf("walked from the run's start to the deck's top: %v %v, want %.2f", y, ok, deckAt(95))
	}
}

// A click on the deck after a heading run onto it: the leg starts at the
// deck's walked height and crosses, no wall under the bridge.
func TestRound822AClickOnTheDeckAfterARunCrossesIt(t *testing.T) {
	f, _ := bridgeRun(t, 1900*time.Millisecond) // 95 units: the deck's top
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(200, 0, 0))
	readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
	e, _ := f.hub.EntityByCharacterID(f.aria)
	if e.Move == nil || e.Move.Heading {
		t.Fatalf("no destination leg: %+v", e.Move)
	}
	if e.Move.Wall || math.Abs(e.Move.Dest.X-200) > 0.5 {
		t.Fatalf("the leg ends at (%.2f, %.2f, %.2f) wall %v: the server walked the ground under the bridge",
			e.Move.Dest.X, e.Move.Dest.Y, e.Move.Dest.Z, e.Move.Wall)
	}
	if math.Abs(e.Move.Src.Y-deckAt(e.Move.Src.X)) > 0.5 {
		t.Fatalf("the leg starts at height %.2f at x %.2f, want the deck's %.2f", e.Move.Src.Y, e.Move.Src.X, deckAt(e.Move.Src.X))
	}
}

// Up's release on the deck: the 0xB023 the mover snaps to stands on the deck,
// not at the run's start height under it.
func TestRound822AStopOnTheDeckStandsOnIt(t *testing.T) {
	f, _ := bridgeRun(t, 1900*time.Millisecond)
	f.send(t, f.connA, OpMovementStopRequest, angleBody(0))
	p, _ := readOp(t, f, f.connA, f.rA, OpMovementStop)
	_, pos, _ := stopWorld(t, spawnZone, p.Data)
	if math.Abs(pos.X-95) > 0.5 || math.Abs(pos.Y-deckAt(pos.X)) > 0.5 {
		t.Fatalf("the stop at (%.2f, %.2f, %.2f), want on the deck at height %.2f", pos.X, pos.Y, pos.Z, deckAt(pos.X))
	}
	if e, _ := f.hub.EntityByCharacterID(f.aria); math.Abs(e.Pos.Y-pos.Y) > 1e-3 || math.Abs(e.Trusted.Y-pos.Y) > 1e-3 {
		t.Fatalf("the hub keeps height %.2f (trusted %.2f), the stop said %.2f", e.Pos.Y, e.Trusted.Y, pos.Y)
	}
}

// A turn on the deck: the bent run goes on from the deck's height, so a stop
// after it is on the deck too (the walk starts from the turn).
func TestRound822ATurnOnTheDeckKeepsItsHeight(t *testing.T) {
	f, now := bridgeRun(t, 1800*time.Millisecond) // 90: on the rising half
	// Still east, a turn by a hair (the u16's quantum): the run's origin moves.
	f.send(t, f.connA, OpMovementTurnRequest, angleBody(1))
	readOp(t, f, f.connA, f.rA, OpMovementTurn)
	e, _ := f.hub.EntityByCharacterID(f.aria)
	if e.Move == nil || math.Abs(e.Move.Src.Y-deckAt(e.Move.Src.X)) > 0.5 {
		t.Fatalf("the bent run starts at %+v, want the deck's height", e.Move)
	}
	now.Add(int64(200 * time.Millisecond)) // 10 more: past the top
	f.send(t, f.connA, OpMovementStopRequest, angleBody(1))
	p, _ := readOp(t, f, f.connA, f.rA, OpMovementStop)
	_, pos, _ := stopWorld(t, spawnZone, p.Data)
	if math.Abs(pos.Y-deckAt(pos.X)) > 0.5 {
		t.Fatalf("the stop at (%.2f, %.2f, %.2f), want on the deck at height %.2f", pos.X, pos.Y, pos.Z, deckAt(pos.X))
	}
}

// Without a navigation mesh nothing changes: the heading run's stop keeps the
// run's height, as before round 822.
func TestRound822NoMeshKeepsTheStraightLine(t *testing.T) {
	SetNavmesh(nil)
	f := startDeadWorldFixture(t)
	var now atomic.Int64
	now.Store(time.Now().UnixNano())
	f.hub.SetClock(func() time.Time { return time.Unix(0, now.Load()) })
	t.Cleanup(func() { f.hub.SetClock(nil) })
	f.send(t, f.connA, proto.OpMovementRequest, []byte{0, 1, 0, 0})
	readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
	now.Add(int64(1900 * time.Millisecond))
	f.send(t, f.connA, OpMovementStopRequest, angleBody(0))
	p, _ := readOp(t, f, f.connA, f.rA, OpMovementStop)
	if _, pos, _ := stopWorld(t, spawnZone, p.Data); pos.Y != 0 {
		t.Fatalf("no mesh: the stop's height %.2f, want the run's 0", pos.Y)
	}
}
