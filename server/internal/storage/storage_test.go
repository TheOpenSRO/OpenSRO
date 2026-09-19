package storage

import (
	"context"
	"errors"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
)

// generousStacks lets everything stack, so a moved amount lands in one slot
// and the counts are easy to assert.
type generousStacks struct{}

func (generousStacks) GetMaxStack(_ context.Context, _ int64) (int, error) { return 1000, nil }

// fixture is a service over in-memory stores with one account holding two
// characters -- the shape that tells a per-account warehouse from a
// per-character one.
type fixture struct {
	svc      *Service
	accounts *account.MemStore
	chars    *character.MemStore
	account  *account.Account
	aria     *character.Character
	bram     *character.Character
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	// Two throwaway accounts first, so the player's account id (3) can never
	// coincide with a character id (1, 2) -- a warehouse row filed under the
	// wrong owner must show up as such.
	for _, name := range []string{"unused-a", "unused-b"} {
		if _, err := accounts.Add(name, "pw"); err != nil {
			t.Fatalf("creating %s: %v", name, err)
		}
	}
	acc, err := accounts.Add("player", "pw")
	if err != nil {
		t.Fatalf("creating account: %v", err)
	}
	chars := character.NewMemStore()
	aria, err := chars.Create(ctx, acc.ID, "Aria")
	if err != nil {
		t.Fatalf("creating Aria: %v", err)
	}
	bram, err := chars.Create(ctx, acc.ID, "Bram")
	if err != nil {
		t.Fatalf("creating Bram: %v", err)
	}
	return &fixture{
		svc: &Service{
			Bag:       inventory.NewMemStore(generousStacks{}),
			Warehouse: inventory.NewMemStore(generousStacks{}),
			Gold:      chars,
			Accounts:  accounts,
		},
		accounts: accounts, chars: chars, account: acc, aria: aria, bram: bram,
	}
}

func slotOf(t *testing.T, store inventory.Store, owner, itemID int64) inventory.Slot {
	t.Helper()
	slots, err := store.List(context.Background(), owner)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	for _, s := range slots {
		if s.ItemID == itemID {
			return s
		}
	}
	t.Fatalf("item %d not found in %+v", itemID, slots)
	return inventory.Slot{}
}

func TestDepositAndWithdraw(t *testing.T) {
	ctx := context.Background()
	const item = int64(100)
	f := newFixture(t)
	cid, aid := f.aria.ID, f.account.ID

	if err := f.svc.Bag.AddItem(ctx, cid, item, 5); err != nil {
		t.Fatalf("seeding bag: %v", err)
	}

	// Deposit 3 of the 5 into the warehouse -- which is the ACCOUNT's.
	bagSlot := slotOf(t, f.svc.Bag, cid, item)
	if err := f.svc.Deposit(ctx, cid, bagSlot.Index, 3); err != nil {
		t.Fatalf("Deposit: %v", err)
	}
	if got := slotOf(t, f.svc.Bag, cid, item).Quantity; got != 2 {
		t.Fatalf("bag has %d after depositing 3 of 5, want 2", got)
	}
	if got := slotOf(t, f.svc.Warehouse, aid, item).Quantity; got != 3 {
		t.Fatalf("warehouse has %d after deposit, want 3", got)
	}
	if rows, _ := f.svc.Warehouse.List(ctx, cid); len(rows) != 0 {
		t.Fatalf("nothing may be filed under the character id in the warehouse, got %+v", rows)
	}

	// Withdraw 1 back.
	whSlot := slotOf(t, f.svc.Warehouse, aid, item)
	if err := f.svc.Withdraw(ctx, cid, whSlot.Index, 1); err != nil {
		t.Fatalf("Withdraw: %v", err)
	}
	if got := slotOf(t, f.svc.Warehouse, aid, item).Quantity; got != 2 {
		t.Fatalf("warehouse has %d after withdrawing 1, want 2", got)
	}
	if got := slotOf(t, f.svc.Bag, cid, item).Quantity; got != 3 {
		t.Fatalf("bag has %d after withdraw, want 3", got)
	}
}

// The game's rule (server_sql.md: `_CHEST WHERE UserJID=%d`): every character
// on the account opens the same warehouse, so what Aria deposits, Bram can
// list and withdraw.
func TestWarehouseIsSharedAcrossTheAccount(t *testing.T) {
	ctx := context.Background()
	const item = int64(100)
	f := newFixture(t)

	if err := f.svc.Bag.AddItem(ctx, f.aria.ID, item, 4); err != nil {
		t.Fatalf("seeding Aria's bag: %v", err)
	}
	if err := f.svc.Deposit(ctx, f.aria.ID, slotOf(t, f.svc.Bag, f.aria.ID, item).Index, 4); err != nil {
		t.Fatalf("Aria deposits: %v", err)
	}

	seenByBram, err := f.svc.List(ctx, f.bram.ID)
	if err != nil {
		t.Fatalf("Bram lists: %v", err)
	}
	if len(seenByBram) != 1 || seenByBram[0].ItemID != item || seenByBram[0].Quantity != 4 {
		t.Fatalf("Bram sees %+v, want Aria's 4 x item %d", seenByBram, item)
	}
	if err := f.svc.Withdraw(ctx, f.bram.ID, seenByBram[0].Index, 4); err != nil {
		t.Fatalf("Bram withdraws: %v", err)
	}
	if got := slotOf(t, f.svc.Bag, f.bram.ID, item).Quantity; got != 4 {
		t.Fatalf("Bram's bag has %d, want the 4 Aria stored", got)
	}
	if left, _ := f.svc.List(ctx, f.aria.ID); len(left) != 0 {
		t.Fatalf("warehouse should be empty for Aria too, got %+v", left)
	}

	// A second account does not see it.
	other, err := f.accounts.Add("stranger", "pw")
	if err != nil {
		t.Fatalf("creating stranger: %v", err)
	}
	cara, err := f.chars.Create(ctx, other.ID, "Cara")
	if err != nil {
		t.Fatalf("creating Cara: %v", err)
	}
	_ = f.svc.Bag.AddItem(ctx, f.aria.ID, item, 1)
	_ = f.svc.Deposit(ctx, f.aria.ID, slotOf(t, f.svc.Bag, f.aria.ID, item).Index, 1)
	if seen, _ := f.svc.List(ctx, cara.ID); len(seen) != 0 {
		t.Fatalf("another account's character sees %+v", seen)
	}
}

