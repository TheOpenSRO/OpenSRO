package combat

import (
	"math"
	"math/rand"
	"testing"
)

func TestSpawnStartsAtFullHP(t *testing.T) {
	h := NewHub()
	m := h.Spawn("jangan", "Mangyang", 0, 0, 0, 100, 10, 5, 50)
	if m.HP != 100 || m.MaxHP != 100 {
		t.Fatalf("got HP=%d MaxHP=%d, want both 100", m.HP, m.MaxHP)
	}
	if m.ID == 0 {
		t.Fatal("expected a nonzero assigned ID")
	}
}

func TestSpawnAssignsUniqueIDs(t *testing.T) {
	h := NewHub()
	m1 := h.Spawn("jangan", "Mangyang", 0, 0, 0, 100, 10, 5, 50)
	m2 := h.Spawn("jangan", "Mangyang", 0, 0, 0, 100, 10, 5, 50)
	if m1.ID == m2.ID {
		t.Fatalf("expected unique IDs, got %d and %d", m1.ID, m2.ID)
	}
}

func TestGetReturnsLiveMonster(t *testing.T) {
	h := NewHub()
	spawned := h.Spawn("jangan", "Mangyang", 0, 0, 0, 100, 10, 5, 50)

	got, ok := h.Get(spawned.ID)
	if !ok {
		t.Fatal("expected to find the spawned monster")
	}
	if got != *spawned {
		t.Fatalf("got %+v, want %+v", got, *spawned)
	}
}

func TestGetUnknownID(t *testing.T) {
	h := NewHub()
	if _, ok := h.Get(999); ok {
		t.Fatal("expected ok=false for an unknown monster ID")
	}
}

func TestApplyDamageReducesHP(t *testing.T) {
	h := NewHub()
	m := h.Spawn("jangan", "Mangyang", 0, 0, 0, 100, 10, 5, 50)

	updated, died, ok := h.ApplyDamage(m.ID, 30)
	if !ok {
		t.Fatal("expected ok=true")
	}
	if died {
		t.Fatal("30 damage to 100 HP should not kill it")
	}
	if updated.HP != 70 {
		t.Fatalf("got HP %d, want 70", updated.HP)
	}
}

func TestApplyDamageKillsAndRemoves(t *testing.T) {
	h := NewHub()
	m := h.Spawn("jangan", "Mangyang", 0, 0, 0, 100, 10, 5, 50)

	updated, died, ok := h.ApplyDamage(m.ID, 150)
	if !ok || !died {
		t.Fatalf("got died=%v ok=%v, want both true", died, ok)
	}
	if updated.HP != 0 {
		t.Fatalf("got HP %d, want 0 (should clamp, not go negative)", updated.HP)
	}

	if _, stillThere := h.Get(m.ID); stillThere {
		t.Fatal("expected the monster to be removed from the hub after dying")
	}
}

func TestApplyDamageUnknownID(t *testing.T) {
	h := NewHub()
	_, died, ok := h.ApplyDamage(999, 10)
	if ok || died {
		t.Fatalf("got died=%v ok=%v, want both false for an unknown monster", died, ok)
	}
}

func TestInZoneOnlyReturnsMatchingZone(t *testing.T) {
	h := NewHub()
	a := h.Spawn("jangan", "Mangyang", 0, 0, 0, 100, 10, 5, 50)
	b := h.Spawn("jangan", "Weasel", 0, 0, 0, 80, 3, 4, 15)
	h.Spawn("donwhang", "Earth Ghost", 0, 0, 0, 350, 18, 14, 120)

	got := h.InZone("jangan")
	if len(got) != 2 {
		t.Fatalf("got %d monsters, want 2", len(got))
	}
	ids := map[int64]bool{got[0].ID: true, got[1].ID: true}
	if !ids[a.ID] || !ids[b.ID] {
		t.Fatalf("got IDs %v, want %d and %d", ids, a.ID, b.ID)
	}
}

