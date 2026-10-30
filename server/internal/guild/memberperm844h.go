package guild

import (
	"context"
	"fmt"
)

// MemberPermissionSetter sets one member's _GUILDMEMBER.Permission mask
// (round 844 lane H: the GM's /guildperm test tool, which the guild storage's
// QA needs to give a member bit 0x08; the master's own grant window is lane
// G's). Both stores implement it; it is optional on Store so a store without
// it simply refuses the tool.
type MemberPermissionSetter interface {
	SetMemberPermission(ctx context.Context, guildID, characterID int64, perm Permission) error
}

// SetMemberPermission implements MemberPermissionSetter.
func (m *MemStore) SetMemberPermission(_ context.Context, guildID, characterID int64, perm Permission) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	g, ok := m.byID[guildID]
	if !ok {
		return ErrGuildNotFound
	}
	for i := range g.Members {
		if g.Members[i].CharacterID == characterID {
			g.Members[i].Permission = perm
			return nil
		}
	}
	return ErrNotInGuild
}

// SetMemberPermission implements MemberPermissionSetter.
func (s *SQLStore) SetMemberPermission(ctx context.Context, guildID, characterID int64, perm Permission) error {
	res, err := s.db.ExecContext(ctx, `UPDATE guild_members SET permission = $1 WHERE guild_id = $2 AND character_id = $3`,
		int64(uint32(perm)), guildID, characterID)
	if err != nil {
		return fmt.Errorf("guild: setting a member's permission: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotInGuild
	}
	return nil
}
