package combat

import "testing"

// Round 875: a monster's skill blow, pinned to MEASURED damage on a level-110
// defender (accessory absorption 119.8 %, so the blow is divided by 2.198)
// from a level-104 monster's 6969..8038 skill at the bottom of its range (the
// centre-biased roll clamped there: the same number arrived several times).
func TestResolveSkillBlowMeasured(t *testing.T) {
	for _, tc := range []struct {
		name    string
		percent int
		flat    float64
		want    int
	}{
		// Cloth (phy def 2602.9): the 152 % skill landed 862, repeatedly.
		{"cloth 152%", 152, 2602.9, 862},
		// Cloth, the 76 % skill: 431 at the bottom (439 was the lowest seen).
		{"cloth 76%", 76, 2602.9, 431},
		// Heavy (3182.49) under a decay of 2000: the 76 % skill landed 1510.
		{"heavy decayed 76%", 76, 1182.49, 1510},
	} {
		b := ResolveSkillBlow(6969, tc.percent, 119.8, tc.flat, 0, 0, 104, 110, nil, nil)
		if b.Damage != tc.want || b.Critical || b.Blocked {
			t.Errorf("%s: %+v, want %d", tc.name, b, tc.want)
		}
	}
}

// A blow mitigated below 5 % of its base is reshaped to 1 + (base/10 - 1) x
// rand (stage 16): on heavy (3182.49) the 76 % skill never clears it and
// landed 13..689 across 22 hits. A nil rand takes the top of the band.
func TestResolveSkillBlowFloorBand(t *testing.T) {
	b := ResolveSkillBlow(6969, 76, 119.8, 3182.49, 0, 0, 104, 110, nil, nil)
	if b.Damage != 696 {
		t.Errorf("band top %d, want 696 (1 + 695.9)", b.Damage)
	}
}

// The percentage comes BEFORE the critical and the floor band, not after: a
// 50 % blow that clears 5 % of its base only before the percentage must be
// reshaped.
func TestResolveSkillBlowPercentBeforeBand(t *testing.T) {
	// base 1000, nothing absorbed, flat 920 -> 80 (8 %), x 50 % = 40 (4 %):
	// the band, top 1 + 99 = 100.
	if b := ResolveSkillBlow(1000, 50, 0, 920, 0, 0, 0, 0, nil, nil); b.Damage != 100 {
		t.Errorf("got %d, want the band's 100", b.Damage)
	}
	// And a critical doubles after the percentage: 1000 - 400 = 600 x 50 %
	// = 300, x 2 = 600.
	if b := ResolveSkillBlow(1000, 50, 0, 400, 100, 0, 0, 0, nil, nil); b.Damage != 600 || !b.Critical {
		t.Errorf("got %+v, want a 600 critical", b)
	}
}
