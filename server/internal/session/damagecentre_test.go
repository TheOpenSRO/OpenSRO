package session

import (
	"context"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
)

// The centre-biased roll is LIVE on the player's attack, and it moves the blow
// in the direction the attack-rate-versus-parry ratio says.
//
// This exists because the path is guarded twice -- the defender must have a
// parry rate and the weapon a real attack rate -- and a guard that is always
// false is indistinguishable from a feature that was never wired. Round 378
// wired it; this is what proves it.
func armedAttacker(t *testing.T, hitRate float64) (context.Context, equipment.Store, combat.ItemLookup) {
	t.Helper()
	ctx := context.Background()
	items := refdata.NewMemStore()
	// A wide damage range, so WHERE in it the blow lands is visible. No
	// reinforce and no Strength below, so the range is the weapon's own.
	if err := items.ImportItems(ctx, []refdata.Item{
		{ID: 100, MaxStack: 1, DurabilityMin: 62, DurabilityMax: 76,
			PhysAttackMin: 100, PhysAttackMax: 200, HitRateMin: hitRate,
			TypeID1: equipment.TypeItem, TypeID2: equipment.TypeEquipment, Country: equipment.CountryChina},
	}); err != nil {
		t.Fatalf("import: %v", err)
	}
	inv := inventory.NewMemStore(items)
	inv.SetDurabilityLookup(items)
	eq := equipment.NewMemStore(inv)
	if err := inv.AddItem(ctx, 1, 100, 1); err != nil {
		t.Fatalf("add: %v", err)
	}
	if err := eq.Equip(ctx, 1, equipment.SlotWeapon, 0); err != nil {
		t.Fatalf("equip: %v", err)
	}
	return ctx, eq, items
}

// blow rolls one attack. This package's TestMain nils the damage generator, so
// every roll here is DETERMINISTIC: the uniform fallback returns the maximum
// (RollDamage's documented nil convention) and the centre roll returns the
// centre exactly, with zero excursion. Exact assertions, no statistics.
func blow(t *testing.T, hitRate, defenderParry float64) int {
	t.Helper()
	ctx, eq, items := armedAttacker(t, hitRate)
	d, err := attackerDamageOf(ctx, 1, 0, 0, eq, items, combat.AttackPhysical, 1, 1, defenderParry)
	if err != nil {
		t.Fatalf("attackerDamageOf: %v", err)
	}
	return d
}

func TestDamageCentreIsLiveOnTheAttackPath(t *testing.T) {
	// A huge attack rate against a tiny parry clamps the centre to 90 %, so the
	// blow is 100 + 0.9*(200-100) = 190. A tiny rate against a huge parry
	// clamps to 10 %: 110. If the centre were not wired both would be the
	// fallback's 200.
	if got := blow(t, 1000, 10); got != 190 {
		t.Errorf("ceiling case: blow = %d, want 190 (centre clamped to 90 %%)", got)
	}
	if got := blow(t, 1, 10000); got != 110 {
		t.Errorf("floor case: blow = %d, want 110 (centre clamped to 10 %%)", got)
	}
	// And a realistic middle: a Copper Sword's attack rate 24 on a level-1
	// character is 10 + 1 + 24 = 35, against a level-1 monster's 2*1+25 = 27.
	// centre = 35/27 * 0.5 = 64.8 %, so 100 + 0.648*100 = 165.
	if got := blow(t, 24, combat.MonsterRate(1)); got != 165 {
		t.Errorf("Copper Sword vs a level-1 monster: blow = %d, want 165", got)
	}
}

// Both guards must fall back to the UNIFORM roll rather than to a floored blow:
// a missing defender parry, and an item table imported before itemdata col 113
// (HitRateMin == 0). Under this package's nil generator that fallback is the
// maximum, which is what every other test here has always asserted.
func TestDamageCentreFallsBackToUniform(t *testing.T) {
	for _, c := range []struct {
		name                   string
		hitRate, defenderParry float64
	}{
		{"no defender parry", 24, 0},
		{"item table predates col 113", 0, 27},
	} {
		if got := blow(t, c.hitRate, c.defenderParry); got != 200 {
			t.Errorf("%s: blow = %d, want the uniform fallback's 200", c.name, got)
		}
	}
}
