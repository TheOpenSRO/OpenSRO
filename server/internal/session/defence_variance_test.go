package session

import (
	"context"
	"math"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/durability"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
)

// fixedEquipment is an equipment.Store that answers Get with a fixed set of
// worn instances, so a defence sum can be checked against exact variances
// without a random roll in the way.
type fixedEquipment struct {
	worn []equipment.Equipped
}

func (f fixedEquipment) Get(context.Context, int64) ([]equipment.Equipped, error) { return f.worn, nil }
func (f fixedEquipment) Equip(context.Context, int64, equipment.Slot, int) error {
	return nil
}
func (f fixedEquipment) Unequip(context.Context, int64, equipment.Slot) error { return nil }
func (f fixedEquipment) SetDurability(context.Context, int64, equipment.Slot, int) error {
	return nil
}

// TestDefenceReadsTheInstanceVariance pins the rule Char_BuildAggregateStats
// (0x00495d60) applies to a worn piece: PD_L + q*(PD_U-PD_L) with q the
// instance's group-3 factor for physical defence and group 4 for magical --
// not the top of the range, which is what this server summed before the
// variance existed. An Untracked row (no instance) still counts at the top.
func TestDefenceReadsTheInstanceVariance(t *testing.T) {
	ctx := context.Background()
	items := stubCombatItems{
		200: {ID: 200, PhysDefenseMin: 10, PhysDefenseMax: 20, MagDefenseMin: 4, MagDefenseMax: 8, DurabilityMin: 50, DurabilityMax: 60},
		201: {ID: 201, PhysDefenseMin: 30, PhysDefenseMax: 40, MagDefenseMin: 0, MagDefenseMax: 2, DurabilityMin: 50, DurabilityMax: 60},
		202: {ID: 202, PhysDefenseMin: 5, PhysDefenseMax: 9, MagDefenseMax: 3},
	}
	full := func(group int) uint64 { return uint64(31) << (5 * uint(group)) }
	half := func(group int) uint64 { return uint64(16) << (5 * uint(group)) }
	eq := fixedEquipment{worn: []equipment.Equipped{
		// Helm: full physical group, empty magical group -> 20 / 4.
		{Slot: equipment.SlotHelm, ItemID: 200, Variance: full(durability.ArmourPhysDefenseGroup), Durability: 55},
		// Mail: group 16/31 on both -> 30 + 16/31*10 and 0 + 16/31*2.
		{Slot: equipment.SlotMail, ItemID: 201, Variance: half(durability.ArmourPhysDefenseGroup) | half(durability.ArmourMagDefenseGroup), Durability: 55},
		// Boots: never got an instance (Untracked) -> the top of the range, 9 / 3.
		{Slot: equipment.SlotBoots, ItemID: 202, Variance: 0, Durability: durability.Untracked},
		// A weapon is not armour and contributes nothing here.
		{Slot: equipment.SlotWeapon, ItemID: 200, Variance: full(durability.ArmourPhysDefenseGroup), Durability: 55},
	}}

	phys, err := defenderArmor(ctx, 1, eq, items)
	if err != nil {
		t.Fatalf("defenderArmor: %v", err)
	}
	wantPhys := int(math.Round(20 + (30 + 16.0/31*10) + 9))
	if phys != wantPhys {
		t.Errorf("physical defence: got %d, want %d", phys, wantPhys)
	}

	mag, err := defenderMagicArmor(ctx, 1, eq, items)
	if err != nil {
		t.Fatalf("defenderMagicArmor: %v", err)
	}
	wantMag := int(math.Round(4 + (0 + 16.0/31*2) + 3))
	if mag != wantMag {
		t.Errorf("magic defence: got %d, want %d", mag, wantMag)
	}

	// A broken piece defends for nothing, variance or not.
	eq.worn[0].Durability = durability.Broken
	phys, err = defenderArmor(ctx, 1, eq, items)
	if err != nil {
		t.Fatalf("defenderArmor (broken helm): %v", err)
	}
	if phys != wantPhys-20 {
		t.Errorf("broken helm still defended: got %d, want %d", phys, wantPhys-20)
	}
}

// The old behaviour is gone on purpose: a fresh-rolled instance sits well
// below the top of its range almost always (the roll is the minimum of three
// draws), so a character's defence must not be the sum of maxima any more.
func TestDefenceIsNotTheSumOfMaxima(t *testing.T) {
	ctx := context.Background()
	items := stubCombatItems{200: {ID: 200, PhysDefenseMin: 10, PhysDefenseMax: 20, DurabilityMin: 50, DurabilityMax: 60}}
	eq := fixedEquipment{worn: []equipment.Equipped{{Slot: equipment.SlotHelm, ItemID: 200, Variance: 0, Durability: 50}}}
	phys, err := defenderArmor(ctx, 1, eq, items)
	if err != nil {
		t.Fatal(err)
	}
	if phys != 10 {
		t.Errorf("an empty variance group must give the bottom of the range: got %d, want 10", phys)
	}
	_ = refdata.ErrItemNotFound
}
