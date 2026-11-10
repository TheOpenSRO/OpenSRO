// Package character implements this server's own character
// creation/selection model — an independent design, not a port of any
// original schema. See docs/protocol/db_schema.md for the facts it's
// informed by (a character belongs to an account; character names are
// unique) and docs/protocol/PROTOCOL_DECISION.md for why this doesn't try
// to match the original data model.
package character

import (
	"context"
	"errors"
	"math"
	"sync"
	"time"
)

// MaxPerAccount caps how many characters one account may have: **4**, READ
// (round 682, docs/protocol/charselect.md section 2) -- the client refuses
// Create at four with "A maximum of 4 characters can be created per account."
// (0x85de50), and SR_ShardManager's create refuses a fifth with 0x405
// (charselect.md section 5, "Create on the server", check 2).
// The user chose retail's 4 (2026-10-02).
//
// This used to be 3 under a note saying the limit "is not recoverable from the
// artifact this project has", because SR_GameServer.exe carries no
// character-creation path. That was true of the GameServer and the wrong
// binary to ask: creation is the ShardManager's (0x7007 -> 0x40f010), which
// the server package on the render box holds.
const MaxPerAccount = 4

// ErrNameTaken is returned by Store.Create when the requested character
// name is already in use (names are unique server-wide, not just per
// account — matches the "_IsExistingCharName"-style global uniqueness check
// found during RE, documented in db_schema.md).
var ErrNameTaken = errors.New("character: name already taken")

// ErrAccountFull is returned by Store.Create when the owning account
// already has MaxPerAccount characters.
var ErrAccountFull = errors.New("character: account already has the maximum number of characters")

// ErrNotFound is returned by Store.Delete when no character with the given
// ID exists for the given account (either it doesn't exist at all, or it
// belongs to a different account — same error either way, so callers can't
// use it to enumerate other accounts' character IDs).
var ErrNotFound = errors.New("character: no such character on this account")

// ErrInsufficientGold is returned by Store.DeductGold when the character
// doesn't have enough to cover the requested amount.
var ErrInsufficientGold = errors.New("character: insufficient gold")

// StartingGold is how much currency a newly-created character has. Own
// design choice (OURS). This package's `_AddNewChar` (EXTERNAL, round 692)
// writes RemainGold 2,000,000 and RemainSkillPoint 5,000,000 -- a private
// shard's values, INFERRED modded (the operator demonstrably edited that same
// INSERT: a commented-out level-110 variant sits beside it), and not adopted:
// charselect.md section 8 has it as a decision for the user.
const StartingGold = 1000

// Health and mana are the game's own formula. RECOVERED, in full.
//
// SR_GameServer.exe does not compute stats with arithmetic in a function. It
// builds a dependency graph of named parameters in a class the binary calls
// GParamKeeper (it says so in its own assert string), and GObjPC_InitStats
// declares the player's whole graph in one go: thirty edges, each a
// `ParamKeeper_BindDerived(source, target, slot)`. Two of those chains are
// health and mana:
//
//	Str(1) -> 52 -> 54 -> MaxHP(3)
//	Int(2) -> 53 -> 55 -> MaxMP(4)
//
// 1000.0 is pushed into slot 3 of params 52 and 53, and 1.02^(level-1) * 100
// into slot 3 of 54 and 55. The keeper evaluates one node as
// `slot0 * (slot1+100)/100 * slot2 * slot3/100`, with slot 3 defaulting to 100,
// so each chain collapses to `stat * (1000/100) * 1.02^(level-1)`.
//
// Reading that out of the binary took undoing two layers. The parameter's
// identity travels in DI, which Ghidra never assigned to an argument, so all
// 297 call sites decompiled to `SetParam(slot, 0, value)` with the identity
// silently gone. And the callers never load the id with MOV -- the optimiser
// materialises each one from whichever register already holds a nearby
// constant, as a ping-pong of LEAs (`LEA EDI,[EBX+0x33]` / `LEA EBX,[EDI-0x32]`
// ...), so nothing is written down to grep for. See
// client/tools/ghidra/ResolveRegArg.java, which resolves the chains.
//
// The binary holds no id->name table -- the enum was compile-time only -- so
// each id is earned from its use sites:
//
//   - 3 and 4 are MaxHP and MaxMP because GObjMob_PublishStats pushes
//     refobj+0x19c and +0x1a0 at them, and +0x19c is the field that
//     RefObjChar_ExtractData asserts `m_dwMaxHP > 0` on.
//   - 0, 1 and 2 are Level, Str and Int because GObjPC_InitStats pushes
//     charData+0x65, +0x74 and +0x76 at them; and 0 is confirmed Level a second
//     time by the monster path pushing its level virtual at the same id.
//
// This supersedes the old own-design `100 + 40*(level-1)` health curve and the
// disclosed `MPBase = 100`. Both are gone: the base was never a constant, it
// was the stat.
const (
	// HPPerStr and MPPerInt are the 1000.0 at .rdata 0x00b462ac, applied by
	// the keeper as a percent scale and so worth ten points of health per
	// point of the stat.
	HPPerStr = 10
	MPPerInt = 10
	// StatGrowth is .rdata 0x00b45ea0, raised to (level-1) by binary
	// exponentiation in GObjPC_InitStats and pushed as a percent scale.
	//
	// RE-VERIFIED FROM ASM 2026-09-18, at the two points it could have been
	// wrong (the floor-band bug was a value read one operand off, so the whole
	// pipeline was re-audited). In GObjPC_InitStats: 0x4e35f6 calls GetLevel
	// (vtable 0x124), 0x4e3601 `sub eax,0x1` -- the exponent is level-1, not
	// level -- and the 1000 at 0x4e32ca/0x4e32e0 is pushed into slot 3 (the
	// SCALE slot, edi=3 at the SetParam call), which ParamKeeper_EvaluateParam
	// divides by 100, so a point of the stat is worth ten of the pool, not a
	// thousand. Both `stat*10` and `1.02^(level-1)` confirmed.
	StatGrowth = 1.02
)

