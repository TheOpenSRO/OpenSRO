package guild

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

	_ "github.com/jackc/pgx/v5/stdlib" // driver registration ("pgx")
)

// schema creates the guilds/guild_members tables if they don't already
// exist. Own schema, not a port of the original.
const schema = `
CREATE TABLE IF NOT EXISTS guilds (
	id        BIGSERIAL PRIMARY KEY,
	name      TEXT NOT NULL,
	leader_id BIGINT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS guilds_name_lower ON guilds (LOWER(name));

CREATE TABLE IF NOT EXISTS guild_members (
	guild_id       BIGINT NOT NULL REFERENCES guilds(id) ON DELETE CASCADE,
	character_id   BIGINT NOT NULL UNIQUE,
	character_name TEXT NOT NULL,
	role           INTEGER NOT NULL,
	joined_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS guild_members_guild_id ON guild_members(guild_id);
`

// SQLStore is a Store backed by PostgreSQL (via the pgx driver).
type SQLStore struct {
	db *sql.DB
}

// OpenSQLStore opens a PostgreSQL database at dsn and ensures its schema
// exists.
func OpenSQLStore(dsn string) (*SQLStore, error) {
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, fmt.Errorf("guild: opening postgres connection: %w", err)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("guild: connecting to postgres: %w", err)
	}
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("guild: creating schema: %w", err)
	}
	return &SQLStore{db: db}, nil
}

// Close closes the underlying database connection.
func (s *SQLStore) Close() error {
	return s.db.Close()
}

// TruncateForTest clears all guild data, for other packages' tests sharing
// this Postgres instance. Not for production use.
func (s *SQLStore) TruncateForTest(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `TRUNCATE TABLE guild_members, guilds RESTART IDENTITY CASCADE`)
	return err
}

// Create implements Store.
func (s *SQLStore) Create(ctx context.Context, name string, leaderID int64, leaderName string) (*Guild, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("guild: beginning transaction: %w", err)
	}
	defer tx.Rollback()

	var alreadyIn bool
	if err := tx.QueryRowContext(ctx,
		`SELECT EXISTS(SELECT 1 FROM guild_members WHERE character_id = $1)`, leaderID).Scan(&alreadyIn); err != nil {
		return nil, fmt.Errorf("guild: checking existing membership: %w", err)
	}
	if alreadyIn {
		return nil, ErrAlreadyInGuild
	}

	var id int64
	err = tx.QueryRowContext(ctx,
		`INSERT INTO guilds (name, leader_id) VALUES ($1, $2) RETURNING id`, name, leaderID).Scan(&id)
	if err != nil {
		if isUniqueConstraintErr(err) {
			return nil, ErrNameTaken
		}
		return nil, fmt.Errorf("guild: inserting guild: %w", err)
	}

	if _, err := tx.ExecContext(ctx,
		`INSERT INTO guild_members (guild_id, character_id, character_name, role) VALUES ($1, $2, $3, $4)`,
		id, leaderID, leaderName, RoleLeader); err != nil {
		return nil, fmt.Errorf("guild: inserting leader membership: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("guild: committing: %w", err)
	}

	return &Guild{
		ID:       id,
		Name:     name,
		LeaderID: leaderID,
		Members:  []Member{{CharacterID: leaderID, Name: leaderName, Role: RoleLeader}},
	}, nil
}

