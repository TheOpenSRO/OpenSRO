package main

import (
	"context"
	"errors"
	"math"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/worldmap"
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
		// Every species must be placeable: either it carries real npcpos
		// rows that all convert, or it has an own-design anchor. A species
		// with neither would spawn at the world origin, on top of the
		// player's own landing spot.
		if len(spec.Spawns) > 0 {
			for _, s := range spec.Spawns {
				rx, ry := worldmap.RegionXY(s.RegionID)
				if _, _, ok := worldmap.ToZoneWorld(spec.Zone, rx, ry, s.LocalX, s.LocalZ); !ok {
					t.Errorf("%s: real spawn in region %d/%d cannot convert -- zone %q has no centre region",
						spec.Name, rx, ry, spec.Zone)
				}
			}
			continue
		}
		if spec.X == 0 && spec.Z == 0 {
			t.Errorf("%s: no real spawns and no anchor -- would spawn on the player", spec.Name)
		}
	}
}

// The real Mangyang placements, wired through to the world coordinates the
// client and server actually exchange.
//
// This is the value-through-the-wire check for the npcpos placements: the
// four rows in the table are region 96/168's ENTIRE npcpos content, all four
// of them id 1933 (MOB_CH_MANGNYANG, level 1, 54 HP in characterdata -- the
// same species and numbers this spec already carried), and each converts to
// a world position measured on the render box rather than derived. Every one
// was confirmed to stand on a single walkable surface with no blocking edge
// within 40 units before it was wired.
//
// The expected values are rounded to whole units because that is the
// precision the measurement was printed at; the real rows carry fractions.
func TestMangyangStandsWhereTheGamePutsIt(t *testing.T) {
	var spec monsterSpec
	for _, s := range monsterSpecs {
		if s.CodeName == "MOB_CH_MANGNYANG" {
			spec = s
			break
		}
	}
	if spec.CodeName == "" {
		t.Fatal("Mangyang is not in the roster")
	}
	if len(spec.Spawns) != 4 {
		t.Fatalf("Mangyang has %d real spawns, want 4 -- region 96/168 has exactly four npcpos rows", len(spec.Spawns))
	}
	want := [][2]float64{{130, 2280}, {882, 2279}, {-406, 2409}, {301, 2857}}
	for i, s := range spec.Spawns {
		if s.RegionID != 24744 {
			t.Errorf("spawn %d is in region %d, want 24744 (96/168)", i, s.RegionID)
		}
		rx, ry := worldmap.RegionXY(s.RegionID)
		x, z, ok := worldmap.ToZoneWorld(spec.Zone, rx, ry, s.LocalX, s.LocalZ)
		if !ok {
			t.Fatalf("spawn %d did not convert", i)
		}
		if math.Abs(x-want[i][0]) > 1 || math.Abs(z-want[i][1]) > 1 {
			t.Errorf("spawn %d -> (%.0f, %.0f), want the measured (%.0f, %.0f)",
				i, x, z, want[i][0], want[i][1])
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

// TestMonsterAttackIsReal pins each species' damage range against the ORIGINAL
// client's tables, and checks a starting character survives the early ladder.
//
// A monster attacks with a SKILL, not a weapon: characterdata col 83 is its
// primary attack skill id, named after the species itself
// (MSKILL_CH_MANGNYANG_ATTACK01 = 160), and that skill's 'att' param carries
// the damage range. With no weapon to scale, the project's already-grounded
// skill formula collapses to rand(min, max).
func TestMonsterAttackIsReal(t *testing.T) {
	want := map[string][2]int{
		"MOB_CH_MANGNYANG": {17, 19}, "MOB_CH_BIGEYEGHOST_CLON": {21, 23},
		"MOB_CH_BIGEYEGHOST": {25, 29}, "MOB_CH_GYO_CLON": {30, 34},
		"MOB_CH_GYO": {35, 40}, "MOB_CH_WATERGHOST_CLON": {41, 47},
		"MOB_CH_WATERGHOST": {47, 54}, "MOB_CH_TOMBSTONE_CLON": {74, 83},
		"MOB_CH_STONEGHOST": {60, 70}, "MOB_CH_YEOHA": {67, 79},
		"MOB_WC_EARTHGHOST": {219, 261},
	}
	seen := 0
	for _, spec := range monsterSpecs {
		w, ok := want[spec.CodeName]
		if !ok {
			continue
		}
		seen++
		if spec.AttackMin != w[0] || spec.AttackMax != w[1] {
			t.Errorf("%s attack = %d-%d, want the real skill range %d-%d",
				spec.CodeName, spec.AttackMin, spec.AttackMax, w[0], w[1])
		}
		if spec.AttackMin > spec.AttackMax {
			t.Errorf("%s has an inverted range %d-%d", spec.CodeName, spec.AttackMin, spec.AttackMax)
		}
	}
	if seen != len(want) {
		t.Fatalf("checked %d species, expected %d -- the roster changed", seen, len(want))
	}

	// A fresh character must survive a reasonable number of blows from the
	// monster it actually starts on -- the level-1 one. This is a sanity check
	// on the wiring, not a judgement on the game's balance: a level-3 monster
	// killing an unarmoured level-1 character in seven hits is the real game
	// being dangerous, not a bug, and an earlier version of this test wrongly
	// flagged exactly that. Real numbers do not get rejected because an
	// invented threshold dislikes them.
	for _, spec := range monsterSpecs {
		if spec.Level != 1 {
			continue
		}
		hits := character.StartingMaxHP / spec.AttackMax
		if hits < 8 {
			t.Errorf("%s (the starting monster) kills a fresh character in %d unarmoured hits",
				spec.CodeName, hits)
		}
	}

	// The range must rise with level across the ladder, which is the property
	// that makes the roster a progression at all.
	prev := 0
	for _, spec := range monsterSpecs {
		if spec.Zone != "jangan" || spec.AttackMax == 0 {
			continue
		}
		if spec.Level <= 7 && spec.AttackMax <= prev {
			t.Errorf("%s (lvl %d) attack %d does not exceed the previous rung's %d",
				spec.CodeName, spec.Level, spec.AttackMax, prev)
		}
		if spec.Level <= 7 {
			prev = spec.AttackMax
		}
	}
}

// TestMonsterGoldIsReal pins each species' gold range against levelgold.txt at
// its level, as shipped with the ORIGINAL client.
func TestMonsterGoldIsReal(t *testing.T) {
	byLevel := map[int][2]int64{
		1: {28, 59}, 2: {32, 66}, 3: {35, 74}, 4: {39, 81}, 5: {42, 88},
		6: {46, 96}, 7: {49, 103}, 8: {53, 110}, 9: {56, 118}, 10: {60, 125},
		27: {119, 250},
	}
	for _, spec := range monsterSpecs {
		w, ok := byLevel[spec.Level]
		if !ok {
			continue
		}
		if spec.GoldMin != w[0] || spec.GoldMax != w[1] {
			t.Errorf("%s (lvl %d) gold = %d-%d, want levelgold's %d-%d",
				spec.CodeName, spec.Level, spec.GoldMin, spec.GoldMax, w[0], w[1])
		}
	}
}

// TestRosterCarriesRealObjectIDs: every roster species names its characterdata
// id (what npcpos places by), distinct across the roster, so -npcpos-csv can
// give each its real placements.
func TestRosterCarriesRealObjectIDs(t *testing.T) {
	seen := map[int64]string{}
	for _, spec := range monsterSpecs {
		if spec.RefObjID <= 0 {
			t.Errorf("%s (%s) has no RefObjID", spec.Name, spec.CodeName)
			continue
		}
		if prev, dup := seen[spec.RefObjID]; dup && prev != spec.CodeName {
			t.Errorf("RefObjID %d is both %s and %s", spec.RefObjID, prev, spec.CodeName)
		}
		seen[spec.RefObjID] = spec.CodeName
	}
}

// TestGMSpawnCarriesBCRadius: a monster the GM console's /spawn puts in the
// world carries the same BCRadius (characterdata col 50, round 247) and the
// same primary-attack ReuseDelay/Range (round 254) as the roster spawn of
// that species. Until round 488 gmSpecies left all three out, so a
// GM-spawned Mangyang had a BCRadius of 0 and combat.ApproachBand's base
// was 6 units short of a roster one's.
func TestGMSpawnCarriesBCRadius(t *testing.T) {
	species := gmSpecies()
	if len(species) != len(monsterSpecs) {
		t.Fatalf("gmSpecies has %d entries, the roster %d", len(species), len(monsterSpecs))
	}
	for i, spec := range monsterSpecs {
		got := species[i].Species
		want := spec.BCRadius
		if want == 0 {
			want = combat.PlayerBCRadius
		}
		if got.BCRadius != want {
			t.Errorf("%s: GM spawn BCRadius = %d, want %d", spec.CodeName, got.BCRadius, want)
		}
		if got.AttackReuseMs != spec.AttackReuseMs || got.AttackRange != spec.AttackRange {
			t.Errorf("%s: GM spawn attack reuse/range = %d/%d, want %d/%d", spec.CodeName,
				got.AttackReuseMs, got.AttackRange, spec.AttackReuseMs, spec.AttackRange)
		}
	}
	for _, sp := range species {
		if sp.CodeName == "MOB_CH_MANGNYANG" {
			if sp.BCRadius != 6 {
				t.Errorf("Mangyang BCRadius = %d, want 6 (characterdata col 50)", sp.BCRadius)
			}
			return
		}
	}
	t.Error("Mangyang missing from gmSpecies")
}

// fakeItemRows is a reference item store holding a fixed set of rows; id -1
// answers a lookup error.
type fakeItemRows map[int64]*refdata.Item

func (f fakeItemRows) GetItem(_ context.Context, id int64) (*refdata.Item, error) {
	if id == -1 {
		return nil, errors.New("lookup failed")
	}
	return f[id], nil
}

// The adapter main wires into grounditem.Hub.SetTradeLookup passes a row's
// CanTrade through as known, and answers unknown -- never bound -- for a
// missing row or a failed lookup, so only a real CanTrade = 0 row reserves a
// drop past the 30 s window (GObjPC::FUN_004901c0, round 492).
func TestGroundTradeLookupAdapter(t *testing.T) {
	lookup := groundTradeLookup(context.Background(), fakeItemRows{
		500: {ID: 500, CanTrade: false},
		4:   {ID: 4, CanTrade: true},
	})
	for _, c := range []struct {
		id              int64
		canTrade, known bool
	}{
		{500, false, true}, // untradeable row: bound
		{4, true, true},    // tradeable row
		{999, true, false}, // not in the store
		{-1, true, false},  // the store failed
	} {
		ct, known := lookup(c.id)
		if ct != c.canTrade || known != c.known {
			t.Errorf("groundTradeLookup(%d) = (%v, %v), want (%v, %v)", c.id, ct, known, c.canTrade, c.known)
		}
	}
}