// RespawnFraction is how much of its maximum a character gets back when it
// comes back from death: **40%**, not full.
//
// RECOVERED. The PC create/load path (CGObjPC::vslot_212, the function whose
// error string is "CheckEquipsetIntegrity() failed while Creating PC") calls
// GObjPC::FUN_004e1120, which restores a character whose STORED pool is zero --
// which is the state death leaves it in:
//
//	if (charData->vf[0x38]() == 0) {              // stored HP is zero
//	    hp = GetParam(3) * _DAT_00b460f0;          // MaxHP * 0.4
//	    charData->vf[0x40](hp);
//	}
//	if (charData->vf[0x3c]() == 0) {              // and the same for MP
//	    mp = GetParam(4) * _DAT_00b460f0;          // MaxMP * 0.4
//	    charData->vf[0x44](mp);
//	}
//
// The constant is `FMUL QWORD PTR ds:0xb460f0` at 0x004e1141 and 0x004e1190 --
// a QWORD, so a double: the bytes `00 00 00 a0 99 99 d9 3f` are
// 0x3FD99999A0000000 = 0.4000000059604645, the FLOAT 0.4 widened to a double
// (the exact double 0.4 would end ...999A; round 550 corrected the "double
// 0.4" wording here and in the records). At float width the same address
// reads -1.08e-19, which would resurrect every character on a negative sliver
// of health; only the double is coherent. Operand size has decided four
// constants in this project now. RespawnFraction is the exact 0.4 rather than
// that value, and for a pool it makes no difference: every use truncates
// (int() here, FLOOR in the SQL store, the handler's own fistp under rounding
// control 11 at 0x510122 on its death-cause-2 path and 0x5101c6 on option 2's
// -- session/deadstate.go's header), and for an integer maximum m the fractional part
// of 0.4 x m is one of 0, .2, .4, .6, .8, so the extra 5.96e-9 x m cannot
// cross an integer below m = 33 million.
//
// This does NOT apply to a level-up. Nothing in the level path zeroes the
// stored pool, so the branch above never fires there and a level-up heals to
// full -- which is why ResetHP and RespawnHP are separate calls.
const (
	RespawnFraction = 0.4
)

