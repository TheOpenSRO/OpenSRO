package combat

import (
	"math"
	"math/rand"
	"reflect"
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

// Round 542: each spawn draws its Heading from the hub's spawn-heading roll,
// once, and keeps it; a copy from Get carries it. A hub given no roll hatches
// every monster at 0. Before round 542 a monster carried no heading at all
// (the monster AI's brain rolled its own), so nothing could push one.
func TestSpawnSpeciesRollsTheHatchHeading(t *testing.T) {
	if m := NewHub().SpawnSpecies("jangan", Species{Name: "Mangyang"}, 0, 0, 0, 54, 7, 0, 0); m.Heading != 0 {
		t.Fatalf("a hub with no roll: heading %g, want 0", m.Heading)
	}
	h := NewHub()
	draws := []float64{1.5, 4.25}
	calls := 0
	h.SetSpawnHeadingRoll(func() float64 {
		v := draws[calls]
		calls++
		return v
	})
	a := h.SpawnSpecies("jangan", Species{Name: "Mangyang"}, 0, 0, 0, 54, 7, 0, 0)
	b := h.Spawn("jangan", "Mangyang", 10, 0, 0, 54, 7, 0, 0)
	if calls != 2 || a.Heading != 1.5 || b.Heading != 4.25 {
		t.Fatalf("headings %g, %g after %d rolls, want 1.5 and 4.25 after 2", a.Heading, b.Heading, calls)
	}
	h.StepCells(1, nil, nil) // nothing moving; the heading is fixed at the spawn
	if got, _ := h.Get(a.ID); got.Heading != 1.5 {
		t.Fatalf("Get's copy carries heading %g, want 1.5", got.Heading)
	}
}

func TestGetReturnsLiveMonster(t *testing.T) {
	h := NewHub()
	spawned := h.Spawn("jangan", "Mangyang", 0, 0, 0, 100, 10, 5, 50)

	got, ok := h.Get(spawned.ID)
	if !ok {
		t.Fatal("expected to find the spawned monster")
	}
	// DeepEqual since round 554: Monster carries a skill list, so the struct
	// is no longer comparable with ==.
	if !reflect.DeepEqual(got, *spawned) {
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
				tc.atkLevel, tc.defLevel, nil, nil)
			if got != tc.want {
				t.Errorf("ResolveBlow = %+v, want %+v", got, tc.want)
			}
		})
	}
}

