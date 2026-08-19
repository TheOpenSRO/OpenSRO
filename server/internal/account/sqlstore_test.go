package account

import (
	"context"
	"errors"
	"testing"
)

func openTestSQLStore(t *testing.T) *SQLStore {
	t.Helper()
	// A unique in-memory database per test (not a shared cache) so tests
	// can't interfere with each other.
	s, err := OpenSQLStore(":memory:")
	if err != nil {
		t.Fatalf("OpenSQLStore: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestSQLStoreRegisterAndAuthenticate(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	acc, err := store.Register(ctx, "alice", "hunter2")
	if err != nil {
		t.Fatalf("Register: %v", err)
	}
	if acc.ID == 0 {
		t.Fatal("expected a nonzero assigned ID")
	}

	got, err := store.Authenticate(ctx, "alice", "hunter2")
	if err != nil {
		t.Fatalf("Authenticate: %v", err)
	}
	if got.Username != "alice" {
		t.Fatalf("got username %q, want alice", got.Username)
	}
}

func TestSQLStoreRegisterDuplicateUsername(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	if _, err := store.Register(ctx, "alice", "pw1"); err != nil {
		t.Fatalf("first Register: %v", err)
	}
	_, err := store.Register(ctx, "alice", "pw2")
	if !errors.Is(err, ErrUsernameTaken) {
		t.Fatalf("got %v, want ErrUsernameTaken", err)
	}
}

func TestSQLStoreAuthenticateWrongPassword(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()
	store.Register(ctx, "alice", "hunter2")

	_, err := store.Authenticate(ctx, "alice", "wrong")
	if !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("got %v, want ErrInvalidCredentials", err)
	}
}

func TestSQLStoreAuthenticateUnknownUser(t *testing.T) {
	store := openTestSQLStore(t)
	_, err := store.Authenticate(context.Background(), "nobody", "anything")
	if !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("got %v, want ErrInvalidCredentials", err)
	}
}

func TestSQLStoreBlockedAccount(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()
	store.Register(ctx, "alice", "hunter2")

	if err := store.SetBlocked(ctx, "alice", true, "test"); err != nil {
		t.Fatalf("SetBlocked: %v", err)
	}

	_, err := store.Authenticate(ctx, "alice", "hunter2")
	if !errors.Is(err, ErrBlocked) {
		t.Fatalf("got %v, want ErrBlocked", err)
	}

	if err := store.SetBlocked(ctx, "alice", false, ""); err != nil {
		t.Fatalf("un-blocking: %v", err)
	}
	if _, err := store.Authenticate(ctx, "alice", "hunter2"); err != nil {
		t.Fatalf("expected auth to succeed after unblocking, got: %v", err)
	}
}

func TestSQLStoreSetBlockedUnknownAccount(t *testing.T) {
	store := openTestSQLStore(t)
	err := store.SetBlocked(context.Background(), "nobody", true, "test")
	if err == nil {
		t.Fatal("expected an error blocking a nonexistent account, got nil")
	}
}

// TestSQLStorePersistsAcrossReopen uses a temp file (not :memory:) to
// confirm data actually survives closing and reopening the store -- the
// whole point of this being a persistent Store rather than MemStore.
func TestSQLStorePersistsAcrossReopen(t *testing.T) {
	dsn := "file:" + t.TempDir() + "/test.db"
	ctx := context.Background()

	s1, err := OpenSQLStore(dsn)
	if err != nil {
		t.Fatalf("OpenSQLStore (first open): %v", err)
	}
	if _, err := s1.Register(ctx, "alice", "hunter2"); err != nil {
		t.Fatalf("Register: %v", err)
	}
	if err := s1.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	s2, err := OpenSQLStore(dsn)
	if err != nil {
		t.Fatalf("OpenSQLStore (second open): %v", err)
	}
	defer s2.Close()

	if _, err := s2.Authenticate(ctx, "alice", "hunter2"); err != nil {
		t.Fatalf("expected account to persist across reopen, got: %v", err)
	}
}

// Both Store and Registerer should be satisfied at compile time.
var (
	_ Store      = (*SQLStore)(nil)
	_ Registerer = (*SQLStore)(nil)
)
