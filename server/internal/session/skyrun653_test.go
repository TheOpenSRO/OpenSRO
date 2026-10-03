package session

import (
	"math"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// Round 653: a position sent on a heading run (the sky click, client SkyRun)
// carries retail's heading form of 0x7021 after the flags byte (bit 1): kind
// 0, the command byte, the u16 wire angle. The codec round-trips it, a plain
// walk is still the old 12 bytes, and proto.DecodeMovement reads the tail
// as the heading form.
func TestRound653MoveRequestCarriesTheHeadingForm(t *testing.T) {
	req := &MoveRequest{X: 1, Y: 2, Z: 3, Run: true, RunCommand: proto.MovementCommandForward, RunAngle: 0x4000}
	enc := req.Encode()
	if len(enc) != 12+1+4 {
		t.Fatalf("a run's MoveRequest is %d bytes, want 12 + flags + the 4-byte heading form", len(enc))
	}
	if enc[12] != moveFlagRun {
		t.Fatalf("the flags byte is %#x, want bit 1 alone", enc[12])
	}
	m, angle, err := proto.DecodeMovement(enc[13:], false)
	if err != nil || m.Kind != proto.MovementKindHeading || m.HeadingByte != 1 || angle != 0x4000 {
		t.Fatalf("the tail is not retail's heading form: %+v angle %#x, %v (% x)", m, angle, err, enc[13:])
	}
	got, err := DecodeMoveRequest(enc)
	if err != nil || !got.Run || got.RunCommand != 1 || got.RunAngle != 0x4000 || got.Relocated || got.X != 1 {
		t.Fatalf("round trip gave %+v, %v", got, err)
	}
	if n := len((&MoveRequest{X: 1}).Encode()); n != 12 {
		t.Fatalf("a walk's MoveRequest is %d bytes, want the old 12", n)
	}
	// A run flag with a short or wrong-kind form is no run; the position stands.
	for _, tail := range [][]byte{{moveFlagRun}, {moveFlagRun, 0, 1}, {moveFlagRun, 1, 0, 0, 0, 0, 0, 0, 0}} {
		bad := append(append([]byte{}, enc[:12]...), tail...)
		got, err := DecodeMoveRequest(bad)
		if err != nil || got.Run || got.X != 1 {
			t.Errorf("tail % x decoded %+v, %v; want a plain position", tail, got, err)
		}
	}
	// Relocated and run together keep both bits.
	both, _ := DecodeMoveRequest((&MoveRequest{Relocated: true, Run: true, RunCommand: 1, RunAngle: 7}).Encode())
	if !both.Relocated || !both.Run || both.RunAngle != 7 {
		t.Fatalf("both flags: %+v", both)
	}
	em, err := DecodeEntityMoved((&EntityMoved{CharacterID: 9, X: 4, Run: true, RunCommand: 1, RunAngle: 0xbeef}).Encode())
	if err != nil || !em.Run || em.RunAngle != 0xbeef || em.CharacterID != 9 || em.X != 4 {
		t.Fatalf("EntityMoved round trip: %+v, %v", em, err)
	}
	if n := len((&EntityMoved{CharacterID: 9}).Encode()); n != 20 {
		t.Fatalf("a walk's EntityMoved is %d bytes, want the old 20", n)
	}
}

// HeadingFromWire is the client's reading of a u16 (FUN_008a5640 +
// FUN_009c40b0) and inverts WireAngle through EncodeMovementAngle.
func TestRound653HeadingFromWireInvertsWireAngle(t *testing.T) {
	for _, h := range []float64{0, 0.3, math.Pi / 2, math.Pi, 4, 2*math.Pi - 0.01} {
		a := proto.EncodeMovementAngle(world.WireAngle(h))
		back := world.HeadingFromWire(a)
		d := math.Abs(back - h)
		if d > math.Pi {
			d = 2*math.Pi - d
		}
		if d > 1e-3 {
			t.Errorf("heading %v -> wire %d -> %v", h, a, back)
		}
	}
}

// The flow: Aria's client runs on a heading and sends positions with the
// heading form. The hub faces her the run's heading -- NOT the way the step
// went -- and Bram hears each position with the same heading form, so his
// client faces her the run's way. The stop is a plain position, relayed
// plain: the run is over.
func TestRound653AHeadingRunIsRelayedWithItsHeading(t *testing.T) {
	w := startReplayWorld(t)
	w.enter(t, w.bram, "bob", "hunter3", "Bram")
	w.enter(t, w.aria, "alice", "hunter2", "Aria")
	drain(t, w.aria, 200*time.Millisecond)
	drain(t, w.bram, 200*time.Millisecond)

	e0, _ := w.hub.EntityByCharacterID(w.aria.id)
	// The run faces +x (heading pi/2); the step itself goes toward +z, so a
	// heading taken from the step (MoveFacing) would be 0, not pi/2.
	wire := proto.EncodeMovementAngle(world.WireAngle(math.Pi / 2))
	w.aria.send(t, OpMove, (&MoveRequest{X: float32(e0.Pos.X), Y: 0, Z: float32(e0.Pos.Z) + 20,
		Run: true, RunCommand: proto.MovementCommandForward, RunAngle: wire}).Encode())
	time.Sleep(150 * time.Millisecond)
	e, ok := w.hub.EntityByCharacterID(w.aria.id)
	if !ok {
		t.Fatal("Aria is not in the world")
	}
	if math.Abs(e.Heading-math.Pi/2) > 1e-3 {
		t.Errorf("on the run Aria faces %v, want the run's pi/2 (the step alone says 0)", e.Heading)
	}
	bGot := drain(t, w.bram, 200*time.Millisecond)
	i := indexOf(bGot, OpEntityMoved)
	if i < 0 {
		t.Fatal("Bram did not hear Aria's run")
	}
	em, err := DecodeEntityMoved(bGot[i].Data)
	if err != nil || !em.Run || em.RunAngle != wire || em.RunCommand != 1 || em.Relocated {
		t.Fatalf("Bram heard %+v, %v; want the run's heading form (angle %d)", em, err, wire)
	}

	// The stop at the wall: a plain position, relayed plain.
	w.aria.send(t, OpMove, (&MoveRequest{X: float32(e0.Pos.X) + 5, Y: 0, Z: float32(e0.Pos.Z) + 20}).Encode())
	time.Sleep(150 * time.Millisecond)
	bGot = drain(t, w.bram, 200*time.Millisecond)
	i = indexOf(bGot, OpEntityMoved)
	if i < 0 {
		t.Fatal("Bram did not hear Aria's stop")
	}
	if em, err := DecodeEntityMoved(bGot[i].Data); err != nil || em.Run || em.X != float32(e0.Pos.X)+5 {
		t.Fatalf("Bram heard the stop as %+v, %v; want a plain position", em, err)
	}
}
