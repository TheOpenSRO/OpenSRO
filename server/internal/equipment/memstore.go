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
	worn map[int64]map[Slot]Equipped // characterID -> slot -> the worn instance
	inv  inventory.Store
}

// NewMemStore returns an empty MemStore backed by inv.
func NewMemStore(inv inventory.Store) *MemStore {
	return &MemStore{worn: make(map[int64]map[Slot]Equipped), inv: inv}
}

// Get implements Store.
func (m *MemStore) Get(_ context.Context, characterID int64) ([]Equipped, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	var out []Equipped
	for slot, e := range m.worn[characterID] {
		e.Slot = slot
		out = append(out, e)
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
	var incoming *inventory.Slot
	for i := range invSlots {
		if invSlots[i].Index == inventorySlot {
			incoming = &invSlots[i]
			break
		}
	}
	if incoming == nil {
		return ErrInventorySlotEmpty
	}

	// A swap, as retail's CGObjPC::AttachEquipItem (0x00524cd0) does it
	// with CGStorage::SwapItem(bag, worn) (round 652, READ): the incoming
	// item leaves the bag first, then whatever was worn goes back into the
	// bag slot it left. Overwriting a filled slot still never loses the item,
	// and a full bag no longer blocks a swap.
	if err := m.inv.RemoveItem(ctx, characterID, inventorySlot, 1); err != nil {
		return err
	}
	before, _ := m.inv.List(ctx, characterID)
	displaced := wornItemID(ctx, m, characterID, slot)
	if err := m.Unequip(ctx, characterID, slot); err != nil && err != ErrSlotEmpty {
		putBack(ctx, m.inv, characterID, *incoming)
		return err
	}

	m.mu.Lock()
	if m.worn[characterID] == nil {
		m.worn[characterID] = make(map[Slot]Equipped)
	}
	// The instance moves with the item: same variance, same durability.
	m.worn[characterID][slot] = Equipped{Slot: slot, ItemID: incoming.ItemID, Variance: incoming.Variance, Durability: incoming.Durability}
	m.mu.Unlock()

	if displaced >= 0 {
		after, _ := m.inv.List(ctx, characterID)
		settleInto(ctx, m.inv, characterID, landedIndex(before, after, displaced), inventorySlot)
	}
	return nil
}

// Unequip implements Store.
func (m *MemStore) Unequip(ctx context.Context, characterID int64, slot Slot) error {
	if !validSlot(slot) {
		return ErrInvalidSlot
	}

	m.mu.Lock()
	worn, ok := m.worn[characterID][slot]
	if !ok {
		m.mu.Unlock()
		return ErrSlotEmpty
	}
	delete(m.worn[characterID], slot)
	m.mu.Unlock()

	// Putting it back can fail on a full bag. Re-equip it rather than
	// destroying it, and report the failure.
	// Back to the bag as the same instance, not a fresh roll.
	if err := m.inv.AddItemInstance(ctx, characterID, worn.ItemID, 1, worn.Instance()); err != nil {
		m.mu.Lock()
		if m.worn[characterID] == nil {
			m.worn[characterID] = make(map[Slot]Equipped)
		}
		m.worn[characterID][slot] = worn
		m.mu.Unlock()
		return err
	}
	return nil
}

// SetDurability implements Store.
func (m *MemStore) SetDurability(_ context.Context, characterID int64, slot Slot, durabilityLeft int) error {
	if !validSlot(slot) {
		return ErrInvalidSlot
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	worn, ok := m.worn[characterID][slot]
	if !ok {
		return ErrSlotEmpty
	}
	worn.Durability = durabilityLeft
	m.worn[characterID][slot] = worn
	return nil
}