func TestInZoneEmptyForUnknownZone(t *testing.T) {
	h := NewHub()
	h.Spawn("jangan", "Mangyang", 0, 0, 0, 100, 10, 5, 50)
	if got := h.InZone("nowhere"); len(got) != 0 {
		t.Fatalf("got %d monsters, want 0", len(got))
	}
}

func TestInZoneExcludesDeadMonsters(t *testing.T) {
	h := NewHub()
	m := h.Spawn("jangan", "Mangyang", 0, 0, 0, 10, 0, 0, 50)
	if _, died, ok := h.ApplyDamage(m.ID, 10); !ok || !died {
		t.Fatalf("setup: got died=%v ok=%v, want both true", died, ok)
	}
	if got := h.InZone("jangan"); len(got) != 0 {
		t.Fatalf("got %d monsters, want 0 (dead monster should be gone)", len(got))
	}
}

// TestMitigateDamage pins the game's own mitigation SHAPE -- a percentage
// reduction plus a flat term -- against the flat subtraction it replaced.
//
// Recovered from Formula_MitigatePhysicalDamage (0040e450) and its magical twin
// (0040e830): damage = raw / (1 + pct/100) - flat. See MitigateDamage.
func TestMitigateDamage(t *testing.T) {
	// A level-10 monster mitigates 10% (characterdata col 73 = its level).
	// 100 / 1.10 = 90.909... -> 91, minus a flat 5 = 86.
	if got := MitigateDamage(100, 10, 5); got != 86 {
		t.Fatalf("MitigateDamage(100, 10, 5) = %d, want 86", got)
	}
	// No percentage is the old flat behaviour exactly.
	if got := MitigateDamage(100, 0, 30); got != 70 {
		t.Fatalf("MitigateDamage(100, 0, 30) = %d, want 70", got)
	}
	// The percentage is a DIVISOR, not a subtraction of a fraction: 100% halves
	// rather than zeroing, which is the whole point of the shape.
	if got := MitigateDamage(100, 100, 0); got != 50 {
		t.Fatalf("MitigateDamage(100, 100, 0) = %d, want 50 (divide, not subtract)", got)
	}
	// Mitigation is monotonic in the percentage -- the property that settled
	// which side of the fight owns it.
	prev := MitigateDamage(1000, 0, 0)
	for pct := 1; pct <= 120; pct++ {
		got := MitigateDamage(1000, pct, 0)
		if got > prev {
			t.Fatalf("mitigation not monotonic: pct %d gave %d, up from %d", pct, got, prev)
		}
		prev = got
	}
	// Floor is 1, not the game's 0: srrevamp has no hit/evade roll, so a
	// zero-damage hit would read as a bug rather than a miss. Disclosed.
	if got := MitigateDamage(5, 90, 500); got != 1 {
		t.Fatalf("over-mitigated hit = %d, want the floor 1", got)
	}
	// A negative percentage cannot amplify damage.
	if got := MitigateDamage(100, -50, 0); got != 100 {
		t.Fatalf("MitigateDamage(100, -50, 0) = %d, want 100", got)
	}
}

