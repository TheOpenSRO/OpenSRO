package combat

import (
	"sort"
	"testing"
)

// Round 656: the region-cell index. The cell lines are the region lines of
// the frame, 960 + 1920k on both axes (worldmap.ToWorld puts the frame's
// centre region's middle at the origin); a line belongs to the cell above it.
func TestCellOfFollowsTheRegionLines(t *testing.T) {
	for _, c := range []struct {
		x, z   float64
		cx, cz int
	}{
		{0, 0, 0, 0}, {959.9, -959.9, 0, 0}, {960, -960, 1, 0}, {-960.1, 0, -1, 0},
		{2879.9, 2880, 1, 2}, {-2880, -2880.1, -1, -2},
	} {
		if got := CellOf("z", c.x, c.z); got != (Cell{"z", c.cx, c.cz}) {
			t.Errorf("CellOf(%v, %v) = %+v, want (%d, %d)", c.x, c.z, got, c.cx, c.cz)
		}
	}
	if CellsWithin(0) != 0 || CellsWithin(111) != 1 || CellsWithin(1920) != 1 || CellsWithin(1921) != 2 {
		t.Error("CellsWithin is ceil(dist / 1920)")
	}
}

func ids(ms []Monster) []int64 {
	out := make([]int64, len(ms))
	for i, m := range ms {
		out[i] = m.ID
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

// The index follows a monster: filed at the spawn, re-filed when a step
// carries it over a line (reported as a CellChange), dropped at the kill; the
// window and zone reads see exactly that, and a step skips a sleeping cell.
func TestCellIndexFollowsSpawnStepAndKill(t *testing.T) {
	h := NewHub()
	a := h.Spawn("jangan", "A", 900, 0, 0, 10, 1, 1, 1)
	b := h.Spawn("jangan", "B", 1920*3, 0, 0, 10, 1, 1, 1)
	c := h.Spawn("donwhang", "C", 0, 0, 0, 10, 1, 1, 1)
	if got := ids(h.InWindow(nil, CellOf("jangan", 0, 0), 2)); len(got) != 1 || got[0] != a.ID {
		t.Fatalf("window around the origin: %v, want [%d]", got, a.ID)
	}
	if got := ids(h.InZone("jangan")); len(got) != 2 {
		t.Fatalf("InZone(jangan) = %v, want A and B", got)
	}
	h.SetMotion(a.ID, 1100, 0, 1000, 1)
	h.SetMotion(b.ID, 1920*3+100, 0, 1000, 1)
	// B's cell asleep: only A moves.
	changes := h.StepCells(0.5, func(cell Cell) bool { return cell.X == 0 }, nil)
	if len(changes) != 1 || changes[0].ID != a.ID || changes[0].From != (Cell{"jangan", 0, 0}) || changes[0].To != (Cell{"jangan", 1, 0}) {
		t.Fatalf("changes %+v, want A from (0,0) to (1,0)", changes)
	}
	if m, _ := h.Get(b.ID); m.X != 1920*3 || !m.Moving {
		t.Fatalf("the sleeping cell's monster stepped: %+v", m)
	}
	if cell, _ := h.CellOfMonster(a.ID); cell != (Cell{"jangan", 1, 0}) {
		t.Fatalf("A is filed under %+v", cell)
	}
	if got := ids(h.InWindow(nil, Cell{"jangan", 3, 0}, 2)); len(got) != 2 {
		t.Fatalf("window around (3,0) after the step: %v, want A and B", got)
	}
	if h.Facing(a.ID) != 0 {
		t.Errorf("A walks along +x, facing %v, want 0", h.Facing(a.ID))
	}
	h.ApplyDamage(c.ID, 10)
	if h.Exists(c.ID) || len(h.InZone("donwhang")) != 0 || len(h.InWindow(nil, CellOf("donwhang", 0, 0), 0)) != 0 {
		t.Fatal("a killed monster is still in the index")
	}
	if _, filed := h.CellOfMonster(c.ID); filed {
		t.Fatal("a killed monster still has a cell")
	}
	if h.Count() != 2 {
		t.Fatalf("Count %d, want 2", h.Count())
	}
}
