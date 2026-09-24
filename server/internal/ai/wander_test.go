package ai

import (
	"math"
	"math/rand"
	"testing"
)

// seqSource is a rand.Source that hands out a fixed list of C rand() values in
// order: crand draws rng.Intn(32768), which for a power of two is
// Int31() & 0x7fff, and Int31 is Int63 >> 32.
type seqSource struct {
	vals []int
	i    int
}

func (s *seqSource) Int63() int64 {
	v := s.vals[s.i%len(s.vals)]
	s.i++
	return int64(v) << 32
}

func (s *seqSource) Seed(int64) {}

func seqRand(vals ...int) (*rand.Rand, *seqSource) {
	src := &seqSource{vals: vals}
	return rand.New(src), src
}

// The stub source draws what it is given, so the exact tests below are about
// the rules and not about Go's generator.
func TestSeqSourceDrawsTheGivenCRandValues(t *testing.T) {
	rng, _ := seqRand(0, 1, 0x7fff, 12345)
	for _, want := range []int{0, 1, 0x7fff, 12345} {
		if got := crand(rng); got != want {
			t.Fatalf("crand drew %d; want %d", got, want)
		}
	}
	rng, _ = seqRand(7, 8)
	if crandSign(rng) != 1 || crandSign(rng) != -1 {
		t.Error("an odd draw is +1 and an even one -1 (rand() & 0x80000001, PickWanderLeg 0x5458d4)")
	}
}

// PickWanderLeg's draw, pinned value by value: s1 odd (+1), rand % 40 = 39 ->
// 124 units; m = 90 % 91 + 45 = 135; s2 even (-1) -> t = -135 degrees. From
// heading 0 the leg bisects 0 and -135: -67.5 degrees. Four draws, in that
// order.
func TestPickWanderLegDrawOrder(t *testing.T) {
	rng, src := seqRand(1, 39, 90, 2)
	dx, dz, h, ok := PickWanderLeg(rng, 10, 20, 0, 22)
	if !ok {
		t.Fatal("a monster running at 22 u/s must get a leg")
	}
	if src.i != 4 {
		t.Errorf("PickWanderLeg drew %d rand() values; the engine draws 4", src.i)
	}
	want := -67.5 * math.Pi / 180
	if math.Abs(dx-(10+124*math.Cos(want))) > 1e-9 || math.Abs(dz-(20+124*math.Sin(want))) > 1e-9 {
		t.Errorf("leg to (%v, %v); want 124 units at -67.5 degrees from (10, 20)", dx, dz)
	}
	if math.Abs(h-want) > 1e-9 {
		t.Errorf("the leg's heading %v; want %v (the move's start faces the destination)", h, want)
	}

	// The shortest leg: s1 even (-1), rand % 40 = 39 -> 46; t = +45 degrees.
	rng, _ = seqRand(0, 39, 0, 1)
	dx, dz, _, _ = PickWanderLeg(rng, 0, 0, math.Pi/2, 22)
	if l := math.Hypot(dx, dz); math.Abs(l-46) > 1e-9 {
		t.Errorf("the shortest leg is %v units; want 46", l)
	}
	if a := math.Atan2(dz, dx) * 180 / math.Pi; math.Abs(a-(90+22.5)) > 1e-9 {
		t.Errorf("heading 90, t +45: leg at %v degrees; want 112.5", a)
	}
}

// Legs are 46..124 units (WanderDistanceRange) and turn 22.5..67.5 degrees
// either side of the heading -- the bisector of the heading and heading + t
// (round 535, WanderLegDirection), NOT round 251's full t of 45..135.
func TestPickWanderLegLengthsAndTurns(t *testing.T) {
	lo, hi := WanderDistanceRange()
	rng := rand.New(rand.NewSource(536))
	var left, right int
	for i := 0; i < 4000; i++ {
		heading := float64(i%360) * math.Pi / 180
		x, z := float64(i%17)*10, -float64(i%13)*10
		dx, dz, h, ok := PickWanderLeg(rng, x, z, heading, 55)
		if !ok {
			t.Fatal("a moving monster was refused a leg")
		}
		l := math.Hypot(dx-x, dz-z)
		if l < lo-1e-9 || l > hi+1e-9 {
			t.Fatalf("a leg of %v units; want %v..%v", l, lo, hi)
		}
		leg := math.Atan2(dz-z, dx-x)
		if math.Abs(angleBetween(h, leg)) > 1e-9 {
			t.Fatalf("returned heading %v is not the leg's direction %v", h, leg)
		}
		turn := angleBetween(leg, heading) * 180 / math.Pi
		if math.Abs(turn) < 22.5-1e-9 || math.Abs(turn) > 67.5+1e-9 {
			t.Fatalf("heading %v deg: the leg turned %v deg; want 22.5..67.5 either side", heading*180/math.Pi, turn)
		}
		if turn > 0 {
			left++
		} else {
			right++
		}
	}
	if left == 0 || right == 0 {
		t.Errorf("turns must go both ways: %d left, %d right", left, right)
	}
}

