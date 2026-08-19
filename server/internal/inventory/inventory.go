// Package inventory implements this project's own per-character item
// storage: a fixed number of slots, each holding a stack of one item type
// up to that item's MaxStack (from refdata). Independent design — nothing
// here is informed by or ported from any original inventory system.
package inventory

import (
	"context"
	"errors"
)

// SlotsPerCharacter is how many inventory slots each character has. Our
// own design choice, not taken from any original game; easy to change
// later if it needs to vary by character level/class/etc.
const SlotsPerCharacter = 50

// ErrNoRoom is returned by Store.AddItem when there's no slot available to
// hold the item (all slots full, and no existing stack has spare capacity).
var ErrNoRoom = errors.New("inventory: no room for item")

// ErrInvalidSlot is returned when a requested slot index is out of range
// for SlotsPerCharacter.
var ErrInvalidSlot = errors.New("inventory: invalid slot index")

// ErrSlotEmpty is returned by Store.RemoveItem when the target slot has
// nothing in it.
var ErrSlotEmpty = errors.New("inventory: slot is empty")

// ErrInsufficientQuantity is returned by Store.RemoveItem when asked to
// remove more than the slot currently holds.
var ErrInsufficientQuantity = errors.New("inventory: not enough quantity in slot")

// Slot is one occupied inventory slot.
type Slot struct {
	Index    int
	ItemID   int64
	Quantity int
}

// MaxStackLookup resolves an item's max stack size, so Store.AddItem knows
// how many can go in one slot before it needs a new one. Satisfied by
// refdata.SQLStore in production; tests can use a trivial stub.
type MaxStackLookup interface {
	GetMaxStack(ctx context.Context, itemID int64) (int, error)
}

// Store is anything that can list, add to, and remove from a character's
// inventory.
type Store interface {
	// List returns every occupied slot for characterID, in slot-index
	// order.
	List(ctx context.Context, characterID int64) ([]Slot, error)

	// AddItem adds quantity of itemID to characterID's inventory, filling
	// any existing under-full stack of the same item first, then using
	// empty slots as needed. Returns ErrNoRoom if it doesn't fit anywhere.
	AddItem(ctx context.Context, characterID, itemID int64, quantity int) error

	// RemoveItem removes quantity from the given slot. If that empties the
	// slot exactly, the slot becomes free again.
	RemoveItem(ctx context.Context, characterID int64, slot int, quantity int) error
}
