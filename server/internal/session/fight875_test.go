package session

import (
	"context"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// Round 875: the whole defender side of a level-101..110 monster's blow on a
// +12 Seal of Nova wearer, end to end through the server's own helpers, against
// numbers MEASURED on the character window and in the blows a level-104
// monster landed. Synthetic ids; the ranges are those of a European
// 11th-degree set and its accessories.

// accessories875 are +12 perfect 11th-degree accessories: earring, necklace,
// two rings (absorption low/high and per-plus increment).
func accessories875(items stubCombatItems) []equipment.Equipped {
	rows := []struct {
		slot        equipment.Slot
		lo, hi, inc float64
	}{
		{equipment.SlotEarring, 26.5, 27.0, 0.25},
		{equipment.SlotNecklace, 31.0, 31.6, 0.29},
		{equipment.SlotRingLeft, 24.1, 24.6, 0.23},
		{equipment.SlotRingRight, 24.1, 24.6, 0.23},
	}
	var worn []equipment.Equipped
	for i, r := range rows {
		id := int64(87600 + i)
		items[id] = &refdata.Item{ID: id, PhysAbsorbMin: r.lo, PhysAbsorbMax: r.hi, PlusIncPhysAbsorb: r.inc,
			MagAbsorbMin: r.lo, MagAbsorbMax: r.hi, PlusIncMagAbsorb: r.inc}
		worn = append(worn, equipment.Equipped{Slot: r.slot, ItemID: id, Variance: perfect, Durability: -1, OptLevel: 12})
	}
	return worn
}

func TestFight875DefenderSide(t *testing.T) {
	ctx := context.Background()
	items, worn := set875(false)
	worn = append(worn, accessories875(items)...)
	eq := fixedEquipment{worn: worn}
	pct := playerMitigationPercent(ctx, 1, eq, items, false)
	// 27.0 + 31.6 + 24.6 x 2 = 107.8, + 12 x (0.25 + 0.29 + 0.23 x 2) = 12.0.
	if pct < 119.79 || pct > 119.81 {
		t.Fatalf("accessory absorption %.3f %%, want 119.8", pct)
	}
	phy, _ := defenderArmor(ctx, 1, 533, eq, items)
	if phy != 3182 {
		t.Fatalf("phy def %d, want the measured 3182", phy)
	}
	// A level-104 monster's physical 152 % skill of 6969..8038 at the top
	// of its range: (8038 / 2.198 - 3182.49) x 1.52 = 721.6 -- MEASURED hits
	// on this defender ran 572..688 (the centre-biased roll keeps most blows
	// low). The engine carries the defence unrounded; this carries 3182.
	b := combat.ResolveSkillBlow(8038, 152, pct, float64(phy), 0, 0, 104, 110, nil, nil)
	if b.Damage < 700 || b.Damage > 723 {
		t.Errorf("the top 152 %% blow %d, want about 722", b.Damage)
	}
}
