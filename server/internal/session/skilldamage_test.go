package session

import (
	"strings"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/leveldata"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
)

// Skill damage is real, and it comes in TWO halves that the engine keeps on
// opposite sides of mitigation: a flat roll added to the weapon's damage before
// mitigation, and a percentage applied to the blow after it. skillDamageBonus
// returns them separately for that reason -- see combat.ApplySkillPercent.
func TestSkillDamageBonusUsesRealParams(t *testing.T) {
	// SKILL_CH_SWORD_SMASH_A_01: 143% of weapon damage, plus 15-18 flat.
	smash := &refdata.Skill{BasicLevel: 1, AttackPercent: 143, DamageMin: 15, DamageMax: 18}
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
	base := &refdata.Skill{BasicLevel: 1, AttackPercent: 60}
	if flat, pct := skillDamageBonus(base); flat != 0 || pct != 60 {
		t.Errorf("a 60%% basic swing: got flat %d pct %d, want 0 and 60", flat, pct)
	}

	// A skill with no 'att' (a buff, a heal, or refdata predating the
	// columns) falls back to the disclosed per-level stand-in, which is flat
	// and therefore carries no percentage.
	buff := &refdata.Skill{BasicLevel: 3}
	flat, pct := skillDamageBonus(buff)
	if want := 3 * DisclosedSkillDamagePerLevel; flat != want || pct != 0 {
		t.Errorf("a skill with no att parameter: got flat %d pct %d, want the disclosed %d and 0", flat, pct, want)
	}

	// A fixed flat value (min == max) must not panic on the range roll.
	fixed := &refdata.Skill{BasicLevel: 1, AttackPercent: 100, DamageMin: 7, DamageMax: 7}
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