// StartingStr and StartingInt are a new character's stats: 20 and 20.
//
// READ in round 692 (this package's `_AddNewChar`, the shard DB's procedure;
// EXTERNAL): its INSERT INTO _Char writes Strength 20, Intellect 20, CurLevel
// 1, HP 200 and MP 200 -- the two numbers this project had chosen as its own
// (they were OWN DESIGN until then; the history below is why). The same
// procedure carries the shard operator's commented-out level-110 variant
// with Strength and Intellect 129, which is 20 + 109 * StatGrowthPerLevel: it
// agrees. 20 apiece puts a level-1 character on 200 health and 200 mana, the
// HP and MP the procedure stores. docs/protocol/charselect.md section 5,
// "_AddNewChar, read".
//
// The rest of this comment is the record from before the procedure was read:
// SR_GameServer.exe does not contain them: nothing writes a constant to
// charData+0x74 or +0x76 anywhere in it, because character creation happened on
// the database side, which this project had no artifact of.
//
// THE ABSENCE IS NOW MEASURED, NOT INFERRED (2026-09-16). It used to rest on one
// binary's silence, which is the weaker kind of negative -- and these two numbers
// matter far more since StatGrowthPerLevel shipped, because every level
// multiplies them. Three artifacts were asked, and none of them holds a starting
// stat:
//
//   - characterdata's PLAYER rows. 78 rows match CHAR_(CH|EU)_(MAN|WOMAN), and
//     **zero of them carry a non-zero MaxHP (col 59)** -- the column that would
//     give Str away, since MaxHP is Str*10 at level 1. There is no bare
//     CHAR_CH_MAN row at all; the player rows are class and appearance variants.
//
//   - the client's character-creation screen. Its strings are UIO_NEWCHAR_*, and
//     they are race, gender, class and _EXPLANATION text. It previews an
//     appearance, not a stat line, so there is no formula in the client either.
//
//   - LevelData.txt. Nine columns, none of them a stat: level, exp, mastery cost,
//     two zero columns, the kill-exp unit, and a triple of large identical values
//     (see the note below).
//
//   - **the GameServer's own stored-procedure list (2026-09-17).** This is the
//     structural one, and it is stronger than the other three because it does
//     not depend on having looked in the right place. The binary names **71**
//     stored procedures across all three call forms, plus five `trs_sm_*job`
//     wrappers, covering every persistence operation it performs: `_AddNewCOS`
//     creates a pet, the `_STRG_ADD_*` family creates every kind of item,
//     `_SiegeFortress*` run a siege, `_AssignNickName` renames, `_skill_manage`
//     and `_quest_manage` persist progress. **None of them creates a
//     character.** So character creation is not a GameServer operation at all,
//     and no amount of further searching in this binary can turn one up.
//
//     The count was re-measured 2026-09-17 (this comment said 75, and
//     persistence.Procs held 39; both were wrong, in opposite directions). The
//     re-measurement STRENGTHENS the argument rather than weakening it: the
//     enumeration now includes the `_STRG_ADD_*` family, so the binary demonstrably
//     has a procedure for creating an item and still has none for creating a
//     character. See docs/protocol/persistence.md.
//
//   - **a fifth, at the machine level (2026-09-17).** `CharData_BindDBColumns`
//     binds `"Strength"` to charData `+0x74` and `"Intellect"` to `+0x76`
//     literally. Scanning every word-sized store to those two offsets across the
//     whole image, the only ones that touch charData are inside `GObjPC::SetStr`
//     and `GObjPC::SetInt` (the other hits are unrelated structs -- quest
//     handlers, navmesh, COS). Those two appear in **0 vtable slots**, so there
//     is no virtual path to them, and their **only** caller is
//     `GObjPC_SpendStatPoints`, which refuses unless `str+int <= pool` and only
//     ever ADDS. So the binary never assigns a starting Strength; it only ever
//     increments one it loaded.
//
// So the value stayed own-design, on four measurements rather than one silence
// -- until round 692 read it in the database procedure, where those
// measurements said it had to be.
//
// WHERE NOT TO LOOK, corrected 2026-09-17. docs/RE_COMPLETION.md named
// `_REFCHARGEN` as "the table that would hold them". It is not.
// `CRefCharGen__AddEntry` (`0x006a29a0`) takes an ObjID, resolves it to a
// RefObj, reads that object's **Country** (`+0x88`, the common table's column
// 14) and the flag bits at `+0x80`, and files the entry in a per-country list.
// `_REFCHARGEN` is the **roster of selectable characters** -- which models a
// player may create -- not a stat table. Obtaining it would not answer this.
const (
	StartingStr = 20
	StartingInt = 20
)

// StatGrowthPerLevel is how much Str and Int each rise by on every level,
// automatically and without the player choosing.
//
// REAL, from GObjPC_SetLevel (`0x004e4d90`), which grants five stat points and
// then calls GObjPC_SpendStatPoints(levels, levels) -- spending two of them on
// the character's behalf. The spend is a plain increment, and the disassembly
// leaves no room for reading it otherwise:
//
//	movzx ecx,WORD PTR [eax+0x74]   ; current Str
//	add   cx,si                     ; + the amount being spent
//	call  0x51dc00                  ; SetStr(Str + amount)
//
// with the Int half the same against +0x76, and ParamKeeper param 1 (Str)
// republished afterwards -- which independently agrees with
// combat.ParamFor[TagStr] == 1, recovered from the tag dispatcher.
//
// THIS IS WHY A LEVEL-40 CHARACTER IS NOT A LEVEL-1 ONE WITH MORE HEALTH.
// MaxHPFor is Str * 10 * 1.02^(level-1): the exponential term is the smaller
// half of the growth, and the Str term is the larger. OpenSRO held Str and Int
// fixed for a character's whole life until 2026-09-16, which left a level-40
// character on roughly a third of the health the real game gives one.
const StatGrowthPerLevel = 1

// StartingMaxHP and StartingMaxMP are what those give at level 1, where the
// growth term is 1.
const (
	StartingMaxHP = StartingStr * HPPerStr
	StartingMaxMP = StartingInt * MPPerInt
)

// MaxHPFor is a character's maximum health: Str * 10 * 1.02^(level-1).
func MaxHPFor(str, level int) int { return derivedStat(str, HPPerStr, level) }

// MaxMPFor is a character's maximum mana: Int * 10 * 1.02^(level-1).
func MaxMPFor(intel, level int) int { return derivedStat(intel, MPPerInt, level) }

// derivedStat walks one of the keeper's stat chains: the stat scaled by its
// per-point constant, then compounded by the level growth.
func derivedStat(stat, perPoint, level int) int {
	if level < 1 {
		level = 1
	}
	if stat < 0 {
		stat = 0
	}
	// TRUNCATED (round 875, MEASURED): a level-110 character's max HP reads
	// 39480 at Str 456 (39480.58), 42510 at Str 491 (42510.89) and its max MP
	// 14199 at Int 164 -- rounding gave 39481 and 42511.
	return int(float64(stat) * float64(perPoint) * math.Pow(StatGrowth, float64(level-1)))
}