func TestDepositMoreThanHeldMovesWhatIsThere(t *testing.T) {
	ctx := context.Background()
	const item = int64(100)
	f := newFixture(t)
	cid := f.aria.ID
	if err := f.svc.Bag.AddItem(ctx, cid, item, 2); err != nil {
		t.Fatalf("seeding bag: %v", err)
	}
	bagSlot := slotOf(t, f.svc.Bag, cid, item)
	if err := f.svc.Deposit(ctx, cid, bagSlot.Index, 99); err != nil {
		t.Fatalf("Deposit: %v", err)
	}
	if got := slotOf(t, f.svc.Warehouse, f.account.ID, item).Quantity; got != 2 {
		t.Fatalf("warehouse has %d, want the 2 that were actually held", got)
	}
	if left, _ := f.svc.Bag.List(ctx, cid); len(left) != 0 {
		t.Fatalf("bag should be empty, got %+v", left)
	}
}

// Warehouse gold is the account's balance (`_UPDATE_USER_N_CHAR_GOLD`): what
// Aria deposits, Bram's balances show and Bram can withdraw.
func TestGoldDepositAndWithdraw(t *testing.T) {
	ctx := context.Background()
	f := newFixture(t)

	bal, err := f.svc.DepositGold(ctx, f.aria.ID, 300)
	if err != nil {
		t.Fatalf("DepositGold: %v", err)
	}
	if bal.Carried != character.StartingGold-300 || bal.Stored != 300 {
		t.Fatalf("after deposit got carried=%d stored=%d, want %d/300", bal.Carried, bal.Stored, character.StartingGold-300)
	}
	if got, _ := f.accounts.StorageGold(ctx, f.account.ID); got != 300 {
		t.Fatalf("account holds %d stored gold, want 300", got)
	}

	// Bram, on the same account, sees the same stored gold and may take it.
	bramBal, err := f.svc.GoldBalances(ctx, f.bram.ID)
	if err != nil {
		t.Fatalf("Bram's balances: %v", err)
	}
	if bramBal.Stored != 300 || bramBal.Carried != character.StartingGold {
		t.Fatalf("Bram sees carried=%d stored=%d, want %d/300", bramBal.Carried, bramBal.Stored, character.StartingGold)
	}
	bal, err = f.svc.WithdrawGold(ctx, f.bram.ID, 100)
	if err != nil {
		t.Fatalf("WithdrawGold: %v", err)
	}
	if bal.Carried != character.StartingGold+100 || bal.Stored != 200 {
		t.Fatalf("after Bram's withdraw got carried=%d stored=%d, want %d/200", bal.Carried, bal.Stored, character.StartingGold+100)
	}

	// Can't withdraw more than is stored, and can't deposit more than carried.
	if _, err := f.svc.WithdrawGold(ctx, f.aria.ID, 9999); !errors.Is(err, character.ErrInsufficientGold) {
		t.Fatalf("over-withdraw: got %v, want ErrInsufficientGold", err)
	}
	if _, err := f.svc.DepositGold(ctx, f.aria.ID, 9_999_999); !errors.Is(err, character.ErrInsufficientGold) {
		t.Fatalf("over-deposit: got %v, want ErrInsufficientGold", err)
	}
	if _, err := f.svc.DepositGold(ctx, f.aria.ID, 0); !errors.Is(err, ErrNothingToMove) {
		t.Fatalf("deposit 0: got %v, want ErrNothingToMove", err)
	}
}

func TestMoveEmptyAndNonPositive(t *testing.T) {
	ctx := context.Background()
	f := newFixture(t)
	if err := f.svc.Deposit(ctx, f.aria.ID, 0, 1); !errors.Is(err, ErrSlotEmpty) {
		t.Fatalf("deposit from empty slot: got %v, want ErrSlotEmpty", err)
	}
	_ = f.svc.Bag.AddItem(ctx, f.aria.ID, 100, 1)
	if err := f.svc.Deposit(ctx, f.aria.ID, 0, 0); !errors.Is(err, ErrNothingToMove) {
		t.Fatalf("deposit of 0: got %v, want ErrNothingToMove", err)
	}
}
