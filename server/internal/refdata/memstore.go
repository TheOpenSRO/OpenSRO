package refdata

import (
	"context"
	"fmt"
	"sort"
	"sync"
)

// MemStore is an in-memory reference-data store, for tests and for running
// the server without a database (see cmd/server's -in-memory). Nothing is
// persisted, and nothing is bundled: it starts empty and is filled by the
// same Import* calls the SQL store takes, from data the operator supplies.
// See docs/LEGAL.md -- no game-balance numbers live in this repo.
type MemStore struct {
	mu          sync.RWMutex
	items       map[int64]Item
	skills      map[int64]Skill
	drops       map[int64][]MonsterDrop
	dropEntries map[int64][]DropGroupEntry
}

// NewMemStore returns an empty MemStore.
func NewMemStore() *MemStore {
	return &MemStore{
		items:       make(map[int64]Item),
		skills:      make(map[int64]Skill),
		drops:       make(map[int64][]MonsterDrop),
		dropEntries: make(map[int64][]DropGroupEntry),
	}
}

// Close implements the same shape as SQLStore.Close so callers can defer
// it either way. There is nothing to close.
func (m *MemStore) Close() error { return nil }

// ImportItems upserts every item in items by ID.
func (m *MemStore) ImportItems(_ context.Context, items []Item) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, it := range items {
		m.items[it.ID] = it
	}
	return nil
}

// GetItem returns the item with the given ID.
func (m *MemStore) GetItem(_ context.Context, id int64) (*Item, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	it, ok := m.items[id]
	if !ok {
		return nil, fmt.Errorf("refdata: querying item %d: %w", id, ErrItemNotFound)
	}
	cp := it
	return &cp, nil
}

// GetItemByCode returns the item whose CodeName is code (round 632 review:
// a composite item names its parts by code, and the engine resolves them by
// code at use time).
func (m *MemStore) GetItemByCode(_ context.Context, code string) (*Item, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	var best *Item
	for _, it := range m.items {
		if it.CodeName == code && (best == nil || it.ID < best.ID) {
			cp := it
			best = &cp
		}
	}
	if best == nil || code == "" {
		return nil, fmt.Errorf("refdata: querying item %q: %w", code, ErrItemNotFound)
	}
	return best, nil
}

// ListAll returns every imported item, ordered by ID.
func (m *MemStore) ListAll(_ context.Context) ([]*Item, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make([]*Item, 0, len(m.items))
	for _, it := range m.items {
		cp := it
		out = append(out, &cp)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

// Count returns how many items have been imported.
func (m *MemStore) Count(_ context.Context) (int, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return len(m.items), nil
}

// GetMaxStack returns an item's stack limit.
func (m *MemStore) GetMaxStack(_ context.Context, itemID int64) (int, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	it, ok := m.items[itemID]
	if !ok {
		// As in SQLStore: unknown means "no configured limit", not an
		// error. See the comment there.
		return 0, nil
	}
	return it.MaxStack, nil
}

// ImportSkills upserts every skill in skills by ID.
func (m *MemStore) ImportSkills(_ context.Context, skills []Skill) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, sk := range skills {
		m.skills[sk.ID] = sk
	}
	return nil
}

// GetSkill returns the skill with the given ID.
func (m *MemStore) GetSkill(_ context.Context, id int64) (*Skill, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	sk, ok := m.skills[id]
	if !ok {
		return nil, fmt.Errorf("refdata: querying skill %d: not found", id)
	}
	cp := sk
	return &cp, nil
}

// ListAllSkills returns every imported skill, ordered by ID.
func (m *MemStore) ListAllSkills(_ context.Context) ([]*Skill, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make([]*Skill, 0, len(m.skills))
	for _, sk := range m.skills {
		cp := sk
		out = append(out, &cp)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

// CountSkills returns how many skills have been imported.
func (m *MemStore) CountSkills(_ context.Context) (int, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return len(m.skills), nil
}

// ImportMonsterDrops replaces the drop rows for every monster mentioned in
// drops.
func (m *MemStore) ImportMonsterDrops(_ context.Context, drops []MonsterDrop) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	touched := map[int64]bool{}
	for _, d := range drops {
		if !touched[d.MonsterID] {
			m.drops[d.MonsterID] = nil
			touched[d.MonsterID] = true
		}
		m.drops[d.MonsterID] = append(m.drops[d.MonsterID], d)
	}
	return nil
}

// GetMonsterDrops returns every drop row for one monster.
func (m *MemStore) GetMonsterDrops(_ context.Context, monsterID int64) ([]*MonsterDrop, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	var out []*MonsterDrop
	for _, d := range m.drops[monsterID] {
		cp := d
		out = append(out, &cp)
	}
	return out, nil
}

// CountMonsterDrops returns how many drop rows have been imported.
func (m *MemStore) CountMonsterDrops(_ context.Context) (int, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	n := 0
	for _, d := range m.drops {
		n += len(d)
	}
	return n, nil
}

// ImportDropGroupEntries replaces the entries of every group mentioned in
// entries.
func (m *MemStore) ImportDropGroupEntries(_ context.Context, entries []DropGroupEntry) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	touched := map[int64]bool{}
	for _, e := range entries {
		if !touched[e.GroupID] {
			m.dropEntries[e.GroupID] = nil
			touched[e.GroupID] = true
		}
		m.dropEntries[e.GroupID] = append(m.dropEntries[e.GroupID], e)
	}
	return nil
}

// GetDropGroupEntries returns every entry in one drop group.
func (m *MemStore) GetDropGroupEntries(_ context.Context, groupID int64) ([]*DropGroupEntry, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	var out []*DropGroupEntry
	for _, e := range m.dropEntries[groupID] {
		cp := e
		out = append(out, &cp)
	}
	return out, nil
}

// CountDropGroupEntries returns how many drop-group entries were imported.
func (m *MemStore) CountDropGroupEntries(_ context.Context) (int, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	n := 0
	for _, e := range m.dropEntries {
		n += len(e)
	}
	return n, nil
}
