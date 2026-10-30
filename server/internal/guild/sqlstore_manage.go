package guild

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// The SQLStore's notice, permissions and hand-over (round 844, manage.go).
// The columns are round 821's (notice_title, notice_body, permission) and
// the original ones (leader_id, role): nothing to add to the schema.

// SetNotice implements ManageStore.
func (s *SQLStore) SetNotice(ctx context.Context, guildID int64, title, body string) (*Guild, error) {
	res, err := s.db.ExecContext(ctx,
		`UPDATE guilds SET notice_title = $1, notice_body = $2 WHERE id = $3`, title, body, guildID)
	if err != nil {
		return nil, fmt.Errorf("guild: setting notice: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return nil, ErrGuildNotFound
	}
	return s.Get(ctx, guildID)
}

// SetPermissions implements ManageStore: one transaction with the guild's row
// locked, every member checked before any is changed.
func (s *SQLStore) SetPermissions(ctx context.Context, guildID int64, changes []PermissionChange) (*Guild, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("guild: beginning transaction: %w", err)
	}
	defer tx.Rollback()
	var leaderID int64
	err = tx.QueryRowContext(ctx, `SELECT leader_id FROM guilds WHERE id = $1 FOR UPDATE`, guildID).Scan(&leaderID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrGuildNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("guild: locking guild: %w", err)
	}
	for _, c := range changes {
		var one int
		err := tx.QueryRowContext(ctx,
			`SELECT 1 FROM guild_members WHERE guild_id = $1 AND character_id = $2`, guildID, c.CharacterID).Scan(&one)
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotInGuild
		}
		if err != nil {
			return nil, fmt.Errorf("guild: looking up member: %w", err)
		}
		if c.CharacterID == leaderID {
			return nil, ErrIsMaster
		}
	}
	for _, c := range changes {
		if _, err := tx.ExecContext(ctx,
			`UPDATE guild_members SET permission = $1 WHERE guild_id = $2 AND character_id = $3`,
			int64(uint32(c.Permission)), guildID, c.CharacterID); err != nil {
			return nil, fmt.Errorf("guild: setting permission: %w", err)
		}
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

// TransferMaster implements ManageStore.
func (s *SQLStore) TransferMaster(ctx context.Context, guildID, toID int64) (*Guild, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("guild: beginning transaction: %w", err)
	}
	defer tx.Rollback()
	var leaderID int64
	err = tx.QueryRowContext(ctx, `SELECT leader_id FROM guilds WHERE id = $1 FOR UPDATE`, guildID).Scan(&leaderID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrGuildNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("guild: locking guild: %w", err)
	}
	if toID == leaderID {
		return nil, ErrIsMaster
	}
	var one int
	err = tx.QueryRowContext(ctx,
		`SELECT 1 FROM guild_members WHERE guild_id = $1 AND character_id = $2`, guildID, toID).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotInGuild
	}
	if err != nil {
		return nil, fmt.Errorf("guild: looking up member: %w", err)
	}
	if _, err := tx.ExecContext(ctx,
		`UPDATE guild_members SET role = $1, permission = $2, siege_authority = $3 WHERE guild_id = $4 AND role = $5`,
		RoleMember, int64(uint32(MasterHandOverPermission)), SiegeNone, guildID, RoleLeader); err != nil {
		return nil, fmt.Errorf("guild: demoting the master: %w", err)
	}
	if _, err := tx.ExecContext(ctx,
		`UPDATE guild_members SET role = $1, permission = 4294967295, siege_authority = $2 WHERE guild_id = $3 AND character_id = $4`,
		RoleLeader, SiegeCommander, guildID, toID); err != nil {
		return nil, fmt.Errorf("guild: promoting the new master: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `UPDATE guilds SET leader_id = $1 WHERE id = $2`, toID, guildID); err != nil {
		return nil, fmt.Errorf("guild: setting the leader: %w", err)
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