// HighestLevel is the character's max level, _CHAR.MaxLevel (round 874):
// MaxLevel, or Level for a row from before it was kept.
func (c *Character) HighestLevel() int {
	return max(c.MaxLevel, c.Level)
}

// LevelsRewarded is how many levels of a rise from `from` to `to` pay their
// stat points, Str and Int: those above the max level `maxLevel` only (round
// 874). READ, GObjPC_SetLevel s:0x4e4d90: the grant runs inside `if
// (charData+0x66 < newLevel)` -- MaxLevel below the new level -- with
// levels = newLevel - MaxLevel, and MaxLevel takes the new level there
// (s:0x4e4e9e..0x4e4f20: +0x84 += levels x 5, SpendStatPoints(levels) =
// Str += levels, Int += levels). MEASURED: a character at level 19 with max
// level 70 keeps Str 89, Int 89 and its 207 points through its level changes.
func LevelsRewarded(from, to, maxLevel int) int {
	return max(to-max(from, maxLevel), 0)
}

// StartingLevel is the level a newly-created character is. There is no
// way to gain a level yet -- experience is not tracked -- so every
// character stays at it; what the level is *for* today is the item table's
// own "required level" column, which equipment checks against it.
const StartingLevel = 1

// Gender names a character's race and sex, the string the world wire still
// carries (EntitySnapshot.Gender, EnterWorldResult.Gender) beside the model
// for an older client. Since round 682 it is DERIVED from the body the
// character was made from (GenderFor of the model's race and sex), not chosen
// on its own; since round 689 (charselect.md lane W) the world messages carry
// RefObjID and Scale too, in trailing tails, and the client draws the body
// from them.
//
// CORRECTED (round 682): this note used to say Europe's base body meshes were
// not present in the available client data, so only China was offered. That
// was wrong. Data.pk2 holds all 26 `Res\Char\Europe\europe(wo)man_*.bsr` bodies
// and the `Prim\Ani\Char\Europe\` clips (MEASURED with pk2list,
// docs/protocol/charselect.md "Corrections"). Europe is offered now (the
// user's decision, 2026-10-02); a client before round 689 knows only the two
// China strings and falls back to its default body for the two Europe ones
// (World3D's DEFAULT_GENDER); a round-689 client reads the model instead.
const (
	GenderChinaMan    = "china_man"
	GenderChinaWoman  = "china_woman"
	GenderEuropeMan   = "europe_man"
	GenderEuropeWoman = "europe_woman"
)

// DefaultGender is used when a character is created without an explicit
// (or a not-recognized) gender choice.
const DefaultGender = GenderChinaMan

// Race values: an object's Country (refobj +0x88, textdata column 14).
const (
	RaceChina  = 0
	RaceEurope = 1
)

// Sex values: refobj +0x1c4 (textdata column 58): 1 a man, 0 a woman (READ,
// the create screen's list builder 0x80b980; MEASURED on the 52 bodies).
const (
	SexWoman = 0
	SexMan   = 1
)

// GenderFor is the Gender string of a body of race and sex.
func GenderFor(race, sex int) string {
	switch {
	case race == RaceEurope && sex == SexMan:
		return GenderEuropeMan
	case race == RaceEurope:
		return GenderEuropeWoman
	case sex == SexMan:
		return GenderChinaMan
	default:
		return GenderChinaWoman
	}
}

// RaceOf and SexOf read a Gender string back.
func RaceOf(gender string) int {
	if gender == GenderEuropeMan || gender == GenderEuropeWoman {
		return RaceEurope
	}
	return RaceChina
}

func SexOf(gender string) int {
	if gender == GenderChinaWoman || gender == GenderEuropeWoman {
		return SexWoman
	}
	return SexMan
}

// The bodies existing characters are migrated to, and what the old create
// path (Store.Create, which tests use) makes: CHAR_CH_MAN_FIGHTER and
// CHAR_CH_WOMAN_FIGHTER, the bodies World3D.GENDER_BODY_CODE draws for the two
// China strings today -- so a migrated character looks as it did (OURS,
// round 682; the user accepted it 2026-10-02).
const (
	ModelChinaManFighter   int64 = 1909
	ModelChinaWomanFighter int64 = 1923
)

// LegacyModelFor is the body a character with only a Gender string is given.
func LegacyModelFor(gender string) int64 {
	if gender == GenderChinaWoman {
		return ModelChinaWomanFighter
	}
	return ModelChinaManFighter
}

// DefaultScale is the scale byte a new character starts with and every
// existing one is migrated to: Height 2 (low nibble) and Volume 2 (high
// nibble), both sliders' middle (READ, the create screen's start values,
// 0x84d040 / 0x84d070). See ScaleHeight/ScaleVolume.
const DefaultScale = 0x22

// ScaleHeight and ScaleVolume split a scale byte: Height is the low nibble and
// Volume the high one, each 0..4 (READ, charselect.md section 2).
func ScaleHeight(scale int) int { return scale & 0x0f }
func ScaleVolume(scale int) int { return (scale >> 4) & 0x0f }

