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

-- Guild points (round 525): the guild's total, _GUILD.GatheredSP (+0x3c), and
-- each member's share of it, _GUILDMEMBER.GP_Donation (+0x40) -- the two
-- fields CGuild::AddPoints (0x5c4110) raises together
-- (docs/protocol/db_bind_offsets.tsv). ADD COLUMN IF NOT EXISTS so a database
-- made before them upgrades in place.
ALTER TABLE guilds ADD COLUMN IF NOT EXISTS gathered_sp BIGINT NOT NULL DEFAULT 0;
ALTER TABLE guild_members ADD COLUMN IF NOT EXISTS gp_donation BIGINT NOT NULL DEFAULT 0;

-- The guild's level (round 528): _GUILD.Lvl (+0x38,
-- docs/protocol/db_bind_offsets.tsv), 1 to 5. The DEFAULT is
-- guild.FoundingLevel, so a guild stored before the column existed reads as
-- level 1, the cap it has always had here.
ALTER TABLE guilds ADD COLUMN IF NOT EXISTS lvl INTEGER NOT NULL DEFAULT 1;

-- A member's grant name (round 814): _GUILDMEMBER.Nickname (+0x64,
-- docs/protocol/db_bind_offsets.tsv), at most guild.MaxNicknameBytes. ''
-- for none, so a database made before the column reads every member as
-- having none.
ALTER TABLE guild_members ADD COLUMN IF NOT EXISTS nickname TEXT NOT NULL DEFAULT '';

-- The guild block's other fields (round 821): _GUILDMEMBER.Permission,
-- Contribution, the war counters and the siege role; _GUILD's notice, crest
-- revision and soldier flags. Defaults read as "none".
ALTER TABLE guild_members ADD COLUMN IF NOT EXISTS permission BIGINT NOT NULL DEFAULT 0;
ALTER TABLE guild_members ADD COLUMN IF NOT EXISTS contribution BIGINT NOT NULL DEFAULT 0;
ALTER TABLE guild_members ADD COLUMN IF NOT EXISTS war_kill BIGINT NOT NULL DEFAULT 0;
ALTER TABLE guild_members ADD COLUMN IF NOT EXISTS war_killed BIGINT NOT NULL DEFAULT 0;
ALTER TABLE guild_members ADD COLUMN IF NOT EXISTS siege_authority INTEGER NOT NULL DEFAULT 0;
ALTER TABLE guilds ADD COLUMN IF NOT EXISTS notice_title TEXT NOT NULL DEFAULT '';
ALTER TABLE guilds ADD COLUMN IF NOT EXISTS notice_body TEXT NOT NULL DEFAULT '';
ALTER TABLE guilds ADD COLUMN IF NOT EXISTS crest_rev BIGINT NOT NULL DEFAULT 0;
ALTER TABLE guilds ADD COLUMN IF NOT EXISTS soldier_flags INTEGER NOT NULL DEFAULT 0;
-- A master stored before round 821 gets the master's mask.
UPDATE guild_members gm SET permission = 4294967295 FROM guilds g
 WHERE g.id = gm.guild_id AND g.leader_id = gm.character_id AND gm.permission = 0;
`

// SQLStore is a Store backed by PostgreSQL (via the pgx driver).
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
		return nil, fmt.Errorf("guild: opening postgres connection: %w", err)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("guild: connecting to postgres: %w", err)
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
		return nil, fmt.Errorf("guild: creating schema: %w", err)
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
	// Name length after membership and before the INSERT, whose unique index
	// is the uniqueness check -- the engine's order (see Store.Create).
	if !ValidName(name) {
		return nil, ErrInvalidNameLength
	}

	var id int64
	var level int
	err = tx.QueryRowContext(ctx,
		`INSERT INTO guilds (name, leader_id, lvl) VALUES ($1, $2, $3) RETURNING id, lvl`,
		name, leaderID, FoundingLevel).Scan(&id, &level)
	if err != nil {
		if isUniqueConstraintErr(err) {
			return nil, ErrNameTaken
		}
		return nil, fmt.Errorf("guild: inserting guild: %w", err)
	}

	if _, err := tx.ExecContext(ctx,
		`INSERT INTO guild_members (guild_id, character_id, character_name, role, permission) VALUES ($1, $2, $3, $4, $5)`,
		id, leaderID, leaderName, RoleLeader, int64(PermAll)); err != nil {
		return nil, fmt.Errorf("guild: inserting leader membership: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("guild: committing: %w", err)
	}

	return &Guild{
		ID:       id,
		Name:     name,
		LeaderID: leaderID,
		Level:    level,
		Members:  []Member{{CharacterID: leaderID, Name: leaderName, Role: RoleLeader, Permission: PermAll}},
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

	var level int
	err = tx.QueryRowContext(ctx, `SELECT lvl FROM guilds WHERE id = $1`, guildID).Scan(&level)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrGuildNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("guild: checking guild existence: %w", err)
	}

	// The engine's member cap, by the guild's level (see guild.MaxMembersFor).
	// Counted inside the same transaction as the insert, so two simultaneous
	// joins cannot both see room.
	var members int
	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM guild_members WHERE guild_id = $1`, guildID).Scan(&members); err != nil {
		return nil, fmt.Errorf("guild: counting members: %w", err)
	}
	if members >= MaxMembersFor(level) {
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
			`UPDATE guild_members SET role = $1, permission = 4294967295 WHERE guild_id = $2 AND character_id = $3`,
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
	guildID, err := s.GuildIDOf(ctx, characterID)
	if err != nil {
		return nil, err
	}
	return s.Get(ctx, guildID)
}

