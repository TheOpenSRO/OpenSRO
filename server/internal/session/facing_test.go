package session

import (
	"encoding/binary"
	"testing"
)

// Round 637's review follow-up: the arrival faces the way the character last
// walked (OpEntityEntered's trailing wire angle), and a relocation is relayed
// as one and turns nothing.
//
// Written against the payloads as bytes, through decoders dev 5a82339 already
// had, so the same test runs -- and fails -- there (the round's negative).

// enteredTail reads OpEntityEntered's payload the way an older client does
// (one snapshot) and returns what follows it.
func enteredTail(t *testing.T, data []byte) []byte {
	t.Helper()
	_, rest, err := decodeEntitySnapshot(data)
	if err != nil {
		t.Fatalf("an older decoder cannot read the OpEntityEntered payload: %v", err)
	}
	return rest
}

func TestArrivalFacesTheLastWalk(t *testing.T) {
	f := startDeadWorldFixture(t)
	// Bram goes ahead to donwhang; Aria hears him leave.
	if czr := changeZone(t, f, f.connB, f.rB, "donwhang"); !czr.OK {
		t.Fatalf("Bram's change to donwhang refused: %+v", czr)
	}
	if p := f.read(t, f.connA, f.rA); p.Opcode != OpEntityLeft {
		t.Fatalf("Aria's packet after Bram left is %#04x, want OpEntityLeft", p.Opcode)
	}
	// Aria walks, last toward -z: heading pi, wire angle pi/2 = 16384.
	f.send(t, f.connA, OpMove, (&MoveRequest{X: 100, Y: 0, Z: 200}).Encode())
	f.send(t, f.connA, OpMove, (&MoveRequest{X: 100, Y: 0, Z: 190}).Encode())
	if czr := changeZone(t, f, f.connA, f.rA, "donwhang"); !czr.OK {
		t.Fatalf("Aria's change to donwhang refused: %+v", czr)
	}
	p := f.read(t, f.connB, f.rB)
	if p.Opcode != OpEntityEntered {
		t.Fatalf("Bram's packet after Aria arrived is %#04x, want OpEntityEntered", p.Opcode)
	}
	tail := enteredTail(t, p.Data)
	if len(tail) != 2 {
		t.Fatalf("OpEntityEntered carries %d byte(s) after the snapshot, want the 2-byte wire angle", len(tail))
	}
	if got := binary.LittleEndian.Uint16(tail); got != 16384 {
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
	if p := f.read(t, f.connA, f.rA); p.Opcode != OpEntityLeft {
		t.Fatalf("Aria's packet after Bram left is %#04x, want OpEntityLeft", p.Opcode)
	}
	if czr := changeZone(t, f, f.connA, f.rA, "donwhang"); !czr.OK {
		t.Fatalf("Aria's change refused: %+v", czr)
	}
	p = f.read(t, f.connB, f.rB)
	if p.Opcode != OpEntityEntered {
		t.Fatalf("Bram's packet after Aria arrived is %#04x, want OpEntityEntered", p.Opcode)
	}
	tail := enteredTail(t, p.Data)
	if len(tail) != 2 {
		t.Fatalf("OpEntityEntered carries %d byte(s) after the snapshot, want 2", len(tail))
	}
	if got := binary.LittleEndian.Uint16(tail); got != 0 {
		t.Errorf("after the relocation the wire angle is %d, want 0 (heading pi/2 kept from the walk, not pi toward the jump)", got)
	}
}