// ValidScale reports whether both nibbles are in the create sliders' 0..4.
func ValidScale(scale int) bool {
	return scale >= 0 && scale <= 0xff && ScaleHeight(scale) <= 4 && ScaleVolume(scale) <= 4
}

// DeleteDelay is how long a deleted character waits, restorable, before it is
// removed: 7 days, 10080 minutes. READ from the client, whose confirm text says
// "reserved for 7 days" and whose countdown gauge is 1 - remaining / 10080
// (charselect.md section 2). The user chose it (2026-10-02). The shard DB's
// procedures agree (READ round 692, this package's; EXTERNAL):
// `_DeleteCharTemporal` only stamps the date (`_DeletedChar`, GetDate()) and
// sets Deleted 1, and `_DeleteCharPermanently` refuses a character deleted
// less than 6 days 23 hours ago ("roughly 7 days ... an hour's error is
// allowed", its comment) -- so the 7 days themselves are the caller's timer,
// with the procedure as a guard an hour short of it.
const DeleteDelay = 10080 * time.Minute

// MinutesLeft is what the list record says of a character pending deletion:
// (purge time - now) in whole minutes, at least 1 (READ ShardManager: "(stored
// date - now) seconds / 60, at least 1"). 0 for a character not deleting.
func (c *Character) MinutesLeft(now time.Time) uint32 {
	if c.DeletedAt.IsZero() {
		return 0
	}
	left := int64(c.DeletedAt.Add(DeleteDelay).Sub(now) / time.Second / 60)
	if left < 1 {
		left = 1
	}
	return uint32(left)
}

// Deleting reports whether the character is pending deletion.
func (c *Character) Deleting() bool { return !c.DeletedAt.IsZero() }

// Character is one player character.
type Character struct {
	ID        int64
	AccountID int64
	Name      string
	Gold      int64
	HP        int
	Gender    string
	Level     int
	// MaxLevel is the highest level the character has reached, the engine's
	// _CHAR.MaxLevel (charData +0x66, docs/protocol/db_bind_offsets.tsv;
	// round 874). A death can take a level away (leveldata.LoseExp) and
	// MaxLevel stays: GObjPC_SetLevel (s:0x4e4d90) grants a level's stat
	// points, Str and Int only for levels above it, so a level lost and
	// regained pays nothing twice. 0 on a row written before round 874 -- read
	// it through HighestLevel, never directly.
	MaxLevel int
	// Exp is progress accumulated at the current level (it resets on a
	// level-up), against leveldata's exp-to-next for Level. StatPoints is the
	// unspent points earned by leveling (leveldata.StatPointsPerLevel each).
	// Spending them into Str/Int is the separate stat system, still to come.
	Exp        int64
	StatPoints int
	// Str and Int are the two spendable stats. They are what health and mana
	// are derived from -- see MaxHPFor/MaxMPFor, which is the game's own
	// formula, so these are not cosmetic.
	Str int
	Int int
	// StorageGold is gold kept in the NPC warehouse, separate from the Gold
	// the character carries. Moved between the two by the storage service.
	StorageGold int64

	// HwanCount is the berserk orbs the character is holding, 0..berserk.Orbs.
	//
	// GROUNDED as a persisted column. `_CHAR.RemainHwanCount` is bound by
	// `CInstancePC::CharData_BindDBColumns` to charData `+0x86`
	// (docs/protocol/db_bind_offsets.tsv, an offset verified twice over -- from
	// the decompilation and again from raw disassembly). The engine keeps the
	// count in the character row, so it survives a logout; OpenSRO used to drop
	// it on disconnect and said so in berserk.Tracker's comment.
	//
	// The orbs are earned on a killing blow and spent five at a time on
	// activation -- see internal/berserk, where the rates are recovered.
	HwanCount int

	// Zone, Frame and PosX/PosY/PosZ are where the character last stood in
	// the world, written by session under cmd/server's -persist-position
	// (round 573) and read back when it enters again. Zone "" means nothing
	// is saved -- a new character, or one that has not been in the world
	// with the flag on -- and it enters at the zone spawn as it always has.
	//
	// GROUNDED as persisted columns: `_CHAR.LatestRegion` and
	// `PosX`/`PosY`/`PosZ` are bound by CharData_BindDBColumns to charData
	// +0x94, +0x98, +0x9c and +0xa0 (docs/protocol/db_bind_offsets.tsv), so
	// the engine keeps the position on the character row. The SHAPE is
	// OpenSRO's own (schema.go's Mapping says how): the engine's position is
	// local to LatestRegion, OpenSRO's is a world point in the frame centred
	// on region Frame ("x/y", the FrameRegion the session named -- see
	// worldmap.ToWorld), plus the zone label the client builds its grid from.
	// When the save happens is OpenSRO's own too (session/position.go).
	Zone             string
	Frame            string
	PosX, PosY, PosZ float64

	// RefObjID is the body the character was made from (_CHAR.RefObjID), one
	// of the creatable catalogue's models; Scale its scale byte (_CHAR.Scale,
	// Height low nibble, Volume high). Round 682; existing rows are migrated
	// to LegacyModelFor(Gender) at DefaultScale.
	RefObjID int64
	Scale    int
	// DeletedAt is when the character was deleted, zero when it is not
	// pending deletion. It is removed DeleteDelay later and can be restored
	// until then (round 682; the engine's `_CHAR.Deleted` plus the date
	// `_DeleteCharTemporal` stores, charselect.md section 2).
	DeletedAt time.Time
	// StartZone and StartX/Y/Z are where the character enters the world while
	// it has no saved position: its race's start spawn, picked at creation
	// (READ, ShardManager FUN_0042bb20; session.StartSpawns), as a zone label
	// and a world point in that zone's frame. "" for a character made before
	// round 682, which enters at the zone spawn as it always has.
	StartZone              string
	StartX, StartY, StartZ float64
}

