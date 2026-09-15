package refdata

import (
	"math"
	"math/rand"
	"testing"
)

// TestDropRollScale pins the recovered denominator. It is a literal in the
// binary (`mov ecx,0xf4240`) and the same figure scales both ratios, so a
// change here means the recovery was misread.
func TestDropRollScale(t *testing.T) {
	if DropRollScale != 1000000 {
		t.Fatalf("DropRollScale = %d, want the recovered 1000000 (0xf4240)", DropRollScale)
	}
}

// TestRollAssignedDropIsPerAttempt is the point of the whole file: the engine
// rolls DropRatio once PER ATTEMPT, so the distribution is binomial over the
// attempt count -- not "one roll, then a quantity".
//
// The two models differ sharply, which is what makes this testable: with 3
// attempts at ratio 0.5 the engine's mean yield is 1.5 and zero comes up about
// an eighth of the time, whereas a roll-then-quantity model would yield 0 half
// the time and 1..3 otherwise.
func TestRollAssignedDropIsPerAttempt(t *testing.T) {
	rnd := rand.New(rand.NewSource(20260915))
	d := MonsterDrop{DropAmountMin: 3, DropAmountMax: 3, DropRatio: 0.5}

	const runs = 200000
	var total, zeros int
	for i := 0; i < runs; i++ {
		got := d.RollAssignedDrop(rnd)
		if got < 0 || got > 3 {
			t.Fatalf("RollAssignedDrop returned %d, outside 0..3", got)
		}
		total += got
		if got == 0 {
			zeros++
		}
	}

	// Binomial(3, 0.5): mean 1.5.
	mean := float64(total) / runs
	if math.Abs(mean-1.5) > 0.02 {
		t.Errorf("mean yield = %.3f, want ~1.5 (binomial 3 x 0.5)", mean)
	}
	// P(zero) = 0.5^3 = 0.125. A roll-then-quantity model would give 0.5,
	// so this is the assertion that separates the two mechanics.
	zeroRate := float64(zeros) / runs
	if math.Abs(zeroRate-0.125) > 0.01 {
		t.Errorf("zero-yield rate = %.3f, want ~0.125; ~0.5 would mean the roll "+
			"is happening once instead of per attempt", zeroRate)
	}
}

// TestRollAssignedDropEdges covers the shapes real rows take and the degenerate
// ones a hand-made CSV can produce.
func TestRollAssignedDropEdges(t *testing.T) {
	rnd := rand.New(rand.NewSource(1))

	// A certain drop of exactly one.
	if got := (MonsterDrop{DropAmountMin: 1, DropAmountMax: 1, DropRatio: 1.0}).RollAssignedDrop(rnd); got != 1 {
		t.Errorf("certain single drop: got %d, want 1", got)
	}
	// Ratio at or above 1 always fires, for every attempt.
	if got := (MonsterDrop{DropAmountMin: 4, DropAmountMax: 4, DropRatio: 1.0}).RollAssignedDrop(rnd); got != 4 {
		t.Errorf("certain 4 attempts: got %d, want 4", got)
	}
	// A zero attempt count yields nothing regardless of ratio.
	if got := (MonsterDrop{DropAmountMin: 0, DropAmountMax: 0, DropRatio: 1.0}).RollAssignedDrop(rnd); got != 0 {
		t.Errorf("zero attempts: got %d, want 0", got)
	}
	// A negative ratio never fires.
	if got := (MonsterDrop{DropAmountMin: 5, DropAmountMax: 5, DropRatio: -1}).RollAssignedDrop(rnd); got != 0 {
		t.Errorf("negative ratio: got %d, want 0", got)
	}
	// Reversed bounds are tolerated rather than panicking on Intn(negative).
	if got := (MonsterDrop{DropAmountMin: 3, DropAmountMax: 1, DropRatio: 1.0}).RollAssignedDrop(rnd); got < 1 || got > 3 {
		t.Errorf("reversed bounds: got %d, want 1..3", got)
	}
	// A nil source must not panic.
	if got := (MonsterDrop{DropAmountMin: 1, DropAmountMax: 1, DropRatio: 1.0}).RollAssignedDrop(nil); got != 1 {
		t.Errorf("nil rand source: got %d, want 1", got)
	}
}

// TestSelectFromGroupIsCumulative checks the weighted pick: entries are chosen
// in proportion to SelectRatio, and a group whose ratios do not reach 1 really
// can select nothing.
func TestSelectFromGroupIsCumulative(t *testing.T) {
	rnd := rand.New(rand.NewSource(7))
	entries := []*DropGroupEntry{
		{GroupID: 1, ItemID: 10, SelectRatio: 0.7},
		{GroupID: 1, ItemID: 20, SelectRatio: 0.2},
		{GroupID: 1, ItemID: 30, SelectRatio: 0.1},
	}

	const runs = 200000
	counts := map[int64]int{}
	for i := 0; i < runs; i++ {
		if e := SelectFromGroup(entries, rnd); e != nil {
			counts[e.ItemID]++
		}
	}
	for _, tc := range []struct {
		item int64
		want float64
	}{{10, 0.7}, {20, 0.2}, {30, 0.1}} {
		got := float64(counts[tc.item]) / runs
		if math.Abs(got-tc.want) > 0.01 {
			t.Errorf("item %d selected %.3f of the time, want ~%.2f", tc.item, got, tc.want)
		}
	}

	// A group that does not sum to 1 leaves a real gap: nothing is selected
	// roughly half the time here, which is the engine's behaviour and not an
	// error condition.
	sparse := []*DropGroupEntry{{GroupID: 2, ItemID: 99, SelectRatio: 0.5}}
	var nils int
	for i := 0; i < runs; i++ {
		if SelectFromGroup(sparse, rnd) == nil {
			nils++
		}
	}
	if rate := float64(nils) / runs; math.Abs(rate-0.5) > 0.01 {
		t.Errorf("sparse group selected nothing %.3f of the time, want ~0.5", rate)
	}

	// Degenerate inputs.
	if SelectFromGroup(nil, rnd) != nil {
		t.Error("empty group should select nothing")
	}
	if SelectFromGroup([]*DropGroupEntry{nil, {SelectRatio: 0}}, rnd) != nil {
		t.Error("a group of nil and zero-weight entries should select nothing")
	}
	// A nil source must not panic.
	if SelectFromGroup(entries, nil) == nil {
		t.Error("nil rand source with a full-weight group should still select")
	}
}
