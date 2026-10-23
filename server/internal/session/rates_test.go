package session

import (
	"context"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/durability"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// Hit rate and parry take each worn item's OWN value, as the engine
// publishes params 11 and 9 (round 629-632 integration): the weapon's
// HitRateMin..Max by its variance group 3, the body armour's
// ParryRatioMin..Max by group 5 (Char_BuildAggregateStats, READ). A broken
// weapon adds nothing, as combat swings it bare-fisted.
func TestCharacterRatesUseTheInstance(t *testing.T) {
	ctx := context.Background()
	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, []refdata.Item{
		// The Copper Sword's retail pair, 24..30.
		{ID: 100, MaxStack: 1, DurabilityMin: 62, DurabilityMax: 76, PhysAttackMin: 6, PhysAttackMax: 9,
			HitRateMin: 24, HitRateMax: 30,
			TypeID1: equipment.TypeItem, TypeID2: equipment.TypeEquipment, Country: equipment.CountryChina},
		{ID: 200, MaxStack: 1, DurabilityMin: 10, DurabilityMax: 10, ParryRatioMin: 4, ParryRatioMax: 8,
			TypeID1: equipment.TypeItem, TypeID2: equipment.TypeEquipment, Country: equipment.CountryChina},
	}); err != nil {
		t.Fatalf("import: %v", err)
	}
	// group g at 31/31: the top of the range for that stat alone.
	top := func(g int) uint64 { return uint64(durability.GroupMax) << (5 * uint(g)) }
	build := func(weaponVariance uint64, weaponDurability int, mailVariance uint64) (int, int) {
		t.Helper()
		inv := inventory.NewMemStore(items)
		inv.SetDurabilityLookup(items)
		eq := equipment.NewMemStore(inv)
		if err := inv.AddItemInstance(ctx, 1, 100, 1, inventory.Instance{Variance: weaponVariance, Durability: weaponDurability}); err != nil {
			t.Fatalf("add weapon: %v", err)
		}
		if err := eq.Equip(ctx, 1, equipment.SlotWeapon, 0); err != nil {
			t.Fatalf("equip weapon: %v", err)
		}
		if err := inv.AddItemInstance(ctx, 1, 200, 1, inventory.Instance{Variance: mailVariance, Durability: 10}); err != nil {
			t.Fatalf("add mail: %v", err)
		}
		if err := eq.Equip(ctx, 1, equipment.SlotMail, 0); err != nil {
			t.Fatalf("equip mail: %v", err)
		}
		built, err := buildCharacterStats(ctx, &character.Character{ID: 1, Level: 2, HP: 10, Str: 20, Int: 20}, 1, eq, items, nil, nil)
		if err != nil {
			t.Fatalf("buildCharacterStats: %v", err)
		}
		return int(built.HitRate), int(built.ParryRate)
	}
	// Variance 0: the lo ends. 10 + 2 + 24 and 10 + 2 + 4.
	if hit, parry := build(0, 70, 0); hit != 36 || parry != 16 {
		t.Errorf("lo ends: hit/parry %d/%d, want 36/16", hit, parry)
	}
	// The weapon's group 3 and the mail's group 5 at the top: 10+2+30, 10+2+8.
	if hit, parry := build(top(durability.WeaponAttackRateGroup), 70, top(durability.ArmourParryGroup)); hit != 42 || parry != 20 {
		t.Errorf("top of the ranges: hit/parry %d/%d, want 42/20", hit, parry)
	}
	// The OTHER groups at the top move neither: the stat reads its own group.
	if hit, parry := build(top(durability.WeaponPhysDamageGroup), 70, top(durability.ArmourPhysDefenseGroup)); hit != 36 || parry != 16 {
		t.Errorf("other groups: hit/parry %d/%d, want 36/16", hit, parry)
	}
	// A broken weapon adds nothing: 10 + 2.
	if hit, _ := build(top(durability.WeaponAttackRateGroup), durability.Broken, 0); hit != 12 {
		t.Errorf("broken weapon: hit %d, want 12", hit)
	}
}
