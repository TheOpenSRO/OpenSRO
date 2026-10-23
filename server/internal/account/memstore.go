package account

import (
	"context"
	"errors"
	"sort"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// MemStore is an in-memory Store, for tests and local development. Not
// suitable for production use — nothing is persisted.
type MemStore struct {
	mu     sync.RWMutex
	byUser map[string]*Account
	nextID int64
	// punishments are every account's (PunishmentStore), in Serial order.
	punishments []Punishment
	nextSerial  int64
	// Now is the clock Authenticate and SetBlocked read; nil is time.Now.
	// Tests set it.
	Now func() time.Time
}

func (m *MemStore) now() time.Time {
	if m.Now != nil {
		return m.Now()
	}
	return time.Now()
}

// NewMemStore returns an empty MemStore.
func NewMemStore() *MemStore {
	return &MemStore{byUser: make(map[string]*Account)}
}

// Register implements account.Registerer.
func (m *MemStore) Register(_ context.Context, username, password string) (*Account, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if _, exists := m.byUser[username]; exists {
		return nil, ErrUsernameTaken
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

// Add is a test/dev convenience wrapper around Register.
func (m *MemStore) Add(username, password string) (*Account, error) {
	return m.Register(context.Background(), username, password)
}

// SetBlocked is the pre-round-788 way to block an account, kept for tests
// and tools: blocked=true records an infinite login block (PunishLogin) whose
// guide is reason, unless one is already active; blocked=false ends the
// account's active login blocks (both login types).
func (m *MemStore) SetBlocked(username string, blocked bool, reason string) error {
	m.mu.RLock()
	acc, ok := m.byUser[username]
	m.mu.RUnlock()
	if !ok {
		return errNotFound(username)
	}
	ctx := context.Background()
	now := m.now()
	if !blocked {
		_, err := m.EndPunishments(ctx, acc.ID, now, LoginBlockTypes...)
		return err
	}
	if active, _ := m.ActivePunishments(ctx, acc.ID, now); len(activeLoginBlocks(active)) > 0 {
		return nil
	}
	_, err := m.AddPunishment(ctx, Punishment{AccountID: acc.ID, Type: PunishLogin, Executor: migratedExecutor,
		Guide: reason, Description: migratedDescription, BeginAt: now})
	return err
}

// Authenticate implements Store. The password is checked first; a right
// password on an account with an active login block is a *BlockedError.
func (m *MemStore) Authenticate(_ context.Context, username, password string) (*Account, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	acc, ok := m.byUser[username]
	if !ok || !acc.verify(password) {
		return nil, ErrInvalidCredentials
	}
	if blocks := activeLoginBlocks(m.activeLocked(acc.ID, m.now())); len(blocks) > 0 {
		return nil, &BlockedError{Punishment: blocks[0]}
	}

	cp := *acc
	return &cp, nil
}

// AccountByName implements AccountLookup.
func (m *MemStore) AccountByName(_ context.Context, username string) (*Account, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	acc, ok := m.byUser[username]
	if !ok {
		return nil, ErrNoSuchAccount
	}
	cp := *acc
	return &cp, nil
}

// AccountByID implements AccountLookup.
func (m *MemStore) AccountByID(_ context.Context, accountID int64) (*Account, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	acc := m.byID(accountID)
	if acc == nil {
		return nil, ErrNoSuchAccount
	}
	cp := *acc
	return &cp, nil
}

// AddPunishment implements PunishmentStore.
func (m *MemStore) AddPunishment(_ context.Context, p Punishment) (Punishment, error) {
	if err := checkPunishment(p); err != nil {
		return Punishment{}, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.byID(p.AccountID) == nil {
		return Punishment{}, ErrNoSuchAccount
	}
	if p.RaisedAt.IsZero() {
		p.RaisedAt = m.now()
	}
	m.nextSerial++
	p.Serial = m.nextSerial
	m.punishments = append(m.punishments, p)
	return p, nil
}

// Punishments implements PunishmentStore.
func (m *MemStore) Punishments(_ context.Context, accountID int64) ([]Punishment, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	var out []Punishment
	for i := len(m.punishments) - 1; i >= 0; i-- {
		if m.punishments[i].AccountID == accountID {
			out = append(out, m.punishments[i])
		}
	}
	return out, nil
}

// ActivePunishments implements PunishmentStore.
func (m *MemStore) ActivePunishments(_ context.Context, accountID int64, at time.Time) ([]Punishment, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.activeLocked(accountID, at), nil
}

func (m *MemStore) activeLocked(accountID int64, at time.Time) []Punishment {
	var out []Punishment
	for _, p := range m.punishments {
		if p.AccountID == accountID && p.ActiveAt(at) {
			out = append(out, p)
		}
	}
	sortActive(out)
	return out
}

// EndPunishments implements PunishmentStore.
func (m *MemStore) EndPunishments(_ context.Context, accountID int64, at time.Time, types ...PunishmentType) (int, error) {
	set := typeSet(types)
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for i := range m.punishments {
		p := &m.punishments[i]
		if p.AccountID != accountID || (len(set) > 0 && !set[p.Type]) {
			continue
		}
		if p.Infinite() || p.EndAt.After(at) {
			p.EndAt = at
			n++
		}
	}
	return n, nil
}

// sortActive orders active punishments by end, the one ending last first.
func sortActive(ps []Punishment) {
	sort.SliceStable(ps, func(i, j int) bool { return ps[i].endsAfter(ps[j]) })
}

// activeLoginBlocks keeps the login blocks of active, in its order.
func activeLoginBlocks(active []Punishment) []Punishment {
	var out []Punishment
	for _, p := range active {
		if p.Type.BlocksLogin() {
			out = append(out, p)
		}
	}
	return out
}

type errNotFound string

func (e errNotFound) Error() string { return "account: no such account: " + string(e) }

// byID finds an account by id; the map is keyed by username and stays small.
func (m *MemStore) byID(accountID int64) *Account {
	for _, acc := range m.byUser {
		if acc.ID == accountID {
			return acc
		}
	}
	return nil
}

// StorageGold implements StorageGoldStore.
func (m *MemStore) StorageGold(_ context.Context, accountID int64) (int64, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	acc := m.byID(accountID)
	if acc == nil {
		return 0, ErrNoSuchAccount
	}
	return acc.StorageGold, nil
}

// AddStorageGold implements StorageGoldStore.
func (m *MemStore) AddStorageGold(ctx context.Context, accountID int64, amount int64) error {
	if amount <= 0 {
		return errors.New("account: storage gold amount must be positive")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	acc := m.byID(accountID)
	if acc == nil {
		return ErrNoSuchAccount
	}
	acc.StorageGold += amount
	m.undoLocked(ctx, accountID, func(a *Account) { a.StorageGold -= amount })
	return nil
}

// DeductStorageGold implements StorageGoldStore.
func (m *MemStore) DeductStorageGold(ctx context.Context, accountID int64, amount int64) error {
	if amount <= 0 {
		return errors.New("account: storage gold amount must be positive")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	acc := m.byID(accountID)
	if acc == nil {
		return ErrNoSuchAccount
	}
	if acc.StorageGold < amount {
		return ErrInsufficientStorageGold
	}
	acc.StorageGold -= amount
	m.undoLocked(ctx, accountID, func(a *Account) { a.StorageGold += amount })
	return nil
}

// ChestSize implements ChestSizeStore.
func (m *MemStore) ChestSize(_ context.Context, accountID int64) (int, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	acc := m.byID(accountID)
	if acc == nil {
		return 0, ErrNoSuchAccount
	}
	return acc.ChestSize, nil
}

// ExpandChest implements ChestSizeStore, under the store's lock so two
// expansions cannot both pass the ceiling.
func (m *MemStore) ExpandChest(_ context.Context, accountID int64, base, amount, ceiling int) (int, error) {
	if amount <= 0 {
		return 0, errors.New("account: chest expansion must be positive")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	acc := m.byID(accountID)
	if acc == nil {
		return 0, ErrNoSuchAccount
	}
	next := max(acc.ChestSize, base) + amount
	if next > ceiling {
		return 0, ErrChestFull
	}
	acc.ChestSize = next
	return next, nil
}

// undoLocked registers, for an action that may fail (txn.Runner.Run), the
// reverse of a change just made to one account. Called with m.mu held.
func (m *MemStore) undoLocked(ctx context.Context, accountID int64, reverse func(a *Account)) {
	txn.OnRollback(ctx, func() {
		m.mu.Lock()
		defer m.mu.Unlock()
		if a := m.byID(accountID); a != nil {
			reverse(a)
		}
	})
}
