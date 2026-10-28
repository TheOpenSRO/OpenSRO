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

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
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
// this project holds. The ceiling is read, and it was misattributed until
// round 270: the expander that refuses above 0x70 = 112 is the QUEST-REWARD
// inventory path (it reads the bag's InventorySize); the warehouse item
// (ITEM_MALL_WAREHOUSE_ADDITION, +30 a use) runs the kind-3 path, which
// refuses once current + 30 would pass 0xd2 = 210
// (inventory.MaxStorageExpansionSlots).
//
// So this number is DISCLOSED, not grounded: 50 is what this server has
// enforced since the warehouse existed (inherited from the bag's
// SlotsPerCharacter), kept so no tester's reach shrinks. The client pages the
// warehouse by 30 (CIFStorageRoom::Create builds 0x1e slot controls and
// addresses a slot as cell + page*0x1e, client 0x6cd350), so 50 shows as a
// full page and a page of 20. It is the size of every account whose
// `accounts.chest_size` is still 0 -- OpenSRO's stand-in for the missing
// `_ChestInfo` row. The warehouse expansion item (round 498, Expand) stores a
// size from here upwards, capped at MaxCapacity.
const DefaultCapacity = 50

// MaxCapacity is the largest warehouse the game's expander allows: the kind-3
// path refuses when current + amount would exceed 0xd2, so 210 -- and with the
// item's 30-slot steps from 50 the reachable sizes are 80, 110, 140, 170, 200.
const MaxCapacity = inventory.MaxStorageExpansionSlots

// MaxAdditions is how many times one account may use the warehouse expansion
// item: "Limited to 2 times only per account." (ITEM_MALL_WAREHOUSE_ADDITION's
// description, MEASURED from the archive's textdata, round 838). The original
// gets the limit out of its sizes -- a 150-slot chest (INFERRED: the only
// 30-slot page count that lets two +30 uses pass the READ 210 bound and refuses
// a third) -- and keeps no count. OpenSRO's start is the disclosed 50 above,
// which would let five uses through, so the limit is counted in the size
// instead (OURS): AdditionCeiling.
const MaxAdditions = 2

// AdditionCeiling is the largest warehouse the expansion item may leave, an
// amount at a time: DefaultCapacity plus MaxAdditions uses, never past
// MaxCapacity. Nothing else grows the warehouse, so a size at the ceiling means
// the account has used both. With the original's 150 it is the READ 210 itself.
func AdditionCeiling(amount int) int {
	return min(MaxCapacity, DefaultCapacity+MaxAdditions*amount)
}

// ErrExpansionRefused is the warehouse expansion's refusal: the engine's
// 0x18fe, UIIT_STT_STORAGE_EXPANSION_USE_ERORR (docs/protocol/error_codes.md),
// which CGObjPC::ExpandInventory (0x004e1910) returns for kind 3 when the
// chest's size byte plus the amount is not below 0xd3 (0x4e194d
// `cmp ecx,0xd2 ; jle`).
var ErrExpansionRefused = errors.New("storage: the warehouse cannot be expanded that far")

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
	// ChestSizes is the warehouse's per-account size (`_ChestInfo.ChestSize`).
	// Nil keeps every warehouse at the container's own Capacity() and refuses
	// expansion. The Warehouse store must be bounded by the same sizes
	// (SetCapacityFunc(CapacityOf(ChestSizes))).
	ChestSizes account.ChestSizeStore
	// Items prices the deposit fee (round 728, DepositFee). Nil charges
	// nothing -- the warehouse as it was before the fee existed.
	Items FeeLookup
}

// FeeLookup resolves an item's reference row for its KeepingFee.
type FeeLookup interface {
	GetItem(ctx context.Context, id int64) (*refdata.Item, error)
}

// DepositFeeCap is the most a deposit costs (READ: gs:0x524300,
// `uVar6 = 10000000`).
const DepositFeeCap = 10_000_000

