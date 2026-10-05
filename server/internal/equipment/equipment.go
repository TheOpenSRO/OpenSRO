// Package equipment implements this project's own equip/unequip system:
// moving an item out of a character's inventory into a small set of
// equipment slots that feed combat stat calculations. Independent design.
package equipment

import (
	"context"
	"errors"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
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
	// resolver said what lives here: TypeID3 == 7 returns slot 8, and every
	// TypeID3 == 7 row in a real itemdata is a trade outfit --
	// ITEM_EU_F_TRADE_TRADER_01, ITEM_CH_M_TRADE_HUNTER_04_01 and so on.
	//
	// "EXTRA" WAS NOT AN INVENTED NAME, contrary to what the commit that
	// renamed it said. The client's own equip-visual debug dump
	// (`0x00a5e360`) prints this slot as `"EXTRA [ %d ] [ %d ]"`, reading
	// `this + 0x98` -- which is 0x38 + 8*0xc, slot 8 exactly. The name came
	// out of the binary; what was a placeholder was the COMMENT on it
	// ("tracked but has no gameplay yet"), which described this project's
	// ignorance rather than the slot.
	//
	// The client has two words for it and they disagree: the debug dump says
	// EXTRA, the window artwork is `equip_slot_specialdress.ddj`. The item
	// table breaks the tie by saying what is actually in it, which is why
	// this is the name that stuck.
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
	// ring. Its equip check (CGItemEquip::CanBeEquipedAt, `0x00497070`) resolves
	// the required slot and demands an exact match, except here --
	//
	//	if (required != 0xb)  return (given != required) ? 0x180e : 1;
	//	if (given == 0xb) return 1;
	//	if (given == 0xc) return 1;
	//	return 0x180e;
	//
	// -- so a character wears two rings. Added 2026-09-16; OpenSRO had one.
	SlotRingLeft
	SlotRingRight
)

// MaxEquipSlots is how many equipment slots the engine has, and NoSlot is
// its "no slot" sentinel. Both are read off the front of the equip check
// (CGItemEquip::CanBeEquipedAt, `0x00497070`), which refuses with 0x1806
// UIIT_MSG_STRGERR_WRONG_POSITION before looking at anything else:
//
//	if ((slot == 0xff) || (0xc < slot)) return 0x1806;
//
// 0xff is the same not-set sentinel the skill table uses for an unused
// weapon requirement (combat.ReqWeaponUnused).
//
// THE ENGINE'S OWN NAME for that check is CanBeEquipedAt (its spelling, one
// `p`). CheckEquipsetIntegrity calls it through vtable offset 0x4f4 -- slot
// 317, the same slot this project had been calling `vslot_317` -- and names it
// when the call disagrees with what is already worn:
//
//	"Equiped already but CanBeEquipedAt() failed!! [Char: %s, Slot: %d, Item: %s]"
//
// A FOURTH WITNESS for the count, 2026-09-16: CheckEquipsetIntegrity's own
// loop runs `local_c` from 0 and returns success at `0xc < local_c`, so it
// validates exactly slots 0..12. That is now the server's equip check, the
// server's resolver, the client's appearance installer, and this.
//
// EquipVisualCount is how many of those slots carry a model the client
// draws. It is the client's own EQUIP_VISUAL_COUNT, from two differently
// worded asserts in CObjCharacter.cpp:
//
//	:1893  8 < dwSlotPos                  "dwSlotPos < EQUIP_VISUAL_COUNT"
//	:770   nEquipSlot < 0 || 8 < nEquipSlot
//	       "(nEquipSlot >=0 ) && ( nEquipSlot < EQUIP_VISUAL_COUNT)"
//
// Both guards stop at 8 and both expressions are strict `<`, so the count is
// 9 -- slots 0..8. It bounds a nine-entry array at CObjCharacter+0x38 with a
// twelve-byte stride, which is the array EQUIP_SLOTS.md described as having
// eight entries. It has nine; the ninth is the job suit.
const (
	MaxEquipSlots    = 13
	NoSlot           = 0xff
	EquipVisualCount = 9
)

