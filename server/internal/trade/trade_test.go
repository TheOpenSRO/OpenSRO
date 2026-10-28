package trade

import "testing"

// Round 839: the stalls' INTERACTMODE reaches Busy and Established, and a
// stalling player cannot be put in an exchange.
func TestSetModes(t *testing.T) {
	h := NewHub()
	modes := map[int64]byte{1: 4, 2: 2}
	h.SetModes(func(id int64) byte { return modes[id] })
	if !h.Busy(1) || !h.Busy(2) || h.Busy(3) {
		t.Fatal("Busy")
	}
	if !h.Established(1) || !h.Established(2) || h.Established(3) {
		t.Fatal("Established")
	}
	if _, err := h.Open(Party{CharacterID: 3}, Party{CharacterID: 1}, nil); err != ErrBusy {
		t.Fatalf("an exchange with a stall owner: %v", err)
	}
	h.SetModes(nil)
	if h.Busy(1) {
		t.Fatal("the modes outlived their removal")
	}
}
