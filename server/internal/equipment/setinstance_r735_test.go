package equipment

import (
	"context"
	"errors"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
)

// Round 735: a worn item's instance is rewritten in place (the GM's /item
// worn), and the effective plus follows it.
func testSetWornInstance(t *testing.T, eq Store, inv inventory.Store) {
	t.Helper()
	ctx := context.Background()
	setter, ok := eq.(InstanceSetter)
	if !ok {
		t.Fatal("store is not an InstanceSetter")
	}
	if err := inv.AddItemInstance(ctx, 1, 100, 1, inventory.Instance{Durability: 30, OptLevel: 7}); err != nil {
		t.Fatal(err)
	}
	if err := eq.Equip(ctx, 1, SlotWeapon, 0); err != nil {
		t.Fatal(err)
	}
	worn, _ := eq.Get(ctx, 1)
	inst := worn[0].Instance()
	inst.OptLevel, inst.AdvElixir = 13, 2
	if err := setter.SetInstance(ctx, 1, SlotWeapon, inst); err != nil {
		t.Fatal(err)
	}
	worn, _ = eq.Get(ctx, 1)
	if len(worn) != 1 || worn[0].OptLevel != 13 || worn[0].Durability != 30 || worn[0].EffectivePlus() != 15 {
		t.Fatalf("worn %+v, want +13 with the elixir's 2 (effective 15), durability kept", worn)
	}
	if err := setter.SetInstance(ctx, 1, SlotShield, inst); !errors.Is(err, ErrSlotEmpty) {
		t.Fatalf("an empty slot: %v, want ErrSlotEmpty", err)
	}
}

func TestSetWornInstanceMem(t *testing.T) {
	inv, eq := memPair()
	testSetWornInstance(t, eq, inv)
}

func TestSetWornInstanceSQL(t *testing.T) {
	eq, inv := openTestStores(t)
	testSetWornInstance(t, eq, inv)
}
