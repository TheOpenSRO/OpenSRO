package session

// Round 646's review: a walled caster's warp landing is ONE relocated move,
// to a point the server named (OURS, walls.go warpLandingAdmits). Wire-only,
// so it runs against 8b59288 (the round before the review), where any
// relocated move was taken for two minutes after any warp -- the negative.

import (
	"testing"
	"time"
)

// relocate sends one relocated OpMove from c and waits for the handler.
func relocate(t *testing.T, c *friendClient, x, y, z float32) {
	t.Helper()
	c.send(t, OpMove, (&MoveRequest{X: x, Y: y, Z: z, Relocated: true}).Encode())
	time.Sleep(150 * time.Millisecond)
}

func (w *replayWorld) ariaAt(t *testing.T) (float64, float64) {
	t.Helper()
	e, ok := w.hub.EntityByCharacterID(w.aria.id)
	if !ok {
		t.Fatal("Aria is not in the world")
	}
	return e.Pos.X, e.Pos.Z
}

// Under -single-frame a walled Aria goes to Donwhang and back to Jangan. Her
// client stands her on Jangan's spawn spot (local 1002,1020: (42, -60) in the
// one frame, ZONE_SPAWN_LOCAL) and reports it: taken. Before it, a
// relocation anywhere else is refused and does not use the landing up;
// after it, a second relocation -- even a step from the spot -- is refused.
func TestRound646ReviewTheLandingIsOneMoveToANamedPoint(t *testing.T) {
	SetSingleFrame(true)
	t.Cleanup(func() { SetSingleFrame(false) })
	w := startReplayWorld(t)
	w.enter(t, w.aria, "alice", "hunter2", "Aria")
	castSelf(t, w.aria, "Aria", 136)
	for _, zone := range []string{"donwhang", "jangan"} {
		w.aria.send(t, OpChangeZone, (&ChangeZoneRequest{Zone: zone}).Encode())
		if r, err := DecodeChangeZoneResult(w.aria.expect(t, OpChangeZoneResult).Data); err != nil || !r.OK {
			t.Fatalf("to %s: %+v %v", zone, r, err)
		}
	}
	drain(t, w.aria, 200*time.Millisecond)

	// Round 764: a zone change to Jangan lands her at its spawn spot itself
	// (changeZoneLanding), where her client stands her.
	relocate(t, w.aria, 900, 0, 900)
	if x, z := w.ariaAt(t); x != 42 || z != -60 {
		t.Errorf("a relocation to (900, 900), where no warp sent her, moved the walled Aria to (%g, %g)", x, z)
	}
	relocate(t, w.aria, 42, -32.6, -60)
	if x, z := w.ariaAt(t); x != 42 || z != -60 {
		t.Errorf("her landing on Jangan's spawn spot left her at (%g, %g), want (42, -60)", x, z)
	}
	relocate(t, w.aria, 60, -32.6, -60)
	if x, z := w.ariaAt(t); x != 42 || z != -60 {
		t.Errorf("a second relocation after the landing moved the walled Aria to (%g, %g): the landing is one move", x, z)
	}
	relocate(t, w.aria, 42, -32.6, -60)
	relocate(t, w.aria, 0, 0, 0)
	if x, z := w.ariaAt(t); x != 42 || z != -60 {
		t.Errorf("a relocation back to the arrival point after the landing moved her to (%g, %g)", x, z)
	}
}

// The landing goes with the wall: a warp while walled, the wall cancelled,
// the wall cast again -- the old landing is not taken under the new root.
func TestRound646ReviewTheLandingEndsWithTheWall(t *testing.T) {
	w := startReplayWorld(t)
	w.enter(t, w.aria, "alice", "hunter2", "Aria")
	wall := castSelf(t, w.aria, "Aria", 136)
	w.aria.send(t, OpChangeZone, (&ChangeZoneRequest{Zone: "donwhang"}).Encode())
	w.aria.expect(t, OpChangeZoneResult)
	w.aria.send(t, OpBuffCancel, (&BuffCancelRequest{CharacterName: "Aria", SkillID: 136, Token: wall.Token}).Encode())
	w.aria.expect(t, OpBuffEnd)
	// Unrooted, she walks away from the arrival point.
	w.aria.send(t, OpMove, (&MoveRequest{X: 300, Y: 0, Z: 300}).Encode())
	time.Sleep(150 * time.Millisecond)
	// The wall's 5 s re-use delay (walls640CSV) passes.
	time.Sleep(5100 * time.Millisecond)
	castSelf(t, w.aria, "Aria", 136)
	drain(t, w.aria, 100*time.Millisecond)
	relocate(t, w.aria, 0.5, 0, 0.5)
	if x, z := w.ariaAt(t); x != 300 || z != 300 {
		t.Errorf("a new wall's root took the old warp's landing: Aria at (%g, %g), want (300, 300)", x, z)
	}
}

// The landing goes with the logout: a walled Aria warps and relogs (her
// book, and the wall, end with the logout), casts the wall again, and a
// relocation to the old arrival point is refused.
func TestRound646ReviewTheLandingEndsWithTheLogout(t *testing.T) {
	w := startReplayWorld(t)
	w.enter(t, w.aria, "alice", "hunter2", "Aria")
	castSelf(t, w.aria, "Aria", 136)
	w.aria.send(t, OpChangeZone, (&ChangeZoneRequest{Zone: "donwhang"}).Encode())
	w.aria.expect(t, OpChangeZoneResult)
	w.aria.conn.Close()
	time.Sleep(150 * time.Millisecond)
	w.enter(t, w.aria, "alice", "hunter2", "Aria")
	w.aria.send(t, OpMove, (&MoveRequest{X: 300, Y: 0, Z: 300}).Encode())
	time.Sleep(150 * time.Millisecond)
	time.Sleep(5100 * time.Millisecond)
	castSelf(t, w.aria, "Aria", 136)
	drain(t, w.aria, 100*time.Millisecond)
	relocate(t, w.aria, 0.5, 0, 0.5)
	if x, z := w.ariaAt(t); x != 300 || z != 300 {
		t.Errorf("after a relog the old warp's landing was taken: Aria at (%g, %g), want (300, 300)", x, z)
	}
}
