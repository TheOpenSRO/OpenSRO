package friend

import (
	"context"
	"database/sql"
	"fmt"

	_ "github.com/jackc/pgx/v5/stdlib" // driver registration ("pgx")
)

// friend_requests held OpenSRO's own stored requests (rounds before 834). It
// is no longer written; it stays so a database that has rows in it keeps
// its shape for the swarm cleanup (cmd/swarm) and TruncateForTest.
const schema = `
CREATE TABLE IF NOT EXISTS friend_requests (
	requester_id   BIGINT NOT NULL,
	requester_name TEXT NOT NULL,
	target_id      BIGINT NOT NULL,
	PRIMARY KEY (requester_id, target_id)
);
CREATE INDEX IF NOT EXISTS friend_requests_target_id ON friend_requests(target_id);

CREATE TABLE IF NOT EXISTS friendships (
	character_id BIGINT NOT NULL,
	friend_id    BIGINT NOT NULL,
	friend_name  TEXT NOT NULL,
	PRIMARY KEY (character_id, friend_id)
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
		return nil, fmt.Errorf("friend: opening postgres connection: %w", err)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("friend: connecting to postgres: %w", err)
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
	if _, err := db.Exec(schema); err != nil {
		return nil, fmt.Errorf("friend: creating schema: %w", err)
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

// TruncateForTest clears all friend data, for other packages' tests
// sharing this Postgres instance. Not for production use.
func (s *SQLStore) TruncateForTest(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `TRUNCATE TABLE friend_requests, friendships`)
	return err
}

// AddFriendship implements Store: both rows in one transaction, after
// both counts and the existing-row test (retail's `_Friend_Add` writes both
// sides, sm:0x447320).
func (s *SQLStore) AddFriendship(ctx context.Context, aID int64, aName string, bID int64, bName string) error {
	if aID == bID {
		return ErrCannotFriendSelf
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("friend: beginning transaction: %w", err)
	}
	defer tx.Rollback()

	// Lock both characters' rows in a fixed order so two crossing adds
	// cannot both pass the counts.
	lo, hi := aID, bID
	if lo > hi {
		lo, hi = hi, lo
	}
	if _, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock($1), pg_advisory_xact_lock($2)`, lockKey(lo), lockKey(hi)); err != nil {
		return fmt.Errorf("friend: locking: %w", err)
	}
	var already bool
	if err := tx.QueryRowContext(ctx,
		`SELECT EXISTS(SELECT 1 FROM friendships WHERE (character_id = $1 AND friend_id = $2) OR (character_id = $2 AND friend_id = $1))`,
		aID, bID).Scan(&already); err != nil {
		return fmt.Errorf("friend: checking existing friendship: %w", err)
	}
	if already {
		return ErrAlreadyFriends
	}
	for _, id := range [2]int64{aID, bID} {
		var n int
		if err := tx.QueryRowContext(ctx,
			`SELECT COUNT(*) FROM friendships WHERE character_id = $1`, id).Scan(&n); err != nil {
			return fmt.Errorf("friend: counting friendships for %d: %w", id, err)
		}
		if n >= MaxFriends {
			return ErrListFull
		}
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO friendships (character_id, friend_id, friend_name) VALUES ($1, $2, $3), ($2, $1, $4)`,
		aID, bID, bName, aName); err != nil {
		return fmt.Errorf("friend: inserting friendship: %w", err)
	}
	return tx.Commit()
}

// ListFriends implements Store.
func (s *SQLStore) ListFriends(ctx context.Context, characterID int64) ([]Friend, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT friend_id, friend_name FROM friendships WHERE character_id = $1 ORDER BY friend_name`, characterID)
	if err != nil {
		return nil, fmt.Errorf("friend: listing friends: %w", err)
	}
	defer rows.Close()

	var out []Friend
	for rows.Next() {
		var f Friend
		if err := rows.Scan(&f.CharacterID, &f.Name); err != nil {
			return nil, fmt.Errorf("friend: scanning row: %w", err)
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

// RemoveFriend implements Store.
func (s *SQLStore) RemoveFriend(ctx context.Context, characterID, friendID int64) error {
	res, err := s.db.ExecContext(ctx,
		`DELETE FROM friendships WHERE (character_id = $1 AND friend_id = $2) OR (character_id = $2 AND friend_id = $1)`,
		characterID, friendID)
	if err != nil {
		return fmt.Errorf("friend: removing friendship: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("friend: checking delete result: %w", err)
	}
	if n == 0 {
		return ErrNotFriends
	}
	return nil
}

// lockKey is a character's advisory lock for friendship writes, in its own
// key space ("frnd") apart from the lobby's ("lobb", character/lobby.go).
func lockKey(characterID int64) int64 { return 0x66726e64<<32 | (characterID & 0xffffffff) }
