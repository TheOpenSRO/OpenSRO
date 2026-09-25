package world

import (
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/gateway"
)

// fakeSession returns a *gateway.Session usable only for its ID() in these
// tests — Hub's logic never calls Send/RemoteAddr on the entities it holds.
func fakeSession(id uint64) *gateway.Session {
	return gateway.NewTestSession(id)
}

func TestEnterReturnsExistingOccupants(t *testing.T) {
	h := NewHub()
	s1, s2 := fakeSession(1), fakeSession(2)

	others := h.Enter(s1, 100, "Aria", 1, "jangan", Position{X: 1, Y: 2, Z: 3})
	if len(others) != 0 {
		t.Fatalf("first entrant should see nobody else, got %+v", others)
	}

	others = h.Enter(s2, 200, "Bram", 1, "jangan", Position{})
	if len(others) != 1 || others[0].Name != "Aria" {
		t.Fatalf("second entrant should see Aria, got %+v", others)
	}
}

func TestEnterIsolatesZones(t *testing.T) {
	h := NewHub()
	s1, s2 := fakeSession(1), fakeSession(2)

	h.Enter(s1, 100, "Aria", 1, "jangan", Position{})
	others := h.Enter(s2, 200, "Bram", 1, "donwhang", Position{})
	if len(others) != 0 {
		t.Fatalf("different zone should see nobody, got %+v", others)
	}
}

func TestMoveUpdatesPositionAndReturnsOthers(t *testing.T) {
	h := NewHub()
	s1, s2 := fakeSession(1), fakeSession(2)
	h.Enter(s1, 100, "Aria", 1, "jangan", Position{})
	h.Enter(s2, 200, "Bram", 1, "jangan", Position{})

	entity, others, ok := h.Move(s1, Position{X: 5, Y: 6, Z: 7})
	if !ok {
		t.Fatal("Move should succeed for an entered session")
	}
	if entity.Pos != (Position{X: 5, Y: 6, Z: 7}) {
		t.Fatalf("got position %+v, want {5 6 7}", entity.Pos)
	}
	if len(others) != 1 || others[0].Name != "Bram" {
		t.Fatalf("expected to see Bram as the other occupant, got %+v", others)
	}
}

func TestMoveUnknownSessionFails(t *testing.T) {
	h := NewHub()
	_, _, ok := h.Move(fakeSession(99), Position{})
	if ok {
		t.Fatal("expected Move to fail for a session that never entered")
	}
}

func TestLeaveRemovesAndReturnsRemaining(t *testing.T) {
	h := NewHub()
	s1, s2 := fakeSession(1), fakeSession(2)
	h.Enter(s1, 100, "Aria", 1, "jangan", Position{})
	h.Enter(s2, 200, "Bram", 1, "jangan", Position{})

	left, remaining, ok := h.Leave(s1)
	if !ok || left.Zone != "jangan" || left.Name != "Aria" {
		t.Fatalf("got left=%+v ok=%v, want zone=jangan name=Aria", left, ok)
	}
	if len(remaining) != 1 || remaining[0].Name != "Bram" {
		t.Fatalf("expected Bram to remain, got %+v", remaining)
	}

	// s1 should no longer be movable/found.
	if _, _, ok := h.Move(s1, Position{}); ok {
		t.Fatal("expected s1 to be gone after Leave")
	}
}

func TestLeaveUnknownSessionFails(t *testing.T) {
	h := NewHub()
	_, _, ok := h.Leave(fakeSession(99))
	if ok {
		t.Fatal("expected Leave to fail for a session that never entered")
	}
}

func TestEntitiesInZoneIncludesEveryone(t *testing.T) {
	h := NewHub()
	s1, s2, s3 := fakeSession(1), fakeSession(2), fakeSession(3)
	h.Enter(s1, 100, "Aria", 1, "jangan", Position{})
	h.Enter(s2, 200, "Bram", 1, "jangan", Position{})
	h.Enter(s3, 300, "Cora", 1, "donwhang", Position{})

	entities := h.EntitiesInZone("jangan")
	if len(entities) != 2 {
		t.Fatalf("got %d entities, want 2 (Aria and Bram)", len(entities))
	}

	names := map[string]bool{}
	for _, e := range entities {
		names[e.Name] = true
	}
	if !names["Aria"] || !names["Bram"] {
		t.Fatalf("expected both Aria and Bram, got %+v", entities)
	}
}

