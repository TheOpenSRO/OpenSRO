package inventory

import (
	"context"
	"errors"
	"testing"
)

// A container given a CapacityFunc is bounded per owner (round 498): the
// warehouse's size is the account's own. Owner 1 is answered 3 slots, owner 2
// is answered 0 and falls back to the container's own 2. Every per-owner
// bound -- AddItem's placement, RemoveItem, MoveItem, SetDurability -- follows
// the owner's answer, in both stores.
func TestCapacityFuncBoundsEachOwner(t *testing.T) {
	ctx := context.Background()
	perOwner := func(_ context.Context, owner int64) int {
		if owner == 1 {
			return 3
		}
		return 0
	}
	for name, s := range moveStores(t, stubMaxStacks{}) {
		switch st := s.(type) {
		case *MemStore:
			st.SetCapacity(2)
			st.SetCapacityFunc(perOwner)
		case *SQLStore:
			st.SetCapacity(2)
			st.SetCapacityFunc(perOwner)
		}
		for i := int64(0); i < 3; i++ {
			if err := s.AddItem(ctx, 1, 100+i, 1); err != nil {
				t.Fatalf("%s: owner 1 adding item %d of 3: %v", name, i+1, err)
			}
		}
		if err := s.AddItem(ctx, 1, 200, 1); !errors.Is(err, ErrNoRoom) {
			t.Fatalf("%s: owner 1's 4th item: got %v, want ErrNoRoom", name, err)
		}
		for i := int64(0); i < 2; i++ {
			if err := s.AddItem(ctx, 2, 100+i, 1); err != nil {
				t.Fatalf("%s: owner 2 adding item %d of 2: %v", name, i+1, err)
			}
		}
		if err := s.AddItem(ctx, 2, 200, 1); !errors.Is(err, ErrNoRoom) {
			t.Fatalf("%s: owner 2's 3rd item (fallback capacity 2): got %v, want ErrNoRoom", name, err)
		}
		if err := s.SetDurability(ctx, 1, 2, 7); err != nil {
			t.Fatalf("%s: SetDurability on owner 1's slot 2: %v", name, err)
		}
		if err := s.SetDurability(ctx, 2, 2, 7); !errors.Is(err, ErrInvalidSlot) {
			t.Fatalf("%s: SetDurability on owner 2's slot 2: got %v, want ErrInvalidSlot", name, err)
		}
		if err := s.MoveItem(ctx, 1, 2, 0); err != nil {
			t.Fatalf("%s: MoveItem from owner 1's slot 2: %v", name, err)
		}
		if err := s.MoveItem(ctx, 2, 0, 2); !errors.Is(err, ErrInvalidSlot) {
			t.Fatalf("%s: MoveItem to owner 2's slot 2: got %v, want ErrInvalidSlot", name, err)
		}
		if err := s.RemoveItem(ctx, 1, 2, 1); err != nil {
			t.Fatalf("%s: RemoveItem from owner 1's slot 2: %v", name, err)
		}
		if err := s.RemoveItem(ctx, 2, 2, 1); !errors.Is(err, ErrInvalidSlot) {
			t.Fatalf("%s: RemoveItem from owner 2's slot 2: got %v, want ErrInvalidSlot", name, err)
		}
	}
}

// Round 633's integration review: a bag whose size falls below a held slot
// (SetKeepHeld) keeps that slot REACHABLE -- listed, its durability written,
// emptied by a move or merge -- but places nothing new past the size. A lower
// -inventory-size of 32 with an item in slot 60: new items (topping up a stack
// included) fill only 0..31, no move may target 32..60, the held slot cannot
// be swapped into, and once it is emptied the bag is 32 again.
func TestKeepHeldReachesHeldSlotsButPlacesWithinTheSize(t *testing.T) {
	ctx := context.Background()
	for name, s := range moveStores(t, stubMaxStacks{100: 50}) {
		t.Run(name, func(t *testing.T) {
			size := 96
			f := func(context.Context, int64) int { return size }
			switch st := s.(type) {
			case *MemStore:
				st.SetCapacityFunc(f)
				st.SetKeepHeld(nil)
			case *SQLStore:
				st.SetCapacityFunc(f)
				st.SetKeepHeld(nil)
			}
			if err := s.AddItem(ctx, 1, 100, 10); err != nil {
				t.Fatal(err)
			}
			if err := s.MoveItem(ctx, 1, 0, 60); err != nil {
				t.Fatal(err)
			}
			if err := s.AddItem(ctx, 1, 300, 1); err != nil {
				t.Fatal(err)
			}
			size = 32 // the operator lowers the size
			if got := CapacityOf(ctx, s, 1); got != 61 {
				t.Fatalf("reach %d, want 61", got)
			}
			if got := PlacementCapacityOf(ctx, s, 1); got != 32 {
				t.Fatalf("placement size %d, want 32", got)
			}
			// A stack of the held item goes to a new slot within the size,
			// not onto slot 60.
			if err := s.AddItem(ctx, 1, 100, 5); err != nil {
				t.Fatal(err)
			}
			wantSlots(t, s, 1, "0:300x1", "1:100x5", "60:100x10")
			for i := int64(0); i < 30; i++ {
				if err := s.AddItem(ctx, 1, 400+i, 1); err != nil {
					t.Fatalf("item %d of the 30 that fill slots 2..31: %v", i+1, err)
				}
			}
			if err := s.AddItem(ctx, 1, 500, 1); !errors.Is(err, ErrNoRoom) {
				t.Fatalf("a 33rd item within a size of 32: got %v, want ErrNoRoom", err)
			}
			for _, to := range []int{32, 59, 60} {
				if err := s.MoveItem(ctx, 1, 2, to); !errors.Is(err, ErrInvalidSlot) {
					t.Fatalf("moving slot 2 to %d past the size: got %v, want ErrInvalidSlot", to, err)
				}
			}
			if err := s.MoveItem(ctx, 1, 60, 0); !errors.Is(err, ErrInvalidSlot) {
				t.Fatalf("swapping item 300 into held slot 60: got %v, want ErrInvalidSlot", err)
			}
			if err := s.SetDurability(ctx, 1, 60, 3); err != nil {
				t.Fatalf("the held slot's durability: %v", err)
			}
			// Merged onto slot 1's stack, slot 60 empties and the size is 32.
			if err := s.MoveItem(ctx, 1, 60, 1); err != nil {
				t.Fatalf("merging the held stack back: %v", err)
			}
			if got := CapacityOf(ctx, s, 1); got != 32 {
				t.Fatalf("reach after emptying slot 60: %d, want 32", got)
			}
		})
	}
}
