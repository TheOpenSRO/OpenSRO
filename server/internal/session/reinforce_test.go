package session

import (
	"context"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
)

// TestAttackerDamageIncludesStrength pins the Strength term at the point it
// actually matters: the number a blow is rolled from.
//
// Strength reaching damage at all is a RECOVERED formula change, not a tuning
// choice. GObjPC_InitStats binds param 1 (Strength) into param 17 at slot 0 and
// param 34 (the weapon's physical reinforce) into param 17 at slot 3, then
// param 17 into param 13 at slot 0 -- and param 13's slot 0 SUMS its entries
// rather than one overwriting the other, because the weapon's own minimum and
// the derived term are stored under different ctx keys. FUN_0040db50, the
// helper the attack roll calls for each bound, reads exactly param 13/14.
//
// The weapon here has a degenerate range (min == max) on both the attack and
// the reinforce columns, so the roll is deterministic and the assertion is
// about the term rather than about the randomness.
//
// This test FAILS without the wiring in attackerDamage: it would report 15
// for both characters.
func TestAttackerDamageIncludesStrength(t *testing.T) {
	ctx := context.Background()
	refItems := refdata.NewMemStore()

	const weaponID = 4242
	if err := refItems.ImportItems(ctx, []refdata.Item{{
		ID: weaponID,
		// A weapon shaped like the real Copper Sword's columns, with the
		// ranges collapsed so the roll is exact.
		PhysAttackMin: 15, PhysAttackMax: 15,
		ReinforcePhysMin: 306, ReinforcePhysMax: 306,
		TypeID1: 3, TypeID2: 1, TypeID3: 6, TypeID4: 2,
	}}); err != nil {
		t.Fatalf("ImportItems: %v", err)
	}

	equip := func(characterID int64) equipment.Store {
		inv := inventory.NewMemStore(refItems)
		eq := equipment.NewMemStore(inv)
		if err := inv.AddItem(ctx, characterID, weaponID, 1); err != nil {
			t.Fatalf("AddItem: %v", err)
		}
		slots, err := inv.List(ctx, characterID)
		if err != nil {
			t.Fatalf("List: %v", err)
		}
		if err := eq.Equip(ctx, characterID, equipment.SlotWeapon, slots[0].Index); err != nil {
			t.Fatalf("Equip: %v", err)
		}
		return eq
	}

	// 20 Strength adds 20 * 30.6% = 6.12, which rounds to 6.
	const wantWithoutStr = 15
	const wantWithStr = 15 + 6

	got, err := attackerDamage(ctx, 1, 0, equip(1), refItems)
	if err != nil {
		t.Fatalf("attackerDamage with no Strength: %v", err)
	}
	if got != wantWithoutStr {
		t.Errorf("damage with 0 Str = %d, want %d (the weapon alone)", got, wantWithoutStr)
	}

	got, err = attackerDamage(ctx, 2, 20, equip(2), refItems)
	if err != nil {
		t.Fatalf("attackerDamage with Strength: %v", err)
	}
	if got != wantWithStr {
		t.Errorf("damage with 20 Str = %d, want %d (weapon %d + Str*reinforce 6)",
			got, wantWithStr, wantWithoutStr)
	}
}

// TestAttackerDamageWithoutReinforceColumns is the compatibility half: an
// export made before the reinforce columns existed leaves them zero, and a
// character's damage must be exactly what it was -- the weapon's range alone,
// no matter how much Strength it has.
func TestAttackerDamageWithoutReinforceColumns(t *testing.T) {
	ctx := context.Background()
	refItems := refdata.NewMemStore()

	const weaponID = 4243
	if err := refItems.ImportItems(ctx, []refdata.Item{{
		ID:            weaponID,
		PhysAttackMin: 15, PhysAttackMax: 15,
		TypeID1: 3, TypeID2: 1, TypeID3: 6, TypeID4: 2,
	}}); err != nil {
		t.Fatalf("ImportItems: %v", err)
	}

	inv := inventory.NewMemStore(refItems)
	eq := equipment.NewMemStore(inv)
	if err := inv.AddItem(ctx, 1, weaponID, 1); err != nil {
		t.Fatalf("AddItem: %v", err)
	}
	slots, _ := inv.List(ctx, 1)
	if err := eq.Equip(ctx, 1, equipment.SlotWeapon, slots[0].Index); err != nil {
		t.Fatalf("Equip: %v", err)
	}

	got, err := attackerDamage(ctx, 1, 200, eq, refItems)
	if err != nil {
		t.Fatalf("attackerDamage: %v", err)
	}
	if got != 15 {
		t.Errorf("damage = %d with no reinforce columns, want 15 -- an older export must not change", got)
	}
}
