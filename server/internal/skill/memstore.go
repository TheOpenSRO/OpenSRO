package skill

import (
	"context"
	"sort"
	"sync"
	"time"
)

// MemStore is an in-memory Store, for tests and for running the server
// without a database (see cmd/server's -in-memory). Nothing is persisted.
type MemStore struct {
	mu        sync.RWMutex
	known     map[int64]map[int64]bool      // characterID -> skillID -> known
	lastUsed  map[int64]map[int64]time.Time // characterID -> skillID -> when
	points    map[int64]int                 // characterID -> unspent skill points
	masteries map[int64]map[int64]int       // characterID -> masteryID -> level
}

// NewMemStore returns an empty MemStore.
func NewMemStore() *MemStore {
	return &MemStore{
		known:     make(map[int64]map[int64]bool),
		lastUsed:  make(map[int64]map[int64]time.Time),
		points:    make(map[int64]int),
		masteries: make(map[int64]map[int64]int),
	}
}

// Learn implements Store.
func (m *MemStore) Learn(_ context.Context, characterID, skillID int64) error {
	if _, ok := Catalog[skillID]; !ok {
		return ErrUnknownSkill
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	if m.known[characterID][skillID] {
		return ErrAlreadyKnown
	}
	if m.known[characterID] == nil {
		m.known[characterID] = make(map[int64]bool)
	}
	m.known[characterID][skillID] = true
	return nil
}

// Knows implements Store.
func (m *MemStore) Knows(_ context.Context, characterID, skillID int64) (bool, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.known[characterID][skillID], nil
}

// KnownSkills implements Store.
func (m *MemStore) KnownSkills(_ context.Context, characterID int64) ([]int64, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	var out []int64
	for id, ok := range m.known[characterID] {
		if ok {
			out = append(out, id)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out, nil
}

// LastUsed implements Store.
func (m *MemStore) LastUsed(_ context.Context, characterID, skillID int64) (time.Time, bool, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	at, ok := m.lastUsed[characterID][skillID]
	return at, ok, nil
}

// RecordUse implements Store.
func (m *MemStore) RecordUse(_ context.Context, characterID, skillID int64, usedAt time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.lastUsed[characterID] == nil {
		m.lastUsed[characterID] = make(map[int64]time.Time)
	}
	m.lastUsed[characterID][skillID] = usedAt
	return nil
}

// SkillPoints implements Store.
func (m *MemStore) SkillPoints(_ context.Context, characterID int64) (int, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.points[characterID], nil
}

// AddSkillPoints implements Store.
func (m *MemStore) AddSkillPoints(_ context.Context, characterID int64, delta int) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	total := m.points[characterID] + delta
	if total < 0 {
		total = 0
	}
	m.points[characterID] = total
	return total, nil
}

// MasteryLevels implements Store.
func (m *MemStore) MasteryLevels(_ context.Context, characterID int64) (map[int64]int, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make(map[int64]int, len(m.masteries[characterID]))
	for id, lvl := range m.masteries[characterID] {
		out[id] = lvl
	}
	return out, nil
}

// RaiseMastery implements Store.
func (m *MemStore) RaiseMastery(_ context.Context, characterID, masteryID int64, cost, levelCap int) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.masteries[characterID] == nil {
		m.masteries[characterID] = make(map[int64]int)
	}
	current := m.masteries[characterID][masteryID]
	if current >= levelCap {
		return current, ErrMasteryCapped
	}
	if m.points[characterID] < cost {
		return current, ErrInsufficientSkillPoints
	}
	m.points[characterID] -= cost
	m.masteries[characterID][masteryID] = current + 1
	return current + 1, nil
}
