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

// TestExpUnitAndKillExp pins the recovered kill-EXP economy: the level table's
// own column-5 unit, and the minimum-level rule around it.
//
// The values are the real ones, identical in the original client's
// leveldata.txt and the pserver's copy -- so a future export that silently
// shifts a column fails here rather than quietly changing the game's pacing.
func TestExpUnitAndKillExp(t *testing.T) {
	// level,exp,mastery_sp,exp_unit -- real rows.
	const csv = `level,exp,mastery_sp,exp_unit
1,118,1,24
2,470,1,47
3,1058,1,71
10,23500,9,235
20,72700,53,470
`
	tbl, err := ParseCSV(strings.NewReader(csv))
	if err != nil {
		t.Fatalf("ParseCSV: %v", err)
	}

	for _, tc := range []struct {
		level int
		want  int64
	}{{1, 24}, {2, 47}, {3, 71}, {10, 235}, {20, 470}} {
		got, ok := tbl.ExpUnit(tc.level)
		if !ok || got != tc.want {
			t.Fatalf("ExpUnit(%d) = %d,%v; want %d", tc.level, got, ok, tc.want)
		}
	}

	// A level the table does not carry is reported as unknown, never guessed.
	if _, ok := tbl.ExpUnit(7); ok {
		t.Fatal("ExpUnit(7) should be unknown -- the fixture has no row for it")
	}

	// The minimum-level rule: a level-20 character killing a level-1 monster
	// is paid at level 1, not level 20.
	if got, ok := tbl.KillExp(20, 1); !ok || got != 24 {
		t.Fatalf("KillExp(20, 1) = %d,%v; want 24 (paid at the monster's level)", got, ok)
	}
	// And the reverse: a level-1 character killing a level-20 monster is also
	// paid at level 1. The rule is symmetric.
	if got, ok := tbl.KillExp(1, 20); !ok || got != 24 {
		t.Fatalf("KillExp(1, 20) = %d,%v; want 24 (paid at the killer's level)", got, ok)
	}
	if a, _ := tbl.KillExp(3, 10); a != 71 {
		t.Fatalf("KillExp(3, 10) = %d; want 71", a)
	}
	if b, _ := tbl.KillExp(10, 3); b != 71 {
		t.Fatalf("KillExp(10, 3) = %d; want 71", b)
	}

	// An export predating the exp_unit column still loads, and reports the
	// unit as unknown rather than zero -- so the caller keeps its fallback.
	old, err := ParseCSV(strings.NewReader("level,exp,mastery_sp\n1,118,1\n"))
	if err != nil {
		t.Fatalf("ParseCSV (3-column): %v", err)
	}
	if _, ok := old.ExpUnit(1); ok {
		t.Fatal("a three-column export should report no exp unit")
	}
	if _, ok := old.KillExp(1, 1); ok {
		t.Fatal("KillExp should be unknown when the table has no exp units")
	}
}

// The death penalty, pinned to its citation.
//
// GObjPC_OnDeath (004e6980) gates the whole block on `10 < GetLevel(victim)`
// and multiplies the level's EXP unit -- levelTable[lvl]+0x1c, the same field
// a kill is paid from -- by one of four constants.
func TestDeathPenaltyExp(t *testing.T) {
	// Real rows, the same ones TestExpUnitAndKillExp uses, plus level 11 --
	// the first level a death costs anything.
	const csv = `level,exp,mastery_sp,exp_unit
1,118,1,24
10,23500,9,235
11,34898,12,259
20,282000,53,470
`
	tbl, err := ParseCSV(strings.NewReader(csv))
	if err != nil {
		t.Fatalf("ParseCSV: %v", err)
	}

	// Levels 1-10 die free: the real gate is `10 < level`, so 10 itself is
	// still inside the grace period and 11 is the first level that pays.
	for _, lvl := range []int{1, 10} {
		loss, ok := tbl.DeathPenaltyExp(lvl, DeathPenaltyKilledByMonster)
		if !ok || loss != 0 {
			t.Errorf("level %d: loss %d ok %v, want a free death", lvl, loss, ok)
		}
	}

	// Level 11 is the first that costs anything, and it costs the EXP unit
	// times 100.
	unit, ok := tbl.ExpUnit(11)
	if !ok {
		t.Fatal("the test table must know level 11")
	}
	for _, tc := range []struct {
		name       string
		multiplier int
	}{
		{"killed by a monster", DeathPenaltyKilledByMonster},
		{"killed by a monster, PK-flagged", DeathPenaltyKilledByMonsterFlagged},
		{"killed by a player", DeathPenaltyKilledByPlayer},
		{"killed by a player, PK-flagged", DeathPenaltyKilledByPlayerFlagged},
	} {
		t.Run(tc.name, func(t *testing.T) {
			loss, ok := tbl.DeathPenaltyExp(11, tc.multiplier)
			if !ok {
				t.Fatal("level 11 must be known")
			}
			if want := unit * int64(tc.multiplier); loss != want {
				t.Errorf("loss = %d, want %d (unit %d * %d)", loss, want, unit, tc.multiplier)
			}
		})
	}
}

// The four multipliers are the recovered ones, so a later "let's tune it" edit
// has to delete a citation to do it.
func TestDeathPenaltyMultipliersAreTheRecoveredOnes(t *testing.T) {
	for _, tc := range []struct {
		name string
		got  int
		want int
	}{
		{"min level", DeathPenaltyMinLevel, 10},
		{"monster", DeathPenaltyKilledByMonster, 100},
		{"monster, flagged", DeathPenaltyKilledByMonsterFlagged, 300},
		{"player", DeathPenaltyKilledByPlayer, 20},
		{"player, flagged", DeathPenaltyKilledByPlayerFlagged, 100},
		{"SP loss, monster flagged", DeathPenaltySkillPointsMonsterFlagged, 60},
		{"SP loss, player flagged", DeathPenaltySkillPointsPlayerFlagged, 20},
	} {
		if tc.got != tc.want {
			t.Errorf("%s = %d, want %d (GObjPC_OnDeath, 004e6980)", tc.name, tc.got, tc.want)
		}
	}
}

// An unknown level is reported as unknown rather than silently costing
// nothing: a death that quietly skips the penalty because the table is short
// would look exactly like the grace period.
func TestDeathPenaltyUnknownLevel(t *testing.T) {
	tbl, err := ParseCSV(strings.NewReader("level,exp,mastery_sp,exp_unit\n11,34898,12,259\n"))
	if err != nil {
		t.Fatalf("ParseCSV: %v", err)
	}
	if _, ok := tbl.DeathPenaltyExp(9999, DeathPenaltyKilledByMonster); ok {
		t.Error("a level the table does not know must report !ok")
	}
}
