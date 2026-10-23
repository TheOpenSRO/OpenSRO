package session

import (
	"context"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// A worn weapon deals its own damage until it breaks; at 0 durability it
// deals the unarmed damage, and comes back when repaired.
func TestBrokenWeaponDealsUnarmed(t *testing.T) {
	ctx := context.Background()
	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, []refdata.Item{
		{ID: 100, MaxStack: 1, DurabilityMin: 62, DurabilityMax: 76, RepairCost: 198,
			PhysAttackMin: 40, PhysAttackMax: 50,
			TypeID1: equipment.TypeItem, TypeID2: equipment.TypeEquipment, Country: equipment.CountryChina},
	}); err != nil {
		t.Fatalf("import: %v", err)
	}
	inv := inventory.NewMemStore(items)
	inv.SetDurabilityLookup(items)
	eq := equipment.NewMemStore(inv)
	if err := inv.AddItem(ctx, 1, 100, 1); err != nil {
		t.Fatalf("add: %v", err)
	}
	if err := eq.Equip(ctx, 1, equipment.SlotWeapon, 0); err != nil {
		t.Fatalf("equip: %v", err)
	}

	// Whole: at least the weapon's floor (40 + reinforce), well above unarmed.
	dmg, err := attackerDamageOf(ctx, 1, 20, 0, eq, items, combat.AttackPhysical, 0, 0, 0)
	if err != nil {
		t.Fatalf("attackerDamageOf: %v", err)
	}
	if dmg <= unarmedDamage {
		t.Fatalf("a whole weapon should beat unarmed(%d), got %d", unarmedDamage, dmg)
	}

	// Broken: exactly unarmed.
	if err := eq.SetDurability(ctx, 1, equipment.SlotWeapon, 0); err != nil {
		t.Fatalf("break: %v", err)
	}
	dmg, err = attackerDamageOf(ctx, 1, 20, 0, eq, items, combat.AttackPhysical, 0, 0, 0)
	if err != nil {
		t.Fatalf("attackerDamageOf broken: %v", err)
	}
	if dmg != unarmedDamage {
		t.Errorf("a broken weapon should deal unarmed(%d), got %d", unarmedDamage, dmg)
	}

	// Repaired to any positive value: it hits for real again.
	if err := eq.SetDurability(ctx, 1, equipment.SlotWeapon, 76); err != nil {
		t.Fatalf("repair: %v", err)
	}
	dmg, _ = attackerDamageOf(ctx, 1, 20, 0, eq, items, combat.AttackPhysical, 0, 0, 0)
	if dmg <= unarmedDamage {
		t.Errorf("a repaired weapon should beat unarmed again, got %d", dmg)
	}
}

// wearWeapon takes exactly one point off, and wearOneSlot reports the break.
func TestWearWeaponLosesOnePoint(t *testing.T) {
	ctx := context.Background()
	items := refdata.NewMemStore()
	items.ImportItems(ctx, []refdata.Item{
		{ID: 100, MaxStack: 1, DurabilityMin: 62, DurabilityMax: 76,
			TypeID1: equipment.TypeItem, TypeID2: equipment.TypeEquipment},
	})
	inv := inventory.NewMemStore(items)
	inv.SetDurabilityLookup(items)
	eq := equipment.NewMemStore(inv)
	inv.AddItem(ctx, 1, 100, 1)
	eq.Equip(ctx, 1, equipment.SlotWeapon, 0)
	eq.SetDurability(ctx, 1, equipment.SlotWeapon, 2)

	// Force the roll to succeed regardless of chance.
	orig := wearRand
	wearRand = alwaysHitRand{}
	defer func() { wearRand = orig }()

	wearWeapon(ctx, eq, 1, 1)
	if d := wornDurability(ctx, t, eq, equipment.SlotWeapon); d != 1 {
		t.Errorf("after one wear: %d, want 1", d)
	}
	broke := wearOneSlot(ctx, eq, 1, equipment.SlotWeapon)
	if !broke {
		t.Error("the last point should report broke=true")
	}
	if d := wornDurability(ctx, t, eq, equipment.SlotWeapon); d != 0 {
		t.Errorf("after breaking: %d, want 0", d)
	}
	// A broken item refuses to go below 0.
	if wearOneSlot(ctx, eq, 1, equipment.SlotWeapon) {
		t.Error("a broken item cannot break again")
	}
}

func wornDurability(ctx context.Context, t *testing.T, eq equipment.Store, slot equipment.Slot) int {
	t.Helper()
	worn, err := eq.Get(ctx, 1)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	for _, e := range worn {
		if e.Slot == slot {
			return e.Durability
		}
	}
	t.Fatalf("slot %d not worn", slot)
	return -1
}

type alwaysHitRand struct{}

func (alwaysHitRand) Intn(n int) int { return 0 } // rand()%100+1 = 1 <= any chance
