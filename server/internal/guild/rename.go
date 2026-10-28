package guild

import (
	"context"
	"fmt"
)

// MemberRenamer follows a character's rename (round 838, the name change
// scroll, OURS): a member row keeps the name it joined with
// (guild_members.character_name), which the member list shows.
type MemberRenamer interface {
	// RenameMember sets characterID's member name; a character in no guild
	// is not an error.
	RenameMember(ctx context.Context, characterID int64, name string) error
}

// RenameMember implements MemberRenamer.
func (m *MemStore) RenameMember(_ context.Context, characterID int64, name string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	gid, ok := m.ofChar[characterID]
	if !ok {
		return nil
	}
	if g := m.byID[gid]; g != nil {
		for i := range g.Members {
			if g.Members[i].CharacterID == characterID {
				g.Members[i].Name = name
			}
		}
	}
	return nil
}

// RenameMember implements MemberRenamer.
func (s *SQLStore) RenameMember(ctx context.Context, characterID int64, name string) error {
	if _, err := s.db.ExecContext(ctx, `UPDATE guild_members SET character_name = $1 WHERE character_id = $2`, name, characterID); err != nil {
		return fmt.Errorf("guild: renaming a member: %w", err)
	}
	return nil
}
