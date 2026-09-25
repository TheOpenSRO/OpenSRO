package ai

import (
	"math"
	"math/rand"
	"testing"
	"time"
)

// The enum is only useful if it stays the one the binary declares. These are
// the sixteen constants read from the sixteen vtables, written out a second
// time so a typo in either list fails rather than silently renumbering a state.
func TestStateIDsMatchTheVtables(t *testing.T) {
	want := map[State]string{
		0: "SPAWN", 1: "IDLE", 2: "WANDER", 3: "BATTLE", 4: "FLEE",
		5: "HOMING", 6: "MOVING", 7: "EMOTION", 8: "HOLDON", 9: "FOLLOW",
		10: "WATCHOUT", 11: "PATROL", 12: "AUTOCOMMAND", 13: "PICKITEM",
		14: "PENDING", 15: "DEAD",
	}
	if len(want) != StateCount {
		t.Fatalf("the table has %d states, StateCount is %d", len(want), StateCount)
	}
	for id, name := range want {
		if got := id.String(); got != name {
			t.Errorf("state %d is %q, want %q", uint16(id), got, name)
		}
	}
	// Every id in range must name a distinct state; the engine's pure-virtual
	// GetStateID means no two classes can share one.
	seen := map[string]State{}
	for i := State(0); i < StateCount; i++ {
		if prev, dup := seen[i.String()]; dup {
			t.Errorf("states %d and %d both name %q", uint16(prev), uint16(i), i.String())
		}
		seen[i.String()] = i
	}
}

func TestValidMatchesTheChangeStateAssert(t *testing.T) {
	// ChangeState asserts on `id < 0 || 0xf < id`.
	for _, s := range []State{0, 1, 15} {
		if !s.Valid() {
			t.Errorf("state %d should be valid", uint16(s))
		}
	}
	for _, s := range []State{16, 17, 255} {
		if s.Valid() {
			t.Errorf("state %d should be rejected", uint16(s))
		}
	}
}

func TestDwellExtensionIsTheBinarysConstant(t *testing.T) {
	if DwellExtension != 3*time.Second {
		t.Errorf("DwellExtension is %v; slots 17 and 18 both add 3000 ms", DwellExtension)
	}
}

// The eleven messages map onto a dense run of vtable slots, 37 through 47.
func TestMessagesMapOntoSlots37To47(t *testing.T) {
	if got := MsgFirst.Slot(); got != 37 {
		t.Errorf("message 0x%02x maps to slot %d, want 37", uint16(MsgFirst), got)
	}
	if got := MsgLast.Slot(); got != 47 {
		t.Errorf("message 0x%02x maps to slot %d, want 47", uint16(MsgLast), got)
	}
	if n := int(MsgLast-MsgFirst) + 1; n != 11 {
		t.Errorf("the switch covers %d messages, want 11", n)
	}
	for m := MsgFirst; m <= MsgLast; m++ {
		if !m.Valid() {
			t.Errorf("message 0x%02x should be valid", uint16(m))
		}
	}
	for _, m := range []Message{0x20, 0x2c, 0} {
		if m.Valid() {
			t.Errorf("message 0x%02x should assert, not dispatch", uint16(m))
		}
		if got := m.Slot(); got != -1 {
			t.Errorf("message 0x%02x maps to slot %d, want -1", uint16(m), got)
		}
	}
}

func TestDefaultTransitions(t *testing.T) {
	want := map[Message]State{
		MsgSpawned:      StateIdle,
		MsgEnemyInRange: StateBattle,
		MsgReturnHome:   StateHoming,
		MsgFollowOwner:  StateFollow,
	}
	for m, s := range want {
		got, ok := m.DefaultTransition()
		if !ok {
			t.Errorf("message 0x%02x should transition", uint16(m))
			continue
		}
		if got != s {
			t.Errorf("message 0x%02x -> %s, want %s", uint16(m), got, s)
		}
	}
	// The one handler that changes no state: it clears the target and returns.
	if _, ok := MsgTargetLost.DefaultTransition(); ok {
		t.Errorf("message 0x%02x performs no transition", uint16(MsgTargetLost))
	}
}

// --- the machine -------------------------------------------------------

