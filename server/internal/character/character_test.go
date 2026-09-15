package character

import (
	"context"
	"testing"
)

// TestRespawnIsFortyPercent pins the recovered respawn pool. A death used to
// give the character back its FULL maximum; the engine gives 40%.
//
// The distinction from a level-up matters and is tested here too: nothing in
// the level path zeroes the stored pool, so the engine's restore branch never
// fires there and a level-up really does heal to full. Two different calls,
// two different numbers.
func TestRespawnIsFortyPercent(t *testing.T) {
	ctx := context.Background()
	m := NewMemStore()
	c, err := m.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	full := c.MaxHP()
	if full <= 0 {
		t.Fatalf("MaxHP = %d, want a positive pool to test against", full)
	}

	// Kill it, then respawn.
	if _, _, err := m.ApplyDamage(ctx, c.ID, full); err != nil {
		t.Fatalf("ApplyDamage: %v", err)
	}
	if err := m.RespawnHP(ctx, c.ID); err != nil {
		t.Fatalf("RespawnHP: %v", err)
	}
	got, err := m.GetByID(ctx, c.ID)
	if err != nil {
		t.Fatalf("GetByID: %v", err)
	}
	want := int(float64(full) * RespawnFraction)
	if got.HP != want {
		t.Errorf("respawn HP = %d, want %d (%.0f%% of %d)", got.HP, want, RespawnFraction*100, full)
	}
	if got.HP >= full {
		t.Errorf("respawn HP = %d, which is the full pool -- the whole point is that it is not", got.HP)
	}

	// A level-up still heals to full: a different call, deliberately.
	if err := m.ResetHP(ctx, c.ID); err != nil {
		t.Fatalf("ResetHP: %v", err)
	}
	if got, _ := m.GetByID(ctx, c.ID); got.HP != full {
		t.Errorf("ResetHP gave %d, want the full %d -- a level-up heals fully", got.HP, full)
	}
}

// Mana comes back through the same constant, and a zero pool stays zero rather
// than going negative.
func TestRespawnMP(t *testing.T) {
	for _, tc := range []struct{ max, want int }{
		{100, 40}, {1, 0}, {0, 0}, {-5, 0}, {250, 100},
	} {
		if got := RespawnMP(tc.max); got != tc.want {
			t.Errorf("RespawnMP(%d) = %d, want %d", tc.max, got, tc.want)
		}
	}
}
