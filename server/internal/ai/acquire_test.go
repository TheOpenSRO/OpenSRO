package ai

import (
	"math"
	"math/rand"
	"testing"
)

// The scan's cadence: tactics timer 1's period, read off the asm (Init
// 0x53f745..0x53f765 and ArmTimer 0x53d6a9..0x53d6ad). The spread S is
// 10 + |rand| % 491, so 10..500, and the period is 1000 + |rand| % S + 1,
// so 1001..1500 -- the +1 is ArmTimer's `lea edi,[edx+edi*1+0x1]`, and the
// low end is reachable (S's floor is 10 and |rand| % S can be 0). The plan
// first asserted [1011, 1501], which would have pushed the implementation
// onto a wrong offset: a correct one lands under 1011 about 2 % of the time
// and can never reach 1501. Under flags & 0x84 the spread is 10 + |rand| % 41
// and the base 0xc8 (0x53f733..0x53f73a): [201, 250].
func TestScanPeriodRangesAsRead(t *testing.T) {
	rng := rand.New(rand.NewSource(552))
	lo, hi := math.MaxInt, 0
	for i := 0; i < 20000; i++ {
		p := ScanPeriodMs(rng, TacticsFlags)
		if p < 1001 || p > 1500 {
			t.Fatalf("draw %d: period %d ms outside [1001, 1500]", i, p)
		}
		if p < lo {
			lo = p
		}
		if p > hi {
			hi = p
		}
	}
	if lo > 1010 {
		t.Errorf("20000 draws never went under 1011 (min %d): the low end is 1001, not the plan's 1011", lo)
	}
	if hi < 1400 {
		t.Errorf("20000 draws never reached 1400 (max %d)", hi)
	}
	for _, flags := range []uint32{0x4, 0x80, 0x84} {
		for i := 0; i < 5000; i++ {
			if p := ScanPeriodMs(rng, flags); p < 201 || p > 250 {
				t.Fatalf("flags %#x, draw %d: period %d ms outside [201, 250]", flags, i, p)
			}
		}
	}
	// The stand-in flag word is 0, the slow timer: neither fast bit.
	if TacticsFlags&TacticsFlagsFastScan != 0 {
		t.Errorf("TacticsFlags %#x carries a fast-scan bit", TacticsFlags)
	}
}

// The aggression byte (Init 0x53f5be..0x53f5e1): mode 0 and 3 scan, mode 1
// never, and mode 2 scans when rand % 100 is BELOW the percent -- a draw at
// or above it writes 1 into ctx+0x168. So 0 % never scans, 100 % always, and
// 50 % about half the time. The roster's stand-in is mode 0.
func TestAggressiveByMode(t *testing.T) {
	rng := rand.New(rand.NewSource(7))
	for i := 0; i < 100; i++ {
		if !Aggressive(rng, 0, 0) {
			t.Fatal("mode 0 is not aggressive")
		}
		if Aggressive(rng, 1, 100) {
			t.Fatal("mode 1 is aggressive")
		}
		if !Aggressive(rng, 3, 0) {
			t.Fatal("a byte of 3 does not scan")
		}
		if Aggressive(rng, 2, 0) {
			t.Fatal("mode 2 at 0 % is aggressive")
		}
		if !Aggressive(rng, 2, 100) {
			t.Fatal("mode 2 at 100 % is not aggressive")
		}
	}
	yes := 0
	for i := 0; i < 10000; i++ {
		if Aggressive(rng, 2, 50) {
			yes++
		}
	}
	if yes < 4500 || yes > 5500 {
		t.Errorf("mode 2 at 50 %%: %d of 10000 aggressive, want about half", yes)
	}
	if !Aggressive(rng, TacticsAggressionMode, TacticsAggressionPct) {
		t.Error("the roster's stand-in (mode 0) is not aggressive")
	}
}

// The nearest-player rule as the selector compares it (0x5464e0): a
// candidate is taken when at most trunc(radius) away and STRICTLY nearer
// than the pick so far, whose distance is stored truncated.
func TestNearestPicksTheCloserAndTruncatesTheRadius(t *testing.T) {
	// The closer of two, whatever the order.
	a, b := Candidate{ID: 1, X: 60}, Candidate{ID: 2, X: 30}
	for _, order := range [][]Candidate{{a, b}, {b, a}} {
		got, dist, ok := Nearest(order, 0, 0, 106)
		if !ok || got.ID != 2 || dist != 30 {
			t.Fatalf("Nearest(%v) = %+v at %g, %v; want id 2 at 30", order, got, dist, ok)
		}
	}
	// The radius truncates: 106.7 admits a candidate at 106 and refuses one
	// at 106.5, which round(106.7) = 107 would have taken.
	if _, _, ok := Nearest([]Candidate{{ID: 1, X: 106}}, 0, 0, 106.7); !ok {
		t.Error("a candidate at exactly trunc(radius) is refused")
	}
	if got, _, ok := Nearest([]Candidate{{ID: 1, X: 106.5}}, 0, 0, 106.7); ok {
		t.Errorf("a candidate at 106.5 was taken with radius 106.7 (trunc 106): %+v", got)
	}
	if got, _, ok := Nearest([]Candidate{{ID: 1, X: 107}}, 0, 0, 106); ok {
		t.Errorf("a candidate at trunc(radius) + 1 was taken: %+v", got)
	}
	// Nobody in range, nobody picked; the distance is the ground plane's.
	if _, _, ok := Nearest(nil, 0, 0, 106); ok {
		t.Error("an empty scan picked someone")
	}
	if _, dist, ok := Nearest([]Candidate{{ID: 1, X: 30, Z: 40}}, 0, 0, 106); !ok || dist != 50 {
		t.Errorf("distance %g, want 50 (3-4-5)", dist)
	}
	// The stored best is truncated and the compare strict: a pick at 10.7
	// (stored 10) is not displaced by a later candidate at 10.5, since 10.5
	// is not below 10; one at 9.9 displaces it.
	if got, _, _ := Nearest([]Candidate{{ID: 1, X: 10.7}, {ID: 2, X: 10.5}}, 0, 0, 106); got.ID != 1 {
		t.Errorf("a candidate at 10.5 displaced the pick at 10.7 (stored 10): got id %d", got.ID)
	}
	if got, _, _ := Nearest([]Candidate{{ID: 1, X: 10.7}, {ID: 2, X: 9.9}}, 0, 0, 106); got.ID != 2 {
		t.Errorf("a candidate at 9.9 did not displace the pick at 10.7: got id %d", got.ID)
	}
	// A pick under one unit away is stored as 0, which the engine reads as
	// no pick yet: the next candidate in range replaces it.
	if got, _, _ := Nearest([]Candidate{{ID: 1, X: 0.5}, {ID: 2, X: 50}}, 0, 0, 106); got.ID != 2 {
		t.Errorf("a pick stored as 0 was kept over a later candidate: got id %d", got.ID)
	}
}

// The roster's acquisition radius under the stand-in: BCRadius + 100, so
// 104..111, and the Mangyang's is 106.
func TestDetectionRadiusUnderTheStandIn(t *testing.T) {
	for _, c := range []struct {
		bc   int
		want float64
	}{{4, 104}, {6, 106}, {10, 110}, {11, 111}} {
		if r, ok := DetectionRadius(c.bc, TacticsDetectionDistance); !ok || r != c.want {
			t.Errorf("DetectionRadius(%d, %d) = %v,%v; want %v", c.bc, TacticsDetectionDistance, r, ok, c.want)
		}
	}
}
