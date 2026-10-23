package session

import (
	"strings"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
)

// Skill damage is real, and it comes in TWO halves that the engine keeps on
// opposite sides of mitigation: a flat roll added to the weapon's damage before
// mitigation, and a percentage applied to the blow after it. skillDamageBonus
// returns them separately for that reason -- see combat.ApplySkillPercent.
func TestSkillDamageBonusUsesRealParams(t *testing.T) {
	// SKILL_CH_SWORD_SMASH_A_01: 143% of weapon damage, plus 15-18 flat.
	smash := &refdata.Skill{ReqLearnSP: 1, BasicLevel: 1, AttackPercent: 143, DamageMin: 15, DamageMax: 18}
	for i := 0; i < 50; i++ {
		flat, pct := skillDamageBonus(smash)
		if flat < 15 || flat > 18 {
			t.Fatalf("smash flat damage: got %d, want 15..18", flat)
		}
		if pct != 143 {
			t.Fatalf("smash percentage: got %d, want 143", pct)
		}
	}

	// SKILL_CH_SWORD_BASE_01: 60% and no flat damage -- a plain swing is
	// weaker than the weapon alone, which now shows as a sub-100 percentage
	// rather than as a negative bonus.
	base := &refdata.Skill{ReqLearnSP: 1, BasicLevel: 1, AttackPercent: 60}
	if flat, pct := skillDamageBonus(base); flat != 0 || pct != 60 {
		t.Errorf("a 60%% basic swing: got flat %d pct %d, want 0 and 60", flat, pct)
	}

	// A skill with no 'att' (a buff, a heal, or refdata predating the
	// columns) falls back to the disclosed per-level stand-in, which is flat
	// and therefore carries no percentage.
	buff := &refdata.Skill{ReqLearnSP: 1, BasicLevel: 3}
	flat, pct := skillDamageBonus(buff)
	if want := 3 * DisclosedSkillDamagePerLevel; flat != want || pct != 0 {
		t.Errorf("a skill with no att parameter: got flat %d pct %d, want the disclosed %d and 0", flat, pct, want)
	}

	// A fixed flat value (min == max) must not panic on the range roll.
	fixed := &refdata.Skill{ReqLearnSP: 1, BasicLevel: 1, AttackPercent: 100, DamageMin: 7, DamageMax: 7}
	if flat, pct := skillDamageBonus(fixed); flat != 7 || pct != 100 {
		t.Errorf("a fixed flat bonus: got flat %d pct %d, want 7 and 100", flat, pct)
	}
}

// The mastery level-up cost is the level table's own column 2 when a table is
// loaded, and the disclosed fallback when it is not.
func TestMasteryUpCostUsesTheLevelTable(t *testing.T) {
	// No table loaded: the disclosed own-design cost.
	SetLevelTable(nil)
	if got := masteryUpCost(20); got != 21 {
		t.Errorf("with no level table: got %d, want the disclosed 21", got)
	}

	// With the real curve, raising from level 20 costs 53, not 21.
	tbl, err := leveldata.ParseCSV(strings.NewReader(
		"level,exp,mastery_sp\n2,470,1\n3,1058,1\n4,1880,2\n10,23500,9\n20,282000,53\n"))
	if err != nil {
		t.Fatalf("ParseCSV: %v", err)
	}
	SetLevelTable(tbl)
	defer SetLevelTable(nil)

	for _, tc := range []struct{ level, want int }{{2, 1}, {3, 1}, {4, 2}, {10, 9}, {20, 53}} {
		if got := masteryUpCost(tc.level); got != tc.want {
			t.Errorf("masteryUpCost(%d) = %d, want the real %d", tc.level, got, tc.want)
		}
	}
	// A level the table does not carry still gets the fallback.
	if got := masteryUpCost(7); got != 8 {
		t.Errorf("a level missing from the table: got %d, want the fallback 8", got)
	}
}

