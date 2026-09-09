package friend

import (
	"context"
	"testing"
)

func TestMemStoreRequestAndAccept(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()

	if err := store.SendRequest(ctx, 1, "One", 1); err != ErrCannotFriendSelf {
		t.Fatalf("befriending yourself: got %v, want ErrCannotFriendSelf", err)
	}
	if err := store.SendRequest(ctx, 1, "One", 2); err != nil {
		t.Fatalf("SendRequest: %v", err)
	}
	if err := store.SendRequest(ctx, 1, "One", 2); err != ErrRequestAlreadySent {
		t.Fatalf("sending twice: got %v, want ErrRequestAlreadySent", err)
	}

	pending, err := store.ListPendingRequests(ctx, 2)
	if err != nil {
		t.Fatalf("ListPendingRequests: %v", err)
	}
	if len(pending) != 1 || pending[0].RequesterID != 1 || pending[0].RequesterName != "One" {
		t.Fatalf("pending = %+v, want one request from One", pending)
	}
	// The request is addressed to 2, so 1 must not see it as incoming.
	if p, _ := store.ListPendingRequests(ctx, 1); len(p) != 0 {
		t.Fatalf("the sender sees %+v as incoming", p)
	}

	if err := store.AcceptRequest(ctx, 2, "Two", 1); err != nil {
		t.Fatalf("AcceptRequest: %v", err)
	}
	if p, _ := store.ListPendingRequests(ctx, 2); len(p) != 0 {
		t.Fatalf("an accepted request is still pending: %+v", p)
	}

	// The friendship is mutual, and each side sees the other's name.
	one, _ := store.ListFriends(ctx, 1)
	two, _ := store.ListFriends(ctx, 2)
	if len(one) != 1 || one[0].CharacterID != 2 || one[0].Name != "Two" {
		t.Fatalf("1's friends = %+v", one)
	}
	if len(two) != 1 || two[0].CharacterID != 1 || two[0].Name != "One" {
		t.Fatalf("2's friends = %+v", two)
	}

	if err := store.SendRequest(ctx, 1, "One", 2); err != ErrAlreadyFriends {
		t.Fatalf("requesting an existing friend: got %v, want ErrAlreadyFriends", err)
	}
}

func TestMemStoreDeclineAndRemove(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()

	if err := store.DeclineRequest(ctx, 2, 1); err != ErrNoSuchRequest {
		t.Fatalf("declining nothing: got %v, want ErrNoSuchRequest", err)
	}
	if err := store.SendRequest(ctx, 1, "One", 2); err != nil {
		t.Fatalf("SendRequest: %v", err)
	}
	if err := store.DeclineRequest(ctx, 2, 1); err != nil {
		t.Fatalf("DeclineRequest: %v", err)
	}
	if f, _ := store.ListFriends(ctx, 2); len(f) != 0 {
		t.Fatalf("a declined request made a friendship: %+v", f)
	}

	if err := store.RemoveFriend(ctx, 1, 2); err != ErrNotFriends {
		t.Fatalf("removing a non-friend: got %v, want ErrNotFriends", err)
	}
	store.SendRequest(ctx, 1, "One", 2)
	store.AcceptRequest(ctx, 2, "Two", 1)
	if err := store.RemoveFriend(ctx, 1, 2); err != nil {
		t.Fatalf("RemoveFriend: %v", err)
	}
	// Removal is mutual: neither side keeps the other.
	if f, _ := store.ListFriends(ctx, 1); len(f) != 0 {
		t.Fatalf("1 still has %+v", f)
	}
	if f, _ := store.ListFriends(ctx, 2); len(f) != 0 {
		t.Fatalf("2 still has %+v", f)
	}
}
