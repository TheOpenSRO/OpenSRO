package ai

import "testing"

// The stand-ins the tests below chase with: OpenSRO's own roam radius
// (session.MonsterRoamRadius, 200, own design) and the four disclosed
// _RefTactics columns. The numbers here are pinned so that a change to a
// disclosed value is a deliberate edit of both the constant and its record.
const testRoamRadius = 200.0

func TestBattleStandInsAreTheDisclosedValues(t *testing.T) {
	if TacticsChaseSwitch != 1 {
		t.Errorf("TacticsChaseSwitch = %d; the disclosed stand-in for column 35 is 1", TacticsChaseSwitch)
	}
	if TacticsGiveUpDistance != 400 {
		t.Errorf("TacticsGiveUpDistance = %v; the disclosed stand-in for column 36 is 400", TacticsGiveUpDistance)
	}
	if TacticsReachRule != 0 {
		t.Errorf("TacticsReachRule = %d; the disclosed stand-in for column 40 is 0", TacticsReachRule)
	}
	if TacticsRetargetRule != RetargetKeepFirst {
		t.Errorf("TacticsRetargetRule = %d; the disclosed stand-in for column 9 is RetargetKeepFirst", TacticsRetargetRule)
	}
	if GiveUpCheckPeriodMs != 1500 {
		t.Errorf("GiveUpCheckPeriodMs = %d; Init arms timer 6 with 0x5dc (0x53f6ec)", GiveUpCheckPeriodMs)
	}
}

// The nest path's reduction (0x545eef..0x545f2d): nothing inside 1.5 x the
// radius, including exactly on it (excess 0 is not > 0), and one unit of
// threshold per unit beyond -- through zero and below, as the engine.
func TestChaseRangeReducesOnlyBeyondOneAndAHalfRadii(t *testing.T) {
	cases := []struct {
		distFromHome float64
		want         float64
	}{
		{0, 400},   // on the spawn
		{299, 400}, // inside 1.5R
		{300, 400}, // exactly 1.5R: excess 0, not reduced
		{600, 100}, // 300 beyond 1.5R
		{700, 0},   // the threshold reaches zero
		{900, -200},
	}
	for _, c := range cases {
		if got := ChaseRange(TacticsGiveUpDistance, testRoamRadius, c.distFromHome); got != c.want {
			t.Errorf("ChaseRange(400, 200, %v) = %v; want %v", c.distFromHome, got, c.want)
		}
	}
}

// +0x79 of 0 or 2, or a zero +0x7c, is within at any distance on either path
// (0x545e5c, 0x545e6f, 0x545e7f); 1 with a distance is the control that the
// early answers are the switch's doing.
func TestTargetWithinChaseRangeSwitchZeroOrTwoOrNoDistanceIsAlwaysWithin(t *testing.T) {
	const far = 1e6
	for _, nest := range []bool{false, true} {
		for _, sw := range []uint8{0, 2} {
			if !TargetWithinChaseRange(far, sw, TacticsGiveUpDistance, nest, testRoamRadius, far) {
				t.Errorf("switch %d, nest %v: a target %v away must be within (0x545e5c/0x545e6f answer 1 at once)", sw, nest, far)
			}
		}
		if !TargetWithinChaseRange(far, 1, 0, nest, testRoamRadius, far) {
			t.Errorf("nest %v: a zero give-up distance must be within at any distance (0x545e7f)", nest)
		}
		if TargetWithinChaseRange(far, 1, TacticsGiveUpDistance, nest, testRoamRadius, 0) {
			t.Errorf("nest %v: switch 1 with a give-up distance must NOT be within at %v", nest, far)
		}
	}
}

// No nest: dist < +0x7c, strict (fcompp at 0x545e97, `test ah,0x5; jnp`).
func TestTargetWithinChaseRangeNoNestIsStrict(t *testing.T) {
	cases := []struct {
		dist float64
		want bool
	}{
		{0, true},
		{399.99, true},
		{400, false}, // equal: C3 alone, even parity, falls to xor al,al
		{400.01, false},
	}
	for _, c := range cases {
		if got := TargetWithinChaseRange(c.dist, TacticsChaseSwitch, TacticsGiveUpDistance, false, testRoamRadius, 0); got != c.want {
			t.Errorf("no nest, dist %v: within = %v; want %v", c.dist, got, c.want)
		}
	}
}