// A blocked blow deals nothing -- never the floor of 1 that MitigateDamage
// keeps, because a block skips mitigation rather than reducing its result.
func TestResolveBlowBlockedIsZeroNotOne(t *testing.T) {
	got := ResolveBlow(1000, 0, 0, 0, 100, 0, 0, nil, nil)
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

// TestApplySkillPercentComesAfterMitigation pins the ORDER, which is the only
// reason ApplySkillPercent is a separate step rather than folded into the raw
// roll.
//
// The engine divides by the defender's reduction, subtracts its flat absorb,
// clamps at zero, and only THEN multiplies by the skill's percentage
// (Formula_MitigatePhysicalDamage, 0040e450). Doing it the other way round
// scales the defence away: against 20 flat armour, a 200% skill on a 100 blow
// is 2*(100-20) = 160 the engine's way, but 2*100-20 = 180 the wrong way.
func TestApplySkillPercentComesAfterMitigation(t *testing.T) {
	const raw, flat, pct = 100, 20, 200

	mitigated := MitigateDamage(raw, 0, flat)
	correct := ApplySkillPercent(mitigated, pct)

	// The order this code used before 2026-09-15: scale first, mitigate after.
	wrong := MitigateDamage(ApplySkillPercent(raw, pct), 0, flat)

	if correct != 160 {
		t.Errorf("mitigate-then-scale = %d, want 160", correct)
	}
	if wrong != 180 {
		t.Errorf("scale-then-mitigate = %d, want 180 (the bug being pinned)", wrong)
	}
	if correct == wrong {
		t.Fatal("the two orders agree, so this test cannot detect the regression")
	}
}

// A skill that declares no percentage, or exactly 100%, leaves the blow alone.
//
// -1 used to be in this list as a robustness sample. It is now
// SkillPercentZero, a REAL percentage of zero, and has its own test below;
// nothing ever passed a negative to mean "none" -- the only two callers are in
// session.performAttack, fed by skillDamageBonus, which returns the skill's own
// positive percent, 0, or the sentinel. Any OTHER negative is nonsense input
// and still leaves the blow alone rather than zeroing it.
func TestApplySkillPercentNeutralCases(t *testing.T) {
	for _, pct := range []int{0, -2, 100} {
		if got := ApplySkillPercent(57, pct); got != 57 {
			t.Errorf("ApplySkillPercent(57, %d) = %d, want 57 unchanged", pct, got)
		}
	}
	// A sub-100 percentage really does reduce the blow -- the game's own basic
	// swings are 60%.
	if got := ApplySkillPercent(100, 60); got != 60 {
		t.Errorf("a 60%% swing on a 100 blow = %d, want 60", got)
	}
	// It never rounds a real blow away to nothing.
	if got := ApplySkillPercent(1, 1); got != 1 {
		t.Errorf("ApplySkillPercent(1, 1) = %d, want the floor of 1", got)
	}
}

// TestDamageFloorIsTheGamesOwn pins the floor of 1 as RECOVERED rather than
// invented, which is what it was recorded as until 2026-09-16.
//
// Combat_ResolveDamage finishes with `if (damage == 0) { if (local_d0 == 0)
// damage = 1; }`, and local_d0 is 1 only for a skill carrying neither 'att' nor
// 'ck' -- a buff. So every blow with an attack parameter is guaranteed at least
// 1 damage by the engine itself. The earlier note read
// Formula_MitigatePhysicalDamage's clamp at 0 and stopped there, missing the
// floor applied a stage later.
//
// The cases below are the ones where mitigation alone would reach or pass zero.
func TestDamageFloorIsTheGamesOwn(t *testing.T) {
	for _, tc := range []struct {
		name                   string
		raw, pct, flat, expect int
	}{
		{"flat absorb exceeds the blow", 10, 0, 50, 1},
		{"flat absorb exactly equals the blow", 10, 0, 10, 1},
		{"percentage alone cannot reach zero", 1, 900, 0, 1},
		{"both terms together overwhelm it", 20, 100, 40, 1},
		{"an ordinary blow is untouched by the floor", 100, 0, 10, 90},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := MitigateDamage(tc.raw, tc.pct, tc.flat); got != tc.expect {
				t.Errorf("MitigateDamage(%d, %d, %d) = %d, want %d",
					tc.raw, tc.pct, tc.flat, got, tc.expect)
			}
		})
	}

	// The floor must never be reachable downward: no input produces 0 or less.
	for raw := 0; raw <= 60; raw++ {
		for flat := 0; flat <= 60; flat += 5 {
			if got := MitigateDamage(raw, 300, flat); got < 1 {
				t.Fatalf("MitigateDamage(%d, 300, %d) = %d, below the engine's floor of 1",
					raw, flat, got)
			}
		}
	}
}

