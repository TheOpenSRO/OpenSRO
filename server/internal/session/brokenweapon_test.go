package session

import (
	"context"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
)

// The serviceability half of a skill's cast requirement.
//
// Skill_CheckCastRequirement (0x0058d480) returns 0x300f when vtable slot 372,
// 399 or 400 answers 0, and the client names 0x300f
// UIIT_SKILL_USE_FAIL_BROKEN_WEAPON -- so a cast requirement wants the item
// present AND not broken (docs/protocol/igobj_vtable.md). srrevamp already
// dropped a broken item's STATS and still let the cast through; weaponIsBroken
// is what closes that, and this pins its contract.
//
// COVERAGE BOUNDARY, stated rather than implied: the gate that calls this lives
// inside UseSkillHandler, and every end-to-end test of that handler opens a
// Postgres store. This covers the helper the gate depends on, not the socket
// round trip.
func TestWeaponIsBroken(t *testing.T) {
	ctx := context.Background()
	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, []refdata.Item{
		{ID: 100, MaxStack: 1, DurabilityMin: 62, DurabilityMax: 76,
			TypeID1: equipment.TypeItem, TypeID2: equipment.TypeEquipment,
			Country: equipment.CountryChina},
	}); err != nil {
		t.Fatalf("import: %v", err)
	}
	inv := inventory.NewMemStore(items)
	inv.SetDurabilityLookup(items)
	eq := equipment.NewMemStore(inv)

	// An empty hand is not a broken weapon, and the answer is trustworthy.
	// A skill with no weapon requirement never reaches here, but one that has
	// a requirement and an empty hand must not be refused for BREAKAGE -- the
	// type check is what refuses that, with its own message.
	broken, known := weaponIsBroken(ctx, 1, eq)
	if !known || broken {
		t.Errorf("empty hand: got broken=%v known=%v, want false/true", broken, known)
	}

	if err := inv.AddItem(ctx, 1, 100, 1); err != nil {
		t.Fatalf("add: %v", err)
	}
	if err := eq.Equip(ctx, 1, equipment.SlotWeapon, 0); err != nil {
		t.Fatalf("equip: %v", err)
	}

	if broken, known = weaponIsBroken(ctx, 1, eq); !known || broken {
		t.Errorf("whole weapon: got broken=%v known=%v, want false/true", broken, known)
	}

	// Zero is the engine's break point: durability.IsBroken is `== 0`, the
	// same condition that strips the item's stats.
	if err := eq.SetDurability(ctx, 1, equipment.SlotWeapon, 0); err != nil {
		t.Fatalf("break: %v", err)
	}
	if broken, known = weaponIsBroken(ctx, 1, eq); !known || !broken {
		t.Errorf("broken weapon: got broken=%v known=%v, want true/true", broken, known)
	}

	// Repaired to any positive value and the cast is allowed again -- a point
	// of durability is enough, because the condition is equality with zero and
	// not a threshold.
	if err := eq.SetDurability(ctx, 1, equipment.SlotWeapon, 1); err != nil {
		t.Fatalf("repair: %v", err)
	}
	if broken, known = weaponIsBroken(ctx, 1, eq); !known || broken {
		t.Errorf("repaired to 1: got broken=%v known=%v, want false/true", broken, known)
	}
}