// GuildIDOf implements Store: one query, no roster.
func (s *SQLStore) GuildIDOf(ctx context.Context, characterID int64) (int64, error) {
	var guildID int64
	err := s.db.QueryRowContext(ctx,
		`SELECT guild_id FROM guild_members WHERE character_id = $1`, characterID).Scan(&guildID)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNotInGuild
	}
	if err != nil {
		return 0, fmt.Errorf("guild: looking up membership: %w", err)
	}
	return guildID, nil
}

// Get implements Store.
func (s *SQLStore) Get(ctx context.Context, guildID int64) (*Guild, error) {
	return getGuild(ctx, s.db, guildID)
}

// querier is what getGuild reads through: the store's *sql.DB, or the
// *sql.Tx LevelUp holds, so the guild it returns is read before it commits.
type querier interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
}

func getGuild(ctx context.Context, q querier, guildID int64) (*Guild, error) {
	g := &Guild{ID: guildID}
	err := q.QueryRowContext(ctx,
		`SELECT name, leader_id, gathered_sp, lvl, notice_title, notice_body, crest_rev, soldier_flags FROM guilds WHERE id = $1`,
		guildID).Scan(&g.Name, &g.LeaderID, &g.GatheredSP, &g.Level, &g.NoticeTitle, &g.NoticeBody, &g.CrestRev, &g.SoldierFlags)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrGuildNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("guild: reading guild: %w", err)
	}

	rows, err := q.QueryContext(ctx,
		`SELECT character_id, character_name, role, gp_donation, nickname, permission, contribution, war_kill, war_killed, siege_authority
		 FROM guild_members WHERE guild_id = $1 ORDER BY joined_at ASC`,
		guildID)
	if err != nil {
		return nil, fmt.Errorf("guild: listing members: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var m Member
		var perm int64
		if err := rows.Scan(&m.CharacterID, &m.Name, &m.Role, &m.GPDonation, &m.Nickname, &perm, &m.Contribution, &m.WarKill, &m.WarKilled, &m.SiegeAuthority); err != nil {
			return nil, fmt.Errorf("guild: scanning member: %w", err)
		}
		m.Permission = Permission(uint32(perm))
		g.Members = append(g.Members, m)
	}
	return g, rows.Err()
}

