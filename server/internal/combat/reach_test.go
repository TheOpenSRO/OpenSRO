package combat

import "testing"

// TestApproachBand pins the three bands and the hole at exactly 10, with the
// retail numbers: a sword (Range 6) against Mangyang (BCRadius 6) from a
// player body (4); a spear (18); a dagger (3); a bow (180).
func TestApproachBand(t *testing.T) {
	cases := []struct {
		name                string
		caster, target      int
		rng                 float64
		wantStop, wantReach float64
	}{
		{"sword vs mangyang", 4, 6, 6, 4 + 6 + 4, 4 + 6 + 6},      // 4 < 6 < 10: stop = reach - 2
		{"dagger vs mangyang", 4, 6, 3, 4 + 6 + 3, 4 + 6 + 3},     // r <= 4: stop = reach
		{"exactly four", 4, 6, 4, 4 + 6 + 4, 4 + 6 + 4},           // the boundary belongs to the short band
		{"spear vs gyo", 4, 10, 18, 4 + 10 + 0.7*18, 4 + 10 + 18}, // r > 10: 70 %
		{"bow vs yeoha", 4, 11, 180, 4 + 11 + 0.7*180, 4 + 11 + 180},
		{"exactly ten", 4, 6, 10, 4 + 6, 4 + 6}, // the engine's hole: `if (10 < r)` guards both adds (round 488)
		{"unarmed", 4, 6, 0, 10, 10},
	}
	for _, c := range cases {
		stop, reach := ApproachBand(c.caster, c.target, c.rng)
		if stop != c.wantStop || reach != c.wantReach {
			t.Errorf("%s: got stop %v reach %v, want %v / %v", c.name, stop, reach, c.wantStop, c.wantReach)
		}
	}
}

func TestEffectiveRangeAndInReach(t *testing.T) {
	if EffectiveRange(0, 6) != 6 || EffectiveRange(150, 6) != 150 || EffectiveRange(0, 0) != 0 {
		t.Error("EffectiveRange: the skill's range wins when it has one, else the weapon's")
	}
	_, reach := ApproachBand(PlayerBCRadius, 6, 6) // 16
	if !InReach(16, reach) || !InReach(18.9, reach) || InReach(19, reach) {
		t.Errorf("InReach: truncated distance against reach %v plus %d", reach, ReachSlack)
	}
	if !InReach(0, reach) {
		t.Error("point blank is in reach")
	}
}
