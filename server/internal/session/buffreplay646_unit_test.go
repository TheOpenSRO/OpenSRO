package session

// Round 646's tests of the warp landing's own helpers (walls.go): they name
// what the round adds, so they are kept out of buffreplay646_test.go, whose
// wire tests run against the base (dev 8658370) for the negative.

import (
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
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
	if warpLandingAdmits(w.aria.id, true, float64(before.Pos.X)+30, 0, time.Now()) {
		t.Error("a rooted caster that never warped has a landing grace")
	}
}

func TestRound646WarpLandingGrace(t *testing.T) {
	const id int64 = 646646
	now := time.Now()
	buffBooks.EndAll(id)
	noteWarpLanding(id, now, [2]float64{0, 0}) // no wall: nothing noted
	if warpLandingAdmits(id, true, 0, 0, now) {
		t.Fatal("a warp with no wall noted a landing")
	}
	arm := func() {
		warpLandings.Store(id, &warpLanding{points: [][2]float64{{100, -200}}, deadline: now.Add(warpLandingGrace)})
	}
	arm()
	t.Cleanup(func() { warpLandings.Delete(id) })
	if warpLandingAdmits(id, false, 100, -200, now) {
		t.Error("a walk was taken as a landing")
	}
	if warpLandingAdmits(id, true, 100+warpLandingTolerance+0.5, -200, now) {
		t.Error("a relocation past the tolerance on x was taken")
	}
	if warpLandingAdmits(id, true, 100, -200-warpLandingTolerance-0.5, now) {
		t.Error("a relocation past the tolerance on z was taken")
	}
	if !warpLandingAdmits(id, true, 100.4, -199.6, now.Add(warpLandingGrace-time.Second)) {
		t.Error("the landing inside the grace and the tolerance was not taken")
	}
	if warpLandingAdmits(id, true, 100, -200, now) {
		t.Error("a second relocation to the same point was taken: the landing is one move")
	}
	arm()
	if warpLandingAdmits(id, true, 100, -200, now.Add(warpLandingGrace+time.Second)) {
		t.Error("a relocation after the grace was taken")
	}
	if _, ok := warpLandings.Load(id); ok {
		t.Error("an expired landing was kept")
	}
}

// Round 646's review: the spawn spot the client stands a Jangan arrival on
// (World3D.ZONE_SPAWN_LOCAL, local 1002,1020 of 97/168) named from the
// server's landing, in Jangan's frame and in another.
func TestRound646LandingSpotFor(t *testing.T) {
	x, z, ok := worldmap.LandingSpotFor("jangan", 0, 0)
	if !ok || x != 42 || z != -60 {
		t.Fatalf("Jangan's spot from its landing (0, 0): (%g, %g, %v), want (42, -60): local 1002,1020 against the middle 960,960, z mirrored", x, z, ok)
	}
	lx, lz, _ := worldmap.Landing("jangan", 102, 153)
	x, z, ok = worldmap.LandingSpotFor("jangan", lx, lz)
	wx, wz := worldmap.ToWorld(97, 168, 1002, 1020, 102, 153)
	if !ok || x != wx || z != wz {
		t.Fatalf("Jangan's spot in Donwhang's frame: (%g, %g), want ToWorld's (%g, %g)", x, z, wx, wz)
	}
	if _, _, ok := worldmap.LandingSpotFor("donwhang", 0, 0); ok {
		t.Error("Donwhang has a spot, but the client has none for it")
	}
}
