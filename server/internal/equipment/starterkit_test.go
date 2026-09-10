package equipment

import (
	"context"
	"errors"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/character"
)

// fakeStores stands in for the inventory and equipment stores. Small enough
// to read, and it keeps this test off a database: what is under test is the
// kit's own logic -- that every wearable slot ends up worn, out of items the
// character actually owns -- not SQL.
type fakeStores struct {
	bag  []int64 // inventory slots, in order
	worn map[Slot]int64
	// failEquipOn makes the given slot's Equip fail, for the partial case.
	failEquipOn Slot
	failEnabled bool
}

func newFakeStores() *fakeStores {
	return &fakeStores{worn: map[Slot]int64{}}
}

func (f *fakeStores) AddItem(_ context.Context, _, itemID int64, quantity int) error {
	for i := 0; i < quantity; i++ {
		f.bag = append(f.bag, itemID)
	}
	return nil
}

func (f *fakeStores) Get(_ context.Context, _ int64) ([]Equipped, error) {
	out := make([]Equipped, 0, len(f.worn))
	for slot, itemID := range f.worn {
		out = append(out, Equipped{Slot: slot, ItemID: itemID})
	}
	return out, nil
}

func (f *fakeStores) Equip(_ context.Context, _ int64, slot Slot, inventorySlot int) error {
	if f.failEnabled && slot == f.failEquipOn {
		return errors.New("equip refused")
	}
	if inventorySlot < 0 || inventorySlot >= len(f.bag) {
		return errors.New("inventory slot empty")
	}
	f.worn[slot] = f.bag[inventorySlot]
	f.bag = append(f.bag[:inventorySlot], f.bag[inventorySlot+1:]...)
	return nil
}

func (f *fakeStores) Unequip(_ context.Context, _ int64, _ Slot) error { return nil }

// TestGiveStartingKitDressesEveryWearableSlot is the point of the kit: the
// client renders a character bare when the server reports nothing equipped,
// and the fix has to be that the character genuinely owns and wears the
// items -- not that the client draws a default set over an empty server.
func TestGiveStartingKitDressesEveryWearableSlot(t *testing.T) {
	for _, gender := range []string{character.GenderChinaMan, character.GenderChinaWoman} {
		f := newFakeStores()
		if err := GiveStartingKit(context.Background(), f, f, 7, gender); err != nil {
			t.Fatalf("GiveStartingKit(%s): %v", gender, err)
		}
		kit := StartingKitFor(gender)
		if len(f.worn) != len(kit) {
			t.Fatalf("%s: equipped %d slot(s), want %d", gender, len(f.worn), len(kit))
		}
		for slot, want := range kit {
			itemID, ok := f.worn[slot]
			if !ok {
				t.Errorf("%s: slot %v was left empty", gender, slot)
				continue
			}
			if itemID != want {
				t.Errorf("%s: slot %v holds item %d, want %d", gender, slot, itemID, want)
			}
		}
		// The game's defaults: a suit, trousers, shoes and a weapon, and
		// nothing on the head, shoulders or forearms.
		for _, slot := range []Slot{SlotMail, SlotPants, SlotBoots, SlotWeapon} {
			if _, ok := kit[slot]; !ok {
				t.Errorf("%s: no starting item for slot %v", gender, slot)
			}
		}
		for _, slot := range []Slot{SlotHelm, SlotShoulderGuard, SlotGauntlet, SlotShield} {
			if _, ok := kit[slot]; ok {
				t.Errorf("%s: the game starts nobody with something in slot %v", gender, slot)
			}
		}
		// Everything added was equipped, so nothing is left loose in the
		// bag. A kit that dressed the character *and* left copies in the
		// inventory would be a duplication bug.
		if len(f.bag) != 0 {
			t.Errorf("%s: inventory holds %d leftover item(s), want 0", gender, len(f.bag))
		}
	}
	// A man's and a woman's kits are the same shape with different rows:
	// the suit is a man's or a woman's, the sword is anyone's.
	if StartingKitFor(character.GenderChinaMan)[SlotMail] == StartingKitFor(character.GenderChinaWoman)[SlotMail] {
		t.Error("a man and a woman are given the same suit")
	}
	if StartingKitFor(character.GenderChinaMan)[SlotWeapon] != StartingKitFor(character.GenderChinaWoman)[SlotWeapon] {
		t.Error("the default sword is for either gender")
	}
}

// A refused Equip is reported rather than swallowed, so the caller can log
// it -- and the slots that did succeed stay on, because a partly dressed
// character is better than an undressed one.
func TestGiveStartingKitReportsAFailedSlot(t *testing.T) {
	f := newFakeStores()
	f.failEnabled = true
	f.failEquipOn = SlotBoots

	err := GiveStartingKit(context.Background(), f, f, 7, character.GenderChinaMan)
	if err == nil {
		t.Fatal("GiveStartingKit succeeded, want the refused slot reported")
	}
	if len(f.worn) != 2 {
		t.Errorf("kept %d slot(s) worn, want the 2 that succeeded before the failure", len(f.worn))
	}
}

// A nil store is how a caller says "no kit" -- any deployment that has not
// wired inventory and equipment. It must not panic.
func TestGiveStartingKitWithoutStoresIsANoOp(t *testing.T) {
	if err := GiveStartingKit(context.Background(), nil, nil, 1, character.GenderChinaMan); err != nil {
		t.Fatalf("GiveStartingKit with no stores: %v", err)
	}
}