// MaxHP is this character's maximum health: the Str chain at its TOTAL Str
// (its own plus its worn items' 'str' options) and level, plus the items'
// flat 'hp' options (round 769: ParamKeeper slot 0 sums, so param 1 is the
// character's Str plus each item's, and param 3's base is chain(54) plus each
// item's 'hp'; the level growth multiplies the item Str but not the item HP.
// READ, gs EvaluateParam 0x4b3210, FUN_004b2e60, GObjPC_SetLevel 0x4e51d2).
func (c *Character) MaxHP() int { return MaxHPWith(c.Str, c.Level, BonusOf(c.ID)) }

// MaxMP is MaxHP's twin over Int and the 'mp' options.
func (c *Character) MaxMP() int { return MaxMPWith(c.Int, c.Level, BonusOf(c.ID)) }

// MaxHPWith is MaxHP for a base Str, a level and a bonus.
//
// Round 785: a buff's percent (param 3 slot 1, 'hpi' value[1]) scales the
// whole: EvaluateParam's S0 x (1 + S1/100), READ 0x4b3740.
func MaxHPWith(str, level int, b Bonus) int {
	base := MaxHPFor(str+b.Str, level)
	if b.StrHPPct != 0 {
		base = chainPct(str+b.Str, HPPerStr, level, b.StrHPPct)
	}
	return scaleOf(scalePct(base+b.HP, b.HPPct), b.HPScale)
}

// MaxMPWith is MaxMP for a base Int, a level and a bonus.
func MaxMPWith(intel, level int, b Bonus) int {
	base := MaxMPFor(intel+b.Int, level)
	if b.IntMPPct != 0 {
		base = chainPct(intel+b.Int, MPPerInt, level, b.IntMPPct)
	}
	return scaleOf(scalePct(base+b.MP, b.MPPct), b.MPScale)
}

// scaleOf is v x scale/100, truncated and at least 1; v itself for a scale
// of 0 (none) or 100. Round 881: EvaluateParam's last factor, the slot-3
// entries compounding from 100, which a panic (max HP) or a combustion (max
// MP) writes as max(100 - value[3], 1) (statuseffect's effects.go).
func scaleOf(v int, scale float64) int {
	if scale == 0 || scale == 100 {
		return v
	}
	out := int(float64(v) * scale / 100)
	if out < 1 {
		out = 1
	}
	return out
}

// chainPct is the stat chain with a percent on its middle param (round 838:
// a devil's spirit's 'hpna' / 'mpna', p52 / p53 slot 1): p52 = Str x 10 x
// (1 + pct/100), then p54 = p52 x 1.02^(level-1), unrounded (READ
// GObjPC_InitStats 0x4e3294..0x4e3664 binds Str -> p52 -> p54 -> p3;
// EvaluateParam 0x4b3210 applies S0 x (S1 + 100) / 100, then slot 3's
// scale). Without one it is derivedStat as before.
func chainPct(stat, perPoint, level int, pct float64) int {
	if pct == 0 {
		return derivedStat(stat, perPoint, level)
	}
	if level < 1 {
		level = 1
	}
	v := float64(stat*perPoint) * (pct + 100) / 100 * math.Pow(StatGrowth, float64(level-1))
	return int(v)
}

// scalePct is v x (1 + pct/100), truncated; v itself for no percent.
func scalePct(v int, pct float64) int {
	if pct == 0 {
		return v
	}
	out := int(float64(v) * (1 + pct/100))
	if out < 1 {
		out = 1
	}
	return out
}

// TotalStr is the character's Str with its worn items' 'str' options: param 1,
// the number the character panel shows (round 769, READ: the 0x303D builder
// sends round(GetParam(1)), CIFPlayerInfo prints it with one "%d").
func (c *Character) TotalStr() int { return c.Str + BonusOf(c.ID).Str }

// TotalInt is TotalStr's twin over Int and the 'int' options.
func (c *Character) TotalInt() int { return c.Int + BonusOf(c.ID).Int }

