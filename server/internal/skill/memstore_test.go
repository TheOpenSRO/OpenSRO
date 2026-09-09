package skill

import (
	"context"
	"testing"
	"time"
)

func TestMemStoreLearnAndKnow(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()

	if err := store.Learn(ctx, 1, 999); err != ErrUnknownSkill {
		t.Fatalf("learning a skill outside the catalog: got %v, want ErrUnknownSkill", err)
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
