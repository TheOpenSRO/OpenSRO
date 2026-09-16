package combat

import "testing"

// TestRealMasksSplitIntoExactlyOneHalf walks the masks that actually occur in
// the real skill table, with the row counts measured on 2026-09-16 over 31,605
// `att` runs. The property under test is the one the damage sum depends on:
// every real mask names exactly one half, never both.
func TestRealMasksSplitIntoExactlyOneHalf(t *testing.T) {
	for _, tc := range []struct {
		mask     AttackType
		rows     int
		physical bool
		magical  bool
	}{
		{5, 17075, true, false}, // {1,4}
		{6, 4055, true, false},  // {2,4}
		{10, 6971, false, true}, // {2,8}
		{9, 2528, false, true},  // {1,8}
		{8, 966, false, true},   // {8}
	} {
		if got := tc.mask.IsPhysical(); got != tc.physical {
			t.Errorf("mask %d (%d real rows): IsPhysical = %v, want %v", tc.mask, tc.rows, got, tc.physical)
		}
		if got := tc.mask.IsMagical(); got != tc.magical {
			t.Errorf("mask %d (%d real rows): IsMagical = %v, want %v", tc.mask, tc.rows, got, tc.magical)
		}
		if tc.mask.IsPhysical() && tc.mask.IsMagical() {
			t.Errorf("mask %d claims BOTH halves; no real skill does, and the engine's sum relies on it", tc.mask)
		}
		if !tc.mask.Known() {
			t.Errorf("mask %d is a real authored mask and must read as Known", tc.mask)
		}
	}
}

// TestUnknownMaskStaysPhysical pins the compatibility rule. A skill record from
// an export made before the AttackType column carries 0, and must keep behaving
// exactly as it did then -- physical, never magical.
func TestUnknownMaskStaysPhysical(t *testing.T) {
	for _, mask := range []AttackType{0, AttackClassA, AttackClassB, AttackClassA | AttackClassB} {
		if !mask.IsPhysical() {
			t.Errorf("mask %d: an unknown mask must read as physical so old exports are unchanged", mask)
		}
		if mask.IsMagical() {
			t.Errorf("mask %d: an unknown mask must never reroute damage to the magical path", mask)
		}
		if mask.Known() {
			t.Errorf("mask %d names no damage half and must not read as Known", mask)
		}
	}
}

// TestBitsAreTheFormulaGuards states the constants against the two functions
// they were read out of, so a later edit that swaps them fails here rather than
// silently sending every magical skill down the physical path.
func TestBitsAreTheFormulaGuards(t *testing.T) {
	if AttackPhysical != 4 {
		t.Errorf("AttackPhysical = %d, want 4 -- Formula_MitigatePhysicalDamage (0040e450) tests & 4", AttackPhysical)
	}
	if AttackMagical != 8 {
		t.Errorf("AttackMagical = %d, want 8 -- Formula_MitigateMagicalDamage (0040e830) tests & 8", AttackMagical)
	}
}
