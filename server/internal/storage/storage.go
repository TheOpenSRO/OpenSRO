// Package storage is the NPC warehouse: a second item container. It is not new
// machinery -- the warehouse is an ordinary inventory.Store on its own table, so
// depositing and withdrawing are just "read the slot's item, remove it here, add
// it there" between the bag and the warehouse. This keeps all the
// stacking/placement rules identical to the bag's.
//
// KNOWN DIVERGENCE, recorded 2026-09-16 rather than fixed: **this warehouse is
// per CHARACTER, and the game's is per ACCOUNT.**
//
// The evidence is the server's own SQL, which is about as unambiguous as this
// project's evidence gets. Every statement touching the warehouse table filters
// on the account id, never a character id:
//
//	SELECT SLOT FROM _CHEST WHERE UserJID=%d AND ItemID<>0 ...
//	SELECT IT.*   FROM _Chest C JOIN _ITEMS IT ON C.ItemID=IT.ID64 WHERE C.UserJID=%d ...
//	SELECT BIND.* FROM _Chest C ... WHERE C.UserJID=%d ...
//	SELECT R.*    FROM _Chest C ... WHERE C.UserJID=%d ...
//
// and the server's own error text is `failed to load user's chest size
// [UserJID: %d]`, so the warehouse's CAPACITY is an account property too. By
// contrast `_Inventory` is keyed by `CharID`, `_InvCOS` by `COSID` and
// `_GuildChest` by `GuildID` -- the binary distinguishes all four owners
// deliberately. See docs/protocol/server_sql.md.
//
// So in the real game every character on an account opens the same warehouse.
// Here each gets a private one, and `character.storage_gold` is likewise a
// per-character column.
//
// WHY IT IS NOT FIXED HERE. Correcting it is a data migration, not a code
// change: every existing account's per-character warehouses would have to be
// merged into one, and a merge that overflows the slot limit destroys items
// belonging to live testers. That is a deliberate, supervised change with a
// backup behind it, not something to slip into an unattended pass. It is on the
// open list in docs/RE_COMPLETION.md.
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
