package session

import (
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/refdata"
)

// Skill damage is real: a skill deals a percentage of the wielder's weapon
// damage plus a flat roll, both from its own 'att' parameter. What the bonus
// reports is the DIFFERENCE the skill makes, since the caller already applies
// the plain weapon damage.
func TestSkillDamageBonusUsesRealParams(t *testing.T) {
	// SKILL_CH_SWORD_SMASH_A_01: 143% of weapon damage, plus 15-18 flat.
	smash := &refdata.Skill{BasicLevel: 1, AttackPercent: 143, DamageMin: 15, DamageMax: 18}
	for i := 0; i < 50; i++ {
		got := skillDamageBonus(smash, 100)
		// 143% of 100 is 143, a surplus of 43, plus 15..18.
		if got < 43+15 || got > 43+18 {
			t.Fatalf("smash on a 100-damage weapon: got %d, want 58..61", got)
		}
	}

	// SKILL_CH_SWORD_BASE_01: 60% and no flat damage -- a plain swing is
	// weaker than the weapon alone, so the bonus is negative.
	base := &refdata.Skill{BasicLevel: 1, AttackPercent: 60}
	if got := skillDamageBonus(base, 100); got != -40 {
		t.Errorf("a 60%% basic swing on a 100-damage weapon: got %d, want -40", got)
	}

	// A skill with no 'att' (a buff, a heal, or refdata predating the
	// columns) falls back to the disclosed per-level stand-in.
	buff := &refdata.Skill{BasicLevel: 3}
	if got, want := skillDamageBonus(buff, 100), 3*DisclosedSkillDamagePerLevel; got != want {
		t.Errorf("a skill with no att parameter: got %d, want the disclosed %d", got, want)
	}

	// A fixed flat value (min == max) must not panic on the range roll.
	fixed := &refdata.Skill{BasicLevel: 1, AttackPercent: 100, DamageMin: 7, DamageMax: 7}
	if got := skillDamageBonus(fixed, 50); got != 7 {
		t.Errorf("a fixed flat bonus: got %d, want 7", got)
	}
}