type probe struct {
	accept   bool
	entered  []State // the `from` of each OnEnter
	left     []State // the `to` of each OnLeave
	selfID   State
	recorder *[]string
}

func (p *probe) OnEnter(from State) bool {
	p.entered = append(p.entered, from)
	*p.recorder = append(*p.recorder, "enter "+p.selfID.String())
	return p.accept
}

func (p *probe) OnLeave(to State) {
	p.left = append(p.left, to)
	*p.recorder = append(*p.recorder, "leave "+p.selfID.String())
}

func build(t *testing.T, accept map[State]bool) (*Machine, map[State]*probe, *[]string) {
	t.Helper()
	log := &[]string{}
	probes := map[State]*probe{}
	var states [StateCount]Enterer
	for i := State(0); i < StateCount; i++ {
		ok := true
		if v, set := accept[i]; set {
			ok = v
		}
		p := &probe{accept: ok, selfID: i, recorder: log}
		probes[i] = p
		states[i] = p
	}
	return NewMachine(states), probes, log
}

func TestMachineStartsInSpawn(t *testing.T) {
	m, _, _ := build(t, nil)
	if m.State() != StateSpawn {
		t.Errorf("a new machine is in %s, want SPAWN", m.State())
	}
}

// The engine leaves the old state before entering the new one.
func TestLeaveRunsBeforeEnter(t *testing.T) {
	m, _, log := build(t, nil)
	if _, err := m.ChangeState(StateWander); err != nil {
		t.Fatal(err)
	}
	if got := *log; len(got) != 2 || got[0] != "leave SPAWN" || got[1] != "enter WANDER" {
		t.Errorf("order was %v, want [leave SPAWN enter WANDER]", got)
	}
	if m.State() != StateWander {
		t.Errorf("ended in %s, want WANDER", m.State())
	}
}

// A refused entry does not propagate. The engine puts the monster in IDLE and
// does not look at IDLE's answer.
func TestRefusedEntryFallsBackToIdle(t *testing.T) {
	m, probes, log := build(t, map[State]bool{StateBattle: false})
	got, err := m.ChangeState(StateBattle)
	if err != nil {
		t.Fatal(err)
	}
	if got != StateIdle || m.State() != StateIdle {
		t.Errorf("a refused BATTLE left the machine in %s, want IDLE", m.State())
	}
	if n := len(probes[StateIdle].entered); n != 1 {
		t.Errorf("IDLE was entered %d times, want 1", n)
	}
	// SPAWN is left once, and only once -- the fallback does not leave again.
	if n := len(probes[StateSpawn].left); n != 1 {
		t.Errorf("SPAWN was left %d times, want 1", n)
	}
	want := []string{"leave SPAWN", "enter BATTLE", "enter IDLE"}
	for i, w := range want {
		if i >= len(*log) || (*log)[i] != w {
			t.Fatalf("order was %v, want %v", *log, want)
		}
	}
}

// Even a refusing IDLE is accepted, because the engine ignores the second
// return value. This is the odd-looking half of ChangeState and the half most
// likely to be "cleaned up" by someone who has not read it.
func TestFallbackIgnoresIdlesOwnRefusal(t *testing.T) {
	m, _, _ := build(t, map[State]bool{StateBattle: false, StateIdle: false})
	got, err := m.ChangeState(StateBattle)
	if err != nil {
		t.Fatal(err)
	}
	if got != StateIdle {
		t.Errorf("ended in %s, want IDLE even though IDLE refused", got)
	}
}

// DEAD is terminal, and the engine checks it before doing anything at all --
// no leave, no enter, no error.
func TestDeadIsTerminal(t *testing.T) {
	m, probes, _ := build(t, nil)
	if _, err := m.ChangeState(StateDead); err != nil {
		t.Fatal(err)
	}
	before := len(probes[StateDead].left)
	got, err := m.ChangeState(StateBattle)
	if err != nil {
		t.Fatalf("a transition out of DEAD is a silent no-op, not an error: %v", err)
	}
	if got != StateDead {
		t.Errorf("left DEAD for %s", got)
	}
	if len(probes[StateDead].left) != before {
		t.Error("DEAD was left; the engine returns before calling OnLeave")
	}
	if n := len(probes[StateBattle].entered); n != 0 {
		t.Errorf("BATTLE was entered %d times from DEAD, want 0", n)
	}
}

