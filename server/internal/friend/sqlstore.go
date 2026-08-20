package friend

import (
	"context"
	"database/sql"
	"fmt"
	"strings"

	_ "github.com/jackc/pgx/v5/stdlib" // driver registration ("pgx")
)

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
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("friend: creating schema: %w", err)
	}
	return &SQLStore{db: db}, nil
}

// Close closes the underlying database connection.
func (s *SQLStore) Close() error {
	return s.db.Close()
}

// TruncateForTest clears all friend data, for other packages' tests
// sharing this Postgres instance. Not for production use.
func (s *SQLStore) TruncateForTest(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `TRUNCATE TABLE friend_requests, friendships`)
	return err
}

// SendRequest implements Store.
func (s *SQLStore) SendRequest(ctx context.Context, fromID int64, fromName string, toID int64) error {
	if fromID == toID {
		return ErrCannotFriendSelf
	}

	var alreadyFriends bool
	if err := s.db.QueryRowContext(ctx,
		`SELECT EXISTS(SELECT 1 FROM friendships WHERE character_id = $1 AND friend_id = $2)`,
		fromID, toID).Scan(&alreadyFriends); err != nil {
		return fmt.Errorf("friend: checking existing friendship: %w", err)
	}
	if alreadyFriends {
		return ErrAlreadyFriends
	}

	_, err := s.db.ExecContext(ctx,
		`INSERT INTO friend_requests (requester_id, requester_name, target_id) VALUES ($1, $2, $3)`,
		fromID, fromName, toID)
	if err != nil {
		if isUniqueConstraintErr(err) {
			return ErrRequestAlreadySent
		}
		return fmt.Errorf("friend: inserting request: %w", err)
	}
	return nil
}

// AcceptRequest implements Store.
func (s *SQLStore) AcceptRequest(ctx context.Context, characterID int64, characterName string, requesterID int64) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("friend: beginning transaction: %w", err)
	}
	defer tx.Rollback()

	var requesterName string
	err = tx.QueryRowContext(ctx,
		`DELETE FROM friend_requests WHERE requester_id = $1 AND target_id = $2 RETURNING requester_name`,
		requesterID, characterID).Scan(&requesterName)
	if err == sql.ErrNoRows {
		return ErrNoSuchRequest
	}
	if err != nil {
		return fmt.Errorf("friend: consuming request: %w", err)
	}

	if _, err := tx.ExecContext(ctx,
		`INSERT INTO friendships (character_id, friend_id, friend_name) VALUES ($1, $2, $3)
		 ON CONFLICT DO NOTHING`, characterID, requesterID, requesterName); err != nil {
		return fmt.Errorf("friend: inserting friendship: %w", err)
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO friendships (character_id, friend_id, friend_name) VALUES ($1, $2, $3)
		 ON CONFLICT DO NOTHING`, requesterID, characterID, characterName); err != nil {
		return fmt.Errorf("friend: inserting reciprocal friendship: %w", err)
	}

	return tx.Commit()
}

// DeclineRequest implements Store.
func (s *SQLStore) DeclineRequest(ctx context.Context, characterID, requesterID int64) error {
	res, err := s.db.ExecContext(ctx,
		`DELETE FROM friend_requests WHERE requester_id = $1 AND target_id = $2`, requesterID, characterID)
	if err != nil {
		return fmt.Errorf("friend: declining request: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("friend: checking delete result: %w", err)
	}
	if n == 0 {
		return ErrNoSuchRequest
	}
	return nil
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

// ListPendingRequests implements Store.
func (s *SQLStore) ListPendingRequests(ctx context.Context, characterID int64) ([]Request, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT requester_id, requester_name FROM friend_requests WHERE target_id = $1 ORDER BY requester_name`,
		characterID)
	if err != nil {
		return nil, fmt.Errorf("friend: listing pending requests: %w", err)
	}
	defer rows.Close()

	var out []Request
	for rows.Next() {
		var r Request
		if err := rows.Scan(&r.RequesterID, &r.RequesterName); err != nil {
			return nil, fmt.Errorf("friend: scanning row: %w", err)
		}
		out = append(out, r)
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

func isUniqueConstraintErr(err error) bool {
	return err != nil && strings.Contains(err.Error(), "duplicate key value violates unique constraint")
}
