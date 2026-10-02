package skill

import (
	"context"
	"fmt"
)

// Forgetter drops a learned skill from a character (the round 691 review): a
// skill no player could have learned -- a monster's, or another race's -- that
// a character holds anyway (learned before the learn gate refused it) is
// dropped when the server finds it. Both stores implement it; it is not part
// of Store so a test double need not.
type Forgetter interface {
	Forget(ctx context.Context, characterID, skillID int64) error
}

// Forget implements Forgetter. Forgetting a skill the character does not
// know is not an error.
func (m *MemStore) Forget(_ context.Context, characterID, skillID int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.known[characterID], skillID)
	delete(m.lastUsed[characterID], skillID)
	return nil
}

// Forget implements Forgetter.
func (s *SQLStore) Forget(ctx context.Context, characterID, skillID int64) error {
	if _, err := s.db.ExecContext(ctx,
		`DELETE FROM character_skills WHERE character_id = $1 AND skill_id = $2`, characterID, skillID); err != nil {
		return fmt.Errorf("skill: forgetting skill %d: %w", skillID, err)
	}
	return nil
}
