package session

// Round 646's tests of the warp landing's own helpers (walls.go): they name
// what the round adds, so they are kept out of buffreplay646_test.go, whose
// wire tests run against the base (dev 8658370) for the negative.

import (
	"testing"
	"time"
)

func clearWarpLanding(id int64) { warpLandings.Delete(id) }

// With no warp, a relocated move is still the root's to drop: the landing is
// a warp's alone.
func TestRound646ARelocationWithoutAWarpIsStillRooted(t *testing.T) {
	w := startReplayWorld(t)
	w.enter(t, w.aria, "alice", "hunter2", "Aria")
	castSelf(t, w.aria, "Aria", 136)
	before, _ := w.hub.EntityByCharacterID(w.aria.id)
	w.aria.send(t, OpMove, (&MoveRequest{X: float32(before.Pos.X) + 30, Y: 0, Z: 0, Relocated: true}).Encode())
	if _, err := DecodeSkillMove(w.aria.expect(t, OpSkillMove).Data); err != nil {
		t.Fatal(err)
	}
	if e, _ := w.hub.EntityByCharacterID(w.aria.id); e.Pos != before.Pos {
		t.Errorf("a relocation with no warp moved the walled Aria from %+v to %+v", before.Pos, e.Pos)
	}
	// The grace is a warp's: a landing noted while no wall stood admits
	// nothing either.
	if warpLandingAdmits(w.aria.id, true, time.Now()) {
		t.Error("a rooted caster that never warped has a landing grace")
	}
}

func TestRound646WarpLandingGrace(t *testing.T) {
	const id int64 = 646646
	now := time.Now()
	buffBooks.EndAll(id)
	noteWarpLanding(id, now) // no wall: nothing noted
	if warpLandingAdmits(id, true, now) {
		t.Fatal("a warp with no wall noted a landing")
	}
	warpLandings.Store(id, now.Add(warpLandingGrace))
	t.Cleanup(func() { warpLandings.Delete(id) })
	if warpLandingAdmits(id, false, now) {
		t.Error("a walk was taken as a landing")
	}
	if !warpLandingAdmits(id, true, now.Add(warpLandingGrace-time.Second)) {
		t.Error("a relocation inside the grace was not taken")
	}
	if warpLandingAdmits(id, true, now.Add(warpLandingGrace+time.Second)) {
		t.Error("a relocation after the grace was taken")
	}
}
