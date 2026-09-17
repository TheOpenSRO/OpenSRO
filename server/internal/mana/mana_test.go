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

// The engine floors the amount at 1, which is why its unbuffed rate is not zero
// even though 'hprg'/'mprg' default to 0.
//
// CORRECTED 2026-09-17. This test used to assert `RegenPerTick(1, 1000) == 1`
// and `RegenPerTick(0, 1000) == 1`, and its comment said the floor applied
// "before anything else". The floor is real and still applies; what was missing
// is that the engine then caps the amount at half the CURRENT pool
// (RegenHalfCapDivisor), so at cur 0 and cur 1 the cap is 0 and takes the floor
// straight back off. Those two rows were asserting a consequence of a partial
// reading of CGObjPC::vslot_362, not a behaviour anyone had observed.
//
// The floor is still observable -- it is what makes a pool of 2..24 regenerate
// at all, since 4% of those rounds to zero -- so it is pinned there instead.
func TestRegenPerTickFloorsAtOne(t *testing.T) {
	// 4% of any of these is zero; only the floor makes them non-zero.
	for _, cur := range []int{2, 3, 10, 24} {
		if got := RegenPerTick(cur, 1000); got != 1 {
			t.Errorf("RegenPerTick(%d, 1000) = %d, want 1 (the engine's floor)", cur, got)
		}
	}
	// And the cap takes it back off where the pool cannot afford it.
	for _, cur := range []int{0, 1} {
		if got := RegenPerTick(cur, 1000); got != 0 {
			t.Errorf("RegenPerTick(%d, 1000) = %d, want 0 — the half-of-current "+
				"cap overrides the floor here", cur, got)
		}
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

// TestRegenHalfCap pins the cap recovered 2026-09-17 from CGObjPC::vslot_362:
// one tick restores at most half the CURRENT pool, applied after the floor at 1.
//
// docs/SYSTEMS.md carried this as the regen row's one open item ("the curHP*0.5
// bound at 0x004e2c00 is read but its comparison is not") until the comparison
// at 0x004e2b4c was read: `cmp ebp,edi ; jl ; mov ebp,edi`, i.e. a min.
func TestRegenHalfCap(t *testing.T) {
	// The cap binds only at the bottom, where the floor of 1 would otherwise
	// hand out more than the pool can support. These three rows are the whole
	// behavioural difference the cap makes.
	for _, tc := range []struct{ cur, max, want int }{
		{0, 100, 0}, // was 1 before the cap
		{1, 100, 0}, // was 1 before the cap -- a pool at 1 does not regenerate
		{2, 100, 1}, // cap is 1, floor is 1
		{3, 100, 1}, // cap is 1 (truncated), floor is 1
		{4, 100, 1}, // 4% of 4 is 0 -> floor 1; cap is 2, so 1 survives
	} {
		if got := RegenPerTick(tc.cur, tc.max); got != tc.want {
			t.Errorf("RegenPerTick(%d, %d) = %d, want %d", tc.cur, tc.max, got, tc.want)
		}
	}

	// Above the bottom the cap is inert: 4% of the pool is far below 50% of it,
	// so removing the cap must not change anything here. A cap applied to the
	// MAXIMUM instead of the current pool would also pass the rows above and
	// fail these, which is the misreading worth guarding.
	for _, cur := range []int{25, 50, 100, 1000, 9999} {
		want := cur * RegenPercentPerTick / 100
		if want < 1 {
			want = 1
		}
		if got := RegenPerTick(cur, cur*10); got != want {
			t.Errorf("RegenPerTick(%d, …) = %d, want %d — the cap must be inert here",
				cur, got, want)
		}
	}
}

// The cap is on the CURRENT pool, not the maximum, and it is a truncating
// integer halving because the engine converts through __ftol2. Both are easy to
// "tidy" into something that passes the common cases and diverges at the edge.
func TestRegenHalfCapIsOfCurrentAndTruncates(t *testing.T) {
	// If the cap were half the MAXIMUM, a nearly-empty pool in a huge bar would
	// regenerate 1; with the real cap it regenerates 0.
	if got := RegenPerTick(1, 100000); got != 0 {
		t.Errorf("RegenPerTick(1, 100000) = %d, want 0 — the cap is half the "+
			"CURRENT pool, not half the maximum", got)
	}
	// An odd pool truncates down: 3/2 is 1, not 2 and not 1.5 rounded up.
	if got := RegenPerTick(3, 100); got != 1 {
		t.Errorf("RegenPerTick(3, 100) = %d, want 1 — __ftol2 truncates", got)
	}
	// The deficit clamp still wins when it is the tighter of the two.
	if got := RegenPerTick(98, 99); got != 1 {
		t.Errorf("RegenPerTick(98, 99) = %d, want 1 (the deficit)", got)
	}
	// And a full pool still regenerates nothing at all.
	if got := RegenPerTick(100, 100); got != 0 {
		t.Errorf("a full pool regenerated %d", got)
	}
}