// MaxItemOptLevel is the highest option level an item may carry.
//
// From CGPCInventoryOP::CheckEquipsetIntegrity (`0x004bb020`), which walks a
// character's equipped items and refuses the whole set if any one of them is
// out of range:
//
//	if (0xfa < item[0xd]->optLevel)      // a byte at +0x2c
//	    "Item OptLevel is invalid!!![Char: %s, Slot: %d, Item: %s, OptLevel: %d]"
//
// The guard fires ABOVE 0xfa, so 250 is legal and 251 is not.
//
// THIS IS A SANITY CEILING, NOT A GAMEPLAY ONE. Real items are enhanced to
// single digits; 250 is where the engine stops believing the number at all.
// Recorded as the engine's bound, not as a balance figure -- OpenSRO does not
// model option levels, and an implementation that treated 250 as a reachable
// target would be reading a validation limit as a design limit.
const MaxItemOptLevel = 250

// AccessorySlots are the worn accessories.
//
// THEY CARRY NO DRAWN MODEL, and that is now measured rather than assumed.
// This comment used to assert it flatly. The client's appearance installer
// (`0x00a61010`) splits on exactly this line:
//
//	if (8 < slot) {                          // 9..12
//	    if ((slot < 0xd) && (item != 0))
//	        FUN_00a5ff00(slot, item);        // a different path entirely
//	    return 0;                            // no mesh, no visual record
//	}
//	// 0..8 fall through to the +0x38 array and the model attach calls
//
// So an accessory never reaches the mesh path. Its `slot < 0xd` is also a
// third independent witness for MaxEquipSlots, from a different binary than
// the two that gave it.
var AccessorySlots = []Slot{SlotEarring, SlotNecklace, SlotRingLeft, SlotRingRight}

// ArmorSlots are the six wearable armour slots -- the ones that add to a
// character's defence and are drawn on the body. SlotWeapon and SlotShield
// are held, not worn; SlotJobSuit holds a trade outfit, which this project
// tracks but has no job system to give meaning to yet.
var ArmorSlots = []Slot{SlotHelm, SlotMail, SlotShoulderGuard, SlotGauntlet, SlotPants, SlotBoots}

// WearableSlots is every slot that carries a model the client draws on the
// character: the armour, the weapon and shield, and the job suit.
//
// THE JOB SUIT WAS MISSING until 2026-09-16, when the claim above it was
// checked for the first time. The client's own item-to-visual-slot resolver
// (GlobalDataManager::FUN_009db5e0, `0x009db5e0`) sends TypeID3 == 7 --
// `(w & 0x780) == 0x380` -- to visual slot 8, which is inside
// EquipVisualCount and therefore on the mesh path. A trade outfit is worn
// and seen, which is the whole point of one.
//
// That resolver is also the client's half of a CROSS-BINARY confirmation.
// It reproduces the server's GObjPC::FUN_00496c20 arm for arm, including
// the armour permutation 1->0 2->2 3->1 4->4 5->3 6->5, weapons to 6,
// shields to 7 (TypeID3 == 4, TypeID4 in {1,2}), and the accessories to
// 9/10/11 by TypeID4 1/2/3 under TypeID3 5 or 12. Two binaries, written
// against each other but compiled separately, agreeing on all twelve.
var WearableSlots = []Slot{SlotHelm, SlotMail, SlotShoulderGuard, SlotGauntlet, SlotPants, SlotBoots, SlotWeapon, SlotShield, SlotJobSuit}

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
	// Variance and Durability are the worn item's instance, carried from the
	// bag slot it came from and back again (see inventory.Slot).
	Variance   uint64
	Durability int
	// OptLevel, MagParams and AdvElixir: the rest of the instance (round
	// 732, inventory.Instance).
	OptLevel  uint8
	MagParams []uint64
	AdvElixir uint8
}

// Instance returns the worn item's per-instance fields.
func (e Equipped) Instance() inventory.Instance {
	return inventory.Instance{Variance: e.Variance, Durability: e.Durability, OptLevel: e.OptLevel,
		MagParams: append([]uint64(nil), e.MagParams...), AdvElixir: e.AdvElixir}
}

// SetInstance writes inst's fields onto the worn item.
func (e *Equipped) SetInstance(inst inventory.Instance) {
	e.Variance, e.Durability = inst.Variance, inst.Durability
	e.OptLevel, e.MagParams, e.AdvElixir = inst.OptLevel, append([]uint64(nil), inst.MagParams...), inst.AdvElixir
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

	// SetDurability writes a worn item's current durability (a loss, a
	// repair, a break); durability.Apply decides the value. ErrSlotEmpty
	// when nothing is worn there.
	SetDurability(ctx context.Context, characterID int64, slot Slot, durability int) error
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
