package session

import (
	"bytes"
	"encoding/binary"
	"math"
	"sync/atomic"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// Round 808: the arrow keys' stop 0x7023 and turn 0x7024 (destmove.go; READ
// s:0x4b12a0 / 0x4b1360, the client's reader of 0xB024 c:0x8a4ec0).

func angleBody(a uint16) []byte { return binary.LittleEndian.AppendUint16(nil, a) }

func TestRound808TheTurnIsRetailsBytes(t *testing.T) {
	if got := encodeMoveTurn(0x01020304, 0xbeef); !bytes.Equal(got, []byte{0x04, 0x03, 0x02, 0x01, 0xef, 0xbe}) {
		t.Fatalf("0xB024 = % x", got)
	}
}

// Up runs, Left turns it: the turn goes to the window and the mover as
// 0xB024 with the angle as received, and the server's run bends there and goes
// on along the new heading.
func TestRound808ATurnBendsTheRunAndIsBroadcast(t *testing.T) {
	f := startDeadWorldFixture(t)
	var now atomic.Int64
	now.Store(time.Now().UnixNano())
	f.hub.SetClock(func() time.Time { return time.Unix(0, now.Load()) })
	t.Cleanup(func() { f.hub.SetClock(nil) })
	// A run toward +x: heading pi/2 is wire angle 0.
	f.send(t, f.connA, proto.OpMovementRequest, []byte{0, 1, 0, 0})
	readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
	readOp(t, f, f.connB, f.rB, proto.OpMovementResponse)
	now.Add(int64(time.Second))
	before, _ := f.hub.EntityByCharacterID(f.aria)
	// Turned to +z: heading 0 is wire angle 0xc000 (three quarters round).
	f.send(t, f.connA, OpMovementTurnRequest, angleBody(0xc000))
	for _, side := range []struct {
		name string
		p    *proto.Packet
	}{{"Aria", opOnly(readOp(t, f, f.connA, f.rA, OpMovementTurn))}, {"Bram", opOnly(readOp(t, f, f.connB, f.rB, OpMovementTurn))}} {
		if len(side.p.Data) != 6 || int64(binary.LittleEndian.Uint32(side.p.Data)) != f.aria || binary.LittleEndian.Uint16(side.p.Data[4:]) != 0xc000 {
			t.Fatalf("%s's 0xB024 % x", side.name, side.p.Data)
		}
	}
	e, _ := f.hub.EntityByCharacterID(f.aria)
	if e.Move == nil || !e.Move.Heading || math.Abs(e.Heading-world.HeadingFromWire(0xc000)) > 1e-9 {
		t.Fatalf("after the turn: heading %v, leg %+v", e.Heading, e.Move)
	}
	now.Add(int64(time.Second))
	after, _ := f.hub.EntityByCharacterID(f.aria)
	dx, dz := after.Pos.X-before.Pos.X, after.Pos.Z-before.Pos.Z
	if math.Abs(dx) > 0.01 || math.Abs(dz-PlayerRunSpeed) > 0.01 { // the u16 angle's quantum
		t.Fatalf("a second after the turn Aria moved (%v, %v), want (0, %v): the run goes on along the new heading", dx, dz, PlayerRunSpeed)
	}
}

// Up's release: the leg ends where the server has it, facing the angle, and
// 0xB023 goes to the window and the mover.
func TestRound808TheStopEndsTheRunAndIsRelayed(t *testing.T) {
	f := startDeadWorldFixture(t)
	var now atomic.Int64
	now.Store(time.Now().UnixNano())
	f.hub.SetClock(func() time.Time { return time.Unix(0, now.Load()) })
	t.Cleanup(func() { f.hub.SetClock(nil) })
	f.send(t, f.connA, proto.OpMovementRequest, []byte{0, 1, 0, 0})
	readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
	readOp(t, f, f.connB, f.rB, proto.OpMovementResponse)
	now.Add(int64(500 * time.Millisecond))
	f.send(t, f.connA, OpMovementStopRequest, angleBody(0x4000))
	for _, side := range []struct {
		name string
		p    *proto.Packet
	}{{"Aria", opOnly(readOp(t, f, f.connA, f.rA, OpMovementStop))}, {"Bram", opOnly(readOp(t, f, f.connB, f.rB, OpMovementStop))}} {
		id, pos, h := stopWorld(t, spawnZone, side.p.Data)
		if id != f.aria || math.Abs(pos.X-PlayerRunSpeed*0.5) > 0.01 || math.Abs(pos.Z) > 0.01 {
			t.Fatalf("%s's 0xB023: %d at %+v", side.name, id, pos)
		}
		if math.Abs(h-world.HeadingFromWire(0x4000)) > 1e-3 {
			t.Fatalf("%s's 0xB023 faces %v, want the angle's %v", side.name, h, world.HeadingFromWire(0x4000))
		}
	}
	if e, _ := f.hub.EntityByCharacterID(f.aria); e.Move != nil {
		t.Fatalf("the leg goes on after the stop: %+v", e.Move)
	}
}

// Spinning in place: the heading changes, nothing walks, everyone hears it.
func TestRound808ATurnStandingOnlyTurns(t *testing.T) {
	f := startDeadWorldFixture(t)
	f.send(t, f.connA, OpMovementTurnRequest, angleBody(0x2000))
	readOp(t, f, f.connB, f.rB, OpMovementTurn)
	e, _ := f.hub.EntityByCharacterID(f.aria)
	if e.Move != nil || math.Abs(e.Heading-world.HeadingFromWire(0x2000)) > 1e-9 {
		t.Fatalf("standing turn: heading %v, leg %+v", e.Heading, e.Move)
	}
}

func opOnly(p *proto.Packet, _ []*proto.Packet) *proto.Packet { return p }
