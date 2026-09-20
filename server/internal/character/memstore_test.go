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
	if c.HP != StartingMaxHP {
		t.Fatalf("got HP %d, want StartingMaxHP %d", c.HP, StartingMaxHP)
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
	if died || hp != StartingMaxHP-30 {
		t.Fatalf("got hp=%d died=%v, want hp=%d died=false", hp, died, StartingMaxHP-30)
	}
}

func TestApplyDamageClampsAtZeroAndReportsDeath(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()
	c, _ := store.Create(ctx, 1, "Aria")

	hp, died, err := store.ApplyDamage(ctx, c.ID, StartingMaxHP+50)
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
	store.ApplyDamage(ctx, c.ID, StartingMaxHP)

	if err := store.ResetHP(ctx, c.ID); err != nil {
		t.Fatalf("ResetHP: %v", err)
	}

	list, _ := store.ListByAccount(ctx, 1)
	if list[0].HP != StartingMaxHP {
		t.Fatalf("got HP %d after reset, want %d", list[0].HP, StartingMaxHP)
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

func TestDerivedHPAndMP(t *testing.T) {
	// The recovered formula: stat * 10 * 1.02^(level-1). Pinned at the shape
	// and at exact values, so a later "tidy-up" of the constants fails here
	// rather than quietly shipping a different game.
	if got := MaxHPFor(StartingStr, 1); got != StartingMaxHP {
		t.Fatalf("level 1 MaxHP = %d, want %d", got, StartingMaxHP)
	}
	if got := MaxMPFor(StartingInt, 1); got != StartingMaxMP {
		t.Fatalf("level 1 MaxMP = %d, want %d", got, StartingMaxMP)
	}
	// Str 20 at level 10: 20 * 10 * 1.02^9 = 238.99... -> 239.
	if got := MaxHPFor(20, 10); got != 239 {
		t.Fatalf("Str 20 at level 10 = %d, want 239", got)
	}
	// The stat is the base, so doubling it doubles health at any level --
	// within the one point that rounding each result separately can cost.
	if d := MaxHPFor(40, 25) - 2*MaxHPFor(20, 25); d < -1 || d > 1 {
		t.Fatalf("health is not linear in Str: %d vs %d", MaxHPFor(40, 25), 2*MaxHPFor(20, 25))
	}
	// Health and mana run the same curve off different stats.
	if MaxHPFor(33, 17) != MaxMPFor(33, 17) {
		t.Fatalf("the two chains disagree: %d vs %d", MaxHPFor(33, 17), MaxMPFor(33, 17))
	}
	// Monotonic in level.
	prev := 0
	for lvl := 1; lvl <= 110; lvl++ {
		hp := MaxHPFor(StartingStr, lvl)
		if hp <= prev {
			t.Fatalf("level %d MaxHP %d not greater than previous %d", lvl, hp, prev)
		}
		prev = hp
	}
	// Junk input clamps rather than going negative or exploding.
	if MaxHPFor(StartingStr, 0) != StartingMaxHP || MaxHPFor(StartingStr, -5) != StartingMaxHP {
		t.Fatalf("a level below 1 should clamp to level 1")
	}
	if MaxHPFor(-3, 10) != 0 {
		t.Fatalf("a negative stat should clamp to 0, got %d", MaxHPFor(-3, 10))
	}
}

func TestResetHPHealsToLevelMax(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()
	c, _ := store.Create(ctx, 1, "Aria")
	// Level them up and damage them, then reset -- HP should return to the
	// level-appropriate maximum, not the flat base.
	if err := store.SetLeveling(ctx, c.ID, 5, 0, 0, StartingStr, StartingInt); err != nil {
		t.Fatalf("SetLeveling: %v", err)
	}
	if _, _, err := store.ApplyDamage(ctx, c.ID, 50); err != nil {
		t.Fatalf("ApplyDamage: %v", err)
	}
	if err := store.ResetHP(ctx, c.ID); err != nil {
		t.Fatalf("ResetHP: %v", err)
	}
	got, err := store.GetByID(ctx, c.ID)
	if err != nil {
		t.Fatalf("GetByID: %v", err)
	}
	if want := MaxHPFor(c.Str, 5); got.HP != want {
		t.Fatalf("after reset HP = %d, want the level-5 max %d", got.HP, want)
	}
}

// The berserk orbs are a persisted column on the engine's character row
// (_CHAR.RemainHwanCount, charData +0x86), so the store must carry them.
func TestSetHwanCountRoundTrips(t *testing.T) {
	ctx := context.Background()
	s := NewMemStore()
	c, err := s.Create(ctx, 1, "Orbholder")
	if err != nil {
		t.Fatal(err)
	}
	if c.HwanCount != 0 {
		t.Fatalf("a new character starts with %d orbs, want 0", c.HwanCount)
	}
	if err := s.SetHwanCount(ctx, c.ID, 4); err != nil {
		t.Fatal(err)
	}
	got, err := s.GetByID(ctx, c.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.HwanCount != 4 {
		t.Errorf("HwanCount = %d after storing 4, want 4", got.HwanCount)
	}
}

func TestSetHwanCountOnAMissingCharacter(t *testing.T) {
	if err := NewMemStore().SetHwanCount(context.Background(), 999, 1); err != ErrNotFound {
		t.Errorf("SetHwanCount on a missing character returned %v, want ErrNotFound", err)
	}
}
