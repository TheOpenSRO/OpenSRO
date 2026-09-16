package leveldata

import (
	"fmt"
	"math"
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

	// The minimum-level rule still holds -- a level-20 character killing a
	// level-1 monster is paid at level 1's unit, not level 20's -- but the
	// window scaler then takes almost all of it away, which is the game's real
	// anti-powerlevelling behaviour and far stronger than the min rule alone.
	// gap -19 -> 1 - 16*0.15 = -1.4, floored at 0.1. 24 * 0.1 = 2.4.
	if got, ok := tbl.KillExp(20, 1); !ok || got != 2 {
		t.Fatalf("KillExp(20, 1) = %d,%v; want 2 (level-1 unit, window floor 0.1)", got, ok)
	}
	// The reverse is not symmetric: the base is still the level-1 unit, but
	// punching 19 levels up earns the gap bonus (capped at 13 steps, 1.39) and
	// pays the far-above window penalty (1 - 9*0.02 = 0.82).
	// 24 * 0.82 * 1.39 = 27.36.
	if got, ok := tbl.KillExp(1, 20); !ok || got != 27 {
		t.Fatalf("KillExp(1, 20) = %d,%v; want 27 (unit 24 * 0.82 * 1.39)", got, ok)
	}
	// A level-3 character killing a level-10 monster sits INSIDE the -3..+10
	// window, so the window scaler is exactly 1.0 and only the gap bonus
	// applies: base 71 at level 3, 10 steps -> 1.30. 71 * 1.30 = 92.3.
	if a, _ := tbl.KillExp(3, 10); a != 92 {
		t.Fatalf("KillExp(3, 10) = %d; want 92 (71 * 1.00 * 1.30)", a)
	}
	// The other way round the killer out-levels by 7: no gap bonus, and the
	// window scaler's far-below arm, 1 - 4*0.15 = 0.4. 71 * 0.4 = 28.4.
	if b, _ := tbl.KillExp(10, 3); b != 28 {
		t.Fatalf("KillExp(10, 3) = %d; want 28 (71 * 0.40)", b)
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

// TestExpDiffScale pins the recovered level-gap bonus, boundary by boundary,
// because every interesting case is a boundary.
//
// From Formula_ExpScaleByLevelDiff (0040ffe0): 1.0 flat when the killer
// out-levels the target by three or more, otherwise 1 + 0.03 * (gap + 3) with
// the step count capped at 13.
func TestExpDiffScale(t *testing.T) {
	for _, tc := range []struct {
		name                     string
		killerLevel, victimLevel int
		want                     float64
	}{
		// The cutoff is `victim + 3 <= killer`, so a gap of exactly -3 is the
		// first level that earns nothing and -2 the last that earns something.
		{"out-levelled by 3 exactly", 10, 7, 1.00},
		{"out-levelled by 4", 10, 6, 1.00},
		{"out-levelled by 2", 10, 8, 1.03},
		{"out-levelled by 1", 10, 9, 1.06},
		{"same level", 10, 10, 1.09},
		{"target one level up", 10, 11, 1.12},
		// 13 steps is the cap: gap 10 reaches it, gap 11 and beyond stay there.
		{"target ten levels up (the cap)", 10, 20, 1.39},
		{"target eleven levels up (still capped)", 10, 21, 1.39},
		{"target fifty levels up (still capped)", 10, 60, 1.39},
		// The bare minimum is 1.0, never below.
		{"a level-1 killer against a level-1 target", 1, 1, 1.09},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := ExpDiffScale(tc.killerLevel, tc.victimLevel)
			if math.Abs(got-tc.want) > 1e-9 {
				t.Errorf("ExpDiffScale(%d, %d) = %v, want %v", tc.killerLevel, tc.victimLevel, got, tc.want)
			}
		})
	}

	// It never scales a reward down, whatever the levels.
	for killer := 1; killer <= 80; killer++ {
		for victim := 1; victim <= 80; victim++ {
			if s := ExpDiffScale(killer, victim); s < 1 || s > ExpDiffScaleCap {
				t.Fatalf("ExpDiffScale(%d, %d) = %v, outside [1, %v]", killer, victim, s, ExpDiffScaleCap)
			}
		}
	}
}

