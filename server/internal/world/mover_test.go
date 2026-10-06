package world

import (
	"math"
	"testing"
	"time"
)

// Round 749: the hub keeps each mover's leg and hands out the position the leg
// gives now (mover.go).

type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time      { return c.t }
func (c *fakeClock) add(d time.Duration) { c.t = c.t.Add(d) }
func clockedHub() (*Hub, *fakeClock) {
	c := &fakeClock{t: time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)}
	h := NewHub()
	h.SetClock(c.now)
	return h, c
}

func closeTo(a, b float64) bool { return math.Abs(a-b) < 1e-9 }

func TestMoverAtWalksAtItsSpeedAndStopsOnItsDestination(t *testing.T) {
	start := time.Date(2026, 10, 6, 0, 0, 0, 0, time.UTC)
	m := &Mover{Src: Position{X: 0, Y: 10, Z: 0}, Dest: Position{X: 30, Y: 40, Z: 40}, Start: start, Speed: 50, dist: 50}
	if p, arrived := m.At(start.Add(500 * time.Millisecond)); arrived || !closeTo(p.X, 15) || !closeTo(p.Z, 20) || !closeTo(p.Y, 25) {
		t.Fatalf("half a second in: %+v arrived=%v, want (15, 25, 20) on the way", p, arrived)
	}
	// READ (CGObjMoverByDest::vslot_003): never past the destination.
	if p, arrived := m.At(start.Add(5 * time.Second)); !arrived || p != m.Dest {
		t.Fatalf("five seconds in: %+v arrived=%v, want the destination", p, arrived)
	}
	if p, _ := m.At(start.Add(-time.Second)); p != m.Src {
		t.Fatalf("before the start: %+v, want the source", p)
	}
	if got := m.Travelled(start.Add(400 * time.Millisecond)); !closeTo(got, 20) {
		t.Fatalf("travelled %v, want 20", got)
	}
	run := &Mover{Src: Position{X: 1, Z: 1}, Heading: true, DirX: 1, DirZ: 0, Start: start, Speed: 10}
	if p, arrived := run.At(start.Add(100 * time.Second)); arrived || !closeTo(p.X, 1001) || !closeTo(p.Z, 1) {
		t.Fatalf("a heading run 100 s in: %+v arrived=%v, want x 1001 and no end", p, arrived)
	}
}

func TestMoverAlongMeasuresAPointAgainstTheLeg(t *testing.T) {
	m := &Mover{Src: Position{}, Dest: Position{X: 100}, Speed: 50, dist: 100}
	if along, off := m.Along(40, 3); !closeTo(along, 40) || !closeTo(off, 3) {
		t.Fatalf("(40, 3): along %v off %v, want 40 and 3", along, off)
	}
	if along, off := m.Along(-10, 0); along != 0 || !closeTo(off, 10) {
		t.Fatalf("behind the source: along %v off %v, want 0 and 10", along, off)
	}
	if along, off := m.Along(130, 0); !closeTo(along, 100) || !closeTo(off, 30) {
		t.Fatalf("past the destination: along %v off %v, want 100 and 30", along, off)
	}
}

func TestStartMoveGivesTheLegAndEveryCopyItsPositionNow(t *testing.T) {
	h, c := clockedHub()
	a, b := fakeSession(1), fakeSession(2)
	h.Enter(a, 100, "Aria", 1, "jangan", Position{})
	h.Enter(b, 200, "Bram", 1, "jangan", Position{X: 10})
	r, st := h.StartMove(a, MoveOrder{Dest: Position{X: 0, Z: 100}, Speed: 50})
	if st != MoveAccepted || r.Entity.Move == nil || r.Entity.Pos != (Position{}) {
		t.Fatalf("StartMove: %v %+v", st, r.Entity)
	}
	if len(r.Watchers) != 1 || r.Watchers[0].CharacterID != 200 {
		t.Fatalf("watchers %+v, want Bram", r.Watchers)
	}
	if !closeTo(r.Entity.Heading, 0) {
		t.Fatalf("heading %v, want 0 (toward +z)", r.Entity.Heading)
	}
	c.add(time.Second)
	for _, e := range []Entity{mustBySession(t, h, a), mustByChar(t, h, 100)} {
		if !closeTo(e.Pos.Z, 50) || e.Move == nil {
			t.Fatalf("one second in: %+v, want z 50 with the leg", e)
		}
	}
	if got := h.ViewOfCharacter(200); len(got) != 2 {
		t.Fatalf("Bram's view %d, want 2", len(got))
	}
	c.add(2 * time.Second)
	if e := mustBySession(t, h, a); e.Pos.Z != 100 || e.Move != nil {
		t.Fatalf("three seconds in: %+v, want arrived at z 100 with no leg", e)
	}
	// The left entity carries where the leg had it.
	left, _, _ := h.Leave(a)
	if left.Pos.Z != 100 || left.Move != nil {
		t.Fatalf("Leave: %+v", left)
	}
	if h.Moving() != 0 {
		t.Fatalf("%d movers after the leave", h.Moving())
	}
}

