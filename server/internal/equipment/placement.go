package equipment

import (
	"context"

	"github.com/OpenSRO/srrevamp/server/internal/inventory"
)

// Where an item coming off the body lands in the bag (round 652).
//
// READ, the retail client: a worn item dropped on a bag slot sends 0x7034
// type 0 with the WORN slot as the source and `bag slot + 13` as the
// destination (FUN_007950b0, case 0x47 -> 0x46), so the client always names
// the slot the player clicked.
//
// READ, the retail server: CGObjPC::DetachEquipItem (0x005255e0) overwrites
// that destination with the first empty bag slot before it moves the item
// (`push 0xd; call CGStorage::FindFirstEmptySlot; mov [edi+0x4],al` at
// 0x5258c6), for armour and accessories alike, and the weapon branch does the
// same. So retail's own server puts an unequipped item in the first free
// slot whatever was clicked -- which is exactly what the user reported and
// asked to change ("please let me choose which slot").
//
// OURS, at the user's request: the clicked slot is honoured. An EMPTY target
// takes the item. An OCCUPIED one swaps when the item there may be worn in
// the slot being emptied -- retail's own rule for the other direction
// (CGObjPC::AttachEquipItem 0x00524cd0 calls CGStorage::SwapItem(bag, worn)),
// applied through Equip below. Anything else falls back to retail's first
// free slot, so nothing is refused that retail would have allowed.

// landedIndex is the bag slot an item returning to the bag landed in: the
// index holding itemID whose occupant is new, or changed, between before
// and after. -1 when none is.
func landedIndex(before, after []inventory.Slot, itemID int64) int {
	prev := make(map[int]inventory.Slot, len(before))
	for _, s := range before {
		prev[s.Index] = s
	}
	for _, s := range after {
		if s.ItemID != itemID {
			continue
		}
		p, ok := prev[s.Index]
		if !ok || p.ItemID != s.ItemID || p.Quantity != s.Quantity {
			return s.Index
		}
	}
	return -1
}

// bagSlot returns the occupant of index in list, if any.
func bagSlot(list []inventory.Slot, index int) (inventory.Slot, bool) {
	for _, s := range list {
		if s.Index == index {
			return s, true
		}
	}
	return inventory.Slot{}, false
}

// settleInto moves the item that landed at `landed` to `target` when target
// is a different, empty slot. A refused move (the target is past the
// configured size, say) leaves it where it landed: it is in the bag either
// way, and nothing is lost. Returns where the item ends up.
func settleInto(ctx context.Context, inv inventory.Store, characterID int64, landed, target int) int {
	if landed < 0 || target < 0 || landed == target {
		return landed
	}
	now, err := inv.List(ctx, characterID)
	if err != nil {
		return landed
	}
	if _, taken := bagSlot(now, target); taken {
		return landed
	}
	if err := inv.MoveItem(ctx, characterID, landed, target); err != nil {
		return landed
	}
	return target
}

// wornItemID is the item worn in slot, or -1.
func wornItemID(ctx context.Context, store Store, characterID int64, slot Slot) int64 {
	worn, err := store.Get(ctx, characterID)
	if err != nil {
		return -1
	}
	for _, w := range worn {
		if w.Slot == slot {
			return w.ItemID
		}
	}
	return -1
}

// putBack returns an item taken out of the bag to the slot it came from
// (first free, then moved), for a step that has to be undone.
func putBack(ctx context.Context, inv inventory.Store, characterID int64, s inventory.Slot) {
	before, _ := inv.List(ctx, characterID)
	if err := inv.AddItemInstance(ctx, characterID, s.ItemID, 1, inventory.Instance{Variance: s.Variance, Durability: s.Durability}); err != nil {
		return
	}
	after, _ := inv.List(ctx, characterID)
	settleInto(ctx, inv, characterID, landedIndex(before, after, s.ItemID), s.Index)
}

// UnequipOutcome says where an UnequipInto put the item.
type UnequipOutcome struct {
	// Landed is the bag slot the worn item is in now, or -1 if unknown.
	Landed int
	// Swapped is true when the target held an item that went on in its place.
	Swapped bool
}

// UnequipInto takes off what is worn in `slot` and puts it in bag slot
// `target` (see the note at the top of this file for what is READ and what
// is OURS). maySwap reports whether the item in an occupied target may be
// worn in `slot` (the session applies the item table's wearing rules); nil
// means "never swap". A negative target, or no inventory store, is the
// retail behaviour: the store's Unequip, first free slot.
func UnequipInto(ctx context.Context, store Store, inv inventory.Store, characterID int64, slot Slot, target int, maySwap func(bagSlot int) bool) (UnequipOutcome, error) {
	if target < 0 || inv == nil {
		return UnequipOutcome{Landed: -1}, store.Unequip(ctx, characterID, slot)
	}
	itemID := wornItemID(ctx, store, characterID, slot)
	if itemID < 0 {
		return UnequipOutcome{Landed: -1}, ErrSlotEmpty
	}
	before, err := inv.List(ctx, characterID)
	if err != nil {
		return UnequipOutcome{Landed: -1}, err
	}
	if _, taken := bagSlot(before, target); taken {
		if maySwap != nil && maySwap(target) {
			// The bag item goes on and the worn one takes its slot: Equip's
			// swap (AttachEquipItem's SwapItem, READ).
			if err := store.Equip(ctx, characterID, slot, target); err != nil {
				return UnequipOutcome{Landed: -1}, err
			}
			return UnequipOutcome{Landed: target, Swapped: true}, nil
		}
		// Retail's own placement: the first free slot.
		if err := store.Unequip(ctx, characterID, slot); err != nil {
			return UnequipOutcome{Landed: -1}, err
		}
		after, _ := inv.List(ctx, characterID)
		return UnequipOutcome{Landed: landedIndex(before, after, itemID)}, nil
	}
	if err := store.Unequip(ctx, characterID, slot); err != nil {
		return UnequipOutcome{Landed: -1}, err
	}
	after, err := inv.List(ctx, characterID)
	if err != nil {
		return UnequipOutcome{Landed: -1}, nil
	}
	return UnequipOutcome{Landed: settleInto(ctx, inv, characterID, landedIndex(before, after, itemID), target)}, nil
}
