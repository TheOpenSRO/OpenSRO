// Package guildstorage is the guild storage (the guild warehouse, the
// engine's _GUILDCHEST): one item container and one gold balance per guild,
// opened by one member at a time at a guild manager (round 844, lane H;
// docs/protocol/guild_storage.md has the whole reading).
//
// Every rule here is READ from SR_GameServer.exe unless marked:
//
//   - the size is a table by guild level, s:0xc6b5f0 = {0, 0, 30, 60, 90, 120}
//     (GObjPC::FUN_005c4ba0 indexes it with CGuild::GetLevel; FUN_004e1ad0
//     builds the chest with it, container type 4, ceiling 0xd2);
//   - level 2 is the floor (0x4c4a UIIT_MSG_GUILD_WAREHOUSE_LIMIT, s:0x5c7468);
//   - the master, or a member with permission bit 0x08 (0x4c1e otherwise,
//     s:0x5c7497 HasPermission(8));
//   - one member at a time: the guild's holder record (guild + 0xc), set by the
//     ShardManager's job 0x24 type 1 and cleared by type 2; a second member
//     gets 0x4c48 with the holder's name (s:0x5ccf2b, the name at +0x20);
//   - a deposit (0x7034 type 0x1e, s:0x524510) takes the WHOLE stack and costs
//     half the warehouse's KeepingFee x the count, 1 to 10,000,000 (the fild /
//     fmul 0.5 at s:0x524658..0x52466a, the clamp at s:0x5246f0); a withdraw
//     (type 0x1f, s:0x5247d0) is free; neither merges -- an occupied
//     destination sends the item to the first empty slot (FUN_00523f70, 0x1807
//     when none); a move inside the storage (type 0x1d, FUN_004b2450) moves,
//     merges or swaps, and refuses a split (5: the chest is container type 4);
//   - gold in and out (types 0x20 / 0x21, s:0x5243d0) needs INTERACTMODE 6
//     (0x1834), a positive amount (0x1829) and the gold to move (0x180f).
//
// The items live in an ordinary inventory container keyed by the guild id
// (ChestTable, ChestOwner), so every stacking and placement rule is the bag's;
// the gold in GoldStore. Both stores join the action's one transaction
// (internal/txn): a move is all of it or none of it, whatever two members or
// a dropped connection do.
package guildstorage

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

// MinLevel is the lowest guild level whose storage opens (READ s:0x5c7468
// `cmp al,0x2 ; jae`).
const MinLevel = 2

// slotsByLevel is the storage's size by guild level (READ s:0xc6b5f0, dwords;
// its only reader is s:0x5c4ba8).
var slotsByLevel = [...]int{0, 0, 30, 60, 90, 120}

// MaxSlots is the container's ceiling (READ s:0x4e1b2d `mov ecx,0xd2`).
const MaxSlots = 0xd2

// PageSlots is one page of the window's lattice (CIFStorageRoom builds 0x1e
// slot controls, c:0x6cc780).
const PageSlots = 30

// Capacity is a guild of this level's storage size (0 below MinLevel).
func Capacity(level int) int {
	if level < 0 || level >= len(slotsByLevel) {
		if level >= len(slotsByLevel) {
			return slotsByLevel[len(slotsByLevel)-1]
		}
		return 0
	}
	return slotsByLevel[level]
}

// The container (OURS: the table and column names; the engine's is
// `_GUILDCHEST WHERE GuildID=%d`, s:0x43d2c0).
const (
	ChestTable = "guild_storage_slots"
	ChestOwner = "guild_id"
)