func TestOutOfRangeIsRejectedWithoutMoving(t *testing.T) {
	m, _, log := build(t, nil)
	got, err := m.ChangeState(State(StateCount))
	if err == nil {
		t.Fatal("state 16 should be rejected")
	}
	if got != StateSpawn || m.State() != StateSpawn {
		t.Errorf("a rejected transition moved the machine to %s", m.State())
	}
	if len(*log) != 0 {
		t.Errorf("a rejected transition ran %v", *log)
	}
}

// A nil state is not a crash: the engine's array is fully populated, but a
// partial Go implementation should degrade rather than panic.
func TestNilStatesAreSkipped(t *testing.T) {
	var states [StateCount]Enterer
	m := NewMachine(states)
	got, err := m.ChangeState(StateWander)
	if err != nil {
		t.Fatal(err)
	}
	if got != StateWander {
		t.Errorf("ended in %s, want WANDER", got)
	}
}

// TestDwellRangesAreTheSwitchArms pins AIState_DwellMs (0x00545b70) arm by arm,
// including the 50 000 ms default HOMING falls into.
func TestDwellRangesAreTheSwitchArms(t *testing.T) {
	cases := []struct {
		s        State
		min, max int
		ok       bool
	}{
		{StateIdle, 2001, 5999, true},
		{StateWander, 5000, 5999, true},
		{StateFlee, 3000, 5000, true},
		{StateEmotion, 3001, 4999, true},
		{StateHoming, 50000, 50000, false},
		{StateBattle, 50000, 50000, false},
	}
	for _, c := range cases {
		min, max, ok := DwellRange(c.s)
		if min != c.min || max != c.max || ok != c.ok {
			t.Errorf("%s: got %d..%d ok=%v, want %d..%d ok=%v", c.s, min, max, ok, c.min, c.max, c.ok)
		}
	}
	if lo, hi := WanderDistanceRange(); lo != 46 || hi != 124 {
		t.Errorf("wander leg 85 +- 39: got %v..%v", lo, hi)
	}
}

// AIState_DwellMs drawn (round 537, the monster AI tick's dwells). IDLE
// draws its sign FIRST and the remainder second (0x545b84, then 0x545ba2): the
// values (1999, 2) give 4000 + 2 = 4002, where remainder-first would give
// 4000 - 1999 = 2001. WANDER and FLEE draw once; HOMING and BATTLE draw
// nothing and take the 50 000 ms default arm. Every draw lies in DwellRange.
func TestDwellMsDrawsTheSwitchArms(t *testing.T) {
	exact := []struct {
		s    State
		vals []int
		want int
	}{
		{StateIdle, []int{1, 1999}, 5999},
		{StateIdle, []int{2, 1999}, 2001},
		{StateIdle, []int{1999, 2}, 4002},
		{StateWander, []int{999}, 5999},
		{StateFlee, []int{2000}, 5000},
		{StateEmotion, []int{1, 999}, 4999},
		{StateEmotion, []int{2, 999}, 3001},
	}
	for _, c := range exact {
		rng, src := seqRand(c.vals...)
		if got := DwellMs(rng, c.s); got != c.want || src.i != len(c.vals) {
			t.Errorf("%s with draws %v: %d after %d draws, want %d after %d", c.s, c.vals, got, src.i, c.want, len(c.vals))
		}
	}
	for _, s := range []State{StateHoming, StateBattle, StateMoving} {
		rng, src := seqRand(5)
		if got := DwellMs(rng, s); got != DwellDefaultMs || src.i != 0 {
			t.Errorf("%s: %d after %d draws, want the %d default and no draw", s, got, src.i, DwellDefaultMs)
		}
	}
	rng := rand.New(rand.NewSource(537))
	for _, s := range []State{StateIdle, StateWander, StateFlee, StateEmotion} {
		min, max, _ := DwellRange(s)
		for i := 0; i < 4000; i++ {
			if got := DwellMs(rng, s); got < min || got > max {
				t.Fatalf("%s drew %d, outside %d..%d", s, got, min, max)
			}
		}
	}
}

