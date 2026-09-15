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
// The 'china_man' literal below must match DefaultGender in character.go --
// SQL can't reference the Go constant directly.
const schema = `
CREATE TABLE IF NOT EXISTS characters (
	id         BIGSERIAL PRIMARY KEY,
	account_id BIGINT NOT NULL,
	name       TEXT NOT NULL,
	gold       BIGINT NOT NULL DEFAULT 0,
	hp         INTEGER NOT NULL DEFAULT 100,
	gender     TEXT NOT NULL DEFAULT 'china_man'
);
ALTER TABLE characters ADD COLUMN IF NOT EXISTS gold BIGINT NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS hp INTEGER NOT NULL DEFAULT 100;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS gender TEXT NOT NULL DEFAULT 'china_man';
ALTER TABLE characters ADD COLUMN IF NOT EXISTS level INTEGER NOT NULL DEFAULT 1;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS exp BIGINT NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS stat_points INTEGER NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS storage_gold BIGINT NOT NULL DEFAULT 0;
-- Str and Int are what health and mana are derived from (character.MaxHPFor).
-- Existing rows default to the starting values rather than 0, which would
-- otherwise leave every migrated character on zero health.
ALTER TABLE characters ADD COLUMN IF NOT EXISTS str INTEGER NOT NULL DEFAULT 20;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS intel INTEGER NOT NULL DEFAULT 20;
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
		`SELECT id, account_id, name, gold, hp, gender, level, exp, stat_points, str, intel, storage_gold FROM characters WHERE account_id = $1 ORDER BY id`, accountID)
	if err != nil {
		return nil, fmt.Errorf("character: listing characters: %w", err)
	}
	defer rows.Close()

	var out []*Character
	for rows.Next() {
		var c Character
		if err := rows.Scan(&c.ID, &c.AccountID, &c.Name, &c.Gold, &c.HP, &c.Gender, &c.Level, &c.Exp, &c.StatPoints, &c.Str, &c.Int, &c.StorageGold); err != nil {
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
		`INSERT INTO characters (account_id, name, gold, hp, gender, level, str, intel) VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id`,
		accountID, name, StartingGold, StartingMaxHP, DefaultGender, StartingLevel,
		StartingStr, StartingInt).Scan(&id)
	if err != nil {
		if isUniqueConstraintErr(err) {
			return nil, ErrNameTaken
		}
		return nil, fmt.Errorf("character: inserting character: %w", err)
	}
	return &Character{ID: id, AccountID: accountID, Name: name, Gold: StartingGold, HP: StartingMaxHP,
		Gender: DefaultGender, Level: StartingLevel, Str: StartingStr, Int: StartingInt}, nil
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

// AddStorageGold implements Store.
func (s *SQLStore) AddStorageGold(ctx context.Context, characterID int64, amount int64) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE characters SET storage_gold = storage_gold + $1 WHERE id = $2`, amount, characterID)
	if err != nil {
		return fmt.Errorf("character: adding storage gold: %w", err)
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

// DeductStorageGold implements Store.
func (s *SQLStore) DeductStorageGold(ctx context.Context, characterID int64, amount int64) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE characters SET storage_gold = storage_gold - $1 WHERE id = $2 AND storage_gold >= $1`, amount, characterID)
	if err != nil {
		return fmt.Errorf("character: deducting storage gold: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("character: checking update result: %w", err)
	}
	if n == 0 {
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

// ApplyDamage implements Store.
func (s *SQLStore) ApplyDamage(ctx context.Context, characterID int64, amount int) (int, bool, error) {
	var hp int
	err := s.db.QueryRowContext(ctx,
		`UPDATE characters SET hp = GREATEST(hp - $1, 0) WHERE id = $2 RETURNING hp`,
		amount, characterID).Scan(&hp)
	if err == sql.ErrNoRows {
		return 0, false, ErrNotFound
	}
	if err != nil {
		return 0, false, fmt.Errorf("character: applying damage: %w", err)
	}
	return hp, hp == 0, nil
}

// Heal implements Store.
func (s *SQLStore) Heal(ctx context.Context, characterID int64, amount, maxHP int) (int, error) {
	if amount <= 0 {
		c, err := s.GetByID(ctx, characterID)
		if err != nil {
			return 0, err
		}
		return c.HP, nil
	}
	var hp int
	err := s.db.QueryRowContext(ctx,
		`UPDATE characters SET hp = LEAST(hp + $1, $2) WHERE id = $3 RETURNING hp`,
		amount, maxHP, characterID).Scan(&hp)
	if err == sql.ErrNoRows {
		return 0, ErrNotFound
	}
	if err != nil {
		return 0, fmt.Errorf("character: healing: %w", err)
	}
	return hp, nil
}

// ResetHP implements Store.
// RespawnHP implements Store: back from death at RespawnFraction of maximum,
// floored at 1 so a character never respawns dead.
func (s *SQLStore) RespawnHP(ctx context.Context, characterID int64) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE characters SET hp = GREATEST(1, FLOOR(ROUND(str * $1 * POWER($2, level - 1)) * $3)) WHERE id = $4`,
		HPPerStr, StatGrowth, RespawnFraction, characterID)
	if err != nil {
		return fmt.Errorf("character: respawning hp: %w", err)
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

func (s *SQLStore) ResetHP(ctx context.Context, characterID int64) error {
	// Max HP scales with the row's own level (base + per-level), so a reset
	// heals to the level-appropriate maximum.
	res, err := s.db.ExecContext(ctx,
		`UPDATE characters SET hp = ROUND(str * $1 * POWER($2, level - 1)) WHERE id = $3`,
		HPPerStr, StatGrowth, characterID)
	if err != nil {
		return fmt.Errorf("character: resetting hp: %w", err)
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

// GetByID implements Store.
func (s *SQLStore) GetByID(ctx context.Context, characterID int64) (*Character, error) {
	var c Character
	err := s.db.QueryRowContext(ctx,
		`SELECT id, account_id, name, gold, hp, gender, level, exp, stat_points, str, intel, storage_gold FROM characters WHERE id = $1`, characterID,
	).Scan(&c.ID, &c.AccountID, &c.Name, &c.Gold, &c.HP, &c.Gender, &c.Level, &c.Exp, &c.StatPoints, &c.Str, &c.Int, &c.StorageGold)
	if err == sql.ErrNoRows {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("character: getting character: %w", err)
	}
	return &c, nil
}

// SetLeveling implements Store.
func (s *SQLStore) SetLeveling(ctx context.Context, characterID int64, level int, exp int64, statPoints int) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE characters SET level = $1, exp = $2, stat_points = $3 WHERE id = $4`,
		level, exp, statPoints, characterID)
	if err != nil {
		return fmt.Errorf("character: setting leveling: %w", err)
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

// SetGender implements Store.
func (s *SQLStore) SetGender(ctx context.Context, characterID int64, gender string) error {
	res, err := s.db.ExecContext(ctx, `UPDATE characters SET gender = $1 WHERE id = $2`, gender, characterID)
	if err != nil {
		return fmt.Errorf("character: setting gender: %w", err)
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

func isUniqueConstraintErr(err error) bool {
	return err != nil && strings.Contains(err.Error(), "duplicate key value violates unique constraint")
}
