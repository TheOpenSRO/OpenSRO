package storage

import (
	"context"
	"errors"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
)

type feeItems map[int64]int64

func (f feeItems) GetItem(_ context.Context, id int64) (*refdata.Item, error) {
	fee, ok := f[id]
	if !ok {
		return nil, errors.New("no such item")
	}
	return &refdata.Item{ID: id, KeepingFee: fee}, nil
}

// Round 728: the server's fee, KeepingFee x the count clamped to
// 1..10,000,000 (READ, gs:0x524160 / 0x524300).
func TestDepositFeeArithmetic(t *testing.T) {
	cases := []struct {
		fee   int64
		count int
		want  int64
	}{
		{0, 1, 1}, {0, 50, 1}, {11, 1, 11}, {11, 3, 33}, {21, 0, 1},
		// ITEM_ETC_ARCHEMY_ATTRSTONE_ER_11: 2,500 x 10,000 is charged the cap.
		{2500, 10000, DepositFeeCap}, {1000, 10000, DepositFeeCap}, {999, 10000, 9_990_000},
	}
	for _, c := range cases {
		if got := DepositFee(c.fee, c.count); got != c.want {
			t.Errorf("DepositFee(%d, %d) = %d, want %d", c.fee, c.count, got, c.want)
		}
	}
}

func TestDepositChargesTheFeeOnWhatMoves(t *testing.T) {
	ctx := context.Background()
	const item = int64(100)
	f := newFixture(t)
	f.svc.Items = feeItems{item: 11}
	cid := f.aria.ID
	if err := f.svc.Bag.AddItem(ctx, cid, item, 5); err != nil {
		t.Fatal(err)
	}
	before, _ := f.chars.GetByID(ctx, cid)
	// Asking for 9 of a stack of 5 moves 5 and is charged for 5.
	if err := f.svc.Deposit(ctx, cid, slotOf(t, f.svc.Bag, cid, item).Index, 9); err != nil {
		t.Fatalf("Deposit: %v", err)
	}
	after, _ := f.chars.GetByID(ctx, cid)
	if before.Gold-after.Gold != 55 {
		t.Fatalf("charged %d, want 55 (11 x 5)", before.Gold-after.Gold)
	}
}

func TestDepositShortOfTheFeeMovesNothing(t *testing.T) {
	ctx := context.Background()
	const item = int64(100)
	f := newFixture(t)
	f.svc.Items = feeItems{item: 1_000_000_000}
	cid := f.aria.ID
	if err := f.svc.Bag.AddItem(ctx, cid, item, 1); err != nil {
		t.Fatal(err)
	}
	err := f.svc.Deposit(ctx, cid, slotOf(t, f.svc.Bag, cid, item).Index, 1)
	if !errors.Is(err, character.ErrInsufficientGold) {
		t.Fatalf("Deposit = %v, want ErrInsufficientGold", err)
	}
	if got := slotOf(t, f.svc.Bag, cid, item).Quantity; got != 1 {
		t.Fatalf("bag has %d after a refused deposit, want 1", got)
	}
	if rows, _ := f.svc.Warehouse.List(ctx, f.account.ID); len(rows) != 0 {
		t.Fatalf("warehouse got %+v from a refused deposit", rows)
	}
}

// With no item lookup the warehouse charges nothing, as before the fee.
func TestDepositWithoutItemsChargesNothing(t *testing.T) {
	ctx := context.Background()
	const item = int64(100)
	f := newFixture(t)
	cid := f.aria.ID
	if err := f.svc.Bag.AddItem(ctx, cid, item, 1); err != nil {
		t.Fatal(err)
	}
	before, _ := f.chars.GetByID(ctx, cid)
	if err := f.svc.Deposit(ctx, cid, slotOf(t, f.svc.Bag, cid, item).Index, 1); err != nil {
		t.Fatal(err)
	}
	after, _ := f.chars.GetByID(ctx, cid)
	if before.Gold != after.Gold {
		t.Fatalf("charged %d with no item lookup", before.Gold-after.Gold)
	}
}

// The retail deposit (0x7034 type 2): the whole stack into the named warehouse
// slot, the fee for the whole stack, the gold taken after the move.
func TestDepositStackMovesTheWholeStackIntoTheSlot(t *testing.T) {
	ctx := context.Background()
	const item = int64(100)
	f := newFixture(t)
	f.svc.Items = feeItems{item: 11}
	cid := f.aria.ID
	if err := f.svc.Bag.AddItem(ctx, cid, item, 5); err != nil {
		t.Fatal(err)
	}
	before, _ := f.chars.GetByID(ctx, cid)
	if err := f.svc.DepositStack(ctx, cid, slotOf(t, f.svc.Bag, cid, item).Index, 3); err != nil {
		t.Fatalf("DepositStack: %v", err)
	}
	after, _ := f.chars.GetByID(ctx, cid)
	if before.Gold-after.Gold != 55 {
		t.Fatalf("charged %d, want 55 (11 x the whole 5)", before.Gold-after.Gold)
	}
	list, _ := f.svc.List(ctx, cid)
	if len(list) != 1 || list[0].Index != 3 || list[0].Quantity != 5 {
		t.Fatalf("warehouse %+v, want 5 in slot 3", list)
	}
}
