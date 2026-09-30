package main

import (
	"strings"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/spawn"
	"github.com/OpenSRO/srrevamp/server/internal/worldmap"
)

// Round 666 (M2): a skills store with no status params -- a table imported
// before round 659 -- is warned about at boot, loudly, naming the re-export;
// one with any is not.
func TestStatusParamsWarning(t *testing.T) {
	w := statusParamsWarning(33698, 0, true)
	for _, want := range []string{"NO status params", "RE-EXPORT skills.csv", "91 columns", "RE-IMPORT", "status_params <> ''", "-monster-ai"} {
		if !strings.Contains(w, want) {
			t.Fatalf("the warning %q does not say %q", w, want)
		}
	}
	if w := statusParamsWarning(0, 0, false); w == "" || strings.Contains(w, "-monster-ai") {
		t.Fatalf("an empty store with the AI off: %q", w)
	}
	if w := statusParamsWarning(33698, 1, true); w != "" {
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
