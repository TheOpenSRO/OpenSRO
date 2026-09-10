package equipment

import (
	"context"
	"fmt"

	"github.com/OpenSRO/srrevamp/server/internal/character"
)

// StartingKitFor is what a new character of the given gender is given and
// wears: the game's own default starter items.
//
// The item table marks them itself. Every row whose code name ends in
// `_A_DEF` is a starter item, and for a China character there are exactly
// three armour pieces per family plus one weapon of each kind:
//
//	3643 ITEM_CH_M_CLOTHES_01_BA_A_DEF  Cotton Suit       3652 (woman)
//	3644 ITEM_CH_M_CLOTHES_01_LA_A_DEF  Cotton Trousers   3653
//	3645 ITEM_CH_M_CLOTHES_01_FA_A_DEF  Cotton Shoes      3654
//	3632 ITEM_CH_SWORD_01_A_DEF         Copper Sword      (either gender)
//
// No hat, shoulder guard or gauntlet: the game does not start anyone in
// those, and the Cotton Hat/Talisman/Wristlet this kit once gave were the
// table's `_RARE` rows, not its defaults. **Two choices are this project's**:
// the garment family (the table also carries Cloth protector and Copper
// armour defaults, and the original picks by the class chosen at creation,
// which this server does not record), and the sword among the five default
// weapons. Each row's model, name and icon then follow from the id.
//
// An operator running with different refdata can change these; an id the
// client's tables do not know still equips, it just has no name or icon.
func StartingKitFor(gender string) map[Slot]int64 {
	if gender == character.GenderChinaWoman {
		return map[Slot]int64{
			SlotMail:   3652,
			SlotPants:  3653,
			SlotBoots:  3654,
			SlotWeapon: 3632,
		}
	}
	return map[Slot]int64{
		SlotMail:   3643,
		SlotPants:  3644,
		SlotBoots:  3645,
		SlotWeapon: 3632,
	}
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
func GiveStartingKit(ctx context.Context, inv InventoryAdder, equip Store, characterID int64, gender string) error {
	if inv == nil || equip == nil {
		return nil
	}
	kit := StartingKitFor(gender)
	for _, slot := range WearableSlots {
		itemID, ok := kit[slot]
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
