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

// Character is one player character.
type Character struct {
	ID        int64
	AccountID int64
	Name      string
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
}
