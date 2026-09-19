package durability

import (
	"math/rand"
	"testing"
)

// The white-stat unit is the minimum of three uniforms: mean 1/4, and never
// reaching 1. A 100,000-draw sample pins the mean within a percent.
func TestRollWhiteStatUnitIsMinOfThree(t *testing.T) {
	r := rand.New(rand.NewSource(1))
	const n = 100000
	sum := 0.0
	for i := 0; i < n; i++ {
		u := RollWhiteStatUnit(r)
		if u < 0 || u > 1 {
			t.Fatalf("unit out of range: %v", u)
		}
		sum += u
	}
	mean := sum / n
	if mean < 0.24 || mean > 0.26 {
		t.Errorf("mean of min-of-three uniforms = %.4f, want ~0.25", mean)
	}
}

// Every group is 0..31, packed 5 bits apart, and the distribution is skewed
// low: over many rolls the average group value sits near 31/4.
func TestRollVarianceGroups(t *testing.T) {
	r := rand.New(rand.NewSource(2))
	const n = 20000
	sum := 0
	for i := 0; i < n; i++ {
		v := RollVariance(r)
		if v>>(5*Groups) != 0 {
			t.Fatalf("bits above group %d set: %x", Groups-1, v)
		}
		for k := 0; k < Groups; k++ {
			g := Group(v, k)
			if g < 0 || g > GroupMax {
				t.Fatalf("group %d = %d out of 0..31", k, g)
			}
			sum += g
		}
	}
	avg := float64(sum) / float64(n*Groups)
	if avg < 7.0 || avg > 8.6 {
		t.Errorf("average group value %.2f, want ~7.75 (31/4)", avg)
	}
}

func TestMaxDurability(t *testing.T) {
	// ITEM_CH_SWORD_01_A: Dur_L 62, Dur_U 76 (itemdata columns 63/64).
	cases := []struct {
		group0 int
		want   int
	}{
		{0, 62},  // 62 + 0
		{31, 76}, // 62 + 14
		{15, 69}, // 62 + 14*15/31 = 68.77 -> 69
		{16, 69}, // 62 + 7.226 -> 69
	}
	for _, c := range cases {
		v := uint64(c.group0) // group 0 is the low five bits
		if got := MaxDurability(62, 76, v); got != c.want {
			t.Errorf("group0 %d: max %d, want %d", c.group0, got, c.want)
		}
	}
	if got := MaxDurability(0, 0, 31); got != 0 {
		t.Errorf("an item without a range has max %d, want 0", got)
	}
	if !Tracked(62, 76) || Tracked(0, 0) {
		t.Error("Tracked follows Dur_U > 0")
	}
}

func TestLossChanceAndRoll(t *testing.T) {
	if LossChancePercent(1) != 2 || LossChancePercent(5) != 10 || LossChancePercent(60) != 100 {
		t.Error("chance is min(2*rate, 100)")
	}
	// At rate 1 the roll succeeds 2% of the time: rand()%100+1 <= 2.
	r := rand.New(rand.NewSource(3))
	const n = 200000
	hits := 0
	for i := 0; i < n; i++ {
		if RollLoss(r, 1) {
			hits++
		}
	}
	p := float64(hits) / n
	if p < 0.017 || p > 0.023 {
		t.Errorf("rate 1 loss frequency %.4f, want ~0.02", p)
	}
	if RollLoss(r, 0) {
		t.Error("rate 0 never loses")
	}
}

// The armour walk: slots 0..7 except the weapon, in order, first success.
func TestArmourLossSlotOrder(t *testing.T) {
	// A source that fails the first two rolls and succeeds the third: the
	// third armour slot in order is slot 2.
	seq := &seqRand{vals: []int{99, 99, 0}}
	if got := ArmourLossSlot(seq, 1); got != 2 {
		t.Errorf("first success on the third roll should be slot 2, got %d", got)
	}
	// Never the weapon: with rate 100 (chance 100%) the first slot wins.
	if got := ArmourLossSlot(rand.New(rand.NewSource(1)), 100); got != 0 {
		t.Errorf("certain loss lands on slot 0 first, got %d", got)
	}
	for _, s := range ArmourSlots {
		if s == SlotWeapon {
			t.Error("the armour walk must skip the weapon slot")
		}
	}
	// All failing: -1.
	if got := ArmourLossSlot(&seqRand{vals: []int{99, 99, 99, 99, 99, 99, 99}}, 1); got != -1 {
		t.Errorf("no success should give -1, got %d", got)
	}
}

func TestApply(t *testing.T) {
	// A normal loss.
	if next, broke, mended := Apply(10, 62, -1); next != 9 || broke || mended {
		t.Errorf("10-1: got %d %v %v", next, broke, mended)
	}
	// The last point breaks the item.
	if next, broke, mended := Apply(1, 62, -1); next != 0 || !broke || mended {
		t.Errorf("1-1: got %d %v %v", next, broke, mended)
	}
	// Refused below zero.
	if next, broke, _ := Apply(0, 62, -1); next != 0 || broke {
		t.Errorf("0-1: got %d %v", next, broke)
	}
	// A repair from broken mends it and clamps at max.
	if next, broke, mended := Apply(0, 62, 100); next != 62 || broke || !mended {
		t.Errorf("0+100: got %d %v %v", next, broke, mended)
	}
	// Untracked is left alone.
	if next, _, _ := Apply(Untracked, 62, -1); next != Untracked {
		t.Errorf("untracked changed to %d", next)
	}
	if !IsBroken(0) || IsBroken(1) || IsBroken(Untracked) {
		t.Error("IsBroken is exactly zero")
	}
}

type seqRand struct {
	vals []int
	i    int
}

func (s *seqRand) Intn(n int) int {
	v := s.vals[s.i%len(s.vals)]
	s.i++
	if v >= n {
		v = n - 1
	}
	return v
}

// TestWhiteStat pins the interpolation and the group each defence reads:
// a full group gives the top of the range, an empty one the bottom, and the
// groups are read from their own 5 bits and nobody else's.
func TestWhiteStat(t *testing.T) {
	full := uint64(31) << (5 * ArmourPhysDefenseGroup)
	if got := WhiteStat(10, 20, full, ArmourPhysDefenseGroup); got != 20 {
		t.Errorf("full physical-defence group: got %v, want 20", got)
	}
	if got := WhiteStat(10, 20, 0, ArmourPhysDefenseGroup); got != 10 {
		t.Errorf("empty group: got %v, want 10", got)
	}
	// The magic-defence group is a different 5 bits: a full physical group
	// leaves it at the bottom of its own range.
	if got := WhiteStat(4, 8, full, ArmourMagDefenseGroup); got != 4 {
		t.Errorf("magic defence read the physical group: got %v, want 4", got)
	}
	// Halfway-ish: group value 16 of 31.
	v := uint64(16) << (5 * ArmourMagDefenseGroup)
	want := 4 + 16.0/31*(8-4)
	if got := WhiteStat(4, 8, v, ArmourMagDefenseGroup); got != want {
		t.Errorf("group 16/31: got %v, want %v", got, want)
	}
	if got := WhiteStat(7, 7, full, ArmourPhysDefenseGroup); got != 7 {
		t.Errorf("zero range: got %v, want 7", got)
	}
	if ArmourPhysDefenseGroup == ArmourMagDefenseGroup || ShieldPhysDefenseGroup == ShieldBlockGroup {
		t.Fatal("the groups must be distinct 5-bit fields")
	}
}
