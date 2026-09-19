package ai

import (
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
