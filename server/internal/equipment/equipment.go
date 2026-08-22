// Package equipment implements this project's own equip/unequip system:
// moving an item out of a character's inventory into a small set of
// equipment slots that feed combat stat calculations. Independent design.
package equipment

import (
	"context"
	"errors"
)

// Slot identifies one equipment slot. Real, decompiler-confirmed slot
// names and order (from sro_client.exe's real "Avatar" equip-visual debug
// dump) -- see docs/protocol/EQUIP_SLOTS.md for the full derivation.
// Replaces an earlier own-design single catch-all SlotArmor now that a
// real per-piece layout has been found.
type Slot int

const (
	SlotWeapon Slot = iota
	SlotHelm
	SlotMail
	SlotShoulderGuard
	SlotPants
	SlotBoots
	SlotShield
	SlotExtra
)

// ArmorSlots are the five real slots CharacterAssembler has a confirmed
// real bone mapping for (see EQUIP_SLOTS.md) -- the ones that actually
// render something client-side. SlotShield/SlotExtra are real and
// trackable but have no confirmed real rendering convention yet.
var ArmorSlots = []Slot{SlotHelm, SlotMail, SlotShoulderGuard, SlotPants, SlotBoots}

// ErrInvalidSlot is returned for a Slot value outside the known set.
var ErrInvalidSlot = errors.New("equipment: invalid slot")

// ErrSlotEmpty is returned by Store.Unequip when nothing is equipped in
// the requested slot.
var ErrSlotEmpty = errors.New("equipment: slot is empty")

// ErrInventorySlotEmpty is returned by Store.Equip when the referenced
// inventory slot has nothing in it.
var ErrInventorySlotEmpty = errors.New("equipment: inventory slot is empty")

// Equipped is one character's equipped item in one slot.
type Equipped struct {
	Slot   Slot
	ItemID int64
}

// Store is anything that can equip, unequip, and list a character's
// equipped items.
type Store interface {
	// Get returns everything currently equipped for characterID.
	Get(ctx context.Context, characterID int64) ([]Equipped, error)

	// Equip moves the item in characterID's inventory slot inventorySlot
	// into equipment slot slot. Whatever was previously equipped there (if
	// anything) goes back to the inventory first. Returns
	// ErrInventorySlotEmpty if inventorySlot has nothing in it.
	Equip(ctx context.Context, characterID int64, slot Slot, inventorySlot int) error

	// Unequip moves whatever's in equipment slot slot back to the
	// character's inventory. Returns ErrSlotEmpty if nothing is equipped
	// there, or inventory.ErrNoRoom if there's nowhere to put it.
	Unequip(ctx context.Context, characterID int64, slot Slot) error
}
