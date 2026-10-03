package skill

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/leveldata"

	_ "github.com/jackc/pgx/v5/stdlib" // driver registration ("pgx")
)

const schema = `
CREATE TABLE IF NOT EXISTS character_skills (
	character_id BIGINT NOT NULL,
	skill_id     BIGINT NOT NULL,
	last_used_at TIMESTAMPTZ,
	PRIMARY KEY (character_id, skill_id)
);
CREATE TABLE IF NOT EXISTS character_skill_points (
	character_id BIGINT PRIMARY KEY,
	points       INTEGER NOT NULL DEFAULT 0
);
-- The carried skill-experience remainder, the game's _CHAR.SExpOffset. Added
-- alongside the points column rather than replacing it, so an existing
-- deployment keeps the points its characters already earned and simply starts
-- carrying a remainder from here on.
ALTER TABLE character_skill_points ADD COLUMN IF NOT EXISTS skill_exp BIGINT NOT NULL DEFAULT 0;
CREATE TABLE IF NOT EXISTS character_mastery_levels (
	character_id BIGINT NOT NULL,
	mastery_id   BIGINT NOT NULL,
	level        INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (character_id, mastery_id)
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
	_, err := s.db.ExecContext(ctx,
		`TRUNCATE TABLE character_skills, character_skill_points, character_mastery_levels`)
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

// SkillPoints implements Store.
func (s *SQLStore) SkillPoints(ctx context.Context, characterID int64) (int, error) {
	var points int
	err := s.db.QueryRowContext(ctx,
		`SELECT points FROM character_skill_points WHERE character_id = $1`, characterID).Scan(&points)
	if err == sql.ErrNoRows {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("skill: reading skill points: %w", err)
	}
	return points, nil
}

// AddSkillPoints implements Store.
func (s *SQLStore) AddSkillPoints(ctx context.Context, characterID int64, delta int) (int, error) {
	var total int
	err := s.db.QueryRowContext(ctx,
		`INSERT INTO character_skill_points (character_id, points) VALUES ($1, GREATEST($2, 0))
		 ON CONFLICT (character_id) DO UPDATE SET points = GREATEST(character_skill_points.points + $2, 0)
		 RETURNING points`, characterID, delta).Scan(&total)
	if err != nil {
		return 0, fmt.Errorf("skill: adding skill points: %w", err)
	}
	return total, nil
}

// AddSkillExp implements Store. One statement, so the read-modify-write of the
// carried remainder cannot interleave with another kill on the same character.
func (s *SQLStore) AddSkillExp(ctx context.Context, characterID int64, sexp int64) (int, int, error) {
	if sexp < 0 {
		sexp = 0
	}
	// A transaction rather than one clever statement: Postgres RETURNING sees
	// the NEW row, so there is no way to report how many points this call
	// awarded from a single upsert. Read, compute, write -- the row is locked
	// FOR UPDATE so two kills on one character cannot interleave.
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, 0, fmt.Errorf("skill: adding skill experience: %w", err)
	}
	defer tx.Rollback()

	var points int
	var carried int64
	err = tx.QueryRowContext(ctx,
		`INSERT INTO character_skill_points (character_id) VALUES ($1)
		 ON CONFLICT (character_id) DO UPDATE SET character_id = EXCLUDED.character_id
		 RETURNING points, skill_exp`, characterID).Scan(&points, &carried)
	if err != nil {
		return 0, 0, fmt.Errorf("skill: reading carried skill experience: %w", err)
	}

	carried += sexp
	gained := int(carried / leveldata.SkillExpPerPoint)
	carried %= leveldata.SkillExpPerPoint
	total := points + gained

	if _, err := tx.ExecContext(ctx,
		`UPDATE character_skill_points SET points = $2, skill_exp = $3 WHERE character_id = $1`,
		characterID, total, carried); err != nil {
		return 0, 0, fmt.Errorf("skill: storing skill experience: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return 0, 0, fmt.Errorf("skill: committing skill experience: %w", err)
	}
	return gained, total, nil
}

// MasteryLevels implements Store.
func (s *SQLStore) MasteryLevels(ctx context.Context, characterID int64) (map[int64]int, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT mastery_id, level FROM character_mastery_levels WHERE character_id = $1`, characterID)
	if err != nil {
		return nil, fmt.Errorf("skill: listing mastery levels: %w", err)
	}
	defer rows.Close()
	out := make(map[int64]int)
	for rows.Next() {
		var id int64
		var level int
		if err := rows.Scan(&id, &level); err != nil {
			return nil, fmt.Errorf("skill: scanning mastery row: %w", err)
		}
		out[id] = level
	}
	return out, rows.Err()
}

// RaiseMastery implements Store: one transaction that checks the cap and the
// character's points, spends cost, and raises the mastery.
func (s *SQLStore) RaiseMastery(ctx context.Context, characterID, masteryID int64, cost, levelCap int) (int, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, fmt.Errorf("skill: raising mastery: %w", err)
	}
	defer tx.Rollback()

	var current int
	err = tx.QueryRowContext(ctx,
		`SELECT level FROM character_mastery_levels WHERE character_id = $1 AND mastery_id = $2`,
		characterID, masteryID).Scan(&current)
	if err != nil && err != sql.ErrNoRows {
		return 0, fmt.Errorf("skill: reading mastery level: %w", err)
	}
	if current >= levelCap {
		return current, ErrMasteryCapped
	}

	var points int
	err = tx.QueryRowContext(ctx,
		`SELECT points FROM character_skill_points WHERE character_id = $1`, characterID).Scan(&points)
	if err != nil && err != sql.ErrNoRows {
		return current, fmt.Errorf("skill: reading skill points: %w", err)
	}
	if points < cost {
		return current, ErrInsufficientSkillPoints
	}

	if _, err := tx.ExecContext(ctx,
		`UPDATE character_skill_points SET points = points - $1 WHERE character_id = $2`,
		cost, characterID); err != nil {
		return current, fmt.Errorf("skill: spending skill points: %w", err)
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO character_mastery_levels (character_id, mastery_id, level) VALUES ($1, $2, 1)
		 ON CONFLICT (character_id, mastery_id) DO UPDATE SET level = character_mastery_levels.level + 1`,
		characterID, masteryID); err != nil {
		return current, fmt.Errorf("skill: raising mastery: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return current, fmt.Errorf("skill: committing mastery raise: %w", err)
	}
	return current + 1, nil
}

func isUniqueConstraintErr(err error) bool {
	return err != nil && strings.Contains(err.Error(), "duplicate key value violates unique constraint")
}
