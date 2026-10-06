package account

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"github.com/OpenSRO/OpenSRO/server/internal/txn"
	_ "github.com/jackc/pgx/v5/stdlib" // driver registration ("pgx")
)

// schema creates the accounts table if it doesn't already exist. Our own
// schema — see docs/protocol/db_schema.md for the facts it's informed by,
// not a port of the original's TB_User layout.
const schema = `
CREATE TABLE IF NOT EXISTS accounts (
	id            BIGSERIAL PRIMARY KEY,
	username      TEXT NOT NULL UNIQUE,
	password_hash BYTEA NOT NULL,
	blocked       BOOLEAN NOT NULL DEFAULT FALSE,
	block_reason  TEXT NOT NULL DEFAULT ''
);
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS storage_gold BIGINT NOT NULL DEFAULT 0;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS chest_size INTEGER NOT NULL DEFAULT 0;
`

// SQLStore is a Store and Registerer backed by PostgreSQL (via the pgx
// driver, registered under the "pgx" database/sql driver name).
type SQLStore struct {
	db *sql.DB
	// ownsDB is false on a shared pool (NewSQLStore), which Close leaves open.
	ownsDB bool
}

// OpenSQLStore opens a PostgreSQL database at dsn (e.g.
// "postgres://user:pass@host:5432/dbname?sslmode=disable") and ensures its
// schema exists.
func OpenSQLStore(dsn string) (*SQLStore, error) {
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, fmt.Errorf("account: opening postgres connection: %w", err)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("account: connecting to postgres: %w", err)
	}
	s, err := NewSQLStore(db)
	if err != nil {
		db.Close()
		return nil, err
	}
	s.ownsDB = true
	return s, nil
}

// NewSQLStore is OpenSQLStore on a pool the caller owns and shares with the
// other stores (round 743). Close does not close it.
func NewSQLStore(db *sql.DB) (*SQLStore, error) {
	if err := txn.Migrate(db, schema); err != nil {
		return nil, fmt.Errorf("account: creating schema: %w", err)
	}
	return &SQLStore{db: db}, nil
}

// TxDB implements txn.TxDBer.
func (s *SQLStore) TxDB() *sql.DB {
	if s == nil {
		return nil
	}
	return s.db
}

// Close closes the underlying database connection, unless it is a shared
// pool.
func (s *SQLStore) Close() error {
	if !s.ownsDB {
		return nil
	}
	return s.db.Close()
}

// Register implements Registerer.
func (s *SQLStore) Register(ctx context.Context, username, password string) (*Account, error) {
	hash, err := HashPassword(password)
	if err != nil {
		return nil, err
	}

	var id int64
	err = txn.Conn(ctx, s.db).QueryRowContext(ctx,
		`INSERT INTO accounts (username, password_hash) VALUES ($1, $2) RETURNING id`,
		username, hash).Scan(&id)
	if err != nil {
		if isUniqueConstraintErr(err) {
			return nil, ErrUsernameTaken
		}
		return nil, fmt.Errorf("account: inserting account: %w", err)
	}
	return &Account{ID: id, Username: username, PasswordHash: hash}, nil
}

// Authenticate implements Store.
func (s *SQLStore) Authenticate(ctx context.Context, username, password string) (*Account, error) {
	var acc Account
	// chest_size is selected so Account.ChestSize means the same here as in
	// MemStore: the stored warehouse size, 0 when none was stored (round 501).
	row := txn.Conn(ctx, s.db).QueryRowContext(ctx,
		`SELECT id, username, password_hash, blocked, block_reason, chest_size FROM accounts WHERE username = $1`, username)
	if err := row.Scan(&acc.ID, &acc.Username, &acc.PasswordHash, &acc.Blocked, &acc.BlockReason, &acc.ChestSize); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrInvalidCredentials
		}
		return nil, fmt.Errorf("account: querying account: %w", err)
	}

	if !acc.verify(password) {
		return nil, ErrInvalidCredentials
	}
	if acc.Blocked {
		return nil, ErrBlocked
	}
	return &acc, nil
}

