package quest

import (
	"context"
	"reflect"
	"testing"
)

// Round 692: a new character's default quests are recorded by code name at
// the Status `_AddNewChar` writes, once each, and do not touch the invented
// Catalog's progress. Both stores; the table is additive and its creation
// idempotent. NEGATIVE: before round 692 neither store has
// GrantDefaultQuests and this file does not compile.

type granter interface {
	Store
	GrantDefaultQuests(ctx context.Context, characterID int64, codes []string) error
	DefaultQuests(ctx context.Context, characterID int64) ([]GrantedQuest, error)
}

func checkGrantDefaultQuests(t *testing.T, s granter) {
	t.Helper()
	ctx := context.Background()
	// Synthetic codes. QSYN_A and QSYNB sort one way by bytes and the other
	// under en_US (which ignores the underscore): the order must be the bytes'.
	if err := s.GrantDefaultQuests(ctx, 9, []string{"QSYN_A", "QSYNB", "QSYN_C"}); err != nil {
		t.Fatal(err)
	}
	if err := s.GrantDefaultQuests(ctx, 9, []string{"QSYN_C"}); err != nil { // idempotent
		t.Fatal(err)
	}
	got, err := s.DefaultQuests(ctx, 9)
	if err != nil {
		t.Fatal(err)
	}
	want := []GrantedQuest{{"QSYNB", 1}, {"QSYN_A", 1}, {"QSYN_C", 1}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("grants %+v, want %+v", got, want)
	}
	if p, _ := s.States(ctx, 9); len(p) != 0 {
		t.Errorf("states %+v, want none: a grant is not a quest log entry", p)
	}
	if other, _ := s.DefaultQuests(ctx, 10); len(other) != 0 {
		t.Errorf("another character has grants %+v", other)
	}
}

func TestGrantDefaultQuestsMem(t *testing.T) { checkGrantDefaultQuests(t, NewMemStore()) }

func TestGrantDefaultQuestsSQL(t *testing.T) {
	checkGrantDefaultQuests(t, openTestSQLStore(t))
	again, err := OpenSQLStore(testDSN())
	if err != nil {
		t.Fatal(err)
	}
	again.Close()
}
