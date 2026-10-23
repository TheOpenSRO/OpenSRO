package character

import (
	"reflect"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/persistence"
)

// The column list here must stay the one the binary declares. Holding it equal
// to the extracted pool is what stops this file becoming a stale copy.
func TestEngineColumnsMatchTheExtractedPool(t *testing.T) {
	pooled := persistence.TableColumns["_CHAR"]
	if !reflect.DeepEqual(EngineCharColumns, pooled) {
		t.Errorf("_CHAR columns differ from the schema pool.\n here: %v\n pool: %v",
			EngineCharColumns, pooled)
	}
	if len(EngineCharColumns) != 42 {
		t.Errorf("%d columns, want the 42 _CHAR introduces", len(EngineCharColumns))
	}
}

// Every field of Character must have a mapping entry. Adding a field without
// one should fail, so that a new field has to state whether the engine has a
// column for it.
func TestEveryCharacterFieldIsMapped(t *testing.T) {
	typ := reflect.TypeOf(Character{})
	mapped := map[string]bool{}
	for _, m := range Mapping {
		if mapped[m.Field] {
			t.Errorf("%s is mapped twice", m.Field)
		}
		mapped[m.Field] = true
	}
	for i := 0; i < typ.NumField(); i++ {
		f := typ.Field(i).Name
		if !mapped[f] {
			t.Errorf("Character.%s has no entry in Mapping -- say whether _CHAR has "+
				"a column for it, or record it as a divergence", f)
		}
	}
	if len(Mapping) != typ.NumField() {
		t.Errorf("Mapping has %d entries for %d fields", len(Mapping), typ.NumField())
	}
}

// A mapped column must actually exist in the engine's list, and a field with no
// column must explain itself.
func TestMappingIsConsistent(t *testing.T) {
	known := map[string]bool{}
	for _, c := range EngineCharColumns {
		known[c] = true
	}
	for _, m := range Mapping {
		if m.Column != "" && !known[m.Column] {
			t.Errorf("%s maps to %q, which is not a _CHAR column", m.Field, m.Column)
		}
		if m.Column == "" && m.Note == "" {
			t.Errorf("%s maps to no column and gives no reason", m.Field)
		}
	}
}

// Every engine column is either claimed by a field or listed as engine-only.
// Neither list may claim the same column, and between them they must cover all
// 42 -- otherwise a column has silently gone unconsidered.
func TestEveryEngineColumnIsAccountedFor(t *testing.T) {
	claimed := map[string]string{}
	for _, m := range Mapping {
		if m.Column == "" {
			continue
		}
		if prev, dup := claimed[m.Column]; dup {
			t.Errorf("%s is claimed by both %s and %s", m.Column, prev, m.Field)
		}
		claimed[m.Column] = m.Field
	}
	for _, c := range EngineCharColumns {
		_, byField := claimed[c]
		_, engineOnly := EngineOnlyColumns[c]
		switch {
		case byField && engineOnly:
			t.Errorf("%s is both mapped to %s and listed as engine-only", c, claimed[c])
		case !byField && !engineOnly:
			t.Errorf("%s is neither mapped nor listed as engine-only", c)
		}
	}
	for c := range EngineOnlyColumns {
		if !known(c) {
			t.Errorf("EngineOnlyColumns lists %q, which is not a _CHAR column", c)
		}
	}
}

func known(c string) bool {
	for _, x := range EngineCharColumns {
		if x == c {
			return true
		}
	}
	return false
}

// The engine persists current MP and OpenSRO does not. That is a deliberate
// divergence, and this test exists so it stays a stated one -- internal/mana's
// comment used to read as though non-persistence followed the game.
func TestMPIsRecordedAsADivergence(t *testing.T) {
	note, ok := EngineOnlyColumns["MP"]
	if !ok {
		t.Fatal("MP is no longer listed as an engine-only column")
	}
	if note == "" {
		t.Error("MP's divergence must carry its reason")
	}
	for _, m := range Mapping {
		if m.Column == "MP" {
			t.Errorf("Character.%s now maps to MP; the divergence note needs revisiting", m.Field)
		}
	}
}
