package inventory

import (
	"context"
	"errors"
	"os"
	"testing"
)

// testDSN points at a local PostgreSQL instance for tests. Override with
// OPENSRO_TEST_POSTGRES_DSN if your dev setup differs (e.g. CI).
func testDSN() string {
	if v := os.Getenv("OPENSRO_TEST_POSTGRES_DSN"); v != "" {
		return v
	}
	return "postgres://postgres:postgres@localhost:5432/opensro_test?sslmode=disable"
}

// stubMaxStacks is a fixed-answer MaxStackLookup for tests, so they don't
// need a real refdata store.
type stubMaxStacks map[int64]int

// An item that is not in the stub is one with no reference data, which the
// MaxStackLookup contract says answers zero -- "no configured limit" --
// rather than an error.
func (s stubMaxStacks) GetMaxStack(_ context.Context, itemID int64) (int, error) {
	return s[itemID], nil
}

func openTestSQLStore(t *testing.T, maxStacks MaxStackLookup) *SQLStore {
	t.Helper()
	s, err := OpenSQLStore(testDSN(), maxStacks)
	if err != nil {
		t.Fatalf("OpenSQLStore: %v (is postgres running? see testDSN)", err)
	}
	if _, err := s.db.Exec(`TRUNCATE TABLE inventory_slots`); err != nil {
		t.Fatalf("truncating inventory_slots table: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestAddItemNewStack(t *testing.T) {
	store := openTestSQLStore(t, stubMaxStacks{100: 20})
	ctx := context.Background()

	if err := store.AddItem(ctx, 1, 100, 5); err != nil {
		t.Fatalf("AddItem: %v", err)
	}

	list, err := store.List(ctx, 1)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(list) != 1 || list[0].ItemID != 100 || list[0].Quantity != 5 {
		t.Fatalf("got %+v, want a single slot with 5x item 100", list)
	}
}

func TestAddItemFillsExistingStackBeforeNewSlot(t *testing.T) {
	store := openTestSQLStore(t, stubMaxStacks{100: 20})
	ctx := context.Background()

	store.AddItem(ctx, 1, 100, 15) // one slot, 15/20
	if err := store.AddItem(ctx, 1, 100, 3); err != nil {
		t.Fatalf("AddItem: %v", err)
	}

	list, err := store.List(ctx, 1)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(list) != 1 || list[0].Quantity != 18 {
		t.Fatalf("expected the existing stack to be topped up to 18, got %+v", list)
	}
}

func TestAddItemOverflowsToNewSlot(t *testing.T) {
	store := openTestSQLStore(t, stubMaxStacks{100: 20})
	ctx := context.Background()

	store.AddItem(ctx, 1, 100, 20) // fills one slot exactly
	if err := store.AddItem(ctx, 1, 100, 5); err != nil {
		t.Fatalf("AddItem: %v", err)
	}

	list, err := store.List(ctx, 1)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(list) != 2 {
		t.Fatalf("expected overflow into a second slot, got %+v", list)
	}
	total := list[0].Quantity + list[1].Quantity
	if total != 25 {
		t.Fatalf("total quantity across slots = %d, want 25", total)
	}
}

func TestAddItemNoRoom(t *testing.T) {
	store := openTestSQLStore(t, stubMaxStacks{100: 1})
	ctx := context.Background()

	for i := 0; i < SlotsPerCharacter; i++ {
		if err := store.AddItem(ctx, 1, 100, 1); err != nil {
			t.Fatalf("AddItem #%d: %v", i, err)
		}
	}

	err := store.AddItem(ctx, 1, 100, 1)
	if !errors.Is(err, ErrNoRoom) {
		t.Fatalf("got %v, want ErrNoRoom", err)
	}
}

func TestAddItemDifferentItemsGetSeparateSlots(t *testing.T) {
	store := openTestSQLStore(t, stubMaxStacks{100: 20, 200: 20})
	ctx := context.Background()

	store.AddItem(ctx, 1, 100, 5)
	store.AddItem(ctx, 1, 200, 5)

	list, err := store.List(ctx, 1)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(list) != 2 {
		t.Fatalf("expected two separate slots for two different items, got %+v", list)
	}
}

func TestRemoveItemPartial(t *testing.T) {
	store := openTestSQLStore(t, stubMaxStacks{100: 20})
	ctx := context.Background()
	store.AddItem(ctx, 1, 100, 10)

	if err := store.RemoveItem(ctx, 1, 0, 4); err != nil {
		t.Fatalf("RemoveItem: %v", err)
	}

	list, err := store.List(ctx, 1)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(list) != 1 || list[0].Quantity != 6 {
		t.Fatalf("expected 6 remaining, got %+v", list)
	}
}

func TestRemoveItemExactClearsSlot(t *testing.T) {
	store := openTestSQLStore(t, stubMaxStacks{100: 20})
	ctx := context.Background()
	store.AddItem(ctx, 1, 100, 10)

	if err := store.RemoveItem(ctx, 1, 0, 10); err != nil {
		t.Fatalf("RemoveItem: %v", err)
	}

	list, err := store.List(ctx, 1)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(list) != 0 {
		t.Fatalf("expected slot to be freed, got %+v", list)
	}
}

func TestRemoveItemInsufficientQuantity(t *testing.T) {
	store := openTestSQLStore(t, stubMaxStacks{100: 20})
	ctx := context.Background()
	store.AddItem(ctx, 1, 100, 5)

	err := store.RemoveItem(ctx, 1, 0, 10)
	if !errors.Is(err, ErrInsufficientQuantity) {
		t.Fatalf("got %v, want ErrInsufficientQuantity", err)
	}
}

func TestRemoveItemEmptySlot(t *testing.T) {
	store := openTestSQLStore(t, stubMaxStacks{})
	err := store.RemoveItem(context.Background(), 1, 0, 1)
	if !errors.Is(err, ErrSlotEmpty) {
		t.Fatalf("got %v, want ErrSlotEmpty", err)
	}
}

func TestRemoveItemInvalidSlot(t *testing.T) {
	store := openTestSQLStore(t, stubMaxStacks{})
	err := store.RemoveItem(context.Background(), 1, SlotsPerCharacter+1, 1)
	if !errors.Is(err, ErrInvalidSlot) {
		t.Fatalf("got %v, want ErrInvalidSlot", err)
	}
}

func TestInventoryIsolatedPerCharacter(t *testing.T) {
	store := openTestSQLStore(t, stubMaxStacks{100: 20})
	ctx := context.Background()

	store.AddItem(ctx, 1, 100, 5)
	store.AddItem(ctx, 2, 100, 7)

	list1, _ := store.List(ctx, 1)
	list2, _ := store.List(ctx, 2)
	if len(list1) != 1 || list1[0].Quantity != 5 {
		t.Fatalf("character 1: got %+v, want 5x item 100", list1)
	}
	if len(list2) != 1 || list2[0].Quantity != 7 {
		t.Fatalf("character 2: got %+v, want 7x item 100", list2)
	}
}

var _ Store = (*SQLStore)(nil)
