package session

import (
	"math"
	"sync/atomic"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/navmesh"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

// Round 878 (the user: "I'm dealing with a movement bug where I get teleported
// back to where I was, seems like server lag"; their prod log: four MOVE
// corrections 75-250 units back, each after a run of quick clicks, most of
// them sky clicks -- heading runs -- in the Wrecked Ship). A heading run is
// walked two seconds ahead at a time (round 857). When one of those walks met
// a wall, the stretch it had walked clear up to the wall was not counted as
// clear: the run stood where that walk began until its time reached the wall,
// then jumped there. The client's run went on meanwhile, so the hub had the
// character up to a whole walk behind -- its stop at the wall was refused and
// corrected back, and a click meanwhile started its leg from the held point.

// rb878Fixture is a fixture with the hub on a clock the test moves and the
// mover pass off (the test runs the pass's walk itself), on a mesh with a
// terrain wall at local x wallLocalX of 97/168 (Jangan's frame: world x is
// local x - 960).
func rb878Fixture(t *testing.T, wallLocalX float32) (*deadWorldFixture, *atomic.Int64) {
	t.Helper()
	strictPositions(t)
	moverPassAuto.Store(false)
	t.Cleanup(func() { moverPassAuto.Store(true) })
	SetNavmesh(navmesh.NewWorld(nil, map[int]*navmesh.Region{worldmap.RegionID(97, 168): wallRegion(wallLocalX)}))
	t.Cleanup(func() { SetNavmesh(nil) })
	f := startDeadWorldFixture(t)
	var now atomic.Int64
	now.Store(time.Now().UnixNano())
	f.hub.SetClock(func() time.Time { return time.Unix(0, now.Load()) })
	t.Cleanup(func() { f.hub.SetClock(nil) })
	return f, &now
}

// The run's place, a pass (250 ms) at a time, against where its time has it:
// before round 878 a run toward a wall 160 off stood at 100 from 2.0 s to
// 3.2 s (the first walk's end), and one toward a wall 40 off stood at its
// start for 0.8 s.
func TestRound878AHeadingRunIsWhereItsTimeHasItUpToTheWall(t *testing.T) {
	for _, c := range []struct {
		name   string
		local  float32
		wallAt float64
	}{{"a wall in the second walk", 1120, 160}, {"a wall in the first walk", 1000, 40}} {
		t.Run(c.name, func(t *testing.T) {
			f, now := rb878Fixture(t, c.local)
			// Up (wire angle 0, heading +x) at the base run speed, 50.
			f.send(t, f.connA, proto.OpMovementRequest, []byte{0, 1, 0, 0})
			readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
			readOp(t, f, f.connB, f.rB, proto.OpMovementResponse)
			for i := 1; i <= 16; i++ {
				now.Add(int64(250 * time.Millisecond))
				f.hub.WalkHeadingRuns()
				ent, _ := f.hub.EntityByCharacterID(f.aria)
				want := math.Min(50*0.25*float64(i), c.wallAt-0.2)
				if math.Abs(ent.Pos.X-want) > 0.3 {
					t.Fatalf("%.2f s into the run the hub has Aria at x %.2f, want %.2f (the run's time, cut at the wall)", 0.25*float64(i), ent.Pos.X, want)
				}
			}
		})
	}
}

// The user's sequence: a run of quick clicks, the last a sky click whose run
// meets a wall in its third walk; the client runs to the wall and reports its
// stop there (OURS, round 749) a frame before the server's own run reaches it.
// The stop is taken: no correction. Before round 878 the hub held the run at
// the third walk's start, 70 short of the wall, and corrected the player back
// there (MEASURED, round 878's lane run w2 on the Wrecked Ship's deck: 60.4
// back at the base run speed).
func TestRound878AStopAtTheRunsWallIsTakenNotCorrected(t *testing.T) {
	// The wall at world x 300 (local 1260, a tile line).
	f, now := rb878Fixture(t, 1260)
	// Quick click-walks east, each before the last arrives (as the user's log
	// shows them), with a duplicate press: refused within 5 of the walk's
	// point (READ 0xb45b28), no echo.
	for _, x := range []float64{20, 35, 35, 50, 60} {
		f.send(t, f.connA, proto.OpMovementRequest, clickTo(x, 0, 0))
		time.Sleep(20 * time.Millisecond) // handled at this clock
		now.Add(int64(150 * time.Millisecond))
	}
	for i := 0; i < 4; i++ {
		readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
		readOp(t, f, f.connB, f.rB, proto.OpMovementResponse)
	}
	ent, _ := f.hub.EntityByCharacterID(f.aria)
	start := ent.Pos.X
	// The sky click: a run east, toward the wall.
	runStart := now.Load()
	f.send(t, f.connA, proto.OpMovementRequest, []byte{0, 1, 0, 0})
	readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
	readOp(t, f, f.connB, f.rB, proto.OpMovementResponse)
	wall := 300 - 0.2
	arrive := (wall - start) / 50 // seconds
	at := func(s float64) { now.Store(runStart + int64(s*float64(time.Second))) }
	for s := 0.25; s < arrive; s += 0.25 {
		at(s)
		f.hub.WalkHeadingRuns() // the mover pass's walk
	}
	// 20 ms short of the server's arrival: the client's stop at its wall.
	at(arrive - 0.02)
	f.send(t, f.connA, OpMove, (&MoveRequest{X: float32(wall), Stopped: true}).Encode())
	p := f.read(t, f.connB, f.rB)
	if _, got, _ := stopWorld(t, spawnZone, p.Data); p.Opcode != OpMovementStop || math.Abs(got.X-wall) > 0.01 {
		t.Fatalf("Bram got %#04x at %+v, want the stop at the wall (%.1f)", p.Opcode, got, wall)
	}
	if !f.nothing(t, f.connA, f.rA) {
		t.Fatal("Aria was corrected for her stop at the wall her run met")
	}
}

// The 5.0 test of a new click is against the destination the leg was given
// (READ, s:0x48c35f: the original's mover keeps it and stops at the edge
// while stepping), not the wall the server's walk clipped the leg at: a click
// just past the wall's stop, while the leg still runs toward it, is taken.
// Before round 878 it was refused (within 5 of the clipped Dest), silently.
func TestRound878TheNearRuleIsAgainstTheAskedDestination(t *testing.T) {
	// The wall at world x 40 (local 1000).
	f, now := rb878Fixture(t, 1000)
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(100, 0, 0))
	readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
	readOp(t, f, f.connB, f.rB, proto.OpMovementResponse)
	now.Add(int64(200 * time.Millisecond)) // 10 along, the leg still runs
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(42, 0, 3))
	p, _ := readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
	e, ok := DecodeMoveEcho(p.Data)
	if !ok || e.Move == nil {
		t.Fatalf("no echo for the click past the wall's stop: %x", p.Data)
	}
	// And one within 5 of the asked destination is refused, as before.
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(100, 0, 0))
	now.Add(int64(50 * time.Millisecond))
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(102, 0, 1))
	readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
	if !f.nothing(t, f.connA, f.rA) {
		t.Fatal("a click within 5 of the asked destination was echoed")
	}
}

// The INFO lines are kept to one a second for a character and rule, the next
// counting what was kept back.
func TestRound878MoveLogLimiter(t *testing.T) {
	var at time.Time = time.Unix(1000, 0)
	moveLogNow = func() time.Time { return at }
	t.Cleanup(func() { moveLogNow = time.Now })
	moveLog("x", 878001, "r")
	k := moveLogKey{878001, "r"}
	for i := 0; i < 5; i++ {
		moveLog("x", 878001, "r")
	}
	if e := moveLogSeen[k]; e == nil || e.suppressed != 5 {
		t.Fatalf("5 within the second: %+v, want 5 kept back", e)
	}
	moveLog("x", 878001, "other") // another rule logs
	at = at.Add(moveLogEvery)
	moveLog("x", 878001, "r")
	if e := moveLogSeen[k]; e == nil || e.suppressed != 0 || !e.at.Equal(at) {
		t.Fatalf("a second later: %+v, want logged afresh", e)
	}
}
