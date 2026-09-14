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

// MaxPerAccount caps how many characters one account may have. Our own
// design choice (a common MMO convention), not taken from the original.
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

// MaxHP is the base maximum health (at level 1) and HPPerLevel is how much
// each level adds. Own design -- but see MaxMPForLevel: the real game's *base*
// curve was recovered, and deliberately is not used for HP. The real base is
// only a fraction of a real character's health (the rest comes from the
// Strength they have spent points on, which this project does not model), so
// adopting it here would leave a level-10 character on 120 HP against the real
// 249-HP Yeoha -- accurate in isolation and unplayable in practice. This stays
// own design until the Strength term is recovered too. Use MaxHPForLevel.
const MaxHP = 100
const HPPerLevel = 40

// MaxHPForLevel is a character's maximum health at the given level.
func MaxHPForLevel(level int) int {
	if level < 1 {
		level = 1
	}
	return MaxHP + (level-1)*HPPerLevel
}

// MPBase and MPGrowth are the REAL per-level mana curve, recovered from the
// pserver's own SR_GameServer.exe. Its player stat initialiser (FUN_004e3200)
// computes one value by binary exponentiation -- base^(level-1) -- and pushes
// it as both the 'hp' and the 'mp' parameter, so a character's base health and
// base mana are the same curve. The two constants are read straight out of
// .rdata: 0x00b45af0 = 100.0 and 0x00b45ea0 = 1.02.
//
// This is the BASE only. A real character's Strength and Intellect add on top,
// and that term has not been recovered -- which is why it is honest for mana
// (this project has no stat allocation, so the base is the whole of it) and
// would be wrong for health (see MaxHP).
const MPBase = 100.0
const MPGrowth = 1.02

// MaxMPForLevel is a character's maximum mana at the given level:
// 100 * 1.02^(level-1), the game's own curve.
func MaxMPForLevel(level int) int {
	if level < 1 {
		level = 1
	}
	return int(math.Round(MPBase * math.Pow(MPGrowth, float64(level-1))))
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
	// StorageGold is gold kept in the NPC warehouse, separate from the Gold
	// the character carries. Moved between the two by the storage service.
	StorageGold int64
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

	// ApplyDamage reduces characterID's HP by amount (never below 0),
	// returning the resulting HP and whether this brought it to exactly 0.
	ApplyDamage(ctx context.Context, characterID int64, amount int) (remainingHP int, died bool, err error)

	// ResetHP restores characterID's HP to MaxHP (e.g. after death/respawn).
	ResetHP(ctx context.Context, characterID int64) error

	// SetLeveling writes characterID's level, current-level exp progress and
	// unspent stat points -- the result the caller computed from a kill's exp
	// against the leveldata curve. Returns ErrNotFound if no such character.
	SetLeveling(ctx context.Context, characterID int64, level int, exp int64, statPoints int) error

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
