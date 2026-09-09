package quest

import (
	"context"
	"testing"
)

func TestMemStoreAccept(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()

	if err := store.Accept(ctx, 1, 999); err != ErrUnknownQuest {
		t.Fatalf("accepting a quest outside the catalog: got %v, want ErrUnknownQuest", err)
	}
	if err := store.Accept(ctx, 1, 1); err != nil {
		t.Fatalf("Accept: %v", err)
	}
	if err := store.Accept(ctx, 1, 1); err != ErrAlreadyAccepted {
		t.Fatalf("accepting twice: got %v, want ErrAlreadyAccepted", err)
	}

	progress, err := store.ListProgress(ctx, 1)
	if err != nil {
		t.Fatalf("ListProgress: %v", err)
	}
	if len(progress) != 1 || progress[0].QuestID != 1 || progress[0].Kills != 0 || progress[0].Completed {
		t.Fatalf("ListProgress = %+v, want quest 1 at zero kills", progress)
	}
}

// A kill counts once, only towards accepted quests, only for the matching
// monster, and only until the quest completes.
func TestMemStoreRecordKill(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()
	target := Catalog[1]

	if err := store.Accept(ctx, 1, 1); err != nil {
		t.Fatalf("Accept: %v", err)
	}

	done, err := store.RecordKill(ctx, 1, "Something Else")
	if err != nil {
		t.Fatalf("RecordKill: %v", err)
	}
	if len(done) != 0 {
		t.Fatalf("an unrelated kill completed %+v", done)
	}
	if p, _ := store.ListProgress(ctx, 1); p[0].Kills != 0 {
		t.Fatalf("an unrelated kill counted: %+v", p)
	}

	for i := 1; i < target.TargetKills; i++ {
		done, err = store.RecordKill(ctx, 1, target.MonsterName)
		if err != nil {
			t.Fatalf("RecordKill: %v", err)
		}
		if len(done) != 0 {
			t.Fatalf("quest completed after %d of %d kills", i, target.TargetKills)
		}
	}

	done, err = store.RecordKill(ctx, 1, target.MonsterName)
	if err != nil {
		t.Fatalf("RecordKill: %v", err)
	}
	if len(done) != 1 || done[0].ID != target.ID {
		t.Fatalf("the completing kill returned %+v, want quest %d", done, target.ID)
	}

	// Completing is once only -- a further kill must not report it again,
	// or the caller pays the reward twice.
	done, err = store.RecordKill(ctx, 1, target.MonsterName)
	if err != nil {
		t.Fatalf("RecordKill: %v", err)
	}
	if len(done) != 0 {
		t.Fatalf("a kill after completion reported %+v again", done)
	}

	// And a character who never accepted it gets nothing.
	done, _ = store.RecordKill(ctx, 2, target.MonsterName)
	if len(done) != 0 {
		t.Fatalf("a character with no accepted quests completed %+v", done)
	}
}
