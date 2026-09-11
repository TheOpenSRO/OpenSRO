package leveldata

import (
	"strings"
	"testing"
)

// A small synthetic curve (not real game data): advancing from level 1 needs
// 100, from 2 needs 200, from 3 needs 300.
const synthCSV = `level,exp
1,100
2,200
3,300
`

func mustParse(t *testing.T) *Table {
	t.Helper()
	tbl, err := ParseCSV(strings.NewReader(synthCSV))
	if err != nil {
		t.Fatalf("ParseCSV: %v", err)
	}
	return tbl
}

func TestParseCSVSkipsHeaderAndReadsRows(t *testing.T) {
	tbl := mustParse(t)
	if got, ok := tbl.ExpToNext(1); !ok || got != 100 {
		t.Errorf("ExpToNext(1) = %d, %v; want 100, true", got, ok)
	}
	if got, ok := tbl.ExpToNext(3); !ok || got != 300 {
		t.Errorf("ExpToNext(3) = %d, %v; want 300, true", got, ok)
	}
	if tbl.MaxLevel() != 3 {
		t.Errorf("MaxLevel = %d, want 3", tbl.MaxLevel())
	}
	if !tbl.Loaded() {
		t.Error("Loaded() = false, want true")
	}
}

func TestAdvanceOneLevelCarriesRemainder(t *testing.T) {
	tbl := mustParse(t)
	// At level 1 with 0 progress, gain 150: cross 100 to level 2, 50 left.
	level, exp, gained := tbl.Advance(1, 0, 150)
	if level != 2 || exp != 50 || gained != 1 {
		t.Errorf("Advance(1,0,150) = (%d,%d,%d); want (2,50,1)", level, exp, gained)
	}
}

func TestAdvanceMultipleLevels(t *testing.T) {
	tbl := mustParse(t)
	// From level 1, gain 100+200+... = 310: crosses level 1 and 2 and reaches
	// level 3, the cap here, so the overflow is dropped (maxed = no progress).
	level, exp, gained := tbl.Advance(1, 0, 310)
	if level != 3 || exp != 0 || gained != 2 {
		t.Errorf("Advance(1,0,310) = (%d,%d,%d); want (3,0,2)", level, exp, gained)
	}
}

func TestAdvanceBelowMaxKeepsRemainder(t *testing.T) {
	// A three-level table where level 2 is not the cap, so a cross into it
	// keeps the remainder.
	tbl, err := ParseCSV(strings.NewReader("level,exp\n1,100\n2,200\n3,300\n4,400\n"))
	if err != nil {
		t.Fatalf("ParseCSV: %v", err)
	}
	level, exp, gained := tbl.Advance(1, 0, 150)
	if level != 2 || exp != 50 || gained != 1 {
		t.Errorf("Advance(1,0,150) = (%d,%d,%d); want (2,50,1)", level, exp, gained)
	}
}

func TestAdvanceStopsAtMaxLevel(t *testing.T) {
	tbl := mustParse(t)
	// Level 3 is the max: gaining exp there does not overflow into a level 4.
	level, exp, gained := tbl.Advance(3, 0, 99999)
	if level != 3 || gained != 0 {
		t.Errorf("Advance at max = (%d,exp,%d); want level 3, 0 gained", level, gained)
	}
	if exp != 0 {
		t.Errorf("max-level progress = %d, want 0 (held)", exp)
	}
}

func TestAdvanceBelowThresholdJustAccumulates(t *testing.T) {
	tbl := mustParse(t)
	level, exp, gained := tbl.Advance(1, 30, 40)
	if level != 1 || exp != 70 || gained != 0 {
		t.Errorf("Advance(1,30,40) = (%d,%d,%d); want (1,70,0)", level, exp, gained)
	}
}

func TestNilAndEmptyTableAreSafe(t *testing.T) {
	var nilTbl *Table
	if nilTbl.Loaded() {
		t.Error("nil table Loaded() = true")
	}
	level, exp, gained := nilTbl.Advance(1, 0, 500)
	if level != 1 || exp != 500 || gained != 0 {
		t.Errorf("nil Advance = (%d,%d,%d); want (1,500,0) -- raw accumulation", level, exp, gained)
	}
	empty, err := ParseCSV(strings.NewReader("level,exp\n"))
	if err != nil {
		t.Fatalf("ParseCSV(header only): %v", err)
	}
	if empty.Loaded() {
		t.Error("header-only table Loaded() = true")
	}
}