// Stage 16 of the engine's pipeline. A blow mitigated below 5% of its
// PRE-mitigation base is divided by ten, floored at 1, and randomised between
// 1 and that value -- not simply floored at 1.
func TestFloorBandOnlyTriggersBelowFivePercentOfBase(t *testing.T) {
	// 60 out of a base of 1000 is 6%, above the threshold: untouched.
	if got := ApplyFloorBand(60, 1000, nil); got != 60 {
		t.Errorf("60 of base 1000 (6%%) = %d, want it untouched", got)
	}
	// 40 out of 1000 is 4%, below: reshaped to a tenth of the BASE (100), not
	// of the damage (which would be 4 -- the degenerate ~1 case this stage
	// exists to avoid). nil r takes the max.
	if got := ApplyFloorBand(40, 1000, nil); got != 100 {
		t.Errorf("40 of base 1000 (4%%) = %d, want 100 (a tenth of the base)", got)
	}
	// The regression guard: a tenth of the DAMAGE would be 4. It must not be.
	if got := ApplyFloorBand(40, 1000, nil); got == 4 {
		t.Errorf("band used a tenth of the damage (4), not of the base (100)")
	}
	// Exactly at the threshold is not below it.
	if got := ApplyFloorBand(50, 1000, nil); got != 50 {
		t.Errorf("50 of base 1000 (exactly 5%%) = %d, want it untouched", got)
	}
}

// The band never returns less than 1, however small the input.
func TestFloorBandNeverGoesBelowOne(t *testing.T) {
	r := rand.New(rand.NewSource(1))
	for _, dmg := range []int{0, 1, 2, 3, 9} {
		for i := 0; i < 50; i++ {
			if got := ApplyFloorBand(dmg, 100000, r); got < 1 {
				t.Fatalf("ApplyFloorBand(%d, 100000) = %d, want >= 1", dmg, got)
			}
		}
	}
}

// The randomisation spans [1, tenth-of-base] rather than being constant -- the
// whole point of the stage. 400 of a base of 100000 is 0.4%, and the band is a
// tenth of the BASE = 10000, so the roll spans [1, 10000].
func TestFloorBandRandomisesBetweenOneAndTheTenth(t *testing.T) {
	r := rand.New(rand.NewSource(7))
	lo, hi := 1<<30, 0
	for i := 0; i < 500; i++ {
		got := ApplyFloorBand(400, 100000, r)
		if got < 1 || got > 10000 {
			t.Fatalf("got %d, outside [1, 10000]", got)
		}
		if got < lo {
			lo = got
		}
		if got > hi {
			hi = got
		}
	}
	if lo == hi {
		t.Errorf("the band produced the constant %d over 500 rolls, want a spread", lo)
	}
	if hi < 7000 {
		t.Errorf("the band's top observed value was %d, want it to reach near 10000", hi)
	}
}

// A base of zero (or an unknown one) leaves the damage alone rather than
// dividing it.
func TestFloorBandIgnoresAnUnknownBase(t *testing.T) {
	if got := ApplyFloorBand(7, 0, nil); got != 7 {
		t.Errorf("ApplyFloorBand(7, 0) = %d, want 7", got)
	}
}

// The constants are the recovered ones, so a tuning edit has to delete a
// citation to happen.
func TestFloorBandConstantsAreTheRecoveredOnes(t *testing.T) {
	if FloorBandThreshold != 0.05 {
		t.Errorf("threshold = %g, want 0.05 (.rdata 0x00b45f60)", FloorBandThreshold)
	}
	if FloorBandScale != 10.0 {
		t.Errorf("scale = %g, want 10 (.rdata 0x00b45c60)", FloorBandScale)
	}
	if FloorBandRandMax != 32767 {
		t.Errorf("rand max = %d, want 32767 (.rdata 0x00b45af8)", FloorBandRandMax)
	}
}

// ResolveBlow must run the band, and an ordinary blow must be unaffected by it.
func TestResolveBlowAppliesTheFloorBandWithoutDisturbingOrdinaryHits(t *testing.T) {
	// 100 base, no mitigation: 100 is well above 5% of 100, untouched.
	got := ResolveBlow(100, 0, 0, 0, 0, 0, 0, nil, nil)
	if got.Damage != 100 {
		t.Errorf("an unmitigated blow = %d, want 100", got.Damage)
	}
	// Heavy mitigation drives it under the threshold (20 of 1000 = 2%), so the
	// band reshapes it UP to a tenth of the BASE (100) -- a meaningful minimum,
	// not the ~1 a tenth of the mitigated 20 would give. nil r takes the max.
	heavy := ResolveBlow(1000, 0, 980, 0, 0, 0, 0, nil, nil)
	if heavy.Damage != 100 {
		t.Errorf("a blow mitigated to 20 of base 1000 should reshape to a tenth of the base (100), got %d", heavy.Damage)
	}
	if heavy.Damage < 1 {
		t.Errorf("the band must never go below 1, got %d", heavy.Damage)
	}
}

