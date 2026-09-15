package character

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
	if _, err := s.db.Exec(`TRUNCATE TABLE characters RESTART IDENTITY CASCADE`); err != nil {
		t.Fatalf("truncating characters table: %v", err)
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

// TestSQLStorePersistsAcrossReopen confirms data survives closing this
// store's connection and reopening a new one against the same database.
func TestSQLStorePersistsAcrossReopen(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	if _, err := store.Create(ctx, 1, "Aria"); err != nil {
		t.Fatalf("Create: %v", err)
	}
	if err := store.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	s2, err := OpenSQLStore(testDSN())
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

func TestSQLStoreGoldOperations(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()
	c, err := store.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if c.Gold != StartingGold {
		t.Fatalf("got starting Gold %d, want %d", c.Gold, StartingGold)
	}

	if err := store.AddGold(ctx, c.ID, 500); err != nil {
		t.Fatalf("AddGold: %v", err)
	}
	if err := store.DeductGold(ctx, c.ID, 200); err != nil {
		t.Fatalf("DeductGold: %v", err)
	}

	list, err := store.ListByAccount(ctx, 1)
	if err != nil {
		t.Fatalf("ListByAccount: %v", err)
	}
	want := int64(StartingGold) + 500 - 200
	if list[0].Gold != want {
		t.Fatalf("got Gold %d, want %d", list[0].Gold, want)
	}
}

func TestSQLStoreDeductGoldInsufficientFunds(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()
	c, _ := store.Create(ctx, 1, "Aria")

	err := store.DeductGold(ctx, c.ID, StartingGold+1)
	if !errors.Is(err, ErrInsufficientGold) {
		t.Fatalf("got %v, want ErrInsufficientGold", err)
	}
}

func TestSQLStoreHPOperations(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()
	c, err := store.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if c.HP != StartingMaxHP {
		t.Fatalf("got starting HP %d, want %d", c.HP, StartingMaxHP)
	}

	hp, died, err := store.ApplyDamage(ctx, c.ID, 30)
	if err != nil {
		t.Fatalf("ApplyDamage: %v", err)
	}
	if died || hp != StartingMaxHP-30 {
		t.Fatalf("got hp=%d died=%v, want hp=%d died=false", hp, died, StartingMaxHP-30)
	}

	hp, died, err = store.ApplyDamage(ctx, c.ID, StartingMaxHP)
	if err != nil {
		t.Fatalf("ApplyDamage: %v", err)
	}
	if !died || hp != 0 {
		t.Fatalf("got hp=%d died=%v, want hp=0 died=true (clamped, not negative)", hp, died)
	}

	if err := store.ResetHP(ctx, c.ID); err != nil {
		t.Fatalf("ResetHP: %v", err)
	}
	list, err := store.ListByAccount(ctx, 1)
	if err != nil {
		t.Fatalf("ListByAccount: %v", err)
	}
	if list[0].HP != StartingMaxHP {
		t.Fatalf("got HP %d after reset, want %d", list[0].HP, StartingMaxHP)
	}
}

func TestSQLStoreApplyDamageNonexistentCharacter(t *testing.T) {
	store := openTestSQLStore(t)
	if _, _, err := store.ApplyDamage(context.Background(), 999, 10); !errors.Is(err, ErrNotFound) {
		t.Fatalf("got %v, want ErrNotFound", err)
	}
}

func TestSQLStoreNewCharacterHasDefaultGender(t *testing.T) {
	store := openTestSQLStore(t)
	c, err := store.Create(context.Background(), 1, "Aria")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if c.Gender != DefaultGender {
		t.Fatalf("got gender %q, want %q", c.Gender, DefaultGender)
	}
}

func TestSQLStoreSetGenderAndGetByID(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()
	c, err := store.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

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

	// ListByAccount should reflect the same real update, not just GetByID.
	list, err := store.ListByAccount(ctx, 1)
	if err != nil {
		t.Fatalf("ListByAccount: %v", err)
	}
	if len(list) != 1 || list[0].Gender != GenderChinaWoman {
		t.Fatalf("got %+v, want one character with gender %q", list, GenderChinaWoman)
	}
}

func TestSQLStoreSetGenderNonexistentCharacter(t *testing.T) {
	store := openTestSQLStore(t)
	if err := store.SetGender(context.Background(), 999, GenderChinaWoman); !errors.Is(err, ErrNotFound) {
		t.Fatalf("got %v, want ErrNotFound", err)
	}
}

func TestSQLStoreGetByIDNonexistentCharacter(t *testing.T) {
	store := openTestSQLStore(t)
	if _, err := store.GetByID(context.Background(), 999); !errors.Is(err, ErrNotFound) {
		t.Fatalf("got %v, want ErrNotFound", err)
	}
}

var _ Store = (*SQLStore)(nil)

// The SQL store must respawn at the same fraction as the in-memory one --
// they are the same recovered rule, and a deployment swapping one for the other
// must not change how much health a death costs.
func TestSQLRespawnMatchesTheMemStore(t *testing.T) {
	ctx := context.Background()
	s, err := OpenSQLStore(testDSN())
	if err != nil {
		t.Fatalf("OpenSQLStore: %v (is postgres running?)", err)
	}
	defer s.Close()
	c, err := s.Create(ctx, 4242, "Respawner")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	full := c.MaxHP()
	if _, _, err := s.ApplyDamage(ctx, c.ID, full); err != nil {
		t.Fatalf("ApplyDamage: %v", err)
	}
	if err := s.RespawnHP(ctx, c.ID); err != nil {
		t.Fatalf("RespawnHP: %v", err)
	}
	got, err := s.GetByID(ctx, c.ID)
	if err != nil {
		t.Fatalf("GetByID: %v", err)
	}
	want := int(float64(full) * RespawnFraction)
	if got.HP != want {
		t.Errorf("SQL respawn HP = %d, want %d (the MemStore's answer for the same character)", got.HP, want)
	}
	if got.HP >= full {
		t.Errorf("SQL respawn gave the full pool (%d)", got.HP)
	}
}
