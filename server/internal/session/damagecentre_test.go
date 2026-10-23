package session

import (
	"context"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
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

// The monster's half of the port (round 379): its counterattack takes the same
// centre-biased roll with the sides swapped. Deterministic here, because this
// package's TestMain nils the damage generator -- the uniform fallback returns
// the maximum and the centre roll returns the centre exactly.
func TestMonsterBlowTakesTheCentre(t *testing.T) {
	// A level-1 monster striking for 100..200. Its attack rate is 2*1+25 = 27.
	m := combat.Monster{Level: 1, AttackMin: 100, AttackMax: 200, Attack: 7}

	// An UNARMOURED-in-data player: no parry, so the uniform fallback, which
	// under the nil generator is the maximum. This is the guard that keeps
	// deployments whose item table predates itemdata col 68 exactly as they
	// were.
	if got := monsterBlow(m, 1, 0); got != 200 {
		t.Errorf("no parry data: blow = %d, want the uniform fallback's 200", got)
	}

	// A well-armoured player: parry 60 gives era = 10 + 1 + 60 = 71, so the
	// centre is 27/71 * 0.5 = 19.0 %, and the blow is 100 + 0.190*100 = 119.
	if got := monsterBlow(m, 1, 60); got != 119 {
		t.Errorf("armoured: blow = %d, want 119 (centre 19.0 %%)", got)
	}

	// A barely-armoured player: parry 2 gives era = 13, centre = 27/13*0.5 =
	// 103.8 %, which clamps to the ceiling 90 % -> 190. The clamp is REACHABLE
	// on the monster's side in a way it never is on the player's, because a
	// monster out-rates a lightly armoured character badly.
	if got := monsterBlow(m, 1, 2); got != 190 {
		t.Errorf("barely armoured: blow = %d, want 190 (centre clamped to 90 %%)", got)
	}

	// A monster with no damage range at all keeps the flat disclosed Attack,
	// unchanged by any of this.
	flat := combat.Monster{Level: 1, Attack: 7}
	if got := monsterBlow(flat, 1, 60); got != 7 {
		t.Errorf("no range: blow = %d, want the flat 7", got)
	}
}

// defenderParryRate sums the worn BODY ARMOUR's parry, and that division is the
// data's own: across all 21,560 retail rows no shield carries a parry and no
// armour carries a block ratio (round 377). A shield with a parry value is not
// a real row; it is here to pin that the walk excludes the slot rather than
// relying on retail data to be zero there.
func TestDefenderParryRate(t *testing.T) {
	ctx := context.Background()
	items := refdata.NewMemStore()
	mk := func(id int64, parry float64) refdata.Item {
		return refdata.Item{ID: id, MaxStack: 1, DurabilityMin: 10, DurabilityMax: 10,
			ParryRatioMin: parry,
			TypeID1:       equipment.TypeItem, TypeID2: equipment.TypeEquipment,
			Country: equipment.CountryChina}
	}
	if err := items.ImportItems(ctx, []refdata.Item{mk(300, 4), mk(301, 6), mk(302, 99)}); err != nil {
		t.Fatalf("import: %v", err)
	}
	inv := inventory.NewMemStore(items)
	inv.SetDurabilityLookup(items)
	eq := equipment.NewMemStore(inv)

	// No armour at all: zero, which the caller reads as "no data" and falls
	// back to the uniform roll.
	if got, err := defenderParryRate(ctx, 1, eq, items); err != nil || got != 0 {
		t.Fatalf("bare: got %v (err %v), want 0", got, err)
	}

	for i, id := range []int64{300, 301, 302} {
		if err := inv.AddItem(ctx, 1, id, 1); err != nil {
			t.Fatalf("add %d: %v", id, err)
		}
		_ = i
	}
	if err := eq.Equip(ctx, 1, equipment.SlotHelm, 0); err != nil {
		t.Fatalf("equip helm: %v", err)
	}
	if err := eq.Equip(ctx, 1, equipment.SlotMail, 1); err != nil {
		t.Fatalf("equip mail: %v", err)
	}
	// Two armour pieces sum.
	if got, err := defenderParryRate(ctx, 1, eq, items); err != nil || got != 10 {
		t.Errorf("helm+mail: got %v (err %v), want 10", got, err)
	}
	// The shield is excluded even carrying 99.
	if err := eq.Equip(ctx, 1, equipment.SlotShield, 2); err != nil {
		t.Fatalf("equip shield: %v", err)
	}
	if got, err := defenderParryRate(ctx, 1, eq, items); err != nil || got != 10 {
		t.Errorf("with a shield: got %v (err %v), want 10 -- shields block, they do not parry", got, err)
	}
	// A broken piece parries for nothing, the same rule the defence walk uses.
	if err := eq.SetDurability(ctx, 1, equipment.SlotMail, 0); err != nil {
		t.Fatalf("break mail: %v", err)
	}
	if got, err := defenderParryRate(ctx, 1, eq, items); err != nil || got != 4 {
		t.Errorf("broken mail: got %v (err %v), want 4 -- only the helm", got, err)
	}
}