// TestSkillLevelPenalty pins Formulae::Formula_SkillPhysDamage (0040f5f0): a
// skill's own flat damage is scaled by 1 - 0.025*d when the TARGET out-levels
// the attacker by d, clamped to [10% of base, base]. See SkillLevelPenalty for
// the disassembly and for the three-way proof of which side is the attacker.
func TestSkillLevelPenalty(t *testing.T) {
	// No deficit, and an advantage, both leave the base alone: the engine's
	// `jle` skips the whole term unless d > 0. The BONUS for out-levelling is
	// a different function (LevelAdvantage) with a different rate.
	for _, tc := range []struct{ atk, tgt int }{{50, 50}, {50, 40}, {50, 1}} {
		if got := SkillLevelPenalty(1000, tc.atk, tc.tgt); got != 1000 {
			t.Errorf("SkillLevelPenalty(1000, %d, %d) = %d, want 1000 (no deficit)",
				tc.atk, tc.tgt, got)
		}
	}

	// One level of deficit is 2.5%; ten is 25%.
	if got := SkillLevelPenalty(1000, 50, 51); got != 975 {
		t.Errorf("one level of deficit = %d, want 975", got)
	}
	if got := SkillLevelPenalty(1000, 50, 60); got != 750 {
		t.Errorf("ten levels of deficit = %d, want 750", got)
	}

	// The floor is 10% of base, and the two ways of reaching it agree: the
	// scale hits 0.10 at exactly 36 levels, so 36 and anything beyond it pin
	// to the same number. That equality is the check that the floor and the
	// rate were read off the same function.
	const floor = 1000 * SkillLevelPenaltyFloorPercent / 100
	for _, d := range []int{36, 37, 100, 255} {
		if got := SkillLevelPenalty(1000, 50, 50+d); got != floor {
			t.Errorf("deficit of %d = %d, want the floor %d", d, got, floor)
		}
	}
	// One level short of saturation must still be above the floor, or the
	// floor is being reached early and the rate is wrong.
	if got := SkillLevelPenalty(1000, 50, 85); got <= floor {
		t.Errorf("deficit of 35 = %d, want more than the floor %d", got, floor)
	}

	// The engine truncates through __ftol2 rather than rounding: 101 * 0.975
	// is 98.475, and the cast makes it 98, not 98.5-rounded-to-98... the
	// distinction bites at .5, so use a base that lands there. 200 * 0.975 =
	// 195 exactly; 100 * 0.975 = 97.5, which truncates to 97 and would round
	// to 98.
	if got := SkillLevelPenalty(100, 50, 51); got != 97 {
		t.Errorf("SkillLevelPenalty(100, 50, 51) = %d, want 97 (__ftol2 truncates)", got)
	}

	// An unknown level on either side is "not set", not "level zero", and
	// skips the term -- the same convention ResolveBlow uses for the advantage.
	if got := SkillLevelPenalty(1000, 0, 60); got != 1000 {
		t.Errorf("unknown attacker level = %d, want 1000", got)
	}
	if got := SkillLevelPenalty(1000, 50, 0); got != 1000 {
		t.Errorf("unknown target level = %d, want 1000", got)
	}
	// A plain attack carries no skill damage, so there is nothing to scale.
	if got := SkillLevelPenalty(0, 1, 99); got != 0 {
		t.Errorf("SkillLevelPenalty(0, ...) = %d, want 0", got)
	}
}

