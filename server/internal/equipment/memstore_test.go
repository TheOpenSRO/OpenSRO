package equipment

import (
	"context"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
)

// A nil stack lookup means "nothing stacks", one item per slot -- which
// is what equipment wants, and what SQLStore does for an item with no
// configured limit.
func memPair() (*inventory.MemStore, *MemStore) {
	inv := inventory.NewMemStore(nil)
	return inv, NewMemStore(inv)
}

// Equipping takes the item out of the bag; unequipping puts it back. The
// item is never in both places and never in neither.
func TestMemStoreEquipMovesTheItem(t *testing.T) {
	inv, eq := memPair()
	ctx := context.Background()

	if err := inv.AddItem(ctx, 1, 4842, 1); err != nil {
		t.Fatalf("AddItem: %v", err)
	}
	if err := eq.Equip(ctx, 1, SlotMail, 0); err != nil {
		t.Fatalf("Equip: %v", err)
	}

	bag, _ := inv.List(ctx, 1)
	if len(bag) != 0 {
		t.Errorf("bag still holds %+v after equipping", bag)
	}
	worn, _ := eq.Get(ctx, 1)
	if len(worn) != 1 || worn[0].Slot != SlotMail || worn[0].ItemID != 4842 {
		t.Fatalf("worn = %+v, want item 4842 in the mail slot", worn)
	}

	if err := eq.Unequip(ctx, 1, SlotMail); err != nil {
		t.Fatalf("Unequip: %v", err)
	}
	bag, _ = inv.List(ctx, 1)
	if len(bag) != 1 || bag[0].ItemID != 4842 {
		t.Fatalf("bag = %+v after unequipping, want the item back", bag)
	}
	if worn, _ := eq.Get(ctx, 1); len(worn) != 0 {
		t.Fatalf("worn = %+v after unequipping, want nothing", worn)
	}
}

// Equipping over a filled slot returns the displaced item rather than
// destroying it.
func TestMemStoreEquipReturnsTheDisplacedItem(t *testing.T) {
	inv, eq := memPair()
	ctx := context.Background()

	if err := inv.AddItem(ctx, 1, 4842, 1); err != nil {
		t.Fatalf("AddItem: %v", err)
	}
	if err := inv.AddItem(ctx, 1, 4843, 1); err != nil {
		t.Fatalf("AddItem: %v", err)
	}
	if err := eq.Equip(ctx, 1, SlotMail, 0); err != nil {
		t.Fatalf("Equip: %v", err)
	}
	// Slots do not compact when one empties, so 4843 is still in slot 1.
	if err := eq.Equip(ctx, 1, SlotMail, 1); err != nil {
		t.Fatalf("Equip over a filled slot: %v", err)
	}

	worn, _ := eq.Get(ctx, 1)
	if len(worn) != 1 || worn[0].ItemID != 4843 {
		t.Fatalf("worn = %+v, want the new item", worn)
	}
	bag, _ := inv.List(ctx, 1)
	if len(bag) != 1 || bag[0].ItemID != 4842 {
		t.Fatalf("bag = %+v, want the displaced item back in it", bag)
	}
}

func TestMemStoreEquipRejectsAnEmptyInventorySlot(t *testing.T) {
	_, eq := memPair()
	if err := eq.Equip(context.Background(), 1, SlotMail, 3); err != ErrInventorySlotEmpty {
		t.Fatalf("got %v, want ErrInventorySlotEmpty", err)
	}
}

func TestMemStoreUnequipRejectsAnEmptySlot(t *testing.T) {
	_, eq := memPair()
	if err := eq.Unequip(context.Background(), 1, SlotMail); err != ErrSlotEmpty {
		t.Fatalf("got %v, want ErrSlotEmpty", err)
	}
}

// The starting kit is what dresses a new character, and it runs against
// whichever pair of stores the server was wired with -- so it has to work
// on these two as well as on the SQL ones.
func TestMemStoreTakesTheStartingKit(t *testing.T) {
	inv, eq := memPair()
	ctx := context.Background()

	if err := GiveStartingKit(ctx, inv, eq, 7, character.DefaultGender); err != nil {
		t.Fatalf("GiveStartingKit: %v", err)
	}
	worn, _ := eq.Get(ctx, 7)
	if kit := StartingKitFor(character.DefaultGender); len(worn) != len(kit) {
		t.Fatalf("dressed %d slot(s), want %d", len(worn), len(kit))
	}
	if bag, _ := inv.List(ctx, 7); len(bag) != 0 {
		t.Errorf("bag holds %+v, want the kit worn rather than carried", bag)
	}
}
