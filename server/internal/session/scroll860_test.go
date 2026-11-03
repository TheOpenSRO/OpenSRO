package session

import (
	"encoding/binary"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 860, lane S: the scroll state 1 holds the character (scrollhold.go;
// READ s:0x4296a0 group 11, an allow list of chat, item use, the cancel and
// two more).

// click sends a 0x7021 to a point dx east of where Aria stands.
func (rig *scrollRig) click(dx float64) {
	rig.t.Helper()
	e, _ := rig.hub.EntityByCharacterID(rig.charID)
	dest := world.Position{X: e.Pos.X + dx, Y: e.Pos.Y, Z: e.Pos.Z}
	region, lx, lz := regionLocalOf(e.Zone, dest)
	body := (&proto.Movement{Kind: 1, Region: region, LocalX: int16(lx), LocalY: int16(e.Pos.Y), LocalZ: int16(lz)}).Encode()
	rig.send(proto.OpMovementRequest, body)
}

func (rig *scrollRig) send(op uint16, data []byte) {
	rig.t.Helper()
	if err := proto.Write(rig.conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
		rig.t.Fatal(err)
	}
}

// pos is where the server has Aria, and whether a leg runs.
func (rig *scrollRig) pos() (world.Position, bool) {
	e, _ := rig.hub.EntityByCharacterID(rig.charID)
	return e.Pos, e.Move != nil
}

// heldAnswer reads what follows a held request: a 0xB023 for Aria at the
// server's position, and none of the opcodes in never.
func (rig *scrollRig) heldAnswer(what string, at world.Position, never ...uint16) {
	rig.t.Helper()
	stop, got := rig.readUntil(OpMovementStop, 2*time.Second)
	for _, p := range append(got, stop) {
		if p == nil {
			continue
		}
		for _, op := range never {
			if p.Opcode == op {
				rig.t.Fatalf("%s while held: got 0x%04x % x", what, op, p.Data)
			}
		}
	}
	if stop == nil {
		rig.t.Fatalf("%s while held: no 0xB023 answer", what)
	}
	ms, ok := DecodeMoveStop(stop.Data)
	if !ok || ms.UID != uint32(rig.charID) {
		rig.t.Fatalf("%s: 0xB023 %+v; want Aria's", what, ms)
	}
	if p, moving := rig.pos(); moving || p != at {
		rig.t.Fatalf("%s while held: the server has Aria at %+v (moving %v); want %+v standing", what, p, moving, at)
	}
}

// Every move kind is refused while a return scroll casts, and the character
// stays where the scroll stopped it; the cancel releases it.
func TestRound860ScrollHoldsMovement(t *testing.T) {
	rig := newScrollRig(t, 60)
	if res := rig.use(fixtureReturnScroll, 0, 0); res.Error != "" {
		t.Fatalf("use refused: %+v", res)
	}
	at, _ := rig.pos()

	// The click (0x7021): no echo, the mover put back.
	rig.click(200)
	rig.heldAnswer("a click", at, proto.OpMovementResponse)

	// The arrow keys: a turn (0x7024) is not relayed, a stop (0x7023) not taken.
	angle := binary.LittleEndian.AppendUint16(nil, 0x4000)
	rig.send(OpMovementTurnRequest, angle)
	rig.heldAnswer("an arrow turn", at, OpMovementTurn)
	rig.send(OpMovementStopRequest, angle)
	rig.heldAnswer("an arrow stop", at)

	// OpMove's walked position and stop (OURS' stream).
	rig.send(OpMove, (&MoveRequest{X: float32(at.X + 3), Y: float32(at.Y), Z: float32(at.Z)}).Encode())
	rig.heldAnswer("a walked position", at)
	rig.send(OpMove, (&MoveRequest{X: float32(at.X + 3), Y: float32(at.Y), Z: float32(at.Z), Stopped: true}).Encode())
	rig.heldAnswer("a stop report", at)

	// The action request: {3, 0x4004} (s:0x4acc40 with the refused flag).
	rig.send(OpCharacterActionRequest, encodeTraceRequest(1))
	resp, _ := rig.readUntil(OpCharacterActionResponse, 2*time.Second)
	if resp == nil {
		t.Fatal("no 0xB074 for a held action")
	}
	if ar, ok := DecodeActionResult(resp.Data); !ok || ar.Result != ActionResultError || ar.Code != ActionErrRefused {
		t.Fatalf("held action answered %+v; want {3, 0x4004}", ar)
	}
	if !rig.caster.Casting(rig.charID) {
		t.Fatal("a held request ended the cast")
	}

	// The cancel releases the hold: the next click walks.
	rig.send(OpScrollCancel, nil)
	if st := scrollStates(func() []*proto.Packet { _, got := rig.readUntil(0xffff, 300*time.Millisecond); return got }()); len(st) != 1 || st[0].Value != 0 {
		t.Fatalf("states after the cancel %+v; want one value 0", st)
	}
	rig.click(200)
	if echo, _ := rig.readUntil(proto.OpMovementResponse, 2*time.Second); echo == nil {
		t.Fatal("a click after the cancel was not accepted")
	}
	if _, moving := rig.pos(); !moving {
		t.Fatal("no leg after the cancel's click")
	}
}

// The reverse return scroll holds as the return scroll does (both state 1),
// and its end releases the character before the warp.
func TestRound860ReverseScrollHoldsUntilItEnds(t *testing.T) {
	rig := newScrollRig(t, 60)
	if res := rig.use(fixtureReverseScroll, ReverseOptionMap, 24); res.Error != "" {
		t.Fatalf("use refused: %+v", res)
	}
	at, _ := rig.pos()
	rig.click(200)
	rig.heldAnswer("a click", at, proto.OpMovementResponse)
	e, _ := rig.hub.EntityByCharacterID(rig.charID)
	rig.fire()
	rig.arrival()
	if scrollHolds(e.Session) {
		t.Fatal("still held after the cast ended")
	}
}

// Only state 1 is held: retail's group 11 has no record for 2 (the
// thief-den scrolls) or 3.
func TestRound860OnlyStateOneHolds(t *testing.T) {
	rig := newScrollRig(t, 60)
	e, _ := rig.hub.EntityByCharacterID(rig.charID)
	for _, v := range []byte{2, 3, ScrollHoldValue} {
		rig.caster.mu.Lock()
		rig.caster.casting[rig.charID] = &scrollCast{sess: e.Session, value: v}
		rig.caster.mu.Unlock()
		if got, want := scrollHolds(e.Session), v == ScrollHoldValue; got != want {
			t.Fatalf("state %d: held %v, want %v", v, got, want)
		}
	}
	rig.caster.mu.Lock()
	delete(rig.caster.casting, rig.charID)
	rig.caster.mu.Unlock()
	if scrollHolds(e.Session) {
		t.Fatal("held with no cast")
	}
}
