package combat

import "testing"

func TestEvadedChance(t *testing.T) {
	for _, c := range []struct {
		name   string
		chance int
		evade  float64
		want   int
	}{
		// The zero every call site passes today: the chance is untouched.
		{"no evasion", 30, 0, 30},
		// The recovered divisor, chance / (1 + evade/100).
		{"evade 100 halves it", 30, 100, 15},
		{"evade 50", 30, 50, 20},
		// Rounded, because the roll takes whole percent (ChanceRollSides).
		{"rounds to nearest", 25, 30, 19}, // 25/1.3 = 19.23
		// A chance of zero stays zero however it is opposed -- every Jangan
		// species has Block 0, so this is the shipped roster's real case.
		{"zero chance", 0, 250, 0},
		{"negative chance is zero", -5, 0, 0},
		// A negative evasion would MULTIPLY the chance; the engine cannot
		// produce one and neither can this.
		{"negative evasion is ignored", 30, -40, 30},
	} {
		if got := EvadedChance(c.chance, c.evade); got != c.want {
			t.Errorf("%s: EvadedChance(%d, %v) = %d, want %d", c.name, c.chance, c.evade, got, c.want)
		}
	}
}

// TestNoPlayerEvasionSourceExists retired in round 769: its tripwire fired
// when the worn items' 'evcr' and 'evbl' options were wired, and its own
// remedy was taken -- the four disclosed call sites now pass the real term
// (session's playerEvadeBlock / playerEvadeCrit). TestEvadedChance above
// still holds the divisor.
