package equipment

import (
	"context"
	"sort"
	"sync"

	"github.com/OpenSRO/srrevamp/server/internal/inventory"
)

// MemStore is an in-memory Store, for tests and for running the server
// without a database (see cmd/server's -in-memory). Nothing is persisted.
//
// Like SQLStore it owns no items of its own: equipping moves an item out
// of the character's inventory and unequipping puts it back, so the same
// inventory store has to be handed to both.
type MemStore struct {
	mu   sync.RWMutex
	worn map[int64]map[Slot]int64 // characterID -> slot -> itemID
	inv  inventory.Store
}

// NewMemStore returns an empty MemStore backed by inv.
func NewMemStore(inv inventory.Store) *MemStore {
	return &MemStore{worn: make(map[int64]map[Slot]int64), inv: inv}
}

// Get implements Store.
func (m *MemStore) Get(_ context.Context, characterID int64) ([]Equipped, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	var out []Equipped
	for slot, itemID := range m.worn[characterID] {
		out = append(out, Equipped{Slot: slot, ItemID: itemID})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Slot < out[j].Slot })
	return out, nil
}

// Equip implements Store.
func (m *MemStore) Equip(ctx context.Context, characterID int64, slot Slot, inventorySlot int) error {
	if !validSlot(slot) {
		return ErrInvalidSlot
	}

	invSlots, err := m.inv.List(ctx, characterID)
	if err != nil {
		return err
	}
	var newItemID int64 = -1
	for _, sl := range invSlots {
		if sl.Index == inventorySlot {
			newItemID = sl.ItemID
			break
		}
	}
	if newItemID == -1 {
		return ErrInventorySlotEmpty
	}

	// Whatever is worn there goes back to the bag first, so overwriting a
	// filled slot never loses the item.
	if err := m.Unequip(ctx, characterID, slot); err != nil && err != ErrSlotEmpty {
		return err
	}
	if err := m.inv.RemoveItem(ctx, characterID, inventorySlot, 1); err != nil {
		return err
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	if m.worn[characterID] == nil {
		m.worn[characterID] = make(map[Slot]int64)
	}
	m.worn[characterID][slot] = newItemID
	return nil
}

// Unequip implements Store.
func (m *MemStore) Unequip(ctx context.Context, characterID int64, slot Slot) error {
	if !validSlot(slot) {
		return ErrInvalidSlot
	}

	m.mu.Lock()
	itemID, ok := m.worn[characterID][slot]
	if !ok {
		m.mu.Unlock()
		return ErrSlotEmpty
	}
	delete(m.worn[characterID], slot)
	m.mu.Unlock()

	// Putting it back can fail on a full bag. Re-equip it rather than
	// destroying it, and report the failure.
	if err := m.inv.AddItem(ctx, characterID, itemID, 1); err != nil {
		m.mu.Lock()
		if m.worn[characterID] == nil {
			m.worn[characterID] = make(map[Slot]int64)
		}
		m.worn[characterID][slot] = itemID
		m.mu.Unlock()
		return err
	}
	return nil
}
