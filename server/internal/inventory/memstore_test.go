package inventory

import (
	"context"
	"testing"
)

// The point of MemStore is that it is interchangeable with SQLStore, so
// these are the same behaviours sqlstore_test.go asserts -- stacking
// order, overflow, the no-room case and partial removal -- checked against
// the in-memory implementation.

func TestMemStoreAddItemFillsExistingStackBeforeNewSlot(t *testing.T) {
	store := NewMemStore(stubMaxStacks{100: 20})
	ctx := context.Background()

	if err := store.AddItem(ctx, 1, 100, 5); err != nil {
		t.Fatalf("AddItem: %v", err)
	}
	if err := store.AddItem(ctx, 1, 100, 10); err != nil {
		t.Fatalf("AddItem: %v", err)
	}

	list, err := store.List(ctx, 1)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(list) != 1 || list[0].Quantity != 15 {
		t.Fatalf("got %+v, want one slot holding 15", list)
	}
}

func TestMemStoreAddItemOverflowsToNewSlot(t *testing.T) {
	store := NewMemStore(stubMaxStacks{100: 20})
	ctx := context.Background()

	if err := store.AddItem(ctx, 1, 100, 25); err != nil {
		t.Fatalf("AddItem: %v", err)
	}

	list, err := store.List(ctx, 1)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(list) != 2 || list[0].Quantity != 20 || list[1].Quantity != 5 {
		t.Fatalf("got %+v, want 20 in slot 0 and 5 in slot 1", list)
	}
	if list[0].Index != 0 || list[1].Index != 1 {
		t.Fatalf("got indices %d and %d, want the two lowest free slots", list[0].Index, list[1].Index)
	}
}

// A request that does not fit must leave the inventory as it was, rather
// than filling what it can and reporting failure.
func TestMemStoreAddItemNoRoomIsAtomic(t *testing.T) {
	store := NewMemStore(stubMaxStacks{100: 1})
	ctx := context.Background()

	if err := store.AddItem(ctx, 1, 100, SlotsPerCharacter+5); err != ErrNoRoom {
		t.Fatalf("AddItem: got %v, want ErrNoRoom", err)
	}
	list, err := store.List(ctx, 1)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(list) != 0 {
		t.Fatalf("a refused AddItem left %d slot(s) filled, want 0", len(list))
	}
}

func TestMemStoreRemoveItem(t *testing.T) {
	store := NewMemStore(stubMaxStacks{100: 20})
	ctx := context.Background()

	if err := store.AddItem(ctx, 1, 100, 5); err != nil {
		t.Fatalf("AddItem: %v", err)
	}
	if err := store.RemoveItem(ctx, 1, 0, 2); err != nil {
		t.Fatalf("RemoveItem: %v", err)
	}
	list, _ := store.List(ctx, 1)
	if len(list) != 1 || list[0].Quantity != 3 {
		t.Fatalf("got %+v, want 3 left in the slot", list)
	}

	if err := store.RemoveItem(ctx, 1, 0, 4); err != ErrInsufficientQuantity {
		t.Fatalf("over-removal: got %v, want ErrInsufficientQuantity", err)
	}
	if err := store.RemoveItem(ctx, 1, 0, 3); err != nil {
		t.Fatalf("RemoveItem: %v", err)
	}
	if list, _ := store.List(ctx, 1); len(list) != 0 {
		t.Fatalf("emptying a slot left %+v, want it free", list)
	}
	if err := store.RemoveItem(ctx, 1, 0, 1); err != ErrSlotEmpty {
		t.Fatalf("removing from a free slot: got %v, want ErrSlotEmpty", err)
	}
	if err := store.RemoveItem(ctx, 1, SlotsPerCharacter, 1); err != ErrInvalidSlot {
		t.Fatalf("out-of-range slot: got %v, want ErrInvalidSlot", err)
	}
}

// Two characters must not see each other's items.
func TestMemStoreKeepsCharactersApart(t *testing.T) {
	store := NewMemStore(stubMaxStacks{100: 20, 200: 20})
	ctx := context.Background()

	if err := store.AddItem(ctx, 1, 100, 3); err != nil {
		t.Fatalf("AddItem: %v", err)
	}
	if err := store.AddItem(ctx, 2, 200, 7); err != nil {
		t.Fatalf("AddItem: %v", err)
	}

	one, _ := store.List(ctx, 1)
	two, _ := store.List(ctx, 2)
	if len(one) != 1 || one[0].ItemID != 100 {
		t.Errorf("character 1 holds %+v", one)
	}
	if len(two) != 1 || two[0].ItemID != 200 {
		t.Errorf("character 2 holds %+v", two)
	}
}

// An item the reference data has never heard of still has to be storable.
// It is not a hypothetical: the five starting-kit items have no rows on a
// deployment that has imported nothing, and an error here left every new
// character undressed with only a line in the server log to say why.
func TestMemStoreHoldsAnItemWithNoReferenceData(t *testing.T) {
	store := NewMemStore(stubMaxStacks{})
	ctx := context.Background()

	if err := store.AddItem(ctx, 1, 4734, 1); err != nil {
		t.Fatalf("AddItem for an item with no max-stack row: %v", err)
	}
	list, _ := store.List(ctx, 1)
	if len(list) != 1 || list[0].ItemID != 4734 || list[0].Quantity != 1 {
		t.Fatalf("got %+v, want one of item 4734", list)
	}
}
