package persistence

import (
	"strings"
	"testing"
)

// The three lists must partition the 85 reference tables exactly: every table
// in one of them, none in two.
func TestTheThreeListsPartitionTheReferenceTables(t *testing.T) {
	seen := map[string]string{}
	add := func(tbl, where string) {
		if prev, dup := seen[tbl]; dup {
			t.Errorf("%s is in both %s and %s", tbl, prev, where)
		}
		seen[tbl] = where
	}
	for tbl := range ClientTextdata {
		add(tbl, "ClientTextdata")
	}
	for _, tbl := range ServerOnlyLootTables {
		add(tbl, "ServerOnlyLootTables")
	}
	for _, tbl := range ServerOnlyOtherTables {
		add(tbl, "ServerOnlyOtherTables")
	}
	for _, tbl := range ReferenceTables {
		if _, ok := seen[tbl]; !ok {
			t.Errorf("%s is in neither the client list nor either server-only list", tbl)
		}
	}
	for tbl := range seen {
		found := false
		for _, r := range ReferenceTables {
			if r == tbl {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("%s is listed but is not one of the 85 reference tables", tbl)
		}
	}
	if n := len(seen); n != len(ReferenceTables) {
		t.Errorf("the lists cover %d tables, there are %d", n, len(ReferenceTables))
	}
}

func TestMeasuredCounts(t *testing.T) {
	if len(ClientTextdata) != 51 {
		t.Errorf("%d tables have a client file, measured 51", len(ClientTextdata))
	}
	if len(ServerOnlyLootTables) != 17 {
		t.Errorf("%d loot tables, measured 17", len(ServerOnlyLootTables))
	}
	if len(ServerOnlyOtherTables) != 17 {
		t.Errorf("%d other server-only tables, measured 17", len(ServerOnlyOtherTables))
	}
}

// Every loot table must actually look like one -- the claim "all seventeen
// drop tables are server-only" only means something if the list IS the drop
// tables.
func TestLootListIsTheDropTables(t *testing.T) {
	for _, tbl := range ServerOnlyLootTables {
		if !strings.Contains(tbl, "DROP") {
			t.Errorf("%s is in ServerOnlyLootTables but has no DROP in its name", tbl)
		}
	}
	// And no drop table may be anywhere else: that completeness is the finding.
	for tbl := range ClientTextdata {
		if strings.Contains(tbl, "DROP") {
			t.Errorf("%s is a drop table with a client file; the loot finding is wrong", tbl)
		}
	}
	for _, tbl := range ServerOnlyOtherTables {
		if strings.Contains(tbl, "DROP") {
			t.Errorf("%s is a drop table but is filed as 'other'", tbl)
		}
	}
	// Every reference table with DROP in its name is accounted for as loot.
	n := 0
	for _, tbl := range ReferenceTables {
		if strings.Contains(tbl, "DROP") {
			n++
		}
	}
	if n != len(ServerOnlyLootTables) {
		t.Errorf("%d reference tables have DROP in the name but the loot list has %d",
			n, len(ServerOnlyLootTables))
	}
}

// A filename must be a plain stem: no shard suffix, no extension, no path.
func TestFilenamesAreBareStems(t *testing.T) {
	for tbl, f := range ClientTextdata {
		if f == "" {
			t.Errorf("%s maps to an empty filename", tbl)
		}
		if strings.ContainsAny(f, "\\/.") {
			t.Errorf("%s maps to %q; store a bare stem, not a path or extension", tbl, f)
		}
		if strings.ToLower(f) != f {
			t.Errorf("%s maps to %q; the archive's names are lowercase", tbl, f)
		}
	}
}

// Spot-checks on the seven that could not be derived from the table name, since
// those are the ones a regenerated map would most easily get wrong.
func TestHandResolvedFilenames(t *testing.T) {
	for tbl, want := range map[string]string{
		"_REFTELELINK":             "teleportlink",
		"_REFOBJITEM":              "itemdata",
		"_REFOBJCHAR":              "characterdata",
		"_REFMAGICOPT":             "magicoption",
		"_REFMAGICOPTASSIGN":       "magicoptionassign",
		"_REFSIEGEFORTRESSREWARDS": "siegefortressreward",
		"_REFSHOP":                 "shopdata",
	} {
		if got := ClientTextdata[tbl]; got != want {
			t.Errorf("%s maps to %q, want %q", tbl, got, want)
		}
	}
}
