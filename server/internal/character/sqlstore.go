package character

import (
	"context"
	"database/sql"
	"fmt"
	"strings"

	_ "modernc.org/sqlite" // driver registration
)

// schema creates the characters table if it doesn't already exist. Own
// schema (see docs/protocol/db_schema.md), not a port of the original.
// COLLATE NOCASE on name gives SQLite-level case-insensitive uniqueness,
// matching MemStore's normalizeName behavior.
const schema = `
CREATE TABLE IF NOT EXISTS characters (
	id         INTEGER PRIMARY KEY AUTOINCREMENT,
	account_id INTEGER NOT NULL,
	name       TEXT NOT NULL COLLATE NOCASE UNIQUE
);
CREATE INDEX IF NOT EXISTS characters_account_id ON characters(account_id);
`

// SQLStore is a Store backed by SQLite via the pure-Go modernc.org/sqlite
// driver — same approach as account.SQLStore.
type SQLStore struct {
	db *sql.DB
}

// OpenSQLStore opens (creating if necessary) a SQLite database at dsn and
// ensures its schema exists. Use ":memory:" for an ephemeral database.
func OpenSQLStore(dsn string) (*SQLStore, error) {
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("character: opening sqlite database: %w", err)
	}
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("character: creating schema: %w", err)
	}
	return &SQLStore{db: db}, nil
}

// Close closes the underlying database connection.
func (s *SQLStore) Close() error {
	return s.db.Close()
}

// ListByAccount implements Store.
func (s *SQLStore) ListByAccount(ctx context.Context, accountID int64) ([]*Character, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, account_id, name FROM characters WHERE account_id = ? ORDER BY id`, accountID)
	if err != nil {
		return nil, fmt.Errorf("character: listing characters: %w", err)
	}
	defer rows.Close()

	var out []*Character
	for rows.Next() {
		var c Character
		if err := rows.Scan(&c.ID, &c.AccountID, &c.Name); err != nil {
			return nil, fmt.Errorf("character: scanning row: %w", err)
		}
		out = append(out, &c)
	}
	return out, rows.Err()
}

// Create implements Store.
func (s *SQLStore) Create(ctx context.Context, accountID int64, name string) (*Character, error) {
	var count int
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM characters WHERE account_id = ?`, accountID).Scan(&count); err != nil {
		return nil, fmt.Errorf("character: counting existing characters: %w", err)
	}
	if count >= MaxPerAccount {
		return nil, ErrAccountFull
	}

	res, err := s.db.ExecContext(ctx,
		`INSERT INTO characters (account_id, name) VALUES (?, ?)`, accountID, name)
	if err != nil {
		if isUniqueConstraintErr(err) {
			return nil, ErrNameTaken
		}
		return nil, fmt.Errorf("character: inserting character: %w", err)
	}

	id, err := res.LastInsertId()
	if err != nil {
		return nil, fmt.Errorf("character: reading new character id: %w", err)
	}
	return &Character{ID: id, AccountID: accountID, Name: name}, nil
}

// Delete implements Store.
func (s *SQLStore) Delete(ctx context.Context, accountID, characterID int64) error {
	res, err := s.db.ExecContext(ctx,
		`DELETE FROM characters WHERE id = ? AND account_id = ?`, characterID, accountID)
	if err != nil {
		return fmt.Errorf("character: deleting character: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("character: checking delete result: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

func isUniqueConstraintErr(err error) bool {
	return err != nil && strings.Contains(err.Error(), "UNIQUE constraint failed")
}
