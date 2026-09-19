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
	// 71, CORRECTED 2026-09-17 from 39. The original harvest matched only
	// `{?=CALL _NAME (...)}`; the server also calls procedures as
	// `{CALL _NAME (...)}` and `EXEC _NAME ...`, which together account for the
	// 32 added. See the package comment for why this is the same defect as the
	// runtime-table undercount.
	if len(Procs) != 71 {
		t.Errorf("%d procedures; 71 were harvested across all three call forms", len(Procs))
	}
}

// The procedures that were missed are the interesting ones, because their
// absence made a FALSE claim look supported: docs/protocol/persistence.md said
// "there is no procedure for gaining experience, taking damage, or changing a
// skill level", and _skill_manage is right there. Item creation was missing
// entirely too, so the catalogue could describe moving an item but not making
// one. Pin the ones whose absence changed a conclusion.
func TestTheProceduresTheFirstHarvestMissed(t *testing.T) {
	have := map[string]Proc{}
	for _, p := range Procs {
		have[p.Name] = p
	}
	for _, name := range []string{
		// The claim-falsifying pair.
		"_skill_manage", "_quest_manage",
		// Every route by which an item comes into existence.
		"_STRG_ADD_EQUIP_NORMAL", "_STRG_ADD_EXPENDABLE", "_STRG_ADD_ALCHEMYSTONE",
		"_STRG_ADD_SPECIALTY", "_STRG_ADD_ITEM_MAGIC", "_STRG_ADD_PACKAGEITEM",
		// Reading gold, which only had writers before.
		"_GET_USER_GOLD", "_GET_GUILD_GOLD",
	} {
		if _, ok := have[name]; !ok {
			t.Errorf("%s is missing; it was one of the 32 the {?=CALL} pattern never saw", name)
		}
	}
	// Exactly two procedures are variadic, and both are the magic-item ones.
	var variadic []string
	for _, p := range Procs {
		if p.Variadic {
			variadic = append(variadic, p.Name)
		}
	}
	if len(variadic) != 2 {
		t.Errorf("%d variadic procedures %v; only the two magic-item ones are", len(variadic), variadic)
	}
	for _, name := range variadic {
		if !strings.Contains(name, "ITEM_MAGIC") {
			t.Errorf("%s is marked variadic but is not a magic-item procedure", name)
		}
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
	// The binary spells its tables three ways (_REFNAME, TAB_REFNAME,
	// _RefName) and the docs quote them as they appear; compare the names
	// normalised -- upper-cased, without the leading underscore or TAB_.
	inDoc := map[string]bool{}
	for _, m := range regexp.MustCompile(`(?:_REF|_Ref|TAB_REF)[A-Za-z0-9_]+`).FindAllString(string(raw), -1) {
		inDoc[normaliseTableName(m)] = true
	}
	inCode := map[string]bool{}
	for _, tbl := range ReferenceTables {
		inCode[normaliseTableName(tbl)] = true
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
	if len(ReferenceTables) != 124 {
		t.Errorf("%d reference tables, want 124", len(ReferenceTables))
	}
}

func normaliseTableName(name string) string {
	n := strings.ToUpper(name)
	n = strings.TrimPrefix(n, "TAB_")
	return strings.TrimPrefix(n, "_")
}

func TestTablesAreDistinctAndDisjoint(t *testing.T) {
	seen := map[string]string{}
	for _, tbl := range ReferenceTables {
		if prev, dup := seen[tbl]; dup {
			t.Errorf("%s appears twice (%s)", tbl, prev)
		}
		seen[tbl] = "reference"
		if !strings.HasPrefix(tbl, "_REF") && !strings.HasPrefix(tbl, "_Ref") && !strings.HasPrefix(tbl, "TAB_REF") {
			t.Errorf("%s is in ReferenceTables but is not a reference table by any of the three spellings", tbl)
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