// SetBlocked sets an existing account's blocked status and reason.
func (s *SQLStore) SetBlocked(ctx context.Context, username string, blocked bool, reason string) error {
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx,
		`UPDATE accounts SET blocked = $1, block_reason = $2 WHERE username = $3`, blocked, reason, username)
	if err != nil {
		return fmt.Errorf("account: updating blocked status: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("account: checking update result: %w", err)
	}
	if n == 0 {
		return fmt.Errorf("account: no such account: %s", username)
	}
	return nil
}

func isUniqueConstraintErr(err error) bool {
	return err != nil && strings.Contains(err.Error(), "duplicate key value violates unique constraint")
}

// StorageGold implements StorageGoldStore.
func (s *SQLStore) StorageGold(ctx context.Context, accountID int64) (int64, error) {
	var gold int64
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx, `SELECT storage_gold FROM accounts WHERE id = $1`, accountID).Scan(&gold)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNoSuchAccount
	}
	if err != nil {
		return 0, fmt.Errorf("account: reading storage gold: %w", err)
	}
	return gold, nil
}

// AddStorageGold implements StorageGoldStore.
func (s *SQLStore) AddStorageGold(ctx context.Context, accountID int64, amount int64) error {
	if amount <= 0 {
		return errors.New("account: storage gold amount must be positive")
	}
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx, `UPDATE accounts SET storage_gold = storage_gold + $1 WHERE id = $2`, amount, accountID)
	if err != nil {
		return fmt.Errorf("account: adding storage gold: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNoSuchAccount
	}
	return nil
}

// DeductStorageGold implements StorageGoldStore. The balance check is in the
// statement itself, so two withdrawals cannot both pass it.
func (s *SQLStore) DeductStorageGold(ctx context.Context, accountID int64, amount int64) error {
	if amount <= 0 {
		return errors.New("account: storage gold amount must be positive")
	}
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx,
		`UPDATE accounts SET storage_gold = storage_gold - $1 WHERE id = $2 AND storage_gold >= $1`, amount, accountID)
	if err != nil {
		return fmt.Errorf("account: deducting storage gold: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		var exists bool
		if err := txn.Conn(ctx, s.db).QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM accounts WHERE id = $1)`, accountID).Scan(&exists); err == nil && !exists {
			return ErrNoSuchAccount
		}
		return ErrInsufficientStorageGold
	}
	return nil
}

// ChestSize implements ChestSizeStore. The column is the game's
// `_ChestInfo.ChestSize`; 0 means no size was ever stored.
func (s *SQLStore) ChestSize(ctx context.Context, accountID int64) (int, error) {
	var size int
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx, `SELECT chest_size FROM accounts WHERE id = $1`, accountID).Scan(&size)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNoSuchAccount
	}
	if err != nil {
		return 0, fmt.Errorf("account: reading chest size: %w", err)
	}
	return size, nil
}

// ExpandChest implements ChestSizeStore. The ceiling check is in the statement
// itself, so two expansions cannot both pass it.
func (s *SQLStore) ExpandChest(ctx context.Context, accountID int64, base, amount, ceiling int) (int, error) {
	if amount <= 0 {
		return 0, errors.New("account: chest expansion must be positive")
	}
	var size int
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx,
		`UPDATE accounts SET chest_size = GREATEST(chest_size, $2) + $3
		 WHERE id = $1 AND GREATEST(chest_size, $2) + $3 <= $4
		 RETURNING chest_size`, accountID, base, amount, ceiling).Scan(&size)
	if errors.Is(err, sql.ErrNoRows) {
		var exists bool
		if err := txn.Conn(ctx, s.db).QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM accounts WHERE id = $1)`, accountID).Scan(&exists); err != nil {
			return 0, fmt.Errorf("account: checking account after a refused expansion: %w", err)
		}
		if !exists {
			return 0, ErrNoSuchAccount
		}
		return 0, ErrChestFull
	}
	if err != nil {
		return 0, fmt.Errorf("account: expanding chest: %w", err)
	}
	return size, nil
}
