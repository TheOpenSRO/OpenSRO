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

// IsAccessory answers inventory.AccessoryLookup (round 838): an earring,
// necklace or ring, TypeID 3/1/5 (China) or 3/1/12 (Europe). An unknown id
// is not one.
func (m *MemStore) IsAccessory(_ context.Context, itemID int64) (bool, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	it, found := m.items[itemID]
	return found && it.IsAccessory(), nil
}

// IsAccessory answers inventory.AccessoryLookup from PostgreSQL; see the
// MemStore method.
func (s *SQLStore) IsAccessory(ctx context.Context, itemID int64) (bool, error) {
	it, err := s.GetItem(ctx, itemID)
	if errors.Is(err, ErrItemNotFound) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("refdata: querying item %d: %w", itemID, err)
	}
	return it.IsAccessory(), nil
}

// IsAccessory reports an earring, necklace or ring: TypeID 3/1/5 or 3/1/12
// (the creation dispatcher's FUN_00488f20 test, gs 0x727590; READ).
func (it *Item) IsAccessory() bool {
	return it.TypeID1 == 3 && it.TypeID2 == 1 && (it.TypeID3 == 5 || it.TypeID3 == 12)
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