// DepositFee is what depositing count of an item costs, READ in the server's
// deposit (move type 2, gs:0x524160): the unit fee (gs:0x523650, the item
// reference's +0xac, itemdata column 30 KeepingFee) times the count, 0 or
// less becoming 1 and DepositFeeCap or more becoming DepositFeeCap. The
// server prices the WHOLE stack: its type-2 request carries no count and it
// overwrites the count with the stack (r728_review.md F2/F7). The client's
// box (purpose 5, 0x63d676) shows max(1, the fee) with no cap, so above the
// cap the box shows more than is charged.
func DepositFee(keepingFee int64, count int) int64 {
	fee := keepingFee * int64(count)
	if fee < 1 {
		fee = 1
	}
	if fee > DepositFeeCap {
		fee = DepositFeeCap
	}
	return fee
}

// Balances is a character's carried gold and the account's warehouse gold.
type Balances struct {
	Carried int64
	Stored  int64
}

// CapacityOf answers each account's warehouse size from chests: the stored
// `_ChestInfo.ChestSize`, or DefaultCapacity when the store is nil, has no
// size stored (0) or fails. A smaller bound almost always only refuses slots
// past it, which is why a failed read degrades to it rather than failing the
// operation. ONE EDGE CASE can lose an item, disclosed rather than handled
// (round 501): a Withdraw from a slot at or past DefaultCapacity of an
// expanded warehouse whose bag add is then refused, when the chest-size read
// ALSO fails for move's refund -- the refund is bounded by DefaultCapacity, so
// it fails if slots 0..49 hold no room for it, and move returns its "character
// may have lost an item" error. It needs the bag to refuse and the read to
// fail within one request. The warehouse store takes it through
// SetCapacityFunc; the game reads the same field for its bound
// (CGObjPC::ExpandInventory reads the size byte at chest+0x1c, the binder's
// ChestSize offset -- docs/protocol/db_bind_offsets.tsv).
func CapacityOf(chests account.ChestSizeStore) inventory.CapacityFunc {
	return func(ctx context.Context, accountID int64) int {
		if chests == nil {
			return DefaultCapacity
		}
		n, err := chests.ChestSize(ctx, accountID)
		if err != nil || n <= 0 {
			return DefaultCapacity
		}
		return n
	}
}

// Capacity is the warehouse's slot count for this character's account, as
// the container enforces it. The client pages its authored 30-slot lattice
// from this.
func (s *Service) Capacity(ctx context.Context, characterID int64) (int, error) {
	if s.ChestSizes == nil {
		return s.Warehouse.Capacity(), nil
	}
	c, err := s.accountOf(ctx, characterID)
	if err != nil {
		return 0, err
	}
	return CapacityOf(s.ChestSizes)(ctx, c.AccountID), nil
}

