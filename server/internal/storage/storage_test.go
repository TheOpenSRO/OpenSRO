package storage

import (
	"context"
	"errors"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/inventory"
)

// generousStacks lets everything stack, so a moved amount lands in one slot
// and the counts are easy to assert.
type generousStacks struct{}

func (generousStacks) GetMaxStack(_ context.Context, _ int64) (int, error) { return 1000, nil }

func newService() *Service {
	return &Service{
		Bag:       inventory.NewMemStore(generousStacks{}),
		Warehouse: inventory.NewMemStore(generousStacks{}),
	}
}

func slotOf(t *testing.T, store inventory.Store, characterID, itemID int64) inventory.Slot {
	t.Helper()
	slots, err := store.List(context.Background(), characterID)
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
	const cid, item = int64(1), int64(100)
	svc := newService()

	if err := svc.Bag.AddItem(ctx, cid, item, 5); err != nil {
		t.Fatalf("seeding bag: %v", err)
	}

	// Deposit 3 of the 5 into the warehouse.
	bagSlot := slotOf(t, svc.Bag, cid, item)
	if err := svc.Deposit(ctx, cid, bagSlot.Index, 3); err != nil {
		t.Fatalf("Deposit: %v", err)
	}
	if got := slotOf(t, svc.Bag, cid, item).Quantity; got != 2 {
		t.Fatalf("bag has %d after depositing 3 of 5, want 2", got)
	}
	if got := slotOf(t, svc.Warehouse, cid, item).Quantity; got != 3 {
		t.Fatalf("warehouse has %d after deposit, want 3", got)
	}

	// Withdraw 1 back.
	whSlot := slotOf(t, svc.Warehouse, cid, item)
	if err := svc.Withdraw(ctx, cid, whSlot.Index, 1); err != nil {
		t.Fatalf("Withdraw: %v", err)
	}
	if got := slotOf(t, svc.Warehouse, cid, item).Quantity; got != 2 {
		t.Fatalf("warehouse has %d after withdrawing 1, want 2", got)
	}
	if got := slotOf(t, svc.Bag, cid, item).Quantity; got != 3 {
		t.Fatalf("bag has %d after withdraw, want 3", got)
	}
}

func TestDepositMoreThanHeldMovesWhatIsThere(t *testing.T) {
	ctx := context.Background()
	const cid, item = int64(1), int64(100)
	svc := newService()
	if err := svc.Bag.AddItem(ctx, cid, item, 2); err != nil {
		t.Fatalf("seeding bag: %v", err)
	}
	bagSlot := slotOf(t, svc.Bag, cid, item)
	if err := svc.Deposit(ctx, cid, bagSlot.Index, 99); err != nil {
		t.Fatalf("Deposit: %v", err)
	}
	if got := slotOf(t, svc.Warehouse, cid, item).Quantity; got != 2 {
		t.Fatalf("warehouse has %d, want the 2 that were actually held", got)
	}
	if left, _ := svc.Bag.List(ctx, cid); len(left) != 0 {
		t.Fatalf("bag should be empty, got %+v", left)
	}
}

func TestMoveEmptyAndNonPositive(t *testing.T) {
	ctx := context.Background()
	svc := newService()
	if err := svc.Deposit(ctx, 1, 0, 1); !errors.Is(err, ErrSlotEmpty) {
		t.Fatalf("deposit from empty slot: got %v, want ErrSlotEmpty", err)
	}
	_ = svc.Bag.AddItem(ctx, 1, 100, 1)
	if err := svc.Deposit(ctx, 1, 0, 0); !errors.Is(err, ErrNothingToMove) {
		t.Fatalf("deposit of 0: got %v, want ErrNothingToMove", err)
	}
}
