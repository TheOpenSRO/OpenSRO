package storage

import (
	"context"
	"errors"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
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

// expandable wires the fixture the way cmd/server does since round 498: the
// warehouse store bounded by each account's own size, the service growing it.
func expandable(f *fixture) *fixture {
	wh := inventory.NewMemStore(generousStacks{})
	wh.SetCapacity(DefaultCapacity)
	wh.SetCapacityFunc(CapacityOf(f.accounts))
	f.svc.Warehouse = wh
	f.svc.ChestSizes = f.accounts
	return f
}

// The warehouse size is the ACCOUNT's (`_ChestInfo.ChestSize`, loaded by
// UserJID) and the expansion item grows it (round 498): Aria's expansion gives
// Bram the same 80 slots and the container really admits slot 50. The kind-3
// ExpandInventory bound (0x4e194d `cmp ecx,0xd2 ; jle`) lets it reach 200 in
// 30-slot steps from the default 50 and refuses the next with 0x18fe.
func TestExpandIsPerAccountAndCapped(t *testing.T) {
	ctx := context.Background()
	f := expandable(newFixture(t))
	aid := f.account.ID

	capacityOf := func(c *character.Character) int {
		t.Helper()
		n, err := f.svc.Capacity(ctx, c.ID)
		if err != nil {
			t.Fatalf("Capacity(%s): %v", c.Name, err)
		}
		return n
	}
	if a, b := capacityOf(f.aria), capacityOf(f.bram); a != DefaultCapacity || b != DefaultCapacity {
		t.Fatalf("fresh account: Aria sees %d, Bram %d, want %d both", a, b, DefaultCapacity)
	}

	// Fill all 50 slots with distinct items; the 51st deposit has nowhere to go.
	for i := 0; i < DefaultCapacity; i++ {
		if err := f.svc.Warehouse.AddItem(ctx, aid, int64(1000+i), 1); err != nil {
			t.Fatalf("filling slot %d: %v", i, err)
		}
	}
	const extra = int64(100)
	if err := f.svc.Bag.AddItem(ctx, f.bram.ID, extra, 1); err != nil {
		t.Fatalf("seeding Bram's bag: %v", err)
	}
	if err := f.svc.Deposit(ctx, f.bram.ID, slotOf(t, f.svc.Bag, f.bram.ID, extra).Index, 1); !errors.Is(err, inventory.ErrNoRoom) {
		t.Fatalf("the 51st deposit into a 50-slot warehouse: got %v, want ErrNoRoom", err)
	}

	// Aria uses an expansion; the account's warehouse is 80 for both.
	n, err := f.svc.Expand(ctx, f.aria.ID, inventory.WarehouseAdditionSlots)
	if err != nil || n != 80 {
		t.Fatalf("Expand = %d, %v; want 80", n, err)
	}
	if a, b := capacityOf(f.aria), capacityOf(f.bram); a != 80 || b != 80 {
		t.Fatalf("after one expansion Aria sees %d, Bram %d, want 80 both", a, b)
	}
	if err := f.svc.Deposit(ctx, f.bram.ID, slotOf(t, f.svc.Bag, f.bram.ID, extra).Index, 1); err != nil {
		t.Fatalf("Bram's deposit after the expansion: %v", err)
	}
	if got := slotOf(t, f.svc.Warehouse, aid, extra).Index; got != 50 {
		t.Fatalf("Bram's deposit landed in slot %d, want 50 (the first new slot)", got)
	}
	if err := f.svc.Withdraw(ctx, f.aria.ID, 50, 1); err != nil {
		t.Fatalf("withdrawing from slot 50: %v", err)
	}

	for _, want := range []int{110, 140, 170, 200} {
		if n, err := f.svc.Expand(ctx, f.aria.ID, inventory.WarehouseAdditionSlots); err != nil || n != want {
			t.Fatalf("Expand = %d, %v; want %d", n, err, want)
		}
	}
	if _, err := f.svc.Expand(ctx, f.bram.ID, inventory.WarehouseAdditionSlots); !errors.Is(err, ErrExpansionRefused) {
		t.Fatalf("Expand from 200: got %v, want ErrExpansionRefused (230 > 210)", err)
	}
	if got := capacityOf(f.bram); got != 200 {
		t.Fatalf("a refused expansion left %d, want 200", got)
	}

	// The bound is `size + amount < 0xd3`: 180 + 30 = 210 passes, 181 + 30 fails.
	for _, tc := range []struct {
		seeded int
		want   error
	}{{180, nil}, {181, ErrExpansionRefused}} {
		g := expandable(newFixture(t))
		if n, err := g.accounts.ExpandChest(ctx, g.account.ID, tc.seeded-30, 30, MaxCapacity); err != nil || n != tc.seeded {
			t.Fatalf("seeding %d: %d, %v", tc.seeded, n, err)
		}
		n, err := g.svc.Expand(ctx, g.aria.ID, inventory.WarehouseAdditionSlots)
		if !errors.Is(err, tc.want) {
			t.Fatalf("Expand from %d: got %d, %v; want %v", tc.seeded, n, err, tc.want)
		}
		if tc.want == nil && n != MaxCapacity {
			t.Fatalf("Expand from %d = %d, want %d", tc.seeded, n, MaxCapacity)
		}
	}
}

// Without a size store the warehouse keeps the container's own size and
// cannot grow.
func TestExpandWithoutChestSizesIsRefused(t *testing.T) {
	ctx := context.Background()
	f := newFixture(t)
	if n, err := f.svc.Capacity(ctx, f.aria.ID); err != nil || n != f.svc.Warehouse.Capacity() {
		t.Fatalf("Capacity = %d, %v; want the container's %d", n, err, f.svc.Warehouse.Capacity())
	}
	if _, err := f.svc.Expand(ctx, f.aria.ID, inventory.WarehouseAdditionSlots); err == nil {
		t.Fatal("Expand without a size store succeeded")
	}
}
