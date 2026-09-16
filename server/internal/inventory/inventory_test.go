package inventory

import "testing"

// TestSlotsPerCharacterFitsTheEngine holds this project's own inventory size to
// the real game's recovered bounds. SlotsPerCharacter is own design, but it is
// not free: CGObjPC::ExpandInventory never lets an inventory reach 100 slots,
// and caps expansion at 99. A later change that exceeds either would put
// srrevamp outside anything the engine can represent, and fails here with the
// citation rather than silently shipping.
func TestSlotsPerCharacterFitsTheEngine(t *testing.T) {
	if SlotsPerCharacter >= SlotsHardLimit {
		t.Errorf("SlotsPerCharacter = %d, but CGObjPC::ExpandInventory requires size < %d",
			SlotsPerCharacter, SlotsHardLimit)
	}
	if SlotsPerCharacter > MaxSlotsExpanded {
		t.Errorf("SlotsPerCharacter = %d, above the engine's largest expanded inventory (%d)",
			SlotsPerCharacter, MaxSlotsExpanded)
	}
	// The two caps are read straight out of the disassembly; a typo in either
	// would quietly widen the bound this test enforces.
	if MaxSlotsDefault != 0x4d {
		t.Errorf("MaxSlotsDefault = %d, want 0x4d = 77 (the `iVar2 = 0x4d` at 004e1910)", MaxSlotsDefault)
	}
	if MaxSlotsExpanded >= SlotsHardLimit {
		t.Errorf("the expanded cap (%d) must stay under the hard limit (%d)", MaxSlotsExpanded, SlotsHardLimit)
	}
	// The three caps are distinct and must not be conflated: 99 inventory,
	// 112 storage, 210 for the unidentified kind-3 container.
	if MaxStorageExpansionSlots != 0xd2 {
		t.Errorf("MaxStorageExpansionSlots = %d, want 0xd2 = 210 (the `cmp ecx,0xd2` at 004e194d)",
			MaxStorageExpansionSlots)
	}
	if MaxStorageSlots == MaxStorageExpansionSlots || MaxStorageSlots == MaxSlotsExpanded {
		t.Error("the three recovered caps are different numbers; collapsing them loses a distinction the engine makes")
	}
	// Storage is a different cap and must not be conflated with inventory.
	if MaxStorageSlots <= SlotsHardLimit {
		t.Errorf("MaxStorageSlots = %d; the slot-174 overload caps at 0x70 = 112, above the inventory limit",
			MaxStorageSlots)
	}
}
