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

// ErrBlocked is what Store.Authenticate's error matches (errors.Is) for an
// account that exists, has the right password, but has an active login block
// (round 788: a *BlockedError carrying the punishment, punishment.go).
var ErrBlocked = errors.New("account: account is blocked")

// ErrUsernameTaken is returned by Registerer.Register when the requested
// username already exists.
var ErrUsernameTaken = errors.New("account: username already taken")

// ErrInsufficientStorageGold is returned by DeductStorageGold when the
// account's warehouse holds less than asked.
var ErrInsufficientStorageGold = errors.New("account: insufficient warehouse gold")

// ErrNoSuchAccount is returned for an account id that does not exist.
var ErrNoSuchAccount = errors.New("account: no such account")

// ErrChestFull is returned by ExpandChest when the warehouse would grow past
// the ceiling it was given. The size is left as it was.
var ErrChestFull = errors.New("account: the warehouse cannot grow that far")

// Account is one registered player account.
type Account struct {
	ID           int64
	Username     string
	PasswordHash []byte
	// Round 788: the old Blocked/BlockReason fields are gone; a block is a
	// Punishment (punishment.go), and Authenticate reports an active one as
	// a *BlockedError.
	// StorageGold is the gold kept in the warehouse. It belongs to the
	// ACCOUNT, not to a character: the game's chest deposit runs
	// `_UPDATE_USER_N_CHAR_GOLD(userJID, userGold, charID, charGold)`
	// (AQ_StorageUpdater::MoveItemWithGold, 0x45af70), the user's balance
	// moving opposite the character's. See docs/protocol/server_sql.md.
	StorageGold int64
	// ChestSize is the warehouse's slot count, the game's per-user
	// `_ChestInfo.ChestSize` (binder DB_Bind__ChestInfo 0x8586e0, the column
	// at record offset 0x1c -- docs/protocol/db_bind_offsets.tsv). Zero means
	// no size was ever stored and the warehouse is its default size
	// (storage.DefaultCapacity); only an expansion item writes it (round 498).
	// Both stores answer it on Authenticate: MemStore keeps it on the
	// account, SQLStore selects accounts.chest_size (round 501; before that
	// a SQL account read 0 here even after an expansion). The warehouse
	// itself reads the size through ChestSizeStore, not through this field.
	ChestSize int
	// silk and silkSeeded are the MemStore's silk balances and its starting
	// grant's mark (round 837, silk.go); the SQL store keeps them in columns.
	silk       Silk
	silkSeeded bool
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
	// password is wrong, or a *BlockedError (errors.Is(err, ErrBlocked)) if
	// the credentials are correct but the account has an active login block
	// (PunishmentType.BlocksLogin). Any other error is the store's own.
	Authenticate(ctx context.Context, username, password string) (*Account, error)
}

// StorageGoldStore is the warehouse gold, kept per ACCOUNT because the game
// keeps it on the user row (see Account.StorageGold). Every character on the
// account deposits into and withdraws from the same balance.
type StorageGoldStore interface {
	// StorageGold returns accountID's warehouse gold.
	StorageGold(ctx context.Context, accountID int64) (int64, error)
	// AddStorageGold credits amount (must be positive) to accountID's
	// warehouse gold.
	AddStorageGold(ctx context.Context, accountID int64, amount int64) error
	// DeductStorageGold debits amount (must be positive) from accountID's
	// warehouse gold. Returns ErrInsufficientStorageGold if it holds less.
	DeductStorageGold(ctx context.Context, accountID int64, amount int64) error
}

// ChestSizeStore is the warehouse's size, kept per ACCOUNT because the game
// keeps it on the user (`_ChestInfo.ChestSize`, loaded by UserJID; see
// docs/protocol/server_sql.md). Every character on the account opens the same
// warehouse at the same size.
type ChestSizeStore interface {
	// ChestSize returns accountID's stored warehouse size, 0 when none was
	// ever stored.
	ChestSize(ctx context.Context, accountID int64) (int, error)
	// ExpandChest grows accountID's warehouse by amount (must be positive)
	// from max(stored size, base) and returns the new size, as one atomic
	// step. It returns ErrChestFull, and changes nothing, when the new size
	// would exceed ceiling.
	ExpandChest(ctx context.Context, accountID int64, base, amount, ceiling int) (int, error)
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
