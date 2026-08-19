package account

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

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
`

// SQLStore is a Store and Registerer backed by PostgreSQL (via the pgx
// driver, registered under the "pgx" database/sql driver name).
type SQLStore struct {
	db *sql.DB
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

	var id int64
	err = s.db.QueryRowContext(ctx,
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
	row := s.db.QueryRowContext(ctx,
		`SELECT id, username, password_hash, blocked, block_reason FROM accounts WHERE username = $1`, username)
	if err := row.Scan(&acc.ID, &acc.Username, &acc.PasswordHash, &acc.Blocked, &acc.BlockReason); err != nil {
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
	res, err := s.db.ExecContext(ctx,
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