func TestStartMoveRefusesADestinationNearTheOneSet(t *testing.T) {
	h, c := clockedHub()
	a := fakeSession(1)
	h.Enter(a, 100, "Aria", 1, "jangan", Position{})
	if _, st := h.StartMove(a, MoveOrder{Dest: Position{X: 100}, Speed: 50}); st != MoveAccepted {
		t.Fatal(st)
	}
	c.add(500 * time.Millisecond)
	// READ (0xb45b28): within 5.0 of the destination set, while moving.
	if _, st := h.StartMove(a, MoveOrder{Dest: Position{X: 103, Z: 4}, Speed: 50}); st != MoveRefusedNear {
		t.Fatalf("a destination 5.0 from the set one: %v, want refused", st)
	}
	if _, st := h.StartMove(a, MoveOrder{Dest: Position{X: 106}, Speed: 50}); st != MoveAccepted {
		t.Fatalf("a destination 6 away: %v, want accepted", st)
	}
	e := mustBySession(t, h, a)
	if !closeTo(e.Move.Src.X, 25) {
		t.Fatalf("the new leg starts at %+v, want x 25 (where the old one had her)", e.Move.Src)
	}
	// Arrived: the same point is a new move.
	c.add(10 * time.Second)
	if _, st := h.StartMove(a, MoveOrder{Dest: Position{X: 104}, Speed: 50}); st != MoveAccepted {
		t.Fatalf("after arriving: %v, want accepted", st)
	}
	if _, st := h.StartMove(fakeSession(9), MoveOrder{Speed: 50}); st != MoveNotInWorld {
		t.Fatalf("a session not in the world: %v", st)
	}
}

func TestAdvanceMoversRefilesACrossingAndEndsAnArrival(t *testing.T) {
	h, c := clockedHub()
	a, b := fakeSession(1), fakeSession(2)
	h.Enter(a, 100, "Aria", 1, "jangan", Position{X: 10, Z: 10})
	// Bram stands four blocks east: out of Aria's 3 x 3 until she walks.
	h.Enter(b, 200, "Bram", 1, "jangan", Position{X: 4*320 + 10, Z: 10})
	if h.Sees(1, 2) {
		t.Fatal("setup: they see each other")
	}
	h.StartMove(a, MoveOrder{Dest: Position{X: 3*320 + 10, Z: 10}, Speed: 100})
	c.add(time.Second) // x 110: same block
	if out := h.AdvanceMovers(nil); len(out) != 0 {
		t.Fatalf("no crossing yet, got %d", len(out))
	}
	c.add(3 * time.Second) // x 410: block 1, Bram (block 4) still out of view
	out := h.AdvanceMovers(nil)
	if len(out) != 1 || len(out[0].Gained) != 0 {
		t.Fatalf("x 410: %+v", out)
	}
	c.add(6 * time.Second) // x 970: block 3, Bram in view
	out = h.AdvanceMovers(nil)
	if len(out) != 1 || len(out[0].Gained) != 1 || out[0].Gained[0].CharacterID != 200 {
		t.Fatalf("x 970: %+v", out)
	}
	if !h.Sees(1, 2) || h.Moving() != 0 {
		t.Fatalf("after the arrival: sees %v movers %d", h.Sees(1, 2), h.Moving())
	}
}

