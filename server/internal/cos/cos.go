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

// Pet growth, read from CGObjCOS_GoldPet::OffsetExpPoint (0x004d6370) on
// 2026-09-20. Only the GOLD pet has this method; the silk pet has no
// experience method at all (docs/protocol/pets.md).
//
// The function has **two paths**, and which one a gain takes is the whole
// rule. The choice is made on the pet's level byte (its data record +0x58)
// against two things:
//
//		4d641b  cmp byte [pet+0x58], 0x6e     ; 110
//		4d641f  jae  <clamp path>             ; at 110 or above -> never levels
//		4d642f  call [owner + 0x124]          ; the owner's GetLevel
//		4d6431  cmp byte [pet+0x58], al
//		4d6434  jb   <level-up path>          ; below the owner -> may level
//
//	  - CLAMP path: experience is added and then held at `threshold - 1`, the
//	    function recomputing the delta to match. The pet keeps gaining but can
//	    never cross into the next level.
//	  - LEVEL-UP path: experience is added and, while it reaches the level's
//	    threshold, the threshold is subtracted and the level incremented -- a
//	    real loop (`jmp 0x4d65f1`), so one gain can carry several levels. It is
//	    guarded by the pet's own GetLevel against 0x8c = 140.
//
// So a gold pet levels only while it is **below its owner's level** and below
// 110; at or past either it still accumulates experience but stops advancing.
// The thresholds are per level and come from a reference row (`this+0x1ce0`,
// +8/+0xc as a 64-bit), not from any constant here, and experience itself is
// 64-bit at the pet's data record +0x60/+0x64.
//
// Those rows are **the same per-level table the character's own level uses**:
// `GObjPC::GObjPC_SetLevel` indexes the identical vector with `level - 1` and
// keeps the row on the character at `+0x1cb0` (round 293). By
// `docs/protocol/refdata_tables.md`'s enumeration that is `_REFLEVEL` /
// `leveldata.txt`, which this server already loads as `leveldata.csv`.
//
// And the column is settled (round 294): `GObjPC_GainExpAndLevel` reads the
// character's own row at the same `+8`/`+0xc` 64-bit pair, and the character's
// exp-to-next is **column 1** -- the value `docs/LEVELING.md` matched against a
// real level-9 character's 17,978. So a pet's level-up threshold is
// `leveldata.Table.ExpToNext`, the curve this server already has; nothing new
// needs loading.
const (
	// PetLevelUpBoundary is the 110 at 0x4d641b. At or above it the clamp
	// path is taken unconditionally. Named for what the code does with it
	// rather than "the cap", because the cap the other path tests is 140.
	PetLevelUpBoundary = 110
	// PetMaxLevel is the 0x8c the level-up path tests the pet's own level
	// against before doing anything.
	PetMaxLevel = 140
)

// PetLevelsUp reports whether a gold pet's experience gain takes the level-up
// path rather than the clamp path.
func PetLevelsUp(petLevel, ownerLevel int) bool {
	if petLevel >= PetLevelUpBoundary {
		return false
	}
	return petLevel < ownerLevel
}