// The wire codes (READ; names from docs/protocol/error_codes.md).
const (
	CodeNotInGuild    uint16 = 0x4c0d // the guild checks' first refusal
	CodePermission    uint16 = 0x4c1e // UIIT_MSG_GUILDERR_PERMISSION_DENIED
	CodeInUse         uint16 = 0x4c48 // + the holder's name (UIIT_MSG_GUILD_WAREHOUSE_USE)
	CodeNotHolder     uint16 = 0x4c49 // the list asked by someone not holding it (s:0x517b35)
	CodeLevel         uint16 = 0x4c4a // UIIT_MSG_GUILD_WAREHOUSE_LIMIT
	CodePermInUse     uint16 = 0x4c4c // UIIT_MSG_GUILD_WAREHOUSE_USE_ING (a permission change)
	CodeNoTarget      uint16 = 3      // the NPC, the range or a slot out of range
	CodeWrongPlace    uint16 = 5      // an equipment slot, or a split in the storage
	CodeSameSlot      uint16 = 0x1806 // UIIT_MSG_STRGERR_WRONG_POSITION
	CodeFull          uint16 = 0x1807 // UIIT_MSG_STRGERR_INVENTORY_FULL
	CodeEmpty         uint16 = 0x1809
	CodeNotEnoughGold uint16 = 0x180f // UIIT_MSG_STRGERR_NOT_ENOUGH_GOLD
	CodeDB            uint16 = 0x1811
	CodePastStack     uint16 = 0x1814 // UIIT_MSG_STRGERR_ENABLEINPUT_FEWERTHAN_REMAIN
	CodeCount         uint16 = 0x1829 // UIIT_MSG_STRGERR_SPECIFY_POSITIVE_NUMBER_ONLY
	CodeBlocked       uint16 = 0x1834 // UIIT_MSG_STRGERR_STORAGE_OPERATION_BLOCKED
	CodeCannotStore   uint16 = 0x1843 // UIIT_MSG_STRGERR_INVALID_TARGET_STORAGE
	CodePetOut        uint16 = 0x18b2 // UIIT_MSG_COSPETERR_CANT_MOVETO_CHEST2
)

// Refusal is a move's refusal, carrying its wire code.
type Refusal struct{ Code uint16 }

func (r *Refusal) Error() string { return fmt.Sprintf("guildstorage: refused 0x%x", r.Code) }

func refuse(code uint16) error { return &Refusal{Code: code} }

// CodeOf is err's wire code: a Refusal's own, CodeDB for anything else, 0 for
// nil.
func CodeOf(err error) uint16 {
	if err == nil {
		return 0
	}
	var r *Refusal
	if errors.As(err, &r) {
		return r.Code
	}
	return CodeDB
}

// FeeCap is the most a deposit costs (READ s:0x5246f0 `uVar6 = 10000000`).
const FeeCap = 10_000_000

// Fee is what depositing count of an item whose KeepingFee is keepingFee
// costs in the guild storage: half the personal warehouse's (READ s:0x52464f
// imul, fild -- the product read unsigned, fadd 2^32 when negative --, fmul
// 0.5 (s:0xb45c50), then _ftol2 s:0x9fbb76, which truncates), 0 or less
// becoming 1 and FeeCap or more FeeCap. The client's box shows the same half
// (c:0x6b111a..0x6b11ec, `(fee * count) / 2`, at least 1).
func Fee(keepingFee int64, count int) int64 {
	p := uint32(int32(keepingFee) * int32(count))
	fee := int64(p) / 2
	if fee < 1 {
		fee = 1
	}
	if fee > FeeCap {
		fee = FeeCap
	}
	return fee
}

// Storable is the deposit's item test (READ s:0x5245fd..0x524628): the
// guild-storage bit (vslot 0x488, ref +0x8c bit 13), not a quest or event
// item (vslot 0xb8, TypeID 3/3/9: CGObj::IsQuest_n_EventItem) and tradeable
// (vslot 0xc4, CGObj::CanTrade, bit 0). Bit 13 is itemdata column 19 & 0x40,
// which refdata does not carry yet (OPEN, docs/protocol/guild_storage.md): the
// test here is the other two, which the bit agrees with on all but 73 of the
// 14,529 tradeable rows (MEASURED, round 844).
func Storable(it *refdata.Item) bool {
	if it == nil {
		return true
	}
	if it.TypeID1 == 3 && it.TypeID2 == 3 && it.TypeID3 == 9 {
		return false
	}
	return it.CanTrade
}

// ErrNotEnoughGold is a GoldStore's refusal to take more than it holds.
var ErrNotEnoughGold = errors.New("guildstorage: not enough gold in the guild storage")

// GoldStore is the guilds' stored gold (the engine's _GET_GUILD_GOLD /
// _UPDATE_GUILD_N_CHAR_GOLD, s:0x43d980, s:0x45af70). Every method joins the
// context's transaction.
type GoldStore interface {
	Gold(ctx context.Context, guildID int64) (int64, error)
	AddGold(ctx context.Context, guildID, amount int64) error
	// TakeGold refuses ErrNotEnoughGold, checked in the write itself.
	TakeGold(ctx context.Context, guildID, amount int64) error
	// DropGuild forgets a disbanded guild's gold.
	DropGuild(ctx context.Context, guildID int64) error
}

