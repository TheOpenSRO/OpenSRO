package combat

import (
	"sort"
	"testing"
)

// Round 656: the cell index; since round 664 its cell is retail's 320-unit
// message block (RegionSpan / 6, READ). The frame's centre region's middle is
// the origin (worldmap.ToWorld), so the region lines 960 + 1920k are block
// lines and every block line is a multiple of 320; a line belongs to the cell
// above it.
func TestCellOfFollowsTheBlockLines(t *testing.T) {
	for _, c := range []struct {
		x, z   float64
		cx, cz int
	}{
		{0, 0, 3, 3}, {319.9, -0.1, 3, 2}, {320, 0, 4, 3}, {959.9, -960, 5, 0}, {960, -960.1, 6, -1},
		{-960.1, 2880, -1, 12},
	} {
		if got := CellOf("z", c.x, c.z); got != (Cell{"z", c.cx, c.cz}) {
			t.Errorf("CellOf(%v, %v) = %+v, want (%d, %d)", c.x, c.z, got, c.cx, c.cz)
		}
	}
	if CellSpan != 320 {
		t.Errorf("CellSpan %v, want retail's 320 (1920 / 6)", CellSpan)
	}
	if CellsWithin(0) != 0 || CellsWithin(111) != 1 || CellsWithin(320) != 1 || CellsWithin(321) != 2 || CellsWithin(1920) != 6 {
		t.Error("CellsWithin is ceil(dist / 320)")
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
	// B's cell asleep: only A moves, over the line at x = 960 (cell 5 -> 6).
	changes := h.StepCells(0.5, func(_ int64, cell Cell) bool { return cell.X < 10 }, nil)
	if len(changes) != 1 || changes[0].ID != a.ID || changes[0].From != (Cell{"jangan", 5, 3}) || changes[0].To != (Cell{"jangan", 6, 3}) {
		t.Fatalf("changes %+v, want A from (5,3) to (6,3)", changes)
	}
	if m, _ := h.Get(b.ID); m.X != 1920*3 || !m.Moving {
		t.Fatalf("the sleeping cell's monster stepped: %+v", m)
	}
	if cell, _ := h.CellOfMonster(a.ID); cell != (Cell{"jangan", 6, 3}) {
		t.Fatalf("A is filed under %+v", cell)
	}
	if got := ids(h.InWindow(nil, Cell{"jangan", 14, 3}, 8)); len(got) != 2 {
		t.Fatalf("window around (14,3) after the step: %v, want A and B", got)
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