// TestSkillLevelPenaltyIsNotTheLevelAdvantage guards against the two
// level-difference terms being collapsed into one. They have different rates
// (2.5% against 3%), different bounds (a floor at 10% against a cap at +30%),
// they fire on opposite signs of the difference, and they come from different
// functions. A future refactor that "unifies" them is a bug.
func TestSkillLevelPenaltyIsNotTheLevelAdvantage(t *testing.T) {
	if SkillLevelPenaltyPerLevel == LevelAdvantagePerLevel {
		t.Fatalf("the penalty rate and the advantage rate are both %v; they are "+
			"2.5%% and 3%% and were read out of different functions",
			SkillLevelPenaltyPerLevel)
	}
	// Ten levels either way: the advantage multiplies up, the penalty scales
	// down, and neither touches the other's side of the difference.
	if adv := LevelAdvantage(60, 50); adv <= 1 {
		t.Errorf("LevelAdvantage(60, 50) = %v, want more than 1", adv)
	}
	if LevelAdvantage(50, 60) != 1 {
		t.Error("LevelAdvantage fires when the attacker is out-levelled; it must not")
	}
	if SkillLevelPenalty(1000, 60, 50) != 1000 {
		t.Error("SkillLevelPenalty fires when the attacker out-levels; it must not")
	}
}

// TestMasteryDamagePercent pins FUN_0059e770: the max of the two slots, with
// BOTH defaulting to 1 rather than 0 when the slot is occupied but unknown.
func TestMasteryDamagePercent(t *testing.T) {
	// No skill record at all is the only way to get 0.
	if got := MasteryDamagePercent(false, true, true, 50, 60); got != 0 {
		t.Errorf("no skill gave %d, want 0", got)
	}
	// A skill with no mastery slots still contributes 1, not 0. This is the
	// default the engine writes before either branch, and a reading that made
	// it 0 would silently remove stage 1 for every masteryless skill.
	if got := MasteryDamagePercent(true, false, false, 50, 60); got != 1 {
		t.Errorf("a skill with no mastery slots gave %d, want 1", got)
	}
	// The higher of the two wins, from either side.
	if got := MasteryDamagePercent(true, true, true, 20, 45); got != 45 {
		t.Errorf("got %d, want the higher slot 45", got)
	}
	if got := MasteryDamagePercent(true, true, true, 45, 20); got != 45 {
		t.Errorf("got %d, want the higher slot 45", got)
	}
	// An occupied slot whose level is below the default still loses to it,
	// because the OTHER slot's default of 1 is compared in.
	if got := MasteryDamagePercent(true, true, false, 0, 0); got != 1 {
		t.Errorf("a zero-level mastery gave %d, want 1 (the other slot's default)", got)
	}
}

// TestClampMasteryPercent pins the three-way clamp. A plain min(pct, 90) passes
// the first two cases and fails the third, which is the whole reason the engine
// spends four instructions here.
func TestClampMasteryPercent(t *testing.T) {
	if got := ClampMasteryPercent(40, 200); got != 40 {
		t.Errorf("a primary under the cap gave %d, want 40", got)
	}
	if got := ClampMasteryPercent(MasteryDamageCap, 200); got != MasteryDamageCap {
		t.Errorf("a primary AT the cap gave %d, want %d", got, MasteryDamageCap)
	}
	// Primary over, secondary under: the result is the cap.
	if got := ClampMasteryPercent(120, 50); got != MasteryDamageCap {
		t.Errorf("got %d, want the cap %d", got, MasteryDamageCap)
	}
	// BOTH over: the result is the secondary, ABOVE the cap. min() gives 90
	// here and is wrong.
	if got := ClampMasteryPercent(120, 150); got != 150 {
		t.Errorf("got %d, want 150 -- both over the cap yields the SECONDARY, "+
			"which is not a min()", got)
	}
	if got := ClampMasteryPercent(120, 150); got == MasteryDamageCap {
		t.Error("the clamp collapsed to min(pct, 90)")
	}
}

