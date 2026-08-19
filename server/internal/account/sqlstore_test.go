package account

import (
	"context"
	"errors"
	"os"
	"testing"
)

// testDSN points at a local PostgreSQL instance for tests. Override with
// SRREVAMP_TEST_POSTGRES_DSN if your dev setup differs (e.g. CI).
func testDSN() string {
	if v := os.Getenv("SRREVAMP_TEST_POSTGRES_DSN"); v != "" {
		return v
	}
	return "postgres://postgres:postgres@localhost:5432/srrevamp_test?sslmode=disable"
}

func openTestSQLStore(t *testing.T) *SQLStore {
	t.Helper()
	s, err := OpenSQLStore(testDSN())
	if err != nil {
		t.Fatalf("OpenSQLStore: %v (is postgres running? see testDSN)", err)
	}
	// Each test gets a clean table -- tests share one real Postgres
	// instance/database, unlike SQLite's ":memory:" trick.
	if _, err := s.db.Exec(`TRUNCATE TABLE accounts RESTART IDENTITY CASCADE`); err != nil {
		t.Fatalf("truncating accounts table: %v", err)
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

// TestSQLStorePersistsAcrossReopen confirms data survives closing this
// store's connection and reopening a new one against the same database --
// the whole point of this being a persistent Store rather than MemStore.
func TestSQLStorePersistsAcrossReopen(t *testing.T) {
	store := openTestSQLStore(t) // truncates, but we close it ourselves below
	ctx := context.Background()

	if _, err := store.Register(ctx, "alice", "hunter2"); err != nil {
		t.Fatalf("Register: %v", err)
	}
	if err := store.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	s2, err := OpenSQLStore(testDSN())
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
