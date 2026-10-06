package world

import "testing"

// A stale session of a reconnect that changes zone stays the stale one (round
// 737's verification, N4): the character and the name stay with the newer
// session that took them. Before, the zone change's re-insertion handed
// them back to the stale session.
func TestAStaleSessionsZoneChangeLeavesTheCharacterLive(t *testing.T) {
	h := NewHub()
	stale, live := fakeSession(1), fakeSession(2)
	h.Enter(stale, 100, "Aria", 1, "jangan", Position{X: 10, Z: 10})
	h.Enter(live, 100, "Aria", 1, "jangan", Position{X: 20, Z: 20})
	if _, _, _, ok := h.ChangeZone(stale, "dw", Position{X: 5, Z: 5}); !ok {
		t.Fatal("the stale session's zone change was refused")
	}
	if e, ok := h.EntityByCharacterID(100); !ok || e.Session != live {
		t.Fatalf("character 100 is on session %v after the stale zone change, want the live one", e.Session.ID())
	}
	if e, ok := h.FindByName("Aria"); !ok || e.Session != live {
		t.Fatal("the name went to the stale session")
	}
	// The live session's own zone change keeps it live.
	if _, _, _, ok := h.ChangeZone(live, "dw", Position{X: 6, Z: 6}); !ok {
		t.Fatal("the live session's zone change was refused")
	}
	if e, ok := h.EntityByCharacterID(100); !ok || e.Session != live || e.Zone != "dw" {
		t.Fatalf("after its own zone change the character is %+v, want the live session in dw", e)
	}
}
