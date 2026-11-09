package session

import (
	"context"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/durability"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/statuseffect"
)

// Round 875: a body armour piece's Strength / Intellect reinforce (PDStr /
// MDInt, tenths of a percent) adds Str x sum/1000 to physical defence and
// Int x sum/1000 to magical, and an empty body slot keeps its naked default
// (armourReinforce). The numbers are MEASURED on the character window of a
// level-110 character; the item ids are synthetic.

// perfect is a variance with every 5-bit group at 31 (a "perfect" white roll).
const perfect = uint64(0x0FFFFFFFFFFFFFFF)

// set875 is six synthetic +12 body pieces carrying a full European 11th-degree
// set's ranges (PD/MD low-high, per-plus increments, PDStr/MDInt), heavy or
// cloth, keyed by the slot they are worn in.
func set875(cloth bool) (stubCombatItems, []equipment.Equipped) {
	type row struct {
		slot                           equipment.Slot
		pdl, pdu, pinc, mdl, mdu, minc float64
		pstr, mint                     float64
	}
	heavy := []row{
		{equipment.SlotHelm, 237.7, 251.7, 7.1, 311.1, 329.5, 9.3, 380, 497},
		{equipment.SlotShoulderGuard, 190.2, 201.4, 5.7, 249.0, 263.7, 7.4, 306, 401},
		{equipment.SlotMail, 316.5, 335.1, 9.4, 414.4, 438.7, 12.3, 501, 656},
		{equipment.SlotGauntlet, 176.6, 187.0, 5.3, 231.2, 244.9, 6.9, 285, 372},
		{equipment.SlotPants, 259.0, 274.2, 7.7, 339.0, 358.9, 10.1, 410, 537},
		{equipment.SlotBoots, 223.7, 236.9, 6.7, 292.9, 310.1, 8.7, 357, 468},
	}
	robe := []row{
		{equipment.SlotHelm, 194.5, 205.9, 5.8, 380.3, 402.7, 11.3, 311, 662},
		{equipment.SlotShoulderGuard, 155.6, 164.8, 4.7, 304.3, 322.3, 9.1, 251, 535},
		{equipment.SlotMail, 259.0, 274.2, 7.7, 506.4, 536.1, 15.0, 410, 874},
		{equipment.SlotGauntlet, 144.5, 153.0, 4.3, 282.6, 299.3, 8.4, 233, 497},
		{equipment.SlotPants, 211.9, 224.3, 6.3, 414.4, 438.7, 12.3, 335, 715},
		{equipment.SlotBoots, 183.0, 193.8, 5.4, 357.9, 379.0, 10.7, 292, 623},
	}
	rows := heavy
	if cloth {
		rows = robe
	}
	items := stubCombatItems{}
	var worn []equipment.Equipped
	for i, r := range rows {
		id := int64(87500 + i)
		items[id] = &refdata.Item{ID: id, DurabilityMin: 66, DurabilityMax: 99,
			PhysDefenseMin: r.pdl, PhysDefenseMax: r.pdu, PlusIncPhysDef: r.pinc,
			MagDefenseMin: r.mdl, MagDefenseMax: r.mdu, PlusIncMagDef: r.minc,
			PDStrMin: r.pstr - 30, PDStrMax: r.pstr, MDIntMin: r.mint - 60, MDIntMax: r.mint}
		worn = append(worn, equipment.Equipped{Slot: r.slot, ItemID: id, Variance: perfect, Durability: 80, OptLevel: 12})
	}
	return items, worn
}

func TestArmourReinforceMatchesTheMeasuredPanel(t *testing.T) {
	ctx := context.Background()
	for _, tc := range []struct {
		name             string
		cloth            bool
		str, intel       int
		wantPhy, wantMag int
	}{
		// MEASURED: heavy, Str 533 / Int 206 -> 3182 / 3205 (1989.1 +
		// 533 x 2.239 = 3182.49; 2602.2 + 206 x 2.931 = 3205.99, truncated).
		{"heavy", false, 533, 206, 3182, 3205},
		// MEASURED: cloth (its requirement met), the same Str / Int -> 2602 / 3984.
		{"cloth", true, 533, 206, 2602, 3984},
	} {
		items, worn := set875(tc.cloth)
		eq := fixedEquipment{worn: worn}
		phy, err := defenderArmor(ctx, 1, tc.str, eq, items)
		if err != nil {
			t.Fatal(err)
		}
		mag, err := defenderMagicArmor(ctx, 1, tc.intel, eq, items)
		if err != nil {
			t.Fatal(err)
		}
		if phy != tc.wantPhy || mag != tc.wantMag {
			t.Errorf("%s: phy %d mag %d, want %d / %d", tc.name, phy, mag, tc.wantPhy, tc.wantMag)
		}
	}
}

// With nothing that counts worn on the body, each slot keeps its naked scale:
// MEASURED phy def 93 at Str 491 (x 0.190) and mag def 50 at Int 164 (x 0.305).
func TestNakedReinforce(t *testing.T) {
	ctx := context.Background()
	eq := fixedEquipment{}
	phy, _ := defenderArmor(ctx, 1, 491, eq, stubCombatItems{})
	mag, _ := defenderMagicArmor(ctx, 1, 164, eq, stubCombatItems{})
	if phy != 93 || mag != 50 {
		t.Errorf("naked: phy %d mag %d, want 93 / 50", phy, mag)
	}
	// A broken piece publishes nothing: its slot falls back to the default.
	items, worn := set875(false)
	for i := range worn {
		worn[i].Durability = durability.Broken
	}
	phy, _ = defenderArmor(ctx, 1, 491, fixedEquipment{worn: worn}, items)
	if phy != 93 {
		t.Errorf("all broken: phy %d, want the naked 93", phy)
	}
}

// A decay ('cspd') takes value[3] off the physical defence, never below 0;
// weakness ('csmd') the same off the magical (READ, statusRuntime.cursedDefence).
func TestDecayCutsPhysicalDefence(t *testing.T) {
	ctx := context.Background()
	items, worn := set875(false)
	eq := fixedEquipment{worn: worn}
	const id = 875001
	h := &statuseffect.Holder{}
	h.Put(statuseffect.Record{Code: "cspd", Slot: statuseffect.SlotDecay, Bit: 17, DurationMs: 30000, CurseCut: 2000})
	statusFX.mu.Lock()
	statusFX.pcs[id] = h
	statusFX.mu.Unlock()
	defer func() {
		statusFX.mu.Lock()
		delete(statusFX.pcs, id)
		statusFX.mu.Unlock()
	}()
	phy, _ := defenderArmor(ctx, id, 533, eq, items)
	if phy != 1182 {
		t.Errorf("decayed phy def %d, want 3182 - 2000", phy)
	}
	mag, _ := defenderMagicArmor(ctx, id, 206, eq, items)
	if mag != 3205 {
		t.Errorf("a decay touched magic defence: %d", mag)
	}
	h.Put(statuseffect.Record{Code: "cspd", Slot: statuseffect.SlotDecay, Bit: 17, DurationMs: 30000, CurseCut: 9000})
	if phy, _ := defenderArmor(ctx, id, 533, eq, items); phy != 0 {
		t.Errorf("a decay larger than the defence left %d, want 0", phy)
	}
}