// A nest: dist <= ChaseRange, inclusive (fcompp at 0x545f38, `test ah,0x1;
// jne`), against the reduced threshold once the monster is beyond 1.5R.
func TestTargetWithinChaseRangeNestIsInclusiveAgainstTheReducedRange(t *testing.T) {
	cases := []struct {
		distFromHome, dist float64
		want               bool
	}{
		{0, 400, true}, // equal, inside 1.5R: within
		{0, 400.01, false},
		{300, 400, true}, // exactly on 1.5R: still the raw 400
		{600, 99, true},  // 300 beyond: the threshold is 100
		{600, 100, true}, // equal to the reduced threshold: within
		{600, 100.01, false},
		{600, 400, false}, // the raw distance no longer applies
		{900, 0, false},   // a negative threshold: even a target on the monster is out
	}
	for _, c := range cases {
		if got := TargetWithinChaseRange(c.dist, TacticsChaseSwitch, TacticsGiveUpDistance, true, testRoamRadius, c.distFromHome); got != c.want {
			t.Errorf("nest, %v from home, dist %v: within = %v; want %v", c.distFromHome, c.dist, got, c.want)
		}
	}
}

// The give-up code compares the RAW +0x7c (fild at 0x54842a), >= (C0 or C3
// alone at 0x548431), and only under switch 1.
func TestGiveUpCodeOnTheRawGiveUpDistance(t *testing.T) {
	cases := []struct {
		dist   float64
		sw     uint8
		want   uint8
		reason string
	}{
		{399.99, 1, 0, "nearer than +0x7c: no code from this rule"},
		{400, 1, 1, "equal: C3 alone is odd parity, falls to mov byte [edi],1"},
		{1000, 1, 1, "beyond: C0 alone, the same"},
		{1000, 0, 0, "switch 0 returns 0 before the timer (0x5483de)"},
		{1000, 2, 0, "switch 2 returns 0 before the timer (0x5483e2)"},
	}
	for _, c := range cases {
		if got := GiveUpCode(c.dist, c.sw, TacticsGiveUpDistance); got != c.want {
			t.Errorf("GiveUpCode(%v, switch %d, 400) = %d; want %d -- %s", c.dist, c.sw, got, c.want, c.reason)
		}
	}
}

// The reach test runs first (0x55a175 before 0x55a1a2), so a code of 1 can
// only be sent where the target is still within chase range. Sweep both
// paths: with no nest that never happens; with a nest it happens at exactly
// dist == +0x7c while the monster is inside 1.5R, and nowhere else. This is
// the "all but unreachable" the record makes, measured rather than asserted.
func TestGiveUpCodeIsReachableOnlyAtTheOneEquality(t *testing.T) {
	const step = 0.25 // exact in binary, so dist == 400 is hit exactly
	for dist := 0.0; dist <= 800; dist += step {
		if TargetWithinChaseRange(dist, TacticsChaseSwitch, TacticsGiveUpDistance, false, testRoamRadius, 0) &&
			GiveUpCode(dist, TacticsChaseSwitch, TacticsGiveUpDistance) == 1 {
			t.Errorf("no nest, dist %v: within AND code 1 -- the strict reach test and the >= give-up must never both hold", dist)
		}
	}
	var reached []float64
	for _, home := range []float64{0, 150, 300, 450, 600} {
		for dist := 0.0; dist <= 800; dist += step {
			within := TargetWithinChaseRange(dist, TacticsChaseSwitch, TacticsGiveUpDistance, true, testRoamRadius, home)
			if within && GiveUpCode(dist, TacticsChaseSwitch, TacticsGiveUpDistance) == 1 {
				if dist != TacticsGiveUpDistance || home > 1.5*testRoamRadius {
					t.Errorf("nest, %v from home, dist %v: within AND code 1 away from the one equality", home, dist)
				}
				reached = append(reached, home)
			}
		}
	}
	// 0, 150 and 300 from home leave the threshold at 400, so the equality
	// exists there and nowhere beyond.
	if len(reached) != 3 || reached[0] != 0 || reached[1] != 150 || reached[2] != 300 {
		t.Errorf("code 1 reached with the target within at homes %v; want exactly [0 150 300] (dist == 400, inside 1.5R)", reached)
	}
}
