package session

import (
	"context"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/mana"
)

// The rule was recovered and never run. These pin the arithmetic the tick
// applies, so "hp recovery exists" cannot quietly stop being true again.
func TestRegenPerTickShape(t *testing.T) {
	// A percentage of the CURRENT pool, not the maximum -- the part srrevamp
	// had wrong before internal/mana was corrected.
	if got := mana.RegenPerTick(1000, 2000); got != 40 {
		t.Errorf("RegenPerTick(1000, 2000) = %d, want 40 (4%% of CURRENT)", got)
	}
	// Full pool: the engine's own first test returns immediately.
	if got := mana.RegenPerTick(500, 500); got != 0 {
		t.Errorf("RegenPerTick at full = %d, want 0", got)
	}
	// The floor at 1 for a small pool...
	if got := mana.RegenPerTick(10, 500); got != 1 {
		t.Errorf("RegenPerTick(10, 500) = %d, want the floor 1", got)
	}
	// ...but the half-of-current cap beats the floor at the very bottom, which
	// is why a character on 1 point does not regenerate at all.
	if got := mana.RegenPerTick(1, 500); got != 0 {
		t.Errorf("RegenPerTick(1, 500) = %d, want 0 -- the cap truncates the floor", got)
	}
	// And the dead stay dead: 0 current gives a cap of 0.
	if got := mana.RegenPerTick(0, 500); got != 0 {
		t.Errorf("RegenPerTick(0, 500) = %d, want 0 -- regen must not revive", got)
	}
}

// A tick with nobody online must not panic or touch anything.
func TestRegenTickWithNoPlayers(t *testing.T) {
	regenTick(context.Background(), nil, nil, RegenDeps{}, nil)
}

// The healed amount must reach the store, or the bar moves and the row does
// not.
func TestRegenHealsThroughTheStore(t *testing.T) {
	ctx := context.Background()
	store := character.NewMemStore()
	c, err := store.Create(ctx, 1, "Woundedsoul")
	if err != nil {
		t.Fatal(err)
	}
	maxHP := character.MaxHPFor(c.Str, c.Level)
	if maxHP <= 2 {
		t.Fatalf("max HP is %d; the fixture cannot be damaged meaningfully", maxHP)
	}
	// Drop to half so there is a deficit to heal.
	if _, _, err := store.ApplyDamage(ctx, c.ID, maxHP/2); err != nil {
		t.Fatal(err)
	}
	before, err := store.GetByID(ctx, c.ID)
	if err != nil {
		t.Fatal(err)
	}
	want := mana.RegenPerTick(before.HP, maxHP)
	if want <= 0 {
		t.Fatalf("no regen expected at %d/%d; the fixture proves nothing", before.HP, maxHP)
	}
	if _, err := store.Heal(ctx, c.ID, want, maxHP); err != nil {
		t.Fatal(err)
	}
	after, err := store.GetByID(ctx, c.ID)
	if err != nil {
		t.Fatal(err)
	}
	if after.HP != before.HP+want {
		t.Errorf("HP went %d -> %d, want +%d", before.HP, after.HP, want)
	}
}
