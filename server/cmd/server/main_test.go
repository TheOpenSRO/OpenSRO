package main

import "testing"

// The monster stat curve is own design, but it must at least be internally
// consistent: monotonic in level (so the ladder actually ramps and doesn't
// repeat the old "level-5 weaker than level-1" bug), positive net damage
// against a starting weapon, and a rarity multiplier that only ever toughens.
func TestMonsterStatsForLevel(t *testing.T) {
	var prevHP, prevGold = -1, int64(-1)
	for lvl := 1; lvl <= 30; lvl++ {
		hp, def, atk, gold := monsterStatsForLevel(lvl, 0)
		if hp <= prevHP {
			t.Fatalf("level %d HP %d not greater than previous %d", lvl, hp, prevHP)
		}
		if gold <= prevGold {
			t.Fatalf("level %d gold %d not greater than previous %d", lvl, gold, prevGold)
		}
		if atk <= 0 {
			t.Fatalf("level %d attack %d must be positive", lvl, atk)
		}
		// A starting Copper Sword hits for ~16; a low-level monster must still
		// take real damage from it (net > 0), or it can't be killed.
		if lvl <= 5 && 16-def <= 0 {
			t.Fatalf("level %d defence %d leaves a starter weapon dealing nothing", lvl, def)
		}
		prevHP, prevGold = hp, gold
	}

	// Level clamps at 1 for a junk level.
	if hp0, _, _, _ := monsterStatsForLevel(0, 0); hp0 != mustHP(t, 1) {
		t.Fatalf("level 0 should clamp to level 1 stats")
	}

	// A rarer rank only toughens and pays more, never less.
	baseHP, _, _, baseGold := monsterStatsForLevel(10, 0)
	rareHP, _, _, rareGold := monsterStatsForLevel(10, 1)
	if rareHP <= baseHP || rareGold <= baseGold {
		t.Fatalf("rarity 1 (%d hp/%d gold) should exceed rarity 0 (%d/%d)", rareHP, rareGold, baseHP, baseGold)
	}
}

func mustHP(t *testing.T, level int) int {
	t.Helper()
	hp, _, _, _ := monsterStatsForLevel(level, 0)
	return hp
}
