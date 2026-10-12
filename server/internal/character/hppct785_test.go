package character

import (
	"context"
	"testing"
)

// Round 785's review, finding 11: the SQL store's ResetHP and RespawnHP left
// out the buffs' HP percent ('hpi', Bonus.HPPct) that MaxHPWith and the
// memory store apply. With +50 % the SQL reset gave the unbuffed maximum.
func TestSQLResetAndRespawnHPApplyTheHPPercent(t *testing.T) {
	s := openTestSQLStore(t)
	ctx := context.Background()
	c, err := s.Create(ctx, 1, "Hpi")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	SetLiveBonusSource(func(id int64) Bonus {
		if id == c.ID {
			return Bonus{HPPct: 50}
		}
		return Bonus{}
	})
	t.Cleanup(func() { SetLiveBonusSource(nil) })

	mem := NewMemStore()
	mc, err := mem.Create(ctx, 1, "Hpi")
	if err != nil {
		t.Fatalf("mem Create: %v", err)
	}
	// The memory character takes the same bonus under its own id.
	SetLiveBonusSource(func(id int64) Bonus {
		if id == c.ID || id == mc.ID {
			return Bonus{HPPct: 50}
		}
		return Bonus{}
	})

	if err := s.ResetHP(ctx, c.ID); err != nil {
		t.Fatalf("ResetHP: %v", err)
	}
	got, _ := s.GetByID(ctx, c.ID)
	if want := got.MaxHP(); got.HP != want {
		t.Errorf("SQL ResetHP = %d, want MaxHP %d (with +50%%)", got.HP, want)
	}
	if err := mem.ResetHP(ctx, mc.ID); err != nil {
		t.Fatalf("mem ResetHP: %v", err)
	}
	if m, _ := mem.GetByID(ctx, mc.ID); m.HP != got.HP {
		t.Errorf("memory ResetHP = %d, SQL %d: the stores disagree", m.HP, got.HP)
	}

	if err := s.RespawnHP(ctx, c.ID); err != nil {
		t.Fatalf("RespawnHP: %v", err)
	}
	got, _ = s.GetByID(ctx, c.ID)
	if err := mem.RespawnHP(ctx, mc.ID); err != nil {
		t.Fatalf("mem RespawnHP: %v", err)
	}
	m, _ := mem.GetByID(ctx, mc.ID)
	if got.HP != m.HP {
		t.Errorf("SQL RespawnHP = %d, memory %d: the stores disagree", got.HP, m.HP)
	}
	if want := int(float64(got.MaxHP()) * RespawnFraction); got.HP != want {
		t.Errorf("SQL RespawnHP = %d, want %d", got.HP, want)
	}
}
