package quest

import (
	"context"
	"database/sql"
	"fmt"
	"strconv"
	"strings"

	_ "github.com/jackc/pgx/v5/stdlib" // driver registration ("pgx")
)

// The schema. character_quests is the table the invented catalogue used
// before round 785; it is left in place (additive migrations only) and no
// longer read. character_quest_state is the quest log: one row per
// character and quest, the _CharQuest shape plus the mission counts.
const schema = `
CREATE TABLE IF NOT EXISTS character_quests (
	character_id BIGINT NOT NULL,
	quest_id     BIGINT NOT NULL,
	kills        INTEGER NOT NULL DEFAULT 0,
	completed_at TIMESTAMPTZ,
	PRIMARY KEY (character_id, quest_id)
);
CREATE TABLE IF NOT EXISTS character_quest_state (
	character_id BIGINT NOT NULL,
	quest_id     BIGINT NOT NULL,
	status       SMALLINT NOT NULL,
	counts       TEXT NOT NULL DEFAULT '',
	achieved     INTEGER NOT NULL DEFAULT 0,
	updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
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

// TruncateForTest clears all quest state, for other packages' tests sharing
// this Postgres instance. Not for production use.
func (s *SQLStore) TruncateForTest(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `TRUNCATE TABLE character_quests, character_quest_state, character_default_quests`)
	return err
}

func encodeCounts(c []int) string {
	parts := make([]string, len(c))
	for i, v := range c {
		parts[i] = strconv.Itoa(v)
	}
	return strings.Join(parts, ",")
}

func decodeCounts(s string) []int {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	out := make([]int, len(parts))
	for i, p := range parts {
		out[i], _ = strconv.Atoi(p)
	}
	return out
}

// States implements Store.
func (s *SQLStore) States(ctx context.Context, characterID int64) ([]State, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT quest_id, status, counts, achieved FROM character_quest_state WHERE character_id = $1 ORDER BY quest_id`,
		characterID)
	if err != nil {
		return nil, fmt.Errorf("quest: listing states: %w", err)
	}
	defer rows.Close()
	var out []State
	for rows.Next() {
		var st State
		var counts string
		if err := rows.Scan(&st.QuestID, &st.Status, &counts, &st.Achieved); err != nil {
			return nil, fmt.Errorf("quest: scanning state: %w", err)
		}
		st.Counts = decodeCounts(counts)
		out = append(out, st)
	}
	return out, rows.Err()
}

// Put implements Store.
func (s *SQLStore) Put(ctx context.Context, characterID int64, st State) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO character_quest_state (character_id, quest_id, status, counts, achieved, updated_at)
		 VALUES ($1, $2, $3, $4, $5, now())
		 ON CONFLICT (character_id, quest_id) DO UPDATE
		 SET status = EXCLUDED.status, counts = EXCLUDED.counts, achieved = EXCLUDED.achieved, updated_at = now()`,
		characterID, st.QuestID, st.Status, encodeCounts(st.Counts), st.Achieved)
	if err != nil {
		return fmt.Errorf("quest: writing state: %w", err)
	}
	return nil
}

// Delete implements Store.
func (s *SQLStore) Delete(ctx context.Context, characterID, questID int64) error {
	if _, err := s.db.ExecContext(ctx,
		`DELETE FROM character_quest_state WHERE character_id = $1 AND quest_id = $2`, characterID, questID); err != nil {
		return fmt.Errorf("quest: deleting state: %w", err)
	}
	return nil
}
