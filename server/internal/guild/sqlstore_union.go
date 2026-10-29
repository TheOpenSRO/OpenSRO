package guild

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// The SQLStore's unions (round 842, union.go): guild_unions and
// guild_union_members (the schema in sqlstore.go).

// unionTx is what the union helpers run on (a transaction or the pool).
type unionTx interface {
	querier
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

// readUnion is union id's record (nil when it does not exist).
func readUnion(ctx context.Context, q querier, id int64) (*Union, error) {
	u := &Union{ID: id}
	var crest int64
	err := q.QueryRowContext(ctx, `SELECT crest_rev FROM guild_unions WHERE id = $1`, id).Scan(&crest)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("guild: reading the union: %w", err)
	}
	u.CrestRev = uint32(crest)
	rows, err := q.QueryContext(ctx, `SELECT guild_id, slot FROM guild_union_members WHERE union_id = $1`, id)
	if err != nil {
		return nil, fmt.Errorf("guild: reading the union's guilds: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var gid int64
		var slot int
		if err := rows.Scan(&gid, &slot); err != nil {
			return nil, fmt.Errorf("guild: reading a union guild: %w", err)
		}
		if slot >= 0 && slot < MaxAllianceGuilds {
			u.Slots[slot] = gid
		}
	}
	return u, rows.Err()
}

// unionIDOf is guildID's union id, 0 for none.
func unionIDOf(ctx context.Context, q querier, guildID int64) (int64, error) {
	var id int64
	err := q.QueryRowContext(ctx, `SELECT union_id FROM guild_union_members WHERE guild_id = $1`, guildID).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("guild: reading the guild's union: %w", err)
	}
	return id, nil
}

// UnionOf implements UnionStore.
func (s *SQLStore) UnionOf(ctx context.Context, guildID int64) (*Union, error) {
	id, err := unionIDOf(ctx, s.db, guildID)
	if err != nil || id == 0 {
		return nil, err
	}
	return readUnion(ctx, s.db, id)
}

// JoinUnion implements UnionStore.
func (s *SQLStore) JoinUnion(ctx context.Context, guildID, hostGuildID int64) (*Union, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("guild: beginning transaction: %w", err)
	}
	defer tx.Rollback()
	for _, id := range []int64{guildID, hostGuildID} {
		var one int
		err := tx.QueryRowContext(ctx, `SELECT 1 FROM guilds WHERE id = $1 FOR UPDATE`, id).Scan(&one)
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrGuildNotFound
		}
		if err != nil {
			return nil, fmt.Errorf("guild: locking a guild: %w", err)
		}
	}
	if guildID == hostGuildID {
		return nil, ErrUnionSameGuild
	}
	if id, err := unionIDOf(ctx, tx, guildID); err != nil {
		return nil, err
	} else if id != 0 {
		return nil, ErrUnionAlreadyMember
	}
	uid, err := unionIDOf(ctx, tx, hostGuildID)
	if err != nil {
		return nil, err
	}
	if uid == 0 {
		if err := tx.QueryRowContext(ctx, `INSERT INTO guild_unions DEFAULT VALUES RETURNING id`).Scan(&uid); err != nil {
			return nil, fmt.Errorf("guild: forming the union: %w", err)
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO guild_union_members (union_id, guild_id, slot) VALUES ($1, $2, 0)`, uid, hostGuildID); err != nil {
			return nil, fmt.Errorf("guild: placing the host guild: %w", err)
		}
	}
	u, err := readUnion(ctx, tx, uid)
	if err != nil {
		return nil, err
	}
	slot := -1
	for i, id := range u.Slots {
		if id == 0 {
			slot = i
			break
		}
	}
	if slot < 0 {
		return nil, ErrUnionFull
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO guild_union_members (union_id, guild_id, slot) VALUES ($1, $2, $3)`, uid, guildID, slot); err != nil {
		return nil, fmt.Errorf("guild: placing the guild: %w", err)
	}
	u.Slots[slot] = guildID
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("guild: committing: %w", err)
	}
	return u, nil
}

// LeaveUnion implements UnionStore.
func (s *SQLStore) LeaveUnion(ctx context.Context, guildID int64) (*Union, *Union, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, nil, fmt.Errorf("guild: beginning transaction: %w", err)
	}
	defer tx.Rollback()
	uid, err := unionIDOf(ctx, tx, guildID)
	if err != nil {
		return nil, nil, err
	}
	if uid == 0 {
		return nil, nil, ErrNoUnion
	}
	before, err := readUnion(ctx, tx, uid)
	if err != nil {
		return nil, nil, err
	}
	after, err := leaveUnionTx(ctx, tx, guildID)
	if err != nil {
		return nil, nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, nil, fmt.Errorf("guild: committing: %w", err)
	}
	return before, after, nil
}

// leaveUnionTx frees guildID's slot and dissolves a union left under
// MinUnionGuilds (also run before a guild is deleted); it returns the union
// after, nil when dissolved or when guildID had none.
func leaveUnionTx(ctx context.Context, tx unionTx, guildID int64) (*Union, error) {
	uid, err := unionIDOf(ctx, tx, guildID)
	if err != nil || uid == 0 {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM guild_union_members WHERE guild_id = $1`, guildID); err != nil {
		return nil, fmt.Errorf("guild: leaving the union: %w", err)
	}
	u, err := readUnion(ctx, tx, uid)
	if err != nil {
		return nil, err
	}
	if u.Count() < MinUnionGuilds {
		if _, err := tx.ExecContext(ctx, `DELETE FROM guild_unions WHERE id = $1`, uid); err != nil {
			return nil, fmt.Errorf("guild: dissolving the union: %w", err)
		}
		return nil, nil
	}
	return u, nil
}

// GuildByName implements UnionStore.
func (s *SQLStore) GuildByName(ctx context.Context, name string) (*Guild, error) {
	var id int64
	err := s.db.QueryRowContext(ctx, `SELECT id FROM guilds WHERE LOWER(name) = LOWER($1)`, name).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrGuildNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("guild: looking a guild up by name: %w", err)
	}
	return s.Get(ctx, id)
}
