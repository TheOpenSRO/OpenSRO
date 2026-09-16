package combat

import (
	"math"
	"testing"
)

// The denominators simplify from the engine's constants. This recomputes them
// the long way -- exactly as the disassembly does them -- and checks the
// simplification, so a mis-simplified constant fails here rather than silently
// changing every number.
func TestDenominatorsMatchTheEnginesArithmetic(t *testing.T) {
	for level := 1; level <= 140; level++ {
		l := float64(level)
		engineStr := ((l - 1) * 7) + 56
		engineStr *= 6.0 / 7.0
		if want := float64(strRatioDenomFactor) * (l + statRatioLevelOffset); math.Abs(engineStr-want) > 1e-9 {
			t.Fatalf("level %d: Str denominator %v, simplified %v", level, engineStr, want)
		}
		engineInt := ((l - 1) * 5) + 40
		engineInt *= 0.8
		if want := float64(intRatioDenomFactor) * (l + statRatioLevelOffset); math.Abs(engineInt-want) > 1e-9 {
			t.Fatalf("level %d: Int denominator %v, simplified %v", level, engineInt, want)
		}
	}
}

// The Str numerator carries a level term and the Int one does not. Writing
// them symmetrically is the obvious "tidy-up" and it would be wrong, so this
// pins the asymmetry.
func TestTheTwoRatiosAreNotSymmetric(t *testing.T) {
	const stat, level = 100, 50
	// Same stat, same level: if the numerators were the same shape, the ratio
	// would differ only by the 6 vs 4 denominator factor.
	s := StrLevelDamageRatio(stat, level)
	i := IntLevelDamageRatio(stat, level)
	symmetric := (float64(stat) + 2*level + strRatioNumeratorBias) /
		(float64(intRatioDenomFactor) * (level + statRatioLevelOffset))
	if math.Abs(i-symmetric) < 1e-9 {
		t.Error("the Int ratio must NOT carry the Str numerator's level term")
	}
	if want := float64(stat) / (intRatioDenomFactor * (level + statRatioLevelOffset)); math.Abs(i-want) > 1e-9 {
		t.Errorf("IntLevelDamageRatio(%d, %d) = %v, want %v", stat, level, i, want)
	}
	if want := (float64(stat) + 2*level + strRatioNumeratorBias) /
		(strRatioDenomFactor * (level + statRatioLevelOffset)); math.Abs(s-want) > 1e-9 {
		t.Errorf("StrLevelDamageRatio(%d, %d) = %v, want %v", stat, level, s, want)
	}
}

// Both clamp at 1.2 on the way up and 0 on the way down.
func TestRatiosClamp(t *testing.T) {
	if got := StrLevelDamageRatio(100000, 1); got != StatRatioClamp {
		t.Errorf("a huge Str gave %v, want the %v clamp", got, StatRatioClamp)
	}
	if got := IntLevelDamageRatio(100000, 1); got != StatRatioClamp {
		t.Errorf("a huge Int gave %v, want the %v clamp", got, StatRatioClamp)
	}
	if got := IntLevelDamageRatio(-500, 10); got != 0 {
		t.Errorf("a negative Int gave %v, want 0", got)
	}
	if got := StrLevelDamageRatio(-500, 10); got != 0 {
		t.Errorf("a very negative Str gave %v, want 0", got)
	}
}

// A level-1 character's numbers, computed by hand from the recovered constants:
// Str 20 -> (20 + 2 + 14) / (6*8) = 36/48 = 0.75; Int 20 -> 20 / (4*8) = 0.625.
func TestLevelOneWorkedExamples(t *testing.T) {
	if got, want := StrLevelDamageRatio(20, 1), 0.75; math.Abs(got-want) > 1e-9 {
		t.Errorf("StrLevelDamageRatio(20, 1) = %v, want %v", got, want)
	}
	if got, want := IntLevelDamageRatio(20, 1), 0.625; math.Abs(got-want) > 1e-9 {
		t.Errorf("IntLevelDamageRatio(20, 1) = %v, want %v", got, want)
	}
}

// A stat that keeps pace with level holds the ratio roughly steady rather than
// running away -- which is what makes it a "how much did you invest" measure
// rather than a raw stat term. Not a claim about balance, just that the shape
// is bounded and monotone in the stat.
func TestRatioRisesWithStatAndIsBoundedAcrossLevels(t *testing.T) {
	for _, level := range []int{1, 20, 60, 110, 140} {
		prev := -1.0
		for _, stat := range []int{10, 50, 100, 200, 400} {
			r := StrLevelDamageRatio(stat, level)
			if r < prev {
				t.Errorf("level %d: ratio fell from %v to %v as Str rose", level, prev, r)
			}
			if r < 0 || r > StatRatioClamp {
				t.Errorf("level %d stat %d: ratio %v out of [0, %v]", level, stat, r, StatRatioClamp)
			}
			prev = r
		}
	}
}

// A non-player never reaches the stat read at all -- the IsPC gate returns 1.0
// first. The constant is here so a caller wiring this in uses the engine's
// value rather than 0.
func TestNonPCConstantIsOne(t *testing.T) {
	if StatRatioNonPC != 1.0 {
		t.Errorf("StatRatioNonPC = %v, want 1.0 (the `fld1` behind the IsPC gate)", StatRatioNonPC)
	}
}