// PickWanderLeg refuses a monster whose run speed is not above 1e-6 (0xb45c84).
func TestPickWanderLegNeedsARunSpeed(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	for _, run := range []float64{0, -5, 1e-6} {
		if x, z, h, ok := PickWanderLeg(rng, 3, 4, 1, run); ok || x != 3 || z != 4 || h != 1 {
			t.Errorf("run speed %v: (%v, %v, %v, %v); want a refusal that leaves the monster as it is", run, x, z, h, ok)
		}
	}
}

// The IDLE roll (0x559cf0): r = rand % 100 + 1, IDLE when r < 25 (0x19 at
// 0x559d01), so WANDER for exactly 76 of r = 1..100.
func TestIdleNextWandersFor76Of100(t *testing.T) {
	vals := make([]int, 100)
	for i := range vals {
		vals[i] = i // r = i + 1
	}
	rng, _ := seqRand(vals...)
	wander := 0
	for r := 1; r <= 100; r++ {
		next := IdleNext(rng)
		switch next {
		case StateWander:
			wander++
		case StateIdle:
		default:
			t.Fatalf("r = %d gave %v; the roll only picks IDLE or WANDER", r, next)
		}
		if r == 24 && next != StateIdle {
			t.Error("r = 24 < 25 stays IDLE")
		}
		if r == 25 && next != StateWander {
			t.Error("r = 25 is not below the threshold: WANDER")
		}
	}
	if wander != 76 {
		t.Errorf("WANDER for %d of r = 1..100; want 76", wander)
	}
}

// Handler_110 (0x5489b0): WANDER and FLEE walk (0), HOMING and BATTLE run (1);
// no run speed gives 0 whatever the state, and no walk speed gives 1.
func TestMotionMode(t *testing.T) {
	cases := []struct {
		name      string
		state     State
		walk, run float64
		want      uint8
	}{
		{"WANDER", StateWander, 8, 22, 0},
		{"FLEE (the caller zeroes the byte, 0x541833)", StateFlee, 8, 22, 0},
		{"HOMING", StateHoming, 8, 22, 1},
		{"BATTLE", StateBattle, 8, 22, 1},
		{"IDLE", StateIdle, 8, 22, 1},
		{"run 0", StateBattle, 8, 0, 0},
		{"run 0, walk 0", StateHoming, 0, 0, 0},
		{"walk 0", StateWander, 0, 22, 1},
	}
	for _, c := range cases {
		if got := MotionMode(c.state, c.walk, c.run); got != c.want {
			t.Errorf("%s: mode %d; want %d", c.name, got, c.want)
		}
	}
}

// IsWithinRoamRadius (0x545f70) is strict: a monster exactly on the radius has
// strayed. Rule 1 widens it by 1.5 (0xb45d78); rule 2 and above never stray.
func TestWithinRoamRadius(t *testing.T) {
	if WithinRoamRadius(100, 100, 300, 100, 200, 0) {
		t.Error("exactly on the radius is not within (fcomp; test ah,0x5; jnp)")
	}
	if !WithinRoamRadius(100, 100, 299.999, 100, 200, 0) {
		t.Error("just inside the radius is within")
	}
	if !WithinRoamRadius(0, 0, 0, 299.999, 200, 1) || WithinRoamRadius(0, 0, 0, 300, 200, 1) {
		t.Error("rule 1: within up to 1.5 x 200 = 300, strictly")
	}
	for _, rule := range []uint8{2, 3, 255} {
		if !WithinRoamRadius(0, 0, 1e6, 1e6, 200, rule) {
			t.Errorf("rule %d: always within", rule)
		}
	}
}