// Expand grows this character's ACCOUNT warehouse by amount slots and returns
// the new size -- the warehouse expansion item's effect (round 498).
//
// CGItemExpendable::UseByKind (0x0049c2b0) case 0x11 passes the row's Param1
// byte and, for Param2 1, container kind 3 to CGObjPC::ExpandInventory
// (0x004e1910, vtable +0x2b4). Kind 3 reads the size byte at [pc+0x21d8]+0x1c
// -- the _ChestInfo record, whose binder puts ChestSize at 0x1c
// (db_bind_offsets.tsv) -- and refuses with 0x18fe unless size + amount < 0xd3
// (0x4e194d `cmp ecx,0xd2 ; jle`), so the largest warehouse is MaxCapacity,
// 210; otherwise AQ_StorageExpander::FUN_0045de20 applies the amount through
// that record's vtable +0x24. The growth starts from DefaultCapacity for an
// account with no stored size, and stops at AdditionCeiling (round 838: two
// uses per account, as the item's description says).
//
// One divergence, disclosed: kind 3 answers 2 (a plain failure) when the size
// byte is 0 (0x4e1935 `test al,al`), because a real user always has a
// `_ChestInfo` row; OpenSRO's 0 means "no row, the default size" and grows
// from DefaultCapacity instead.
func (s *Service) Expand(ctx context.Context, characterID int64, amount int) (int, error) {
	if s.ChestSizes == nil {
		return 0, errors.New("storage: the warehouse size is not stored here")
	}
	c, err := s.accountOf(ctx, characterID)
	if err != nil {
		return 0, err
	}
	n, err := s.ChestSizes.ExpandChest(ctx, c.AccountID, DefaultCapacity, amount, AdditionCeiling(amount))
	if errors.Is(err, account.ErrChestFull) {
		return 0, ErrExpansionRefused
	}
	if err != nil {
		return 0, fmt.Errorf("storage: expanding the warehouse: %w", err)
	}
	return n, nil
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
// warehouse, returning the balances afterwards. The debit and the credit are
// ONE transaction (round 743): there is no refund step.
func (s *Service) DepositGold(ctx context.Context, characterID int64, amount int64) (Balances, error) {
	if amount <= 0 {
		return Balances{}, ErrNothingToMove
	}
	c, err := s.accountOf(ctx, characterID)
	if err != nil {
		return Balances{}, err
	}
	err = s.run(ctx, func(ctx context.Context) error {
		if err := s.Gold.DeductGold(ctx, characterID, amount); err != nil {
			return fmt.Errorf("storage: taking gold from purse: %w", err)
		}
		if err := s.Accounts.AddStorageGold(ctx, c.AccountID, amount); err != nil {
			return fmt.Errorf("storage: crediting warehouse gold: %w", err)
		}
		return nil
	})
	if err != nil {
		return Balances{}, err
	}
	return s.GoldBalances(ctx, characterID)
}

// WithdrawGold moves amount from the account's warehouse back into the
// character's purse, returning the balances afterwards, in ONE transaction.
func (s *Service) WithdrawGold(ctx context.Context, characterID int64, amount int64) (Balances, error) {
	if amount <= 0 {
		return Balances{}, ErrNothingToMove
	}
	c, err := s.accountOf(ctx, characterID)
	if err != nil {
		return Balances{}, err
	}
	err = s.run(ctx, func(ctx context.Context) error {
		if err := s.Accounts.DeductStorageGold(ctx, c.AccountID, amount); err != nil {
			if errors.Is(err, account.ErrInsufficientStorageGold) {
				return fmt.Errorf("storage: taking gold from warehouse: %w", character.ErrInsufficientGold)
			}
			return fmt.Errorf("storage: taking gold from warehouse: %w", err)
		}
		if err := s.Gold.AddGold(ctx, characterID, amount); err != nil {
			return fmt.Errorf("storage: crediting purse gold: %w", err)
		}
		return nil
	})
	if err != nil {
		return Balances{}, err
	}
	return s.GoldBalances(ctx, characterID)
}

// run runs one warehouse action as one transaction over the service's
// stores (txn.Runner).
func (s *Service) run(ctx context.Context, fn func(ctx context.Context) error) error {
	return txn.For(s.Bag, s.Warehouse, s.Gold, s.Accounts).Run(ctx, fn)
}

// List returns the account's warehouse as seen by this character.
func (s *Service) List(ctx context.Context, characterID int64) ([]inventory.Slot, error) {
	c, err := s.accountOf(ctx, characterID)
	if err != nil {
		return nil, err
	}
	return s.Warehouse.List(ctx, c.AccountID)
}

// Deposit moves quantity from the character's bag slot into the account's
// warehouse, charging the fee on what moves (Charge).
func (s *Service) Deposit(ctx context.Context, characterID int64, bagSlot, quantity int) error {
	if quantity <= 0 {
		return ErrNothingToMove
	}
	return s.deposit(ctx, characterID, bagSlot, quantity, -1)
}

// DepositStack is the retail deposit (0x7034 type 2, gs:0x524160): the WHOLE
// stack in bagSlot into warehouse slot dst (the server's own choice when dst
// is taken, out of range, or the warehouse cannot place -- OURS), the fee
// for the whole stack (DepositFee).
func (s *Service) DepositStack(ctx context.Context, characterID int64, bagSlot, dst int) error {
	return s.deposit(ctx, characterID, bagSlot, 0, dst)
}

// deposit is both: quantity 0 is the whole stack. In the retail order: the
// purse is checked against the fee first (0x180f, character.ErrInsufficientGold),
// the item is moved, and only then is the gold taken (READ, gs:0x524160 ->
// 0x523f70, reason 0x21). All of it is ONE transaction (round 743): a purse
// emptied between the check and the charge rolls the move back, where
// before a best-effort search put the item back.
func (s *Service) deposit(ctx context.Context, characterID int64, bagSlot, quantity, dst int) error {
	c, err := s.accountOf(ctx, characterID)
	if err != nil {
		return err
	}
	return s.run(ctx, func(ctx context.Context) error {
		slots, err := s.Bag.List(ctx, characterID)
		if err != nil {
			return fmt.Errorf("storage: reading source: %w", err)
		}
		var found *inventory.Slot
		for i := range slots {
			if slots[i].Index == bagSlot {
				found = &slots[i]
				break
			}
		}
		if found == nil || found.Quantity <= 0 {
			return ErrSlotEmpty
		}
		count := found.Quantity
		if quantity > 0 && quantity < count {
			count = quantity
		}
		var fee int64
		if s.Items != nil {
			var keeping int64
			if it, e := s.Items.GetItem(ctx, found.ItemID); e == nil && it != nil {
				keeping = it.KeepingFee
			}
			fee = DepositFee(keeping, count)
			ch, err := s.Gold.GetByID(ctx, characterID)
			if err != nil {
				return fmt.Errorf("storage: reading purse: %w", err)
			}
			if ch.Gold < fee {
				return character.ErrInsufficientGold
			}
		}
		placed := false
		if p, ok := s.Warehouse.(inventory.Placer); ok && dst >= 0 && count == found.Quantity {
			inst, err := inventory.Take(ctx, s.Bag, characterID, bagSlot, count, found.ItemID, found.Instance())
			if err != nil {
				return fmt.Errorf("storage: taking from the bag: %w", err)
			}
			if err := p.PlaceItemInstance(ctx, c.AccountID, dst, found.ItemID, count, inst); err == nil {
				placed = true
			} else if err := s.Warehouse.AddItemInstance(ctx, c.AccountID, found.ItemID, count, inst); err != nil {
				// dst was taken or out of range: the server's own choice.
				return fmt.Errorf("storage: adding to destination: %w", err)
			} else {
				placed = true
			}
		}
		if !placed {
			if err := move(ctx, s.Bag, characterID, s.Warehouse, c.AccountID, bagSlot, count); err != nil {
				return err
			}
		}
		if fee == 0 {
			return nil
		}
		return s.Gold.DeductGold(ctx, characterID, fee)
	})
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
// is there) and moving no more than the slot holds. ONE transaction (round
// 743; a savepoint inside the caller's): the item is taken under the
// source's lock, checked to be the item read, and added; a destination that
// will not take it rolls the take back. What crosses is what left -- the
// same instance, with its serial when the whole stack moves.
func move(ctx context.Context, from inventory.Store, fromOwner int64, to inventory.Store, toOwner int64, slot, quantity int) error {
	if quantity <= 0 {
		return ErrNothingToMove
	}
	return txn.For(from, to).Run(ctx, func(ctx context.Context) error {
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
		n := quantity
		if n > found.Quantity {
			n = found.Quantity
		}
		inst, err := inventory.Take(ctx, from, fromOwner, slot, n, found.ItemID, found.Instance())
		if err != nil {
			if errors.Is(err, inventory.ErrSlotEmpty) || errors.Is(err, inventory.ErrItemChanged) {
				return ErrSlotEmpty
			}
			return fmt.Errorf("storage: removing from source: %w", err)
		}
		if err := to.AddItemInstance(ctx, toOwner, found.ItemID, n, inst); err != nil {
			return fmt.Errorf("storage: adding to destination: %w", err)
		}
		return nil
	})
}