// TestApplyDeathPenaltyReduction pins the SHAPE of the engine's death-penalty
// reduction, which matters even though srrevamp's own rate is zero: the term is
// a percentage of the loss, not a flat subtraction, and a premium system later
// has to slot into the right arithmetic.
//
// From GObjPC_OnDeath: EvaluateParam(257) on the victim's own keeper, divided
// by 100, multiplied by the loss, subtracted only when positive.
func TestApplyDeathPenaltyReduction(t *testing.T) {
	for _, tc := range []struct {
		name    string
		loss    int64
		percent int
		want    int64
	}{
		{"srrevamp's own rate is zero", 1000, 0, 1000},
		{"a negative rate never adds", 1000, -20, 1000},
		{"a quarter off", 1000, 25, 750},
		{"rounds rather than truncates", 101, 50, 50}, // 50.5 -> 51 off
		{"a full hundred percent wipes it", 1000, 100, 0},
		{"beyond a hundred cannot go negative", 1000, 250, 0},
		{"a zero loss stays zero", 0, 50, 0},
		{"a rate too small to move a small loss", 1, 10, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := ApplyDeathPenaltyReduction(tc.loss, tc.percent); got != tc.want {
				t.Errorf("ApplyDeathPenaltyReduction(%d, %d) = %d, want %d",
					tc.loss, tc.percent, got, tc.want)
			}
		})
	}

	// The constant is zero, and RECOVERED as zero. The only writer of param
	// 257 in the binary is CTJ_PremiumKeeper, so an ordinary character never
	// has it granted and the param falls back to its descriptor default --
	// which the param registry at VA 0x00c64110 gives as 0 (min 0, max 1000).
	// See docs/protocol/param_registry.md.
	if DeathPenaltyReductionPercent != 0 {
		t.Errorf("DeathPenaltyReductionPercent = %d; it is a premium-only stat and zero here",
			DeathPenaltyReductionPercent)
	}

	// And it must not have changed what a death costs. A level-20 character's
	// loss is still the bare 470 * 100.
	tbl, err := ParseCSV(strings.NewReader("level,exp,mastery_sp,exp_unit\n20,72700,53,470\n"))
	if err != nil {
		t.Fatalf("ParseCSV: %v", err)
	}
	got, ok := tbl.DeathPenaltyExp(20, DeathPenaltyKilledByMonster)
	if !ok || got != 470*100 {
		t.Errorf("DeathPenaltyExp(20, monster) = %d,%v; want %d unchanged by the zero reduction",
			got, ok, 470*100)
	}
}

// TestExpWindowScale pins the recovered window scaler at every boundary its
// three modes create. The mode edges are the whole content of the function, so
// a test that only sampled the middle would prove nothing.
func TestExpWindowScale(t *testing.T) {
	for _, tc := range []struct {
		name                     string
		killerLevel, victimLevel int
		want                     float64
	}{
		// Mode 0 is the band -3 <= gap < 11, and inside it the engine leaves
		// the scale at the 1.0 it was initialised to.
		{"same level", 20, 20, 1.00},
		{"three below (the last of mode 0)", 20, 17, 1.00},
		{"ten above (the last of mode 0)", 20, 30, 1.00},
		// Mode 1 starts at gap 11 and decays 2% a level past the tenth.
		{"eleven above (first of mode 1)", 20, 31, 0.98},
		{"twenty above", 20, 40, 0.80},
		{"far above, floored", 20, 100, 0.10},
		// Mode 2 starts at gap -4. Four to six below is a flat 0.9.
		{"four below (first of mode 2)", 20, 16, 0.90},
		{"six below (last of the flat band)", 20, 14, 0.90},
		// Seven below and worse falls away 15% a level, from 1 - (7-3)*0.15.
		{"seven below", 20, 13, 0.40},
		{"eight below", 20, 12, 0.25},
		{"nine below", 20, 11, 0.10},
		{"far below, floored", 20, 1, 0.10},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := ExpWindowScale(tc.killerLevel, tc.victimLevel)
			if math.Abs(got-tc.want) > 1e-9 {
				t.Errorf("ExpWindowScale(%d, %d) = %v, want %v",
					tc.killerLevel, tc.victimLevel, got, tc.want)
			}
		})
	}

	// It never scales a reward UP, and never below the floor.
	for killer := 1; killer <= 120; killer++ {
		for victim := 1; victim <= 120; victim++ {
			s := ExpWindowScale(killer, victim)
			if s < ExpWindowScaleFloor || s > 1 {
				t.Fatalf("ExpWindowScale(%d, %d) = %v, outside [%v, 1]",
					killer, victim, s, ExpWindowScaleFloor)
			}
		}
	}
}