// TestRollDamage pins the recovered damage roll: uniform in [min, max],
// inclusive at both ends, with a non-positive span yielding the max.
//
// Recovered from Formula_RollWeaponDamage (0040f8d0) and its twin (0040f930):
//
//	min = GetParam(191); max = GetParam(190)
//	if max - min < 1 { return 0 }
//	return rand() % (max - min + 1) + min
func TestRollDamage(t *testing.T) {
	r := rand.New(rand.NewSource(1))

	// Both ends are reachable, and nothing outside the range ever is.
	seen := map[int]bool{}
	for i := 0; i < 2000; i++ {
		v := RollDamage(10, 14, r)
		if v < 10 || v > 14 {
			t.Fatalf("roll %d outside [10, 14]", v)
		}
		seen[v] = true
	}
	for want := 10; want <= 14; want++ {
		if !seen[want] {
			t.Errorf("value %d never rolled in 2000 tries -- range is not inclusive", want)
		}
	}

	// A zero-width range is the value itself, not a panic.
	if got := RollDamage(7, 7, r); got != 7 {
		t.Fatalf("RollDamage(7, 7) = %d, want 7", got)
	}
	// Reversed bounds are tolerated rather than producing nonsense.
	if got := RollDamage(9, 3, r); got < 3 || got > 9 {
		t.Fatalf("RollDamage(9, 3) = %d, want something in [3, 9]", got)
	}
	// A nil source rolls the maximum, so a caller that wants a fixed blow
	// does not need a separate code path.
	if got := RollDamage(4, 11, nil); got != 11 {
		t.Fatalf("RollDamage(4, 11, nil) = %d, want the max 11", got)
	}
}

// TestRollGold pins the per-level gold roll and its fallback.
//
// The range is real client data (levelgold.txt: level 1 = 28-59, level 10 =
// 60-125) and the binary's gold table is the one a gold item is spawned from;
// the join between file and table is inferred, and RollGold's doc comment says
// so. What this test guards is the mechanics: in range, inclusive, and a clean
// fall back to the flat disclosed reward when a monster has no range.
func TestRollGold(t *testing.T) {
	r := rand.New(rand.NewSource(7))

	seen := map[int64]bool{}
	for i := 0; i < 4000; i++ {
		v := RollGold(28, 59, 999, r)
		if v < 28 || v > 59 {
			t.Fatalf("gold %d outside the level-1 range [28, 59]", v)
		}
		seen[v] = true
	}
	if !seen[28] || !seen[59] {
		t.Error("the level-1 gold range is not inclusive at both ends")
	}

	// No range means the flat disclosed reward, not zero -- a monster whose
	// level the table does not cover must still pay something.
	if got := RollGold(0, 0, 42, r); got != 42 {
		t.Fatalf("RollGold with no range = %d, want the flat fallback 42", got)
	}
	// An inverted range is treated as absent rather than panicking.
	if got := RollGold(90, 10, 42, r); got != 42 {
		t.Fatalf("RollGold with an inverted range = %d, want the fallback 42", got)
	}
	// A zero-width range is that value.
	if got := RollGold(70, 70, 42, r); got != 70 {
		t.Fatalf("RollGold(70, 70) = %d, want 70", got)
	}
	// A nil generator takes the maximum, keeping callers deterministic.
	if got := RollGold(28, 59, 0, nil); got != 59 {
		t.Fatalf("RollGold with a nil source = %d, want the max 59", got)
	}
}

// The level-advantage term, pinned to its citation.
//
// Formula_MitigatePhysicalDamage (0040e450) ends with
// `if defLvl < atkLvl { damage = (FUN_0040fd60() + 1.0) * damage }`, and
// FUN_0040fd60 is `clamp((level(ECX) - level(EDI)) * 0.03, 0, 0.3)` -- read off
// the disassembly because the decompiled register arguments do not say which
// level is subtracted from which. 0.03 is the double at .rdata 0x00b45dc8 and
// the 0.3 ceiling is the float at 0x00b45b8c.
func TestLevelAdvantage(t *testing.T) {
	for _, tc := range []struct {
		name     string
		atk, def int
		want     float64
	}{
		{"same level is no bonus", 10, 10, 1.00},
		{"being out-levelled is no penalty", 5, 20, 1.00},
		{"one level up is 3%", 11, 10, 1.03},
		{"five levels up is 15%", 15, 10, 1.15},
		{"ten levels up hits the cap", 20, 10, 1.30},
		{"beyond the cap stays capped", 99, 1, 1.30},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := LevelAdvantage(tc.atk, tc.def)
			if math.Abs(got-tc.want) > 1e-9 {
				t.Errorf("LevelAdvantage(%d, %d) = %g, want %g", tc.atk, tc.def, got, tc.want)
			}
		})
	}
}

