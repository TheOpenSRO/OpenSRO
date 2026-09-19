// Package storage is the NPC warehouse: a second item container. It is not new
// machinery -- the warehouse is an ordinary inventory.Store on its own table, so
// depositing and withdrawing are just "read the slot's item, remove it here, add
// it there" between the bag and the warehouse. This keeps all the
// stacking/placement rules identical to the bag's.
//
// **The warehouse belongs to the ACCOUNT, not the character.** The bag is the
// character's. That is the game's own rule, read from the server's SQL: every
// statement touching the warehouse table filters on the account id, never a
// character id --
//
//	SELECT SLOT FROM _CHEST WHERE UserJID=%d AND ItemID<>0 ...      (AQ_CharDataLoader::SelectUsedSlotsForStorage, 0x43d2c0)
//	SELECT SLOT FROM _INVENTORY WHERE CharID=%d AND ItemID<>0 ...   (the bag, same function)
//	SELECT SLOT FROM _GUILDCHEST WHERE GuildID=%d ...                (the guild's)
//
// and the warehouse GOLD is the user's balance: the deposit calls
// `_UPDATE_USER_N_CHAR_GOLD(userJID, userGold, charID, charGold)`
// (AQ_StorageUpdater::MoveItemWithGold, 0x45af70). See
// docs/protocol/server_sql.md. So every character on an account opens the
// same warehouse and the same stored gold -- which is also how items and gold
// move between a player's own characters.
//
// Until 2026-09-19 this warehouse was per character (recorded as a known
// divergence since 2026-09-16, parked because merging per-character
// warehouses could overflow and destroy items). MigrateToAccounts is that
// merge, done losslessly: rows keep their slot where it is free and take the
// lowest free slot otherwise, gold is summed, and nothing is dropped.
package storage

import (
	"context"
	"errors"
	"fmt"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
)

// DefaultCapacity is the warehouse's slot count for every account.
//
// What the game does is READ, and it is not a constant: the capacity is a
// per-user row, `_ChestInfo.ChestSize` (the server's binder DB_Bind__ChestInfo,
// 0x8586e0, names the table and column), loaded by UserJID in
// AQ_CharDataLoader::DoWork (0x43d980) into the character object at +0x110 --
// and a user without the row fails to load ("failed to load user's chest size
// [UserJID: %d]"), so the binary carries no default. The starting size is
// written by the database's user-creation procedure, which is in no archive
// this project holds. The ceiling is read: the storage expander refuses a new
// size above 0x70 (inventory.MaxStorageSlots, 112).
//
// So this number is DISCLOSED, not grounded: 50 is what this server has
// enforced since the warehouse existed (inherited from the bag's
// SlotsPerCharacter), kept so no tester's reach shrinks. The client pages the
// warehouse by 30 (CIFStorageRoom::Create builds 0x1e slot controls and
// addresses a slot as cell + page*0x1e, client 0x6cd350), so 50 shows as a
// full page and a page of 20 -- the same shape 112 would have (3 x 30 + 22).
// When an operator has the shard database, ChestSize per account replaces
// this constant; the expansion path caps it at MaxCapacity.
const DefaultCapacity = 50

// MaxCapacity is the largest warehouse the game's expander allows (0x70).
const MaxCapacity = inventory.MaxStorageSlots

// ErrSlotEmpty is returned when the slot to move from holds nothing.
var ErrSlotEmpty = errors.New("storage: nothing in that slot")

// ErrNothingToMove is returned for a non-positive quantity.
var ErrNothingToMove = errors.New("storage: quantity must be positive")

// Service moves items between a character's bag and the account's warehouse,
// and gold between the character's purse and the account's stored gold.
// Every method takes the acting CHARACTER; the account is looked up from it,
// never taken from a caller.
type Service struct {
	Bag       inventory.Store          // owned by the character
	Warehouse inventory.Store          // owned by the ACCOUNT (inventory.WarehouseOwnerColumn)
	Gold      character.Store          // the purse
	Accounts  account.StorageGoldStore // the warehouse gold
}

// Balances is a character's carried gold and the account's warehouse gold.
type Balances struct {
	Carried int64
	Stored  int64
}

// Capacity is the warehouse's slot count, as the container enforces it. The
// client pages its authored 30-slot lattice from this.
func (s *Service) Capacity() int {
	return s.Warehouse.Capacity()
}

// accountOf resolves the acting character to its account.
func (s *Service) accountOf(ctx context.Context, characterID int64) (*character.Character, error) {
	c, err := s.Gold.GetByID(ctx, characterID)
	if err != nil {
		return nil, fmt.Errorf("storage: resolving character %d: %w", characterID, err)
	}
	return c, nil
}

// GoldBalances returns the character's carried gold and the account's stored gold.
func (s *Service) GoldBalances(ctx context.Context, characterID int64) (Balances, error) {
	c, err := s.accountOf(ctx, characterID)
	if err != nil {
		return Balances{}, err
	}
	stored, err := s.Accounts.StorageGold(ctx, c.AccountID)
	if err != nil {
		return Balances{}, fmt.Errorf("storage: reading warehouse gold: %w", err)
	}
	return Balances{Carried: c.Gold, Stored: stored}, nil
}

