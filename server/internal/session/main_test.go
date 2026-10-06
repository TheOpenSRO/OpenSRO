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
func TestMain(m *testing.M) {
	damageRollNG = nil
	trustPositions.Store(true)
	release := testdb.Lock(inventoryTestDSN())
	code := m.Run()
	release()
	os.Exit(code)
}