// The constants themselves, so a later "let's tune it" edit has to delete a
// citation to do it.
func TestLevelAdvantageConstantsAreTheRecoveredOnes(t *testing.T) {
	if LevelAdvantagePerLevel != 0.03 {
		t.Errorf("per-level = %g, want 0.03 (.rdata 0x00b45dc8)", LevelAdvantagePerLevel)
	}
	if LevelAdvantageCap != 0.30 {
		t.Errorf("cap = %g, want 0.30 (.rdata 0x00b45b8c)", LevelAdvantageCap)
	}
}

// ApplyLevelAdvantage scales an already-mitigated blow and never rounds a hit
// away to nothing.
func TestApplyLevelAdvantage(t *testing.T) {
	if got := ApplyLevelAdvantage(100, 20, 10); got != 130 {
		t.Errorf("capped bonus on 100 = %d, want 130", got)
	}
	if got := ApplyLevelAdvantage(100, 10, 10); got != 100 {
		t.Errorf("no advantage must not change the blow, got %d", got)
	}
	if got := ApplyLevelAdvantage(1, 1, 50); got != 1 {
		t.Errorf("a minimum hit stays 1, got %d", got)
	}
}

// The chance roll, pinned to its citation.
//
// FUN_00599cc0 (reached via FUN_005a1a20 from Combat_ResolveDamage):
// chance 0 never succeeds, chance >= 100 always succeeds without rolling, and
// otherwise success is `chance >= rand() % 101` -- inclusive at both ends,
// modulus 0x65.
func TestRollChanceEdges(t *testing.T) {
	r := rand.New(rand.NewSource(1))
	if RollChance(0, r) {
		t.Error("a chance of 0 must never succeed")
	}
	if RollChance(-5, r) {
		t.Error("a negative chance must never succeed")
	}
	if !RollChance(50, nil) {
		t.Error("a nil generator takes the maximum outcome, like RollDamage")
	}
	if RollChance(0, nil) {
		t.Error("...but a chance of 0 is still never, generator or not")
	}
	for _, c := range []int{100, 101, 1000} {
		if !RollChance(c, r) {
			t.Errorf("a chance of %d must always succeed", c)
		}
	}
	if ChanceRollSides != 101 {
		t.Errorf("roll sides = %d, want 101 (the binary's modulus is 0x65)", ChanceRollSides)
	}
	if CriticalMultiplier != 2 {
		t.Errorf("critical multiplier = %d, want 2", CriticalMultiplier)
	}
}

// A chance of n succeeds about n% of the time. Loose bounds -- this is a check
// that the roll is not off by a factor or inverted, not a statistics exam.
func TestRollChanceRoughlyMatchesItsPercent(t *testing.T) {
	const trials = 200000
	for _, chance := range []int{2, 20, 50, 90} {
		r := rand.New(rand.NewSource(int64(chance)))
		hits := 0
		for i := 0; i < trials; i++ {
			if RollChance(chance, r) {
				hits++
			}
		}
		got := float64(hits) * 100 / trials
		// The true rate is (chance+1)/101, a shade above chance%.
		want := float64(chance+1) * 100 / 101
		if math.Abs(got-want) > 1.0 {
			t.Errorf("chance %d succeeded %.2f%% of the time, want about %.2f%%", chance, got, want)
		}
	}
}