// ItemLookup resolves an item's reference row (the fee and the item test).
type ItemLookup interface {
	GetItem(ctx context.Context, id int64) (*refdata.Item, error)
}

// Service moves items and gold between a member's bag and purse and the
// guild's storage. The session layer checks the guild, the holder, the NPC
// and the interaction first; the capacities it passes are the guild's
// (Capacity) and the bag's.
type Service struct {
	Bag   inventory.Store // by character
	Chest inventory.Store // by guild id (ChestTable)
	Purse character.Store
	Vault GoldStore
	Items ItemLookup
}

func (s *Service) run(ctx context.Context, fn func(ctx context.Context) error) error {
	return txn.For(s.Bag, s.Chest, s.Purse, s.Vault).Run(ctx, fn)
}

// List is the guild's storage: its slots and its gold.
func (s *Service) List(ctx context.Context, guildID int64) ([]inventory.Slot, int64, error) {
	slots, err := s.Chest.List(ctx, guildID)
	if err != nil {
		return nil, 0, err
	}
	gold, err := s.Vault.Gold(ctx, guildID)
	if err != nil {
		return nil, 0, err
	}
	return slots, gold, nil
}

func slotAt(slots []inventory.Slot, index int) *inventory.Slot {
	for i := range slots {
		if slots[i].Index == index && slots[i].Quantity > 0 {
			return &slots[i]
		}
	}
	return nil
}

// firstFree is the lowest index below capacity no slot holds, -1 for none
// (CGStorage::FindFirstEmptySlot).
func firstFree(slots []inventory.Slot, capacity int) int {
	taken := make(map[int]bool, len(slots))
	for _, sl := range slots {
		taken[sl.Index] = true
	}
	for i := 0; i < capacity; i++ {
		if !taken[i] {
			return i
		}
	}
	return -1
}

// place puts a whole stack into dst when it is free, else the first free slot
// (FUN_00523f70: no merge), returning the slot used.
func place(ctx context.Context, st inventory.Store, owner int64, capacity, dst int, it inventory.Slot, inst inventory.Instance) (int, error) {
	held, err := st.List(ctx, owner)
	if err != nil {
		return -1, err
	}
	if dst < 0 || dst >= capacity || slotAt(held, dst) != nil {
		dst = firstFree(held, capacity)
	}
	if dst < 0 {
		return -1, refuse(CodeFull)
	}
	p, ok := st.(inventory.Placer)
	if !ok {
		return -1, errors.New("guildstorage: the container cannot place an item")
	}
	if err := p.PlaceItemInstance(ctx, owner, dst, it.ItemID, it.Quantity, inst); err != nil {
		if errors.Is(err, inventory.ErrInvalidSlot) {
			return -1, refuse(CodeFull)
		}
		return -1, err
	}
	return dst, nil
}

// Deposit is 0x7034 type 0x1e (s:0x524510 -> FUN_00523f70): bag slot bagSlot's
// whole stack into the storage at dst (or its first empty slot), the fee
// taken after the move. It returns the slot used and the fee.
func (s *Service) Deposit(ctx context.Context, characterID, guildID int64, capacity, bagSlot, dst int) (int, int64, error) {
	used, fee := -1, int64(0)
	err := s.run(ctx, func(ctx context.Context) error {
		bag, err := s.Bag.List(ctx, characterID)
		if err != nil {
			return err
		}
		src := slotAt(bag, bagSlot)
		if src == nil {
			return refuse(CodeEmpty)
		}
		var keeping int64
		if s.Items != nil {
			it, err := s.Items.GetItem(ctx, src.ItemID)
			if err == nil && it != nil {
				if !Storable(it) {
					return refuse(CodeCannotStore)
				}
				keeping = it.KeepingFee
			}
		}
		fee = Fee(keeping, src.Quantity)
		ch, err := s.Purse.GetByID(ctx, characterID)
		if err != nil {
			return err
		}
		if ch.Gold < fee {
			return refuse(CodeNotEnoughGold)
		}
		if dst < 0 || dst >= capacity {
			return refuse(CodeNoTarget)
		}
		inst, err := inventory.Take(ctx, s.Bag, characterID, bagSlot, src.Quantity, src.ItemID, src.Instance())
		if err != nil {
			if errors.Is(err, inventory.ErrSlotEmpty) || errors.Is(err, inventory.ErrItemChanged) || errors.Is(err, inventory.ErrInsufficientQuantity) {
				return refuse(CodeEmpty)
			}
			return err
		}
		if used, err = place(ctx, s.Chest, guildID, capacity, dst, *src, inst); err != nil {
			return err
		}
		if err := s.Purse.DeductGold(ctx, characterID, fee); err != nil {
			if errors.Is(err, character.ErrInsufficientGold) {
				return refuse(CodeNotEnoughGold)
			}
			return err
		}
		return nil
	})
	return used, fee, err
}

