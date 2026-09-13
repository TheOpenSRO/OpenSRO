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

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
)

// ErrItemNotFound is returned by Service.Buy when itemID isn't in the
// catalog.
var ErrItemNotFound = errors.New("shop: item not found")

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
}

// Buy attempts to purchase quantity of itemID for characterID: looks up
// the price, deducts gold, then adds the item to the inventory. If adding
// to the inventory fails after gold was already deducted (e.g. no room),
// the gold is refunded before returning the error.
func (s *Service) Buy(ctx context.Context, characterID, itemID int64, quantity int) error {
	item, err := s.Items.GetItem(ctx, itemID)
	if err != nil {
		return ErrItemNotFound
	}

	cost := Price(item) * int64(quantity)
	if err := s.Gold.DeductGold(ctx, characterID, cost); err != nil {
		return fmt.Errorf("shop: %w", err)
	}

	if err := s.Inv.AddItem(ctx, characterID, itemID, quantity); err != nil {
		if refundErr := s.Gold.AddGold(ctx, characterID, cost); refundErr != nil {
			return fmt.Errorf("shop: adding item failed (%w) AND refund failed (%v) -- character may have lost gold", err, refundErr)
		}
		return fmt.Errorf("shop: adding item to inventory: %w", err)
	}
	return nil
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
