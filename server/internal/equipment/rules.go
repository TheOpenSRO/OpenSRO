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
