// Package storage is the NPC warehouse: a character's second item container.
// It is not new machinery -- the warehouse is an ordinary inventory.Store on
// its own table, so depositing and withdrawing are just "read the slot's item,
// remove it here, add it there" between the bag and the warehouse. This keeps
// all the stacking/placement rules identical to the bag's.
package storage

import (
	"context"
	"errors"
	"fmt"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
)

// ErrSlotEmpty is returned when the slot to move from holds nothing.
var ErrSlotEmpty = errors.New("storage: nothing in that slot")

// ErrNothingToMove is returned for a non-positive quantity.
var ErrNothingToMove = errors.New("storage: quantity must be positive")

// Service moves items between a character's bag and warehouse, and gold
// between the character's purse and the warehouse.
type Service struct {
	Bag       inventory.Store
	Warehouse inventory.Store
	Gold      character.Store
}

// Balances is a character's carried gold and warehouse gold.
type Balances struct {
	Carried int64
	Stored  int64
}

// GoldBalances returns the character's carried and stored gold.
func (s *Service) GoldBalances(ctx context.Context, characterID int64) (Balances, error) {
	c, err := s.Gold.GetByID(ctx, characterID)
	if err != nil {
		return Balances{}, fmt.Errorf("storage: reading balances: %w", err)
	}
	return Balances{Carried: c.Gold, Stored: c.StorageGold}, nil
}

// DepositGold moves amount from the character's purse into the warehouse,
// returning the balances afterwards. Refunds the purse if crediting the
// warehouse fails.
func (s *Service) DepositGold(ctx context.Context, characterID int64, amount int64) (Balances, error) {
	if amount <= 0 {
		return Balances{}, ErrNothingToMove
	}
	if err := s.Gold.DeductGold(ctx, characterID, amount); err != nil {
		return Balances{}, fmt.Errorf("storage: taking gold from purse: %w", err)
	}
	if err := s.Gold.AddStorageGold(ctx, characterID, amount); err != nil {
		if backErr := s.Gold.AddGold(ctx, characterID, amount); backErr != nil {
			return Balances{}, fmt.Errorf("storage: crediting warehouse failed (%w) AND refunding purse failed (%v) -- gold may be lost", err, backErr)
		}
		return Balances{}, fmt.Errorf("storage: crediting warehouse gold: %w", err)
	}
	return s.GoldBalances(ctx, characterID)
}

// WithdrawGold moves amount from the warehouse back into the character's
// purse, returning the balances afterwards. Refunds the warehouse if crediting
// the purse fails.
func (s *Service) WithdrawGold(ctx context.Context, characterID int64, amount int64) (Balances, error) {
	if amount <= 0 {
		return Balances{}, ErrNothingToMove
	}
	if err := s.Gold.DeductStorageGold(ctx, characterID, amount); err != nil {
		return Balances{}, fmt.Errorf("storage: taking gold from warehouse: %w", err)
	}
	if err := s.Gold.AddGold(ctx, characterID, amount); err != nil {
		if backErr := s.Gold.AddStorageGold(ctx, characterID, amount); backErr != nil {
			return Balances{}, fmt.Errorf("storage: crediting purse failed (%w) AND returning to warehouse failed (%v) -- gold may be lost", err, backErr)
		}
		return Balances{}, fmt.Errorf("storage: crediting purse gold: %w", err)
	}
	return s.GoldBalances(ctx, characterID)
}

// List returns the warehouse's contents for a character.
func (s *Service) List(ctx context.Context, characterID int64) ([]inventory.Slot, error) {
	return s.Warehouse.List(ctx, characterID)
}

// Deposit moves quantity from the character's bag slot into the warehouse.
func (s *Service) Deposit(ctx context.Context, characterID int64, bagSlot, quantity int) error {
	return move(ctx, s.Bag, s.Warehouse, characterID, bagSlot, quantity)
}

// Withdraw moves quantity from the warehouse slot back into the bag.
func (s *Service) Withdraw(ctx context.Context, characterID int64, warehouseSlot, quantity int) error {
	return move(ctx, s.Warehouse, s.Bag, characterID, warehouseSlot, quantity)
}

// move takes quantity from `from`'s slot and adds it to `to`, reading the
// slot's own item and count from the source (never trusting a caller for what
// is there) and moving no more than the slot holds. If adding to the
// destination fails after the source was decremented, the items are returned
// to the source before the error propagates.
func move(ctx context.Context, from, to inventory.Store, characterID int64, slot, quantity int) error {
	if quantity <= 0 {
		return ErrNothingToMove
	}
	slots, err := from.List(ctx, characterID)
	if err != nil {
		return fmt.Errorf("storage: reading source: %w", err)
	}
	var found *inventory.Slot
	for i := range slots {
		if slots[i].Index == slot {
			found = &slots[i]
			break
		}
	}
	if found == nil || found.Quantity <= 0 {
		return ErrSlotEmpty
	}
	if quantity > found.Quantity {
		quantity = found.Quantity
	}

	if err := from.RemoveItem(ctx, characterID, slot, quantity); err != nil {
		return fmt.Errorf("storage: removing from source: %w", err)
	}
	if err := to.AddItem(ctx, characterID, found.ItemID, quantity); err != nil {
		if backErr := from.AddItem(ctx, characterID, found.ItemID, quantity); backErr != nil {
			return fmt.Errorf("storage: adding to destination failed (%w) AND returning it failed (%v) -- character may have lost an item", err, backErr)
		}
		return fmt.Errorf("storage: adding to destination: %w", err)
	}
	return nil
}
