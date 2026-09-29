package character

import (
	"context"
	"sync"
)

// MemStore is an in-memory Store, for tests and local development. Not
// suitable for production use — nothing is persisted.
type MemStore struct {
	mu         sync.RWMutex
	byID       map[int64]*Character
	namesTaken map[string]bool // lowercased, for case-insensitive uniqueness
	nextID     int64
	// invSize is each character's own bag size (InventorySizeStore); a
	// character with no entry has none stored (0).
	invSize map[int64]int
	// headings is each character's saved heading (HeadingStore); none is 0.
	headings map[int64]float64
}

// NewMemStore returns an empty MemStore.
func NewMemStore() *MemStore {
	return &MemStore{
		byID:       make(map[int64]*Character),
		namesTaken: make(map[string]bool),
	}
}

func normalizeName(name string) string {
	out := make([]rune, 0, len(name))
	for _, r := range name {
		if r >= 'A' && r <= 'Z' {
			r += 'a' - 'A'
		}
		out = append(out, r)
	}
	return string(out)
}

// ListByAccount implements Store.
func (m *MemStore) ListByAccount(_ context.Context, accountID int64) ([]*Character, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	var out []*Character
	for _, c := range m.byID {
		if c.AccountID == accountID {
			cp := *c
			out = append(out, &cp)
		}
	}
	return out, nil
}

// Create implements Store.
func (m *MemStore) Create(_ context.Context, accountID int64, name string) (*Character, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	key := normalizeName(name)
	if m.namesTaken[key] {
		return nil, ErrNameTaken
	}

	count := 0
	for _, c := range m.byID {
		if c.AccountID == accountID {
			count++
		}
	}
	if count >= MaxPerAccount {
		return nil, ErrAccountFull
	}

	m.nextID++
	c := &Character{ID: m.nextID, AccountID: accountID, Name: name, Gold: StartingGold, HP: StartingMaxHP,
		Gender: DefaultGender, Level: StartingLevel, Str: StartingStr, Int: StartingInt}
	m.byID[c.ID] = c
	m.namesTaken[key] = true

	cp := *c
	return &cp, nil
}

// Delete implements Store.
func (m *MemStore) Delete(_ context.Context, accountID, characterID int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	c, ok := m.byID[characterID]
	if !ok || c.AccountID != accountID {
		return ErrNotFound
	}
	delete(m.byID, characterID)
	delete(m.namesTaken, normalizeName(c.Name))
	return nil
}

// AddGold implements Store.
func (m *MemStore) AddGold(_ context.Context, characterID int64, amount int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	c, ok := m.byID[characterID]
	if !ok {
		return ErrNotFound
	}
	c.Gold += amount
	return nil
}

// DeductGold implements Store.
func (m *MemStore) DeductGold(_ context.Context, characterID int64, amount int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	c, ok := m.byID[characterID]
	if !ok {
		return ErrNotFound
	}
	if c.Gold < amount {
		return ErrInsufficientGold
	}
	c.Gold -= amount
	return nil
}

// SetHwanCount implements Store.
func (s *MemStore) SetHwanCount(ctx context.Context, characterID int64, count int) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, ok := s.byID[characterID]
	if !ok {
		return ErrNotFound
	}
	c.HwanCount = count
	return nil
}

// AddStorageGold implements Store.
func (m *MemStore) AddStorageGold(_ context.Context, characterID int64, amount int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	c, ok := m.byID[characterID]
	if !ok {
		return ErrNotFound
	}
	c.StorageGold += amount
	return nil
}

// DeductStorageGold implements Store.
func (m *MemStore) DeductStorageGold(_ context.Context, characterID int64, amount int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	c, ok := m.byID[characterID]
	if !ok {
		return ErrNotFound
	}
	if c.StorageGold < amount {
		return ErrInsufficientGold
	}
	c.StorageGold -= amount
	return nil
}

// ApplyDamage implements Store.
func (m *MemStore) ApplyDamage(_ context.Context, characterID int64, amount int) (int, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	c, ok := m.byID[characterID]
	if !ok {
		return 0, false, ErrNotFound
	}
	// died is the TRANSITION to 0 (Store's contract, round 550): a blow on
	// a character already at 0 changes nothing and reports no death.
	before := c.HP
	c.HP -= amount
	if c.HP < 0 {
		c.HP = 0
	}
	return c.HP, before > 0 && c.HP == 0, nil
}

// Heal implements Store.
func (m *MemStore) Heal(_ context.Context, characterID int64, amount, maxHP int) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	c, ok := m.byID[characterID]
	if !ok {
		return 0, ErrNotFound
	}
	if amount > 0 {
		c.HP += amount
		if c.HP > maxHP {
			c.HP = maxHP
		}
	}
	return c.HP, nil
}

// ResetHP implements Store.
func (m *MemStore) ResetHP(_ context.Context, characterID int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	c, ok := m.byID[characterID]
	if !ok {
		return ErrNotFound
	}
	c.HP = c.MaxHP()
	return nil
}

// RespawnHP implements Store: back from death at RespawnFraction of maximum.
func (m *MemStore) RespawnHP(_ context.Context, characterID int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	c, ok := m.byID[characterID]
	if !ok {
		return ErrNotFound
	}
	hp := int(float64(c.MaxHP()) * RespawnFraction)
	if hp < 1 {
		// Never respawn dead: a character with a tiny maximum still comes
		// back alive.
		hp = 1
	}
	c.HP = hp
	return nil
}

// GetByID implements Store.
func (m *MemStore) GetByID(_ context.Context, characterID int64) (*Character, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	c, ok := m.byID[characterID]
	if !ok {
		return nil, ErrNotFound
	}
	cp := *c
	return &cp, nil
}

// SetGender implements Store.
func (m *MemStore) SetGender(_ context.Context, characterID int64, gender string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	c, ok := m.byID[characterID]
	if !ok {
		return ErrNotFound
	}
	c.Gender = gender
	return nil
}

// SetLeveling implements Store.
func (m *MemStore) SetLeveling(_ context.Context, characterID int64, level int, exp int64, statPoints, str, intel int) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	c, ok := m.byID[characterID]
	if !ok {
		return ErrNotFound
	}
	c.Level = level
	c.Exp = exp
	c.StatPoints = statPoints
	c.Str = str
	c.Int = intel
	return nil
}

// SavePosition implements Store.
func (m *MemStore) SavePosition(_ context.Context, characterID int64, zone, frame string, x, y, z float64) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	c, ok := m.byID[characterID]
	if !ok {
		return ErrNotFound
	}
	c.Zone, c.Frame = zone, frame
	c.PosX, c.PosY, c.PosZ = x, y, z
	return nil
}