func TestMasteryDamageScale(t *testing.T) {
	if got := MasteryDamageScale(0); got != 1 {
		t.Errorf("mastery 0 scales by %v, want 1", got)
	}
	if got := MasteryDamageScale(MasteryDamageCap); got != 1.9 {
		t.Errorf("mastery at the cap scales by %v, want 1.9", got)
	}
	// The cap is on the PERCENT, and 90 means +90%, not +9% or x90. Pin the
	// magnitude, since this is the largest single multiplier in the pipeline.
	if got := ApplyMasteryScale(100, MasteryDamageCap); got != 190 {
		t.Errorf("ApplyMasteryScale(100, 90) = %d, want 190", got)
	}
	if got := ApplyMasteryScale(100, 40); got != 140 {
		t.Errorf("ApplyMasteryScale(100, 40) = %d, want 140", got)
	}
	// A masteryless skill's default of 1 is +1%, which rounds away on small
	// numbers and must not be mistaken for a bug.
	if got := ApplyMasteryScale(100, 1); got != 101 {
		t.Errorf("ApplyMasteryScale(100, 1) = %d, want 101", got)
	}
	if got := ApplyMasteryScale(0, 90); got != 0 {
		t.Errorf("scaling a zero base gave %d, want 0", got)
	}
}

// A real percentage of zero is not the same as no percentage. The engine's
// multiply is unconditional once the attack descriptor exists, so zero makes
// the mitigated blow zero, and Combat_ResolveDamage floors a computed zero at 1.
func TestApplySkillPercentRealZeroIsTheFloor(t *testing.T) {
	if got := ApplySkillPercent(500, SkillPercentZero); got != 1 {
		t.Errorf("ApplySkillPercent(500, SkillPercentZero) = %d, want 1", got)
	}
	// 0 still means "this blow carries no skill percentage" -- a plain attack.
	if got := ApplySkillPercent(500, 0); got != 500 {
		t.Errorf("ApplySkillPercent(500, 0) = %d, want 500 unchanged", got)
	}
	if SkillPercentZero >= 0 {
		t.Error("SkillPercentZero must be negative: the engine reads the field unsigned, so no real percentage can collide with it")
	}
}

// The engine's damage ceiling, 2^24 - 1, read off the tail of
// Formula_MitigatePhysicalDamage and confirmed in its magical twin.
func TestDamageCeiling(t *testing.T) {
	if MaxDamage != 16777215 {
		t.Fatalf("MaxDamage is %d; the constant at .rdata 0x00b46108/0x00b46110 is 16777215", MaxDamage)
	}
	// WHY 2^24 - 1: it is the last integer a float32 still counts one by one.
	// The engine accumulates damage in a float and converts at the end, so
	// above this the number it stores would not be the number it computed.
	// float32 cannot tell 2^24+1 from 2^24, and that is the first such pair.
	if float32(MaxDamage+2) != float32(MaxDamage+1) {
		t.Errorf("float32 still separates %d from %d, so 2^24-1 is not the "+
			"representability limit and the ceiling's rationale is wrong",
			MaxDamage+1, MaxDamage+2)
	}
	if float32(MaxDamage) == float32(MaxDamage-1) {
		t.Errorf("float32 already cannot separate %d from %d, so the ceiling "+
			"would be below the limit", MaxDamage-1, MaxDamage)
	}
	for _, tc := range []struct{ in, want int }{
		{0, 0},
		{1, 1},
		{MaxDamage - 1, MaxDamage - 1},
		{MaxDamage, MaxDamage},
		{MaxDamage + 1, MaxDamage},
		{1 << 30, MaxDamage},
	} {
		if got := CapDamage(tc.in); got != tc.want {
			t.Errorf("CapDamage(%d) = %d, want %d", tc.in, got, tc.want)
		}
	}
}
