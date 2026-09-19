package combat

import (
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/durability"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
)

// TestWeaponRangeReadsTheInstance pins the weapon branch of
// Char_BuildAggregateStats: the damage pairs interpolate by variance group 4
// (physical) / 5 (magical), the reinforce pairs by groups 1 / 2, each between
// the row's lo and hi columns; a full group gives the hi end, an empty one the
// lo, and the groups do not read each other's bits.
func TestWeaponRangeReadsTheInstance(t *testing.T) {
	w := &refdata.Item{
		PhysAttackMin: 20, PhysAttackMinHi: 26, PhysAttackMax: 30, PhysAttackMaxHi: 36,
		MagAttackMin: 10, MagAttackMinHi: 16, MagAttackMax: 12, MagAttackMaxHi: 18,
		// tenths of a percent: 30.6% .. 40.0% on the min, 34.2% .. 50.0% on the max
		ReinforcePhysMin: 306, ReinforcePhysMinHi: 400, ReinforcePhysMax: 342, ReinforcePhysMaxHi: 500,
	}
	full := func(g int) uint64 { return uint64(31) << (5 * uint(g)) }

	// No instance: the lo ends, exactly as before the hi columns existed.
	if min, max := WeaponRange(w, NoInstance, 0, 0, AttackPhysical); min != 20 || max != 30 {
		t.Errorf("no instance: got %d~%d, want 20~30", min, max)
	}
	// A tracked instance with an empty variance sits at the lo ends too.
	if min, max := WeaponRange(w, Instance{Tracked: true}, 0, 0, AttackPhysical); min != 20 || max != 30 {
		t.Errorf("empty variance: got %d~%d, want 20~30", min, max)
	}
	// Full physical-damage group: the hi ends of BOTH physical pairs (one
	// `mov esi,4` serves the min and the max store), and nothing else moves.
	inst := Instance{Variance: full(durability.WeaponPhysDamageGroup), Tracked: true}
	if min, max := WeaponRange(w, inst, 0, 0, AttackPhysical); min != 26 || max != 36 {
		t.Errorf("full physical group: got %d~%d, want 26~36", min, max)
	}
	if min, max := WeaponRange(w, inst, 0, 0, AttackMagical); min != 10 || max != 12 {
		t.Errorf("physical group must not move the magical pair: got %d~%d, want 10~12", min, max)
	}
	// Full magical-damage group moves only the magical pair.
	inst = Instance{Variance: full(durability.WeaponMagDamageGroup), Tracked: true}
	if min, max := WeaponRange(w, inst, 0, 0, AttackMagical); min != 16 || max != 18 {
		t.Errorf("full magical group: got %d~%d, want 16~18", min, max)
	}
	if min, max := WeaponRange(w, inst, 0, 0, AttackPhysical); min != 20 || max != 30 {
		t.Errorf("magical group must not move the physical pair: got %d~%d, want 20~30", min, max)
	}
	// The physical reinforce pair reads group 1: with 100 Str a full group
	// adds 40% and 50% instead of 30.6% and 34.2%.
	inst = Instance{Variance: full(durability.WeaponPhysReinforceGroup), Tracked: true}
	min, max := WeaponRange(w, inst, 100, 0, AttackPhysical)
	if min != 20+40 || max != 30+50 {
		t.Errorf("full physical reinforce group with 100 Str: got %d~%d, want 60~80", min, max)
	}
	min, max = WeaponRange(w, NoInstance, 100, 0, AttackPhysical)
	if min != 20+ReinforceDamage(100, 306) || max != 30+ReinforceDamage(100, 342) {
		t.Errorf("lo reinforce with 100 Str: got %d~%d", min, max)
	}
	// Group 16 of 31 on the physical damage: 20 + 16/31*6 = 23.1 -> 23,
	// 30 + 16/31*6 = 33.1 -> 33.
	inst = Instance{Variance: uint64(16) << (5 * durability.WeaponPhysDamageGroup), Tracked: true}
	if min, max := WeaponRange(w, inst, 0, 0, AttackPhysical); min != 23 || max != 33 {
		t.Errorf("group 16/31: got %d~%d, want 23~33", min, max)
	}
	// An older export (hi == 0) reads the lo alone, whatever the instance.
	old := &refdata.Item{PhysAttackMin: 20, PhysAttackMax: 30}
	inst = Instance{Variance: full(durability.WeaponPhysDamageGroup), Tracked: true}
	if min, max := WeaponRange(old, inst, 0, 0, AttackPhysical); min != 20 || max != 30 {
		t.Errorf("no hi columns: got %d~%d, want 20~30", min, max)
	}
}
