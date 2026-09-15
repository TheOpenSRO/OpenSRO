package main

import (
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/combat"
)

// What is left of the monster stat curve is own design, and must at least be
// internally consistent: rising with level and a rarity multiplier that only
// ever pays more. HP left in 2026-09-14 (real characterdata col 59) and
// DEFENCE left in 2026-09-15 (real col 71, plus col 73 as the percentage) --
// both are checked against the real table below.
func TestMonsterStatsForLevel(t *testing.T) {
	var prevGold = int64(-1)
	for lvl := 1; lvl <= 30; lvl++ {
		atk, gold := monsterStatsForLevel(lvl, 0)
		if gold <= prevGold {
			t.Fatalf("level %d gold %d not greater than previous %d", lvl, gold, prevGold)
		}
		if atk <= 0 {
			t.Fatalf("level %d attack %d must be positive", lvl, atk)
		}
		prevGold = gold
	}

	// Level clamps at 1 for a junk level.
	a0, g0 := monsterStatsForLevel(0, 0)
	a1, g1 := monsterStatsForLevel(1, 0)
	if a0 != a1 || g0 != g1 {
		t.Fatalf("level 0 should clamp to level 1 stats")
	}

	// A rarer rank pays more. It deliberately no longer touches HP: the real
	// per-species MaxHP already says what the species is.
	_, baseGold := monsterStatsForLevel(10, 0)
	_, rareGold := monsterStatsForLevel(10, 1)
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

// TestMonsterDefenceIsReal pins the per-species flat absorption against the
// ORIGINAL client's characterdata column 71, and checks the starter weapon can
// still hurt the early ladder through the game's own mitigation.
//
// Recovered: Formula_MitigatePhysicalDamage (0040e450) fetches param 5 as the
// flat term and param 7 as the percentage, and GObjMob_PublishStats publishes
// characterdata cols 71 and 73 into exactly those two params.
func TestMonsterDefenceIsReal(t *testing.T) {
	want := map[string]int{
		"MOB_CH_MANGNYANG": 7, "MOB_CH_BIGEYEGHOST_CLON": 9, "MOB_CH_BIGEYEGHOST": 9,
		"MOB_CH_GYO_CLON": 12, "MOB_CH_GYO": 12, "MOB_CH_WATERGHOST_CLON": 15,
		"MOB_CH_WATERGHOST": 15, "MOB_CH_TOMBSTONE_CLON": 15, "MOB_CH_STONEGHOST": 22,
		"MOB_CH_YEOHA": 22, "MOB_WC_EARTHGHOST": 103,
	}
	seen := 0
	for _, spec := range monsterSpecs {
		w, ok := want[spec.CodeName]
		if !ok {
			continue
		}
		seen++
		if spec.Defense != w {
			t.Errorf("%s defence = %d, want the real col-71 value %d", spec.CodeName, spec.Defense, w)
		}
	}
	if seen != len(want) {
		t.Fatalf("checked %d species, expected %d -- the roster changed", seen, len(want))
	}

	// The whole ladder must stay killable with a starting weapon under the
	// game's real mitigation, or the grounded numbers would have made the
	// early game unplayable rather than more accurate.
	for _, spec := range monsterSpecs {
		if spec.Level > 10 {
			continue
		}
		// A Copper Sword tops out around 16.
		if got := combat.MitigateDamage(16, spec.Level, spec.Defense); got < 1 {
			t.Fatalf("%s (lvl %d, def %d) takes %d from a starter weapon",
				spec.CodeName, spec.Level, spec.Defense, got)
		}
	}
}
