package combat

import (
	"math"
	"math/rand"
	"testing"
)

// TestRollChanceTrackedMatchesTheEngineRule walks the recovered rule by hand
// against a scripted sequence of rolls, so a change to the accumulator
// arithmetic fails here rather than drifting silently.
//
//	succeed when acc >= rand()%101, acc starting at chance
//	then acc += chance        on failure
//	     acc += chance - 100  on success
func TestRollChanceTrackedMatchesTheEngineRule(t *testing.T) {
	t.Run("a failure raises the accumulator by the base chance", func(t *testing.T) {
		tr := NewChanceTracker()
		// Seed chosen so the first roll exceeds a chance of 20 and fails.
		r := rand.New(rand.NewSource(1))
		got := RollChanceTracked(20, r, tr, 1, ChanceCritical)
		acc, seen := tr.Accumulated(1, ChanceCritical)
		if !seen {
			t.Fatal("no accumulator recorded after a roll")
		}
		want := 40 // 20 (start) + 20 (failure)
		if got {
			want = -60 // 20 + 20 - 100
		}
		if acc != want {
			t.Errorf("after one roll (success=%v) acc = %d, want %d", got, acc, want)
		}
	})

	t.Run("the trivial outcomes touch no accumulator", func(t *testing.T) {
		tr := NewChanceTracker()
		r := rand.New(rand.NewSource(2))
		if RollChanceTracked(0, r, tr, 1, ChanceCritical) {
			t.Error("a zero chance should never succeed")
		}
		if _, seen := tr.Accumulated(1, ChanceCritical); seen {
			t.Error("a zero chance must not create an accumulator -- the engine returns first")
		}
		if !RollChanceTracked(100, r, tr, 1, ChanceCritical) {
			t.Error("a chance of 100 should always succeed")
		}
		if _, seen := tr.Accumulated(1, ChanceCritical); seen {
			t.Error("a chance of 100 must not create an accumulator")
		}
	})

	t.Run("a nil tracker is exactly RollChance", func(t *testing.T) {
		for _, chance := range []int{0, 1, 50, 99, 100, 250} {
			a := RollChanceTracked(chance, nil, nil, 1, ChanceCritical)
			b := RollChance(chance, nil)
			if a != b {
				t.Errorf("chance %d: tracked=%v untracked=%v, want identical", chance, a, b)
			}
		}
	})
}

// TestBadLuckProtectionBreaksStreaks is the behavioural point of the whole
// mechanic: the long-run rate is unchanged, but long dry runs get rarer.
//
// Both halves matter. If only the rate were checked, a broken accumulator that
// did nothing would still pass; if only the streaks were checked, one that
// inflated the chance would pass too.
func TestBadLuckProtectionBreaksStreaks(t *testing.T) {
	const (
		chance = 20
		runs   = 400000
	)

	measure := func(tracked bool) (rate float64, longest int) {
		r := rand.New(rand.NewSource(20260916))
		var tr *ChanceTracker
		if tracked {
			tr = NewChanceTracker()
		}
		hits, streak := 0, 0
		for i := 0; i < runs; i++ {
			var ok bool
			if tracked {
				ok = RollChanceTracked(chance, r, tr, 1, ChanceCritical)
			} else {
				ok = RollChance(chance, r)
			}
			if ok {
				hits++
				streak = 0
				continue
			}
			streak++
			if streak > longest {
				longest = streak
			}
		}
		return float64(hits) / runs, longest
	}

	trackedRate, trackedStreak := measure(true)
	plainRate, plainStreak := measure(false)

	// The long-run rate is preserved. The accumulator spends exactly 100 per
	// success and gains exactly `chance` per roll, so the mean is unchanged.
	if math.Abs(trackedRate-plainRate) > 0.01 {
		t.Errorf("tracked rate %.4f vs memoryless %.4f -- bad-luck protection must not "+
			"change the long-run frequency", trackedRate, plainRate)
	}

	// And the streaks are shorter. With a 20%% chance over 400k rolls a
	// memoryless run reaches well past 40 consecutive misses; the accumulator
	// makes a miss strictly more likely to break the run each time.
	if trackedStreak >= plainStreak {
		t.Errorf("longest dry streak: tracked %d, memoryless %d -- tracked must be shorter",
			trackedStreak, plainStreak)
	}
}

// TestChanceKindsAndActorsDoNotShareStreaks covers the scoping recovered from
// the key construction: the engine keys accumulators by actor AND by kind.
func TestChanceKindsAndActorsDoNotShareStreaks(t *testing.T) {
	tr := NewChanceTracker()
	r := rand.New(rand.NewSource(5))

	for i := 0; i < 20; i++ {
		RollChanceTracked(10, r, tr, 1, ChanceCritical)
	}
	if _, seen := tr.Accumulated(1, ChanceBlock); seen {
		t.Error("critical rolls leaked into the block accumulator")
	}
	if _, seen := tr.Accumulated(2, ChanceCritical); seen {
		t.Error("actor 1's rolls leaked into actor 2's accumulator")
	}

	// Forget drops every kind for one actor and leaves other actors alone.
	RollChanceTracked(10, r, tr, 2, ChanceCritical)
	RollChanceTracked(10, r, tr, 1, ChanceBlock)
	tr.Forget(1)
	if _, seen := tr.Accumulated(1, ChanceCritical); seen {
		t.Error("Forget left actor 1's critical accumulator behind")
	}
	if _, seen := tr.Accumulated(1, ChanceBlock); seen {
		t.Error("Forget left actor 1's block accumulator behind")
	}
	if _, seen := tr.Accumulated(2, ChanceCritical); !seen {
		t.Error("Forget(1) removed actor 2's accumulator")
	}
}

// TestResolveBlowMemoryIsOptional pins that a nil ChanceMemory leaves
// ResolveBlow exactly as it was -- every test asserting an exact blow depends
// on it.
func TestResolveBlowMemoryIsOptional(t *testing.T) {
	// nil r takes the maximum outcome, so a 100% block blocks.
	if got := ResolveBlow(1000, 0, 0, 0, 100, 0, 0, nil, nil); !got.Blocked {
		t.Error("nil memory with a certain block: want blocked")
	}
	// A memory whose tracker is nil behaves the same way.
	mem := &ChanceMemory{AttackerID: 1, DefenderID: 2}
	if got := ResolveBlow(1000, 0, 0, 0, 100, 0, 0, nil, mem); !got.Blocked {
		t.Error("nil tracker inside memory: want blocked")
	}
}
