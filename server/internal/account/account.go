// Package account implements this server's own account/authentication
// model. It is an independent design, not a port of any original schema —
// see docs/protocol/db_schema.md for the facts it's informed by (an account
// concept with a username/password credential check and a blocked/allowed
// status) and docs/protocol/opcodes/login.md for the wire-level login flow
// this will eventually sit behind.
package account

import (
	"context"
	"errors"

	"golang.org/x/crypto/bcrypt"
)

// ErrInvalidCredentials is returned by Store.Authenticate when the username
// doesn't exist or the password doesn't match. Deliberately the same error
// for both cases, so callers can't use response differences to enumerate
// valid usernames.
var ErrInvalidCredentials = errors.New("account: invalid username or password")

// ErrBlocked is returned by Store.Authenticate for an account that exists,
// has the right password, but is currently blocked.
var ErrBlocked = errors.New("account: account is blocked")

// ErrUsernameTaken is returned by Registerer.Register when the requested
// username already exists.
var ErrUsernameTaken = errors.New("account: username already taken")

// Account is one registered player account.
type Account struct {
	ID           int64
	Username     string
	PasswordHash []byte
	Blocked      bool
	BlockReason  string
}

// HashPassword hashes a plaintext password for storage. Never store
// plaintext passwords or reversible encryption of them.
func HashPassword(plaintext string) ([]byte, error) {
	return bcrypt.GenerateFromPassword([]byte(plaintext), bcrypt.DefaultCost)
}

// verify reports whether plaintext matches this account's stored hash.
func (a *Account) verify(plaintext string) bool {
	return bcrypt.CompareHashAndPassword(a.PasswordHash, []byte(plaintext)) == nil
}

// Store is anything that can look up and authenticate accounts. The gateway
// login handler (once implemented) will depend on this interface, not on a
// concrete storage backend, so tests can use an in-memory Store and
// production can use a real database without either caring about the other.
type Store interface {
	// Authenticate looks up username and checks password against it.
	// Returns ErrInvalidCredentials if the username doesn't exist or the
	// password is wrong, or ErrBlocked if the credentials are correct but
	// the account is currently blocked.
	Authenticate(ctx context.Context, username, password string) (*Account, error)
}

// Registerer is anything that can create new accounts. Kept separate from
// Store so a read-mostly deployment (e.g. a world server that only ever
// authenticates, never registers) can depend on just Store.
type Registerer interface {
	// Register creates a new account with the given username and plaintext
	// password (hashed internally before storage). Returns ErrUsernameTaken
	// if the username already exists.
	Register(ctx context.Context, username, password string) (*Account, error)
}
