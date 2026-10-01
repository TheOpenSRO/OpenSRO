package session

import (
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/safezone"
	"github.com/OpenSRO/srrevamp/server/internal/worldmap"
)

// The round-674 shim: everything safezone674_test.go needs of the round's new
// API, in one file. The round's negative runs safezone674_test.go against the
// base revision with a stub of this file whose installTowns674 does nothing --
// the base has no region table (docs/WORLD_ISSUES.md, round 674).

// installTowns674 installs a region table -- SYNTHETIC, the test's own -- in
// which each of towns (x/y) has IsBattleField 0 and each of fields 1, and
// takes it out when the test ends.
func installTowns674(t *testing.T, towns, fields [][2]int) {
	t.Helper()
	var rows []safezone.Region
	for _, r := range towns {
		rows = append(rows, safezone.Region{ID: worldmap.RegionID(r[0], r[1]), Area: "TEST_TOWN"})
	}
	for _, r := range fields {
		rows = append(rows, safezone.Region{ID: worldmap.RegionID(r[0], r[1]), Area: "TEST_FIELD", Battlefield: true})
	}
	SetSafeRegions(safezone.New(rows))
	t.Cleanup(func() { SetSafeRegions(nil) })
}
