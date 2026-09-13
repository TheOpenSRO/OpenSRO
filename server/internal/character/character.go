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

// MaxHP is every character's maximum health. Flat for now -- own design
// choice, revisit once there's a leveling/stats system to scale it.
const MaxHP = 100

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
