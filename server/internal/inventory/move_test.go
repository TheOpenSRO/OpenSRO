package inventory

import (
	"context"
	"fmt"
	"strings"
	"testing"
)

// MoveItem's three outcomes -- move, merge, swap -- and its refusals, run
// against BOTH stores through the same table, since the point of MemStore
// is that it is interchangeable with SQLStore.

// slotsOf flattens a List into "index:item×qty" strings so a whole-bag
// expectation reads at a glance.
func slotsOf(t *testing.T, s Store, characterID int64) []string {
	t.Helper()
	list, err := s.List(context.Background(), characterID)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	out := make([]string, 0, len(list))
	for _, sl := range list {
		out = append(out, fmt.Sprintf("%d:%dx%d", sl.Index, sl.ItemID, sl.Quantity))
	}
	return out
}

func wantSlots(t *testing.T, s Store, characterID int64, want ...string) {
	t.Helper()
	got := slotsOf(t, s, characterID)
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Fatalf("bag is %v, want %v", got, want)
	}
}

// moveStores yields each Store implementation fresh, with the given stack
// limits. The SQL store is truncated first so each case starts empty.
func moveStores(t *testing.T, limits stubMaxStacks) map[string]Store {
	t.Helper()
	sqlStore := openTestSQLStore(t, limits)
	if err := sqlStore.TruncateForTest(context.Background()); err != nil {
		t.Fatalf("truncate: %v", err)
	}
	return map[string]Store{
		"mem": NewMemStore(limits),
		"sql": sqlStore,
	}
}

func TestMoveItemIntoEmptySlot(t *testing.T) {
	for name, store := range moveStores(t, stubMaxStacks{100: 20}) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			if err := store.AddItem(ctx, 1, 100, 5); err != nil {
				t.Fatalf("AddItem: %v", err)
			}
			if err := store.MoveItem(ctx, 1, 0, 9); err != nil {
				t.Fatalf("MoveItem: %v", err)
			}
			wantSlots(t, store, 1, "9:100x5")
		})
	}
}

func TestMoveItemSwapsDifferentItems(t *testing.T) {
	for name, store := range moveStores(t, stubMaxStacks{100: 20, 200: 20}) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			if err := store.AddItem(ctx, 1, 100, 5); err != nil {
				t.Fatalf("AddItem: %v", err)
			}
			if err := store.AddItem(ctx, 1, 200, 7); err != nil {
				t.Fatalf("AddItem: %v", err)
			}
			if err := store.MoveItem(ctx, 1, 0, 1); err != nil {
				t.Fatalf("MoveItem: %v", err)
			}
			wantSlots(t, store, 1, "0:200x7", "1:100x5")
		})
	}
}

func TestMoveItemMergesSameItemFully(t *testing.T) {
	for name, store := range moveStores(t, stubMaxStacks{100: 20}) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			// Two under-full stacks of one item: fill slot 0 to its limit so
			// the rest spills to slot 1, then take some out of slot 0.
			if err := store.AddItem(ctx, 1, 100, 25); err != nil { // 20 + 5
				t.Fatalf("AddItem: %v", err)
			}
			if err := store.RemoveItem(ctx, 1, 0, 12); err != nil { // slot 0 now 8
				t.Fatalf("RemoveItem: %v", err)
			}
			if err := store.MoveItem(ctx, 1, 1, 0); err != nil { // 5 onto 8 fits
				t.Fatalf("MoveItem: %v", err)
			}
			wantSlots(t, store, 1, "0:100x13")
		})
	}
}

func TestMoveItemMergesSameItemPartially(t *testing.T) {
	for name, store := range moveStores(t, stubMaxStacks{100: 20}) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			if err := store.AddItem(ctx, 1, 100, 25); err != nil { // 20 + 5
				t.Fatalf("AddItem: %v", err)
			}
			if err := store.RemoveItem(ctx, 1, 0, 2); err != nil { // slot 0 now 18
				t.Fatalf("RemoveItem: %v", err)
			}
			if err := store.MoveItem(ctx, 1, 1, 0); err != nil { // only 2 of 5 fit
				t.Fatalf("MoveItem: %v", err)
			}
			wantSlots(t, store, 1, "0:100x20", "1:100x3")
		})
	}
}

func TestMoveItemNonStackableSameItemSwaps(t *testing.T) {
	// Two swords (no configured limit = one to a slot) never merge; they
	// swap places, and nothing is lost.
	for name, store := range moveStores(t, stubMaxStacks{}) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			if err := store.AddItem(ctx, 1, 300, 1); err != nil {
				t.Fatalf("AddItem: %v", err)
			}
			if err := store.AddItem(ctx, 1, 300, 1); err != nil {
				t.Fatalf("AddItem: %v", err)
			}
			if err := store.MoveItem(ctx, 1, 0, 1); err != nil {
				t.Fatalf("MoveItem: %v", err)
			}
			wantSlots(t, store, 1, "0:300x1", "1:300x1")
		})
	}
}

func TestMoveItemFullStackOfSameItemSwaps(t *testing.T) {
	// A full stack has no room, so a same-item drop swaps instead of
	// silently doing nothing.
	for name, store := range moveStores(t, stubMaxStacks{100: 20}) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			if err := store.AddItem(ctx, 1, 100, 23); err != nil { // 20 + 3
				t.Fatalf("AddItem: %v", err)
			}
			if err := store.MoveItem(ctx, 1, 1, 0); err != nil {
				t.Fatalf("MoveItem: %v", err)
			}
			wantSlots(t, store, 1, "0:100x3", "1:100x20")
		})
	}
}

func TestMoveItemRefusals(t *testing.T) {
	for name, store := range moveStores(t, stubMaxStacks{100: 20}) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			if err := store.AddItem(ctx, 1, 100, 5); err != nil {
				t.Fatalf("AddItem: %v", err)
			}
			if err := store.MoveItem(ctx, 1, 3, 4); err != ErrSlotEmpty {
				t.Fatalf("moving an empty slot: got %v, want ErrSlotEmpty", err)
			}
			if err := store.MoveItem(ctx, 1, 0, SlotsPerCharacter); err != ErrInvalidSlot {
				t.Fatalf("moving past the end: got %v, want ErrInvalidSlot", err)
			}
			if err := store.MoveItem(ctx, 1, -1, 0); err != ErrInvalidSlot {
				t.Fatalf("moving from -1: got %v, want ErrInvalidSlot", err)
			}
			if err := store.MoveItem(ctx, 1, 0, 0); err != nil {
				t.Fatalf("moving onto itself: got %v, want nil", err)
			}
			if err := store.MoveItem(ctx, 2, 0, 1); err != ErrSlotEmpty {
				t.Fatalf("a character with nothing: got %v, want ErrSlotEmpty", err)
			}
			wantSlots(t, store, 1, "0:100x5") // none of the above touched the bag
		})
	}
}