// DepositGold moves amount from the character's purse into the account's
// warehouse, returning the balances afterwards. Refunds the purse if crediting
// the warehouse fails.
func (s *Service) DepositGold(ctx context.Context, characterID int64, amount int64) (Balances, error) {
	if amount <= 0 {
		return Balances{}, ErrNothingToMove
	}
	c, err := s.accountOf(ctx, characterID)
	if err != nil {
		return Balances{}, err
	}
	if err := s.Gold.DeductGold(ctx, characterID, amount); err != nil {
		return Balances{}, fmt.Errorf("storage: taking gold from purse: %w", err)
	}
	if err := s.Accounts.AddStorageGold(ctx, c.AccountID, amount); err != nil {
		if backErr := s.Gold.AddGold(ctx, characterID, amount); backErr != nil {
			return Balances{}, fmt.Errorf("storage: crediting warehouse failed (%w) AND refunding purse failed (%v) -- gold may be lost", err, backErr)
		}
		return Balances{}, fmt.Errorf("storage: crediting warehouse gold: %w", err)
	}
	return s.GoldBalances(ctx, characterID)
}

// WithdrawGold moves amount from the account's warehouse back into the
// character's purse, returning the balances afterwards. Refunds the warehouse
// if crediting the purse fails.
func (s *Service) WithdrawGold(ctx context.Context, characterID int64, amount int64) (Balances, error) {
	if amount <= 0 {
		return Balances{}, ErrNothingToMove
	}
	c, err := s.accountOf(ctx, characterID)
	if err != nil {
		return Balances{}, err
	}
	if err := s.Accounts.DeductStorageGold(ctx, c.AccountID, amount); err != nil {
		if errors.Is(err, account.ErrInsufficientStorageGold) {
			return Balances{}, fmt.Errorf("storage: taking gold from warehouse: %w", character.ErrInsufficientGold)
		}
		return Balances{}, fmt.Errorf("storage: taking gold from warehouse: %w", err)
	}
	if err := s.Gold.AddGold(ctx, characterID, amount); err != nil {
		if backErr := s.Accounts.AddStorageGold(ctx, c.AccountID, amount); backErr != nil {
			return Balances{}, fmt.Errorf("storage: crediting purse failed (%w) AND returning to warehouse failed (%v) -- gold may be lost", err, backErr)
		}
		return Balances{}, fmt.Errorf("storage: crediting purse gold: %w", err)
	}
	return s.GoldBalances(ctx, characterID)
}

// List returns the account's warehouse as seen by this character.
func (s *Service) List(ctx context.Context, characterID int64) ([]inventory.Slot, error) {
	c, err := s.accountOf(ctx, characterID)
	if err != nil {
		return nil, err
	}
	return s.Warehouse.List(ctx, c.AccountID)
}

// Deposit moves quantity from the character's bag slot into the account's warehouse.
func (s *Service) Deposit(ctx context.Context, characterID int64, bagSlot, quantity int) error {
	c, err := s.accountOf(ctx, characterID)
	if err != nil {
		return err
	}
	return move(ctx, s.Bag, characterID, s.Warehouse, c.AccountID, bagSlot, quantity)
}

// Withdraw moves quantity from the account's warehouse slot back into the character's bag.
func (s *Service) Withdraw(ctx context.Context, characterID int64, warehouseSlot, quantity int) error {
	c, err := s.accountOf(ctx, characterID)
	if err != nil {
		return err
	}
	return move(ctx, s.Warehouse, c.AccountID, s.Bag, characterID, warehouseSlot, quantity)
}

// move takes quantity from `from`'s slot and adds it to `to`, reading the
// slot's own item and count from the source (never trusting a caller for what
// is there) and moving no more than the slot holds. If adding to the
// destination fails after the source was decremented, the items are returned
// to the source before the error propagates.
func move(ctx context.Context, from inventory.Store, fromOwner int64, to inventory.Store, toOwner int64, slot, quantity int) error {
	if quantity <= 0 {
		return ErrNothingToMove
	}
	slots, err := from.List(ctx, fromOwner)
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

	if err := from.RemoveItem(ctx, fromOwner, slot, quantity); err != nil {
		return fmt.Errorf("storage: removing from source: %w", err)
	}
	// The same instance crosses the counter -- its variance and durability
	// go with it and come back with it, never re-rolled.
	if err := to.AddItemInstance(ctx, toOwner, found.ItemID, quantity, found.Instance()); err != nil {
		if backErr := from.AddItemInstance(ctx, fromOwner, found.ItemID, quantity, found.Instance()); backErr != nil {
			return fmt.Errorf("storage: adding to destination failed (%w) AND returning it failed (%v) -- character may have lost an item", err, backErr)
		}
		return fmt.Errorf("storage: adding to destination: %w", err)
	}
	return nil
}
