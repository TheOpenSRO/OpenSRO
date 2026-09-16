package inventory

import (
	"context"
	"sort"
	"sync"
)

// MemStore is an in-memory Store, for tests and for running the server
// without a database (see cmd/server's -in-memory). Nothing is persisted.
//
// It follows SQLStore's rules exactly: existing under-full stacks of the
// same item are topped up before an empty slot is taken, the lowest free
// slot index wins, and removing a slot's whole quantity frees the slot.
type MemStore struct {
	mu        sync.RWMutex
	slots     map[int64]map[int]*Slot // characterID -> slot index -> slot
	maxStacks MaxStackLookup
}

// NewMemStore returns an empty MemStore. maxStacks may be nil, in which
// case nothing stacks -- one item per slot, which is what SQLStore does
// for an item with no configured limit.
func NewMemStore(maxStacks MaxStackLookup) *MemStore {
	return &MemStore{slots: make(map[int64]map[int]*Slot), maxStacks: maxStacks}
}

// List implements Store.
func (m *MemStore) List(_ context.Context, characterID int64) ([]Slot, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	var out []Slot
	for _, sl := range m.slots[characterID] {
		out = append(out, *sl)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Index < out[j].Index })
	return out, nil
}

// AddItem implements Store.
func (m *MemStore) AddItem(ctx context.Context, characterID, itemID int64, quantity int) error {
	if quantity <= 0 {
		return ErrInvalidQuantity
	}
	maxStack := 1
	if m.maxStacks != nil {
		n, err := m.maxStacks.GetMaxStack(ctx, itemID)
		if err != nil {
			return err
		}
		if n > 0 {
			maxStack = n
		}
	}

	m.mu.Lock()
	defer m.mu.Unlock()

	held := m.slots[characterID]
	if held == nil {
		held = make(map[int]*Slot)
		m.slots[characterID] = held
	}

	// Plan the whole placement before applying any of it, so a request
	// that does not fit leaves the inventory untouched rather than
	// half-filled.
	remaining := quantity
	topUps := map[int]int{}
	for index := 0; index < SlotsPerCharacter && remaining > 0; index++ {
		sl := held[index]
		if sl == nil || sl.ItemID != itemID || sl.Quantity+topUps[index] >= maxStack {
			continue
		}
		add := min(maxStack-sl.Quantity-topUps[index], remaining)
		topUps[index] += add
		remaining -= add
	}
	var fresh []Slot
	for index := 0; index < SlotsPerCharacter && remaining > 0; index++ {
		if held[index] != nil {
			continue
		}
		add := min(maxStack, remaining)
		fresh = append(fresh, Slot{Index: index, ItemID: itemID, Quantity: add})
		remaining -= add
	}
	if remaining > 0 {
		return ErrNoRoom
	}

	for index, add := range topUps {
		held[index].Quantity += add
	}
	for _, sl := range fresh {
		cp := sl
		held[cp.Index] = &cp
	}
	return nil
}

// RemoveItem implements Store.
func (m *MemStore) RemoveItem(_ context.Context, characterID int64, slot int, quantity int) error {
	if slot < 0 || slot >= SlotsPerCharacter {
		return ErrInvalidSlot
	}
	// Checked BEFORE the upper bound, because `quantity > slot.Quantity` passes
	// for every negative value and the removal below is a subtraction.
	if quantity <= 0 {
		return ErrInvalidQuantity
	}

	m.mu.Lock()
	defer m.mu.Unlock()

	sl := m.slots[characterID][slot]
	if sl == nil {
		return ErrSlotEmpty
	}
	if quantity > sl.Quantity {
		return ErrInsufficientQuantity
	}
	if quantity == sl.Quantity {
		delete(m.slots[characterID], slot)
		return nil
	}
	sl.Quantity -= quantity
	return nil
}
