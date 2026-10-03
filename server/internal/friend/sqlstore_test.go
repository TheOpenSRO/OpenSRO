package friend

import (
	"context"
	"errors"
	"os"
	"testing"
)

func testDSN() string {
	if v := os.Getenv("OPENSRO_TEST_POSTGRES_DSN"); v != "" {
		return v
	}
	return "postgres://postgres:postgres@localhost:5432/opensro_test?sslmode=disable"
}

func openTestSQLStore(t *testing.T) *SQLStore {
	t.Helper()
	s, err := OpenSQLStore(testDSN())
	if err != nil {
		t.Fatalf("OpenSQLStore: %v (is postgres running?)", err)
	}
	if err := s.TruncateForTest(context.Background()); err != nil {
		t.Fatalf("truncating friend tables: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestSendRequestAndListPending(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	if err := store.SendRequest(ctx, 1, "Aria", 2); err != nil {
		t.Fatalf("SendRequest: %v", err)
	}

	pending, err := store.ListPendingRequests(ctx, 2)
	if err != nil {
		t.Fatalf("ListPendingRequests: %v", err)
	}
	if len(pending) != 1 || pending[0].RequesterID != 1 || pending[0].RequesterName != "Aria" {
		t.Fatalf("unexpected pending requests: %+v", pending)
	}
}

func TestSendRequestSelf(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()
	if err := store.SendRequest(ctx, 1, "Aria", 1); !errors.Is(err, ErrCannotFriendSelf) {
		t.Fatalf("got %v, want ErrCannotFriendSelf", err)
	}
}

func TestSendRequestAlreadySent(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()
	if err := store.SendRequest(ctx, 1, "Aria", 2); err != nil {
		t.Fatalf("SendRequest: %v", err)
	}
	if err := store.SendRequest(ctx, 1, "Aria", 2); !errors.Is(err, ErrRequestAlreadySent) {
		t.Fatalf("got %v, want ErrRequestAlreadySent", err)
	}
}

func TestSendRequestAlreadyFriends(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()
	if err := store.SendRequest(ctx, 1, "Aria", 2); err != nil {
		t.Fatalf("SendRequest: %v", err)
	}
	if err := store.AcceptRequest(ctx, 2, "Bram", 1); err != nil {
		t.Fatalf("AcceptRequest: %v", err)
	}
	if err := store.SendRequest(ctx, 1, "Aria", 2); !errors.Is(err, ErrAlreadyFriends) {
		t.Fatalf("got %v, want ErrAlreadyFriends", err)
	}
}

func TestAcceptRequestFormsSymmetricFriendship(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()
	if err := store.SendRequest(ctx, 1, "Aria", 2); err != nil {
		t.Fatalf("SendRequest: %v", err)
	}
	if err := store.AcceptRequest(ctx, 2, "Bram", 1); err != nil {
		t.Fatalf("AcceptRequest: %v", err)
	}

	friendsOfAria, err := store.ListFriends(ctx, 1)
	if err != nil {
		t.Fatalf("ListFriends(1): %v", err)
	}
	if len(friendsOfAria) != 1 || friendsOfAria[0].CharacterID != 2 || friendsOfAria[0].Name != "Bram" {
		t.Fatalf("unexpected friends of Aria: %+v", friendsOfAria)
	}

	friendsOfBram, err := store.ListFriends(ctx, 2)
	if err != nil {
		t.Fatalf("ListFriends(2): %v", err)
	}
	if len(friendsOfBram) != 1 || friendsOfBram[0].CharacterID != 1 || friendsOfBram[0].Name != "Aria" {
		t.Fatalf("unexpected friends of Bram: %+v", friendsOfBram)
	}

	// The request should be consumed, not still pending.
	pending, err := store.ListPendingRequests(ctx, 2)
	if err != nil {
		t.Fatalf("ListPendingRequests: %v", err)
	}
	if len(pending) != 0 {
		t.Fatalf("expected no pending requests after accept, got %+v", pending)
	}
}

func TestAcceptRequestNoSuchRequest(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()
	if err := store.AcceptRequest(ctx, 2, "Bram", 1); !errors.Is(err, ErrNoSuchRequest) {
		t.Fatalf("got %v, want ErrNoSuchRequest", err)
	}
}

func TestDeclineRequest(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()
	if err := store.SendRequest(ctx, 1, "Aria", 2); err != nil {
		t.Fatalf("SendRequest: %v", err)
	}
	if err := store.DeclineRequest(ctx, 2, 1); err != nil {
		t.Fatalf("DeclineRequest: %v", err)
	}

	friends, err := store.ListFriends(ctx, 1)
	if err != nil {
		t.Fatalf("ListFriends: %v", err)
	}
	if len(friends) != 0 {
		t.Fatalf("expected no friendship after decline, got %+v", friends)
	}

	if err := store.DeclineRequest(ctx, 2, 1); !errors.Is(err, ErrNoSuchRequest) {
		t.Fatalf("second decline: got %v, want ErrNoSuchRequest", err)
	}
}

func TestRemoveFriend(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()
	if err := store.SendRequest(ctx, 1, "Aria", 2); err != nil {
		t.Fatalf("SendRequest: %v", err)
	}
	if err := store.AcceptRequest(ctx, 2, "Bram", 1); err != nil {
		t.Fatalf("AcceptRequest: %v", err)
	}

	if err := store.RemoveFriend(ctx, 1, 2); err != nil {
		t.Fatalf("RemoveFriend: %v", err)
	}

	if friends, err := store.ListFriends(ctx, 1); err != nil || len(friends) != 0 {
		t.Fatalf("ListFriends(1) after remove: %+v, err=%v", friends, err)
	}
	if friends, err := store.ListFriends(ctx, 2); err != nil || len(friends) != 0 {
		t.Fatalf("ListFriends(2) after remove: %+v, err=%v", friends, err)
	}
}

func TestRemoveFriendNotFriends(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()
	if err := store.RemoveFriend(ctx, 1, 2); !errors.Is(err, ErrNotFriends) {
		t.Fatalf("got %v, want ErrNotFriends", err)
	}
}
