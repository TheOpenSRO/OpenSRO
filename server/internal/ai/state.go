// Package ai holds the monster AI state machine, recovered whole from
// SR_GameServer.exe.
//
// Everything in this file was read out of the binary. The sixteen states are
// not a guess at what a monster AI should have: each one is a compiled C++
// class with its own vtable, and each declares its own id in vtable slot 1 as a
// four- or five-byte function that returns a constant. Those sixteen constants
// are the enum below, read one vtable at a time.
//
// Three independent facts agree that the set is exactly sixteen and that the
// numbering is right:
//
//  1. Fifteen states carry a unique slot-1 body returning ids 0, 2..15, laid
//     out in one contiguous block of the image from 0x0053dc40 to 0x0053e9e0,
//     in id order.
//  2. The missing id, 1, belongs to CAIState_IDLE, whose slot 1 was read
//     straight out of its vtable at 0x00af899c: it points at 0x00506380,
//     `mov ax,0x1; ret`. (That function is COMDAT-folded -- nine vtables in the
//     image share it -- which is why it is not named after IDLE anywhere. The
//     vtable slot is the evidence, not the function.)
//  3. AI::CTactics::ChangeState (0x0053ff30) opens with a bounds assert that
//     rejects anything outside 0..0xf, and indexes a sixteen-entry array.
//
// CAIState's own slot 1 is __purecall, so GetStateID is pure virtual: every
// concrete state must declare an id, and no state can share one by accident.
//
// See docs/protocol/monster_ai.md for the full specification.
package ai

import (
	"fmt"
	"time"
)

// State is a monster's AI state -- the value CAIState::GetStateID (vtable
// slot 1) returns, which the engine's own log format string calls "AIStateID".
type State uint16

// The sixteen states, each read from the vtable slot 1 of its own class. The
// address is the getter that produced the value.
const (
	StateSpawn       State = 0  // CAIState_SPAWN        0x0053dc40
	StateIdle        State = 1  // CAIState_IDLE         0x00506380 (folded)
	StateWander      State = 2  // CAIState_WANDER       0x0053de50
	StateBattle      State = 3  // CAIState_BATTLE       0x0053df30
	StateFlee        State = 4  // CAIState_FLEE         0x0053e010
	StateHoming      State = 5  // CAIState_HOMING       0x0053e0f0
	StateMoving      State = 6  // CAIState_MOVING       0x0053e1d0
	StateEmotion     State = 7  // CAIState_EMOTION      0x0053e2b0
	StateHoldOn      State = 8  // CAIState_HOLDON       0x0053e390
	StateFollow      State = 9  // CAIState_FOLLOW       0x0053e470
	StateWatchOut    State = 10 // CAIState_WATCHOUT     0x0053e560
	StatePatrol      State = 11 // CAIState_PATROL       0x0053e660
	StateAutoCommand State = 12 // CAIState_AUTOCOMMAND  0x0053e900
	StatePickItem    State = 13 // CAIState_PICKITEM     0x0053e820
	StatePending     State = 14 // CAIState_PENDING      0x0053e740
	StateDead        State = 15 // CAIState_DEAD         0x0053e9e0
)

const (
	// StateCount is the size of the state array ChangeState indexes, and the
	// bound its assert enforces.
	StateCount = 16

	// FallbackState is where the engine puts a monster when the state it tried
	// to enter refuses. ChangeState does not propagate the refusal: it takes
	// element 1 of the state array and enters that instead, unconditionally.
	//
	// Element 1 is IDLE, which is how (2) above was settled -- the one state
	// with no slot-1 override of its own is also the one the engine falls back
	// to, and those are independent readings of the same index.
	FallbackState = StateIdle

	// TerminalState is checked by name at the top of ChangeState: if the
	// current state's GetStateID returns 0xf, the call returns 0 immediately
	// without leaving, entering, or touching the current state. A dead monster
	// cannot be moved out of DEAD by any transition.
	TerminalState = StateDead
)