// AddPoints implements Store. One transaction, so the guild's GatheredSP and
// the member's GPDonation move together or not at all (CGuild::AddPoints,
// 0x5c4110, touches both only once FUN_005d0c90 has found the member). The
// member row is updated first, then the guild row.
//
// That order does NOT rule out a deadlock with Leave. A leader's Leave locks
// the leaver's member row (DELETE), then the guild row (UPDATE leader_id),
// then the new leader's member row (UPDATE role). An AddPoints for that new
// leader running at the same moment holds the new leader's row and waits for
// the guild row, while Leave holds the guild row and waits for the new
// leader's: a cycle. Postgres detects it and aborts one side. If it aborts
// AddPoints, the caller logs the error and the batch is lost (the decorator
// never retries -- the engine does not test the request's result either). If
// it aborts Leave, the leave fails and the member can try again. No lock
// order serves both: taking the guild row first would instead cycle with
// Leave on the LEAVER's row.
func (s *SQLStore) AddPoints(ctx context.Context, guildID, characterID int64, points int) error {
	if points <= 0 {
		return nil
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("guild: beginning transaction: %w", err)
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx,
		`UPDATE guild_members SET gp_donation = gp_donation + $1 WHERE guild_id = $2 AND character_id = $3`,
		points, guildID, characterID)
	if err != nil {
		return fmt.Errorf("guild: crediting member points: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("guild: crediting member points: %w", err)
	}
	if n == 0 {
		// No such member of this guild -- or no such guild at all, which is
		// the more specific answer when it is the case.
		var exists bool
		if err := tx.QueryRowContext(ctx,
			`SELECT EXISTS(SELECT 1 FROM guilds WHERE id = $1)`, guildID).Scan(&exists); err != nil {
			return fmt.Errorf("guild: checking guild existence: %w", err)
		}
		if !exists {
			return ErrGuildNotFound
		}
		return ErrNotInGuild
	}

	res, err = tx.ExecContext(ctx,
		`UPDATE guilds SET gathered_sp = gathered_sp + $1 WHERE id = $2`, points, guildID)
	if err != nil {
		return fmt.Errorf("guild: crediting guild points: %w", err)
	}
	if n, err := res.RowsAffected(); err != nil {
		return fmt.Errorf("guild: crediting guild points: %w", err)
	} else if n == 0 {
		return ErrGuildNotFound
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("guild: committing: %w", err)
	}
	return nil
}

// LevelUp implements Store, in one transaction that locks the guild's row
// (FOR UPDATE OF g): CheckLevelUp against the row, then pay, then the
// guild-point cost off gathered_sp and lvl + 1, and the guild read back, all
// before the commit. A refusal, or pay's error, rolls the transaction back.
//
// Its lock does not add a deadlock with AddPoints or Leave: it takes the guild
// row and no member row, so it waits on neither's member-row lock while
// holding what they want.
//
// One window is left, after pay: if the UPDATE, the read-back or the commit
// fails, the gold has been taken. The error is returned, and the caller that
// took the gold gives it back (session.handleGuildLevel). For the UPDATE and
// the read-back the level was not kept: the transaction rolls back. A commit
// error is AMBIGUOUS (round 531): a connection that drops after Postgres
// committed but before its reply arrives reports an error too, and then the
// level WAS kept. Nothing here can tell the two apart, so the caller's refund
// can pay back a level the guild kept. (A ctx cancelled before the commit is
// not ambiguous: database/sql rolls the transaction back and Commit returns
// the context's error or ErrTxDone.)
func (s *SQLStore) LevelUp(ctx context.Context, characterID int64, alive bool, gold int64, pay func(gold int64) error) (*Guild, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("guild: beginning transaction: %w", err)
	}
	defer tx.Rollback()

	var (
		guildID, leaderID int64
		level             int
		gatheredSP        int64
	)
	inGuild := true
	err = tx.QueryRowContext(ctx,
		`SELECT g.id, g.leader_id, g.lvl, g.gathered_sp
		 FROM guild_members gm JOIN guilds g ON g.id = gm.guild_id
		 WHERE gm.character_id = $1
		 FOR UPDATE OF g`, characterID).Scan(&guildID, &leaderID, &level, &gatheredSP)
	if errors.Is(err, sql.ErrNoRows) {
		inGuild = false
	} else if err != nil {
		return nil, fmt.Errorf("guild: looking up the guild to level up: %w", err)
	}

	goldCost, gpCost, err := CheckLevelUp(alive, inGuild, leaderID == characterID, level, gold, gatheredSP)
	if err != nil {
		return nil, err
	}
	if pay != nil {
		if err := pay(goldCost); err != nil {
			return nil, err
		}
	}

	if _, err := tx.ExecContext(ctx,
		`UPDATE guilds SET lvl = lvl + 1, gathered_sp = gathered_sp - $1 WHERE id = $2`,
		gpCost, guildID); err != nil {
		return nil, fmt.Errorf("guild: raising the guild's level: %w", err)
	}
	g, err := getGuild(ctx, tx, guildID)
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("guild: committing: %w", err)
	}
	return g, nil
}

func isUniqueConstraintErr(err error) bool {
	return err != nil && strings.Contains(err.Error(), "duplicate key value violates unique constraint")
}

// SetNickname implements Store: CheckNickname against the actor's guild as
// one transaction holds it (the guild row locked, so a level read and the
// write agree), then the target's row.
func (s *SQLStore) SetNickname(ctx context.Context, actorID, targetID int64, nickname string, allowed func(string) bool) (*Guild, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("guild: beginning transaction: %w", err)
	}
	defer tx.Rollback()

	var guildID int64
	var level int
	err = tx.QueryRowContext(ctx,
		`SELECT g.id, g.lvl FROM guild_members gm JOIN guilds g ON g.id = gm.guild_id
		 WHERE gm.character_id = $1 FOR UPDATE OF g`, actorID).Scan(&guildID, &level)
	inGuild := true
	if errors.Is(err, sql.ErrNoRows) {
		inGuild = false
	} else if err != nil {
		return nil, fmt.Errorf("guild: looking up membership: %w", err)
	}
	if err := CheckNickname(inGuild, level, actorID, targetID, nickname, allowed); err != nil {
		return nil, err
	}
	res, err := tx.ExecContext(ctx,
		`UPDATE guild_members SET nickname = $1 WHERE guild_id = $2 AND character_id = $3`, nickname, guildID, targetID)
	if err != nil {
		return nil, fmt.Errorf("guild: setting grant name: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return nil, ErrNotInGuild
	}
	g, err := getGuild(ctx, tx, guildID)
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("guild: committing: %w", err)
	}
	return g, nil
}
