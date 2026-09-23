package session

import (
	"context"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/durability"
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

// A broken item satisfies NO entry of a skill's 'reqi' list, and the refusal is
// the ordinary "wrong equipment" (0x300d), not "broken weapon" (0x300f).
//
// Skill_CheckCastRequirement (0x0058d480) reads each slot's type through a
// getter -- the shield's at 58d4c9 (0x004ead80), the weapon's at 58d4d4
// (Equip_GetWeaponTID 0x004ead40) -- and both write TID 0 when the item's
// +0x190 broken flag is set (4eada3 / 4ead63 `cmp [eax+0x190],0 ; jne`). A
// broken staff is therefore an empty weapon slot to the list walk. The handler
// feeds equippedTypes into combat.SkillAllowsEquipment, so the pair is the
// gate; this pins the pair.
func TestReqiBrokenWeaponSatisfiesNothing(t *testing.T) {
	// kind 6 is the weapon category, kind 4 the shield, and (4, 1) is the
	// buckler record -- combat.CastRequirement's measured record shapes.
	const shield = 4
	staffReq := combat.CastRequirement{Kind: combat.WeaponTypeIDCategory, Value: combat.WeaponEUStaff}
	bucklerReq := combat.CastRequirement{Kind: shield, Value: 1}

	ctx := context.Background()
	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, []refdata.Item{
		{ID: 200, MaxStack: 1, DurabilityMin: 40, DurabilityMax: 50,
			TypeID1: equipment.TypeItem, TypeID2: equipment.TypeEquipment,
			TypeID3: combat.WeaponTypeIDCategory, TypeID4: combat.WeaponEUStaff},
		{ID: 201, MaxStack: 1, DurabilityMin: 40, DurabilityMax: 50,
			TypeID1: equipment.TypeItem, TypeID2: equipment.TypeEquipment,
			TypeID3: shield, TypeID4: 1},
	}); err != nil {
		t.Fatalf("import: %v", err)
	}
	inv := inventory.NewMemStore(items)
	inv.SetDurabilityLookup(items)
	eq := equipment.NewMemStore(inv)

	wear := func(char int64, itemID int64, slot equipment.Slot) {
		t.Helper()
		if err := inv.AddItem(ctx, char, itemID, 1); err != nil {
			t.Fatalf("add %d: %v", itemID, err)
		}
		bag, err := inv.List(ctx, char)
		if err != nil || len(bag) == 0 {
			t.Fatalf("list: %v (%d slots)", err, len(bag))
		}
		if err := eq.Equip(ctx, char, slot, bag[len(bag)-1].Index); err != nil {
			t.Fatalf("equip %d: %v", itemID, err)
		}
	}
	setDur := func(char int64, slot equipment.Slot, d int) {
		t.Helper()
		if err := eq.SetDurability(ctx, char, slot, d); err != nil {
			t.Fatalf("durability %d: %v", d, err)
		}
	}
	allows := func(char int64, reqs []combat.CastRequirement, all bool) bool {
		t.Helper()
		worn, known := equippedTypes(ctx, char, eq, items)
		if !known {
			t.Fatalf("char %d: equippedTypes answered unknown", char)
		}
		return combat.SkillAllowsEquipment(reqs, all, worn)
	}

	// A staff skill with the staff broken: refused, as with no staff at all.
	wear(1, 200, equipment.SlotWeapon)
	setDur(1, equipment.SlotWeapon, durability.Broken)
	if allows(1, []combat.CastRequirement{staffReq}, false) {
		t.Error("broken staff on a staff skill: allowed, want refused (the getter reads TID 0)")
	}
	// One point is enough (the flag is durability < 1), and an untracked item
	// is not broken.
	setDur(1, equipment.SlotWeapon, 1)
	if !allows(1, []combat.CastRequirement{staffReq}, false) {
		t.Error("staff at durability 1: refused, want allowed")
	}
	setDur(1, equipment.SlotWeapon, durability.Untracked)
	if !allows(1, []combat.CastRequirement{staffReq}, false) {
		t.Error("staff with untracked durability: refused, want allowed")
	}

	// The shield getter is the same shape.
	wear(2, 201, equipment.SlotShield)
	setDur(2, equipment.SlotShield, durability.Broken)
	if allows(2, []combat.CastRequirement{bucklerReq}, false) {
		t.Error("broken buckler on a buckler skill: allowed, want refused")
	}
	setDur(2, equipment.SlotShield, 5)
	if !allows(2, []combat.CastRequirement{bucklerReq}, false) {
		t.Error("buckler at durability 5: refused, want allowed")
	}

	// ANY-of: the whole staff is enough even with the buckler broken. ALL-of
	// ('reqn') fails on the broken buckler, because it is an empty slot.
	wear(3, 200, equipment.SlotWeapon)
	wear(3, 201, equipment.SlotShield)
	setDur(3, equipment.SlotWeapon, 30)
	setDur(3, equipment.SlotShield, durability.Broken)
	both := []combat.CastRequirement{staffReq, bucklerReq}
	if !allows(3, both, false) {
		t.Error("any-of staff/buckler with a whole staff and a broken buckler: refused, want allowed")
	}
	if allows(3, both, true) {
		t.Error("all-of staff/buckler with a broken buckler: allowed, want refused")
	}
}
