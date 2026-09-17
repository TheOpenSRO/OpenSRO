package persistence

import (
	"strings"
	"testing"
)

func TestPoolShape(t *testing.T) {
	if len(ColumnPool) != 310 {
		t.Errorf("%d pool entries, want the 310 read from .rdata", len(ColumnPool))
	}
	if len(SchemaTableOrder) != 54 {
		t.Errorf("%d tables, want 54", len(SchemaTableOrder))
	}
	if SchemaPoolEnd <= SchemaPoolStart {
		t.Error("the pool bounds are inverted")
	}
	// Every entry is a plain SQL identifier -- if the extraction ever walks off
	// the end of the pool it will pick up something that is not.
	for _, s := range ColumnPool {
		if s == "" {
			t.Fatal("an empty identifier is in the pool")
		}
		for i, r := range s {
			ok := r == '_' || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') ||
				(i > 0 && r >= '0' && r <= '9')
			if !ok {
				t.Errorf("%q is not a plain identifier", s)
				break
			}
		}
	}
}

// The pool is deduplicated: every name appears exactly once.
func TestPoolIsDeduplicated(t *testing.T) {
	seen := map[string]bool{}
	for _, s := range ColumnPool {
		if seen[s] {
			t.Errorf("%q appears twice; the pool should hold each name once", s)
		}
		seen[s] = true
	}
}

// The table order and the grouping must describe the same pool: concatenating
// each table marker with the names it introduces reproduces ColumnPool exactly.
func TestGroupingReproducesThePool(t *testing.T) {
	var rebuilt []string
	for _, tbl := range SchemaTableOrder {
		rebuilt = append(rebuilt, tbl)
		rebuilt = append(rebuilt, TableColumns[tbl]...)
	}
	if len(rebuilt) != len(ColumnPool) {
		t.Fatalf("regrouping gives %d entries, the pool has %d", len(rebuilt), len(ColumnPool))
	}
	for i := range rebuilt {
		if rebuilt[i] != ColumnPool[i] {
			t.Fatalf("entry %d is %q regrouped but %q in the pool", i, rebuilt[i], ColumnPool[i])
		}
	}
}

// A table marker starts with an underscore and a column name does not. That is
// how the grouping tells them apart, so it has to keep holding.
func TestTableMarkersAreDistinguishable(t *testing.T) {
	for _, tbl := range SchemaTableOrder {
		if !strings.HasPrefix(tbl, "_") {
			t.Errorf("table %q does not start with an underscore", tbl)
		}
	}
	for tbl, cols := range TableColumns {
		for _, c := range cols {
			if strings.HasPrefix(c, "_") {
				t.Errorf("%s introduces %q, which looks like a table marker", tbl, c)
			}
		}
	}
}

// The tables that introduce nothing are real and load-bearing: they reuse a
// sibling's names entirely, which is the clearest evidence the pool is
// deduplicated rather than per-table.
func TestSomeTablesIntroduceNothing(t *testing.T) {
	for _, tbl := range []string{"_TIMEDJOBFORPET", "_INVENTORYFORAVATAR", "_CHEST"} {
		cols, ok := TableColumns[tbl]
		if !ok {
			t.Errorf("%s is missing from TableColumns", tbl)
			continue
		}
		if len(cols) != 0 {
			t.Errorf("%s introduces %d names; it should reuse its sibling's", tbl, len(cols))
		}
	}
}

// Spot-checks on names this closes a gap for elsewhere. Each is cited in a
// spec, so a regenerated pool that lost one would break that citation silently.
func TestNamesCitedByOtherSpecs(t *testing.T) {
	want := map[string]string{
		"_SiegeFortress":      "CreatedDungeonCount",
		"_TRAININGCAMPMEMBER": "MemberClass",
		"_GUILDMEMBER":        "Permission",
		"_TIMEDJOB":           "TimeToKeep",
		"_CHAR":               "HwanLevel",
	}
	for tbl, col := range want {
		found := false
		for _, c := range TableColumns[tbl] {
			if c == col {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("%s no longer introduces %q, which a spec cites", tbl, col)
		}
	}
}
