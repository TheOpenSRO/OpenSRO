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

func TestNewCharacterHasStartingGold(t *testing.T) {
	store := NewMemStore()
	c, _ := store.Create(context.Background(), 1, "Aria")
	if c.Gold != StartingGold {
		t.Fatalf("got Gold %d, want StartingGold %d", c.Gold, StartingGold)
	}
}

func TestAddGold(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()
	c, _ := store.Create(ctx, 1, "Aria")

	if err := store.AddGold(ctx, c.ID, 500); err != nil {
		t.Fatalf("AddGold: %v", err)
	}

	list, _ := store.ListByAccount(ctx, 1)
	if list[0].Gold != StartingGold+500 {
		t.Fatalf("got Gold %d, want %d", list[0].Gold, StartingGold+500)
	}
}

func TestDeductGold(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()
	c, _ := store.Create(ctx, 1, "Aria")

	if err := store.DeductGold(ctx, c.ID, 300); err != nil {
		t.Fatalf("DeductGold: %v", err)
	}

	list, _ := store.ListByAccount(ctx, 1)
	if list[0].Gold != StartingGold-300 {
		t.Fatalf("got Gold %d, want %d", list[0].Gold, StartingGold-300)
	}
}

func TestDeductGoldInsufficientFunds(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()
	c, _ := store.Create(ctx, 1, "Aria")

	err := store.DeductGold(ctx, c.ID, StartingGold+1)
	if !errors.Is(err, ErrInsufficientGold) {
		t.Fatalf("got %v, want ErrInsufficientGold", err)
	}

	// Balance should be unchanged.
	list, _ := store.ListByAccount(ctx, 1)
	if list[0].Gold != StartingGold {
		t.Fatalf("got Gold %d, want unchanged %d", list[0].Gold, StartingGold)
	}
}

func TestGoldOperationsOnNonexistentCharacter(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()
	if err := store.AddGold(ctx, 999, 100); !errors.Is(err, ErrNotFound) {
		t.Fatalf("AddGold: got %v, want ErrNotFound", err)
	}
	if err := store.DeductGold(ctx, 999, 100); !errors.Is(err, ErrNotFound) {
		t.Fatalf("DeductGold: got %v, want ErrNotFound", err)
	}
}

func TestNewCharacterHasFullHP(t *testing.T) {
	store := NewMemStore()
	c, _ := store.Create(context.Background(), 1, "Aria")
	if c.HP != MaxHP {
		t.Fatalf("got HP %d, want MaxHP %d", c.HP, MaxHP)
	}
}

func TestApplyDamageReducesHP(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()
	c, _ := store.Create(ctx, 1, "Aria")

	hp, died, err := store.ApplyDamage(ctx, c.ID, 30)
	if err != nil {
		t.Fatalf("ApplyDamage: %v", err)
	}
	if died || hp != MaxHP-30 {
		t.Fatalf("got hp=%d died=%v, want hp=%d died=false", hp, died, MaxHP-30)
	}
}

func TestApplyDamageClampsAtZeroAndReportsDeath(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()
	c, _ := store.Create(ctx, 1, "Aria")

	hp, died, err := store.ApplyDamage(ctx, c.ID, MaxHP+50)
	if err != nil {
		t.Fatalf("ApplyDamage: %v", err)
	}
	if !died || hp != 0 {
		t.Fatalf("got hp=%d died=%v, want hp=0 died=true", hp, died)
	}
}

func TestApplyDamageNonexistentCharacter(t *testing.T) {
	store := NewMemStore()
	if _, _, err := store.ApplyDamage(context.Background(), 999, 10); !errors.Is(err, ErrNotFound) {
		t.Fatalf("got %v, want ErrNotFound", err)
	}
}

func TestResetHP(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()
	c, _ := store.Create(ctx, 1, "Aria")
	store.ApplyDamage(ctx, c.ID, MaxHP)

	if err := store.ResetHP(ctx, c.ID); err != nil {
		t.Fatalf("ResetHP: %v", err)
	}

	list, _ := store.ListByAccount(ctx, 1)
	if list[0].HP != MaxHP {
		t.Fatalf("got HP %d after reset, want %d", list[0].HP, MaxHP)
	}
}

func TestNewCharacterHasDefaultGender(t *testing.T) {
	store := NewMemStore()
	c, err := store.Create(context.Background(), 1, "Aria")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if c.Gender != DefaultGender {
		t.Fatalf("got gender %q, want %q", c.Gender, DefaultGender)
	}
}

func TestSetGender(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()
	c, _ := store.Create(ctx, 1, "Aria")

	if err := store.SetGender(ctx, c.ID, GenderChinaWoman); err != nil {
		t.Fatalf("SetGender: %v", err)
	}

	got, err := store.GetByID(ctx, c.ID)
	if err != nil {
		t.Fatalf("GetByID: %v", err)
	}
	if got.Gender != GenderChinaWoman {
		t.Fatalf("got gender %q, want %q", got.Gender, GenderChinaWoman)
	}
}

func TestSetGenderNonexistentCharacter(t *testing.T) {
	store := NewMemStore()
	if err := store.SetGender(context.Background(), 999, GenderChinaWoman); !errors.Is(err, ErrNotFound) {
		t.Fatalf("got %v, want ErrNotFound", err)
	}
}

func TestGetByIDNonexistentCharacter(t *testing.T) {
	store := NewMemStore()
	if _, err := store.GetByID(context.Background(), 999); !errors.Is(err, ErrNotFound) {
		t.Fatalf("got %v, want ErrNotFound", err)
	}
}