// Bonus is what a character's worn items add through their blue options
// (round 769): the flat 'str', 'int', 'hp' and 'mp' sums
// (Stat_ApplyTaggedModifier 0x498690 writes each into slot 0 of params 1, 2,
// 3 and 4 with the item as its context), and the 'evbl' / 'evcr' sums
// (params 56 / 57, clamped at 100), cached here so a blow does not read the
// worn items each time (the review's F5).
type Bonus struct {
	Str, Int, HP, MP      int
	EvadeBlock, EvadeCrit int
	// HPPct and MPPct are the buffs' percent entries of params 3 and 4
	// (round 785); the gear writes none.
	HPPct, MPPct float64
	// StrHPPct and IntMPPct are params 52 and 53's percent entries (round
	// 838: a devil's spirit's 'hpna' / 'mpna'), which scale the Str / Int
	// chain before the level growth (chainPct).
	StrHPPct, IntMPPct float64
	// HPScale and MPScale are params 3 and 4's scale entries in percent
	// (round 881: a panic's, a combustion's); 0 is none.
	HPScale, MPScale float64
}

// add is b with o's entries summed in.
func (b Bonus) add(o Bonus) Bonus {
	b.Str += o.Str
	b.Int += o.Int
	b.HP += o.HP
	b.MP += o.MP
	b.EvadeBlock += o.EvadeBlock
	b.EvadeCrit += o.EvadeCrit
	b.HPPct += o.HPPct
	b.MPPct += o.MPPct
	b.StrHPPct += o.StrHPPct
	b.IntMPPct += o.IntMPPct
	b.HPScale = joinScale(b.HPScale, o.HPScale)
	b.MPScale = joinScale(b.MPScale, o.MPScale)
	return b
}

// joinScale compounds two scale entries (0: none).
func joinScale(a, b float64) float64 {
	switch {
	case a == 0:
		return b
	case b == 0:
		return a
	}
	return a * b / 100
}

// liveBonus is the part of a character's bonus that changes with no event
// the cache could hear (round 785: its buffs, which start and expire on
// their own clocks), added to the cached gear bonus on every read.
var liveBonus func(characterID int64) Bonus

// SetLiveBonusSource registers the uncached part of BonusOf (nil: none).
func SetLiveBonusSource(f func(characterID int64) Bonus) {
	bonusMu.Lock()
	liveBonus = f
	bonusMu.Unlock()
}

// The bonus registry. The worn items live in the equipment store, which a
// Character does not know; session registers the source (SetBonusSource) and
// clears a character's entry whenever its worn items change
// (InvalidateBonus), and BonusOf computes it again on the next read.
var (
	bonusMu     sync.RWMutex
	bonusCache  = map[int64]Bonus{}
	bonusGen    = map[int64]uint64{}
	bonusEpoch  uint64
	bonusSource func(characterID int64) (Bonus, bool)
)

// SetBonusSource registers how a character's bonus is computed (ok false
// when it could not be read, which is not cached), and forgets every cached
// one. nil: no character has a bonus.
func SetBonusSource(f func(characterID int64) (Bonus, bool)) {
	bonusMu.Lock()
	defer bonusMu.Unlock()
	bonusSource = f
	bonusCache = map[int64]Bonus{}
	bonusEpoch++
}

// InvalidateBonus forgets a character's bonus: its worn items changed.
func InvalidateBonus(characterID int64) {
	bonusMu.Lock()
	delete(bonusCache, characterID)
	bonusGen[characterID]++
	bonusMu.Unlock()
}

// BonusOf is a character's bonus, computed by the registered source when it is
// not cached. The source runs outside the lock (it reads the stores); its
// result is cached only when it read cleanly and nothing invalidated the
// character, or replaced the source, meanwhile.
func BonusOf(characterID int64) Bonus {
	bonusMu.RLock()
	live := liveBonus
	bonusMu.RUnlock()
	b := gearBonusOf(characterID)
	if live != nil && characterID != 0 {
		b = b.add(live(characterID))
	}
	return b
}

// gearBonusOf is the cached part of BonusOf.
func gearBonusOf(characterID int64) Bonus {
	bonusMu.RLock()
	b, ok := bonusCache[characterID]
	src, gen, epoch := bonusSource, bonusGen[characterID], bonusEpoch
	bonusMu.RUnlock()
	if ok || src == nil || characterID == 0 {
		return b
	}
	b, good := src(characterID)
	if !good {
		return b
	}
	bonusMu.Lock()
	if bonusEpoch == epoch && bonusGen[characterID] == gen {
		bonusCache[characterID] = b
	}
	bonusMu.Unlock()
	return b
}

