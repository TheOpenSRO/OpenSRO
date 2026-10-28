package skilljob

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
	_ "github.com/jackc/pgx/v5/stdlib" // driver registration ("pgx")
)

// schema is OURS (the package comment): one row per running job.
const schema = `
CREATE TABLE IF NOT EXISTS skill_jobs (
	character_id BIGINT NOT NULL,
	skill_id     BIGINT NOT NULL,
	item_id      BIGINT NOT NULL DEFAULT 0,
	until        TIMESTAMPTZ NOT NULL,
	PRIMARY KEY (character_id, skill_id)
);
`

// SQLStore is the PostgreSQL Store.
type SQLStore struct {
	db *sql.DB
}

// NewSQLStore opens the store on a pool shared with the other stores and
// creates its table.
func NewSQLStore(db *sql.DB) (*SQLStore, error) {
	if err := txn.Migrate(db, schema); err != nil {
		return nil, fmt.Errorf("skilljob: creating schema: %w", err)
	}
	return &SQLStore{db: db}, nil
}

// TruncateForTest clears the table. Not for production use.
func (s *SQLStore) TruncateForTest(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `TRUNCATE TABLE skill_jobs`)
	return err
}

// Put implements Store.
func (s *SQLStore) Put(ctx context.Context, j Job) error {
	_, err := txn.Conn(ctx, s.db).ExecContext(ctx, `INSERT INTO skill_jobs (character_id, skill_id, item_id, until)
		VALUES ($1, $2, $3, $4)
		ON CONFLICT (character_id, skill_id) DO UPDATE SET item_id = EXCLUDED.item_id, until = EXCLUDED.until`,
		j.CharacterID, j.SkillID, j.ItemID, j.Until)
	if err != nil {
		return fmt.Errorf("skilljob: recording a job: %w", err)
	}
	return nil
}

// List implements Store.
func (s *SQLStore) List(ctx context.Context, characterID int64) ([]Job, error) {
	rows, err := txn.Conn(ctx, s.db).QueryContext(ctx, `SELECT character_id, skill_id, item_id, until
		FROM skill_jobs WHERE character_id = $1 ORDER BY until, skill_id`, characterID)
	if err != nil {
		return nil, fmt.Errorf("skilljob: reading jobs: %w", err)
	}
	defer rows.Close()
	var out []Job
	for rows.Next() {
		var j Job
		if err := rows.Scan(&j.CharacterID, &j.SkillID, &j.ItemID, &j.Until); err != nil {
			return nil, err
		}
		out = append(out, j)
	}
	return out, rows.Err()
}

// Delete implements Store.
func (s *SQLStore) Delete(ctx context.Context, characterID, skillID int64) error {
	if _, err := txn.Conn(ctx, s.db).ExecContext(ctx, `DELETE FROM skill_jobs WHERE character_id = $1 AND skill_id = $2`,
		characterID, skillID); err != nil {
		return fmt.Errorf("skilljob: dropping a job: %w", err)
	}
	return nil
}

// DeleteEnded implements Store.
func (s *SQLStore) DeleteEnded(ctx context.Context, characterID int64, now time.Time) error {
	if _, err := txn.Conn(ctx, s.db).ExecContext(ctx, `DELETE FROM skill_jobs WHERE character_id = $1 AND until <= $2`,
		characterID, now); err != nil {
		return fmt.Errorf("skilljob: dropping ended jobs: %w", err)
	}
	return nil
}
