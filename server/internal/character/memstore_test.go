package character

import (
	"context"
	"errors"
	"testing"
)

func TestCreateAndList(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()

	c, err := store.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if c.Name != "Aria" || c.AccountID != 1 {
		t.Fatalf("unexpected character: %+v", c)
	}

	list, err := store.ListByAccount(ctx, 1)
	if err != nil {
		t.Fatalf("ListByAccount: %v", err)
	}
	if len(list) != 1 || list[0].ID != c.ID {
		t.Fatalf("got %+v, want a single-element list containing %+v", list, c)
	}
}

func TestListByAccountIsolatesAccounts(t *testing.T) {
	store := NewMemStore()
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

func TestCreateNameTakenCaseInsensitive(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()

	if _, err := store.Create(ctx, 1, "Aria"); err != nil {
		t.Fatalf("first Create: %v", err)
	}
	_, err := store.Create(ctx, 2, "ARIA")
	if !errors.Is(err, ErrNameTaken) {
		t.Fatalf("got %v, want ErrNameTaken (names should be case-insensitively unique)", err)
	}
}

func TestCreateEnforcesMaxPerAccount(t *testing.T) {
	store := NewMemStore()
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

func TestDeleteRemovesCharacterAndFreesName(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()

	c, _ := store.Create(ctx, 1, "Aria")

	if err := store.Delete(ctx, 1, c.ID); err != nil {
		t.Fatalf("Delete: %v", err)
	}

	list, _ := store.ListByAccount(ctx, 1)
	if len(list) != 0 {
		t.Fatalf("expected no characters after delete, got %+v", list)
	}

	// The name should be free again.
	if _, err := store.Create(ctx, 2, "Aria"); err != nil {
		t.Fatalf("expected freed name to be reusable, got: %v", err)
	}
}

func TestDeleteWrongAccountFails(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()

	c, _ := store.Create(ctx, 1, "Aria")

	err := store.Delete(ctx, 2, c.ID)
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("got %v, want ErrNotFound (can't delete another account's character)", err)
	}

	// Confirm it's still there.
	list, _ := store.ListByAccount(ctx, 1)
	if len(list) != 1 {
		t.Fatalf("character should not have been deleted, got %+v", list)
	}
}

func TestDeleteNonexistent(t *testing.T) {
	store := NewMemStore()
	if err := store.Delete(context.Background(), 1, 999); !errors.Is(err, ErrNotFound) {
		t.Fatalf("got %v, want ErrNotFound", err)
	}
}
