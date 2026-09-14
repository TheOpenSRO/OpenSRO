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
	perTick := max * RegenPercentPerTick / 100
	if got, want := tr.Current(1, max), 70+3*perTick; got != want {
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
