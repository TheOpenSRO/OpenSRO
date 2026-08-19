package equipment

import (
	"context"
	"errors"
	"os"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/inventory"
)

func testDSN() string {
	if v := os.Getenv("SRREVAMP_TEST_POSTGRES_DSN"); v != "" {
		return v
	}
	return "postgres://postgres:postgres@localhost:5432/srrevamp_test?sslmode=disable"
}

type stubMaxStacks map[int64]int

func (s stubMaxStacks) GetMaxStack(_ context.Context, itemID int64) (int, error) {
	v, ok := s[itemID]
	if !ok {
		return 0, errors.New("no such item")
	}
	return v, nil
}

func openTestStores(t *testing.T) (*SQLStore, inventory.Store) {
	t.Helper()
	inv, err := inventory.OpenSQLStore(testDSN(), stubMaxStacks{100: 1, 200: 1})
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	if err := inv.TruncateForTest(context.Background()); err != nil {
		t.Fatalf("truncating inventory: %v", err)
	}
	t.Cleanup(func() { inv.Close() })

	eq, err := OpenSQLStore(testDSN(), inv)
	if err != nil {
		t.Fatalf("OpenSQLStore: %v", err)
	}
	if err := eq.TruncateForTest(context.Background()); err != nil {
		t.Fatalf("truncating equipment: %v", err)
	}
	t.Cleanup(func() { eq.Close() })

	return eq, inv
}

func TestEquipMovesItemFromInventory(t *testing.T) {
	eq, inv := openTestStores(t)
	ctx := context.Background()
	inv.AddItem(ctx, 1, 100, 1) // lands in inventory slot 0

	if err := eq.Equip(ctx, 1, SlotWeapon, 0); err != nil {
		t.Fatalf("Equip: %v", err)
	}

	equipped, err := eq.Get(ctx, 1)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if len(equipped) != 1 || equipped[0].Slot != SlotWeapon || equipped[0].ItemID != 100 {
		t.Fatalf("got %+v, want weapon slot with item 100", equipped)
	}

	invList, err := inv.List(ctx, 1)
	if err != nil {
		t.Fatalf("inv.List: %v", err)
	}
	if len(invList) != 0 {
		t.Fatalf("expected item removed from inventory after equip, got %+v", invList)
	}
}

func TestEquipInventorySlotEmpty(t *testing.T) {
	eq, _ := openTestStores(t)
	err := eq.Equip(context.Background(), 1, SlotWeapon, 0)
	if !errors.Is(err, ErrInventorySlotEmpty) {
		t.Fatalf("got %v, want ErrInventorySlotEmpty", err)
	}
}

func TestEquipInvalidSlot(t *testing.T) {
	eq, inv := openTestStores(t)
	ctx := context.Background()
	inv.AddItem(ctx, 1, 100, 1)

	err := eq.Equip(ctx, 1, Slot(99), 0)
	if !errors.Is(err, ErrInvalidSlot) {
		t.Fatalf("got %v, want ErrInvalidSlot", err)
	}
}

func TestEquipSwapsOutPreviousItem(t *testing.T) {
	eq, inv := openTestStores(t)
	ctx := context.Background()
	inv.AddItem(ctx, 1, 100, 1) // slot 0
	inv.AddItem(ctx, 1, 200, 1) // slot 1

	if err := eq.Equip(ctx, 1, SlotWeapon, 0); err != nil {
		t.Fatalf("first Equip: %v", err)
	}
	if err := eq.Equip(ctx, 1, SlotWeapon, 1); err != nil {
		t.Fatalf("second Equip: %v", err)
	}

	equipped, _ := eq.Get(ctx, 1)
	if len(equipped) != 1 || equipped[0].ItemID != 200 {
		t.Fatalf("expected weapon slot to now hold item 200, got %+v", equipped)
	}

	// The first item (100) should be back in the inventory.
	invList, _ := inv.List(ctx, 1)
	found := false
	for _, sl := range invList {
		if sl.ItemID == 100 {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected item 100 to return to inventory after being swapped out, got %+v", invList)
	}
}

func TestUnequip(t *testing.T) {
	eq, inv := openTestStores(t)
	ctx := context.Background()
	inv.AddItem(ctx, 1, 100, 1)
	eq.Equip(ctx, 1, SlotWeapon, 0)

	if err := eq.Unequip(ctx, 1, SlotWeapon); err != nil {
		t.Fatalf("Unequip: %v", err)
	}

	equipped, _ := eq.Get(ctx, 1)
	if len(equipped) != 0 {
		t.Fatalf("expected nothing equipped, got %+v", equipped)
	}
	invList, _ := inv.List(ctx, 1)
	if len(invList) != 1 || invList[0].ItemID != 100 {
		t.Fatalf("expected item back in inventory, got %+v", invList)
	}
}

func TestUnequipEmptySlot(t *testing.T) {
	eq, _ := openTestStores(t)
	err := eq.Unequip(context.Background(), 1, SlotWeapon)
	if !errors.Is(err, ErrSlotEmpty) {
		t.Fatalf("got %v, want ErrSlotEmpty", err)
	}
}

func TestEquipmentIsolatedPerCharacter(t *testing.T) {
	eq, inv := openTestStores(t)
	ctx := context.Background()
	inv.AddItem(ctx, 1, 100, 1)
	inv.AddItem(ctx, 2, 200, 1)
	eq.Equip(ctx, 1, SlotWeapon, 0)
	eq.Equip(ctx, 2, SlotWeapon, 0)

	e1, _ := eq.Get(ctx, 1)
	e2, _ := eq.Get(ctx, 2)
	if len(e1) != 1 || e1[0].ItemID != 100 {
		t.Fatalf("character 1: got %+v", e1)
	}
	if len(e2) != 1 || e2[0].ItemID != 200 {
		t.Fatalf("character 2: got %+v", e2)
	}
}

var _ Store = (*SQLStore)(nil)
