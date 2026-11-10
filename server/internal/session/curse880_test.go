package session

import (
	"context"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/statuseffect"
)

// Round 880: a decay or a weakness never takes more than 70 % of the defence
// there is (statuseffect.CurseCutOf, READ s:0x4a51df), and a monster's blow
// takes the defence off unrounded (defenderArmorExact). The numbers are
// MEASURED blows of a level-104 monster's skills (base 6969..8038, 76 % a hit
// and 152 %) on a level-110 character behind an accessory absorption of
// 119.8 %; the item ids are synthetic (set875, accessories875).

func curse880(t *testing.T, id int64, code string, slot, cut int) {
	t.Helper()
	h := &statuseffect.Holder{}
	h.Put(statuseffect.Record{Code: code, Slot: slot, Bit: slot, DurationMs: 30000, CurseCut: cut})
	statusFX.mu.Lock()
	statusFX.pcs[id] = h
	statusFX.mu.Unlock()
	t.Cleanup(func() {
		statusFX.mu.Lock()
		delete(statusFX.pcs, id)
		statusFX.mu.Unlock()
	})
}

func TestCurseKeepsThirtyPercentOfTheDefence(t *testing.T) {
	for _, tc := range []struct{ value, current, want int }{
		{2000, 2602, 1821}, // MEASURED: the cloth wearer's decay (ftol(2602 - 780.6))
		{2000, 3182, 2000}, // MEASURED: the heavy wearer's, whole (the cap is 2227)
		{3020, 3984, 2788}, // a weakness of 3020 on a magic defence of 3984
		{9000, 3182, 2227},
		{2000, 0, 0},
		{0, 3182, 0},
	} {
		if got := statuseffect.CurseCutOf(tc.value, tc.current); got != tc.want {
			t.Errorf("CurseCutOf(%d, %d) = %d, want %d", tc.value, tc.current, got, tc.want)
		}
	}
}

func TestDecayedBlowsMatchTheMeasuredOnes(t *testing.T) {
	ctx := context.Background()
	for _, tc := range []struct {
		name          string
		cloth         bool
		id            int64
		percent       int
		before, after int
	}{
		// MEASURED on the cloth wearer (phy def 2602.86): the 152 % skill's
		// lowest blow 862 before a decay; the 76 % skill's lowest 1815 a hit
		// under it (the defence left is 2602.86 - 1821 = 781.86). A 0 is a
		// blow that was not measured at the bottom of its range.
		{"cloth 152 %", true, 880001, 152, 862, 0},
		{"cloth 76 %", true, 880002, 76, 0, 1815},
		// MEASURED on the heavy wearer (phy def 3182.49): the 76 % skill's
		// lowest blow 1510 a hit and the 152 % skill's 3021 under the decay
		// (the whole 2000 comes off: 1182.49 left). Before it both are under
		// 5 % of their base and land in the floor band.
		{"heavy 76 %", false, 880003, 76, 0, 1510},
		{"heavy 152 %", false, 880004, 152, 0, 3021},
	} {
		items, worn := set875(tc.cloth)
		worn = append(worn, accessories875(items)...)
		eq := fixedEquipment{worn: worn}
		pct := playerMitigationPercent(ctx, tc.id, eq, items, false)
		def, err := defenderArmorExact(ctx, tc.id, 533, eq, items)
		if err != nil {
			t.Fatal(err)
		}
		if tc.before > 0 {
			if b := combat.ResolveSkillBlow(6969, tc.percent, pct, def, 0, 0, 104, 110, nil, nil); b.Damage != tc.before {
				t.Errorf("%s: the lowest blow %d, want the measured %d (defence %.2f)", tc.name, b.Damage, tc.before, def)
			}
		}
		curse880(t, tc.id, "cspd", statuseffect.SlotDecay, 2000)
		def, _ = defenderArmorExact(ctx, tc.id, 533, eq, items)
		if b := combat.ResolveSkillBlow(6969, tc.percent, pct, def, 0, 0, 104, 110, nil, nil); tc.after > 0 && b.Damage != tc.after {
			t.Errorf("%s: the lowest decayed blow %d, want the measured %d (defence left %.2f)", tc.name, b.Damage, tc.after, def)
		}
	}
}

// A weakness is the same rule on the magic defence, and leaves the physical
// defence alone.
func TestWeaknessKeepsThirtyPercentOfTheMagicDefence(t *testing.T) {
	ctx := context.Background()
	items, worn := set875(true)
	eq := fixedEquipment{worn: worn}
	const id = 880010
	curse880(t, id, "csmd", statuseffect.SlotWeakness, 3020)
	mag, _ := defenderMagicArmor(ctx, id, 206, eq, items)
	// 3984 - min(3020, ftol(3984 x 0.7) = 2788) = 1196.
	if mag != 1196 {
		t.Errorf("weakened magic defence %d, want 1196", mag)
	}
	if phy, _ := defenderArmor(ctx, id, 533, eq, items); phy != 2602 {
		t.Errorf("a weakness touched the physical defence: %d", phy)
	}
}
