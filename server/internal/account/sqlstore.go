package account

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

	_ "modernc.org/sqlite" // driver registration
)

// schema creates the accounts table if it doesn't already exist. Our own
// schema — see docs/protocol/db_schema.md for the facts it's informed by,
// not a port of the original's TB_User layout.
const schema = `
CREATE TABLE IF NOT EXISTS accounts (
	id            INTEGER PRIMARY KEY AUTOINCREMENT,
	username      TEXT NOT NULL UNIQUE,
	password_hash BLOB NOT NULL,
	blocked       INTEGER NOT NULL DEFAULT 0,
	block_reason  TEXT NOT NULL DEFAULT ''
);
`

// SQLStore is a Store and Registerer backed by SQLite (via the pure-Go
// modernc.org/sqlite driver — no cgo, so it builds the same way everywhere
// this project's Go code does).
type SQLStore struct {
	db *sql.DB
}

// OpenSQLStore opens (creating if necessary) a SQLite database at dsn and
// ensures its schema exists. Use ":memory:" for an ephemeral in-memory
// database (handy for tests), or a file path for real persistence.
func OpenSQLStore(dsn string) (*SQLStore, error) {
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("account: opening sqlite database: %w", err)
	}
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("account: creating schema: %w", err)
	}
	return &SQLStore{db: db}, nil
}

// Close closes the underlying database connection.
func (s *SQLStore) Close() error {
	return s.db.Close()
}

// Register implements Registerer.
func (s *SQLStore) Register(ctx context.Context, username, password string) (*Account, error) {
	hash, err := HashPassword(password)
	if err != nil {
		return nil, err
	}

	res, err := s.db.ExecContext(ctx,
		`INSERT INTO accounts (username, password_hash) VALUES (?, ?)`, username, hash)
	if err != nil {
		// SQLite's UNIQUE constraint violation doesn't map to a typed Go
		// error via database/sql; string-matching the driver's message is
		// the pragmatic option here (same approach modernc.org/sqlite's own
		// docs point to, absent a stable sentinel error).
		if isUniqueConstraintErr(err) {
			return nil, ErrUsernameTaken
		}
		return nil, fmt.Errorf("account: inserting account: %w", err)
	}

	id, err := res.LastInsertId()
	if err != nil {
		return nil, fmt.Errorf("account: reading new account id: %w", err)
	}
	return &Account{ID: id, Username: username, PasswordHash: hash}, nil
}

// Authenticate implements Store.
func (s *SQLStore) Authenticate(ctx context.Context, username, password string) (*Account, error) {
	var acc Account
	var blockedInt int
	row := s.db.QueryRowContext(ctx,
		`SELECT id, username, password_hash, blocked, block_reason FROM accounts WHERE username = ?`, username)
	if err := row.Scan(&acc.ID, &acc.Username, &acc.PasswordHash, &blockedInt, &acc.BlockReason); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrInvalidCredentials
		}
		return nil, fmt.Errorf("account: querying account: %w", err)
	}
	acc.Blocked = blockedInt != 0

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
	blockedInt := 0
	if blocked {
		blockedInt = 1
	}
	res, err := s.db.ExecContext(ctx,
		`UPDATE accounts SET blocked = ?, block_reason = ? WHERE username = ?`, blockedInt, reason, username)
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
	return err != nil && strings.Contains(err.Error(), "UNIQUE constraint failed")
}
