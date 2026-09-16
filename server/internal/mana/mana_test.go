package mana

import (
	"testing"
	"time"
)

func TestSpendAndRegen(t *testing.T) {
	tr := NewTracker()
	const max = 120

	// A character not seen before starts full.
	if got := tr.Current(1, max); got != max {
		t.Fatalf("a fresh character should start full: got %d, want %d", got, max)
	}
	// A cost that is affordable is taken.
	rem, ok := tr.Spend(1, max, 50)
	if !ok || rem != 70 {
		t.Fatalf("spending 50 of 120: got remaining=%d ok=%v", rem, ok)
	}
	// A cost that is not affordable takes nothing and reports it.
	rem, ok = tr.Spend(1, max, 100)
	if ok {
		t.Fatalf("spending 100 with 70 left should fail, got ok=true")
	}
	if rem != 70 {
		t.Fatalf("a refused spend must not take mana: got %d, want 70", rem)
	}
	// A free skill always succeeds and takes nothing.
	if rem, ok = tr.Spend(1, max, 0); !ok || rem != 70 {
		t.Fatalf("a zero cost: got remaining=%d ok=%v", rem, ok)
	}

	// Regeneration is settled lazily: backdate the clock and read.
	tr.mu.Lock()
	tr.lastGen[1] = time.Now().Add(-3 * RegenInterval)
	tr.mu.Unlock()
	// The engine's rate is a percentage of the CURRENT pool, so the three
	// ticks compound rather than multiplying out -- computed the same way the
	// tracker does rather than restating a number, so this test tracks the
	// model instead of pinning an arithmetic result.
	want := 70
	for i := 0; i < 3; i++ {
		want += RegenPerTick(want, max)
	}
	if got := tr.Current(1, max); got != want {
		t.Fatalf("after 3 regen ticks: got %d, want %d", got, want)
	}

	// Regeneration never overfills.
	tr.mu.Lock()
	tr.lastGen[1] = time.Now().Add(-1000 * RegenInterval)
	tr.mu.Unlock()
	if got := tr.Current(1, max); got != max {
		t.Fatalf("regen should cap at max: got %d, want %d", got, max)
	}

	// A shrunken pool clamps rather than reporting more than the maximum.
	if got := tr.Current(1, 50); got != 50 {
		t.Fatalf("a smaller max should clamp: got %d, want 50", got)
	}

	// Refill and Clear.
	tr.Spend(1, max, 60)
	tr.Refill(1, max)
	if got := tr.Current(1, max); got != max {
		t.Fatalf("after Refill: got %d, want %d", got, max)
	}
	tr.Clear(1)
	if got := tr.Current(1, max); got != max {
		t.Fatalf("a cleared character starts full again: got %d", got)
	}
}

// The engine takes its percentage of the CURRENT pool, not the maximum. This
// is the difference that matters: a drained caster gets less than a nearly-full
// one, where the old percent-of-max gave them the same.
func TestRegenPerTickScalesWithCurrentNotMax(t *testing.T) {
	const max = 1000
	low := RegenPerTick(100, max)
	high := RegenPerTick(900, max)
	if low >= high {
		t.Errorf("regen at 100/%d = %d should be less than at 900/%d = %d", max, low, max, high)
	}
	if want := 100 * RegenPercentPerTick / 100; low != want {
		t.Errorf("RegenPerTick(100, %d) = %d, want %d", max, low, want)
	}
}

// The engine floors the amount at 1 before anything else, which is why its
// unbuffed rate is not zero even though 'hprg'/'mprg' default to 0.
func TestRegenPerTickFloorsAtOne(t *testing.T) {
	// A pool so small that the percentage rounds to nothing.
	if got := RegenPerTick(1, 1000); got != 1 {
		t.Errorf("RegenPerTick(1, 1000) = %d, want 1 (the engine's floor)", got)
	}
	if got := RegenPerTick(0, 1000); got != 1 {
		t.Errorf("RegenPerTick(0, 1000) = %d, want 1", got)
	}
}

// A full pool regenerates nothing, and the last tick cannot overshoot.
func TestRegenPerTickStopsAtFull(t *testing.T) {
	if got := RegenPerTick(1000, 1000); got != 0 {
		t.Errorf("RegenPerTick(full) = %d, want 0", got)
	}
	if got := RegenPerTick(1001, 1000); got != 0 {
		t.Errorf("RegenPerTick(over-full) = %d, want 0", got)
	}
	if got := RegenPerTick(999, 1000); got != 1 {
		t.Errorf("RegenPerTick(999, 1000) = %d, want 1 (capped at the deficit)", got)
	}
	if got := RegenPerTick(5, 0); got != 0 {
		t.Errorf("RegenPerTick with max 0 = %d, want 0", got)
	}
}

// Ticks compound, so N ticks is strictly more than N times the first tick once
// the pool has grown. Multiplying out -- which this package used to do -- would
// under-count.
func TestRegenTicksCompound(t *testing.T) {
	cur, max := 100, 10000
	first := RegenPerTick(cur, max)
	total := 0
	for i := 0; i < 10; i++ {
		g := RegenPerTick(cur, max)
		cur += g
		total += g
	}
	if total <= 10*first {
		t.Errorf("ten compounding ticks gained %d, should exceed 10x the first tick (%d)", total, 10*first)
	}
}

// The interval is the engine's own, read off the timer registration.
func TestRegenIntervalIsTheEnginesFour(t *testing.T) {
	if RegenInterval != 4*time.Second {
		t.Errorf("RegenInterval = %v, want 4s (.rdata 0x00b45dc0 = 4.0)", RegenInterval)
	}
}
