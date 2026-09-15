package session

import (
	"os"
	"testing"
)

// TestMain pins the damage roll to its maximum for every test in this package.
//
// The game rolls a blow uniformly in [min, max] (combat.RollDamage, recovered
// from Formula_RollWeaponDamage), which is correct and non-deterministic. These
// tests are about the protocol and the combat FLOW -- that a hit is
// acknowledged, broadcast, mitigated, and kills at zero -- not about the
// distribution, so they assert exact numbers and would otherwise flake.
//
// A nil generator makes RollDamage return the maximum, which is exactly what
// this package asserted before the roll existed, so the expectations are
// unchanged rather than loosened. The roll itself is tested where it lives, in
// internal/combat.
func TestMain(m *testing.M) {
	damageRollNG = nil
	os.Exit(m.Run())
}
