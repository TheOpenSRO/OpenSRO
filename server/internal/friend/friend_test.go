package friend

import (
	"context"
	"errors"
	"testing"
)

// TestMaxFriendsMatchesTheEngine pins the recovered cap and the strictness of
// its comparison. The engine's check is `jb` on 0x14 -- strictly fewer than 20
// may add -- so 20 is a full list, not a permitted one.
func TestMaxFriendsMatchesTheEngine(t *testing.T) {
	if MaxFriends != 0x14 {
		t.Errorf("MaxFriends = %d, want 0x14 = 20 (the `cmp [esi+0x14],0x14` at 005d7746)", MaxFriends)
	}
}

// storeContract is what every Store does: a mutual add, each side listing
// the other's name, the refusals, and a mutual remove.
func storeContract(t *testing.T, store Store) {
	t.Helper()
	ctx := context.Background()
	if err := store.AddFriendship(ctx, 1, "One", 1, "One"); !errors.Is(err, ErrCannotFriendSelf) {
		t.Fatalf("befriending yourself: got %v, want ErrCannotFriendSelf", err)
	}
	if err := store.AddFriendship(ctx, 1, "One", 2, "Two"); err != nil {
		t.Fatalf("AddFriendship: %v", err)
	}
	one, _ := store.ListFriends(ctx, 1)
	two, _ := store.ListFriends(ctx, 2)
	if len(one) != 1 || one[0].CharacterID != 2 || one[0].Name != "Two" {
		t.Fatalf("1's friends = %+v", one)
	}
	if len(two) != 1 || two[0].CharacterID != 1 || two[0].Name != "One" {
		t.Fatalf("2's friends = %+v", two)
	}
	for _, pair := range [][2]int64{{1, 2}, {2, 1}} {
		if err := store.AddFriendship(ctx, pair[0], "x", pair[1], "y"); !errors.Is(err, ErrAlreadyFriends) {
			t.Fatalf("adding %v again: got %v, want ErrAlreadyFriends", pair, err)
		}
	}
	if err := store.RemoveFriend(ctx, 1, 3); !errors.Is(err, ErrNotFriends) {
		t.Fatalf("removing a non-friend: got %v, want ErrNotFriends", err)
	}
	// Removal is mutual and either side may do it.
	if err := store.RemoveFriend(ctx, 2, 1); err != nil {
		t.Fatalf("RemoveFriend: %v", err)
	}
	if f, _ := store.ListFriends(ctx, 1); len(f) != 0 {
		t.Fatalf("1 still has %+v", f)
	}
	if f, _ := store.ListFriends(ctx, 2); len(f) != 0 {
		t.Fatalf("2 still has %+v", f)
	}
}

// capContract fills a list to MaxFriends and checks the refusal lands there,
// whichever side of the add is full.
func capContract(t *testing.T, store Store) {
	t.Helper()
	ctx := context.Background()
	for i := int64(2); i <= MaxFriends+1; i++ {
		if err := store.AddFriendship(ctx, i, "R", 1, "Host"); err != nil {
			t.Fatalf("add %d of %d: %v", i-1, MaxFriends, err)
		}
	}
	if err := store.AddFriendship(ctx, 9000, "Late", 1, "Host"); !errors.Is(err, ErrListFull) {
		t.Errorf("adding to a full list: got %v, want ErrListFull", err)
	}
	if err := store.AddFriendship(ctx, 1, "Host", 9001, "Late"); !errors.Is(err, ErrListFull) {
		t.Errorf("a full list adding: got %v, want ErrListFull", err)
	}
	if f, _ := store.ListFriends(ctx, 9000); len(f) != 0 {
		t.Errorf("a refused add left %+v on the other side", f)
	}
}

func TestMemStoreContract(t *testing.T) { storeContract(t, NewMemStore()) }

func TestMemStoreFillsToTheCap(t *testing.T) { capContract(t, NewMemStore()) }
