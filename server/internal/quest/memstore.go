package quest

import (
	"context"
	"sort"
	"sync"
)

// MemStore is an in-memory Store, for tests and for running the server
// without a database (see cmd/server's -in-memory). Nothing is persisted.
//
// Quest progress is the one thing this package's doc comment calls out as
// worth surviving a restart, so an in-memory store is explicitly the
// development-and-test option, not a deployment one.
type MemStore struct {
	mu       sync.RWMutex
	progress map[int64]map[int64]*Progress // characterID -> questID -> progress
}

// NewMemStore returns an empty MemStore.
func NewMemStore() *MemStore {
	return &MemStore{progress: make(map[int64]map[int64]*Progress)}
}

// Accept implements Store.
func (m *MemStore) Accept(_ context.Context, characterID, questID int64) error {
	if _, ok := Catalog[questID]; !ok {
		return ErrUnknownQuest
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	if m.progress[characterID][questID] != nil {
		return ErrAlreadyAccepted
	}
	if m.progress[characterID] == nil {
		m.progress[characterID] = make(map[int64]*Progress)
	}
	m.progress[characterID][questID] = &Progress{QuestID: questID}
	return nil
}

// ListProgress implements Store.
func (m *MemStore) ListProgress(_ context.Context, characterID int64) ([]Progress, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	var out []Progress
	for _, p := range m.progress[characterID] {
		out = append(out, *p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].QuestID < out[j].QuestID })
	return out, nil
}

// RecordKill implements Store.
func (m *MemStore) RecordKill(_ context.Context, characterID int64, monsterName string) ([]Quest, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	var completed []Quest
	for questID, p := range m.progress[characterID] {
		q, ok := Catalog[questID]
		if !ok || p.Completed || q.MonsterName != monsterName {
			continue
		}
		p.Kills++
		if p.Kills >= q.TargetKills {
			p.Completed = true
			completed = append(completed, q)
		}
	}
	sort.Slice(completed, func(i, j int) bool { return completed[i].ID < completed[j].ID })
	return completed, nil
}
