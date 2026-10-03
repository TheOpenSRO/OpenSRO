package quest

import (
	"context"
	"fmt"
	"sort"
	"time"
)

// A new character's default quests (round 692).
//
// READ (this package's `_AddNewChar`, EXTERNAL data; refdata.CharDefaults):
// the procedure starts each of the race's level-1 default quests -- a
// `_CharQuest` row with Status 1 and AchievementCount 0, its QuestID the
// `_RefQuest` id of the row's CodeName.
//
// This package cannot hold them as quests yet: its Catalog is invented, and its
// ids 1 and 2 are the real QEVENT_GUIDE and QTUTORIAL_CH (questdata.txt,
// MEASURED; see quest.go), so Accept would put a new character on "Mangyang
// Cull" in place of the guide. No real quest's steps are modelled either. So
// what is stored is the grant itself: the character, the quest's CodeName and
// the Status the procedure writes, in a table of its own that nothing else
// reads. Whether the procedure would really insert each code depends on its
// join with `_RefQuest` (not exported): every code is recorded (INFERRED to
// pass it; refdata.CharDefaults.Quests). When real quests are imported, this table says which ones each
// character created since round 692 was given. Additive and idempotent: the
// table is created if absent, and a grant already stored is left as it is.

// DefaultQuestStatus is the Status `_AddNewChar` writes (READ). What 1 means
// is not in the procedure (OPEN; INFERRED: in progress).
const DefaultQuestStatus = 1

const defaultsSchema = `
CREATE TABLE IF NOT EXISTS character_default_quests (
	character_id BIGINT NOT NULL,
	quest_code   TEXT NOT NULL,
	status       SMALLINT NOT NULL,
	granted_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
	PRIMARY KEY (character_id, quest_code)
);
`

// GrantedQuest is one stored default-quest grant.
type GrantedQuest struct {
	Code   string
	Status int
}

// GrantDefaultQuests stores codes as characterID's default quests at
// DefaultQuestStatus. Implements session.CharDefaultQuests.
func (s *SQLStore) GrantDefaultQuests(ctx context.Context, characterID int64, codes []string) error {
	for _, code := range codes {
		if _, err := s.db.ExecContext(ctx,
			`INSERT INTO character_default_quests (character_id, quest_code, status) VALUES ($1, $2, $3)
			 ON CONFLICT (character_id, quest_code) DO NOTHING`, characterID, code, DefaultQuestStatus); err != nil {
			return fmt.Errorf("quest: granting default quest %s: %w", code, err)
		}
	}
	return nil
}

// DefaultQuests returns characterID's stored grants, by code in byte order
// (COLLATE "C": the database's own collation differs between hosts -- en_US
// on CI and opensro-01, C locally -- and the memory store sorts by bytes).
func (s *SQLStore) DefaultQuests(ctx context.Context, characterID int64) ([]GrantedQuest, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT quest_code, status FROM character_default_quests WHERE character_id = $1 ORDER BY quest_code COLLATE "C"`, characterID)
	if err != nil {
		return nil, fmt.Errorf("quest: listing default quests: %w", err)
	}
	defer rows.Close()
	var out []GrantedQuest
	for rows.Next() {
		var g GrantedQuest
		if err := rows.Scan(&g.Code, &g.Status); err != nil {
			return nil, fmt.Errorf("quest: scanning default quest: %w", err)
		}
		out = append(out, g)
	}
	return out, rows.Err()
}

type memGrant struct {
	status int
	at     time.Time
}

// GrantDefaultQuests implements session.CharDefaultQuests.
func (m *MemStore) GrantDefaultQuests(_ context.Context, characterID int64, codes []string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.defaults == nil {
		m.defaults = make(map[int64]map[string]memGrant)
	}
	if m.defaults[characterID] == nil {
		m.defaults[characterID] = make(map[string]memGrant)
	}
	for _, code := range codes {
		if _, ok := m.defaults[characterID][code]; !ok {
			m.defaults[characterID][code] = memGrant{status: DefaultQuestStatus, at: time.Now()}
		}
	}
	return nil
}

// DefaultQuests returns characterID's stored grants, by code in byte order.
func (m *MemStore) DefaultQuests(_ context.Context, characterID int64) ([]GrantedQuest, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	var out []GrantedQuest
	for code, g := range m.defaults[characterID] {
		out = append(out, GrantedQuest{Code: code, Status: g.status})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Code < out[j].Code })
	return out, nil
}
