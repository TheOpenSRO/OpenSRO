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
)

// MaxPerAccount caps how many characters one account may have. Own design, and
// now with a reason rather than just a label: it is not recoverable from the
// artifact this project has.
//
// SR_GameServer.exe carries no character-creation path at all -- no limit
// string, no count check -- because creation happens on the AgentServer and in
// the database. That is the same wall this project already hit for starting
// Str/Int ("nothing writes a CONSTANT to charData+0x74/+0x76") and for
// the default InventorySize (nothing writes charData+0xac either).
//
// THE QUALIFIER MATTERS AND THIS LINE HAD LOST IT (fixed 2026-09-16). It read
// "nothing writes charData+0x74/+0x76 anywhere in the binary", which is false:
// GObjPC_SpendStatPoints (`0x00511470`) writes both, incrementing them when
// points are spent. The claim that holds is the narrower one at StartingStr --
// nothing writes an initial constant there. A paraphrase that drops the word
// doing the work turns a true absence into a false one. Anything
// decided when a character is first made is outside this executable, so the
// whole category is closed rather than each value being rediscovered.
const MaxPerAccount = 3

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
// design choice.
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
// a QWORD, so the double 0.4. At float width the same address reads
// -1.08e-19, which would resurrect every character on a negative sliver of
// health; only the double is coherent. Operand size has decided four constants
// in this project now.
//
// This does NOT apply to a level-up. Nothing in the level path zeroes the
// stored pool, so the branch above never fires there and a level-up heals to
// full -- which is why ResetHP and RespawnHP are separate calls.
const (
	RespawnFraction = 0.4
)

// StartingStr and StartingInt are a new character's stats. OWN DESIGN,
// disclosed -- the formula above is the game's, these two numbers are not.
// SR_GameServer.exe does not contain them: nothing writes a constant to
// charData+0x74 or +0x76 anywhere in it, because character creation happened on
// the database side, which this project has no artifact of. 20 apiece puts a
// level-1 character on 200 health and 200 mana.
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
//   - the client's character-creation screen. Its strings are UIO_NEWCHAR_*, and
//     they are race, gender, class and _EXPLANATION text. It previews an
//     appearance, not a stat line, so there is no formula in the client either.
//   - LevelData.txt. Nine columns, none of them a stat: level, exp, mastery cost,
//     two zero columns, the kill-exp unit, and a triple of large identical values
//     (see the note below).
//
// So the value stays own-design, but the reason is now three measurements rather
// than one silence. If it is ever recovered, it is worth doing: at level 40 a
// wrong starting Str is a wrong health total by the same ratio.
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
// half of the growth, and the Str term is the larger. srrevamp held Str and Int
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
	return int(math.Round(float64(stat) * float64(perPoint) * math.Pow(StatGrowth, float64(level-1))))
}

// StartingLevel is the level a newly-created character is. There is no
// way to gain a level yet -- experience is not tracked -- so every
// character stays at it; what the level is *for* today is the item table's
// own "required level" column, which equipment checks against it.
const StartingLevel = 1

// Gender selects which real body/skeleton/equipment assets a character
// renders with client-side (see client/scripts/World3D.gd). Real,
// RE-confirmed asset options, not invented: this project's available real
// client data (see docs/PROGRESS.md) has complete, parallel body/skeleton/
// armor asset sets for China man and China woman, but not for any other
// real race found in that data (Europe's base body meshes weren't present
// in the available client install) -- so only these two are offered, not
// a larger invented roster.
const (
	GenderChinaMan   = "china_man"
	GenderChinaWoman = "china_woman"
)

// DefaultGender is used when a character is created without an explicit
// (or a not-recognized) gender choice.
const DefaultGender = GenderChinaMan

// ValidGender reports whether g is one of the real, supported Gender
// values above.
func ValidGender(g string) bool {
	return g == GenderChinaMan || g == GenderChinaWoman
}

// Character is one player character.
type Character struct {
	ID        int64
	AccountID int64
	Name      string
	Gold      int64
	HP        int
	Gender    string
	Level     int
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
}

// MaxHP is this character's maximum health, from its Str and Level.
func (c *Character) MaxHP() int { return MaxHPFor(c.Str, c.Level) }

// MaxMP is this character's maximum mana, from its Int and Level.
func (c *Character) MaxMP() int { return MaxMPFor(c.Int, c.Level) }

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

	// ApplyDamage reduces characterID's HP by amount (never below 0),
	// returning the resulting HP and whether this brought it to exactly 0.
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
	SetLeveling(ctx context.Context, characterID int64, level int, exp int64, statPoints, str, intel int) error

	// GetByID returns the character with the given ID, regardless of which
	// account owns it (unlike ListByAccount). Returns ErrNotFound if no
	// such character exists. Used to resolve real per-player rendering
	// details (e.g. Gender) for *other* players, who are only otherwise
	// known by ID/name/position via world.Entity.
	GetByID(ctx context.Context, characterID int64) (*Character, error)

	// SetGender updates characterID's Gender. Returns ErrNotFound if no
	// such character exists. Doesn't validate gender against ValidGender --
	// callers (see server/internal/session/character.go) are expected to
	// have already checked, same as this project's other Store methods
	// trusting their caller for business-rule validation.
	SetGender(ctx context.Context, characterID int64, gender string) error
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
