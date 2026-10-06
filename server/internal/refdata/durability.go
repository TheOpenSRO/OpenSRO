package refdata

import (
	"context"
	"errors"
	"fmt"
)

// DurabilityRange answers inventory.DurabilityLookup from the item table:
// itemdata columns 63/64 (Dur_L, Dur_U) as exported into DurabilityMin/Max.
// ok is false for an unknown id or an item whose row carries no durability
// (Dur_U == 0: consumables, quest items), so the bag leaves those Untracked
// instead of rolling a durability they do not have.
func (m *MemStore) DurabilityRange(_ context.Context, itemID int64) (durMin, durMax float64, ok bool, err error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	it, found := m.items[itemID]
	if !found || it.DurabilityMax <= 0 {
		return 0, 0, false, nil
	}
	return it.DurabilityMin, it.DurabilityMax, true, nil
}

// DurabilityRange answers inventory.DurabilityLookup from PostgreSQL; see the
// MemStore method for the semantics.
func (s *SQLStore) DurabilityRange(ctx context.Context, itemID int64) (durMin, durMax float64, ok bool, err error) {
	it, err := s.GetItem(ctx, itemID) // cached once read (round 743's review, F3)
	if errors.Is(err, ErrItemNotFound) {
		return 0, 0, false, nil
	}
	if err != nil {
		return 0, 0, false, fmt.Errorf("refdata: querying durability of item %d: %w", itemID, err)
	}
	if it.DurabilityMax <= 0 {
		return 0, 0, false, nil
	}
	return it.DurabilityMin, it.DurabilityMax, true, nil
}
