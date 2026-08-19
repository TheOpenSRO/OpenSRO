package account

import (
	"context"
	"sync"
)

// MemStore is an in-memory Store, for tests and local development. Not
// suitable for production use — nothing is persisted.
type MemStore struct {
	mu     sync.RWMutex
	byUser map[string]*Account
	nextID int64
}

// NewMemStore returns an empty MemStore.
func NewMemStore() *MemStore {
	return &MemStore{byUser: make(map[string]*Account)}
}

// Add registers a new account with the given username and plaintext
// password (hashed internally), returning the created Account. Returns an
// error if the username is already taken.
func (m *MemStore) Add(username, password string) (*Account, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if _, exists := m.byUser[username]; exists {
		return nil, errAlreadyExists(username)
	}

	hash, err := HashPassword(password)
	if err != nil {
		return nil, err
	}

	m.nextID++
	acc := &Account{ID: m.nextID, Username: username, PasswordHash: hash}
	m.byUser[username] = acc
	return acc, nil
}

// SetBlocked sets an existing account's blocked status and reason.
func (m *MemStore) SetBlocked(username string, blocked bool, reason string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	acc, ok := m.byUser[username]
	if !ok {
		return errNotFound(username)
	}
	acc.Blocked = blocked
	acc.BlockReason = reason
	return nil
}

// Authenticate implements Store.
func (m *MemStore) Authenticate(_ context.Context, username, password string) (*Account, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	acc, ok := m.byUser[username]
	if !ok || !acc.verify(password) {
		return nil, ErrInvalidCredentials
	}
	if acc.Blocked {
		return nil, ErrBlocked
	}

	cp := *acc
	return &cp, nil
}

type errAlreadyExists string

func (e errAlreadyExists) Error() string { return "account: username already exists: " + string(e) }

type errNotFound string

func (e errNotFound) Error() string { return "account: no such account: " + string(e) }