// TestMasteryUpCostFirstPointIsFree pins Mastery_LevelUp's level-0 path
// (0x0059c4e0): `test cl,cl ; jne` at 0x59c628 sends a level-0 mastery to the
// level setter FUN_005a8bf0 with cl = 1 and jumps past both the cost loop and
// the 0x3802 check, so the first point costs nothing -- with or without a level
// table, and even if a table carried a row for level 0 (RefLevel_GetEntry
// indexes rows[level-1], so the engine has none to read).
func TestMasteryUpCostFirstPointIsFree(t *testing.T) {
	SetLevelTable(nil)
	defer SetLevelTable(nil)
	if got := masteryUpCost(0); got != 0 {
		t.Errorf("no level table: masteryUpCost(0) = %d, want 0 (the level-0 path skips the cost loop)", got)
	}
	if got := masteryUpCost(1); got != 2 {
		t.Errorf("no level table: masteryUpCost(1) = %d, want the disclosed fallback 2 -- only level 0 is free", got)
	}

	tbl, err := leveldata.ParseCSV(strings.NewReader("level,exp,mastery_sp\n0,0,7\n1,67,1\n2,470,1\n"))
	if err != nil {
		t.Fatalf("ParseCSV: %v", err)
	}
	SetLevelTable(tbl)
	if got := masteryUpCost(0); got != 0 {
		t.Errorf("a table with a level-0 row: masteryUpCost(0) = %d, want 0 (the engine never reads it)", got)
	}
	if got := masteryUpCost(1); got != 1 {
		t.Errorf("masteryUpCost(1) = %d, want the table's 1", got)
	}
}

// TestMasteryCostLoopStopsSummingAt120 pins the bound of Mastery_LevelUp's cost
// loop: `cmp esi,0x78 ; jg 0x59c687` at 0x59c64e jumps to the skill-point check,
// so a raise FROM level 120 still sums row 120's column 2 and a raise from 121
// or above sums nothing -- whatever the table carries past 120.
func TestMasteryCostLoopStopsSummingAt120(t *testing.T) {
	if MasteryCostLevelCeiling != 120 {
		t.Fatalf("MasteryCostLevelCeiling = %d, want 120 (0x78 at 0x59c64e)", MasteryCostLevelCeiling)
	}
	SetLevelTable(nil)
	defer SetLevelTable(nil)
	// No table: the disclosed fallback up to 120, nothing past it.
	for _, tc := range []struct{ level, want int }{{119, 120}, {120, 121}, {121, 0}, {140, 0}} {
		if got := masteryUpCost(tc.level); got != tc.want {
			t.Errorf("no level table: masteryUpCost(%d) = %d, want %d", tc.level, got, tc.want)
		}
	}

	tbl, err := leveldata.ParseCSV(strings.NewReader(
		"level,exp,mastery_sp\n119,1,5000\n120,1,6000\n121,1,7000\n140,1,9000\n"))
	if err != nil {
		t.Fatalf("ParseCSV: %v", err)
	}
	SetLevelTable(tbl)
	for _, tc := range []struct{ level, want int }{
		{119, 5000},
		{120, 6000}, // `0x78 < 120` is false: the last level the loop sums
		{121, 0},    // the loop breaks before RefLevel_GetEntry(121)
		{140, 0},
	} {
		if got := masteryUpCost(tc.level); got != tc.want {
			t.Errorf("masteryUpCost(%d) = %d, want %d", tc.level, got, tc.want)
		}
	}
}

// TestRealSkillsWinOverTheOwnDesignCatalog guards the ordering that was wrong
// until 2026-09-16.
//
// skill.Catalog occupies ids 1 and 2. In the client's own skilldata those are
// SKILL_PUNCH_01 and SKILL_CH_SWORD_BASE_01 -- the unarmed attack and the basic
// sword swing. The use path consulted the catalog first, so a server with real
// refdata loaded resolved skill 2 to an invented "Whirlwind" (+10 flat) rather
// than the real 60%-of-weapon swing, while the LEARN path had already preferred
// refdata. The two disagreed about the same id.
//
// This pins the two facts that made it a bug rather than a style choice: the
// catalog really does occupy the colliding ids, and the real basic swing really
// is a sub-100 percentage with no flat damage, so the shadowing changed damage.
func TestRealSkillsWinOverTheOwnDesignCatalog(t *testing.T) {
	for _, id := range []int64{1, 2} {
		if _, ok := skill.Catalog[id]; !ok {
			t.Fatalf("skill.Catalog no longer holds id %d; this guard assumed the collision", id)
		}
	}

	// The real SKILL_CH_SWORD_BASE_01 (id 2): 60%, no flat damage. If the
	// catalog shadowed it the blow would instead take a flat +10 and no
	// percentage, which is what this asserts cannot silently become true.
	realBase := &refdata.Skill{ReqLearnSP: 1, BasicLevel: 1, AttackPercent: 60}
	flat, pct := skillDamageBonus(realBase)
	if flat != 0 || pct != 60 {
		t.Errorf("the real basic swing: got flat %d pct %d, want 0 and 60", flat, pct)
	}
	if cat := skill.Catalog[2]; int(cat.DamageBonus) == flat {
		t.Errorf("the catalog's id 2 bonus (%d) is indistinguishable from the real "+
			"skill's flat damage (%d); the test can no longer tell which one resolved",
			cat.DamageBonus, flat)
	}
}

