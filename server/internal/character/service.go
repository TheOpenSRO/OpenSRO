package character

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// ServiceStore keeps what the private-server service scrolls (round 838,
// session/servicescroll.go) leave on a character. All of it is OURS: the
// archive's mall sells the scrolls (ITEM_NAME_COLOR_*, ITEM_TITLE_COLOR_*,
// ITEM_NAME_CHANGE, ITEM_ANTHEIA_STATRESET, ITEM_ETERNITY_STATSKILLRESET),
// but their effects were a private server's filter, which no binary here
// holds; the scrolls' own descriptions are the specification.
//
//   - The plate colours: the name's and the title's, as 0xAARRGGBB, 0 for
//     the default (the name's white, the title's yellow). Sent with every
//     spawn, so everyone sees them.
//   - The pending work a scroll leaves for the next login (ServicePending*):
//     a rename at character select, a stat reset, a skill reset.
//
// Kept off Character, as AutoPotionStore and HeadingStore are.
type ServiceStore interface {
	// PlateColours returns characterID's name and title colours (0 = default).
	PlateColours(ctx context.Context, characterID int64) (name, title uint32, err error)
	// SetNameColour / SetTitleColour store one colour (0 = back to default).
	SetNameColour(ctx context.Context, characterID int64, argb uint32) error
	SetTitleColour(ctx context.Context, characterID int64, argb uint32) error
	// ServicePending returns characterID's pending flags.
	ServicePending(ctx context.Context, characterID int64) (uint32, error)
	// AddServicePending sets flags, ClearServicePending clears them; each
	// returns the flags after.
	AddServicePending(ctx context.Context, characterID int64, flags uint32) (uint32, error)
	ClearServicePending(ctx context.Context, characterID int64, flags uint32) (uint32, error)
	// Rename gives characterID a new name: ErrNameTaken when another
	// character (any account, a pending deletion included, case ignored) or
	// this one already holds it.
	Rename(ctx context.Context, characterID int64, name string) error
}

// The pending flags (OURS).
const (
	// ServicePendingRename: the next Start asks for a new name first
	// (ITEM_NAME_CHANGE, "change your name on your next login").
	ServicePendingRename uint32 = 1 << iota
	// ServicePendingStatReset: the next entry resets Str, Int and the stat
	// points (ITEM_ANTHEIA_STATRESET, "once you relogin, your stats will be
	// reset").
	ServicePendingStatReset
	// ServicePendingSkillReset: the next entry forgets the learned skills
	// and refunds their SP (ITEM_ETERNITY_STATSKILLRESET, with the stats).
	ServicePendingSkillReset
)

// serviceSchema adds the service columns to the characters table (round 838).
const serviceSchema = `
ALTER TABLE characters ADD COLUMN IF NOT EXISTS name_colour BIGINT NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS title_colour BIGINT NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS service_pending INTEGER NOT NULL DEFAULT 0;
`

// memService is one character's MemStore service state.
type memService struct {
	name, title, pending uint32
}

func (m *MemStore) serviceLocked(characterID int64) (*memService, error) {
	if _, ok := m.byID[characterID]; !ok {
		return nil, ErrNotFound
	}
	if m.service == nil {
		m.service = map[int64]*memService{}
	}
	s := m.service[characterID]
	if s == nil {
		s = &memService{}
		m.service[characterID] = s
	}
	return s, nil
}

// PlateColours implements ServiceStore.
func (m *MemStore) PlateColours(_ context.Context, characterID int64) (uint32, uint32, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, err := m.serviceLocked(characterID)
	if err != nil {
		return 0, 0, err
	}
	return s.name, s.title, nil
}

// SetNameColour implements ServiceStore.
func (m *MemStore) SetNameColour(ctx context.Context, characterID int64, argb uint32) error {
	return m.setColour(ctx, characterID, argb, false)
}

// SetTitleColour implements ServiceStore.
func (m *MemStore) SetTitleColour(ctx context.Context, characterID int64, argb uint32) error {
	return m.setColour(ctx, characterID, argb, true)
}

func (m *MemStore) setColour(ctx context.Context, characterID int64, argb uint32, title bool) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, err := m.serviceLocked(characterID)
	if err != nil {
		return err
	}
	p := &s.name
	if title {
		p = &s.title
	}
	before := *p
	*p = argb
	txn.OnRollback(ctx, func() {
		m.mu.Lock()
		defer m.mu.Unlock()
		if s, err := m.serviceLocked(characterID); err == nil {
			if title {
				s.title = before
			} else {
				s.name = before
			}
		}
	})
	return nil
}

// ServicePending implements ServiceStore.
func (m *MemStore) ServicePending(_ context.Context, characterID int64) (uint32, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, err := m.serviceLocked(characterID)
	if err != nil {
		return 0, err
	}
	return s.pending, nil
}

// AddServicePending implements ServiceStore.
func (m *MemStore) AddServicePending(ctx context.Context, characterID int64, flags uint32) (uint32, error) {
	return m.changePending(ctx, characterID, func(p uint32) uint32 { return p | flags })
}

