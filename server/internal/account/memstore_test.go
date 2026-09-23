package account

import (
	"context"
	"errors"
	"testing"
)

func TestAuthenticateSuccess(t *testing.T) {
	store := NewMemStore()
	if _, err := store.Add("alice", "correct horse"); err != nil {
		t.Fatalf("Add: %v", err)
	}

	acc, err := store.Authenticate(context.Background(), "alice", "correct horse")
	if err != nil {
		t.Fatalf("Authenticate: %v", err)
	}
	if acc.Username != "alice" {
		t.Fatalf("got username %q, want alice", acc.Username)
	}
	if len(acc.PasswordHash) == 0 {
		t.Fatal("expected caller to still see the hash for its own bookkeeping, got none")
	}
}

func TestAuthenticateWrongPassword(t *testing.T) {
	store := NewMemStore()
	store.Add("alice", "correct horse")

	_, err := store.Authenticate(context.Background(), "alice", "wrong")
	if !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("got %v, want ErrInvalidCredentials", err)
	}
}

func TestAuthenticateUnknownUser(t *testing.T) {
	store := NewMemStore()

	_, err := store.Authenticate(context.Background(), "nobody", "anything")
	if !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("got %v, want ErrInvalidCredentials (not a distinct 'no such user' error)", err)
	}
}

func TestAuthenticateBlocked(t *testing.T) {
	store := NewMemStore()
	store.Add("alice", "correct horse")
	if err := store.SetBlocked("alice", true, "test"); err != nil {
		t.Fatalf("SetBlocked: %v", err)
	}

	_, err := store.Authenticate(context.Background(), "alice", "correct horse")
	if !errors.Is(err, ErrBlocked) {
		t.Fatalf("got %v, want ErrBlocked", err)
	}
}

func TestAddDuplicateUsername(t *testing.T) {
	store := NewMemStore()
	if _, err := store.Add("alice", "pw1"); err != nil {
		t.Fatalf("first Add: %v", err)
	}
	if _, err := store.Add("alice", "pw2"); err == nil {
		t.Fatal("expected error adding duplicate username, got nil")
	}
}

func TestAuthenticateReturnsCopyNotInternalPointer(t *testing.T) {
	store := NewMemStore()
	store.Add("alice", "correct horse")

	acc, err := store.Authenticate(context.Background(), "alice", "correct horse")
	if err != nil {
		t.Fatalf("Authenticate: %v", err)
	}
	acc.Blocked = true // mutate the caller's copy

	// A second, independent Authenticate call should be unaffected if the
	// store returned a copy rather than its internal pointer.
	if _, err := store.Authenticate(context.Background(), "alice", "correct horse"); err != nil {
		t.Fatalf("second Authenticate affected by caller's mutation of the first result: %v", err)
	}
}

// The warehouse size (round 498): 0 until an expansion is stored, then grown
// from max(stored, base) by the amount, refused -- unchanged -- past the
// ceiling. The numbers are the warehouse's: base storage.DefaultCapacity (50),
// +30 a use, ceiling 210 (ExpandInventory kind 3, 0x4e194d `cmp ecx,0xd2`).
func TestMemStoreChestSize(t *testing.T) {
	ctx := context.Background()
	store := NewMemStore()
	acc, err := store.Add("alice", "pw")
	if err != nil {
		t.Fatalf("Add: %v", err)
	}
	if n, err := store.ChestSize(ctx, acc.ID); err != nil || n != 0 {
		t.Fatalf("ChestSize of a fresh account = %d, %v; want 0, nil", n, err)
	}
	for _, want := range []int{80, 110, 140, 170, 200} {
		n, err := store.ExpandChest(ctx, acc.ID, 50, 30, 210)
		if err != nil || n != want {
			t.Fatalf("ExpandChest = %d, %v; want %d", n, err, want)
		}
	}
	if _, err := store.ExpandChest(ctx, acc.ID, 50, 30, 210); !errors.Is(err, ErrChestFull) {
		t.Fatalf("ExpandChest past 210 = %v, want ErrChestFull", err)
	}
	if n, _ := store.ChestSize(ctx, acc.ID); n != 200 {
		t.Fatalf("a refused expansion changed the size to %d, want 200", n)
	}
	if _, err := store.ExpandChest(ctx, 999, 50, 30, 210); !errors.Is(err, ErrNoSuchAccount) {
		t.Fatalf("ExpandChest on a missing account = %v, want ErrNoSuchAccount", err)
	}
	if _, err := store.ExpandChest(ctx, acc.ID, 50, 0, 210); err == nil {
		t.Fatal("ExpandChest by 0 succeeded")
	}
}
