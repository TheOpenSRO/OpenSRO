package character

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// InventorySizeStore is each character's own bag size: the engine's
// `_CHAR.InventorySize` (charData+0xac, CInstancePC::CharData_BindDBColumns),
// which counts the 13 equipment slots, kept here as the bag's slots alone --
// OpenSRO's bag indices start at 0, apart from the equipment.
//
// The client reads the engine's value, takes the 13 off (0x9d9aee `sub
// dl,0xd`) and pages the bag by it: 32 slots a page, at most three
// (IFInventory 0x6b6620, round 633). An item or a quest grows it
// (CGObjPC::ExpandInventory, inventory.MaxSlotsDefault), a GM sets it.
//
// A stored 0 means "none stored": the caller's default applies (cmd/server's
// -inventory-size), so the flag decides the size of every character nobody
// has sized or expanded.
type InventorySizeStore interface {
	// InventorySize returns characterID's stored bag size, 0 when none.
	InventorySize(ctx context.Context, characterID int64) (int, error)
	// SetInventorySize stores characterID's bag size (0 clears it back to
	// the default). The caller bounds it.
	SetInventorySize(ctx context.Context, characterID int64, size int) error
	// ExpandInventory grows characterID's bag by amount from its stored size,
	// or from base when none is stored, refusing with ErrInventoryFull when
	// the result would pass ceiling. Returns the new size. Atomic, so two
	// expansions cannot both pass the same check.
	ExpandInventory(ctx context.Context, characterID int64, base, amount, ceiling int) (int, error)
}

// ErrInventoryFull is ExpandInventory's refusal.
var ErrInventoryFull = errors.New("character: the inventory cannot grow that far")

// InventorySize implements InventorySizeStore.
func (m *MemStore) InventorySize(_ context.Context, characterID int64) (int, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if _, ok := m.byID[characterID]; !ok {
		return 0, ErrNotFound
	}
	return m.invSize[characterID], nil
}

// SetInventorySize implements InventorySizeStore.
func (m *MemStore) SetInventorySize(_ context.Context, characterID int64, size int) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.byID[characterID]; !ok {
		return ErrNotFound
	}
	if m.invSize == nil {
		m.invSize = make(map[int64]int)
	}
	m.invSize[characterID] = size
	return nil
}

// ExpandInventory implements InventorySizeStore, under the store's lock.
func (m *MemStore) ExpandInventory(_ context.Context, characterID int64, base, amount, ceiling int) (int, error) {
	if amount <= 0 {
		return 0, fmt.Errorf("character: expanding by %d", amount)
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.byID[characterID]; !ok {
		return 0, ErrNotFound
	}
	cur := m.invSize[characterID]
	if cur <= 0 {
		cur = base
	}
	next := cur + amount
	if next > ceiling {
		return 0, ErrInventoryFull
	}
	if m.invSize == nil {
		m.invSize = make(map[int64]int)
	}
	m.invSize[characterID] = next
	return next, nil
}

// InventorySize implements InventorySizeStore.
func (s *SQLStore) InventorySize(ctx context.Context, characterID int64) (int, error) {
	var n int
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx, `SELECT inventory_size FROM characters WHERE id = $1`, characterID).Scan(&n)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNotFound
	}
	if err != nil {
		return 0, fmt.Errorf("character: reading inventory size: %w", err)
	}
	return n, nil
}

// SetInventorySize implements InventorySizeStore.
func (s *SQLStore) SetInventorySize(ctx context.Context, characterID int64, size int) error {
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx, `UPDATE characters SET inventory_size = $1 WHERE id = $2`, size, characterID)
	if err != nil {
		return fmt.Errorf("character: setting inventory size: %w", err)
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

// ExpandInventory implements InventorySizeStore. The ceiling check is in the
// statement, so a concurrent expansion cannot slip past it.
func (s *SQLStore) ExpandInventory(ctx context.Context, characterID int64, base, amount, ceiling int) (int, error) {
	if amount <= 0 {
		return 0, fmt.Errorf("character: expanding by %d", amount)
	}
	var next int
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx, `
		UPDATE characters
		SET inventory_size = (CASE WHEN inventory_size > 0 THEN inventory_size ELSE $2 END) + $3
		WHERE id = $1 AND (CASE WHEN inventory_size > 0 THEN inventory_size ELSE $2 END) + $3 <= $4
		RETURNING inventory_size`, characterID, base, amount, ceiling).Scan(&next)
	if errors.Is(err, sql.ErrNoRows) {
		if _, gerr := s.InventorySize(ctx, characterID); gerr != nil {
			return 0, gerr
		}
		return 0, ErrInventoryFull
	}
	if err != nil {
		return 0, fmt.Errorf("character: expanding inventory: %w", err)
	}
	return next, nil
}