// ClearServicePending implements ServiceStore.
func (m *MemStore) ClearServicePending(ctx context.Context, characterID int64, flags uint32) (uint32, error) {
	return m.changePending(ctx, characterID, func(p uint32) uint32 { return p &^ flags })
}

func (m *MemStore) changePending(ctx context.Context, characterID int64, f func(uint32) uint32) (uint32, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, err := m.serviceLocked(characterID)
	if err != nil {
		return 0, err
	}
	before := s.pending
	s.pending = f(before)
	txn.OnRollback(ctx, func() {
		m.mu.Lock()
		defer m.mu.Unlock()
		if s, err := m.serviceLocked(characterID); err == nil {
			s.pending = before
		}
	})
	return s.pending, nil
}

// Rename implements ServiceStore.
func (m *MemStore) Rename(ctx context.Context, characterID int64, name string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	c, ok := m.byID[characterID]
	if !ok {
		return ErrNotFound
	}
	key, old := normalizeName(name), c.Name
	if m.namesTaken[key] {
		return ErrNameTaken
	}
	delete(m.namesTaken, normalizeName(old))
	m.namesTaken[key] = true
	c.Name = name
	txn.OnRollback(ctx, func() {
		m.mu.Lock()
		defer m.mu.Unlock()
		if c, ok := m.byID[characterID]; ok {
			delete(m.namesTaken, normalizeName(c.Name))
			m.namesTaken[normalizeName(old)] = true
			c.Name = old
		}
	})
	return nil
}

// PlateColours implements ServiceStore.
func (s *SQLStore) PlateColours(ctx context.Context, characterID int64) (uint32, uint32, error) {
	var name, title int64
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx, `SELECT name_colour, title_colour FROM characters WHERE id = $1`,
		characterID).Scan(&name, &title)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, 0, ErrNotFound
	}
	if err != nil {
		return 0, 0, fmt.Errorf("character: reading the plate colours: %w", err)
	}
	return uint32(name), uint32(title), nil
}

// SetNameColour implements ServiceStore.
func (s *SQLStore) SetNameColour(ctx context.Context, characterID int64, argb uint32) error {
	return s.serviceUpdate(ctx, `UPDATE characters SET name_colour = $1 WHERE id = $2`, int64(argb), characterID)
}

// SetTitleColour implements ServiceStore.
func (s *SQLStore) SetTitleColour(ctx context.Context, characterID int64, argb uint32) error {
	return s.serviceUpdate(ctx, `UPDATE characters SET title_colour = $1 WHERE id = $2`, int64(argb), characterID)
}

func (s *SQLStore) serviceUpdate(ctx context.Context, q string, args ...any) error {
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx, q, args...)
	if err != nil {
		return fmt.Errorf("character: saving the service state: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("character: checking update result: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// ServicePending implements ServiceStore.
func (s *SQLStore) ServicePending(ctx context.Context, characterID int64) (uint32, error) {
	var p int64
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx, `SELECT service_pending FROM characters WHERE id = $1`, characterID).Scan(&p)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNotFound
	}
	if err != nil {
		return 0, fmt.Errorf("character: reading the pending service: %w", err)
	}
	return uint32(p), nil
}

// AddServicePending implements ServiceStore.
func (s *SQLStore) AddServicePending(ctx context.Context, characterID int64, flags uint32) (uint32, error) {
	return s.pendingUpdate(ctx, `UPDATE characters SET service_pending = service_pending | $1 WHERE id = $2 RETURNING service_pending`,
		int64(flags), characterID)
}

// ClearServicePending implements ServiceStore.
func (s *SQLStore) ClearServicePending(ctx context.Context, characterID int64, flags uint32) (uint32, error) {
	return s.pendingUpdate(ctx, `UPDATE characters SET service_pending = service_pending & ~$1::integer WHERE id = $2 RETURNING service_pending`,
		int64(flags), characterID)
}

func (s *SQLStore) pendingUpdate(ctx context.Context, q string, flags, characterID int64) (uint32, error) {
	var p int64
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx, q, flags, characterID).Scan(&p)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNotFound
	}
	if err != nil {
		return 0, fmt.Errorf("character: changing the pending service: %w", err)
	}
	return uint32(p), nil
}

// Rename implements ServiceStore. The unique index on LOWER(name)
// (characters_name_lower) is the uniqueness test, so two renames to one name
// cannot both pass.
func (s *SQLStore) Rename(ctx context.Context, characterID int64, name string) error {
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx, `UPDATE characters SET name = $1 WHERE id = $2`, name, characterID)
	if isUniqueConstraintErr(err) {
		return ErrNameTaken
	}
	if err != nil {
		return fmt.Errorf("character: renaming: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("character: checking update result: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// SameName reports whether a and b are one name to the uniqueness rule (case
// ignored, as characters_name_lower and the MemStore's map compare them).
func SameName(a, b string) bool { return strings.EqualFold(a, b) }