// Join implements Store.
func (s *SQLStore) Join(ctx context.Context, guildID, characterID int64, characterName string) (*Guild, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("guild: beginning transaction: %w", err)
	}
	defer tx.Rollback()

	var alreadyIn bool
	if err := tx.QueryRowContext(ctx,
		`SELECT EXISTS(SELECT 1 FROM guild_members WHERE character_id = $1)`, characterID).Scan(&alreadyIn); err != nil {
		return nil, fmt.Errorf("guild: checking existing membership: %w", err)
	}
	if alreadyIn {
		return nil, ErrAlreadyInGuild
	}

	var exists bool
	if err := tx.QueryRowContext(ctx,
		`SELECT EXISTS(SELECT 1 FROM guilds WHERE id = $1)`, guildID).Scan(&exists); err != nil {
		return nil, fmt.Errorf("guild: checking guild existence: %w", err)
	}
	if !exists {
		return nil, ErrGuildNotFound
	}

	// The engine's member cap (see guild.MaxMembers). Counted inside the same
	// transaction as the insert, so two simultaneous joins cannot both see room.
	var members int
	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM guild_members WHERE guild_id = $1`, guildID).Scan(&members); err != nil {
		return nil, fmt.Errorf("guild: counting members: %w", err)
	}
	if members >= MaxMembers {
		return nil, ErrGuildFull
	}

	if _, err := tx.ExecContext(ctx,
		`INSERT INTO guild_members (guild_id, character_id, character_name, role) VALUES ($1, $2, $3, $4)`,
		guildID, characterID, characterName, RoleMember); err != nil {
		return nil, fmt.Errorf("guild: inserting membership: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("guild: committing: %w", err)
	}

	return s.Get(ctx, guildID)
}

// Leave implements Store.
func (s *SQLStore) Leave(ctx context.Context, characterID int64) (int64, *Guild, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, nil, fmt.Errorf("guild: beginning transaction: %w", err)
	}
	defer tx.Rollback()

	var guildID int64
	var wasLeader bool
	err = tx.QueryRowContext(ctx,
		`SELECT gm.guild_id, g.leader_id = gm.character_id
		 FROM guild_members gm JOIN guilds g ON g.id = gm.guild_id
		 WHERE gm.character_id = $1`, characterID).Scan(&guildID, &wasLeader)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil, ErrNotInGuild
	}
	if err != nil {
		return 0, nil, fmt.Errorf("guild: looking up membership: %w", err)
	}

	if _, err := tx.ExecContext(ctx,
		`DELETE FROM guild_members WHERE character_id = $1`, characterID); err != nil {
		return 0, nil, fmt.Errorf("guild: deleting membership: %w", err)
	}

	var remaining int
	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM guild_members WHERE guild_id = $1`, guildID).Scan(&remaining); err != nil {
		return 0, nil, fmt.Errorf("guild: counting remaining members: %w", err)
	}

	if remaining == 0 {
		if _, err := tx.ExecContext(ctx, `DELETE FROM guilds WHERE id = $1`, guildID); err != nil {
			return 0, nil, fmt.Errorf("guild: disbanding empty guild: %w", err)
		}
		if err := tx.Commit(); err != nil {
			return 0, nil, fmt.Errorf("guild: committing: %w", err)
		}
		return guildID, nil, nil
	}

	if wasLeader {
		var newLeaderID int64
		if err := tx.QueryRowContext(ctx,
			`SELECT character_id FROM guild_members WHERE guild_id = $1 ORDER BY joined_at ASC LIMIT 1`,
			guildID).Scan(&newLeaderID); err != nil {
			return 0, nil, fmt.Errorf("guild: choosing new leader: %w", err)
		}
		if _, err := tx.ExecContext(ctx,
			`UPDATE guilds SET leader_id = $1 WHERE id = $2`, newLeaderID, guildID); err != nil {
			return 0, nil, fmt.Errorf("guild: promoting new leader: %w", err)
		}
		if _, err := tx.ExecContext(ctx,
			`UPDATE guild_members SET role = $1 WHERE guild_id = $2 AND character_id = $3`,
			RoleLeader, guildID, newLeaderID); err != nil {
			return 0, nil, fmt.Errorf("guild: updating new leader's role: %w", err)
		}
	}

	if err := tx.Commit(); err != nil {
		return 0, nil, fmt.Errorf("guild: committing: %w", err)
	}

	remainingGuild, err := s.Get(ctx, guildID)
	if err != nil {
		return 0, nil, err
	}
	return guildID, remainingGuild, nil
}

// GetByCharacter implements Store.
func (s *SQLStore) GetByCharacter(ctx context.Context, characterID int64) (*Guild, error) {
	var guildID int64
	err := s.db.QueryRowContext(ctx,
		`SELECT guild_id FROM guild_members WHERE character_id = $1`, characterID).Scan(&guildID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotInGuild
	}
	if err != nil {
		return nil, fmt.Errorf("guild: looking up membership: %w", err)
	}
	return s.Get(ctx, guildID)
}

// Get implements Store.
func (s *SQLStore) Get(ctx context.Context, guildID int64) (*Guild, error) {
	g := &Guild{ID: guildID}
	err := s.db.QueryRowContext(ctx,
		`SELECT name, leader_id FROM guilds WHERE id = $1`, guildID).Scan(&g.Name, &g.LeaderID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrGuildNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("guild: reading guild: %w", err)
	}

	rows, err := s.db.QueryContext(ctx,
		`SELECT character_id, character_name, role FROM guild_members WHERE guild_id = $1 ORDER BY joined_at ASC`,
		guildID)
	if err != nil {
		return nil, fmt.Errorf("guild: listing members: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var m Member
		if err := rows.Scan(&m.CharacterID, &m.Name, &m.Role); err != nil {
			return nil, fmt.Errorf("guild: scanning member: %w", err)
		}
		g.Members = append(g.Members, m)
	}
	return g, rows.Err()
}

func isUniqueConstraintErr(err error) bool {
	return err != nil && strings.Contains(err.Error(), "duplicate key value violates unique constraint")
}
