// Package equipment implements this project's own equip/unequip system:
// moving an item out of a character's inventory into a small set of
// equipment slots that feed combat stat calculations. Independent design.
package equipment

import (
	"context"
	"errors"
)

// Slot identifies one equipment slot, numbered in the game's own order.
//
// The order is the one the client's equipment window loads its slot
// artwork in -- helm, mail, shoulderguard, gauntlet, pants, boots, weapon,
// shield, then the accessories -- and the one its avatar's equip-visual
// struct keeps the first eight in, twelve bytes apart (see
// docs/protocol/EQUIP_SLOTS.md). Gauntlet is the slot that struct's debug
// dump skipped and this project once could not name: the wristlet worn on
// the forearms, `clothes_NN_aa` in the model files.
type Slot int

const (
	SlotHelm Slot = iota
	SlotMail
	SlotShoulderGuard
	SlotGauntlet
	SlotPants
	SlotBoots
	SlotWeapon
	SlotShield
	SlotExtra
	// The accessory slots, added 2026-09-16. Appended rather than inserted:
	// a Slot is persisted as its integer, so giving an existing value a new
	// meaning would silently move every equipped item.
	SlotEarring
	SlotNecklace
	SlotRing
)

// AccessorySlots are the three worn accessories. They carry no model the
// client draws, which is why they are not in WearableSlots.
var AccessorySlots = []Slot{SlotEarring, SlotNecklace, SlotRing}

// ArmorSlots are the six wearable armour slots -- the ones that add to a
// character's defence and are drawn on the body. SlotWeapon and SlotShield
// are held, not worn; SlotExtra is tracked but has no gameplay yet.
var ArmorSlots = []Slot{SlotHelm, SlotMail, SlotShoulderGuard, SlotGauntlet, SlotPants, SlotBoots}

// WearableSlots is every slot that carries a model the client draws on
// the character: the armour, plus the weapon and shield.
var WearableSlots = []Slot{SlotHelm, SlotMail, SlotShoulderGuard, SlotGauntlet, SlotPants, SlotBoots, SlotWeapon, SlotShield}

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

// ErrTwoHandedShield is returned when a shield and a two-handed weapon would
// be worn at once. Both hands are already busy.
var ErrTwoHandedShield = errors.New("equipment: a two-handed weapon leaves no hand for a shield")

// TwoHandedConflict reports whether putting `incoming` into `slot` would leave
// a character holding a two-handed weapon and a shield at the same time.
// `worn` is what is already equipped, keyed by slot.
//
// This rule was dormant until shields started blocking: with no block, a
// spurious shield was only a drawing mistake, and now it is free damage
// avoidance. The real game gives the shield its own slot (7, the same index
// this package uses) and a two-handed weapon takes both hands.
//
// TwoHanded is real, from _RefObjItem's own column -- see
// cmd/export-refdata's fTwoHanded for how it was identified and for the
// five-of-five cross-check against the client's independently recovered
// one-hand/two-hand animation group names.
func TwoHandedConflict(worn map[Slot]*ItemStats, slot Slot, incoming *ItemStats) bool {
	if incoming == nil {
		return false
	}
	switch slot {
	case SlotShield:
		w := worn[SlotWeapon]
		return w != nil && w.TwoHanded
	case SlotWeapon:
		return incoming.TwoHanded && worn[SlotShield] != nil
	}
	return false
}

// ItemStats is the slice of an item this package needs to judge a conflict.
// Deliberately not refdata.Item: equipment must not depend on the reference
// data package, which depends on this one for slot types.
type ItemStats struct {
	TwoHanded bool
}
