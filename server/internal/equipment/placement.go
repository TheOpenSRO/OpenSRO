package equipment

import (
	"context"

	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
)

// Where an item moved between the body and the bag lands (round 652).
//
// READ, the retail client: a worn item dropped on a bag slot sends 0x7034
// type 0 with the WORN slot as the source and `bag slot + 13` as the
// destination (FUN_007950b0, case 0x47 -> 0x46), so the client names the slot
// the player clicked -- and so does ours (a trailing int32 on OpUnequip).
//
// READ, the retail server: CGObjPC::DetachEquipItem (0x005255e0) overwrites
// that destination with the first empty bag slot before it moves the item
// (`push 0xd; call CGStorage::FindFirstEmptySlot; mov [edi+0x4],al` at
// 0x5258c6), for armour and accessories alike, and the weapon branch does the
// same. The server here does the same: Store.Unequip puts the item in the
// first free slot and the clicked slot is parsed but not used. Round 652
// first honoured the clicked slot (OURS); the user chose the original's rule.
//
// READ: CGObjPC::AttachEquipItem (0x00524cd0) calls CGStorage::SwapItem(bag,
// worn), so equipping over a worn item puts that item in the bag slot the new
// one came from. Both stores' Equip do that with the helpers below.

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
