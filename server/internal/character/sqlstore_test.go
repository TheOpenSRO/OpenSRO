package character

import (
	"context"
	"errors"
	"testing"
)

func openTestSQLStore(t *testing.T) *SQLStore {
	t.Helper()
	s, err := OpenSQLStore(":memory:")
	if err != nil {
		t.Fatalf("OpenSQLStore: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestSQLStoreCreateAndList(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	c, err := store.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if c.ID == 0 {
		t.Fatal("expected a nonzero assigned ID")
	}

	list, err := store.ListByAccount(ctx, 1)
	if err != nil {
		t.Fatalf("ListByAccount: %v", err)
	}
	if len(list) != 1 || list[0].Name != "Aria" {
		t.Fatalf("got %+v, want a single Aria", list)
	}
}

func TestSQLStoreListIsolatesAccounts(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()
	store.Create(ctx, 1, "Aria")
	store.Create(ctx, 2, "Bram")

	list, err := store.ListByAccount(ctx, 1)
	if err != nil {
		t.Fatalf("ListByAccount: %v", err)
	}
	if len(list) != 1 || list[0].Name != "Aria" {
		t.Fatalf("account 1 should only see its own character, got %+v", list)
	}
}

func TestSQLStoreNameTakenCaseInsensitive(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()
	if _, err := store.Create(ctx, 1, "Aria"); err != nil {
		t.Fatalf("first Create: %v", err)
	}
	_, err := store.Create(ctx, 2, "ARIA")
	if !errors.Is(err, ErrNameTaken) {
		t.Fatalf("got %v, want ErrNameTaken", err)
	}
}

func TestSQLStoreEnforcesMaxPerAccount(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()
	for i := 0; i < MaxPerAccount; i++ {
		if _, err := store.Create(ctx, 1, string(rune('A'+i))); err != nil {
			t.Fatalf("Create #%d: %v", i, err)
		}
	}
	_, err := store.Create(ctx, 1, "OneTooMany")
	if !errors.Is(err, ErrAccountFull) {
		t.Fatalf("got %v, want ErrAccountFull", err)
	}
}

func TestSQLStoreDelete(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()
	c, _ := store.Create(ctx, 1, "Aria")

	if err := store.Delete(ctx, 1, c.ID); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	list, _ := store.ListByAccount(ctx, 1)
	if len(list) != 0 {
		t.Fatalf("expected no characters after delete, got %+v", list)
	}
	// Name should be free again.
	if _, err := store.Create(ctx, 2, "Aria"); err != nil {
		t.Fatalf("expected freed name to be reusable, got: %v", err)
	}
}

func TestSQLStoreDeleteWrongAccountFails(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()
	c, _ := store.Create(ctx, 1, "Aria")

	if err := store.Delete(ctx, 2, c.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("got %v, want ErrNotFound", err)
	}
	list, _ := store.ListByAccount(ctx, 1)
	if len(list) != 1 {
		t.Fatalf("character should not have been deleted, got %+v", list)
	}
}

// TestSQLStorePersistsAcrossReopen confirms data survives closing and
// reopening the store, which is the entire point of it over MemStore.
func TestSQLStorePersistsAcrossReopen(t *testing.T) {
	dsn := "file:" + t.TempDir() + "/test.db"
	ctx := context.Background()

	s1, err := OpenSQLStore(dsn)
	if err != nil {
		t.Fatalf("OpenSQLStore (first open): %v", err)
	}
	if _, err := s1.Create(ctx, 1, "Aria"); err != nil {
		t.Fatalf("Create: %v", err)
	}
	if err := s1.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	s2, err := OpenSQLStore(dsn)
	if err != nil {
		t.Fatalf("OpenSQLStore (second open): %v", err)
	}
	defer s2.Close()

	list, err := s2.ListByAccount(ctx, 1)
	if err != nil {
		t.Fatalf("ListByAccount: %v", err)
	}
	if len(list) != 1 || list[0].Name != "Aria" {
		t.Fatalf("expected character to persist across reopen, got %+v", list)
	}
}

var _ Store = (*SQLStore)(nil)
