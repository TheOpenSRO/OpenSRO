package friend

import (
	"context"
	"sort"
	"sync"
)

// MemStore is an in-memory Store, for tests and for running the server
// without a database (see cmd/server's -in-memory). Nothing is persisted.
type MemStore struct {
	mu       sync.RWMutex
	friends  map[int64]map[int64]string // characterID -> friendID -> their name
	requests map[int64]map[int64]string // addressee -> requesterID -> requester name
}

// NewMemStore returns an empty MemStore.
func NewMemStore() *MemStore {
	return &MemStore{
		friends:  make(map[int64]map[int64]string),
		requests: make(map[int64]map[int64]string),
	}
}

// SendRequest implements Store.
func (m *MemStore) SendRequest(_ context.Context, fromID int64, fromName string, toID int64) error {
	if fromID == toID {
		return ErrCannotFriendSelf
	}

	m.mu.Lock()
	defer m.mu.Unlock()

	if _, already := m.friends[fromID][toID]; already {
		return ErrAlreadyFriends
	}
	if _, pending := m.requests[toID][fromID]; pending {
		return ErrRequestAlreadySent
	}
	if m.requests[toID] == nil {
		m.requests[toID] = make(map[int64]string)
	}
	m.requests[toID][fromID] = fromName
	return nil
}

// AcceptRequest implements Store.
func (m *MemStore) AcceptRequest(_ context.Context, characterID int64, characterName string, requesterID int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	requesterName, pending := m.requests[characterID][requesterID]
	if !pending {
		return ErrNoSuchRequest
	}
	delete(m.requests[characterID], requesterID)

	if m.friends[characterID] == nil {
		m.friends[characterID] = make(map[int64]string)
	}
	if m.friends[requesterID] == nil {
		m.friends[requesterID] = make(map[int64]string)
	}
	m.friends[characterID][requesterID] = requesterName
	m.friends[requesterID][characterID] = characterName
	return nil
}

// DeclineRequest implements Store.
func (m *MemStore) DeclineRequest(_ context.Context, characterID, requesterID int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if _, pending := m.requests[characterID][requesterID]; !pending {
		return ErrNoSuchRequest
	}
	delete(m.requests[characterID], requesterID)
	return nil
}

// ListFriends implements Store.
func (m *MemStore) ListFriends(_ context.Context, characterID int64) ([]Friend, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	var out []Friend
	for id, friendName := range m.friends[characterID] {
		out = append(out, Friend{CharacterID: id, Name: friendName})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CharacterID < out[j].CharacterID })
	return out, nil
}

// ListPendingRequests implements Store.
func (m *MemStore) ListPendingRequests(_ context.Context, characterID int64) ([]Request, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	var out []Request
	for id, requesterName := range m.requests[characterID] {
		out = append(out, Request{RequesterID: id, RequesterName: requesterName})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].RequesterID < out[j].RequesterID })
	return out, nil
}

// RemoveFriend implements Store.
func (m *MemStore) RemoveFriend(_ context.Context, characterID, friendID int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if _, are := m.friends[characterID][friendID]; !are {
		return ErrNotFriends
	}
	delete(m.friends[characterID], friendID)
	delete(m.friends[friendID], characterID)
	return nil
}