// Store is anything that can list, create, and delete characters for an
// account.
type Store interface {
	// ListByAccount returns all characters belonging to accountID, in
	// creation order.
	ListByAccount(ctx context.Context, accountID int64) ([]*Character, error)

	// Create adds a new character named name to accountID. Returns
	// ErrNameTaken or ErrAccountFull as appropriate.
	Create(ctx context.Context, accountID int64, name string) (*Character, error)

	// Delete removes characterID from accountID. Returns ErrNotFound if it
	// doesn't exist under that account.
	Delete(ctx context.Context, accountID, characterID int64) error

	// AddGold credits amount (must be positive) to characterID's balance.
	AddGold(ctx context.Context, characterID int64, amount int64) error

	// DeductGold debits amount (must be positive) from characterID's
	// balance. Returns ErrInsufficientGold if the balance is too low.
	DeductGold(ctx context.Context, characterID int64, amount int64) error

	// AddStorageGold credits amount to characterID's warehouse gold (the gold
	// kept in storage, separate from what the character carries).
	AddStorageGold(ctx context.Context, characterID int64, amount int64) error

	// DeductStorageGold debits amount from characterID's warehouse gold.
	// Returns ErrInsufficientGold if the stored balance is too low.
	DeductStorageGold(ctx context.Context, characterID int64, amount int64) error

	// SetHwanCount stores characterID's berserk orb count, the engine's
	// _CHAR.RemainHwanCount. Clamped by the caller to 0..berserk.Orbs; this
	// only writes what it is given.
	SetHwanCount(ctx context.Context, characterID int64, count int) error

	// ApplyDamage reduces characterID's HP by amount (never below 0),
	// returning the resulting HP and whether THIS call took it from above 0
	// to 0 -- the transition. A character already at 0 is left as it is and
	// reports (0, false): the pool write is a no-op, made under the store's
	// own lock or in one UPDATE (round 550).
	//
	// died is a fact about the write, not the verdict on a death (round
	// 551). Round 550 had the kill paths read it as the verdict -- two blows
	// racing each other would report one transition between them -- and that
	// made a character ALIVE at 0 unkillable: an HP-cost cast lands its
	// caster at exactly 0 (the engine's gate passes on equal,
	// combat.CanPaySkillHealth), the pool is then already at 0 for every
	// later blow, and each read (0, false) and landed nothing, for ever
	// (session/skill.go pays the cost through this method and does not
	// treat its transition as a death). The kill is decided one layer up,
	// by session's per-character kill lock (session/monsterstrike.go
	// killLock, fallen): a blow whose damage leaves the pool at 0 reads the
	// character back under it -- alive and still at 0, it is THE kill;
	// already dead, or already respawned or revived, it lost. So this method
	// promises only the arithmetic: HP after the call, and whether this call
	// emptied the pool. Nothing in session reads died today; tests pin it
	// (TestApplyDamageOnACharacterAtZeroReportsNoDeath).
	ApplyDamage(ctx context.Context, characterID int64, amount int) (remainingHP int, died bool, err error)

	// ResetHP restores characterID's HP to MaxHP. Used on a LEVEL-UP, where
	// the game does heal to full; a death respawns at RespawnFraction
	// instead -- see RespawnHP.
	ResetHP(ctx context.Context, characterID int64) error

	// RespawnHP restores characterID's HP to RespawnFraction of its maximum,
	// which is what the game gives a character coming back from death.
	RespawnHP(ctx context.Context, characterID int64) error

	// Heal raises characterID's HP by amount, never above maxHP, returning
	// the resulting HP. Used by consumables; a non-positive amount is a
	// no-op that still reports the current HP.
	Heal(ctx context.Context, characterID int64, amount, maxHP int) (int, error)

	// SetLeveling writes characterID's level, current-level exp progress,
	// unspent stat points, and Str/Int -- the result the caller computed from
	// a kill's exp against the leveldata curve. Returns ErrNotFound if no such
	// character.
	//
	// Str and Int are here because the engine writes them in the same breath.
	// GObjPC_SetLevel grants five stat points per level and immediately calls
	// SpendStatPoints(levels, levels), which does `Str += levels` and
	// `Int += levels` (asm: `movzx ecx,[eax+0x74]; add cx,si; call SetStr`).
	// One level-up is one transaction in the engine, so it is one call here.
	//
	// Round 874: MaxLevel follows -- it becomes the larger of itself, the
	// level the row had and the level written, so a store never lowers it.
	SetLeveling(ctx context.Context, characterID int64, level int, exp int64, statPoints, str, intel int) error

	// GetByID returns the character with the given ID, regardless of which
	// account owns it (unlike ListByAccount). Returns ErrNotFound if no
	// such character exists. Used to resolve real per-player rendering
	// details (e.g. Gender) for *other* players, who are only otherwise
	// known by ID/name/position via world.Entity.
	GetByID(ctx context.Context, characterID int64) (*Character, error)

	// SetGender updates characterID's Gender. Returns ErrNotFound if no
	// such character exists. Doesn't validate gender; a China gender also
	// sets the matching legacy body (LegacyModelFor). Since round 682 the
	// lobby sets a character's gender at creation (LobbyStore.
	// CreateCharacter) and only tests call this.
	SetGender(ctx context.Context, characterID int64, gender string) error

	// SavePosition stores where characterID last stood: the zone label, the
	// frame region x/y/z are relative to ("x/y", or "" for a label with
	// none), and the point (Character.Zone, Frame, PosX/PosY/PosZ). Returns
	// ErrNotFound if no such character.
	SavePosition(ctx context.Context, characterID int64, zone, frame string, x, y, z float64) error
}

// RespawnMP is the mana a character comes back from death with:
// RespawnFraction of its maximum, floored at 0. The engine restores HP and MP
// through the same branch and the same 0.4, so this is the one constant applied
// twice rather than two numbers that happen to agree.
func RespawnMP(maxMP int) int {
	if maxMP <= 0 {
		return 0
	}
	return int(float64(maxMP) * RespawnFraction)
}