func TestAdvanceMoversRebasesAChangedSpeed(t *testing.T) {
	h, c := clockedHub()
	a := fakeSession(1)
	h.Enter(a, 100, "Aria", 1, "jangan", Position{})
	h.StartMove(a, MoveOrder{Dest: Position{X: 200}, Speed: 50})
	c.add(time.Second)
	h.AdvanceMovers(func(int64) float64 { return 100 })
	c.add(time.Second)
	if e := mustBySession(t, h, a); !closeTo(e.Pos.X, 150) {
		t.Fatalf("50 then 100 a second: x %v, want 150", e.Pos.X)
	}
	h.AdvanceMovers(func(int64) float64 { return 25 })
	c.add(time.Second)
	if e := mustBySession(t, h, a); !closeTo(e.Pos.X, 175) {
		t.Fatalf("then 25: x %v, want 175", e.Pos.X)
	}
}

func TestStopAtAdmitsOrLeavesTheLeg(t *testing.T) {
	h, c := clockedHub()
	a := fakeSession(1)
	h.Enter(a, 100, "Aria", 1, "jangan", Position{})
	h.StartMove(a, MoveOrder{Dest: Position{X: 100}, Speed: 50})
	c.add(time.Second)
	var seen Entity
	_, admitted, ok := h.StopAt(a, Position{X: 30}, MoveRelocate, 0, func(_ time.Time, cur Entity) bool {
		seen = cur
		return false
	})
	if !ok || admitted || !closeTo(seen.Pos.X, 50) || seen.Move == nil {
		t.Fatalf("refused stop: ok %v admitted %v, admit saw %+v", ok, admitted, seen)
	}
	if e := mustBySession(t, h, a); e.Move == nil {
		t.Fatal("a refused stop ended the leg")
	}
	r, admitted, _ := h.StopAt(a, Position{X: 30}, MoveRelocate, 0, func(time.Time, Entity) bool { return true })
	if !admitted || r.Entity.Pos.X != 30 || r.Entity.Move != nil || h.Moving() != 0 {
		t.Fatalf("admitted stop: %+v, movers %d", r.Entity, h.Moving())
	}
	// A relocation ends a leg too.
	h.StartMove(a, MoveOrder{Dest: Position{X: 100}, Speed: 50})
	h.Relocate(a, Position{X: 7}, MoveRelocate, 0)
	if e := mustBySession(t, h, a); e.Move != nil || e.Pos.X != 7 || h.Moving() != 0 {
		t.Fatalf("after a relocation: %+v", e)
	}
	// Halt ends one where it is now.
	h.StartMove(a, MoveOrder{Dest: Position{X: 107}, Speed: 50})
	c.add(time.Second)
	r, moved, ok := h.Halt(a)
	if !ok || !moved || !closeTo(r.Entity.Pos.X, 57) || r.Entity.Move != nil {
		t.Fatalf("Halt: %+v moved %v", r.Entity, moved)
	}
	if _, moved, _ := h.Halt(a); moved {
		t.Fatal("a second Halt had a leg")
	}
}

func TestAHeadingRunFacesItsHeading(t *testing.T) {
	h, c := clockedHub()
	a := fakeSession(1)
	h.Enter(a, 100, "Aria", 1, "jangan", Position{})
	r, st := h.StartMove(a, MoveOrder{Heading: true, HeadingRadians: math.Pi / 2, Command: 1, WireAngle: 0, Speed: 50})
	if st != MoveAccepted || !closeTo(r.Entity.Heading, math.Pi/2) || !r.Entity.Move.Heading {
		t.Fatalf("%v %+v", st, r.Entity)
	}
	c.add(2 * time.Second)
	// Heading pi/2 faces +x in OpenSRO's frame (heading.go).
	if e := mustBySession(t, h, a); !closeTo(e.Pos.X, 100) || math.Abs(e.Pos.Z) > 1e-9 {
		t.Fatalf("two seconds of the run: %+v", e.Pos)
	}
}

func mustBySession(t *testing.T, h *Hub, s interface{ ID() uint64 }) Entity {
	t.Helper()
	e, ok := h.EntityBySession(s.ID())
	if !ok {
		t.Fatal("not in the world")
	}
	return e
}

func mustByChar(t *testing.T, h *Hub, id int64) Entity {
	t.Helper()
	e, ok := h.EntityByCharacterID(id)
	if !ok {
		t.Fatal("not in the world")
	}
	return e
}
