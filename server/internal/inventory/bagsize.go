package inventory

import (
	"context"
	"log/slog"
	"sync"

	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// The bag's pages, READ from the client (round 633). IFInventory 0x6b6620
// builds the bag from its size -- the character's InventorySize less the 13
// equipment slots (0x9d9aee `sub dl,0xd`) -- as ((size-1)>>5)+1 pages of 32
// slots, asserting at most three (IFInventory.cpp line 0xa7). A slot past the
// size on the last page is drawn locked (`interface\pet\pt_block.ddj`) and
// disabled.
const (
	BagPageSlots = 32
	MaxBagPages  = 3
	// MaxBagSlots is the most the client can show: three full pages. It is
	// MORE than the engine lets a bag grow to by its own means --
	// ExpandInventory stops the whole array (bag + 13 equipment) at
	// MaxSlotsDefault 77, or MaxSlotsExpanded 99 with the expansion quest,
	// so at most 86 bag slots, two pages and 22 slots of the third. A GM or
	// the -inventory-size flag may still set 96.
	MaxBagSlots = BagPageSlots * MaxBagPages

	// DefaultBagSlots is the size of a bag nobody has sized or expanded: the
	// default of cmd/server's -inventory-size. OURS -- three full pages, the
	// user's choice for the test server (round 633). The retail starting size
	// is a database default (_CHAR.InventorySize) that neither executable
	// carries (see SlotsPerCharacter), so it is not claimed here.
	DefaultBagSlots = MaxBagSlots
)

// EquipSlotsInEngineSize is how many of the engine's InventorySize slots are
// the equipment's: the client takes 13 off before it pages the bag (0x9d9aee),
// and the server's own array keeps the equipment at 0..12 (inventory.go,
// "HOW TO READ THE BOUNDS BELOW").
const EquipSlotsInEngineSize = 13

// SizeLookup answers a character's stored bag size, 0 when none is stored.
// character.InventorySizeStore satisfies it.
type SizeLookup interface {
	InventorySize(ctx context.Context, characterID int64) (int, error)
}

// BagCapacity is the bag's per-character slot count for a store's
// SetCapacityFunc: the character's stored size, or def when none is stored or
// it cannot be read, clamped to 1..MaxBagSlots.
func BagCapacity(sizes SizeLookup, def int) CapacityFunc {
	return func(ctx context.Context, owner int64) int {
		n := 0
		if sizes != nil {
			if stored, err := sizes.InventorySize(ctx, owner); err == nil {
				n = stored
			}
		}
		if n <= 0 {
			n = def
		}
		return ClampBagSlots(n)
	}
}

// ClampBagSlots bounds a bag size to what the client can page: 1..MaxBagSlots.
func ClampBagSlots(n int) int {
	if n < 1 {
		return 1
	}
	if n > MaxBagSlots {
		return MaxBagSlots
	}
	return n
}

// OwnerCapacity is a store that can say one owner's slot count (its
// CapacityFunc's answer, or its own Capacity()). With SetKeepHeld it is the
// REACH -- never below the owner's highest held slot + 1 -- which is what the
// bag list reports, so an item held past the size stays visible.
type OwnerCapacity interface {
	CapacityFor(ctx context.Context, owner int64) int
}

// PlacementCapacity is a store that can say the size NEW placements are held
// to: the CapacityFunc's answer (the configured or stored size), never raised
// for held items. See SetKeepHeld.
type PlacementCapacity interface {
	PlacementCapacityFor(ctx context.Context, owner int64) int
}

// CapacityOf is owner's slot count in store: its per-owner answer when it has
// one, its Capacity() otherwise. For the bag this is the reach (see
// OwnerCapacity); PlacementCapacityOf is the size new items are held to.
func CapacityOf(ctx context.Context, store Store, owner int64) int {
	if oc, ok := store.(OwnerCapacity); ok {
		return oc.CapacityFor(ctx, owner)
	}
	if store == nil {
		return 0
	}
	return store.Capacity()
}

// PlacementCapacityOf is the size a new item may be placed within for owner:
// the configured or stored size, NOT raised for items held past it
// (SetKeepHeld). Stores without the distinction answer CapacityOf.
func PlacementCapacityOf(ctx context.Context, store Store, owner int64) int {
	if pc, ok := store.(PlacementCapacity); ok {
		return pc.PlacementCapacityFor(ctx, owner)
	}
	return CapacityOf(ctx, store, owner)
}

// CapacityFor implements OwnerCapacity.
func (m *MemStore) CapacityFor(ctx context.Context, owner int64) int {
	return m.capacityFor(ctx, owner)
}

// CapacityFor implements OwnerCapacity.
func (s *SQLStore) CapacityFor(ctx context.Context, owner int64) int {
	return s.capacityFor(ctx, owner)
}

// PlacementCapacityFor implements PlacementCapacity.
func (m *MemStore) PlacementCapacityFor(ctx context.Context, owner int64) int {
	return m.placeCapacityFor(ctx, owner)
}

// PlacementCapacityFor implements PlacementCapacity.
func (s *SQLStore) PlacementCapacityFor(ctx context.Context, owner int64) int {
	return s.placeCapacityFor(ctx, owner)
}

// HighestSlotter answers the highest occupied slot index an owner has in a
// container, -1 when it holds nothing.
type HighestSlotter interface {
	HighestSlot(ctx context.Context, owner int64) (int, error)
}

// heldReach is SetKeepHeld's state (round 633's review, OURS): a bag whose
// size was set below what a character already holds -- a lower
// -inventory-size, a stored size below a held slot -- keeps the items past
// the size REACHABLE: listed, removed, moved out, their durability written.
// It does not make room for new ones. Every new placement -- AddItem's
// stacking and free-slot search, a move's target, the trade space check --
// stays within the configured size (placeCapacityFor), so the bag falls back
// to that size as the player empties the slots past it, and nothing can
// refill them. The original has no such case -- its size only grows
// (ExpandInventory) -- so this is the safe reading of a size an operator set.
type heldReach struct {
	on     bool
	logger *slog.Logger
	logged sync.Map
}

// raise answers the reach for owner: n, or the highest held slot + 1 when that
// is more. Each raise is logged once per owner and size.
func (h *heldReach) raise(ctx context.Context, store HighestSlotter, owner int64, n int) int {
	if !h.on {
		return n
	}
	hi, err := store.HighestSlot(ctx, owner)
	if err != nil || hi < n {
		return n
	}
	raised := hi + 1
	type key struct {
		owner        int64
		size, raised int
	}
	if _, seen := h.logged.LoadOrStore(key{owner, n, raised}, true); !seen && h.logger != nil {
		h.logger.Warn("bag size below a held slot: the items past it stay reachable, nothing new is placed there",
			"character_id", owner, "size", n, "highestSlot", hi, "reach", raised)
	}
	return raised
}

// SetKeepHeld turns on the held-slot reach (see heldReach) for this store:
// the bag's. Set once, before the store is used.
func (m *MemStore) SetKeepHeld(logger *slog.Logger) { m.reach.on, m.reach.logger = true, logger }

// SetKeepHeld turns on the held-slot reach (see heldReach) for this store.
func (s *SQLStore) SetKeepHeld(logger *slog.Logger) { s.reach.on, s.reach.logger = true, logger }

// HighestSlot implements HighestSlotter.
func (m *MemStore) HighestSlot(_ context.Context, owner int64) (int, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	hi := -1
	for idx := range m.slots[owner] {
		if idx > hi {
			hi = idx
		}
	}
	return hi, nil
}

// HighestSlot implements HighestSlotter.
func (s *SQLStore) HighestSlot(ctx context.Context, owner int64) (int, error) {
	var hi int
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx, s.q(`SELECT COALESCE(MAX(slot), -1) FROM %s WHERE character_id = $1`), owner).Scan(&hi)
	if err != nil {
		return -1, err
	}
	return hi, nil
}
