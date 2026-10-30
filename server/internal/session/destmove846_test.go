package session

import (
	"math"
	"sync/atomic"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 846 (the user: "if I take small steps it doesn't register on another
// client ... It only registers when I take a large step and it shows that I
// teleported away", "it only seems to happen at a higher /speed"). The server
// half: every step -- one unit or forty, at the base speed or a GM /speed of
// ten -- that reaches the server once the last leg is over is taken and
// echoed to the window, starting where the last one ended; the speed it is
// walked at is the one the window was told (/speed's token-less OpBuffEnd, sendSpeed);
// and a step within 5.0 of a destination still being walked is refused, as
// retail's handler refuses it (READ 0xb45b28) -- which is why the client
// holds such a step until the server's leg is over (MoveOrderSync.held).
func TestRound846EveryStepIsEchoedAtAnySpeed(t *testing.T) {
	strictPositions(t)
	f := startDeadWorldFixture(t)
	var now atomic.Int64
	now.Store(time.Now().UnixNano())
	f.hub.SetClock(func() time.Time { return time.Unix(0, now.Load()) })
	t.Cleanup(func() { f.hub.SetClock(nil); buffBooks.SetGMSpeedFactor(f.aria, 1) })
	at := world.Position{}
	for _, factor := range []float64{1, 2, 5, 10} {
		run := gmSpeed{hub: f.hub}.SetGMSpeed(f.aria, factor)
		want := uint32(math.Round(float64(PlayerRunSpeed) * factor))
		if run != want {
			t.Fatalf("/speed %v: run speed %d, want %d", factor, run, want)
		}
		// Bram is told the speed Aria now walks at (sendSpeed: a token-less
		// OpBuffEnd to the zone), so his client walks her legs at it.
		if factor != 1 {
			p, _ := readOp(t, f, f.connB, f.rB, OpBuffEnd)
			be, err := DecodeBuffEnd(p.Data)
			if err != nil || be.OwnerID != f.aria || be.RunSpeed != want {
				t.Fatalf("/speed %v: Bram's speed message %+v (%v), want owner %d speed %d", factor, be, err, f.aria, want)
			}
		}
		readOp(t, f, f.connA, f.rA, OpBuffEnd)
		for _, step := range []float64{1, 2, 3, 4.9, 40} {
			dest := world.Position{X: math.Trunc(at.X + step), Z: at.Z}
			f.send(t, f.connA, proto.OpMovementRequest, clickTo(dest.X, 0, dest.Z))
			p, _ := readOp(t, f, f.connB, f.rB, proto.OpMovementResponse)
			readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
			e, ok := DecodeMoveEcho(p.Data)
			if !ok || int64(e.UID) != f.aria {
				t.Fatalf("/speed %v, a %v step: the window's echo %+v", factor, step, e)
			}
			sx, sz := worldOfRegionLocal(spawnZone, e.SrcRegion, float64(e.SrcX)/10, float64(e.SrcZ)/10)
			if math.Abs(sx-at.X) > 0.1 || math.Abs(sz-at.Z) > 0.1 {
				t.Fatalf("/speed %v, a %v step: the echo's source (%.2f, %.2f), want where the last step ended (%.2f, %.2f)", factor, step, sx, sz, at.X, at.Z)
			}
			ent, _ := f.hub.EntityByCharacterID(f.aria)
			if ent.Move == nil || ent.Move.Speed != float64(want) {
				t.Fatalf("/speed %v, a %v step: the hub walks the leg at %+v, want %d", factor, step, ent.Move, want)
			}
			// The leg's time, and the next step comes a frame after it.
			legMs := math.Abs(dest.X-at.X) / float64(want) * 1000
			now.Add(int64(time.Duration(legMs*float64(time.Millisecond)) + 16*time.Millisecond))
			if ent, _ := f.hub.EntityByCharacterID(f.aria); ent.Move != nil || math.Abs(ent.Pos.X-dest.X) > 1e-6 {
				t.Fatalf("/speed %v, a %v step: after the leg Aria is at %+v (leg %v), want %v", factor, step, ent.Pos, ent.Move, dest)
			}
			at = dest
		}
	}
	// READ (0xb45b28): while the leg runs, a destination within 5.0 of its
	// own is refused, silently.
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(at.X+100, 0, at.Z))
	readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
	readOp(t, f, f.connB, f.rB, proto.OpMovementResponse)
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(at.X+103, 0, at.Z))
	if !f.nothing(t, f.connA, f.rA) || !f.nothing(t, f.connB, f.rB) {
		t.Fatal("a step within 5.0 of the destination being walked was taken")
	}
}
