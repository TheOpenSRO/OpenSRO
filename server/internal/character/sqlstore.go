package character

import (
	"context"
	"database/sql"
	"fmt"
	"strings"

	_ "github.com/jackc/pgx/v5/stdlib" // driver registration ("pgx")
)

// schema creates the characters table if it doesn't already exist. Own
// schema (see docs/protocol/db_schema.md), not a port of the original. The
// unique index on lower(name) gives case-insensitive uniqueness, matching
// MemStore's normalizeName behavior (Postgres has no COLLATE NOCASE).
const schema = `
CREATE TABLE IF NOT EXISTS characters (
	id         BIGSERIAL PRIMARY KEY,
	account_id BIGINT NOT NULL,
	name       TEXT NOT NULL,
	gold       BIGINT NOT NULL DEFAULT 0
);
ALTER TABLE characters ADD COLUMN IF NOT EXISTS gold BIGINT NOT NULL DEFAULT 0;
CREATE UNIQUE INDEX IF NOT EXISTS characters_name_lower ON characters (LOWER(name));
CREATE INDEX IF NOT EXISTS characters_account_id ON characters(account_id);
`

// SQLStore is a Store backed by PostgreSQL (via the pgx driver) — same
// approach as account.SQLStore.
type SQLStore struct {
	db *sql.DB
}

// OpenSQLStore opens a PostgreSQL database at dsn and ensures its schema
// exists.
func OpenSQLStore(dsn string) (*SQLStore, error) {
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, fmt.Errorf("character: opening postgres connection: %w", err)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("character: connecting to postgres: %w", err)
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
		`SELECT id, account_id, name, gold FROM characters WHERE account_id = $1 ORDER BY id`, accountID)
	if err != nil {
		return nil, fmt.Errorf("character: listing characters: %w", err)
	}
	defer rows.Close()

	var out []*Character
	for rows.Next() {
		var c Character
		if err := rows.Scan(&c.ID, &c.AccountID, &c.Name, &c.Gold); err != nil {
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
		`SELECT COUNT(*) FROM characters WHERE account_id = $1`, accountID).Scan(&count); err != nil {
		return nil, fmt.Errorf("character: counting existing characters: %w", err)
	}
	if count >= MaxPerAccount {
		return nil, ErrAccountFull
	}

	var id int64
	err := s.db.QueryRowContext(ctx,
		`INSERT INTO characters (account_id, name, gold) VALUES ($1, $2, $3) RETURNING id`,
		accountID, name, StartingGold).Scan(&id)
	if err != nil {
		if isUniqueConstraintErr(err) {
			return nil, ErrNameTaken
		}
		return nil, fmt.Errorf("character: inserting character: %w", err)
	}
	return &Character{ID: id, AccountID: accountID, Name: name, Gold: StartingGold}, nil
}

// Delete implements Store.
func (s *SQLStore) Delete(ctx context.Context, accountID, characterID int64) error {
	res, err := s.db.ExecContext(ctx,
		`DELETE FROM characters WHERE id = $1 AND account_id = $2`, characterID, accountID)
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

// AddGold implements Store.
func (s *SQLStore) AddGold(ctx context.Context, characterID int64, amount int64) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE characters SET gold = gold + $1 WHERE id = $2`, amount, characterID)
	if err != nil {
		return fmt.Errorf("character: adding gold: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("character: checking update result: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// DeductGold implements Store.
func (s *SQLStore) DeductGold(ctx context.Context, characterID int64, amount int64) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE characters SET gold = gold - $1 WHERE id = $2 AND gold >= $1`, amount, characterID)
	if err != nil {
		return fmt.Errorf("character: deducting gold: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("character: checking update result: %w", err)
	}
	if n == 0 {
		// Either the character doesn't exist, or gold was insufficient --
		// distinguish so callers get an accurate error.
		var exists bool
		if err := s.db.QueryRowContext(ctx,
			`SELECT EXISTS(SELECT 1 FROM characters WHERE id = $1)`, characterID).Scan(&exists); err != nil {
			return fmt.Errorf("character: checking existence: %w", err)
		}
		if !exists {
			return ErrNotFound
		}
		return ErrInsufficientGold
	}
	return nil
}

func isUniqueConstraintErr(err error) bool {
	return err != nil && strings.Contains(err.Error(), "duplicate key value violates unique constraint")
}
