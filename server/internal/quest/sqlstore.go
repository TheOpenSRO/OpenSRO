package quest

import (
	"context"
	"database/sql"
	"fmt"
	"strings"

	_ "github.com/jackc/pgx/v5/stdlib" // driver registration ("pgx")
)

const schema = `
CREATE TABLE IF NOT EXISTS character_quests (
	character_id BIGINT NOT NULL,
	quest_id     BIGINT NOT NULL,
	kills        INTEGER NOT NULL DEFAULT 0,
	completed_at TIMESTAMPTZ,
	PRIMARY KEY (character_id, quest_id)
);
`

// SQLStore is a Store backed by PostgreSQL.
type SQLStore struct {
	db *sql.DB
	// ownsDB is false on a shared pool (NewSQLStore), which Close leaves open.
	ownsDB bool
}

// OpenSQLStore opens a PostgreSQL database at dsn and ensures its schema
// exists.
func OpenSQLStore(dsn string) (*SQLStore, error) {
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, fmt.Errorf("quest: opening postgres connection: %w", err)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("quest: connecting to postgres: %w", err)
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
// other stores (round 743: one capped pool per process). Close does not
// close it.
func NewSQLStore(db *sql.DB) (*SQLStore, error) {
	if _, err := db.Exec(schema + defaultsSchema); err != nil {
		return nil, fmt.Errorf("quest: creating schema: %w", err)
	}
	return &SQLStore{db: db}, nil
}

// Close closes the underlying database connection, unless it is a shared
// pool.
func (s *SQLStore) Close() error {
	if !s.ownsDB {
		return nil
	}
	return s.db.Close()
}

// TruncateForTest clears all quest progress, for other packages' tests
// sharing this Postgres instance. Not for production use.
func (s *SQLStore) TruncateForTest(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `TRUNCATE TABLE character_quests, character_default_quests`)
	return err
}

// Accept implements Store.
func (s *SQLStore) Accept(ctx context.Context, characterID, questID int64) error {
	if _, ok := Catalog[questID]; !ok {
		return ErrUnknownQuest
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO character_quests (character_id, quest_id) VALUES ($1, $2)`, characterID, questID)
	if err != nil {
		if isUniqueConstraintErr(err) {
			return ErrAlreadyAccepted
		}
		return fmt.Errorf("quest: accepting quest: %w", err)
	}
	return nil
}

// ListProgress implements Store.
func (s *SQLStore) ListProgress(ctx context.Context, characterID int64) ([]Progress, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT quest_id, kills, completed_at IS NOT NULL FROM character_quests WHERE character_id = $1 ORDER BY quest_id`,
		characterID)
	if err != nil {
		return nil, fmt.Errorf("quest: listing progress: %w", err)
	}
	defer rows.Close()

	var out []Progress
	for rows.Next() {
		var p Progress
		if err := rows.Scan(&p.QuestID, &p.Kills, &p.Completed); err != nil {
			return nil, fmt.Errorf("quest: scanning row: %w", err)
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// RecordKill implements Store.
func (s *SQLStore) RecordKill(ctx context.Context, characterID int64, monsterName string) ([]Quest, error) {
	var completed []Quest
	for _, q := range Catalog {
		if q.MonsterName != monsterName {
			continue
		}

		var kills int
		err := s.db.QueryRowContext(ctx,
			`UPDATE character_quests SET kills = kills + 1
			 WHERE character_id = $1 AND quest_id = $2 AND completed_at IS NULL
			 RETURNING kills`,
			characterID, q.ID).Scan(&kills)
		if err == sql.ErrNoRows {
			// Not accepted, or already completed -- nothing to do for this
			// quest.
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("quest: recording kill: %w", err)
		}

		if kills >= q.TargetKills {
			if _, err := s.db.ExecContext(ctx,
				`UPDATE character_quests SET completed_at = now() WHERE character_id = $1 AND quest_id = $2`,
				characterID, q.ID); err != nil {
				return nil, fmt.Errorf("quest: marking complete: %w", err)
			}
			completed = append(completed, q)
		}
	}
	return completed, nil
}

func isUniqueConstraintErr(err error) bool {
	return err != nil && strings.Contains(err.Error(), "duplicate key value violates unique constraint")
}