var stateNames = [StateCount]string{
	"SPAWN", "IDLE", "WANDER", "BATTLE", "FLEE", "HOMING", "MOVING", "EMOTION",
	"HOLDON", "FOLLOW", "WATCHOUT", "PATROL", "AUTOCOMMAND", "PICKITEM",
	"PENDING", "DEAD",
}

// Valid reports whether s is one the engine would accept. ChangeState asserts
// `id < 0 || 0xf < id` and breaks into the debugger, so anything outside this
// range is a bug in the caller rather than a state the engine handles.
func (s State) Valid() bool { return s < StateCount }

// String returns the state's own class-name suffix -- CAIState_WANDER is
// "WANDER". These are the engine's spellings, including HOLDON and WATCHOUT as
// single words.
func (s State) String() string {
	if !s.Valid() {
		return fmt.Sprintf("State(%d)", uint16(s))
	}
	return stateNames[s]
}

// Terminal reports whether a monster in this state can still be transitioned.
func (s State) Terminal() bool { return s == TerminalState }

// DwellExtension is 3000 milliseconds, and it is a real constant rather than a
// tuning choice: the base CAIState::OnUpdate (0x00558b90) expires a state when
//
//	timeout != 0 && timeout < (now - enteredAt)
//
// returning -1, and two separate slots -- 18 (0x00559450) and the head of
// slot 17 (0x00559310) -- set that timeout to `(now - enteredAt) + 3000`. The
// literal appears at both sites.
//
// OnEnter (0x00558b70) is what starts the clock: it stores the current tick in
// the state and zeroes the timeout, so a state with no explicit extension never
// expires on its own.
const DwellExtension = 3000 * time.Millisecond

// Message is an AI event id. CAIState::Dispatch (vtable slot 36, 0x005597b0)
// is a switch over exactly these eleven values that forwards each to its own
// vtable slot; the default arm asserts.
type Message uint16

// The eleven messages. The engine does not name them anywhere in the image --
// no string, no log format -- so the names here are this project's, chosen
// from the one thing that is proven about each: the transition its default
// handler performs. The ids and the slot mapping are the engine's.
const (
	MsgSpawned      Message = 0x21 // -> IDLE
	MsgEnemyInRange Message = 0x22 // -> BATTLE, after a range test
	MsgCombatEnded  Message = 0x23 // -> IDLE (folded default)
	MsgArrived      Message = 0x24 // -> IDLE (folded default)
	MsgInterrupted  Message = 0x25 // -> IDLE (folded default)
	MsgReturnHome   Message = 0x26 // -> HOMING
	MsgUnused27     Message = 0x27 // -> IDLE (folded default); no sender in the image
	MsgTeleportHome Message = 0x28 // restores a saved location, then -> IDLE
	MsgTargetLost   Message = 0x29 // clears the target; no transition
	MsgBodyChanged  Message = 0x2a // argument-dependent; -> IDLE on argument 1
	MsgFollowOwner  Message = 0x2b // -> FOLLOW when the argument is zero
)

const (
	// MsgFirst and MsgLast bound the switch in CAIState::Dispatch.
	MsgFirst = MsgSpawned
	MsgLast  = MsgFollowOwner

	// MsgFirstSlot is the vtable slot MsgFirst forwards to. The switch is a
	// dense jump table: message 0x21 calls *(vtable + 0x94), 0x22 calls
	// *(vtable + 0x98), and so on up to 0x2b at *(vtable + 0xbc).
	MsgFirstSlot = 37
)

// Valid reports whether Dispatch would forward m rather than assert.
func (m Message) Valid() bool { return m >= MsgFirst && m <= MsgLast }

// Slot returns the CAIState vtable slot Dispatch forwards m to, or -1.
func (m Message) Slot() int {
	if !m.Valid() {
		return -1
	}
	return MsgFirstSlot + int(m-MsgFirst)
}

