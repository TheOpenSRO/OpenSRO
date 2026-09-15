package berserk

import "testing"

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
