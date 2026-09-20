// Package cos holds the summon rules for the game's "COS" objects -- the
// pets, carts, mercenaries and guild soldiers a character can call out.
// Recovered from SR_GameServer.exe.
//
// COS is the engine's own abbreviation; every class in the family carries it
// (CGObjCOS, CGObjCOS_Pet, CGObjCOS_Cart, CGObjCOS_GoldPet, CGObjCOS_SilkPet,
// CGObjCOS_Mercenary), so it is used here rather than "pet", which names only
// two of the six.
//
// srrevamp has no COS system. This is the rule set one would be built from.
//
// See docs/protocol/pets.md.
package cos

import "errors"

// The refusal codes, with the client's name for each from
// docs/protocol/error_codes.md.
const (
	ErrCannotActivateCart  = 0x1849 // STRGERR_YOU_CANT_ACTIVATE_CART
	ErrMultipleCOS         = 0x185c // STRGERR_CANT_SUMMON_MULTIPLE_COSOBJ
	ErrHigherLevelRequired = 0x186c // STRGERR_HIGHER_LEVEL_REQUIRED_TO_USE_THISITEM
	ErrDuplicatePetType    = 0x18a9 // COS_CANT_SUMMON_DUPLICATE_PETTYPE
	ErrPetTooHighLevel     = 0x18a5 // COSPETERR_CANT_PETSUM_HIGHLEVEL
)

// MinOwnerLevel is 5: a character below it cannot use a COS summoner item at
// all, whatever the item's own requirement.
//
// Two functions enforce it independently, both through vtable slot 73
// (`+0x124`, the level getter):
//
//	CGItemCOSSummoner::vslot_307 (0x00493100):  if (level < 5) -> 0x186c
//	GObjPC::FUN_004fcef0         (0x004fcef0):  if (level < 5) -> 0x186c
//
// It is the same threshold party.MinCreatorLevel uses, which is why this reads
// as a general "past the opening" gate rather than a COS-specific number.
const MinOwnerLevel = 5

// PetRequiredLevelOffset is where a COS item's own level requirement lives:
// byte `+0x198` of its reference record. The check is
//
//	if (ownerLevel < *(byte *)(refRecord + 0x198)) -> refuse
//
// so the requirement is per-item data, not a constant. This package records
// the offset rather than a value because there is no single value to record.
const PetRequiredLevelOffset = 0x198

// Pet name length. FUN_00511bb0 validates it against the std::string size
// field:
//
//	if (len == 0 || 0xc < len) { refuse }
//
// so a pet name is 1 to 12 characters. Note this is NOT the same rule as a
// guild name, which is 2 to 12 -- the minimum differs and the maximum does not.
const (
	MinNameLength = 1
	MaxNameLength = 12
)

// ValidName reproduces the engine's check.
func ValidName(name string) bool {
	n := len(name)
	return n >= MinNameLength && n <= MaxNameLength
}

// ErrInvalidNameLength is the refusal for a name outside that range. The
// engine answers with a bare `5` here rather than a named code.
var ErrInvalidNameLength = errors.New("cos: a pet name must be 1 to 12 characters")

// GuildSoldierMinGuildLevel is 3: the COS kind handled by case 5 of
// GObjPC::FUN_004fcef0's switch calls CGuild::GetLevel and refuses below 3.
//
// That is the same threshold the fortress war requires to register
// (internal/siege.MinGuildLevel), which is worth noting but is NOT evidence
// that they are the same rule -- two checks reading one number are two checks.
const GuildSoldierMinGuildLevel = 3

// SummonRequest is what GObjPC::FUN_004fcef0 decides about, for the pet kinds
// (its switch cases 3 and 4).
type SummonRequest struct {
	OwnerLevel int
	// ItemRequiredLevel is the byte at PetRequiredLevelOffset in the summoner
	// item's reference record.
	ItemRequiredLevel int
	// HasOwner is the `*(int *)(param_1 + 0x2c) != 0` guard the level-5 floor
	// sits behind: without an owner object the floor is not applied, only the
	// item's own requirement is.
	HasOwner bool
	// SameTypeAlreadyOut is the loop over the character's active COS objects,
	// comparing type ids.
	SameTypeAlreadyOut bool
}

// CheckSummon returns 0 when the summon is permitted, or the refusal code.
//
// The order is the binary's: the two level tests are one combined condition,
// so a character who fails both is told once, and the duplicate-type scan only
// runs after the level tests pass.
func CheckSummon(r SummonRequest) int {
	if (r.HasOwner && r.OwnerLevel < MinOwnerLevel) || r.OwnerLevel < r.ItemRequiredLevel {
		return ErrHigherLevelRequired
	}
	if r.SameTypeAlreadyOut {
		return ErrDuplicatePetType
	}
	return 0
}