// Withdraw is 0x7034 type 0x1f (s:0x5247d0 -> FUN_00523f70): storage slot
// slot's whole stack into bag slot bagDst (or the bag's first empty slot),
// free. It returns the bag slot used.
func (s *Service) Withdraw(ctx context.Context, characterID, guildID int64, capacity, slot, bagCapacity, bagDst int) (int, error) {
	used := -1
	err := s.run(ctx, func(ctx context.Context) error {
		if slot < 0 || slot >= capacity || bagDst < 0 || bagDst >= bagCapacity {
			return refuse(CodeNoTarget)
		}
		chest, err := s.Chest.List(ctx, guildID)
		if err != nil {
			return err
		}
		src := slotAt(chest, slot)
		if src == nil {
			return refuse(CodeEmpty)
		}
		inst, err := inventory.Take(ctx, s.Chest, guildID, slot, src.Quantity, src.ItemID, src.Instance())
		if err != nil {
			if errors.Is(err, inventory.ErrSlotEmpty) || errors.Is(err, inventory.ErrItemChanged) || errors.Is(err, inventory.ErrInsufficientQuantity) {
				return refuse(CodeEmpty)
			}
			return err
		}
		used, err = place(ctx, s.Bag, characterID, bagCapacity, bagDst, *src, inst)
		return err
	})
	return used, err
}

// Moved is a move inside the storage as the reply carries it.
type Moved struct {
	Src, Dst, Count int
}

// Move is 0x7034 type 0x1d (FUN_004b2450 on the chest): src's stack onto dst.
// An empty dst takes the stack (count must be the stack, or the item must not
// stack: a smaller count is a split, refused 5 in the storage; a larger one
// 0x1814); an occupied one takes what merges, else the two swap. The reply's
// count is the stack moved or the amount merged.
func (s *Service) Move(ctx context.Context, guildID int64, capacity, src, dst, count int) (Moved, error) {
	out := Moved{Src: src, Dst: dst, Count: count}
	err := s.run(ctx, func(ctx context.Context) error {
		if src == dst || src < 0 || dst < 0 || src >= capacity || dst >= capacity {
			return refuse(CodeSameSlot)
		}
		chest, err := s.Chest.List(ctx, guildID)
		if err != nil {
			return err
		}
		from := slotAt(chest, src)
		if from == nil {
			return refuse(CodeEmpty)
		}
		if count < 1 {
			return refuse(CodeCount)
		}
		to := slotAt(chest, dst)
		if to == nil {
			stacks := s.stacks(ctx, from.ItemID)
			if stacks && count != from.Quantity {
				if count > from.Quantity {
					return refuse(CodePastStack)
				}
				return refuse(CodeWrongPlace)
			}
			out.Count = from.Quantity
			return s.Chest.MoveItem(ctx, guildID, src, dst)
		}
		before := to.Quantity
		if err := s.Chest.MoveItem(ctx, guildID, src, dst); err != nil {
			return err
		}
		after, err := s.Chest.List(ctx, guildID)
		if err != nil {
			return err
		}
		if nt := slotAt(after, dst); nt != nil && nt.ItemID == to.ItemID && nt.Quantity > before {
			out.Count = nt.Quantity - before // merged
		} else {
			out.Count = from.Quantity // swapped
		}
		return nil
	})
	return out, err
}

