package session

import (
	"testing"
)

// Round 637's review follow-up: the arrival faces the way the character last
// walked, and a relocation is relayed as one and turns nothing. Since round
// 737 the arrival is retail's spawn record, whose u16 angle (pcspawn,
// FUN_009c3a70's) carries the heading where OpEntityEntered's trailing wire
// angle did.

func TestArrivalFacesTheLastWalk(t *testing.T) {
	f := startDeadWorldFixture(t)
	// Bram goes ahead to donwhang; Aria hears him leave.
	if czr := changeZone(t, f, f.connB, f.rB, "donwhang"); !czr.OK {
		t.Fatalf("Bram's change to donwhang refused: %+v", czr)
	}
	expectPlayerDespawn(t, f.connA, f.rA, f.bram)
	// Aria walks, last toward -z: heading pi, wire angle pi/2 = 16384.
	f.send(t, f.connA, OpMove, (&MoveRequest{X: 100, Y: 0, Z: 200}).Encode())
	f.send(t, f.connA, OpMove, (&MoveRequest{X: 100, Y: 0, Z: 190}).Encode())
	if czr := changeZone(t, f, f.connA, f.rA, "donwhang"); !czr.OK {
		t.Fatalf("Aria's change to donwhang refused: %+v", czr)
	}
	if got := expectPlayerSpawn(t, f.connB, f.rB, f.aria)[0].Angle; got != 16384 {
		t.Errorf("the arrival's wire angle is %d, want 16384 (heading pi, the last walk toward -z)", got)
	}
}

func TestRelocationIsRelayedAndKeepsTheHeading(t *testing.T) {
	f := startDeadWorldFixture(t)
	// Aria walks toward +x (heading pi/2, wire angle 0) ...
	f.send(t, f.connA, OpMove, (&MoveRequest{X: 100, Y: 0, Z: 200}).Encode())
	f.send(t, f.connA, OpMove, (&MoveRequest{X: 110, Y: 0, Z: 200}).Encode())
	for i := 0; i < 2; i++ {
		if p := f.read(t, f.connB, f.rB); p.Opcode != OpEntityMoved || len(p.Data) != 20 {
			t.Fatalf("walk %d reached Bram as %#04x of %d bytes, want OpEntityMoved of 20 (no flag on a walk)", i, p.Opcode, len(p.Data))
		}
	}
	// ... then is put 400 units toward -z: the flags byte, bit 0.
	relocated := append((&MoveRequest{X: 110, Y: 0, Z: -200}).Encode()[:12], 1)
	f.send(t, f.connA, OpMove, relocated)
	p := f.read(t, f.connB, f.rB)
	if p.Opcode != OpEntityMoved {
		t.Fatalf("the relocation reached Bram as %#04x, want OpEntityMoved", p.Opcode)
	}
	if len(p.Data) != 21 || p.Data[20]&1 == 0 {
		t.Errorf("the relocation is relayed as %d bytes (last %#x), want 21 with the relocated flag", len(p.Data), p.Data[len(p.Data)-1])
	}
	if m, err := DecodeEntityMoved(p.Data); err != nil || m.X != 110 || m.Z != -200 {
		t.Errorf("an older decoder reads the flagged move as %+v, %v", m, err)
	}
	// The heading is still the walk's: Bram goes on, Aria follows.
	if czr := changeZone(t, f, f.connB, f.rB, "donwhang"); !czr.OK {
		t.Fatalf("Bram's change refused: %+v", czr)
	}
	expectPlayerDespawn(t, f.connA, f.rA, f.bram)
	if czr := changeZone(t, f, f.connA, f.rA, "donwhang"); !czr.OK {
		t.Fatalf("Aria's change refused: %+v", czr)
	}
	if got := expectPlayerSpawn(t, f.connB, f.rB, f.aria)[0].Angle; got != 0 {
		t.Errorf("after the relocation the wire angle is %d, want 0 (heading pi/2 kept from the walk, not pi toward the jump)", got)
	}
}

// The arrivals (round 637's review follow-up, "headings in the arrival
// lists"): someone arriving where a character already stands sees it facing
// the way it last walked. Since round 737 that is the group spawn's record of
// Aria: wire angle 16384 for heading pi (her last walk toward -z).
func TestArrivalListCarriesTheHeadingsOfThoseStanding(t *testing.T) {
	f := startDeadWorldFixture(t)
	f.send(t, f.connA, OpMove, (&MoveRequest{X: 100, Y: 0, Z: 200}).Encode())
	f.send(t, f.connA, OpMove, (&MoveRequest{X: 100, Y: 0, Z: 190}).Encode())
	for i := 0; i < 2; i++ { // both walks are in the hub once Bram has heard them
		if p := f.read(t, f.connB, f.rB); p.Opcode != OpEntityMoved {
			t.Fatalf("Bram's packet %d is %#04x, want OpEntityMoved", i, p.Opcode)
		}
	}
	if czr := changeZone(t, f, f.connB, f.rB, "donwhang"); !czr.OK {
		t.Fatalf("Bram's change to donwhang refused: %+v", czr)
	}
	if czr := changeZone(t, f, f.connB, f.rB, "jangan"); !czr.OK || len(czr.Others) != 0 {
		t.Fatalf("Bram's change back: %+v; want OK with no list", czr)
	}
	if got := expectPlayerSpawn(t, f.connB, f.rB, f.aria)[0].Angle; got != 16384 {
		t.Errorf("Bram's spawn of Aria faces wire angle %d, want 16384 (heading pi)", got)
	}
}
