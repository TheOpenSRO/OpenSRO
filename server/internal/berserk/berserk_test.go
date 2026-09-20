package berserk

import (
	"testing"
	"time"
)

// forceRoll pins rand()%10000 for one test and restores it afterwards.
func forceRoll(t *testing.T, v int) {
	t.Helper()
	prev := roll10000
	roll10000 = func() int { return v }
	t.Cleanup(func() { roll10000 = prev })
}

// TestGainChanceIsTheBinarysTable pins FUN_00410880 point by point -- the
// numbers are the .rdata constants read off SR_GameServer.exe (8.0 at
// 0xb45e14, 0.25 at 0xb45b50 and 0xb45ca8, 8.0 at 0xb45eb0) run through the
// asm at 0x410880-0x4109c0, and the rarity cases are its jump table at
// 0x4109e8. Chance is in units of 1/100 % (rolled against rand()%10000).
func TestGainChanceIsTheBinarysTable(t *testing.T) {
	cases := []struct {
		name           string
		killer, victim int
		monster        bool
		rarity         int
		gainPct        int
		wantChance     int
		wantAmount     int
	}{
		{"same level: base 8%", 20, 20, true, 0, 0, 800, 1},
		{"victim 3 below: still class 0", 20, 17, true, 0, 0, 800, 1},
		{"victim 4 below: class 2 but clamped to base", 20, 16, true, 0, 0, 800, 1},
		{"victim 5 below: exactly base", 20, 15, true, 0, 0, 800, 1},
		{"victim 6 below: 7.75%", 20, 14, true, 0, 0, 775, 1},
		{"victim 10 below: 6.75%", 20, 10, true, 0, 0, 675, 1},
		{"victim 36 below: reaches the 0.25% floor", 40, 4, true, 0, 0, 25, 1},
		{"victim 60 below: floored", 80, 20, true, 0, 0, 25, 1},
		{"victim 10 above: class 0, base", 20, 30, true, 0, 0, 800, 1},
		{"victim 11 above: class 1, no bonus", 20, 31, true, 0, 0, 800, 1},
		{"champion: no modifier", 20, 20, true, 1, 0, 800, 1},
		{"unique (3): all five, certain", 20, 20, true, RarityUnique, 0, GainCertain, UniqueGain},
		{"unique (8): all five, certain", 20, 20, true, RarityUnique2, 0, GainCertain, UniqueGain},
		{"giant: x5", 20, 20, true, RarityGiant, 0, 4000, 1},
		{"titan: no modifier", 20, 20, true, 5, 0, 800, 1},
		{"elite: x2", 20, 20, true, RarityElite, 0, 1600, 1},
		{"giant far below: x5 on the decayed chance", 20, 10, true, RarityGiant, 0, 3375, 1},
		{"not a monster: no rarity switch", 20, 20, false, RarityUnique, 0, 800, 1},
		{"param 184 = 200: doubles", 20, 20, true, 0, 200, 1600, 1},
		{"param 184 = 50 on a giant: 4000*50/100", 20, 20, true, RarityGiant, 50, 2000, 1},
	}
	for _, c := range cases {
		chance, amount := GainChance(Kill{KillerLevel: c.killer, VictimLevel: c.victim,
			VictimIsMonster: c.monster, VictimRarity: c.rarity, GainPercent: c.gainPct})
		if chance != c.wantChance || amount != c.wantAmount {
			t.Errorf("%s: GainChance = (%d, %d), want (%d, %d)", c.name, chance, amount, c.wantChance, c.wantAmount)
		}
	}
}

// TestLevelGapClassIsFUN_0040fe60 pins the three classes: diff < -3 -> 2,
// diff < 11 -> 0, else 1, with diff = victim - killer.
func TestLevelGapClassIsFUN_0040fe60(t *testing.T) {
	for diff, want := range map[int]int{-4: 2, -3: 0, 0: 0, 10: 0, 11: 1, 50: 1, -100: 2} {
		if got := LevelGapClass(50, 50+diff); got != want {
			t.Errorf("LevelGapClass(diff %d) = %d, want %d", diff, got, want)
		}
	}
}

