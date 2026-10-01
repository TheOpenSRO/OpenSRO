package combat

import "testing"

// Round 674: Remove is a removal, not a death -- the monster leaves the hub
// and its cell, its damage list goes with it, nothing is credited -- and it
// is booked on the death log, the nest scheduler's signal of a lost hatch.
func TestRemoveTakesAMonsterOutWithoutADeath(t *testing.T) {
	h := NewHub()
	h.LogDeaths(true)
	m := h.Spawn("jangan", "Test", 10, 0, 20, 100, 0, 5, 0)
	other := h.Spawn("jangan", "Other", 12, 0, 20, 100, 0, 5, 0)
	if _, died, ok, _ := h.ApplyDamageFrom(m.ID, 7, 30); died || !ok {
		t.Fatal("setup: the blow killed the monster or found none")
	}
	got, ok := h.Remove(m.ID)
	if !ok || got.ID != m.ID || got.HP != 70 {
		t.Fatalf("Remove = %+v, %v: want the monster as it stood, HP 70", got, ok)
	}
	if h.Exists(m.ID) || h.Count() != 1 {
		t.Errorf("after Remove: exists %v, count %d, want gone and one left", h.Exists(m.ID), h.Count())
	}
	if _, filed := h.CellOfMonster(m.ID); filed {
		t.Error("the removed monster is still filed in a cell")
	}
	if hits := h.Hits(m.ID); len(hits) != 0 {
		t.Errorf("the removed monster's damage list is kept: %+v", hits)
	}
	if in := h.InWindow(nil, CellOf("jangan", 10, 20), 0); len(in) != 1 || in[0].ID != other.ID {
		t.Errorf("the cell holds %+v, want only the other monster", in)
	}
	if d := h.DrainDeaths(nil); len(d) != 1 || d[0] != m.ID {
		t.Errorf("the death log holds %v, want the removed monster", d)
	}
	if _, again := h.Remove(m.ID); again {
		t.Error("a second Remove found the monster")
	}
}
