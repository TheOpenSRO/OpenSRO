package berserk

import (
	"testing"
	"time"
)

func TestFillCapsAndActivates(t *testing.T) {
	tr := NewTracker()
	const id = int64(1)

	// Fills by FillPerHit, capped at Max.
	got := 0
	for i := 0; i < 100; i++ {
		got = tr.Fill(id)
	}
	if got != Max {
		t.Fatalf("gauge capped at %d, got %d", Max, got)
	}

	// Not active until activated; activation needs a full gauge.
	if tr.Active(id) {
		t.Fatal("should not be active before activation")
	}
	if !tr.Activate(id) {
		t.Fatal("a full gauge should activate")
	}
	if tr.Gauge(id) != 0 {
		t.Fatalf("gauge should empty on activation, got %d", tr.Gauge(id))
	}
	if !tr.Active(id) {
		t.Fatal("should be active after activation")
	}
}

func TestActivateNeedsFullGauge(t *testing.T) {
	tr := NewTracker()
	const id = int64(1)
	tr.Fill(id) // one hit, nowhere near full
	if tr.Activate(id) {
		t.Fatal("a partial gauge must not activate")
	}
	if tr.Gauge(id) != FillPerHit {
		t.Fatalf("a failed activation must not empty the gauge, got %d", tr.Gauge(id))
	}
}

func TestBoostOnlyWhenActive(t *testing.T) {
	tr := NewTracker()
	const id = int64(1)
	if tr.Boost(id, 100) != 100 {
		t.Fatal("no boost when inactive")
	}
	for i := 0; i < 100; i++ {
		tr.Fill(id)
	}
	tr.Activate(id)
	if got := tr.Boost(id, 100); got != 200 {
		t.Fatalf("boosted damage = %d, want %d", got, 200)
	}
}

// The multiplier is the recovered one, not a balance knob: berserk doubles
// the blow, because Formula_MitigatePhysicalDamage replaces its 1.0 damage
// multiplier with GetParam(189) + 2.0 when the attacker IsBerserk(), and
// param 189 is zero unless the separate berserk-damage stat has been granted.
//
// Pinned as a test rather than left as a constant nobody rereads: this was
// +50% own design until 2026-09-15, and a later "let's tune it" edit should
// have to delete a citation to do it.
func TestBerserkDoublesTheBlow(t *testing.T) {
	if DamageNumerator != 2 || DamageDenominator != 1 {
		t.Fatalf("berserk multiplier = %d/%d, want 2/1 (.rdata 0x00b45f30 = 2.0)",
			DamageNumerator, DamageDenominator)
	}
	tr := NewTracker()
	const id = int64(7)
	for i := 0; i < Max/FillPerHit+1; i++ {
		tr.Fill(id)
	}
	if !tr.Activate(id) {
		t.Fatal("a full gauge must activate")
	}
	for _, tc := range []struct{ in, want int }{{0, 0}, {1, 2}, {37, 74}, {1000, 2000}} {
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
// Max and FillPerHit are deliberately NOT pinned here: they are own design, and
// a test asserting an invented number only makes it harder to replace.
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