// defaultTransitions is the state each message's base handler changes to, read
// from the state id the handler loads into EDI before calling ChangeState.
// A message absent from this map performs no transition of its own.
var defaultTransitions = map[Message]State{
	MsgSpawned:      StateIdle,
	MsgEnemyInRange: StateBattle,
	MsgCombatEnded:  StateIdle,
	MsgArrived:      StateIdle,
	MsgInterrupted:  StateIdle,
	MsgReturnHome:   StateHoming,
	MsgUnused27:     StateIdle,
	MsgTeleportHome: StateIdle,
	MsgBodyChanged:  StateIdle,
	MsgFollowOwner:  StateFollow,
}

// DefaultTransition returns the state the base handler for m moves to, and
// whether it moves at all.
//
// "Default" is meant strictly: a state may override any of slots 37..47 and do
// something else. In the shipped binary only two do -- IDLE overrides slot 41
// (MsgInterrupted) and BATTLE overrides slot 44 (MsgTeleportHome).
func (m Message) DefaultTransition() (State, bool) {
	s, ok := defaultTransitions[m]
	return s, ok
}

// Handled reports whether the base handler for m ends the update by returning
// 2. Senders test for exactly that value -- `if (Dispatch(...) == 2) return;`
// appears at every send site -- so 2 means "consumed, stop processing this
// tick" and 0 means "not consumed, carry on".
const Handled = 2

// Enterer is the part of a state the machine below needs: whether it accepts
// being entered. OnEnter is vtable slot 2 and returns a negative value to
// refuse; CAIState_WANDER (0x00559df0) is the clearest case, refusing with
// -1 when the owner's HP has reached zero.
type Enterer interface {
	// OnEnter reports whether the state accepts the transition.
	OnEnter(from State) bool
	// OnLeave is vtable slot 4, called on the outgoing state before the
	// incoming one is entered. Only BATTLE, FLEE and PICKITEM override it;
	// the base is a bare `return 0`.
	OnLeave(to State)
}

// Machine drives one monster's state, in the order AI::CTactics::ChangeState
// (0x0053ff30) does it.
type Machine struct {
	cur    State
	states [StateCount]Enterer
}

// NewMachine builds a machine sitting in SPAWN, which is where
// AI::CTactics::Init (vtable slot 15, 0x0053f4d0) puts a monster: it is the
// one ChangeState call in the whole image that names state 0.
func NewMachine(states [StateCount]Enterer) *Machine {
	return &Machine{cur: StateSpawn, states: states}
}

// State returns the current state.
func (m *Machine) State() State { return m.cur }

// ChangeState performs a transition exactly as the engine does:
//
//  1. Reject an out-of-range id. The engine asserts here; this returns an
//     error and leaves the machine alone, because a Go server should not take
//     the process down over one bad monster.
//  2. If the current state is DEAD, do nothing and report no error. This is a
//     silent no-op in the engine too -- ChangeState returns 0 before touching
//     anything.
//  3. Call OnLeave on the outgoing state.
//  4. Enter the requested state. If it refuses, enter IDLE instead, and do NOT
//     consult IDLE's answer -- the engine ignores the second OnEnter's return
//     value entirely.
//
// The returned State is where the machine ended up, which is not always the
// one asked for.
func (m *Machine) ChangeState(next State) (State, error) {
	if !next.Valid() {
		return m.cur, fmt.Errorf("ai: state %d is outside 0..%d", uint16(next), StateCount-1)
	}
	if m.cur.Terminal() {
		return m.cur, nil
	}
	from := m.cur
	if s := m.states[from]; s != nil {
		s.OnLeave(next)
	}
	m.cur = next
	if s := m.states[next]; s != nil && !s.OnEnter(from) {
		m.cur = FallbackState
		if f := m.states[FallbackState]; f != nil {
			f.OnEnter(from)
		}
	}
	return m.cur, nil
}
