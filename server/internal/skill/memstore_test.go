package skill

import (
	"context"
	"testing"
	"time"
)

func TestMemStoreLearnAndKnow(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()

	// Learn no longer validates the id (real skills are validated against the
	// refdata by session.LearnSkillHandler); the store just records it known.
	if err := store.Learn(ctx, 3, 999); err != nil {
		t.Fatalf("Learn(3, 999): %v", err)
	}
	if known, _ := store.Knows(ctx, 3, 999); !known {
		t.Error("Learn did not record the skill as known")
	}
	if err := store.Learn(ctx, 1, 1); err != nil {
		t.Fatalf("Learn: %v", err)
	}
	if err := store.Learn(ctx, 1, 1); err != ErrAlreadyKnown {
		t.Fatalf("learning twice: got %v, want ErrAlreadyKnown", err)
	}

	known, err := store.Knows(ctx, 1, 1)
	if err != nil || !known {
		t.Fatalf("Knows(1, 1) = %v, %v; want true", known, err)
	}
	if known, _ := store.Knows(ctx, 2, 1); known {
		t.Error("another character knows a skill they never learned")
	}

	if err := store.Learn(ctx, 1, 2); err != nil {
		t.Fatalf("Learn: %v", err)
	}
	list, err := store.KnownSkills(ctx, 1)
	if err != nil {
		t.Fatalf("KnownSkills: %v", err)
	}
	if len(list) != 2 || list[0] != 1 || list[1] != 2 {
		t.Fatalf("KnownSkills = %v, want [1 2] in id order", list)
	}
}

func TestMemStoreRecordsUseForCooldowns(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()

	if _, ok, _ := store.LastUsed(ctx, 1, 1); ok {
		t.Fatal("an unused skill reports a last-used time")
	}

	when := time.Now().Truncate(time.Second)
	if err := store.RecordUse(ctx, 1, 1, when); err != nil {
		t.Fatalf("RecordUse: %v", err)
	}
	got, ok, err := store.LastUsed(ctx, 1, 1)
	if err != nil || !ok {
		t.Fatalf("LastUsed = %v, %v, %v", got, ok, err)
	}
	if !got.Equal(when) {
		t.Fatalf("LastUsed = %v, want %v", got, when)
	}
}

func TestMemStoreSkillPointsAndMastery(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()

	if p, _ := store.SkillPoints(ctx, 1); p != 0 {
		t.Fatalf("fresh character has %d skill points, want 0", p)
	}
	if total, _ := store.AddSkillPoints(ctx, 1, 10); total != 10 {
		t.Fatalf("AddSkillPoints(+10) = %d, want 10", total)
	}
	// Spending more than held floors at zero, never negative.
	if total, _ := store.AddSkillPoints(ctx, 1, -100); total != 0 {
		t.Fatalf("AddSkillPoints(-100) from 10 = %d, want 0 (floored)", total)
	}

	// Raising with no points fails and changes nothing.
	if _, err := store.RaiseMastery(ctx, 1, 257, 3, 80); err != ErrInsufficientSkillPoints {
		t.Fatalf("RaiseMastery with 0 points: got %v, want ErrInsufficientSkillPoints", err)
	}

	store.AddSkillPoints(ctx, 1, 5)
	lvl, err := store.RaiseMastery(ctx, 1, 257, 3, 80) // cost 3, single-mastery cap 80
	if err != nil || lvl != 1 {
		t.Fatalf("RaiseMastery = %d, %v; want 1, nil", lvl, err)
	}
	if p, _ := store.SkillPoints(ctx, 1); p != 2 {
		t.Fatalf("skill points after spending 3 of 5 = %d, want 2", p)
	}
	if levels, _ := store.MasteryLevels(ctx, 1); levels[257] != 1 {
		t.Fatalf("mastery 257 level = %d, want 1", levels[257])
	}

	// At the cap, a raise is refused and no points are spent.
	store.AddSkillPoints(ctx, 1, 100)
	if _, err := store.RaiseMastery(ctx, 1, 257, 3, 1); err != ErrMasteryCapped {
		t.Fatalf("RaiseMastery at cap: got %v, want ErrMasteryCapped", err)
	}
	if p, _ := store.SkillPoints(ctx, 1); p != 102 {
		t.Fatalf("points after a capped (refused) raise = %d, want 102 (unspent)", p)
	}
}
