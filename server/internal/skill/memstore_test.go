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

// TestAddSkillExpCarriesTheRemainder pins the mechanism, not just the number.
//
// The game grants skill EXPERIENCE and converts whole points out of a running
// total, keeping the remainder on the character (_CHAR.SExpOffset). Handing out
// whole points per kill -- which this project did until 2026-09-15 -- cannot
// reproduce that at any rate, because it rounds every kill to a whole point.
// Three kills worth 150 each should yield exactly one point, not zero and not
// three.
func TestAddSkillExpCarriesTheRemainder(t *testing.T) {
	ctx := context.Background()
	m := NewMemStore()

	// 150 + 150 = 300, still short of 400: no point yet, but nothing is lost.
	for i, want := range []int{0, 0} {
		gained, total, err := m.AddSkillExp(ctx, 1, 150)
		if err != nil {
			t.Fatalf("AddSkillExp #%d: %v", i, err)
		}
		if gained != want || total != want {
			t.Fatalf("after %d kills: gained %d total %d, want %d/%d", i+1, gained, total, want, want)
		}
	}
	// 450 crosses 400: one point, 50 carried.
	gained, total, err := m.AddSkillExp(ctx, 1, 150)
	if err != nil {
		t.Fatalf("AddSkillExp: %v", err)
	}
	if gained != 1 || total != 1 {
		t.Fatalf("third kill: gained %d total %d, want 1/1", gained, total)
	}
	// The carried 50 must still be there: 350 more reaches 400 exactly.
	if gained, _, _ := m.AddSkillExp(ctx, 1, 350); gained != 1 {
		t.Errorf("the remainder was dropped: 50 carried + 350 should award a point, got %d", gained)
	}

	// A single large award converts in one go rather than one point at a time.
	if gained, total, _ := m.AddSkillExp(ctx, 2, 400*7+399); gained != 7 || total != 7 {
		t.Errorf("a 7-point award: gained %d total %d, want 7/7", gained, total)
	}
	// ...and the 399 it carried is one short, so a single point of exp tips it.
	if gained, _, _ := m.AddSkillExp(ctx, 2, 1); gained != 1 {
		t.Errorf("the carried 399 + 1 should award a point, got %d", gained)
	}

	// Characters carry separately.
	if _, total, _ := m.AddSkillExp(ctx, 1, 0); total != 2 {
		t.Errorf("character 1 total = %d, want 2 -- character 2's exp leaked", total)
	}

	// Negative experience never removes points.
	if gained, total, _ := m.AddSkillExp(ctx, 1, -10_000); gained != 0 || total != 2 {
		t.Errorf("negative exp: gained %d total %d, want 0/2", gained, total)
	}
}
