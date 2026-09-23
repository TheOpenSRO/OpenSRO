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