// TestEarnOnKillRollsWholeOrbs: the dice decide, a success adds whole orbs,
// a unique adds all five regardless of the dice, and the count caps at Orbs.
func TestEarnOnKillRollsWholeOrbs(t *testing.T) {
	tr := NewTracker()
	const id = int64(1)
	same := Kill{KillerLevel: 10, VictimLevel: 10, VictimIsMonster: true}

	forceRoll(t, 800) // rand()%10000 == chance: NOT below it, so no gain
	if got := tr.EarnOnKill(id, same); got != 0 || tr.Charges(id) != 0 {
		t.Fatalf("roll == chance must fail: gained %d, charges %d", got, tr.Charges(id))
	}
	forceRoll(t, 799) // just below: success, one orb
	if got := tr.EarnOnKill(id, same); got != 1 || tr.Charges(id) != 1 {
		t.Fatalf("roll < chance must add one orb: gained %d, charges %d", got, tr.Charges(id))
	}
	if tr.Gauge(id) != Max/Orbs {
		t.Fatalf("one orb on the wire = %d, got %d", Max/Orbs, tr.Gauge(id))
	}
	forceRoll(t, 9999) // the worst roll: a unique still pays, and all five
	unique := Kill{KillerLevel: 10, VictimLevel: 10, VictimIsMonster: true, VictimRarity: RarityUnique}
	if got := tr.EarnOnKill(id, unique); got != Orbs-1 || tr.Charges(id) != Orbs {
		t.Fatalf("a unique fills to the cap: gained %d, charges %d", got, tr.Charges(id))
	}
	if got := tr.EarnOnKill(id, unique); got != 0 || tr.Charges(id) != Orbs {
		t.Fatalf("at the cap nothing more is added: gained %d, charges %d", got, tr.Charges(id))
	}
	if tr.Gauge(id) != Max {
		t.Fatalf("five orbs on the wire = Max %d, got %d", Max, tr.Gauge(id))
	}
}

// TestActivateNeedsAllFiveAndSpendsThem: the handler refuses below 5 (error 1)
// and spends exactly -5; and AddHwanCount refuses gains while berserk is on.
func TestActivateNeedsAllFiveAndSpendsThem(t *testing.T) {
	tr := NewTracker()
	const id = int64(7)
	forceRoll(t, 0)
	k := Kill{KillerLevel: 10, VictimLevel: 10, VictimIsMonster: true}
	for i := 0; i < Orbs-1; i++ {
		tr.EarnOnKill(id, k)
	}
	if tr.Activate(id) {
		t.Fatal("activation with four orbs must be refused")
	}
	if tr.Charges(id) != Orbs-1 {
		t.Fatalf("a refused activation must not spend: charges %d", tr.Charges(id))
	}
	tr.EarnOnKill(id, k)
	if !tr.Activate(id) {
		t.Fatal("activation with five orbs must succeed")
	}
	if tr.Charges(id) != 0 || tr.Gauge(id) != 0 {
		t.Fatalf("activation spends all five: charges %d gauge %d", tr.Charges(id), tr.Gauge(id))
	}
	if !tr.Active(id) {
		t.Fatal("berserk should be active after activation")
	}
	if got := tr.EarnOnKill(id, k); got != 0 || tr.Charges(id) != 0 {
		t.Fatalf("no hwan is earned while berserk: gained %d, charges %d", got, tr.Charges(id))
	}
}

func TestBoostOnlyWhenActive(t *testing.T) {
	tr := NewTracker()
	const id = int64(2)
	if tr.Boost(id, 100) != 100 {
		t.Fatal("boost must be a no-op when not berserk")
	}
	forceRoll(t, 0)
	for i := 0; i < Orbs; i++ {
		tr.EarnOnKill(id, Kill{KillerLevel: 1, VictimLevel: 1, VictimIsMonster: true})
	}
	tr.Activate(id)
	if got := tr.Boost(id, 100); got != 200 {
		t.Fatalf("berserk doubles the blow: Boost(100) = %d, want 200", got)
	}
	tr.Clear(id)
	if tr.Active(id) || tr.Charges(id) != 0 {
		t.Fatal("Clear must drop the state")
	}
}

// TestBerserkDoublesTheBlow pins the recovered x2 across a few amounts.
func TestBerserkDoublesTheBlow(t *testing.T) {
	tr := NewTracker()
	const id = int64(3)
	forceRoll(t, 0)
	for i := 0; i < Orbs; i++ {
		tr.EarnOnKill(id, Kill{KillerLevel: 1, VictimLevel: 1, VictimIsMonster: true})
	}
	if !tr.Activate(id) {
		t.Fatal("could not activate")
	}
	for _, tc := range []struct{ in, want int }{{1, 2}, {7, 14}, {50, 100}, {123, 246}} {
		if got := tr.Boost(id, tc.in); got != tc.want {
			t.Errorf("Boost(%d) = %d, want %d", tc.in, got, tc.want)
		}
	}
}

