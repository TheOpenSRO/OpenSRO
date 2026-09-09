package equipment

import (
	"context"
	"fmt"
)

// StartingKitItems is the item a new character gets in each wearable slot.
//
// These are the game's own item ids for the China "Cotton" starter set --
// the same table the client reads to find an item's name and inventory
// icon, so a character created here shows "Cotton Hat", "Cotton Suit" and
// the rest with their real artwork rather than an unnamed placeholder:
//
//	4734 Cotton Hat        icon item\china\man_item\clothes_01_ha.ddj
//	4842 Cotton Suit                                    clothes_01_ba.ddj
//	4806 Cotton Talisman                                clothes_01_sa.ddj
//	4878 Cotton Trousers                                clothes_01_la.ddj
//	4950 Cotton Shoes                                   clothes_01_fa.ddj
//
// An operator running with different refdata can change these; an id the
// client's tables do not know still equips, it just has no name or icon.
var StartingKitItems = map[Slot]int64{
	SlotHelm:          4734,
	SlotMail:          4842,
	SlotShoulderGuard: 4806,
	SlotPants:         4878,
	SlotBoots:         4950,
}

// InventoryAdder is the slice of the inventory store a starting kit needs.
// Declared here rather than importing the inventory package so equipment
// does not depend on it.
type InventoryAdder interface {
	AddItem(ctx context.Context, characterID, itemID int64, quantity int) error
}

// GiveStartingKit dresses a newly-created character: one armour item per
// wearable slot, added to the inventory and then equipped.
//
// Why a real kit rather than a client-side default. The client renders a
// character bare because the server reports nothing equipped, and the
// tempting fix is to have it draw a default set anyway. That would make the
// character look dressed while the equipment window, the inventory and the
// server all disagree -- the same class of "looks finished, lies about what
// is behind it" this project keeps writing down. Giving the character the
// items instead keeps every one of those in agreement.
//
// Best effort by design: a character that cannot be given its kit is still
// a usable character, so failures are returned for logging rather than
// unwinding the creation.
func GiveStartingKit(ctx context.Context, inv InventoryAdder, equip Store, characterID int64) error {
	if inv == nil || equip == nil {
		return nil
	}
	for _, slot := range ArmorSlots {
		itemID, ok := StartingKitItems[slot]
		if !ok {
			continue
		}
		if err := inv.AddItem(ctx, characterID, itemID, 1); err != nil {
			return fmt.Errorf("equipment: starting kit: adding item %d for slot %v: %w", itemID, slot, err)
		}
		// AddItem fills the first free slot, and each item is equipped
		// straight out of it before the next is added, so slot 0 is always
		// the one just added.
		if err := equip.Equip(ctx, characterID, slot, 0); err != nil {
			return fmt.Errorf("equipment: starting kit: equipping slot %v: %w", slot, err)
		}
	}
	return nil
}
