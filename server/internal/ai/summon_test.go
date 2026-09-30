package ai

import "testing"

// Round 661: the unique selectors' summon choice, READ (summon.go).

func TestHPBucketEdges(t *testing.T) {
	for _, c := range []struct{ cur, max, want int }{
		{100, 100, 4}, {80, 100, 4}, {79, 100, 3}, {60, 100, 3}, {59, 100, 2}, {40, 100, 2},
		{39, 100, 1}, {20, 100, 1}, {19, 100, 0}, {0, 100, 0}, {5, 0, 4},
	} {
		if got := HPBucket(c.cur, c.max); got != c.want {
			t.Errorf("HP %d/%d -> bucket %d, want %d", c.cur, c.max, got, c.want)
		}
	}
}

// The gate: 10 % of MaxHP taken since the last summon, inclusive.
func TestSummonDueAtATenthOfMaxHP(t *testing.T) {
	if SummonDue(29935, 299360) {
		t.Fatal("9.9997 % taken summoned")
	}
	if !SummonDue(29936, 299360) {
		t.Fatal("10 % taken did not summon")
	}
	if !SummonDue(1, 0) || SummonDue(0, 0) {
		t.Fatal("a MaxHP under 2 counts as 1")
	}
}

// Summon_A: above 80 % the first slot, then one slot per 20 %, below 40 % the
// fourth. Summon_B: above 80 % list entry 3 whatever the die; below, the die
// picks the first set (rand % 1000 < 500) or the second (+4).
func TestSummonIndexes(t *testing.T) {
	for b, want := range []int{3, 3, 2, 1, 0} {
		if got := SummonAIndex(b); got != want {
			t.Errorf("A: bucket %d -> %d, want %d", b, got, want)
		}
	}
	for _, c := range []struct{ bucket, r, want int }{
		{4, 0, 3}, {4, 999, 3}, {3, 499, 0}, {3, 500, 4}, {2, 1499, 1}, {2, 1500, 5}, {1, 0, 2}, {0, 700, 6},
	} {
		if got := SummonBIndex(c.bucket, c.r); got != c.want {
			t.Errorf("B: bucket %d die %d -> %d, want %d", c.bucket, c.r, got, c.want)
		}
	}
}
