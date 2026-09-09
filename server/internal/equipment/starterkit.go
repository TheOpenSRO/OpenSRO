package equipment

import (
	"context"
	"fmt"
)

// StartingArmorItemID is the item every new character is dressed in.
//
// Own design, and a placeholder like the rest of cmd/server's ref items:
// this project ships no real item table (see docs/protocol/refdata_schema.md),
// so operators importing real refdata should point this at a real starting
// armour item. What matters is that it is *a* real inventory item, so the
// equipment the client renders is equipment the character genuinely has,
// rather than something the client draws because a slot looked empty.
const StartingArmorItemID int64 = 510

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
		if err := inv.AddItem(ctx, characterID, StartingArmorItemID, 1); err != nil {
			return fmt.Errorf("equipment: starting kit: adding item for slot %v: %w", slot, err)
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
