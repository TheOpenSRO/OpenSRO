package equipment

import (
	"errors"
	"fmt"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
)

// The rules for who may wear what, as the item table states them. Every
// column here is the game's own -- see docs/protocol/ITEM_FORMAT.md for
// how each was established -- and the checks are the ones the original
// enforces server-side (the client greys an item out for the same reasons
// and never sends the request).
//
// What is checked: the slot an item may go in (its TypeID4), the race
// (Country), the gender (ReqGender) and the character's level where the
// requirement is by character level (ReqLevelType1 == 1). What is
// recorded but not yet enforced: requirements by mastery level (a
// ReqLevelType1 of 513..518, the European masteries' own ids -- nothing
// here tracks a mastery level yet) and ReqStr/ReqInt (characters have no
// stats yet).

var (
	// ErrNotEquippable means the item is not something that goes in an
	// equipment slot at all.
	ErrNotEquippable = errors.New("equipment: item cannot be equipped")
	// ErrWrongSlot means the item goes in a different slot from the one asked.
	ErrWrongSlot = errors.New("equipment: item does not go in that slot")
	// ErrWrongRace means the item belongs to another race.
	ErrWrongRace = errors.New("equipment: item is for another race")
	// ErrWrongGender means the item is for the other gender.
	ErrWrongGender = errors.New("equipment: item is for the other gender")
	// ErrLevelTooLow means the character has not reached the item's level.
	ErrLevelTooLow = errors.New("equipment: level too low")
)

// Item type ids, from the table's TypeID1..4 columns.
const (
	TypeItem = 3 // TypeID1: every item

	TypeEquipment = 1 // TypeID2: worn or held

	// TypeID3 under TypeEquipment: the family.
	FamilyChinaGarment   = 1
	FamilyChinaProtector = 2
	FamilyChinaArmor     = 3
	FamilyShield         = 4
	FamilyWeapon         = 6
	FamilyAccessory      = 7
	FamilyEuropeRobe     = 9
	FamilyEuropeLight    = 10
	FamilyEuropeHeavy    = 11

	// TypeID4 under an armour family: the piece. Its own numbering, not
	// the slot order -- measured across every armour row in a real table,
	// 136-140 of each, with no exceptions.
	PieceHelm          = 1
	PieceShoulderGuard = 2
	PieceMail          = 3
	PiecePants         = 4
	PieceGauntlet      = 5
	PieceBoots         = 6
)

// The widths of the type-id hierarchy, RECOVERED from the server binary rather
// than inferred from the tables this project has seen.
//
// ReferenceData::RefItem_ReadTypeIDs (`0x006a8090`) deserialises the five type
// bytes and bounds-checks each one against a named constant, asserting through
// the game's own file and line:
//
//	ReferenceData.cpp:2466   if (1    < btCash)  "btCash < MAX_CASHITEM_TID_COUNT"
//	ReferenceData.cpp:2467   if (7    < btType1) "btType1 < MAX_TID1_COUNT"
//	ReferenceData.cpp:2468   if (3    < btType2) "btType2 < MAX_TID2_COUNT"
//	ReferenceData.cpp:2469   if (0xf  < btType3) "btType3 < MAX_TID3_COUNT"
//	ReferenceData.cpp:2470   if (0x1f < btType4) "btType4 < MAX_TID4_COUNT"
//
// Each assert fires on `limit-1 < value`, so the constant is one past the
// largest legal value. The widths fall out as 1, 3, 2, 4 and 5 bits.
//
// These are not used to gate anything at runtime -- the engine's own check is
// an assert, not a rejection, and real tables are well inside the bounds. They
// are here because they bound the ENUMERATIONS above: there can be at most 16
// families and at most 32 pieces, so a family id of 30 would be a typo rather
// than an unknown armour set. TestTypeIDsAreWithinRecoveredBounds holds the
// constants above to them.
const (
	MaxCashItemTID = 2  // btCash  in [0, 1]
	MaxTID1        = 8  // TypeID1 in [0, 7]
	MaxTID2        = 4  // TypeID2 in [0, 3]
	MaxTID3        = 16 // TypeID3 in [0, 15]
	MaxTID4        = 32 // TypeID4 in [0, 31]
)

