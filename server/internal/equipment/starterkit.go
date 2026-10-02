package equipment

import (
	"context"
	"fmt"

	"github.com/OpenSRO/srrevamp/server/internal/character"
)

// StartingKitFor is the LEGACY dressing: what a character with nothing worn
// and nothing carried is given on its way into the world (cmd/server's enter
// hook), and what every character was given at creation before round 682.
// Since round 682 a new character wears what the player CHOSE on the create
// screen -- its armour set and weapon, plus the shield or ammunition the
// server adds (session.LobbyHandler, GiveKit below) -- and this kit is no
// longer how anyone is made.
//
// The ids are the item table's own defaults (every row whose code ends
// `_A_DEF` is one): the China Clothes set and the Copper Sword,
//
//	3643 ITEM_CH_M_CLOTHES_01_BA_A_DEF  Cotton Suit       3652 (woman)
//	3644 ITEM_CH_M_CLOTHES_01_LA_A_DEF  Cotton Trousers   3653
//	3645 ITEM_CH_M_CLOTHES_01_FA_A_DEF  Cotton Shoes      3654
//	3632 ITEM_CH_SWORD_01_A_DEF         Copper Sword      (either gender)
//
// which is one of the choices the create screen offers (Protector 3, Weapon
// 1), so a legacy-dressed character wears something a new one could. The
// shield a one-handed sword now comes with is not added here: the legacy kit
// stays what it was.
//
// CORRECTED (round 682). This note used to say the original's starting-kit
// rule "is not recoverable from the binaries available here", because
// SR_GameServer.exe has no 0x7007 handler and the only AgentServer was a
// modified build. Both were true and beside the point: creation is
// SR_ShardManager.exe's (0x7007 -> 0x40f010), and the rule is READ there and
// in the client (docs/protocol/charselect.md sections 4-5). The kit is what
// the customize screen sends -- one of three armour sets and one weapon -- and
// the server checks race and sex and adds a shield or ammunition itself. No
// "class chosen at creation" picks it, and the garment family and the sword
// were never the original's choice: they are the player's.
//
// A bare helm or gauntlet slot is not a bare character -- the client draws
// nothing there -- and the two slots that would look wrong bare, the mail and
// the pants, the client covers by itself; see defaultwear.go.
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

// KitPiece is one item a new character is given: the item, how many, and the
// slot it is worn in (Worn false: it goes into the bag and stays there).
type KitPiece struct {
	Slot     Slot
	ItemID   int64
	Quantity int
	Worn     bool
}

// GiveKit gives characterID each piece in order: added to the bag and, when
// Worn, equipped straight out of it. Best effort like GiveStartingKit: the
// first failure is returned for logging, and what was given before it stays.
func GiveKit(ctx context.Context, inv InventoryAdder, equip Store, characterID int64, pieces []KitPiece) error {
	if inv == nil || equip == nil {
		return nil
	}
	for _, p := range pieces {
		q := p.Quantity
		if q < 1 {
			q = 1
		}
		if err := inv.AddItem(ctx, characterID, p.ItemID, q); err != nil {
			return fmt.Errorf("equipment: kit: adding item %d: %w", p.ItemID, err)
		}
		if !p.Worn {
			continue
		}
		// AddItem fills the first free slot and each worn piece leaves it
		// at once, so on a new character's empty bag slot 0 is the one just
		// added -- the same reasoning as GiveStartingKit. Pieces that stay in
		// the bag come last (session.chosenKit orders them so).
		if err := equip.Equip(ctx, characterID, p.Slot, 0); err != nil {
			return fmt.Errorf("equipment: kit: equipping slot %v: %w", p.Slot, err)
		}
	}
	return nil
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
