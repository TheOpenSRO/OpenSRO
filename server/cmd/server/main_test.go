package main

import "testing"

// What is left of the monster stat curve is own design, and must at least be
// internally consistent: rising with level, positive net damage against a
// starting weapon, and a rarity multiplier that only ever pays more. HP is no
// longer part of it -- that is real characterdata (col 59), checked below.
func TestMonsterStatsForLevel(t *testing.T) {
	var prevGold = int64(-1)
	for lvl := 1; lvl <= 30; lvl++ {
		def, atk, gold := monsterStatsForLevel(lvl, 0)
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
		prevGold = gold
	}

	// Level clamps at 1 for a junk level.
	d0, a0, g0 := monsterStatsForLevel(0, 0)
	d1, a1, g1 := monsterStatsForLevel(1, 0)
	if d0 != d1 || a0 != a1 || g0 != g1 {
		t.Fatalf("level 0 should clamp to level 1 stats")
	}

	// A rarer rank pays more. It deliberately no longer touches HP: the real
	// per-species MaxHP already says what the species is.
	_, _, baseGold := monsterStatsForLevel(10, 0)
	_, _, rareGold := monsterStatsForLevel(10, 1)
	if rareGold <= baseGold {
		t.Fatalf("rarity 1 gold %d should exceed rarity 0 %d", rareGold, baseGold)
	}
}

// Every spawned species must carry its real characterdata values. A spec that
// forgot MaxHP would put a monster in the world that dies to the first hit,
// and one that forgot Level would break the exp/stat curve keyed off it.
//
// The HP numbers themselves are the game's own (col 59) and are deliberately
// NOT asserted to rise with level: a "_CLON" is a weaker slave version, so
// the level-4 Old Weasel really does sit under the level-3 Big-eyed Ghost.
func TestMonsterSpecsCarryRealData(t *testing.T) {
	if len(monsterSpecs) == 0 {
		t.Fatal("no monsters configured")
	}
	for _, spec := range monsterSpecs {
		if spec.MaxHP < 1 {
			t.Errorf("%s (%s): no real MaxHP set", spec.Name, spec.CodeName)
		}
		if spec.Level < 1 {
			t.Errorf("%s (%s): no Level set", spec.Name, spec.CodeName)
		}
		if spec.CodeName == "" {
			t.Errorf("%s: no CodeName -- the client cannot resolve a model", spec.Name)
		}
	}
}
