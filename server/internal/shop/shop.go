// Package shop implements a basic NPC vendor: buying items from the refdata
// catalog with character gold.
//
// Prices are REAL, from the client's own itemdata (_RefObjCommon Price and
// SellPrice columns): a Copper Sword buys at 890 and sells at 427, an HP
// potion 600/210 -- confirmed against real rows and pinned by the neighbouring
// columns lining up with ItemTableReader (see docs/protocol/refdata_schema.md).
//
// This corrects an earlier conclusion. Restoring SRO_VT_SHARD.Bak (2026-08-22)
// found no vendor price in the *database* _RefObjItem, only the item-mall
// _RefPricePolicyOfItem, and the shop fell back to an own-design formula. But
// the client itemdata.txt does carry Price/SellPrice; the DB export had simply
// dropped them. So Price/SellValue return the real number when the import has
// it, and keep the formula only as a fallback for an import that predates the
// price columns.
package shop

import (
	"context"
	"errors"
	"fmt"
	"sync"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// ErrItemNotFound is returned by Service.Buy when itemID isn't in the
// catalog.
var ErrItemNotFound = errors.New("shop: item not found")

// ErrSlotEmpty is returned by Service.Sell when the inventory slot to sell
// from holds nothing.
// ErrCannotSell means the item carries no CanSell permission -- the engine's
// own flag, refused at a shop with 0x183b UIIT_MSG_STRGERR_CANNOT_DEAL_AT_SHOP.
var ErrCannotSell = errors.New("shop: this item cannot be sold")

var ErrSlotEmpty = errors.New("shop: nothing in that slot")

// ErrNothingToSell is returned by Service.Sell for a non-positive quantity.
var ErrNothingToSell = errors.New("shop: quantity must be positive")

// MaxItemsPerShopTab is 240, the highest slot index a shop tab addresses.
//
// **Recovered 2026-09-17 from the engine's own assert**, which names the
// constant in words:
//
//	ReferenceData.h line 1809:
//	  "0 <= pGoods->m_btSlotIndex && pGoods->m_btSlotIndex < MAX_ITEM_PER_SHOP_TAB"
//
// and compiles to a single unsigned comparison, because `m_btSlotIndex` is a
// byte and `0 <= x` is vacuous for one:
//
//	720a81  cmp BYTE PTR [esi+0x48],0xf0
//	720a85  jb  pass
//
// So the constant is 0xf0 = 240, and `m_btSlotIndex` lives at `+0x48` of the
// goods record.
//
// This is a bound on the slot INDEX, not a statement that a tab holds 240
// items -- the real shop tables are far sparser. OpenSRO does not model shop
// tabs at all yet, so nothing enforces it; it is recorded for when it does.
const MaxItemsPerShopTab = 240

// basePrice and statMultiplier are this project's own pricing formula
// constants -- the fallback when an import has no real price, not derived
// from any original economy data. sellFallbackDivisor likewise: a buy-back
// at half is a disclosed guess, used only when the real SellPrice is absent.
const (
	basePrice           = 100
	statMultiplier      = 10
	sellFallbackDivisor = 2
)

// Price is the NPC buy price in gold: the item's real price from the client's
// own itemdata when the import carries it, else the own-design formula (a flat
// base plus a multiple of the item's best stats). The real number is what a
// player pays, so it wins.
func Price(item *refdata.Item) int64 {
	if item.Price > 0 {
		return item.Price
	}
	statTotal := item.PhysAttackMax + item.MagAttackMax + item.PhysDefenseMax + item.MagDefenseMax
	return basePrice + int64(statTotal*statMultiplier)
}

// SellValue is what the NPC pays to buy an item back: the item's real
// SellPrice when present, else a disclosed fraction of the buy price. On real
// rows SellPrice is well under Price (Copper Sword 890 buy, 427 sell), so
// selling at a loss is grounded rather than invented.
func SellValue(item *refdata.Item) int64 {
	if item.SellPrice > 0 {
		return item.SellPrice
	}
	return Price(item) / sellFallbackDivisor
}

// ItemLookup resolves item stats, for pricing, existence checks, and
// building the shop's catalog. Satisfied by refdata.SQLStore in
// production.
type ItemLookup interface {
	GetItem(ctx context.Context, id int64) (*refdata.Item, error)
	ListAll(ctx context.Context) ([]*refdata.Item, error)
}

// CatalogEntry is one item available for purchase: its computed price
// plus enough stats to tell items apart in a UI, since refdata.Item has
// no display name (the curated schema never included one -- see
// docs/protocol/refdata_schema.md).
type CatalogEntry struct {
	ItemID         int64
	Price          int64
	ItemClass      int
	PhysAttackMax  float64
	PhysDefenseMax float64
}

// Service is the NPC shop: buy items from the catalog with character gold.
// Not itself backed by a database table -- it's a computed service over
// character (gold), inventory (receiving items), and the refdata catalog
// (pricing).
type Service struct {
	Gold  character.Store
	Inv   inventory.Store
	Items ItemLookup

	// The buy-back book (round 728, buyback.go): each character's last
	// BuybackSlots sales, oldest first.
	soldMu sync.Mutex
	sold   map[int64][]Sold
}

// Buy attempts to purchase quantity of itemID for characterID: looks up the
// price, then deducts the gold and adds the item in ONE transaction (round
// 743), so a purchase that does not fit (no room) or fails costs nothing --
// there is no refund step to fail.
func (s *Service) Buy(ctx context.Context, characterID, itemID int64, quantity int) error {
	item, err := s.Items.GetItem(ctx, itemID)
	if err != nil {
		return ErrItemNotFound
	}
	return s.buy(ctx, characterID, itemID, quantity, Price(item)*int64(quantity))
}

// BuyFree is Buy at no cost (round 783, OURS): the Test Items NPC's goods,
// which its definition gives away (internal/testnpc). No gold is deducted or
// even tested, so a character with none still gets the item; the item must
// exist and fit, as any buy's.
func (s *Service) BuyFree(ctx context.Context, characterID, itemID int64, quantity int) error {
	if _, err := s.Items.GetItem(ctx, itemID); err != nil {
		return ErrItemNotFound
	}
	return s.buy(ctx, characterID, itemID, quantity, 0)
}

// BuyFreeInstance is BuyFree with the instance the item is made with (round
// 786, OURS: the Test Items NPC's +12 full-blue equipment) instead of a
// fresh roll.
func (s *Service) BuyFreeInstance(ctx context.Context, characterID, itemID int64, quantity int, inst inventory.Instance) error {
	if _, err := s.Items.GetItem(ctx, itemID); err != nil {
		return ErrItemNotFound
	}
	return txn.For(s.Gold, s.Inv).Run(ctx, func(ctx context.Context) error {
		if err := s.Inv.AddItemInstance(ctx, characterID, itemID, quantity, inst); err != nil {
			return fmt.Errorf("shop: adding item to inventory: %w", err)
		}
		return nil
	})
}

func (s *Service) buy(ctx context.Context, characterID, itemID int64, quantity int, cost int64) error {
	return txn.For(s.Gold, s.Inv).Run(ctx, func(ctx context.Context) error {
		if cost > 0 {
			if err := s.Gold.DeductGold(ctx, characterID, cost); err != nil {
				return fmt.Errorf("shop: %w", err)
			}
		}
		if err := s.Inv.AddItem(ctx, characterID, itemID, quantity); err != nil {
			return fmt.Errorf("shop: adding item to inventory: %w", err)
		}
		return nil
	})
}

// Sell sells quantity from the given inventory slot back to the NPC: it reads
// the slot's own item and count from the server's inventory (never trusting
// the client for what is there), credits SellValue*quantity in gold, and
// removes the items. Selling more than the slot holds sells what it holds.
// Returns the gold credited. If crediting gold fails after the items were
// removed, the items are put back before returning the error.
func (s *Service) Sell(ctx context.Context, characterID int64, slot, quantity int) (int64, error) {
	gold, _, err := s.SellBooked(ctx, characterID, slot, quantity)
	return gold, err
}

// SellBooked is Sell, also answering the buy-back book byte the retail sell
// result carries: the book's size after the sale (1..5), or NotBooked
// (buyback.go).
func (s *Service) SellBooked(ctx context.Context, characterID int64, slot, quantity int) (int64, byte, error) {
	if quantity <= 0 {
		return 0, 0, ErrNothingToSell
	}
	slots, err := s.Inv.List(ctx, characterID)
	if err != nil {
		return 0, 0, fmt.Errorf("shop: reading inventory: %w", err)
	}
	var found *inventory.Slot
	for i := range slots {
		if slots[i].Index == slot {
			found = &slots[i]
			break
		}
	}
	if found == nil || found.Quantity <= 0 {
		return 0, 0, ErrSlotEmpty
	}
	if quantity > found.Quantity {
		quantity = found.Quantity
	}
	item, err := s.Items.GetItem(ctx, found.ItemID)
	if err != nil {
		return 0, 0, ErrItemNotFound
	}
	// THE ITEM'S OWN SELL FLAG, the engine's refusal at this exact point.
	// `CanSell` is vtable slot 50 (`IGObj::CanSell`), and the shop path returns
	// 0x183b UIIT_MSG_STRGERR_CANNOT_DEAL_AT_SHOP when it answers zero --
	// `GObjPC::FUN_006182a0` does precisely this. See
	// docs/protocol/item_capability_flags.md; the flag is itemdata column 17.
	//
	// Checked BEFORE the item is removed, so a refusal costs nothing.
	if item != nil && !item.CanSell {
		return 0, 0, ErrCannotSell
	}

	gold := SellValue(item) * int64(quantity)

	// The item out and the gold in, ONE transaction (round 743). The item is
	// taken under the bag's lock and checked to be the one priced, so two
	// racing sales of one stack sell it once; what left (its serial, when the
	// whole stack went) is what the book keeps.
	sold := found.Instance()
	err = txn.For(s.Gold, s.Inv).Run(ctx, func(ctx context.Context) error {
		inst, err := inventory.Take(ctx, s.Inv, characterID, slot, quantity, found.ItemID, found.Instance())
		if err != nil {
			if errors.Is(err, inventory.ErrSlotEmpty) || errors.Is(err, inventory.ErrItemChanged) {
				return ErrSlotEmpty
			}
			return fmt.Errorf("shop: removing sold item: %w", err)
		}
		sold = inst
		if err := s.Gold.AddGold(ctx, characterID, gold); err != nil {
			return fmt.Errorf("shop: crediting gold: %w", err)
		}
		return nil
	})
	if err != nil {
		return 0, 0, err
	}
	if item != nil && NeverBooked(item) {
		return gold, NotBooked, nil
	}
	price := gold
	if item != nil && item.SellPrice*int64(quantity) > price {
		price = item.SellPrice * int64(quantity)
	}
	return gold, s.recordSold(characterID, Sold{ItemID: found.ItemID, Quantity: quantity, Price: price, Inst: sold}), nil
}

// Catalog returns every purchasable item (the entire refdata catalog --
// there's no curated "shop-only" subset, see this package's doc comment)
// with its computed price.
func (s *Service) Catalog(ctx context.Context) ([]CatalogEntry, error) {
	items, err := s.Items.ListAll(ctx)
	if err != nil {
		return nil, fmt.Errorf("shop: listing catalog: %w", err)
	}
	out := make([]CatalogEntry, len(items))
	for i, item := range items {
		out[i] = CatalogEntry{
			ItemID:         item.ID,
			Price:          Price(item),
			ItemClass:      item.ItemClass,
			PhysAttackMax:  item.PhysAttackMax,
			PhysDefenseMax: item.PhysDefenseMax,
		}
	}
	return out, nil
}

// CatalogFor returns catalog entries for just the given item ids -- the goods
// one NPC sells -- rather than the whole refdata table. Ids that don't resolve
// are skipped. This is what keeps a shop listing to a handful of items: the
// full Catalog is ~12,000 entries, which overflows a single protocol frame.
func (s *Service) CatalogFor(ctx context.Context, ids []int64) ([]CatalogEntry, error) {
	out := make([]CatalogEntry, 0, len(ids))
	for _, id := range ids {
		item, err := s.Items.GetItem(ctx, id)
		if err != nil {
			continue
		}
		out = append(out, CatalogEntry{
			ItemID:         item.ID,
			Price:          Price(item),
			ItemClass:      item.ItemClass,
			PhysAttackMax:  item.PhysAttackMax,
			PhysDefenseMax: item.PhysDefenseMax,
		})
	}
	return out, nil
}
