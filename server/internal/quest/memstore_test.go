package quest

import (
	"context"
	"testing"
)

func TestMemStoreStates(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()
	if err := store.Put(ctx, 1, State{QuestID: 7, Status: StatusAchieving, Counts: []int{2, 0}}); err != nil {
		t.Fatal(err)
	}
	if err := store.Put(ctx, 1, State{QuestID: 3, Status: StatusAchieved, Achieved: 1}); err != nil {
		t.Fatal(err)
	}
	got, _ := store.States(ctx, 1)
	if len(got) != 2 || got[0].QuestID != 3 || got[1].QuestID != 7 || got[1].Counts[0] != 2 {
		t.Fatalf("states %+v", got)
	}
	// The store keeps its own copy.
	got[1].Counts[0] = 99
	again, _ := store.States(ctx, 1)
	if again[1].Counts[0] != 2 {
		t.Fatal("States must return copies")
	}
	if err := store.Delete(ctx, 1, 7); err != nil {
		t.Fatal(err)
	}
	if got, _ := store.States(ctx, 1); len(got) != 1 {
		t.Fatalf("after delete %+v", got)
	}
	if got, _ := store.States(ctx, 2); len(got) != 0 {
		t.Fatalf("another character %+v", got)
	}
}
