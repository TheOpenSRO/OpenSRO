package equipment

import (
	"context"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
)

// Round 732: an item's plus, blue options and advanced elixir go onto the
// body with it, survive a swap, and come back to the bag on unequip.
func testWornInstance(t *testing.T, eq Store, inv inventory.Store) {
	t.Helper()
	ctx := context.Background()
	inst := inventory.Instance{Variance: 0x3ff, Durability: 33, OptLevel: 5,
		MagParams: []uint64{inventory.MagParam(1, 7), inventory.MagParam(16, 100)}, AdvElixir: 2}
	if err := inv.AddItemInstance(ctx, 1, 100, 1, inst); err != nil {
		t.Fatal(err)
	}
	if err := inv.AddItem(ctx, 1, 200, 1); err != nil {
		t.Fatal(err)
	}
	if err := eq.Equip(ctx, 1, SlotWeapon, 0); err != nil {
		t.Fatalf("Equip: %v", err)
	}
	worn, err := eq.Get(ctx, 1)
	if err != nil || len(worn) != 1 || !worn[0].Instance().Equal(inst) {
		t.Fatalf("worn %+v %v, want the instance %+v", worn, err, inst)
	}
	// Swapping item 200 in sends item 100 back, instance and all.
	if err := eq.Equip(ctx, 1, SlotWeapon, 1); err != nil {
		t.Fatalf("Equip swap: %v", err)
	}
	bag, _ := inv.List(ctx, 1)
	if len(bag) != 1 || bag[0].ItemID != 100 || !bag[0].Instance().Equal(inst) {
		t.Fatalf("after the swap the bag holds %+v", bag)
	}
	if err := eq.Equip(ctx, 1, SlotWeapon, bag[0].Index); err != nil {
		t.Fatal(err)
	}
	if err := eq.Unequip(ctx, 1, SlotWeapon); err != nil {
		t.Fatalf("Unequip: %v", err)
	}
	bag, _ = inv.List(ctx, 1)
	for _, sl := range bag {
		if sl.ItemID == 100 && !sl.Instance().Equal(inst) {
			t.Fatalf("after Unequip: %+v", sl)
		}
	}
}

func TestWornInstanceMem(t *testing.T) {
	inv, eq := memPair()
	testWornInstance(t, eq, inv)
}

func TestWornInstanceSQL(t *testing.T) {
	eq, inv := openTestStores(t)
	testWornInstance(t, eq, inv)
}
