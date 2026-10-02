package skill

import (
	"context"
	"testing"
)

// Round 692: a new character's default masteries are rows at level 0; a level
// already there is kept; a raise takes a seeded mastery from 0 to 1 as it
// takes an absent one. Both stores. NEGATIVE: before round 692 neither store
// has SeedMasteries and this file does not compile.

type seeder interface {
	Store
	SeedMasteries(ctx context.Context, characterID int64, masteryIDs []int64) error
}

func checkSeedMasteries(t *testing.T, s seeder) {
	t.Helper()
	ctx := context.Background()
	if _, err := s.AddSkillPoints(ctx, 7, 10); err != nil {
		t.Fatal(err)
	}
	if _, err := s.RaiseMastery(ctx, 7, 257, 0, 10); err != nil {
		t.Fatal(err)
	}
	if err := s.SeedMasteries(ctx, 7, []int64{257, 258, 259}); err != nil {
		t.Fatal(err)
	}
	if err := s.SeedMasteries(ctx, 7, []int64{258}); err != nil { // idempotent
		t.Fatal(err)
	}
	levels, err := s.MasteryLevels(ctx, 7)
	if err != nil {
		t.Fatal(err)
	}
	want := map[int64]int{257: 1, 258: 0, 259: 0}
	if len(levels) != len(want) {
		t.Fatalf("levels %v, want %v", levels, want)
	}
	for id, lvl := range want {
		if levels[id] != lvl {
			t.Errorf("mastery %d level %d, want %d", id, levels[id], lvl)
		}
	}
	if n, err := s.RaiseMastery(ctx, 7, 258, 0, 10); err != nil || n != 1 {
		t.Errorf("raising a seeded mastery: level %d err %v, want 1", n, err)
	}
	if pts, _ := s.SkillPoints(ctx, 7); pts != 10 {
		t.Errorf("points %d after free raises, want 10 (seeding spends none)", pts)
	}
}

func TestSeedMasteriesMem(t *testing.T) { checkSeedMasteries(t, NewMemStore()) }

func TestSeedMasteriesSQL(t *testing.T) {
	s := openTestSQLStore(t)
	checkSeedMasteries(t, s)
	// The schema is unchanged and opening again is harmless.
	again, err := OpenSQLStore(testDSN())
	if err != nil {
		t.Fatal(err)
	}
	again.Close()
}