// The detection radius is BCRadius + the row's distance, and nothing when the
// row carries none; the BATTLE-entry bands are the five doubles at their
// level differences, with the engine's own boundaries (>= 4, >= 1, <= -7,
// <= -4, else 1.0).
func TestDetectionAndLevelScaledRadius(t *testing.T) {
	if r, ok := DetectionRadius(6, 50); !ok || r != 56 {
		t.Fatalf("DetectionRadius(6, 50) = %v,%v; want 56,true", r, ok)
	}
	if _, ok := DetectionRadius(6, 0); ok {
		t.Fatal("a zero tactics distance never acquires")
	}
	cases := []struct {
		monster, target int
		want            float64
	}{
		{10, 6, 1.4}, {10, 5, 1.4}, // diff 4, 5
		{10, 9, 1.2}, {10, 7, 1.2}, // diff 1, 3
		{10, 10, 1.0}, {10, 13, 1.0}, // diff 0, -3
		{10, 14, 0.8}, {10, 16, 0.8}, // diff -4, -6
		{10, 17, 0.6}, {1, 60, 0.6}, // diff -7, -59
	}
	for _, c := range cases {
		if got := LevelScaledRadius(100, c.monster, c.target); got != 100*c.want {
			t.Errorf("LevelScaledRadius(100, %d, %d) = %v; want %v", c.monster, c.target, got, 100*c.want)
		}
	}
}

// The link count is the nearby party members clamped to the gathered
// monsters (at most ten), and each link's damage halves by default,
// truncating like ftol.
func TestAggroLink(t *testing.T) {
	if got := AggroLinkCount(3, 10); got != 3 {
		t.Fatalf("3 members, 10 gathered: %d links; want 3", got)
	}
	if got := AggroLinkCount(8, 2); got != 2 {
		t.Fatalf("8 members, 2 gathered: %d links; want 2", got)
	}
	if got := AggroLinkCount(12, 15); got != 10 {
		t.Fatalf("the gather never holds more than ten: got %d", got)
	}
	if got := AggroLinkCount(-1, 5); got != 0 {
		t.Fatalf("a negative count clamps to 0: got %d", got)
	}
	// 45 damage: the first linked monster is credited 45, the second 22, the
	// third 11 (45 * 0.5 = 22.5 -> 22, 22 * 0.5 = 11).
	for i, want := range []int{45, 22, 11, 5} {
		if got := AggroLinkDamage(45, i, AggroLinkDecreaseRatio); got != want {
			t.Errorf("link %d: %d damage; want %d", i, got, want)
		}
	}
	// The victim books 45 * 1.15 = 51.75 -> 51.
	raw := 45.0
	if got := int(raw * AggroVictimDamageFactor); got != 51 {
		t.Errorf("victim's own credit: %d; want 51", got)
	}
}

