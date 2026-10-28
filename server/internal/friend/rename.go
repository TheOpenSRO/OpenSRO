package friend

import (
	"context"
	"fmt"
)

// Renamer follows a character's rename (round 838, the name change scroll,
// OURS): each friend's row keeps the name it was added with
// (friendships.friend_name), which the list shows and sorts by.
type Renamer interface {
	// RenameFriend sets the name every friend list holds for characterID.
	RenameFriend(ctx context.Context, characterID int64, name string) error
}

// RenameFriend implements Renamer.
func (m *MemStore) RenameFriend(_ context.Context, characterID int64, name string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, list := range m.friends {
		if _, ok := list[characterID]; ok {
			list[characterID] = name
		}
	}
	return nil
}

// RenameFriend implements Renamer.
func (s *SQLStore) RenameFriend(ctx context.Context, characterID int64, name string) error {
	if _, err := s.db.ExecContext(ctx, `UPDATE friendships SET friend_name = $1 WHERE friend_id = $2`, name, characterID); err != nil {
		return fmt.Errorf("friend: renaming: %w", err)
	}
	return nil
}
