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
//
// CONFIRMED AGAINST THE SERVER 2026-09-16, and this numbering is the
// engine's own. GObjPC::FUN_00496c20 (`0x00496c20`) is the engine's
// item-to-slot resolver: it reads the item's packed type word and switches
// to a slot number. Its armour arm maps TypeID4 to slot as
//
//	1 -> 0   2 -> 2   3 -> 1   4 -> 4   5 -> 3   6 -> 5
//
// which is a PERMUTATION, not the identity -- and it is exactly the
// permutation between the table's piece order (helm, shoulder, mail, pants,
// gauntlet, boots) and the order above, derived independently from the
// client's window artwork. Two binaries, two unrelated artefacts, one
// numbering. The rest of the resolver lands weapons on 6, shields on 7, job
// suits on 8 and the accessories on 9/10/11, all of which this enum already
// had in place. See docs/protocol/EQUIP_SLOTS.md.
//
// AND A THIRD ARTEFACT AGREES, which is what named slots 8, 11 and 12. The
// client's equipment window loads one .ddj per slot and the filenames are
// the game's own words for them:
//
//	8  equip_slot_specialdress.ddj      11  equip_slot_l_ring.ddj
//	9  equip_slot_earring.ddj           12  equip_slot_r_ring.ddj
//	10 equip_slot_necklace.ddj
//
// The artwork had two ring slots before this project knew the server
// accepted two, and it called slot 8 a dress before the item table was
// asked what lives there. Both were sitting in EQUIP_SLOTS.md unread.
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
	// SlotJobSuit was called SlotExtra until 2026-09-16, when the engine's
	// resolver named it: TypeID3 == 7 returns slot 8, and every TypeID3 == 7
	// row in a real itemdata is a trade outfit -- ITEM_EU_F_TRADE_TRADER_01,
	// ITEM_CH_M_TRADE_HUNTER_04_01 and so on. "Extra" was a placeholder, and
	// a placeholder is a claim like any other.
	//
	// 10 of the 128 rows are ITEM_CH_F_FRPVP_VOUCHER_*, the free-PvP tokens,
	// which are not job suits but share the family and therefore the slot.
	SlotJobSuit
	// The accessory slots, added 2026-09-16. Appended rather than inserted:
	// a Slot is persisted as its integer, so giving an existing value a new
	// meaning would silently move every equipped item.
	SlotEarring
	SlotNecklace
	// SlotRingLeft and SlotRingRight are a PAIR: the engine accepts either for a
	// ring. Its equip check (CGItemEquip::vslot_317, `0x00497070`) resolves
	// the required slot and demands an exact match, except here --
	//
	//	if (required != 0xb)  return (given != required) ? 0x180e : 1;
	//	if (given == 0xb) return 1;
	//	if (given == 0xc) return 1;
	//	return 0x180e;
	//
	// -- so a character wears two rings. Added 2026-09-16; srrevamp had one.
	SlotRingLeft
	SlotRingRight
)

// MaxEquipSlots is how many equipment slots the engine has, and NoSlot is
// its "no slot" sentinel. Both are read off the front of the equip check
// (CGItemEquip::vslot_317, `0x00497070`), which refuses with 0x1806
// UIIT_MSG_STRGERR_WRONG_POSITION before looking at anything else:
//
//	if ((slot == 0xff) || (0xc < slot)) return 0x1806;
//
// 0xff is the same not-set sentinel the skill table uses for an unused
// weapon requirement (combat.ReqWeaponUnused).
const (
	MaxEquipSlots = 13
	NoSlot        = 0xff
)

// AccessorySlots are the worn accessories. They carry no model the client
// draws, which is why they are not in WearableSlots. There are two ring
// slots and the engine takes a ring in either.
var AccessorySlots = []Slot{SlotEarring, SlotNecklace, SlotRingLeft, SlotRingRight}

// ArmorSlots are the six wearable armour slots -- the ones that add to a
// character's defence and are drawn on the body. SlotWeapon and SlotShield
// are held, not worn; SlotJobSuit holds a trade outfit, which this project
// tracks but has no job system to give meaning to yet.
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
