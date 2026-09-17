package persistence

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestProcsAreDistinctAndPlausible(t *testing.T) {
	seen := map[string]bool{}
	for _, p := range Procs {
		if seen[p.Name] {
			t.Errorf("procedure %s listed twice", p.Name)
		}
		seen[p.Name] = true
		if !strings.HasPrefix(p.Name, "_") {
			t.Errorf("procedure %s does not start with an underscore; every one in "+
				"the binary does", p.Name)
		}
		if p.Args < 0 || p.Args > 32 {
			t.Errorf("procedure %s takes %d arguments", p.Name, p.Args)
		}
		if p.Caller == "" {
			t.Errorf("procedure %s records no caller", p.Name)
		}
	}
	if len(Procs) != 39 {
		t.Errorf("%d procedures; 39 were harvested from the call literals", len(Procs))
	}
}

// The storage procedures are the ones srrevamp's inventory code has to be able
// to express. Spot-checking their arity catches a regenerated catalogue that
// silently lost an argument.
func TestStorageProcArities(t *testing.T) {
	want := map[string]int{
		"_STRG_DEL_ITEM":     4,
		"_STRG_MOVE_ITEM":    8,
		"_STRG_SWAP_ITEM":    8,
		"_STRG_MERGE_ITEM":   8,
		"_STRG_MOVEITEM_NEW": 9,
	}
	got := map[string]int{}
	for _, p := range Procs {
		if _, ok := want[p.Name]; ok {
			got[p.Name] = p.Args
		}
	}
	for name, n := range want {
		if got[name] != n {
			t.Errorf("%s takes %d arguments, want %d", name, got[name], n)
		}
	}
}

// The reference-table list must stay exactly the set docs/protocol/refdata_tables.md
// enumerated from the 85 loader functions. The two were recovered by probes
// with nothing in common -- reading loaders versus harvesting strings -- and
// their agreeing is the only reason "85" can be called complete rather than
// "85 found so far". If either drifts, that claim stops being true.
func TestReferenceTablesMatchTheCatalogue(t *testing.T) {
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(root, "docs", "protocol", "refdata_tables.md"))
	if err != nil {
		t.Fatal(err)
	}
	inDoc := map[string]bool{}
	for _, m := range regexp.MustCompile(`_REF[A-Z0-9_]+`).FindAllString(string(raw), -1) {
		inDoc[m] = true
	}
	inCode := map[string]bool{}
	for _, tbl := range ReferenceTables {
		inCode[tbl] = true
	}
	for tbl := range inDoc {
		if !inCode[tbl] {
			t.Errorf("%s is in refdata_tables.md but not in ReferenceTables", tbl)
		}
	}
	for tbl := range inCode {
		if !inDoc[tbl] {
			t.Errorf("%s is in ReferenceTables but not in refdata_tables.md", tbl)
		}
	}
	if len(ReferenceTables) != 85 {
		t.Errorf("%d reference tables, want 85", len(ReferenceTables))
	}
}

func TestTablesAreDistinctAndDisjoint(t *testing.T) {
	seen := map[string]string{}
	for _, tbl := range ReferenceTables {
		if prev, dup := seen[tbl]; dup {
			t.Errorf("%s appears twice (%s)", tbl, prev)
		}
		seen[tbl] = "reference"
		if !strings.HasPrefix(tbl, "_REF") {
			t.Errorf("%s is in ReferenceTables but is not a _REF table", tbl)
		}
	}
	for _, tbl := range RuntimeTables {
		if prev, dup := seen[tbl]; dup {
			t.Errorf("%s appears in both lists (%s)", tbl, prev)
		}
		seen[tbl] = "runtime"
		if strings.HasPrefix(strings.ToUpper(tbl), "_REF") {
			t.Errorf("%s is a _REF table but is in RuntimeTables", tbl)
		}
	}
	// The runtime list IS the schema pool's table order. Holding them equal is
	// what stops the list drifting back to a hand-maintained one.
	if len(RuntimeTables) != len(SchemaTableOrder) {
		t.Errorf("%d runtime tables but %d in the schema pool", len(RuntimeTables), len(SchemaTableOrder))
	}
	for i := range RuntimeTables {
		if i < len(SchemaTableOrder) && RuntimeTables[i] != SchemaTableOrder[i] {
			t.Errorf("entry %d is %q in RuntimeTables and %q in the pool",
				i, RuntimeTables[i], SchemaTableOrder[i])
		}
	}
	// _LOADED is deliberately absent: it is not in the schema pool, which is
	// what resolved persistence.md's hedge that it might be a flag.
	for _, tbl := range RuntimeTables {
		if tbl == "_LOADED" {
			t.Error("_LOADED is back in RuntimeTables; it is not in the schema pool")
		}
	}
}

// The tables srrevamp already persists to should all be in the runtime list.
// This is the check that would catch a harvest that missed something obvious.
func TestTheObviousRuntimeTablesArePresent(t *testing.T) {
	need := []string{
		"_CHAR", "_USER", "_INVENTORY", "_ITEMS",
		"_CHARSKILL", "_CHARQUEST", "_GUILD", "_GUILDMEMBER",
	}
	have := map[string]bool{}
	for _, tbl := range RuntimeTables {
		have[tbl] = true
	}
	for _, tbl := range need {
		if !have[tbl] {
			t.Errorf("%s is missing from RuntimeTables", tbl)
		}
	}
}

// The nine slots are distinct indices inside the 12-slot AQ_Base vtable.
func TestSlotIndicesAreDistinctAndInRange(t *testing.T) {
	slots := map[string]int{
		"Destructor": SlotDestructor, "Reset": SlotReset, "Release": SlotRelease,
		"IsReady": SlotIsReady, "Prepare": SlotPrepare, "DoWork": SlotDoWork,
		"OnSuccess": SlotOnSuccess, "OnFailure": SlotOnFailure,
		"OnCleanup": SlotOnCleanup, "OnFinish": SlotOnFinish,
	}
	seen := map[int]string{}
	for name, i := range slots {
		if prev, dup := seen[i]; dup {
			t.Errorf("slots %s and %s are both %d", prev, name, i)
		}
		seen[i] = name
		if i < 0 || i >= 12 {
			t.Errorf("slot %s is %d, outside AQ_Base's 12", name, i)
		}
	}
	if SlotDoWork != 6 {
		t.Errorf("SlotDoWork is %d; the engine's own DoWork() strings are in slot 6", SlotDoWork)
	}
	if QueryStateRunning != 0xb {
		t.Errorf("QueryStateRunning is %#x; both callbacks assert 0xb", QueryStateRunning)
	}
}

// Not one of the 85 reference tables declares a column name in the binary, and
// that is structural: they are read with `SELECT * FROM %s` and consumed
// positionally by the ExtractData deserializers, so the server never needs
// their names. This is the fact that closes the item-column-naming question --
// see docs/protocol/db_columns.md.
func TestNoReferenceTableIsInTheSchemaPool(t *testing.T) {
	inPool := map[string]bool{}
	for _, tbl := range SchemaTableOrder {
		inPool[strings.ToUpper(tbl)] = true
	}
	for _, tbl := range ReferenceTables {
		if inPool[strings.ToUpper(tbl)] {
			t.Errorf("%s is a reference table but declares columns in the schema pool", tbl)
		}
	}
}
