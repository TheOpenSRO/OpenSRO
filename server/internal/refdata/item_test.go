package refdata

import "testing"

// ContainerExpansion is CGItemExpendable::UseByKind (0x0049c2b0) case 0x11
// read as a predicate (round 498): the kind is 3/3/13/17, the amount Param1's
// low byte (column 118, RestoreHP), the container Param2 (column 120,
// RestoreHPPct) -- 0 the bag, 1 the warehouse, anything else refused. The two
// expansion rows' kinds and Param blocks are the real ones (24365: 32 / 0,
// 24366: 30 / 1); the rest are illustrative.
func TestContainerExpansion(t *testing.T) {
	for _, tc := range []struct {
		name          string
		it            Item
		wantContainer int
		wantSlots     int
		wantOK        bool
	}{
		{"ITEM_MALL_WAREHOUSE_ADDITION (30 / 1)",
			Item{TypeID1: 3, TypeID2: 3, TypeID3: 13, TypeID4: 17, RestoreHP: 30, RestoreHPPct: 1},
			ExpansionContainerWarehouse, 30, true},
		{"ITEM_MALL_INVENTORY_ADDITION (32 / 0)",
			Item{TypeID1: 3, TypeID2: 3, TypeID3: 13, TypeID4: 17, RestoreHP: 32, RestoreHPPct: 0},
			ExpansionContainerBag, 32, true},
		// The amount is a byte (0x4e1943 movzx): 286 is 0x11e, so 30.
		{"Param1 taken as a byte",
			Item{TypeID1: 3, TypeID2: 3, TypeID3: 13, TypeID4: 17, RestoreHP: 286, RestoreHPPct: 1},
			ExpansionContainerWarehouse, 30, true},
		// UseByKind answers 3 for a Param2 other than 0 or 1.
		{"Param2 2 names no container",
			Item{TypeID1: 3, TypeID2: 3, TypeID3: 13, TypeID4: 17, RestoreHP: 30, RestoreHPPct: 2},
			0, 0, false},
		{"zero amount",
			Item{TypeID1: 3, TypeID2: 3, TypeID3: 13, TypeID4: 17, RestoreHP: 0, RestoreHPPct: 1},
			0, 0, false},
		// HP_POTION_01's kind: its Param block is a restore amount, not a size.
		{"a potion 3/3/1/1",
			Item{TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 1, RestoreHP: 120},
			0, 0, false},
		// The resurrection scroll: UseByKind case 6, not 0x11.
		{"3/3/13/6",
			Item{TypeID1: 3, TypeID2: 3, TypeID3: 13, TypeID4: 6, RestoreHP: 30, RestoreHPPct: 1},
			0, 0, false},
		// DoJob reaches UseByKind only under TypeID3 13.
		{"3/3/1/17",
			Item{TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 17, RestoreHP: 30, RestoreHPPct: 1},
			0, 0, false},
	} {
		container, slots, ok := tc.it.ContainerExpansion()
		if container != tc.wantContainer || slots != tc.wantSlots || ok != tc.wantOK {
			t.Errorf("%s: ContainerExpansion = (%d, %d, %v), want (%d, %d, %v)",
				tc.name, container, slots, ok, tc.wantContainer, tc.wantSlots, tc.wantOK)
		}
	}
}