// AITactics_HasArrived (0x541f60) is strict: exactly 5.0 away is not there.
func TestHasArrived(t *testing.T) {
	if HasArrived(0, 0, 3, 4) {
		t.Error("exactly 5.0 away is not arrived (fcomp 0xb45b28; test ah,0x5; jp)")
	}
	if !HasArrived(0, 0, 3, 3.999) || !HasArrived(7, 7, 7, 7) {
		t.Error("under 5.0 away is arrived")
	}
}

// MoveHome's destination lies on the line from home toward the monster, at an
// offset inside HomingScatterRange's band -- never behind home.
func TestHomeDestination(t *testing.T) {
	const r = 200.0
	lo, hi := HomingScatterRange(r)
	rng := rand.New(rand.NewSource(261))
	sawLo, sawHi := false, false
	for i := 0; i < 20000; i++ {
		x, z := 300.0, 400.0 // (0.6, 0.8) from home
		dx, dz := HomeDestination(rng, 0, 0, x, z, r)
		off := math.Hypot(dx, dz)
		if off < lo-1e-9 || off > hi+1e-9 {
			t.Fatalf("offset %v; want %v..%v", off, lo, hi)
		}
		if math.Abs(dx*0.8-dz*0.6) > 1e-9 || dx < 0 {
			t.Fatalf("destination (%v, %v) is off the ray from home toward the monster", dx, dz)
		}
		sawLo = sawLo || math.Abs(off-lo) < 1e-9
		sawHi = sawHi || math.Abs(off-hi) < 1e-9
	}
	if !sawLo || !sawHi {
		t.Errorf("the draw should reach both ends of %v..%v (lo %v, hi %v)", lo, hi, sawLo, sawHi)
	}

	// rand() = 66: 66 % 67 = 66, + 200/3 -> the band's top, 132.67.
	rng2, src := seqRand(66)
	dx, dz := HomeDestination(rng2, 10, 10, 10, 1000, r)
	if dx != 10 || math.Abs(dz-(10+hi)) > 1e-9 || src.i != 1 {
		t.Errorf("rand 66, R 200: (%v, %v) after %d draws; want (10, %v) after 1", dx, dz, src.i, 10+hi)
	}
	// A monster standing on its home has no direction: the destination is home.
	if dx, dz := HomeDestination(rng, 5, 6, 5, 6, r); dx != 5 || dz != 6 {
		t.Errorf("monster on home: (%v, %v); want home", dx, dz)
	}
}

// Nest_Hatch's heading is rand() / 32767 * 2pi: 0 at rand 0, a full turn at
// RAND_MAX, and inside [0, 2pi] for any draw.
func TestSpawnHeading(t *testing.T) {
	rng, _ := seqRand(0, CRandMax, 16384)
	if h := SpawnHeading(rng); h != 0 {
		t.Errorf("rand 0: %v", h)
	}
	if h := SpawnHeading(rng); math.Abs(h-2*math.Pi) > 1e-12 {
		t.Errorf("rand 0x7fff: %v; want 2pi", h)
	}
	if h := SpawnHeading(rng); math.Abs(h-16384.0/32767*2*math.Pi) > 1e-12 {
		t.Errorf("rand 16384: %v", h)
	}
}

// BATTLE enters with no timeout (BATTLE::OnEnter 0x559fb0 calls only the base
// OnEnter, +0x14 = 0, and never AIState_DwellMs), and the base OnUpdate
// (0x558b90) expires only a non-zero timeout, strictly after it.
func TestBattleHasNoDwellExpiry(t *testing.T) {
	if BattleDwellMs != 0 {
		t.Fatalf("BATTLE's entry timeout is %d; the base OnEnter stores 0", BattleDwellMs)
	}
	for _, elapsed := range []int{0, 5000, 60000, 1 << 30} {
		if DwellExpired(BattleDwellMs, elapsed) {
			t.Errorf("BATTLE expired after %d ms; a zero timeout never expires", elapsed)
		}
	}
	// The strictness, on a WANDER dwell's own range (DwellRange).
	_, max, _ := DwellRange(StateWander)
	if DwellExpired(max, max) || !DwellExpired(max, max+1) {
		t.Errorf("a %d ms dwell expires strictly after %d ms (timeout < elapsed)", max, max)
	}
}
