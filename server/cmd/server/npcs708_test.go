package main

import (
	"sort"
	"strings"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/spawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/species"
)

// The NPC rows of npcpos: without an NPC table, every row the monster table
// does not name; with one, the rows it names (synthetic ids and positions).
func TestNPCRows(t *testing.T) {
	placements := spawn.Table{
		1933: {{ObjectID: 1933, RegionID: 25000, LocalX: 1, LocalZ: 2}}, // a monster
		2003: {{ObjectID: 2003, RegionID: 25000, LocalX: 3, LocalZ: 4}}, // an NPC
		2094: {{ObjectID: 2094, RegionID: 25000, LocalX: 5, LocalZ: 6}}, // neither table's
	}
	row := make([]string, len(species.CSVColumns))
	row[0], row[1] = "1933", "MOB_TEST"
	for i := 2; i < len(row); i++ {
		if row[i] == "" {
			row[i] = "0"
		}
	}
	monsters, err := species.Read(strings.NewReader(strings.Join(species.CSVColumns, ",") + "\n" + strings.Join(row, ",") + "\n"))
	if err != nil {
		t.Fatalf("the fixture species table: %v", err)
	}
	ids := func(rows []npcspawn.Row) []int64 {
		var out []int64
		for _, r := range rows {
			out = append(out, r.RefID)
		}
		sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
		return out
	}
	if got := ids(npcRows(placements, monsters, nil)); len(got) != 2 || got[0] != 2003 || got[1] != 2094 {
		t.Fatalf("without an NPC table: %v, want [2003 2094]", got)
	}
	table := npcspawn.Table{2003: {ID: 2003, Code: "NPC_CH_SMITH"}}
	if got := ids(npcRows(placements, monsters, table)); len(got) != 1 || got[0] != 2003 {
		t.Fatalf("with an NPC table: %v, want [2003]", got)
	}
}