// Homing: arrival at 5 units, the offset band, and the re-aggro window a
// Mangyang (detection 56 at run speed 50) keeps shut for 1120 ms.
//
// The band is MoveHome's (0x00545c50) rand % (1 + trunc(R/3)) + R/3 toward
// the monster (round 535). Round 261's -R/9 .. +2R/9 came from the
// decompiler's stale ST0 after _ftol2_sse, which pops its argument; that
// reading put the destination up to R/9 BEHIND home, which the x87 walk at
// 0x545cff..0x545d70 does not allow -- the offset is never below R/3.
func TestHomingRules(t *testing.T) {
	if HomingArrivalRadius != 5.0 {
		t.Fatal("arrival is 5.0 units")
	}
	cases := []struct {
		radius, lo, hi float64
	}{
		{200, 200.0 / 3, 200.0/3 + 66}, // 66.7 .. 132.7
		{100, 100.0 / 3, 100.0/3 + 33}, // trunc(33.3) = 33
		{9, 3, 6},                      // R/3 whole: 3 + rand % 4
		{2, 2.0 / 3, 2.0 / 3},          // trunc(0.67) = 0: rand % 1, R/3 exactly
		{0, 0, 0},                      // no radius: home itself
	}
	for _, c := range cases {
		lo, hi := HomingScatterRange(c.radius)
		if math.Abs(lo-c.lo) > 1e-9 || math.Abs(hi-c.hi) > 1e-9 {
			t.Errorf("offset for R=%v: %v..%v; want %v..%v", c.radius, lo, hi, c.lo, c.hi)
		}
		if lo < c.radius/3 {
			t.Errorf("R=%v: the offset starts at %v, short of R/3 (round 261's -R/9 reading)", c.radius, lo)
		}
	}
	if d := HomingReaggroDelayMs(56, 50); d != 1120 {
		t.Fatalf("re-aggro delay %d ms; want 1120", d)
	}
	if d := HomingReaggroDelayMs(56, 0); d != 0 {
		t.Fatalf("no speed, no window: %d", d)
	}
	// The conversion truncates (fistp under RC=chop, 0x55a622/0x55a636):
	// 5/3 s is 1666 ms, not the 1667 the helper gave until round 552 -- the
	// helper's own negative. The Mangyang's blackout under the stand-in
	// (radius 106, run 22) is 4818 ms, a value derived from that stand-in.
	if d := HomingReaggroDelayMs(5, 3); d != 1666 {
		t.Fatalf("re-aggro delay for 5 units at 3/s = %d ms; want 1666 (truncated), not 1667 (rounded)", d)
	}
	if d := HomingReaggroDelayMs(106, 22); d != 4818 {
		t.Fatalf("the Mangyang's blackout = %d ms; want 4818", d)
	}
}

// angleBetween is the signed difference a - b folded into (-pi, pi].
func angleBetween(a, b float64) float64 {
	return math.Remainder(a-b, 2*math.Pi)
}

// PickWanderLeg's direction (0x005459b3..0x005459eb) is normalize(heading +
// unit(heading + t)), so for a unit heading the leg turns by t/2: 22.5
// degrees at the draw's smallest t, 67.5 at its largest, either side. Round
// 251 recorded the full t (45..135); that rule is checked here as the one
// the leg must NOT follow. A zeroed heading gives atan2(0, 0) = 0, and the leg
// is the absolute heading t from +x.
func TestWanderLegBisectsHeadingAndTurn(t *testing.T) {
	const deg = math.Pi / 180
	tMin := float64(WanderTurnMinDegrees)
	tMax := float64(WanderTurnMinDegrees + WanderTurnSpreadDeg - 1)
	if tMin != 45 || tMax != 135 {
		t.Fatalf("the draw t is 45..135 degrees; constants give %v..%v", tMin, tMax)
	}
	for _, a := range []float64{0, 30, 90, 200, -120} {
		for _, turn := range []float64{tMin, 90, tMax, -tMin, -tMax} {
			x, z := WanderLegDirection(math.Cos(a*deg), math.Sin(a*deg), turn*deg)
			if l := math.Hypot(x, z); math.Abs(l-1) > 1e-12 {
				t.Errorf("heading %v, t %v: leg length %v; want 1", a, turn, l)
			}
			got := math.Atan2(z, x)
			if d := angleBetween(got, (a+turn/2)*deg); math.Abs(d) > 1e-9 {
				t.Errorf("heading %v, t %v: leg at %.4f deg; want the bisector %.4f",
					a, turn, got/deg, a+turn/2)
			}
			if d := angleBetween(got, (a+turn)*deg); math.Abs(d) < 1e-3 {
				t.Errorf("heading %v, t %v: leg turned the full t (round 251's reading)", a, turn)
			}
			if d := math.Abs(angleBetween(got, a*deg)) / deg; d < 22.5-1e-9 || d > 67.5+1e-9 {
				t.Errorf("heading %v, t %v: turned %.4f deg; want 22.5..67.5", a, turn, d)
			}
		}
	}
	x, z := WanderLegDirection(0, 0, 100*deg)
	if d := angleBetween(math.Atan2(z, x), 100*deg); math.Abs(d) > 1e-9 || math.Abs(math.Hypot(x, z)-1) > 1e-12 {
		t.Errorf("zeroed heading, t 100: leg (%v, %v); want the unit vector at 100 deg", x, z)
	}
}
