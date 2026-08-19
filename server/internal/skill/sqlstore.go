package skill

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib" // driver registration ("pgx")
)

const schema = `
CREATE TABLE IF NOT EXISTS character_skills (
	character_id BIGINT NOT NULL,
	skill_id     BIGINT NOT NULL,
	last_used_at TIMESTAMPTZ,
	PRIMARY KEY (character_id, skill_id)
);
`

// SQLStore is a Store backed by PostgreSQL.
type SQLStore struct {
	db *sql.DB
}

// OpenSQLStore opens a PostgreSQL database at dsn and ensures its schema
// exists.
func OpenSQLStore(dsn string) (*SQLStore, error) {
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, fmt.Errorf("skill: opening postgres connection: %w", err)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("skill: connecting to postgres: %w", err)
	}
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("skill: creating schema: %w", err)
	}
	return &SQLStore{db: db}, nil
}

// Close closes the underlying database connection.
func (s *SQLStore) Close() error {
	return s.db.Close()
}

// TruncateForTest clears all skill data, for other packages' tests sharing
// this Postgres instance. Not for production use.
func (s *SQLStore) TruncateForTest(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `TRUNCATE TABLE character_skills`)
	return err
}

// Learn implements Store.
func (s *SQLStore) Learn(ctx context.Context, characterID, skillID int64) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO character_skills (character_id, skill_id) VALUES ($1, $2)`, characterID, skillID)
	if err != nil {
		if isUniqueConstraintErr(err) {
			return ErrAlreadyKnown
		}
		return fmt.Errorf("skill: learning skill: %w", err)
	}
	return nil
}

// Knows implements Store.
func (s *SQLStore) Knows(ctx context.Context, characterID, skillID int64) (bool, error) {
	var exists bool
	err := s.db.QueryRowContext(ctx,
		`SELECT EXISTS(SELECT 1 FROM character_skills WHERE character_id = $1 AND skill_id = $2)`,
		characterID, skillID).Scan(&exists)
	if err != nil {
		return false, fmt.Errorf("skill: checking known skill: %w", err)
	}
	return exists, nil
}

// KnownSkills implements Store.
func (s *SQLStore) KnownSkills(ctx context.Context, characterID int64) ([]int64, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT skill_id FROM character_skills WHERE character_id = $1 ORDER BY skill_id`, characterID)
	if err != nil {
		return nil, fmt.Errorf("skill: listing known skills: %w", err)
	}
	defer rows.Close()

	var out []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("skill: scanning row: %w", err)
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// LastUsed implements Store.
func (s *SQLStore) LastUsed(ctx context.Context, characterID, skillID int64) (time.Time, bool, error) {
	var lastUsed sql.NullTime
	err := s.db.QueryRowContext(ctx,
		`SELECT last_used_at FROM character_skills WHERE character_id = $1 AND skill_id = $2`,
		characterID, skillID).Scan(&lastUsed)
	if err == sql.ErrNoRows {
		return time.Time{}, false, ErrNotKnown
	}
	if err != nil {
		return time.Time{}, false, fmt.Errorf("skill: reading last use: %w", err)
	}
	if !lastUsed.Valid {
		return time.Time{}, false, nil
	}
	return lastUsed.Time, true, nil
}

// RecordUse implements Store.
func (s *SQLStore) RecordUse(ctx context.Context, characterID, skillID int64, usedAt time.Time) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE character_skills SET last_used_at = $1 WHERE character_id = $2 AND skill_id = $3`,
		usedAt, characterID, skillID)
	if err != nil {
		return fmt.Errorf("skill: recording use: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("skill: checking update result: %w", err)
	}
	if n == 0 {
		return ErrNotKnown
	}
	return nil
}

func isUniqueConstraintErr(err error) bool {
	return err != nil && strings.Contains(err.Error(), "duplicate key value violates unique constraint")
}
