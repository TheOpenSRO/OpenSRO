package session

import (
	"os"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/testdb"
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
// It also holds the shared test-database lock for the whole run: this
// package's full-flow tests use the local PostgreSQL test database, and two
// `go test` processes on one host clobbered each other's rows on 2026-09-19
// (see internal/testdb).
//
// Round 749: the suite places its characters with OpMove wherever a test
// needs them -- the QA path, -trust-client-positions. The production bound
// on those positions (a stop on the server's own leg, a placement at a point
// it named) has its own tests in destmove749_test.go, each of which turns the
// trust off for itself (strictPositions).
//
// Round 786: likewise the arrival guard, off for the suite and on for
// arrival786_test.go's tests (guardOn).
func TestMain(m *testing.M) {
	damageRollNG = nil
	trustPositions.Store(true)
	// Round 786: the arrival guard (arrival.go) holds every arrival until
	// its client's 0x3012; the suite's older tests expect the arrival at
	// once, so it is off here, and arrival786_test.go turns it on
	// (guardOn).
	arrivalGuardOn.Store(false)
	// Round 786: the game clock's 0x3020 follows every world entry
	// (celestial.go); the suite's older tests read the frames after the
	// result in order, so it is off here, and celestial786_test.go turns it
	// on.
	clockAtEntry.Store(false)
	release := testdb.Lock(inventoryTestDSN())
	code := m.Run()
	release()
	os.Exit(code)
}