// TestOrbsIsTheRecoveredCap pins the one number in this package's gauge that is
// the game's rather than ours.
//
// _CHAR.RemainHwanCount is a persisted count, and CUsedItemLimit::FUN_004a05b0
// refuses an item when it has reached 5 -- a branchless ternary returning 1
// when the count is not 5 and error 0x183e when it is. A limit that refuses at
// exactly 5 is a cap of 5.
//
// Max is deliberately NOT pinned here: it is only the HUD's wire scale.
func TestOrbsIsTheRecoveredCap(t *testing.T) {
	if Orbs != 5 {
		t.Errorf("Orbs = %d, want 5 -- the cap CUsedItemLimit refuses at", Orbs)
	}
	// The gauge must divide into whole orbs, or the HUD shows a partial pip
	// for a full gauge.
	if Max%Orbs != 0 {
		t.Errorf("Max %d does not divide into %d orbs", Max, Orbs)
	}
}

// TestDurationIsTheRecoveredSixty pins the berserk duration and, more
// importantly, the two facts behind it -- because the previous reading of this
// code concluded the opposite (that berserk has no timer at all) and was wrong.
//
// What is recovered: GObjPC_InitStats sets param 60 to the float32 60.0 at
// 0xb461bc, the berserk activation handler passes GetParam(60) + GetParam(195)
// to SetBodyMode with a real state-change slot, and param 195 (`hwit`,
// PARAM_HWAN_TIME_INCREASE) is initialised to 0. So an unbuffed berserk runs
// for exactly the base.
//
// What is NOT recovered is the unit; see the constant's comment.
func TestDurationIsTheRecoveredSixty(t *testing.T) {
	if Duration != 60*time.Second {
		t.Errorf("Duration = %v, want the recovered base of 60 (param 60 = 60.0f)", Duration)
	}
	// It must not silently drift back to the invented 20s it carried before
	// the activation handler was found.
	if Duration == 20*time.Second {
		t.Error("Duration is back at the pre-recovery placeholder of 20s")
	}
}

// TestOrbsMatchesTheChargeSpend records the third independent grounding of
// Orbs = 5. The berserk activation handler refuses when RemainHwanCount < 5 and
// then spends exactly -5 against a field the adjuster clamps to [0, 5].
//
// The three are independent: CUsedItemLimit refuses an item at 5, the adjuster
// clamps at 5, and the activation both requires and spends 5.
func TestOrbsMatchesTheChargeSpend(t *testing.T) {
	if Orbs != 5 {
		t.Fatalf("Orbs = %d, want 5", Orbs)
	}
	// A full gauge is what activation costs, so the two must stay in step: a
	// gauge that filled to Max in fewer than Orbs units would let a player
	// berserk without the engine's five charges.
	if Max%Orbs != 0 {
		t.Errorf("Max (%d) is not a whole number of Orbs (%d) -- one orb is not a "+
			"clean fraction of the gauge", Max, Orbs)
	}
	if perOrb := Max / Orbs; perOrb <= 0 {
		t.Errorf("Max/Orbs = %d, want a positive gauge step", perOrb)
	}
}

// Seeding is how a character's orbs survive a logout, and seed-once is the part
// that matters: the live count is the authority once play has started.
func TestEnsureSeededIsOnlyTheFirstWord(t *testing.T) {
	tr := NewTracker()
	tr.EnsureSeeded(7, 3)
	if got := tr.Charges(7); got != 3 {
		t.Fatalf("Charges = %d after seeding 3, want 3", got)
	}
	// A later re-seed from a stale row must not undo what was earned since.
	tr.EnsureSeeded(7, 0)
	if got := tr.Charges(7); got != 3 {
		t.Errorf("Charges = %d after a second seed, want the live 3 -- a re-seed "+
			"from a stale row would silently destroy orbs", got)
	}
}

// The stored value comes from a database row and is not trusted blindly.
func TestEnsureSeededClampsAStoredValue(t *testing.T) {
	tr := NewTracker()
	tr.EnsureSeeded(1, 99)
	if got := tr.Charges(1); got != Orbs {
		t.Errorf("Charges = %d after seeding 99, want the cap %d", got, Orbs)
	}
	tr2 := NewTracker()
	tr2.EnsureSeeded(2, -4)
	if got := tr2.Charges(2); got != 0 {
		t.Errorf("Charges = %d after seeding -4, want 0", got)
	}
}

// An unseeded character still reads as zero, so seeding is not mandatory for
// correctness -- only for continuity across a logout.
func TestUnseededCharacterHasNoOrbs(t *testing.T) {
	if got := NewTracker().Charges(42); got != 0 {
		t.Errorf("Charges = %d for an unseeded character, want 0", got)
	}
}