// The shared pipeline, in the order the engine runs it.
//
// A nil generator takes the maximum outcome on every roll, so a chance of 0
// still never fires and any positive chance always does -- which makes the
// ordering assertions exact.
func TestResolveBlowOrder(t *testing.T) {
	for _, tc := range []struct {
		name               string
		base, pct, flat    int
		crit, block        int
		atkLevel, defLevel int
		want               Blow
	}{
		{
			name: "plain blow: mitigate only",
			base: 100, pct: 0, flat: 30, want: Blow{Damage: 70},
		},
		{
			name: "a block skips everything, including the flat floor",
			base: 100, flat: 30, block: 1, crit: 1, atkLevel: 20, defLevel: 1,
			want: Blow{Blocked: true},
		},
		{
			name: "a critical doubles the MITIGATED damage, not the raw",
			base: 100, flat: 30, crit: 1, want: Blow{Damage: 140, Critical: true},
		},
		{
			name: "the level term comes last, after the critical",
			base: 100, flat: 30, crit: 1, atkLevel: 20, defLevel: 10,
			want: Blow{Damage: 182, Critical: true}, // (100-30)*2 = 140, +30% = 182
		},
		{
			name: "percentage mitigation runs before the flat term",
			base: 100, pct: 100, flat: 10, want: Blow{Damage: 40}, // 100/2 - 10
		},
		{
			name: "being out-levelled is no penalty",
			base: 100, flat: 30, atkLevel: 1, defLevel: 50, want: Blow{Damage: 70},
		},
		{
			name: "an unknown level skips the term entirely",
			base: 100, flat: 30, atkLevel: 0, defLevel: 10, want: Blow{Damage: 70},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := ResolveBlow(tc.base, tc.pct, tc.flat, tc.crit, tc.block,
				tc.atkLevel, tc.defLevel, nil)
			if got != tc.want {
				t.Errorf("ResolveBlow = %+v, want %+v", got, tc.want)
			}
		})
	}
}

// A blocked blow deals nothing -- never the floor of 1 that MitigateDamage
// keeps, because a block skips mitigation rather than reducing its result.
func TestResolveBlowBlockedIsZeroNotOne(t *testing.T) {
	got := ResolveBlow(1000, 0, 0, 0, 100, 0, 0, nil)
	if !got.Blocked || got.Damage != 0 {
		t.Errorf("blocked blow = %+v, want {Damage:0 Blocked:true}", got)
	}
}

// TestReinforceDamage pins the Strength-to-damage term against the engine's
// own numbers rather than a curve.
//
// The magnitudes here are real: 306 and 342 are itemdata columns 105 and 107
// for a Copper Sword, and they are also the FLOORS of those two columns across
// all 1,568 weapon rows -- which is what matches them to the innate defaults
// GObjPC_InitStats writes from .rdata, 30.6 for param 34 and 34.2 for param 36.
// A character with 20 Strength therefore adds 20*0.306 = 6.12 to the bottom of
// its range and 20*0.342 = 6.84 to the top.
func TestReinforceDamage(t *testing.T) {
	for _, tc := range []struct {
		name      string
		str       int
		reinforce float64
		want      int
	}{
		{"copper sword min at 20 Str", 20, 306, 6},  // 6.12
		{"copper sword max at 20 Str", 20, 342, 7},  // 6.84, rounds up
		{"the engine's innate floor", 100, 306, 31}, // 30.6
		{"no strength", 0, 306, 0},
		{"no reinforce column", 20, 0, 0},
		{"an export predating the columns", 20, 0, 0},
		{"negative strength cannot subtract", -5, 306, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := ReinforceDamage(tc.str, tc.reinforce); got != tc.want {
				t.Errorf("ReinforceDamage(%d, %v) = %d, want %d", tc.str, tc.reinforce, got, tc.want)
			}
		})
	}
}

// TestReinforceDamageRounds guards the specific decision that it rounds rather
// than truncates. The engine carries the whole chain in floats and rounds once
// at the end, so truncating here would bias every blow down: 6.84 is a 7, not
// a 6.
func TestReinforceDamageRounds(t *testing.T) {
	if got := ReinforceDamage(20, 342); got == 6 {
		t.Fatal("ReinforceDamage truncated 6.84 to 6; the engine rounds")
	}
}
