package world

import (
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
)

// Round 786: a held character (Entity.Held) is in no message block until
// Release -- out of every other player's window, no crossing gains it, Sees
// is false -- as retail's PC is out of the world until its client's 0x3012.
func TestRound786HeldIsInNoWindowUntilRelease(t *testing.T) {
	h := NewHub()
	a, b := gateway.NewTestSession(1), gateway.NewTestSession(2)
	h.Enter(b, 2, "Bram", 1, "jangan", Position{})
	if others := h.EnterHeld(a, 1, "Aria", 1, "jangan", Position{X: 10}); len(others) != 1 {
		t.Fatalf("a held entry sees %d other(s), want Bram (it may be sent nothing, but it knows its window)", len(others))
	}
	if h.Sees(1, 2) {
		t.Fatal("Sees is true for a held character")
	}
	for _, e := range h.ViewOfCharacter(2) {
		if e.CharacterID == 1 {
			t.Fatal("Bram's window holds held Aria")
		}
	}
	// Bram walks across a block line and back: he gains nobody held.
	if r, _ := h.Relocate(b, Position{X: 700}, MoveRelocate, 0); len(r.Gained) != 0 {
		t.Fatalf("Bram gained %v crossing", r.Gained)
	}
	if r, _ := h.Relocate(b, Position{}, MoveRelocate, 0); len(r.Gained) != 0 {
		t.Fatalf("Bram gained %v crossing back to held Aria", r.Gained)
	}
	// Aria's own move while held crosses nothing.
	if r, _ := h.Relocate(a, Position{X: 700}, MoveRelocate, 0); r.Crossed || len(r.Gained)+len(r.Lost) != 0 {
		t.Fatalf("a held move crossed: %+v", r)
	}
	h.Relocate(a, Position{X: 10}, MoveRelocate, 0)
	released, others, ok := h.Release(a)
	if !ok || released.Held || len(others) != 1 || others[0].CharacterID != 2 {
		t.Fatalf("Release: %+v %v %v; want Aria released with Bram in view", released, others, ok)
	}
	if !h.Sees(1, 2) {
		t.Fatal("not in view after the release")
	}
	if _, _, again := h.Release(a); again {
		t.Fatal("a second Release of a character not held reported ok")
	}
	// A held zone change takes her out of Bram's window at once.
	h.ChangeZoneHeld(a, "jangan", Position{X: 20})
	if h.Sees(1, 2) {
		t.Fatal("in view after a held zone change")
	}
	if e, _ := h.EntityByCharacterID(1); !e.Held {
		t.Fatal("ChangeZoneHeld left her not held")
	}
}