func TestEntitiesInZoneEmptyForUnknownZone(t *testing.T) {
	h := NewHub()
	if entities := h.EntitiesInZone("nowhere"); len(entities) != 0 {
		t.Fatalf("expected no entities for an unknown zone, got %+v", entities)
	}
}

func TestReenterMovesRatherThanDuplicates(t *testing.T) {
	h := NewHub()
	s1 := fakeSession(1)
	h.Enter(s1, 100, "Aria", 1, "jangan", Position{})
	h.Enter(s1, 100, "Aria", 1, "donwhang", Position{}) // re-enter, different zone

	_, remaining, ok := h.Leave(s1)
	if !ok {
		t.Fatal("expected s1 to be found in donwhang after re-entering")
	}
	if len(remaining) != 0 {
		t.Fatalf("expected no lingering duplicate entity, got %+v", remaining)
	}
}

func TestChangeZoneMovesEntityAndReturnsBothSides(t *testing.T) {
	h := NewHub()
	s1, s2, s3 := fakeSession(1), fakeSession(2), fakeSession(3)
	h.Enter(s1, 100, "Aria", 1, "jangan", Position{X: 1, Y: 2, Z: 3})
	h.Enter(s2, 200, "Bram", 1, "jangan", Position{})
	h.Enter(s3, 300, "Cyra", 1, "donwhang", Position{})

	old, remainingOld, othersNew, ok := h.ChangeZone(s1, "donwhang", Position{X: 9, Y: 8, Z: 7})
	if !ok {
		t.Fatal("expected s1 to be found")
	}
	if old.Zone != "jangan" || old.Pos != (Position{X: 1, Y: 2, Z: 3}) {
		t.Fatalf("old entity snapshot wrong: %+v", old)
	}
	if len(remainingOld) != 1 || remainingOld[0].Name != "Bram" {
		t.Fatalf("expected only Bram left behind in jangan, got %+v", remainingOld)
	}
	if len(othersNew) != 1 || othersNew[0].Name != "Cyra" {
		t.Fatalf("expected only Cyra already in donwhang, got %+v", othersNew)
	}

	// Aria should now genuinely be in donwhang at the new position, not
	// duplicated in jangan.
	entity, ok := h.EntityBySession(s1.ID())
	if !ok || entity.Zone != "donwhang" || entity.Pos != (Position{X: 9, Y: 8, Z: 7}) {
		t.Fatalf("expected Aria in donwhang at the new position, got %+v (ok=%v)", entity, ok)
	}
	if entities := h.EntitiesInZone("jangan"); len(entities) != 1 || entities[0].Name != "Bram" {
		t.Fatalf("expected only Bram left in jangan, got %+v", entities)
	}
}

func TestChangeZoneUnknownSessionFails(t *testing.T) {
	h := NewHub()
	_, _, _, ok := h.ChangeZone(fakeSession(1), "donwhang", Position{})
	if ok {
		t.Fatal("expected ChangeZone to fail for a session never in the world")
	}
}

// The cached level (round 555): Enter records it, ChangeZone carries it,
// SetLevel moves it for a character in the world and reports false for one
// who is not.
func TestEnterCarriesTheLevelAndSetLevelMovesIt(t *testing.T) {
	h := NewHub()
	s1 := fakeSession(1)
	h.Enter(s1, 100, "Aria", 7, "jangan", Position{})
	if e, ok := h.EntityByCharacterID(100); !ok || e.Level != 7 {
		t.Fatalf("after Enter at level 7: %+v (ok=%v)", e, ok)
	}
	if _, _, _, ok := h.ChangeZone(s1, "donwhang", Position{}); !ok {
		t.Fatal("ChangeZone failed")
	}
	if e, _ := h.EntityByCharacterID(100); e.Level != 7 {
		t.Fatalf("the level did not travel with the zone change: %+v", e)
	}
	if !h.SetLevel(100, 8) {
		t.Fatal("SetLevel reported the character absent")
	}
	if e, _ := h.EntityByCharacterID(100); e.Level != 8 {
		t.Fatalf("after SetLevel(8): %+v", e)
	}
	if h.SetLevel(999, 3) {
		t.Fatal("SetLevel reported a change for a character not in the world")
	}
}
