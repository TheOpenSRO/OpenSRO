package character

import (
	"context"
	"testing"
)

// Round 684's review: the in-memory list is in creation order on every call,
// as the SQL store's ORDER BY id is -- a map's random order swapped
// equal-level characters' slots between lists, and the select screen's
// re-select by slot index (READ 0x85f840) then landed on another character.
// NEGATIVE: before the sort, 200 lists of four in a row came out in more
// than one order.
func TestListByAccountIsInCreationOrder(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()
	var want []int64
	for _, n := range []string{"Qachina", "Qaeuro", "Qaknight", "Qaspear"} {
		c, err := store.Create(ctx, 7, n)
		if err != nil {
			t.Fatalf("Create %s: %v", n, err)
		}
		want = append(want, c.ID)
	}
	if _, err := store.Create(ctx, 8, "Other"); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 200; i++ {
		list, err := store.ListByAccount(ctx, 7)
		if err != nil {
			t.Fatal(err)
		}
		if len(list) != len(want) {
			t.Fatalf("list %d: %d characters, want %d", i, len(list), len(want))
		}
		for k, c := range list {
			if c.ID != want[k] {
				t.Fatalf("list %d: slot %d is id %d, want %d (creation order)", i, k, c.ID, want[k])
			}
		}
	}
}
