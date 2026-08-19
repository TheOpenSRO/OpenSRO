// Package shop implements a basic NPC vendor: buying items from the
// refdata catalog with character gold. Entirely own design -- there's no
// original pricing data to draw from (the obtained package's DB backups
// were never fully restored/mined for a real price table), so prices are
// computed from an item's own stats via a simple formula rather than
// looked up.
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
// constants -- not derived from any original economy data.
const (
	basePrice      = 100
	statMultiplier = 10
)

// Price computes an item's cost in gold from its own stats: a flat base
// plus a multiple of its best offensive/defensive numbers. Deliberately
// simple -- refine once actual game balance work happens.
func Price(item *refdata.Item) int64 {
	statTotal := item.PhysAttackMax + item.MagAttackMax + item.PhysDefenseMax + item.MagDefenseMax
	return basePrice + int64(statTotal*statMultiplier)
}

// ItemLookup resolves an item's stats, for pricing and existence checks.
// Satisfied by refdata.SQLStore in production.
type ItemLookup interface {
	GetItem(ctx context.Context, id int64) (*refdata.Item, error)
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
