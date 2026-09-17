package skill

import "testing"

// TestWithdrawCostShape pins Formulae 0x00410c80: goldMin * 100, scaled by
// 1 + masteryLevel/10, rounded half-up.
func TestWithdrawCostShape(t *testing.T) {
	// No mastery requirement is the bare term: goldMin * 100.
	if got := WithdrawCost(28, 0); got != 2800 {
		t.Errorf("WithdrawCost(28, 0) = %d, want 2800", got)
	}
	// Mastery 10 doubles it -- 1 + 10/10 = 2.
	if got := WithdrawCost(28, 10); got != 5600 {
		t.Errorf("WithdrawCost(28, 10) = %d, want 5600", got)
	}
	// Mastery 100 is 11x, and the divisor is 10 rather than 100: a formula
	// that read the constant as a percentage would give 1.01x here, which is
	// the mistake this case exists to catch.
	if got := WithdrawCost(28, 100); got != 30800 {
		t.Errorf("WithdrawCost(28, 100) = %d, want 30800 (11x, not 1.01x)", got)
	}
	// Each mastery level is a flat tenth of the base, so the series is linear.
	base := WithdrawCost(60, 0)
	for m := 1; m <= 12; m++ {
		want := base + int64(m)*base/10
		if got := WithdrawCost(60, m); got != want {
			t.Errorf("WithdrawCost(60, %d) = %d, want %d", m, got, want)
		}
	}
}

// The engine adds 0.5 and truncates through __ftol2. With integer inputs the
// term is mathematically always an integer -- goldMin*100 + goldMin*10*mastery
// -- so the +0.5 is not a rounding rule at all: it is a float-error guard.
//
// MEASURED over goldMin 1..3000 x mastery 0..200 (600,000 pairs): the +0.5
// changes the answer in 27,435 of them, and in EVERY one of those plain
// truncation lands one BELOW the exact integer. So dropping it would not be a
// rounding-convention quibble, it would be a systematic off-by-one on 4.6% of
// inputs.
func TestWithdrawCostAbsorbsFloatError(t *testing.T) {
	// The smallest measured case where truncation alone is wrong:
	// (13/10 + 1) * 100 is 229.99999999999997 in float64.
	if got := WithdrawCost(1, 13); got != 230 {
		t.Errorf("WithdrawCost(1, 13) = %d, want 230 (truncation alone gives 229)", got)
	}
	if got := WithdrawCost(1, 31); got != 410 {
		t.Errorf("WithdrawCost(1, 31) = %d, want 410", got)
	}
	// The closed form holds everywhere, which is the real invariant: if a
	// refactor reintroduces the float error this fails in thousands of cases
	// rather than needing the exact one above to be remembered.
	for g := int64(1); g <= 400; g++ {
		for m := 0; m <= 60; m++ {
			want := g*100 + g*10*int64(m)
			if got := WithdrawCost(g, m); got != want {
				t.Fatalf("WithdrawCost(%d, %d) = %d, want %d", g, m, got, want)
			}
		}
	}
}

func TestWithdrawCostDegenerateInputs(t *testing.T) {
	if got := WithdrawCost(0, 5); got != 0 {
		t.Errorf("a zero gold minimum should cost nothing, got %d", got)
	}
	if got := WithdrawCost(-1, 5); got != 0 {
		t.Errorf("a negative gold minimum should cost nothing, got %d", got)
	}
	if got := WithdrawCost(28, -3); got != WithdrawCost(28, 0) {
		t.Errorf("a negative mastery level should behave as zero, got %d", got)
	}
}

// A partial withdrawal pays per LINK, each with its own mastery requirement --
// not one term for the whole skill. A sum that used a single mastery level
// would pass the shape test above and fail this one.
func TestWithdrawCostForLevelsSumsPerLink(t *testing.T) {
	links := []int{20, 10, 0}
	want := WithdrawCost(28, 20) + WithdrawCost(28, 10) + WithdrawCost(28, 0)
	if got := WithdrawCostForLevels(28, links); got != want {
		t.Errorf("WithdrawCostForLevels = %d, want %d", got, want)
	}
	// It must not collapse to one term at the highest requirement.
	if got := WithdrawCostForLevels(28, links); got == WithdrawCost(28, 20) {
		t.Error("the sum collapsed to a single link's cost")
	}
	if got := WithdrawCostForLevels(28, nil); got != 0 {
		t.Errorf("refunding no levels costs %d, want 0", got)
	}
}

// The refusal vocabulary is contiguous from the success value, which is how it
// was recognised as one system in the first place.
func TestWithdrawCodesAreContiguousFromSuccess(t *testing.T) {
	codes := []int{
		WithdrawOK, WithdrawFailNotLearn, WithdrawFailInvalidLevel,
		WithdrawFailUnknown, WithdrawFailNotEnoughGold,
		WithdrawFailNotEnoughItem, WithdrawFailDependency,
	}
	for i, c := range codes {
		if c != 0x7800+i {
			t.Errorf("code %d is %#x, want %#x", i, c, 0x7800+i)
		}
	}
}
