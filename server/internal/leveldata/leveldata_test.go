package leveldata

import (
	"fmt"
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
	// From level 1, gain 310: crosses level 1 (100) and level 2 (200) and
	// reaches level 3, the cap here, with 10 left over. 10 is below level 3's
	// own requirement (300), so it is kept as partial progress -- the client
	// only clamps the max-level bar when the gain would actually overflow it.
	level, exp, gained := tbl.Advance(1, 0, 310)
	if level != 3 || exp != 10 || gained != 2 {
		t.Errorf("Advance(1,0,310) = (%d,%d,%d); want (3,10,2)", level, exp, gained)
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
	// A gain that would overflow is held at the level's requirement minus one
	// (300-1 = 299), the way the client does it (FUN_008a97c0) -- a
	// full-but-not-overflowing bar, not a zeroed one.
	level, exp, gained := tbl.Advance(3, 0, 99999)
	if level != 3 || gained != 0 {
		t.Errorf("Advance at max = (%d,exp,%d); want level 3, 0 gained", level, gained)
	}
	if exp != 299 {
		t.Errorf("max-level progress = %d, want 299 (held at requirement-1)", exp)
	}
}

// The character cap is MaxCharacterLevel (110), recovered from the client, even
// when the curve table defines more levels than that.
func TestAdvanceHonoursCharacterCapBelowTableEnd(t *testing.T) {
	var b strings.Builder
	b.WriteString("level,exp\n")
	// A curve out to level 200, every level needing 100.
	for lvl := 1; lvl <= 200; lvl++ {
		fmt.Fprintf(&b, "%d,100\n", lvl)
	}
	tbl, err := ParseCSV(strings.NewReader(b.String()))
	if err != nil {
		t.Fatalf("ParseCSV: %v", err)
	}
	if tbl.MaxLevel() != 200 {
		t.Fatalf("table MaxLevel = %d, want 200", tbl.MaxLevel())
	}
	// From level 1 with a huge gain, the character stops at 110, not 200, and
	// the bar is held at that level's requirement minus one (100-1 = 99).
	level, exp, _ := tbl.Advance(1, 0, 1_000_000)
	if level != MaxCharacterLevel {
		t.Errorf("Advance capped at level %d, want %d", level, MaxCharacterLevel)
	}
	if exp != 99 {
		t.Errorf("capped progress = %d, want 99 (requirement-1)", exp)
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
