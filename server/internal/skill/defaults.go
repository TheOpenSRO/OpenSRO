package skill

import (
	"context"
	"fmt"
)

// A new character's default masteries (round 692). READ (this package's
// `_AddNewChar`, EXTERNAL data; refdata.CharDefaults): the procedure inserts
// each of the race's default masteries into `_CharSkillMastery` at Level 0.
// Here that is a character_mastery_levels row at level 0. Every reader of the
// levels treats a level-0 row as it treated an absent one (a sum, a maximum,
// a lookup that defaults to 0), and RaiseMastery takes a level-0 row to 1 as
// it takes an absent one; a count of rows, though, now counts the defaults --
// a rule that means "masteries chosen" must count levels above 0.

// SeedMasteries gives characterID each of masteryIDs at level 0, leaving any
// it already has as it is. Implements session.CharDefaultSkills.
func (s *SQLStore) SeedMasteries(ctx context.Context, characterID int64, masteryIDs []int64) error {
	for _, id := range masteryIDs {
		if _, err := s.db.ExecContext(ctx,
			`INSERT INTO character_mastery_levels (character_id, mastery_id, level) VALUES ($1, $2, 0)
			 ON CONFLICT (character_id, mastery_id) DO NOTHING`, characterID, id); err != nil {
			return fmt.Errorf("skill: seeding mastery %d: %w", id, err)
		}
	}
	return nil
}

// SeedMasteries implements session.CharDefaultSkills.
func (m *MemStore) SeedMasteries(_ context.Context, characterID int64, masteryIDs []int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.masteries[characterID] == nil {
		m.masteries[characterID] = make(map[int64]int)
	}
	for _, id := range masteryIDs {
		if _, ok := m.masteries[characterID][id]; !ok {
			m.masteries[characterID][id] = 0
		}
	}
	return nil
}

// MasterySetter writes a mastery's level outright (round 877: the GM's
// /mastery, OURS -- a test tool with no retail counterpart; the original's
// masteries only rise, through Mastery_LevelUp).
type MasterySetter interface {
	SetMasteryLevel(ctx context.Context, characterID, masteryID int64, level int) error
}

// SetMasteryLevel implements MasterySetter.
func (s *SQLStore) SetMasteryLevel(ctx context.Context, characterID, masteryID int64, level int) error {
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO character_mastery_levels (character_id, mastery_id, level) VALUES ($1, $2, $3)
		 ON CONFLICT (character_id, mastery_id) DO UPDATE SET level = EXCLUDED.level`, characterID, masteryID, level); err != nil {
		return fmt.Errorf("skill: setting mastery %d: %w", masteryID, err)
	}
	return nil
}

// SetMasteryLevel implements MasterySetter.
func (m *MemStore) SetMasteryLevel(_ context.Context, characterID, masteryID int64, level int) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.masteries[characterID] == nil {
		m.masteries[characterID] = make(map[int64]int)
	}
	m.masteries[characterID][masteryID] = level
	return nil
}
