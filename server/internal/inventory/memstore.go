package inventory

import (
	"context"
	"sort"
	"sync"

	"github.com/OpenSRO/OpenSRO/server/internal/durability"
	"github.com/OpenSRO/OpenSRO/server/internal/txn"
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
	// capacity is this container's slot count (SlotsPerCharacter unless
	// SetCapacity said otherwise -- the warehouse has its own).
	capacity int
	// capacityOf, when set, answers each owner's own slot count (the
	// warehouse's per-account size); see SetCapacityFunc.
	capacityOf CapacityFunc
	// reach keeps slots held past the size reachable (SetKeepHeld).
	reach heldReach
	// durabilities rolls a fresh item's instance and initialises legacy
	// rows; nil leaves every instance Untracked (see SetDurabilityLookup).
	durabilities DurabilityLookup
	// Rand is the source the instance rolls draw from; tests set it.
	Rand durability.Rand
}

// NewMemStore returns an empty MemStore. maxStacks may be nil, in which
// case nothing stacks -- one item per slot, which is what SQLStore does
// for an item with no configured limit.
func NewMemStore(maxStacks MaxStackLookup) *MemStore {
	return &MemStore{slots: make(map[int64]map[int]*Slot), maxStacks: maxStacks, capacity: SlotsPerCharacter}
}

// SetCapacity sets this container's slot count. The bag keeps
// SlotsPerCharacter; the warehouse is opened with storage.DefaultCapacity.
func (m *MemStore) SetCapacity(n int) {
	if n > 0 {
		m.capacity = n
	}
}

// Capacity implements Store.
func (m *MemStore) Capacity() int { return m.capacity }

// SetCapacityFunc makes the slot count per owner: every operation on an owner
// is bounded by f's answer for it, falling back to Capacity() when f answers
// zero or less. Set once, before the store is used.
func (m *MemStore) SetCapacityFunc(f CapacityFunc) { m.capacityOf = f }

// placeCapacityFor is owner's configured slot count, the bound on every NEW
// placement. It is called BEFORE m.mu is taken: f may reach another store.
func (m *MemStore) placeCapacityFor(ctx context.Context, owner int64) int {
	if m.capacityOf != nil {
		if n := m.capacityOf(ctx, owner); n > 0 {
			return n
		}
	}
	return m.capacity
}

// capacityFor is owner's reach: placeCapacityFor, raised to the highest held
// slot + 1 under SetKeepHeld -- the bound on reading, removing and moving OUT
// what is already held. Called before m.mu is taken (HighestSlot locks).
func (m *MemStore) capacityFor(ctx context.Context, owner int64) int {
	return m.reach.raise(ctx, m, owner, m.placeCapacityFor(ctx, owner))
}

// SetDurabilityLookup gives the store the reference data it needs to roll a
// fresh item's variance and durability. Set once, before the store is used.
func (m *MemStore) SetDurabilityLookup(l DurabilityLookup) { m.durabilities = l }

// List implements Store.
func (m *MemStore) List(ctx context.Context, characterID int64) ([]Slot, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	var out []Slot
	for _, sl := range m.slots[characterID] {
		// A row from before durability existed gets its instance on first
		// read rather than reading as broken.
		if _, err := initLegacy(ctx, m.durabilities, m.Rand, sl); err != nil {
			return nil, err
		}
		cp := *sl
		cp.MagParams = cloneParams(sl.MagParams)
		out = append(out, cp)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Index < out[j].Index })
	return out, nil
}

// AddItem implements Store.
func (m *MemStore) AddItem(ctx context.Context, characterID, itemID int64, quantity int) error {
	if quantity <= 0 {
		return ErrInvalidQuantity
	}
	inst, err := FreshInstance(ctx, m.durabilities, m.Rand, itemID)
	if err != nil {
		return err
	}
	return m.addItem(ctx, characterID, itemID, quantity, inst)
}

// AddItemInstance implements Store: an existing instance moving in.
func (m *MemStore) AddItemInstance(ctx context.Context, characterID, itemID int64, quantity int, inst Instance) error {
	if quantity <= 0 {
		return ErrInvalidQuantity
	}
	return m.addItem(ctx, characterID, itemID, quantity, inst)
}

