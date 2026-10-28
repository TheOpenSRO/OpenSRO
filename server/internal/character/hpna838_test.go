package character

import (
	"context"
	"testing"
)

// Round 838: a devil's spirit's 'hpna' (p52 slot 1) scales the Str chain
// before the level growth: Str 20, level 1, +13 % -> 200 x 1.13 = 226; the
// SQL reset agrees with MaxHPWith, and no percent leaves the old rounding.
func TestStrChainPercent(t *testing.T) {
	if got := MaxHPWith(20, 1, Bonus{StrHPPct: 13}); got != 226 {
		t.Errorf("MaxHPWith(20, 1, hpna 13) = %d, want 226", got)
	}
	if got, want := MaxHPWith(37, 40, Bonus{}), MaxHPFor(37, 40); got != want {
		t.Errorf("no percent: %d, want MaxHPFor's %d", got, want)
	}
	if got := MaxMPWith(20, 1, Bonus{IntMPPct: 13, MP: 5}); got != 231 {
		t.Errorf("MaxMPWith(20, 1, mpna 13, +5) = %d, want 231", got)
	}

	s := openTestSQLStore(t)
	ctx := context.Background()
	c, err := s.Create(ctx, 1, "Hpna")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	SetLiveBonusSource(func(id int64) Bonus {
		if id == c.ID {
			return Bonus{StrHPPct: 13}
		}
		return Bonus{}
	})
	t.Cleanup(func() { SetLiveBonusSource(nil) })
	if err := s.ResetHP(ctx, c.ID); err != nil {
		t.Fatalf("ResetHP: %v", err)
	}
	got, _ := s.GetByID(ctx, c.ID)
	if want := got.MaxHP(); got.HP != want || want <= MaxHPFor(got.Str, got.Level) {
		t.Errorf("SQL ResetHP = %d, MaxHP %d (plain %d): want equal and above the plain chain", got.HP, want, MaxHPFor(got.Str, got.Level))
	}
}
