package equipment

import (
	"errors"
	"fmt"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// The rules for who may wear what, as the item table states them. Every
// column here is the game's own -- see docs/protocol/ITEM_FORMAT.md for
// how each was established -- and the checks are the ones the original
// enforces server-side (the client greys an item out for the same reasons
// and never sends the request).
//
// What is checked: the slot an item may go in (its TypeID4), the race
// (Country), the gender (ReqGender), the character's level where the
// requirement is by character level (a requirement type of 1) and, from
// round 877, the masteries where it is by mastery level (513..518, any one of
// the item's: Refusal's mastery lookup), and the armour-and-cloth mix
// (ArmourMixRefusal). What is recorded but not enforced: the job-tier type
// 769 (no equippable row carries it) and ReqStr/ReqInt (see below).
//
// ALL FOUR REQUIREMENT SLOTS ARE READ as of 2026-09-16, not just the first,
// and the rule for combining them is the engine's -- see requirements.go,
// which recovers CheckEquipRequirements (0x004919e0). An earlier note here
// called 513..518 "the European masteries' own ids"; that is wrong. Real
// Chinese rows use 513/515/518 and real European ones 514/516/517/518, so
// the range covers both races' masteries.
//
// THE REASON GIVEN FOR SKIPPING ReqStr/ReqInt WAS WRONG, corrected 2026-09-16.
// It said "characters have no stats yet", which stopped being true when
// character.Character gained Str and Int. The real reason is better: **no item
// in the table carries either requirement.** Measured over a real client's
// complete itemdata, the count of items with a non-zero ReqStr or ReqInt is
// **zero** -- columns 59 and 60 are present on every row and always 0.
//
// The engine does have the refusals: `0x1830 UIIT_MSG_STRGERR_HIGHER_STRENGTH_
// REQUIRED` and `0x1831 ..._HIGHER_INTELLECT_REQUIRED`
// (docs/protocol/error_codes.md). So the mechanism is real and the data never
// uses it. Implementing the check would be dead code, and saying "characters
// have no stats" would now be a false explanation for a correct decision --
// which is worse than no explanation.

var (
	// ErrNotEquippable means the item is not something that goes in an
	// equipment slot at all.
	ErrNotEquippable = errors.New("equipment: item cannot be equipped")
	// ErrWrongSlot means the item goes in a different slot from the one asked.
	ErrWrongSlot = errors.New("equipment: item does not go in that slot")
	// The three below are refusals the real game makes too, and each has the
	// engine's own error code and message name -- recovered from the client's
	// dispatcher, see docs/protocol/error_codes.md. OpenSRO arrived at these
	// independently from the itemdata columns; the names are recorded because
	// agreeing with the game about WHICH refusals exist is worth being able to
	// check.

	// ErrWrongRace means the item belongs to another race.
	// Engine: 0x182f UIIT_MSG_STRGERR_COUNTRY_MISMATCH.
	ErrWrongRace = errors.New("equipment: item is for another race")
	// ErrWrongGender means the item is for the other gender.
	// Engine: 0x1816 UIIT_MSG_STRGERR_GENDER_MISMATCH.
	ErrWrongGender = errors.New("equipment: item is for the other gender")
	// ErrLevelTooLow means the character has not reached the item's level.
	// Engine: 0x186c UIIT_MSG_STRGERR_HIGHER_LEVEL_REQUIRED_TO_USE_THISITEM,
	// the code CheckEquipRequirements (s:0x4919e0) gives every unmet level or
	// mastery requirement alike (round 877; this said 0x1810 before).
	ErrLevelTooLow = errors.New("equipment: level too low")
	// ErrArmourMix means a body piece of cloth (a garment or a robe) would be
	// worn with armour, or armour with cloth (round 877, ArmourMixRefusal).
	// Engine: 0x1832, worded UIIT_MSG_STRGERR_CANT_MIX_EXCLUSIVE_ARMOR_TYPE for
	// a Chinese character and UIIT_MSG_STRGERR_EU_CANT_MIX_EXCLUSIVE_ARMOR_TYPE
	// for a European one (READ, the client's error switch c:0x7b8e01..0x7b8e57).
	ErrArmourMix = errors.New("equipment: armour and cloth cannot be worn together")
)

// Item type ids, from the table's TypeID1..4 columns.
const (
	TypeItem = 3 // TypeID1: every item

	TypeEquipment = 1 // TypeID2: worn or held

	// TypeExpendable is TypeID2 for everything consumed rather than worn --
	// potions, quest items, alchemy stock. It is here for one reason: the
	// engine's slot resolver has a second arm for it, and it holds
	// ammunition. See FamilyAmmunition.
	TypeExpendable = 3

	// TypeID3 under TypeEquipment: the family.
	FamilyChinaGarment   = 1
	FamilyChinaProtector = 2
	FamilyChinaArmor     = 3
	FamilyShield         = 4
	FamilyWeapon         = 6
	FamilyEuropeRobe     = 9
	FamilyEuropeLight    = 10
	FamilyEuropeHeavy    = 11

	// The ACCESSORY families, added 2026-09-16, and a correction with them.
	//
	// This list used to carry `FamilyAccessory = 7`. **Seven is not
	// accessories.** Every TypeID3 == 7 row in a real itemdata is a JOB SUIT --
	// ITEM_EU_F_TRADE_TRADER_01, ITEM_CH_M_TRADE_HUNTER_04_01,
	// ITEM_CH_F_FRPVP_VOUCHER_D and so on, 111 items across TypeID4 1, 2, 3, 5,
	// 6, 7 for trader, thief, hunter and free-PvP. The name was invented and
	// nothing checked it.
	//
	// Accessories are two families, one per race, and each holds exactly the
	// same three pieces -- measured over a complete itemdata, 99 items apiece:
	//
	//	TypeID3  5  China   TypeID4 1 earring, 2 necklace, 3 ring
	//	TypeID3 12  Europe  TypeID4 1 earring, 2 necklace, 3 ring
	//
	// Neither family was in this list, so 594 real items answered
	// ErrNotEquippable.
	FamilyChinaAccessory  = 5
	FamilyJobSuit         = 7
	FamilyEuropeAccessory = 12

	// TypeID4 under an armour family: the piece. Its own numbering, not
	// the slot order -- measured across every armour row in a real table,
	// 136-140 of each, with no exceptions.
	PieceHelm          = 1
	PieceShoulderGuard = 2
	PieceMail          = 3
	PiecePants         = 4
	PieceGauntlet      = 5
	PieceBoots         = 6

	// TypeID4 under an ACCESSORY family. A separate numbering from the armour
	// pieces above, which is why it gets its own names: both accessory families
	// use 1/2/3, and each value holds 99 items in a real table.
	PieceEarring  = 1
	PieceNecklace = 2
	PieceRing     = 3

	// FamilyAmmunition is TypeID3 == 4 under TypeExpendable -- quivers of
	// arrows and cases of bolts. FOUR IS ALSO FamilyShield, under
	// TypeEquipment: TypeID3's meaning depends on the TypeID2 above it, so
	// the two constants share a value without sharing a meaning.
	//
	// Ammunition is EQUIPPED, and in the shield slot. The engine's resolver
	// has a whole second arm for it:
	//
	//	if (tid2 != 1) { if (tid2 != 3) assert; if ((w & 0x780) == 0x200) return 7; }
	//
	// (0x780 is the TypeID3 field, 0x200 >> 7 == 4.) That is the same slot
	// number the shield arm returns, which is the mechanism: a bow user
	// gives up the shield to carry arrows.
	//
	// THE ENGINE'S OWN WORD FOR IT IS "BULLET", and a fourth confirmation
	// arrived 2026-09-16 from CGPCInventoryOP::CheckEquipsetIntegrity
	// (`0x004bb020`). That validator rejects anything that is not equipment,
	// with one exception spelled out in the condition itself:
	//
	//	if ((notEquip != 1) || (slot != 7))
	//	    "Item is neither Equip nor Bullet! [Char: %s, Slot: %d, Item: %s]"
	//
	// A bullet passes only at slot 7. So the engine does not merely allow
	// ammunition in the shield slot -- it allows it nowhere else.
	FamilyAmmunition = 4
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
//
// This is GObjPC::FUN_00496c20 (`0x00496c20`), the engine's own resolver,
// arm for arm. Checked against a real client's complete itemdata: of 11,772
// TypeID1 == 3 rows, every row this returns a slot for is one the engine
// returns the same slot for, and the two disagree nowhere. The rows with no
// slot are the expendables (which are not worn) and TypeID3 13/14, the
// avatars -- the engine has no case for those either and asserts on them,
// because they live in a separate container.
func SlotFor(it *refdata.Item) (Slot, bool) {
	if it == nil || it.TypeID1 != TypeItem {
		return 0, false
	}
	// Ammunition is not TypeEquipment but is still equipped, in the shield
	// slot. The engine tests this arm before the family switch.
	if it.TypeID2 == TypeExpendable {
		if it.TypeID3 == FamilyAmmunition {
			return SlotShield, true
		}
		return 0, false
	}
	if it.TypeID2 != TypeEquipment {
		return 0, false
	}
	switch it.TypeID3 {
	case FamilyWeapon:
		return SlotWeapon, true
	case FamilyShield:
		return SlotShield, true
	case FamilyJobSuit:
		return SlotJobSuit, true
	case FamilyChinaAccessory, FamilyEuropeAccessory:
		// Both races number the pieces identically.
		switch it.TypeID4 {
		case PieceEarring:
			return SlotEarring, true
		case PieceNecklace:
			return SlotNecklace, true
		case PieceRing:
			return SlotRingLeft, true
		}
		return 0, false
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

// SlotAccepts reports whether an item whose resolved slot is want may
// actually be placed in given. It is an equality test everywhere except the
// rings, where the engine takes either of the pair -- see SlotRingRight.
func SlotAccepts(want, given Slot) bool {
	if want == SlotRingLeft {
		return given == SlotRingLeft || given == SlotRingRight
	}
	return want == given
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
//
// mastery is the character's level in a mastery id (513..518), a mastery it
// does not hold reading 0 (Mastery_GetLevel s:0x59e750 returns 0 when
// FUN_0059d6f0 finds none). nil leaves the mastery requirements unenforced,
// as every caller did before round 877.
func Refusal(c *character.Character, it *refdata.Item, slot Slot, mastery func(masteryID int) (int, bool)) error {
	if it == nil {
		return fmt.Errorf("%w: no reference data for the item", ErrNotEquippable)
	}
	want, ok := SlotFor(it)
	if !ok {
		return fmt.Errorf("%w: item %d is type %d/%d/%d/%d", ErrNotEquippable, it.ID, it.TypeID1, it.TypeID2, it.TypeID3, it.TypeID4)
	}
	if !SlotAccepts(want, slot) {
		return fmt.Errorf("%w: item %d goes in slot %d, not %d", ErrWrongSlot, it.ID, want, slot)
	}
	// An item of the other race is refused; Country 3 (either) is not. The
	// character's race is its body's (character.RaceOf its Gender, which is
	// derived from RefObjID since round 682, when Europe became creatable);
	// with no character the check is a China one, as it always was.
	race := character.RaceChina
	if c != nil {
		race = character.RaceOf(c.Gender)
	}
	if it.Country == CountryEurope && race != character.RaceEurope {
		return fmt.Errorf("%w: item %d is European", ErrWrongRace, it.ID)
	}
	if it.Country == CountryChina && race != character.RaceChina {
		return fmt.Errorf("%w: item %d is Chinese", ErrWrongRace, it.ID)
	}
	if c != nil {
		switch it.ReqGender {
		case ReqGenderMan:
			if character.SexOf(c.Gender) != character.SexMan {
				return fmt.Errorf("%w: item %d is a man's", ErrWrongGender, it.ID)
			}
		case ReqGenderWoman:
			if character.SexOf(c.Gender) != character.SexWoman {
				return fmt.Errorf("%w: item %d is a woman's", ErrWrongGender, it.ID)
			}
		}
		// All four requirement slots, by the engine's own rule -- see
		// requirements.go. Round 877: the masteries through the caller's
		// lookup (READ s:0x491b25..0x491b40: the requirement's own type is
		// the mastery id passed to Mastery_GetLevel, any one of the item's
		// masteries meets the category). The tier category is passed no
		// lookup: no equippable row carries it.
		if err := CheckRequirements(RequirementsOf(it), c.Level, mastery, nil); err != nil {
			return fmt.Errorf("item %d: %w", it.ID, err)
		}
	}
	return nil
}

// IsBodyArmour is CGItemEquip vtable slot 39 (s:0x4834c0 -> 0x488eb0): an
// equipment row whose family is one of the six body-armour families, China's
// garment, protector and armour and Europe's robe, light and heavy armour
// (TypeID3 1, 2, 3, 9, 10, 11).
func IsBodyArmour(it *refdata.Item) bool {
	if it == nil || it.TypeID1 != TypeItem || it.TypeID2 != TypeEquipment {
		return false
	}
	switch it.TypeID3 {
	case FamilyChinaGarment, FamilyChinaProtector, FamilyChinaArmor,
		FamilyEuropeRobe, FamilyEuropeLight, FamilyEuropeHeavy:
		return true
	}
	return false
}

// IsCloth is CGItemEquip vtable slot 38 (s:0x4834e0): a garment or a robe
// (TypeID3 1 or 9) -- the body pieces that are not armour.
func IsCloth(it *refdata.Item) bool {
	return IsBodyArmour(it) && (it.TypeID3 == FamilyChinaGarment || it.TypeID3 == FamilyEuropeRobe)
}

// ArmourMixRefusal is CGObjPC::AttachEquipItem's armour test (READ,
// s:0x524cd0, after CanBeEquipedAt has passed): a body piece going into slot
// is compared with the FIRST worn armour piece (the lowest of slots 0..5,
// CGStorage::GetFirstItem(6)) through CGItemEquip::vslot_318 (s:0x4972c0),
// which accepts when either is not body armour or both are cloth or both are
// not. Refused (0x1832, ErrArmourMix) otherwise -- unless that piece is the
// only one worn and sits in slot itself, when the two simply swap. So heavy
// and light armour mix (MEASURED: a European's light armour with a robe
// piece is refused, "Armor and robe cannot be equipped at the same time.").
// worn is what is worn, by slot; a slot whose item has no reference data is
// left out.
func ArmourMixRefusal(it *refdata.Item, slot Slot, worn map[Slot]*refdata.Item) error {
	if !IsBodyArmour(it) {
		return nil
	}
	count := 0
	var first *refdata.Item
	firstSlot := Slot(-1)
	for s := SlotHelm; s <= SlotBoots; s++ {
		w := worn[s]
		if w == nil {
			continue
		}
		count++
		if first == nil {
			first, firstSlot = w, s
		}
	}
	if first == nil || !IsBodyArmour(first) || IsCloth(first) == IsCloth(it) {
		return nil
	}
	if count == 1 && firstSlot == slot {
		return nil
	}
	return fmt.Errorf("%w: item %d with item %d worn", ErrArmourMix, it.ID, first.ID)
}

// Qualifies reports whether a worn item's level and mastery requirements are
// met -- CGItemEquip::CheckEquipRequirements alone (s:0x4919e0), the test
// GObjPC::PublishEquipItemParams (s:0x4e3760) puts before an item's params
// count. mastery as Refusal's.
func Qualifies(it *refdata.Item, level int, mastery func(masteryID int) (int, bool)) bool {
	if it == nil {
		return true
	}
	return CheckRequirements(RequirementsOf(it), level, mastery, nil) == nil
}