// stacks reports whether itemID stacks past one (refdata's MaxStack).
func (s *Service) stacks(ctx context.Context, itemID int64) bool {
	if s.Items == nil {
		return true
	}
	it, err := s.Items.GetItem(ctx, itemID)
	if err != nil || it == nil {
		return true
	}
	return it.MaxStack > 1
}

// DepositGold is 0x7034 type 0x20: amount from the purse into the storage.
func (s *Service) DepositGold(ctx context.Context, characterID, guildID, amount int64) error {
	if amount <= 0 {
		return refuse(CodeCount)
	}
	return s.run(ctx, func(ctx context.Context) error {
		if err := s.Purse.DeductGold(ctx, characterID, amount); err != nil {
			if errors.Is(err, character.ErrInsufficientGold) {
				return refuse(CodeNotEnoughGold)
			}
			return err
		}
		return s.Vault.AddGold(ctx, guildID, amount)
	})
}

// WithdrawGold is 0x7034 type 0x21: amount from the storage into the purse.
func (s *Service) WithdrawGold(ctx context.Context, characterID, guildID, amount int64) error {
	if amount <= 0 {
		return refuse(CodeCount)
	}
	return s.run(ctx, func(ctx context.Context) error {
		if err := s.Vault.TakeGold(ctx, guildID, amount); err != nil {
			if errors.Is(err, ErrNotEnoughGold) {
				return refuse(CodeNotEnoughGold)
			}
			return err
		}
		return s.Purse.AddGold(ctx, characterID, amount)
	})
}

// Drop empties a disbanded guild's storage: "All the items in the warehouse
// and guild points(GP) will be gone if your guild is disbanded."
// (UIIT_MSG_GUILD_BREAK_ANOTHER_EXPLAIN, READ); its gold goes with it
// (INFERRED: the ShardManager's disband job is not in this binary).
func (s *Service) Drop(ctx context.Context, guildID int64) error {
	return s.run(ctx, func(ctx context.Context) error {
		slots, err := s.Chest.List(ctx, guildID)
		if err != nil {
			return err
		}
		for _, sl := range slots {
			if err := s.Chest.RemoveItem(ctx, guildID, sl.Index, sl.Quantity); err != nil {
				return err
			}
		}
		return s.Vault.DropGuild(ctx, guildID)
	})
}

// Holder is the member using a guild's storage.
type Holder struct {
	CharacterID int64
	Name        string
}

// Locks is each guild's holder: the engine's guild + 0xc record, which the
// ShardManager's job 0x24 sets (type 1, the open) and clears (type 2, the
// close; CMainProcess::FUN_005c5510). OURS: one process, so a map; a holder
// leaving the world releases it (the ShardManager's own release is not in
// this binary, INFERRED).
type Locks struct {
	mu      sync.Mutex
	byGuild map[int64]Holder
}

// NewLocks returns an empty set.
func NewLocks() *Locks { return &Locks{byGuild: map[int64]Holder{}} }

// Acquire makes h the guild's holder unless another member is: then it
// answers that member and false. The holder asking again keeps it.
func (l *Locks) Acquire(guildID int64, h Holder) (Holder, bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if cur, ok := l.byGuild[guildID]; ok && cur.CharacterID != h.CharacterID {
		return cur, false
	}
	l.byGuild[guildID] = h
	return h, true
}

// Release clears the guild's holder when it is characterID.
func (l *Locks) Release(guildID, characterID int64) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if cur, ok := l.byGuild[guildID]; ok && cur.CharacterID == characterID {
		delete(l.byGuild, guildID)
		return true
	}
	return false
}

// ReleaseCharacter clears whatever storage characterID holds, answering the
// guild.
func (l *Locks) ReleaseCharacter(characterID int64) (int64, bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	for g, cur := range l.byGuild {
		if cur.CharacterID == characterID {
			delete(l.byGuild, g)
			return g, true
		}
	}
	return 0, false
}

// HolderOf is the guild's holder, if any.
func (l *Locks) HolderOf(guildID int64) (Holder, bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	h, ok := l.byGuild[guildID]
	return h, ok
}

// Holds reports whether characterID holds the guild's storage.
func (l *Locks) Holds(guildID, characterID int64) bool {
	h, ok := l.HolderOf(guildID)
	return ok && h.CharacterID == characterID
}