// A skill the engine resolves no blow for has no damage bonus at all -- not the
// disclosed per-level fallback it used to get. The fallback survives for skills
// with no real row, which is a different case.
func TestNoCombatParamSkillHasNoDamageBonus(t *testing.T) {
	buff := &refdata.Skill{ReqLearnSP: 1, ID: 1, BasicLevel: 5, NoCombatParam: true}
	if flat, pct := skillDamageBonus(buff); flat != 0 || pct != 0 {
		t.Errorf("skillDamageBonus(no-combat skill) = (%d, %d), want (0, 0)", flat, pct)
	}
	// The same skill without the flag still gets the disclosed bonus, so the
	// test above is measuring the flag rather than the level.
	same := &refdata.Skill{ReqLearnSP: 1, ID: 1, BasicLevel: 5}
	if flat, _ := skillDamageBonus(same); flat != 5*DisclosedSkillDamagePerLevel {
		t.Errorf("without the flag the disclosed fallback should still apply; got %d, want %d",
			flat, 5*DisclosedSkillDamagePerLevel)
	}
	// And a skill with a real 'att' is untouched by any of this.
	real := &refdata.Skill{ReqLearnSP: 1, ID: 1, BasicLevel: 5, AttackPercent: 143, DamageMin: 15, DamageMax: 15}
	if flat, pct := skillDamageBonus(real); flat != 15 || pct != 143 {
		t.Errorf("skillDamageBonus(att skill) = (%d, %d), want (15, 143)", flat, pct)
	}
}

// ZeroDamage is the wider rule and NoCombatParam is inside it: a skill that
// carries a combat parameter but neither 'att' nor 'ck' still deals nothing,
// because Combat_ResolveDamage's local_d0 zeroes both halves of the blow.
func TestZeroDamageSkillHasNoDamageBonus(t *testing.T) {
	zero := &refdata.Skill{ReqLearnSP: 1, ID: 1, BasicLevel: 5, ZeroDamage: true}
	if flat, pct := skillDamageBonus(zero); flat != 0 || pct != 0 {
		t.Errorf("skillDamageBonus(zero-damage skill) = (%d, %d), want (0, 0)", flat, pct)
	}
	// A skill carrying 'ck' but no 'att' is NOT zero-damage: local_d0 stays 0,
	// the mitigation path runs and the weapon's own blow lands. Exactly one
	// real skill is like this, which is why the flag is exported rather than
	// inferred from AttackPercent alone.
	ckOnly := &refdata.Skill{ReqLearnSP: 1, ID: 1, BasicLevel: 5}
	if flat, pct := skillDamageBonus(ckOnly); flat == 0 && pct == 0 {
		t.Error("a skill with no att but no ZeroDamage flag should still get the disclosed fallback, not zero")
	}
}

// A floor-blow skill asks for a real zero percentage and no flat term. It must
// NOT fall through to the disclosed per-level bonus, which is what every such
// skill got while "percent 0" and "no att" were the same thing.
func TestFloorBlowSkillAsksForARealZeroPercent(t *testing.T) {
	pet := &refdata.Skill{ReqLearnSP: 1, ID: 1, BasicLevel: 5, FloorBlow: true}
	flat, pct := skillDamageBonus(pet)
	if flat != 0 || pct != combat.SkillPercentZero {
		t.Errorf("skillDamageBonus(floor-blow skill) = (%d, %d), want (0, %d)", flat, pct, combat.SkillPercentZero)
	}
}