// TestPartyExpBonus pins the engine's party multiplier: 1.0 plus 3% for every
// member past the first, from the FMUL 0.03 / FADD 1.0 pair in
// CGObjCOS_GoldPet::vslot_399. Both constants are QWORD in the disassembly, so
// they are doubles -- read as float32 the first is -3.7e19, which is why the
// operand size is checked rather than assumed.
func TestPartyExpBonus(t *testing.T) {
	for _, tc := range []struct {
		members int
		want    float64
	}{
		{0, 1.0},  // nonsense size, no bonus
		{1, 1.0},  // solo: the engine keeps the FLD1 it started with
		{2, 1.03}, // one companion
		{3, 1.06},
		{5, 1.12}, // party.MaxSize here
		{8, 1.21}, // the engine's own cap, for reference
	} {
		got := PartyExpBonus(tc.members)
		if math.Abs(got-tc.want) > 1e-9 {
			t.Errorf("PartyExpBonus(%d) = %v, want %v", tc.members, got, tc.want)
		}
	}

	// The per-member step is the recovered constant itself, not a rounding of
	// it: a bonus built from any other step would drift here.
	if PartyExpBonusPerMember != 0.03 {
		t.Fatalf("PartyExpBonusPerMember = %v, want the recovered 0.03", PartyExpBonusPerMember)
	}

	// Monotonic and never a penalty -- the engine only ever adds.
	prev := PartyExpBonus(1)
	for n := 2; n <= 16; n++ {
		cur := PartyExpBonus(n)
		if cur <= prev {
			t.Errorf("PartyExpBonus(%d) = %v is not greater than PartyExpBonus(%d) = %v", n, cur, n-1, prev)
		}
		if cur < 1.0 {
			t.Errorf("PartyExpBonus(%d) = %v, below 1.0 -- the bonus must never reduce exp", n, cur)
		}
		prev = cur
	}
}

// TestMasteryExpScale pins the recovered "keep your mastery up" rule: 0.1 of a
// kill's experience lost per level the best mastery lags the character level,
// clamped to [0.1, 1.9], and a flat 1.0 once the reference passes 120.
//
// The reference being the HIGHEST MASTERY LEVEL is the part that took a use-site
// to settle (see the constant's comment), so the table below is written in those
// terms deliberately -- a future reader changing it should have to confront what
// the second argument means.
func TestMasteryExpScale(t *testing.T) {
	for _, tc := range []struct {
		name       string
		charLevel  int
		maxMastery int
		want       float64
	}{
		{"mastery level with the character: no adjustment", 40, 40, 1.0},
		{"one level behind", 41, 40, 0.9},
		{"five levels behind", 45, 40, 0.5},
		{"nine behind reaches the floor exactly", 49, 40, 0.1},
		{"far behind is held at the floor", 80, 40, 0.1},
		{"one level ahead", 40, 41, 1.1},
		{"far ahead is held at the ceiling", 40, 80, 1.9},
		{"a fresh level-1 character with no mastery", 1, 0, 0.9},
		{"a level-10 character who ignored masteries", 10, 0, 0.1},
		{"reference above 120 short-circuits to 1.0", 80, 121, 1.0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := MasteryExpScale(tc.charLevel, tc.maxMastery)
			if math.Abs(got-tc.want) > 1e-9 {
				t.Errorf("MasteryExpScale(%d, %d) = %v, want %v",
					tc.charLevel, tc.maxMastery, got, tc.want)
			}
		})
	}

	// The scale never leaves the recovered bounds, whatever the inputs.
	for charLevel := 0; charLevel <= 140; charLevel++ {
		for mastery := 0; mastery <= 120; mastery++ {
			got := MasteryExpScale(charLevel, mastery)
			if got < MasteryExpScaleMin || got > MasteryExpScaleMax {
				t.Fatalf("MasteryExpScale(%d, %d) = %v, outside [%v, %v]",
					charLevel, mastery, got, MasteryExpScaleMin, MasteryExpScaleMax)
			}
		}
	}

	// The per-level step is the recovered constant, not a rounding of it.
	if MasteryExpPenaltyPerLevel != 0.1 {
		t.Errorf("MasteryExpPenaltyPerLevel = %v, want the recovered 0.1", MasteryExpPenaltyPerLevel)
	}
	// 0x78 -- the same ceiling as a single mastery.
	if MasteryExpRefCap != 120 {
		t.Errorf("MasteryExpRefCap = %d, want 120 (0x78)", MasteryExpRefCap)
	}
}

// TestStatPointsPerLevelMatchesTheEngineArithmetic pins the constant to the
// engine's own two steps rather than to the character window that first
// suggested it: five granted, two immediately spent, three left.
//
// Written as the arithmetic and not as a bare `== 3` so that the relationship
// is what fails if someone changes one half of it.
func TestStatPointsPerLevelMatchesTheEngineArithmetic(t *testing.T) {
	const (
		grantedPerLevel   = 5 // GObjPC_SetLevel: pool += levels*5
		autoSpentPerLevel = 2 // SpendStatPoints(str = levels, int = levels)
	)
	if got := grantedPerLevel - autoSpentPerLevel; got != StatPointsPerLevel {
		t.Fatalf("the engine grants %d and auto-spends %d, leaving %d; StatPointsPerLevel is %d",
			grantedPerLevel, autoSpentPerLevel, got, StatPointsPerLevel)
	}
	// The original observation this replaces: a level-9 character had 24 points.
	if got := (9 - 1) * StatPointsPerLevel; got != 24 {
		t.Errorf("a level-9 character should hold 24 spendable points, got %d", got)
	}
}
