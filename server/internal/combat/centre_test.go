package combat

import (
	"math"
	"math/rand"
	"testing"
)

func TestMonsterRate(t *testing.T) {
	// characterdata cols 75 and 77 both hold 2*level + 25 on every monster row.
	for _, c := range []struct {
		level int
		want  float64
	}{{1, 27}, {3, 31}, {10, 45}, {27, 79}} {
		if got := MonsterRate(c.level); got != c.want {
			t.Errorf("MonsterRate(%d) = %v, want %v", c.level, got, c.want)
		}
	}
}

func TestCharacterRate(t *testing.T) {
	// Bare: the innate 10 plus the level edge, both at slot 0, which sums.
	if got := CharacterRate(1, 0); got != 11 {
		t.Errorf("CharacterRate(1, 0) = %v, want 11", got)
	}
	// Equipment adds into the same slot.
	if got := CharacterRate(10, 24); got != 44 {
		t.Errorf("CharacterRate(10, 24) = %v, want 44", got)
	}
}

func TestDamageCentrePercent(t *testing.T) {
	// Equal rates, equal levels: the ratio is 1, scaled by 0.5 -> 50 %.
	if got := DamageCentrePercent(30, 30, 5, 5); got != 50 {
		t.Errorf("equal rates: got %v, want 50", got)
	}
	// The level term adds 3 % a level, capped at 30 %, and only upward.
	if got := DamageCentrePercent(30, 30, 7, 5); math.Abs(got-56) > 1e-9 {
		t.Errorf("two levels up: got %v, want 56", got)
	}
	if got := DamageCentrePercent(30, 30, 3, 5); got != 50 {
		t.Errorf("out-levelled must not subtract: got %v, want 50", got)
	}
	if got := DamageCentrePercent(30, 30, 99, 5); got != 80 {
		t.Errorf("level term must cap at +30: got %v, want 80", got)
	}
	// Both clamps. These are the engine's own 10 and 90, not a simplification:
	// a blow's centre never sits in the bottom or top tenth of the range.
	if got := DamageCentrePercent(1, 1000, 1, 1); got != CentreFloorPercent {
		t.Errorf("floor: got %v, want %v", got, CentreFloorPercent)
	}
	if got := DamageCentrePercent(1000, 1, 1, 1); got != CentreCeilingPercent {
		t.Errorf("ceiling: got %v, want %v", got, CentreCeilingPercent)
	}
	// A defender with no parry cannot divide by zero.
	if got := DamageCentrePercent(30, 0, 1, 1); got != CentreCeilingPercent {
		t.Errorf("zero era: got %v, want %v", got, CentreCeilingPercent)
	}
}

// The scenarios this actually produces, written down so the balance
// consequences are VISIBLE rather than discovered in play. Every number is the
// recovered formula applied to grounded inputs: a character is 10 + Level +
// equipment, a monster is 2*Level + 25.
//
// The two extremes are the point. A bare level-1 character against a level-1
// monster sits at 20 % -- blows near the BOTTOM of the weapon's range -- and the
// same fight with a weapon's attack rate sits near the middle. That is why the
// port waited for itemdata cols 113 and 68 to be carried: shipping it on the
// innate rate alone would have looked like a damage nerf rather than the
// distribution fix it is.
func TestDamageCentreScenarios(t *testing.T) {
	cases := []struct {
		name               string
		hra, era           float64
		atkLevel, defLevel int
		wantCentre         float64
	}{
		{"bare level 1 vs level 1 monster", CharacterRate(1, 0), MonsterRate(1), 1, 1, 100.0 * 11 / 27 * 0.5},
		{"level 1 with a Copper Sword (24)", CharacterRate(1, 24), MonsterRate(1), 1, 1, 100.0 * 35 / 27 * 0.5},
		{"level 10 armed vs level 10", CharacterRate(10, 24), MonsterRate(10), 10, 10, 100.0 * 44 / 45 * 0.5},
		{"monster level 1 vs bare player", MonsterRate(1), CharacterRate(1, 0), 1, 1, CentreCeilingPercent},
		{"monster level 1 vs armoured player", MonsterRate(1), CharacterRate(1, 20), 1, 1, 100.0 * 27 / 31 * 0.5},
	}
	for _, c := range cases {
		got := DamageCentrePercent(c.hra, c.era, c.atkLevel, c.defLevel)
		if math.Abs(got-c.wantCentre) > 1e-9 {
			t.Errorf("%s: centre = %.2f %%, want %.2f %%", c.name, got, c.wantCentre)
		}
	}
	// The one that would have bitten: an UNARMOURED player is hit at the
	// ceiling, because a level-1 monster's 27 against an innate 11 exceeds the
	// clamp. Pinned so nobody reads the clamp as unreachable.
	if got := DamageCentrePercent(MonsterRate(1), CharacterRate(1, 0), 1, 1); got != CentreCeilingPercent {
		t.Errorf("unarmoured player: centre = %v, want the ceiling %v", got, CentreCeilingPercent)
	}
}

func TestRollCentredBounds(t *testing.T) {
	r := rand.New(rand.NewSource(7))
	for i := 0; i < 5000; i++ {
		got := RollCentred(100, 200, 50, r)
		if got < 100 || got > 200 {
			t.Fatalf("RollCentred left the range: %d", got)
		}
	}
	// A nil generator takes zero excursion: the centre itself.
	if got := RollCentred(100, 200, 50, nil); got != 150 {
		t.Errorf("nil r: got %d, want the centre 150", got)
	}
	if got := RollCentred(100, 200, 10, nil); got != 110 {
		t.Errorf("nil r at the floor: got %d, want 110", got)
	}
	// A degenerate range is still in range.
	if got := RollCentred(50, 50, 90, r); got != 50 {
		t.Errorf("zero-width range: got %d, want 50", got)
	}
}

// The distribution is NOT uniform, and this pins it against its own CLOSED FORM
// rather than against an impression.
//
// The excursion is min(u1, u2, u3), whose CDF is 1 - (1-x)^3, so the share of
// blows landing within +-10 %% of the centre is 1 - 0.9^3 = 27.1 %%. A uniform
// roll over the same 101 integers would give 21/101 = 20.8 %%.
//
// THE BIAS IS THEREFORE MODEST, and this comment exists because the first
// version of this test asserted ">30 %%, and comfortably" -- a guess about the
// distribution's strength that the measurement refuted at 28.2 %%. Porting this
// roll changes the SHAPE of damage, not its scale: most of the difference from
// a uniform roll is a mild concentration, not a dramatic one.
func TestRollCentredMatchesItsClosedForm(t *testing.T) {
	r := rand.New(rand.NewSource(11))
	const n = 200000
	near := 0
	for i := 0; i < n; i++ {
		got := RollCentred(0, 100, 50, r)
		if got >= 40 && got <= 60 {
			near++
		}
	}
	frac := float64(near) / n
	const want = 1 - 0.9*0.9*0.9 // 0.271, the excursion CDF at 10 %
	if math.Abs(frac-want) > 0.02 {
		t.Errorf("middle-fifth share = %.3f, want ~%.3f (1 - 0.9^3); the excursion "+
			"is not min-of-three", frac, want)
	}
	// And it must still beat a uniform roll's 20.8 %%, or the port bought nothing.
	if frac <= 0.208 {
		t.Errorf("middle-fifth share = %.3f, no better than uniform 0.208", frac)
	}
}
