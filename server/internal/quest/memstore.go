package quest

import (
	"context"
	"sort"
	"sync"
)

// MemStore is an in-memory Store, for tests and -in-memory servers. Nothing
// is persisted.
type MemStore struct {
	mu       sync.RWMutex
	states   map[int64]map[int64]State     // characterID -> questID -> state
	defaults map[int64]map[string]memGrant // characterID -> quest code -> default grant (round 692, defaults.go)
}

// NewMemStore returns an empty MemStore.
func NewMemStore() *MemStore {
	return &MemStore{states: make(map[int64]map[int64]State)}
}

// States implements Store, by quest id.
func (m *MemStore) States(_ context.Context, characterID int64) ([]State, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	var out []State
	for _, s := range m.states[characterID] {
		out = append(out, s.Clone())
	}
	sort.Slice(out, func(i, j int) bool { return out[i].QuestID < out[j].QuestID })
	return out, nil
}

// Put implements Store.
func (m *MemStore) Put(_ context.Context, characterID int64, s State) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.states[characterID] == nil {
		m.states[characterID] = map[int64]State{}
	}
	m.states[characterID][s.QuestID] = s.Clone()
	return nil
}

// Delete implements Store.
func (m *MemStore) Delete(_ context.Context, characterID, questID int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.states[characterID], questID)
	return nil
}