// Country values.
const (
	CountryChina  = 0
	CountryEurope = 1
	CountryAny    = 3
)

// ReqGender values.
const (
	ReqGenderWoman = 0
	ReqGenderMan   = 1
	ReqGenderAny   = 2
)

// ReqLevelTypeCharacter is the ReqLevelType that asks for the character's
// own level. Any other value in a real table is a mastery id (513..518,
// Europe's), asking for that mastery's level instead.
const ReqLevelTypeCharacter = 1

// SlotFor reports the slot an item goes in, or false if it is not worn or
// held in any of the slots this project has.
func SlotFor(it *refdata.Item) (Slot, bool) {
	if it == nil || it.TypeID1 != TypeItem || it.TypeID2 != TypeEquipment {
		return 0, false
	}
	switch it.TypeID3 {
	case FamilyWeapon:
		return SlotWeapon, true
	case FamilyShield:
		return SlotShield, true
	case FamilyChinaGarment, FamilyChinaProtector, FamilyChinaArmor,
		FamilyEuropeRobe, FamilyEuropeLight, FamilyEuropeHeavy:
		switch it.TypeID4 {
		case PieceHelm:
			return SlotHelm, true
		case PieceShoulderGuard:
			return SlotShoulderGuard, true
		case PieceMail:
			return SlotMail, true
		case PiecePants:
			return SlotPants, true
		case PieceGauntlet:
			return SlotGauntlet, true
		case PieceBoots:
			return SlotBoots, true
		}
	}
	return 0, false
}

// Refusal reports why c may not put it in slot, or nil if it may. Every
// outcome is one of the Err* values above, wrapped with the specifics.
//
// A nil item -- no reference data for that id -- is REFUSED. This used to be
// allowed through, on the reasoning that reference data is the operator's and
// an id the tables do not know should still equip (just with no name, icon or
// model). That permissiveness was a real bug: an HP potion could be put in an
// armour slot on any server whose refdata did not carry the ETC consumables,
// because "unknown" was read as "fine". A slot is typed, so belonging in it is
// something an item must be positively shown to do -- if we cannot tell, the
// safe answer is no. Callers that genuinely have no reference data wired skip
// the rules entirely rather than passing nil here (see session.equipRefusal).
func Refusal(c *character.Character, it *refdata.Item, slot Slot) error {
	if it == nil {
		return fmt.Errorf("%w: no reference data for the item", ErrNotEquippable)
	}
	want, ok := SlotFor(it)
	if !ok {
		return fmt.Errorf("%w: item %d is type %d/%d/%d/%d", ErrNotEquippable, it.ID, it.TypeID1, it.TypeID2, it.TypeID3, it.TypeID4)
	}
	if want != slot {
		return fmt.Errorf("%w: item %d goes in slot %d, not %d", ErrWrongSlot, it.ID, want, slot)
	}
	// Every character is China today; a Europe item is for another race.
	if it.Country == CountryEurope {
		return fmt.Errorf("%w: item %d is European", ErrWrongRace, it.ID)
	}
	if c != nil {
		switch it.ReqGender {
		case ReqGenderMan:
			if c.Gender != character.GenderChinaMan {
				return fmt.Errorf("%w: item %d is a man's", ErrWrongGender, it.ID)
			}
		case ReqGenderWoman:
			if c.Gender != character.GenderChinaWoman {
				return fmt.Errorf("%w: item %d is a woman's", ErrWrongGender, it.ID)
			}
		}
		if it.ReqLevelType1 == ReqLevelTypeCharacter && c.Level < it.ReqLevel1 {
			return fmt.Errorf("%w: item %d needs level %d, character is %d", ErrLevelTooLow, it.ID, it.ReqLevel1, c.Level)
		}
	}
	return nil
}
