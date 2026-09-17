package inventory

import (
	"context"
	"errors"
	"strings"
	"testing"
)

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

// TestRemoveItemRejectsNonPositiveQuantity covers a duplication bug: RemoveItem
// checked only that the quantity did not EXCEED the stack, and every negative
// value passes that test. The removal is `slot.Quantity -= quantity`, so a
// negative amount added items.
//
// The engine guards both ends of the range -- 0x1829
// SPECIFY_POSITIVE_NUMBER_ONLY below, 0x1814 ENABLEINPUT_FEWERTHAN_REMAIN above
// -- and srrevamp was guarding only the upper one.
func TestRemoveItemRejectsNonPositiveQuantity(t *testing.T) {
	ctx := context.Background()
	m := NewMemStore(nil)
	if err := m.AddItem(ctx, 1, 100, 5); err != nil {
		t.Fatalf("AddItem: %v", err)
	}

	for _, q := range []int{0, -1, -1000} {
		if err := m.RemoveItem(ctx, 1, 0, q); !errors.Is(err, ErrInvalidQuantity) {
			t.Errorf("RemoveItem(quantity=%d): got %v, want ErrInvalidQuantity", q, err)
		}
		// The holdings must be untouched. Before the guard, q=-1000 raised the
		// slot's quantity. Summed rather than shape-matched, because a store
		// with no max-stack source splits into slots of one.
		slots, err := m.List(ctx, 1)
		if err != nil {
			t.Fatalf("List: %v", err)
		}
		total := 0
		for _, sl := range slots {
			total += sl.Quantity
		}
		if total != 5 {
			t.Fatalf("after RemoveItem(quantity=%d) the character holds %d, want 5", q, total)
		}
	}

	// A positive removal still works.
	if err := m.RemoveItem(ctx, 1, 0, 1); err != nil {
		t.Errorf("RemoveItem(1): %v", err)
	}
}

// TestAddItemRejectsNonPositiveQuantity is the same guard on the other side. It
// was a silent no-op rather than a duplication, but an operation that reports
// success without doing anything is its own kind of bug.
func TestAddItemRejectsNonPositiveQuantity(t *testing.T) {
	ctx := context.Background()
	m := NewMemStore(nil)
	for _, q := range []int{0, -3} {
		if err := m.AddItem(ctx, 1, 100, q); !errors.Is(err, ErrInvalidQuantity) {
			t.Errorf("AddItem(quantity=%d): got %v, want ErrInvalidQuantity", q, err)
		}
	}
}

// The six codes are the engine's, and each is also the name of an RTTI class in
// the server (with a C prefixed). If a later pass adds a code, it has to come
// from one of those two places.
func TestExpansionQuestCodes(t *testing.T) {
	if len(ExpansionQuestCodes) != 6 {
		t.Errorf("%d expansion quest codes, want 6 (GObjPC::FUN_004e13b0 builds six)",
			len(ExpansionQuestCodes))
	}
	seen := map[string]bool{}
	for _, c := range ExpansionQuestCodes {
		if seen[c] {
			t.Errorf("%s listed twice", c)
		}
		seen[c] = true
		if !strings.HasPrefix(c, "QSP_") || !strings.Contains(c, "_EXINVENTORY_") {
			t.Errorf("%s is not one of the engine's expansion quest codes", c)
		}
	}
	// The cap they unlock, and the one they unlock it from.
	if MaxSlotsDefault != 0x4d || MaxSlotsExpanded != 0x63 {
		t.Errorf("caps are %d and %d, want 0x4d and 0x63 as read at 0x004e196d and 0x004e1974",
			MaxSlotsDefault, MaxSlotsExpanded)
	}
}