// Classes are the six COS classes in the binary, with their vtable addresses.
// All but CGObjCOS itself are ~403-slot IGObj descendants, which is why a COS
// object can be attacked, damaged and killed through the same paths a monster
// is.
var Classes = map[string]uint32{
	"CGObjCOS":           0x00af0c1c,
	"CGObjCOS_Cart":      0x00af127c,
	"CGObjCOS_Pet":       0x00af1a4c,
	"CGObjCOS_GoldPet":   0x00af20ac,
	"CGObjCOS_SilkPet":   0x00af270c,
	"CGObjCOS_Mercenary": 0x00af343c,
}

// Procs are the stored procedures the COS system calls, with the argument
// count from each call literal. See internal/persistence.
var Procs = map[string]int{
	"_AddNewCOS":      12,
	"_DeleteCharCOS":  3,
	"_ChangeCOSState": 2,
	"_COS_Naming":     2,
}

// The five summon kinds, and what distinguishes them.
//
// `GObjPC::CheckCanSummonCOS` (`0x004fcef0`) dispatches on
// `*(ushort *)(obj + 0x80) >> 11` -- a 16-bit packed type id shifted down by
// eleven, which is how the client reads a **TypeID4** too (`ITEM_FORMAT.md`
// records `FUN_00a5a7d0` doing exactly that to pick a weapon's animation
// group). The switch has cases 1 through 5.
//
// **Which TypeID4 this is was established by measurement, and the first answer
// was wrong.** Read as the summoner ITEM's TypeID4, the COS rows of
// `itemdata` carry 1, 2, 4, 6, 7, 9 and 12 -- not a range a five-case switch
// could cover. Read as the summoned CHARACTER's, `characterdata`'s
// `TypeID3 == 3` family runs exactly 1..5 and nothing else:
//
//	TID4  rows   code names
//	   1    63   COS_C_RUDOLPH, COS_C_UNICORN, COS_C_OSTRICH_5
//	   2    39   COS_T_LIZARD, COS_T_BEHEMOTH, COS_T_WHITEELEPHANT_20
//	   3  1260   COS_P_WOLF_001 ...
//	   4    11   COS_P_MYOWON, COS_P_SEOWON, COS_P_RABBIT
//	   5  2100   COS_GUILD_CH_SOLDIER1_001 ...
//
// The engine's own refusals agree with that split from the other side, which
// is what makes it a reading rather than a correlation: cases 1 and 2 refuse
// with `STRGERR_YOU_CANT_ACTIVATE_CART`, cases 3 and 4 with
// `COS_CANT_SUMMON_DUPLICATE_PETTYPE`, and case 5 with
// `GUILD_SOLDIER_SAME_SUMMON_LIMIT` after a guild-level test. Two independent
// witnesses, the table's names and the binary's error strings.
//
// What separates 1 from 2, and 3 from 4, is NOT named here. The code prefixes
// differ (`COS_C_` vs `COS_T_`, and a 1,260-row `COS_P_WOLF` family against an
// eleven-row one) and the engine treats each pair identically in this
// function, so the distinction lives somewhere this pass did not read.
const (
	KindCOS_C     = 1 // COS_C_* -- shares the cart refusal with KindCOS_T
	KindCOS_T     = 2 // COS_T_*
	KindPetWolf   = 3 // COS_P_*, the 1,260-row family
	KindPetSmall  = 4 // COS_P_MYOWON / SEOWON / RABBIT, eleven rows
	KindGuildCOS  = 5 // COS_GUILD_CH_SOLDIER*
	KindCOSFamily = 3 // the TypeID3 every one of them carries
)

// SummonKindIsCart reports whether a kind takes the cart refusal path
// (`ErrCannotActivateCart`) rather than the pet or guild one.
func SummonKindIsCart(typeID4 int) bool { return typeID4 == KindCOS_C || typeID4 == KindCOS_T }

// SummonKindIsPet reports whether a kind takes the pet path, where a duplicate
// of the same type is refused with ErrDuplicatePetType.
func SummonKindIsPet(typeID4 int) bool { return typeID4 == KindPetWolf || typeID4 == KindPetSmall }

// SummonKindIsGuild reports whether a kind takes the guild path, which also
// tests the guild's level.
func SummonKindIsGuild(typeID4 int) bool { return typeID4 == KindGuildCOS }
