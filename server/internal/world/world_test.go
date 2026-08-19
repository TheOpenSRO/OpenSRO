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

	others := h.Enter(s1, 100, "Aria", "jangan", Position{X: 1, Y: 2, Z: 3})
	if len(others) != 0 {
		t.Fatalf("first entrant should see nobody else, got %+v", others)
	}

	others = h.Enter(s2, 200, "Bram", "jangan", Position{})
	if len(others) != 1 || others[0].Name != "Aria" {
		t.Fatalf("second entrant should see Aria, got %+v", others)
	}
}

func TestEnterIsolatesZones(t *testing.T) {
	h := NewHub()
	s1, s2 := fakeSession(1), fakeSession(2)

	h.Enter(s1, 100, "Aria", "jangan", Position{})
	others := h.Enter(s2, 200, "Bram", "donwhang", Position{})
	if len(others) != 0 {
		t.Fatalf("different zone should see nobody, got %+v", others)
	}
}

func TestMoveUpdatesPositionAndReturnsOthers(t *testing.T) {
	h := NewHub()
	s1, s2 := fakeSession(1), fakeSession(2)
	h.Enter(s1, 100, "Aria", "jangan", Position{})
	h.Enter(s2, 200, "Bram", "jangan", Position{})

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
	h.Enter(s1, 100, "Aria", "jangan", Position{})
	h.Enter(s2, 200, "Bram", "jangan", Position{})

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

func TestReenterMovesRatherThanDuplicates(t *testing.T) {
	h := NewHub()
	s1 := fakeSession(1)
	h.Enter(s1, 100, "Aria", "jangan", Position{})
	h.Enter(s1, 100, "Aria", "donwhang", Position{}) // re-enter, different zone

	_, remaining, ok := h.Leave(s1)
	if !ok {
		t.Fatal("expected s1 to be found in donwhang after re-entering")
	}
	if len(remaining) != 0 {
		t.Fatalf("expected no lingering duplicate entity, got %+v", remaining)
	}
}