// SetDurability implements Store.
func (m *MemStore) SetDurability(ctx context.Context, characterID int64, slot int, durabilityLeft int) error {
	if slot < 0 || slot >= m.capacityFor(ctx, characterID) {
		return ErrInvalidSlot
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	sl := m.slots[characterID][slot]
	if sl == nil {
		return ErrSlotEmpty
	}
	m.journalLocked(ctx, characterID)
	sl.Durability = durabilityLeft
	return nil
}

// SetInstance implements Store.
func (m *MemStore) SetInstance(ctx context.Context, characterID int64, slot int, inst Instance) error {
	if slot < 0 || slot >= m.capacityFor(ctx, characterID) {
		return ErrInvalidSlot
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	sl := m.slots[characterID][slot]
	if sl == nil {
		return ErrSlotEmpty
	}
	m.journalLocked(ctx, characterID)
	sl.SetInstance(inst)
	return nil
}

func (m *MemStore) addItem(ctx context.Context, characterID, itemID int64, quantity int, inst Instance) error {
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
	// New items go only within the configured size, never into the slots a
	// held item keeps reachable past it (SetKeepHeld).
	capacity := m.placeCapacityFor(ctx, characterID)

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
	for index := 0; index < capacity && remaining > 0; index++ {
		sl := held[index]
		if sl == nil || sl.ItemID != itemID || sl.Quantity+topUps[index] >= maxStack {
			continue
		}
		add := min(maxStack-sl.Quantity-topUps[index], remaining)
		topUps[index] += add
		remaining -= add
	}
	var fresh []Slot
	for index := 0; index < capacity && remaining > 0; index++ {
		if held[index] != nil {
			continue
		}
		add := min(maxStack, remaining)
		sl := Slot{Index: index, ItemID: itemID, Quantity: add}
		sl.SetInstance(inst)
		if len(fresh) == 0 {
			sl.serial = inst.Serial // a whole stack keeps its identity
		}
		fresh = append(fresh, sl)
		remaining -= add
	}
	if remaining > 0 {
		return ErrNoRoom
	}

	m.journalLocked(ctx, characterID)
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
func (m *MemStore) RemoveItem(ctx context.Context, characterID int64, slot int, quantity int) error {
	if slot < 0 || slot >= m.capacityFor(ctx, characterID) {
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
	m.journalLocked(ctx, characterID)
	if quantity == sl.Quantity {
		delete(m.slots[characterID], slot)
		return nil
	}
	sl.Quantity -= quantity
	return nil
}

// maxStackFor is AddItem's stack-limit rule in one place: one to a slot
// unless the lookup says otherwise, and a lookup that never heard of the
// item answers zero, which also means one.
func (m *MemStore) maxStackFor(ctx context.Context, itemID int64) (int, error) {
	if m.maxStacks == nil {
		return 1, nil
	}
	n, err := m.maxStacks.GetMaxStack(ctx, itemID)
	if err != nil {
		return 0, err
	}
	if n <= 0 {
		return 1, nil
	}
	return n, nil
}

// MoveItem implements Store. See the interface for the three outcomes.
//
// `from` may be any reachable slot; `to` must be within the configured size,
// and a slot held past it (SetKeepHeld) may be emptied or merged from but not
// swapped into -- a swap would place the other item there.
func (m *MemStore) MoveItem(ctx context.Context, characterID int64, from, to int) error {
	reach := m.capacityFor(ctx, characterID)
	place := m.placeCapacityFor(ctx, characterID)
	if from < 0 || from >= reach || to < 0 || to >= place {
		return ErrInvalidSlot
	}
	if from == to {
		return nil
	}

	m.mu.Lock()
	defer m.mu.Unlock()

	held := m.slots[characterID]
	src := held[from]
	if src == nil {
		return ErrSlotEmpty
	}
	dst := held[to]
	m.journalLocked(ctx, characterID)

	// Plain move into a free slot.
	if dst == nil {
		src.Index = to
		held[to] = src
		delete(held, from)
		return nil
	}

	// Same item: merge what fits. A stack limit of one (a non-stackable, or
	// an item the lookup does not know) never merges, so two swords swap.
	if dst.ItemID == src.ItemID {
		limit, err := m.maxStackFor(ctx, src.ItemID)
		if err != nil {
			return err
		}
		if space := limit - dst.Quantity; space > 0 {
			moved := min(space, src.Quantity)
			dst.Quantity += moved
			src.Quantity -= moved
			if src.Quantity == 0 {
				delete(held, from)
			}
			return nil
		}
	}

	// Different items, or nowhere to merge into: swap the two slots -- unless
	// that would put the other item into a slot past the size.
	if from >= place {
		return ErrInvalidSlot
	}
	src.Index, dst.Index = to, from
	held[to], held[from] = src, dst
	return nil
}

// journalLocked records owner's slots as they are now, so a failed action
// (txn.Runner.Run) puts them back. Called with m.mu held, before a change;
// outside an action it does nothing.
func (m *MemStore) journalLocked(ctx context.Context, owner int64) {
	if !txn.InAction(ctx) {
		return
	}
	var snap map[int]*Slot
	if held, ok := m.slots[owner]; ok {
		snap = make(map[int]*Slot, len(held))
		for i, sl := range held {
			cp := *sl
			cp.MagParams = cloneParams(sl.MagParams)
			snap[i] = &cp
		}
	}
	txn.OnRollback(ctx, func() {
		m.mu.Lock()
		defer m.mu.Unlock()
		if snap == nil {
			delete(m.slots, owner)
			return
		}
		m.slots[owner] = snap
	})
}

// TakeItem implements Taker.
func (m *MemStore) TakeItem(ctx context.Context, owner int64, slot, quantity int, wantItem int64) (int64, Instance, error) {
	if slot < 0 || slot >= m.capacityFor(ctx, owner) {
		return 0, Instance{}, ErrInvalidSlot
	}
	if quantity <= 0 {
		return 0, Instance{}, ErrInvalidQuantity
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	sl := m.slots[owner][slot]
	if sl == nil {
		return 0, Instance{}, ErrSlotEmpty
	}
	if wantItem != 0 && sl.ItemID != wantItem {
		return 0, Instance{}, ErrItemChanged
	}
	if quantity > sl.Quantity {
		return 0, Instance{}, ErrInsufficientQuantity
	}
	m.journalLocked(ctx, owner)
	inst := sl.Instance()
	itemID := sl.ItemID
	if quantity == sl.Quantity {
		inst.Serial = sl.serial
		delete(m.slots[owner], slot)
	} else {
		sl.Quantity -= quantity
	}
	return itemID, inst, nil
}
