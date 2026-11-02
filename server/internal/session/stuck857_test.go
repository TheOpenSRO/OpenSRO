package session

import (
	"bufio"
	"math"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/navmesh"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

// Round 857 (the user: "I can sometimes clip into buildings and other parts of
// the map and then I can't escape"): an arrow-key (or sky-click) run, the
// heading form of 0x7021, is walked on the server's mesh like every other
// step (READ: CGObjMoverByCmd's step goes through slot 305 to the collision
// query, s:0x485740 -> s:0x98b300, and a blocking edge ends the movement).
// Before, the server ran it as a straight line through every wall (round
// 812's list), so the Up key's release (0x7023 -> Halt -> 0xB023) stopped the
// character inside or beyond whatever it ran at, and its client was snapped
// there.
func TestRound857AHeadingRunStopsAtTheWall(t *testing.T) {
	strictPositions(t)
	// Jangan's frame: world (0, 0) is 97/168's local (960, 960); the terrain
	// wall at local x 1000 (a tile line, as real cell edges lie) is world x 40.
	SetNavmesh(navmesh.NewWorld(nil, map[int]*navmesh.Region{worldmap.RegionID(97, 168): wallRegion(1000)}))
	t.Cleanup(func() { SetNavmesh(nil) })
	f := startDeadWorldFixture(t)
	var now atomic.Int64
	now.Store(time.Now().UnixNano())
	f.hub.SetClock(func() time.Time { return time.Unix(0, now.Load()) })
	t.Cleanup(func() { f.hub.SetClock(nil); buffBooks.SetGMSpeedFactor(f.aria, 1) })
	for _, factor := range []float64{1, 10} {
		gmSpeed{hub: f.hub}.SetGMSpeed(f.aria, factor)
		if factor != 1 {
			readOp(t, f, f.connA, f.rA, OpBuffEnd)
			readOp(t, f, f.connB, f.rB, OpBuffEnd)
		}
		// Up: wire angle 0 is heading pi/2, +x -- at the wall.
		f.send(t, f.connA, proto.OpMovementRequest, []byte{0, 1, 0, 0})
		readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
		readOp(t, f, f.connB, f.rB, proto.OpMovementResponse)
		// Held for 3 s: 150 units at 1x, 1,500 at 10x, the wall 40 off.
		for i := 0; i < 12; i++ {
			now.Add(int64(250 * time.Millisecond))
			f.hub.WalkHeadingRuns()
		}
		ent, _ := f.hub.EntityByCharacterID(f.aria)
		if ent.Pos.X > 40 || ent.Pos.X < 39 {
			t.Fatalf("/speed %v: 3 s into a run at a wall 40 off the hub has Aria at %+v, want at the wall", factor, ent.Pos)
		}
		// The pass ends the run at the wall and tells both (0xB023).
		moverPass(f.hub)
		for _, side := range []struct {
			name string
			p    *proto.Packet
		}{{"Aria", opOnly(readOp(t, f, f.connA, f.rA, OpMovementStop))}, {"Bram", opOnly(readOp(t, f, f.connB, f.rB, OpMovementStop))}} {
			_, pos, _ := stopWorld(t, spawnZone, side.p.Data)
			if pos.X > 40 || pos.X < 39.7 || math.Abs(pos.Z) > 0.25 {
				t.Fatalf("/speed %v: %s's 0xB023 at %+v, want the wall's stop (x 39.8)", factor, side.name, pos)
			}
		}
		// The release finds it there: the stop names the same point.
		f.send(t, f.connA, OpMovementStopRequest, angleBody(0))
		_, pos, _ := stopWorld(t, spawnZone, opOnly(readOp(t, f, f.connA, f.rA, OpMovementStop)).Data)
		readOp(t, f, f.connB, f.rB, OpMovementStop)
		if pos.X > 40 || pos.X < 39.7 {
			t.Fatalf("/speed %v: the release's stop at %+v, want the wall", factor, pos)
		}
		// Back west and round for the next speed: a click walk home.
		f.send(t, f.connA, proto.OpMovementRequest, clickTo(0, 0, 0))
		readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
		readOp(t, f, f.connB, f.rB, proto.OpMovementResponse)
		now.Add(int64(2 * time.Second))
		if ent, _ := f.hub.EntityByCharacterID(f.aria); math.Abs(ent.Pos.X) > 0.5 {
			t.Fatalf("/speed %v: back home at %+v", factor, ent.Pos)
		}
	}
	// A run away from the wall goes on: 2 s west at 1x is 100 units.
	gmSpeed{hub: f.hub}.SetGMSpeed(f.aria, 1)
	readOp(t, f, f.connA, f.rA, OpBuffEnd)
	readOp(t, f, f.connB, f.rB, OpBuffEnd)
	f.send(t, f.connA, proto.OpMovementRequest, append([]byte{0, 1}, angleBody(32768)...))
	readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
	readOp(t, f, f.connB, f.rB, proto.OpMovementResponse)
	for i := 0; i < 8; i++ {
		now.Add(int64(250 * time.Millisecond))
		f.hub.WalkHeadingRuns()
	}
	if ent, _ := f.hub.EntityByCharacterID(f.aria); math.Abs(ent.Pos.X+100) > 0.5 {
		t.Fatalf("a run away from the wall: Aria at %+v, want x -100", ent.Pos)
	}
}

// Round 857: a client's stop report (a claim, OURS since round 749) past a
// wall from where the server has the character is refused and corrected,
// however near; one on the server's side is taken as before. Before, a claim
// within the slack and the banked second was taken wherever it lay, so a
// client whose own walk had gone into a building put the server there too.
func TestRound857AClaimPastAWallIsCorrected(t *testing.T) {
	strictPositions(t)
	// The wall at world x 40 (local 1000, a tile line).
	SetNavmesh(navmesh.NewWorld(nil, map[int]*navmesh.Region{worldmap.RegionID(97, 168): wallRegion(1000)}))
	t.Cleanup(func() { SetNavmesh(nil) })
	f := startDeadWorldFixture(t)
	// Aria walks to x 36 (short of the wall) and stands.
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(36, 0, 0))
	readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
	readOp(t, f, f.connB, f.rB, proto.OpMovementResponse)
	time.Sleep(1100 * time.Millisecond) // the leg, and a second's allowance banked
	// A stop report 6 past the wall: within slack and allowance, but walled.
	f.send(t, f.connA, OpMove, (&MoveRequest{X: 46, Stopped: true}).Encode())
	for _, side := range []struct {
		name string
		conn net.Conn
		r    *bufio.Reader
	}{{"Aria", f.connA, f.rA}, {"Bram", f.connB, f.rB}} {
		p := f.read(t, side.conn, side.r)
		if p.Opcode != OpMovementStop {
			t.Fatalf("%s got %#04x, want the correction", side.name, p.Opcode)
		}
		if _, at, _ := stopWorld(t, spawnZone, p.Data); math.Abs(at.X-36) > 0.01 {
			t.Fatalf("%s told %+v, want the server's x 36", side.name, at)
		}
	}
	// One on this side of the wall: taken, and only the window hears it.
	f.send(t, f.connA, OpMove, (&MoveRequest{X: 39.5, Stopped: true}).Encode())
	p := f.read(t, f.connB, f.rB)
	if _, at, _ := stopWorld(t, spawnZone, p.Data); p.Opcode != OpMovementStop || math.Abs(at.X-39.5) > 0.01 {
		t.Fatalf("Bram got %#04x at %+v, want the stop at 39.5", p.Opcode, at)
	}
	if !f.nothing(t, f.connA, f.rA) {
		t.Fatal("Aria was corrected for a stop on her side of the wall")
	}
}
