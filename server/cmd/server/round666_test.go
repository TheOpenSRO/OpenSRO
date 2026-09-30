package main

import (
	"errors"
	"strings"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/spawn"
	"github.com/OpenSRO/srrevamp/server/internal/worldmap"
)

// Round 666 (M2): a skills store with no status params -- a table imported
// before round 659 -- is warned about at boot, loudly, naming the re-export;
// one with any is not. Its review (L3): the warning fits the store (an empty
// in-memory store is "no skills loaded", with no SQL and no import), and a
// count that failed is reported as the error, not read as 0.
func TestStatusParamsWarning(t *testing.T) {
	has := func(w string, want ...string) {
		t.Helper()
		for _, s := range want {
			if !strings.Contains(w, s) {
				t.Fatalf("the warning %q does not say %q", w, s)
			}
		}
	}
	lacks := func(w string, not ...string) {
		t.Helper()
		for _, s := range not {
			if strings.Contains(w, s) {
				t.Fatalf("the warning %q says %q", w, s)
			}
		}
	}
	w := statusParamsWarning(false, 33698, 0, nil, true)
	has(w, "NO status params", "RE-EXPORT skills.csv", "91 columns", "RE-IMPORT", "status_params <> ''", "-monster-ai")
	w = statusParamsWarning(false, 0, 0, nil, false)
	has(w, "EMPTY")
	lacks(w, "-monster-ai", "before round 659")
	w = statusParamsWarning(true, 0, 0, nil, false)
	has(w, "no skills loaded", "-skills-csv")
	lacks(w, "RE-IMPORT", "SELECT", "before round 659")
	w = statusParamsWarning(true, 500, 0, nil, false)
	has(w, "RE-EXPORT skills.csv", "-skills-csv")
	lacks(w, "RE-IMPORT", "SELECT")
	w = statusParamsWarning(false, 0, 0, errors.New("connection refused"), false)
	has(w, "could not count", "connection refused")
	lacks(w, "RE-IMPORT", "EMPTY")
	if w := statusParamsWarning(false, 33698, 1, nil, true); w != "" {
		t.Fatalf("a store with status params warned: %q", w)
	}
}

// Round 666 (LOW): -monster-sleep's help names the window the area of
// interest serves since round 664 -- 3x3 blocks of 320 units -- not round
// 656's 5x5 regions.
func TestMonsterSleepHelpNamesTheWindow(t *testing.T) {
	u := monsterSleepUsage()
	if strings.Contains(u, "5x5") || !strings.Contains(u, "3x3 blocks of 320 units") {
		t.Fatalf("-monster-sleep's help: %q", u)
	}
}

// Round 666 (LOW): two windows equally dense -- two stand-in nests far apart
// -- and the boot line names the lower cell on every run. Before, the map's
// random iteration picked either.
func TestDensestWindowTieIsTheLowestCell(t *testing.T) {
	_, tab := synthWorld(t)
	npcs := spawn.Table{
		7002: {{ObjectID: 7002, RegionID: 25000 + 10, LocalX: 100, LocalZ: 100},
			{ObjectID: 7002, RegionID: 25000, LocalX: 100, LocalZ: 100}},
	}
	x0, z0 := worldmap.ToWorld(97, 168, 100, 100, worldmap.WorldOrigin[0], worldmap.WorldOrigin[1])
	x1, z1 := worldmap.ToWorld(97, 178, 100, 100, worldmap.WorldOrigin[0], worldmap.WorldOrigin[1])
	lo, hi := combat.CellOf(worldmap.WorldBucket, x0, z0), combat.CellOf(worldmap.WorldBucket, x1, z1)
	if cellLess(hi, lo) {
		lo, hi = hi, lo
	}
	if lo == hi {
		t.Fatal("setup: the two nests share a cell")
	}
	for i := 0; i < 64; i++ {
		_, rep := fullMapSlots(npcs, tab, nil, nil)
		if rep.densest != 1 || rep.densestCell != lo {
			t.Fatalf("run %d: densest %d at %+v; want 1 at the lower cell %+v (not %+v)", i, rep.densest, rep.densestCell, lo, hi)
		}
	}
}
