package persistence

import (
	"strconv"
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

// The control that makes BoundColumns trustworthy, and the reason it exists.
//
// docs/protocol/character_schema.md states _CHAR's 42 columns, recovered from
// the deduplicated string pool. The binder read gives 43. They must agree
// exactly but for the key: nothing the document lists may be missing here, and
// the single extra must be CharID, which the pool attributes to whichever table
// introduces it first rather than to _CHAR.
//
// If this ever fails, the extraction has drifted and BoundColumns should not be
// trusted for the other 55 tables either -- this is the only one with an
// independent answer to check against.
func TestBoundColumnsMatchTheDocumentedCharSchema(t *testing.T) {
	bound := BoundColumns["_CHAR"]
	if len(bound) == 0 {
		t.Fatal("BoundColumns has no _CHAR")
	}
	have := map[string]bool{}
	for _, c := range bound {
		have[c] = true
	}
	documented := TableColumns["_CHAR"]
	if len(documented) != 42 {
		t.Fatalf("TableColumns[_CHAR] has %d names, want the documented 42", len(documented))
	}
	for _, c := range documented {
		if !have[c] {
			t.Errorf("_CHAR column %q is in the string pool but not in the binder read", c)
		}
	}
	var extra []string
	for _, c := range bound {
		found := false
		for _, d := range documented {
			if c == d {
				found = true
				break
			}
		}
		if !found {
			extra = append(extra, c)
		}
	}
	if len(extra) != 1 || extra[0] != "CharID" {
		t.Errorf("binder has extras %v, want exactly [CharID] -- the primary key the "+
			"pool attributes to another table", extra)
	}
}

// LiteralNamedTables are the five runtime tables that have a DB_Bind__ binder
// but whose names are absent from the 310-string schema pool entirely.
//
// This was a wrong assumption before it was a finding: the first version of the
// test below asserted every bound table is a pool table, and failed on these
// five. They are not an extraction defect. `_ChestInfo` is the proof from two
// directions -- the warehouse work already cited its binder at 0x8586e0, which
// this sweep found independently, and the binder declares the name as an INLINE
// LITERAL rather than a pointer into the pool. Names reach the pool by being
// registered through the schema machinery; a literal never enters it.
//
// So the pool's 54 table names are not the count of runtime tables. The binder
// family says at least 59.
var LiteralNamedTables = map[string]bool{
	"_OpenMarket":            true,
	"_ShopItemStockQuantity": true,
	"_RentItemInfo":          true,
	"_ChestInfo":             true,
	"_BindingOptionWithItem": true,
}

// Every bound table is either one the pool knows or one of the five that
// declare their name as a literal. A new name in neither set means the
// extraction has drifted.
func TestBoundColumnsTablesAreAccountedFor(t *testing.T) {
	for table := range BoundColumns {
		if _, ok := TableColumns[table]; ok {
			continue
		}
		if LiteralNamedTables[table] {
			continue
		}
		t.Errorf("BoundColumns has %q, which is neither in the schema pool nor a "+
			"recorded literal-named table", table)
	}
	for table := range LiteralNamedTables {
		if _, ok := BoundColumns[table]; !ok {
			t.Errorf("%q is recorded as a literal-named table but has no binder entry", table)
		}
	}
}

// The offsets are trustworthy only because of these two checks; both are the
// reason the FIRST extraction was thrown away.
func TestColumnOffsetsMatchIndependentlyRecordedOnes(t *testing.T) {
	for _, tc := range []struct {
		column string
		want   int
	}{
		{"Strength", 0x74},        // recorded from GObjPC_InitStats' graph
		{"RemainHwanCount", 0x86}, // recorded from the berserk economy
		{"PosX", 0x98},            // the float triple, consecutive by 4
		{"PosY", 0x9c},
		{"PosZ", 0xa0},
	} {
		got, ok := OffsetOf("_CHAR", tc.column)
		if !ok {
			t.Errorf("_CHAR.%s has no offset", tc.column)
			continue
		}
		if got != tc.want {
			t.Errorf("_CHAR.%s is at 0x%x, want 0x%x", tc.column, got, tc.want)
		}
	}
}

// No two columns of one table may share an offset. This is what caught the
// first extraction, which read the first assignment after each column name and
// so put PosX, PosY and PosZ all at 0x5 -- those three emit the offset and the
// type code in the opposite order to every other column.
func TestNoTwoColumnsShareAnOffset(t *testing.T) {
	seen := map[string]string{}
	for _, c := range ColumnOffsets {
		key := c.Table + "\x00" + string(rune(c.Offset))
		if prev, dup := seen[key]; dup {
			t.Errorf("%s: %s and %s both claim offset 0x%x", c.Table, prev, c.Column, c.Offset)
		}
		seen[key] = c.Column
	}
}

// The two extractions must agree, including on MULTIPLICITY.
//
// BoundColumns (round 307) writes a runtime-suffixed column as `Name*N`, from
// counting how many times the binder emits the base name. ColumnOffsets (round
// 308) has N separate rows for it, one per offset. The two were read on
// different days by different scripts, so their agreeing on N is a real check --
// and it is how the `Name*N` guess stopped being a guess: _ITEMS MagParam is 12
// rows at 0x60..0xb8, an exact 8-byte stride, immediately after MagParamNum at
// 0x58. The count field sits in front of the array it counts.
func TestOffsetsAgreeWithBoundColumns(t *testing.T) {
	for table, cols := range BoundColumns {
		want := map[string]int{}
		for _, name := range cols {
			base, n := name, 1
			if i := strings.Index(name, "*"); i >= 0 {
				base = name[:i]
				v, err := strconv.Atoi(name[i+1:])
				if err != nil {
					t.Errorf("%s: cannot read the repeat count in %q", table, name)
					continue
				}
				n = v
			}
			want[base] += n
		}
		got := map[string]int{}
		for _, c := range ColumnOffsets {
			if c.Table == table {
				got[c.Column]++
			}
		}
		for base, n := range want {
			if got[base] != n {
				t.Errorf("%s.%s: BoundColumns says %d, ColumnOffsets has %d",
					table, base, n, got[base])
			}
		}
		for base := range got {
			if _, ok := want[base]; !ok {
				t.Errorf("%s.%s has an offset but is not in BoundColumns", table, base)
			}
		}
	}
}

// The reverse lookup is the one this project keeps needing: an offset appears in
// a decompiled function and the question is which column it is.
func TestColumnAtResolvesARecordedOffset(t *testing.T) {
	if got, ok := ColumnAt("_CHAR", 0x86); !ok || got != "RemainHwanCount" {
		t.Errorf("ColumnAt(_CHAR, 0x86) = %q/%v, want RemainHwanCount", got, ok)
	}
}
