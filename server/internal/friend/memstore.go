package friend

import (
	"context"
	"sort"
	"sync"
)

// MemStore is an in-memory Store, for tests and for running the server
// without a database (see cmd/server's -in-memory). Nothing is persisted.
type MemStore struct {
	mu      sync.RWMutex
	friends map[int64]map[int64]string // characterID -> friendID -> their name
}

// NewMemStore returns an empty MemStore.
func NewMemStore() *MemStore {
	return &MemStore{friends: make(map[int64]map[int64]string)}
}

// AddFriendship implements Store.
func (m *MemStore) AddFriendship(_ context.Context, aID int64, aName string, bID int64, bName string) error {
	if aID == bID {
		return ErrCannotFriendSelf
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	_, ab := m.friends[aID][bID]
	_, ba := m.friends[bID][aID]
	if ab || ba {
		return ErrAlreadyFriends
	}
	if len(m.friends[aID]) >= MaxFriends || len(m.friends[bID]) >= MaxFriends {
		return ErrListFull
	}
	if m.friends[aID] == nil {
		m.friends[aID] = make(map[int64]string)
	}
	if m.friends[bID] == nil {
		m.friends[bID] = make(map[int64]string)
	}
	m.friends[aID][bID] = bName
	m.friends[bID][aID] = aName
	return nil
}

// ListFriends implements Store, sorted by name as the SQL store is.
func (m *MemStore) ListFriends(_ context.Context, characterID int64) ([]Friend, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	var out []Friend
	for id, friendName := range m.friends[characterID] {
		out = append(out, Friend{CharacterID: id, Name: friendName})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Name != out[j].Name {
			return out[i].Name < out[j].Name
		}
		return out[i].CharacterID < out[j].CharacterID
	})
	return out, nil
}

// RemoveFriend implements Store.
func (m *MemStore) RemoveFriend(_ context.Context, characterID, friendID int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	_, ab := m.friends[characterID][friendID]
	_, ba := m.friends[friendID][characterID]
	if !ab && !ba {
		return ErrNotFriends
	}
	delete(m.friends[characterID], friendID)
	delete(m.friends[friendID], characterID)
	return nil
}
