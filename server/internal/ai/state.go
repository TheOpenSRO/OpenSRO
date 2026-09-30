// Package ai holds the monster AI state machine, recovered whole from
// SR_GameServer.exe.
//
// WIRED BEHIND A DEFAULT-OFF FLAG (round 537). session/monsterai.go drives
// this machine on its own tick when cmd/server runs with -monster-ai
// (SRREVAMP_MONSTER_AI); without the flag nothing here runs and the server
// behaves exactly as it did before. The tick runs SPAWN, IDLE, WANDER and
// HOMING by the rules below and in wander.go, and an interim BATTLE that only
// holds a struck monster where the blow found it. Every stand-in it carries is
// listed in docs/protocol/monster_ai.md, "srrevamp's runtime".
//
// Since then, each behind its own default-off flag: the BATTLE chase and the
// monster's own swing (round 546, -monster-battle; battle.go's rules), target
// acquisition (round 552, -monster-aggro; acquire.go's rules) and, riding
// -monster-battle with no flag of its own, the aggro link (round 553; the
// rules below, session/monsterai.go's linkAggro). Still NOT wired: the threat
// table's retarget rules and the skill choice. internal/systems'
// orphans_test.go names each such function with the item that will call it --
// the rule this package was parked under until round 537, after the HP/MP
// regen rule and the real drop tables were each found recovered, tested and
// uncalled for weeks.
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
	"math"
	"math/rand"
	"sort"
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
	MsgUnused27     Message = 0x27 // -> IDLE (folded default); sent by BATTLE::OnUpdate when the reach test fails (round 238)
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
// refuse; CAIState_WANDER (0x00559df0) is the clearest case. It returns -1
// when the owner's run speed (+0x170) is not above zero (`fldz; fcomp
// [owner+0x170]; test ah,0x1`, 0x559df0..0x559e09), and when the owner is a
// COS (IsCOS, slot 11) that is not a mercenary (IsMercenary, slot 15;
// 0x559e15..0x559e30). It does not test HP: round 251 read HP there, and round
// 536 corrected it (docs/protocol/monster_ai.md, "WANDER's leg").
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

// Resume puts a freshly built machine back into s WITHOUT running any
// OnLeave or OnEnter: the state is being restored, not entered. OURS, not the
// engine's: srrevamp's -monster-sleep drops the brain of a monster no player is
// near and rebuilds it when one comes near (session/monsterai.go, round 666),
// and the rebuilt brain must carry on in the state it slept in, with the
// timers it slept with, rather than re-enter it and roll a new dwell. An
// out-of-range s is refused (false) and the machine is left alone, and so is
// SPAWN: no brain sleeps in it (it leaves SPAWN on its first pass), and a
// machine resumed there would never leave -- nothing updates SPAWN (round
// 666's review).
func (m *Machine) Resume(s State) bool {
	if !s.Valid() || s == StateSpawn {
		return false
	}
	m.cur = s
	return true
}

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

// --- Dwell times and the wander leg (round 251, 2026-09-19) ------------------
//
// AIState_DwellMs (0x00545b70) is the per-state duration a state stores in
// its own +0x14 on entry -- the timeout the base OnUpdate expires it by. Every
// caller passes the entering state's own id (IDLE/HOMING through GetStateID,
// EMOTION from its +0x8; WANDER and FLEE materialise 2 and 4), and the switch
// is, in milliseconds with rand()'s usual bounds:
//
//	IDLE   (1): 4000 + (rand % 2000) * (random sign)   -> 2001 .. 5999
//	WANDER (2): 5000 + rand % 1000                     -> 5000 .. 5999
//	FLEE   (4): 3000 + |rand| % 2001                   -> 3000 .. 5000
//	EMOTION(7): 4000 + (rand % 1000) * (random sign)   -> 3001 .. 4999
//	default:    50000                                   (HOMING and the rest)
//
// WANDER::OnEnter (0x00559df0) stores 1000 instead when no leg could be picked.

// DwellRange is the [min, max] milliseconds AIState_DwellMs returns for a
// state; ok is false for a state that takes the 50 000 ms default.
func DwellRange(s State) (min, max int, ok bool) {
	switch s {
	case StateIdle:
		return 2001, 5999, true
	case StateWander:
		return 5000, 5999, true
	case StateFlee:
		return 3000, 5000, true
	case StateEmotion:
		return 3001, 4999, true
	}
	return DwellDefaultMs, DwellDefaultMs, false
}

// DwellDefaultMs is the switch's default arm.
const DwellDefaultMs = 50000

// DwellMs is AIState_DwellMs (0x00545b70) drawn for state s: a switch on
// s - 1 through the jump table at 0x545c2c (seven entries, read from the PE:
// IDLE 0x545b84, WANDER 0x545bbb, BATTLE 0x545c23, FLEE 0x545c08, HOMING
// 0x545c23, MOVING 0x545c23, EMOTION 0x545bd1), with rand()'s draws in the
// engine's order:
//
//	IDLE     a random sign first (0x545b84..0x545b9f; odd -> +1), then
//	         4000 (0xfa0) + sign x (rand % 2000 (0x7d0))       -> 2001 .. 5999
//	WANDER   5000 (0x1388) + rand % 1000 (0x3e8)               -> 5000 .. 5999
//	FLEE     3000 (0xbb8) + |rand| % 2001 (0x7d1)              -> 3000 .. 5000
//	EMOTION  a random sign, then 4000 + sign x (rand % 1000)   -> 3001 .. 4999
//	the rest 50 000 (0xc350 at 0x545c23), drawing nothing
//
// so every value lies inside DwellRange(s). BATTLE's table entry is the
// default, but BATTLE::OnEnter never calls this (BattleDwellMs).
func DwellMs(rng *rand.Rand, s State) int {
	switch s {
	case StateIdle:
		sign := crandSign(rng)
		return 4000 + crand(rng)%2000*sign
	case StateWander:
		return 5000 + crand(rng)%1000
	case StateFlee:
		return 3000 + crand(rng)%2001
	case StateEmotion:
		sign := crandSign(rng)
		return 4000 + crand(rng)%1000*sign
	}
	return DwellDefaultMs
}

// The wander leg, read off CAIState_WANDER::PickWanderLeg (0x00545860),
// which WANDER::OnEnter runs for a monster whose run speed is above 1e-6:
//
//	distance  = 85 +- (rand % 40)                     ; 46 .. 124 world units (0xb46160 = 85.0)
//	t         = +-(45 + rand % 91) deg                ; 45..135 either side (0xb45e00 = pi/180)
//	h         = atan2(dir.z, dir.x) + t               ; dir = the owner's heading, +0x24/+0x2c
//	direction = normalize(dir + (cos h, 0, sin h))    ; 0x5459b3..0x5459eb, FUN_004328c0
//	probe     = position + direction * 30              ; 0xb45e58 = 30.0
//	if the world's probe (DAT_00cc387c slot 12) of that point reports bit 0 or
//	bit 28 -- blocked -- the direction is reversed (* -1.0, 0xb45e68)
//
// then FUN_00540f70 sets the destination position + direction * distance and
// the move starts; the leg's state timeout is the WANDER dwell above. A leg
// whose destination cannot be picked leaves the state after 1000 ms. Between
// the leg and the probe, when ctx+0x14c resolves to an object (FUN_00485d90)
// the unit vector toward that object is added and the sum normalized again
// (0x5459f0..0x545a50); what +0x14c holds is unread, and neither that term
// nor the probe is modelled here.
//
// Corrected in round 535. Round 251 read the leg as heading + t, a full
// 45..135 degree turn. The binary ADDS the unit vector at heading + t to the
// owner's direction (fld [esi] with esi = owner+0x24 at 0x545989, fadd the
// cosine at [esp+0x24]; +0x28 plus 0.0; +0x2c plus the sine) and normalizes
// the sum. The owner's +0x24/+0x2c is its unit heading: SetHeading (vtable
// slot 230: 0x00482440, the CGObjMobile override 0x0048ba10) writes
// (cos a, 0, sin a) there, called by CGObj::EnterWorld (0x48541e) and at
// every destination move's start (CGObjMoverByDest 0x48c330 -> its slot 10,
// 0x48c660); the only other GObj writer found, CGObj::vslot_000 (0x4848e0),
// zeroes it and its callers were not traced (docs/protocol/monster_ai.md,
// "WANDER's leg"). So the leg bisects the heading and heading + t: a turn of
// t/2, 22.5..67.5 degrees either side. See WanderLegDirection.
const (
	WanderDistanceBase   = 85.0
	WanderDistanceSpread = 40 // rand % 40, either sign
	WanderTurnMinDegrees = 45
	WanderTurnSpreadDeg  = 91 // rand % 91, so t is 45..135 degrees; the leg turns t/2 (round 535)
	WanderProbeDistance  = 30.0
	WanderNoLegTimeoutMs = 1000
	WanderMinRunSpeed    = 1e-6 // 0xb45c84
)

// WanderDistanceRange is the leg length's [min, max] in world units.
func WanderDistanceRange() (min, max float64) {
	return WanderDistanceBase - float64(WanderDistanceSpread-1), WanderDistanceBase + float64(WanderDistanceSpread-1)
}

// WanderLegDirection is PickWanderLeg's leg direction on the ground plane
// (0x00545911..0x005459eb), before the ctx+0x14c term and the blocked-probe
// reversal: the owner's direction (dirX, dirZ) -- its +0x24/+0x2c -- plus the
// unit vector at atan2(dirZ, dirX) + turn (0x9fc1aa is the CRT's _CIatan2,
// z loaded first; 0x489490/0x4894b0 reach fcos/fsin), normalized.
// FUN_004328c0 leaves a zero-length vector zero. turn is t in radians,
// signed. For a unit heading the result turns by turn/2; for a zeroed
// direction atan2(0, 0) = 0 and it is the absolute heading turn from +x.
func WanderLegDirection(dirX, dirZ, turn float64) (x, z float64) {
	h := math.Atan2(dirZ, dirX) + turn
	x, z = dirX+math.Cos(h), dirZ+math.Sin(h)
	if l := math.Hypot(x, z); l > 0 {
		return x / l, z / l
	}
	return 0, 0
}

// Target acquisition, read off the tactics context (round 257,
// docs/protocol/monster_ai.md "Target acquisition"):
//
//	detection = BCRadius + _RefTactics[+0x14]          ; ctx+0x15c, set at the end of
//	                                                    ; AI::CTactics::BindSkillsAndRanges
//	                                                    ; (0x53fa23..0x53fa4f: fild BCRadius,
//	                                                    ; fiadd [row+0x14])
//
// AITactics_AcquireTarget (0x5478f0, behaviour +0xf8, installed only when the
// row's +0x14 is non-zero) scans the regions within trunc(detection) (RC=chop:
// `or eax,0xc00` 0x547989, `fistp` 0x54799a; round 552 corrected round 257's
// "round") for PLAYERS (kind mask 1 by default; the row's flag bits 2/7/8
// widen the kinds) and takes the NEAREST by the region-aware distance
// (selector 2, 0x5464e0; acquire.go's Nearest carries its compare). No level
// term: a level-1 Mangyang and a level-60 player are the same candidate. The
// row's aggression mode gates whether the scan runs at all (mode 1 never,
// mode 2 by its percent, rolled once at spawn: Aggressive), and tactics timer
// 1 paces it (ScanPeriodMs). IDLE, WANDER, HOMING (after its blackout),
// WATCHOUT and EMOTION run it from their OnUpdate; the runtime's three are
// session/monsterai.go's acquire, behind -monster-aggro (round 552).
//
// The level term lives elsewhere: on entering BATTLE the same base radius is
// scaled against the TARGET's level and the ten nearest MONSTERS inside it
// (never MOB_AUTOMOB) are gathered into ctx+0x80 (AITactics_LevelScaledRadius
// 0x541e00 -> AITactics_GatherObjectsWithin 0x540860, mask 2). That list is
// the aggro link's (below; round 258, wired in round 553). The factors are
// doubles (fmul QWORD at 0x541e62/73/84/95), and each holds a FLOAT literal
// widened -- 0xb45c08 is 0x3ff6666660000000, the float 1.4f, read off .rdata
// in round 553 -- so the bands are (level difference = monster - target,
// each level a byte off vtable slot 73, `movzx` at 0x541e47/0x541e54):
//
//	monster level - target level >= 4   : x 1.4  (0xb45c08: 1.39999997615814)
//	                          1 .. 3   : x 1.2  (0xb45c00: 1.20000004768372)
//	                         -3 .. 0   : x 1.0  (no multiply: 0x541e8f jumps past it)
//	                         -6 .. -4  : x 0.8  (0xb45bf0: 0.80000001192093)
//	                          <= -7    : x 0.6  (0xb45bf8: 0.60000002384186)
//
// The product is stored back as a float (fstp DWORD 0x541e9b) and then
// chopped to an int (LevelScaledRadius). The per-species +0x14 distances are
// in no archive this project holds (_RefTactics is a server database table;
// the package on the box carries no shard backup, and its GameServer
// minidumps hold no heap), so a monster's detection distance stays disclosed
// until a source appears: TacticsDetectionDistance (acquire.go) is the one
// stand-in every species gets under -monster-aggro.
const (
	LevelRadiusFarAbove  = float64(float32(1.4)) // target at least 4 levels below the monster; 0xb45c08 = 0x3ff6666660000000
	LevelRadiusAbove     = float64(float32(1.2)) // 1 to 3 levels below; 0xb45c00 = 0x3ff3333340000000
	LevelRadiusNear      = 1.0                   // up to 3 levels above: the base unchanged
	LevelRadiusBelow     = float64(float32(0.8)) // 4 to 6 levels above; 0xb45bf0 = 0x3fe99999a0000000
	LevelRadiusFarBelow  = float64(float32(0.6)) // 7 or more levels above; 0xb45bf8 = 0x3fe3333340000000
	LevelRadiusAboveBand = 4
	LevelRadiusBelowBand = -4
	LevelRadiusFarBand   = -7
)

// DetectionRadius is how far a monster notices a player: its BCRadius plus
// its tactics row's +0x14 distance. ok is false when the distance is zero --
// such a monster never acquires a target on its own.
func DetectionRadius(bcRadius, tacticsDistance int) (radius float64, ok bool) {
	if tacticsDistance <= 0 {
		return 0, false
	}
	return float64(bcRadius + tacticsDistance), true
}

// LevelScaledRadius is AITactics_LevelScaledRadius (0x541e00): the base
// radius -- ctx+0x15c, a float (`fld DWORD [eax+0x15c]` 0x541e00) -- times
// the band's factor, stored back as a float (`fstp DWORD [esp+0x4]` 0x541e9b;
// the -3..0 band skips the multiply and the store, 0x541e8f -> 0x541e9f) and
// converted under RC=chop (`or eax,0xc00; fldcw; fistp QWORD`,
// 0x541ea4..0x541ec2) into the INT the caller's out-parameter holds (`mov
// [ebx],edx` 0x541ec2). A target the engine cannot resolve (edi = 0) chops the
// raw base the same way (0x541e0d..0x541e29), which is the -3..0 band here.
//
// The float store is modelled: a float (24-bit significand) times a widened
// float (24 bits) is exact in float64, so the one rounding on this path is
// the store's, in both the engine and here -- 110 x 1.4f is 153.9999974,
// which the store rounds to 154.0 and the chop leaves at 154; chopping the
// exact product would give 153. Corrected in round 553: until then this
// returned the unrounded float64 product of the base and 1.4 exactly.
func LevelScaledRadius(base float64, monsterLevel, targetLevel int) int {
	r := float32(base)
	diff := monsterLevel - targetLevel
	switch {
	case diff >= LevelRadiusAboveBand:
		r = float32(float64(r) * LevelRadiusFarAbove)
	case diff >= 1:
		r = float32(float64(r) * LevelRadiusAbove)
	case diff <= LevelRadiusFarBand:
		r = float32(float64(r) * LevelRadiusFarBelow)
	case diff <= LevelRadiusBelowBand:
		r = float32(float64(r) * LevelRadiusBelow)
	}
	return int(r)
}

// GatherWithin is AITactics_GatherObjectsWithin (0x540860) for the aggro
// link's list: of cands -- the OTHER monsters around the owner (the routine
// skips the owner itself and keeps kind mask 2, never one named MOB_AUTOMOB)
// -- those whose distance from the owner at (x, z) (GObj_DistanceBetween
// 0x53d7a0 with the owner in eax and the candidate in ecx, 0x540a85..0x540a8d),
// stored as a float, is AT MOST the radius (`fStack_48 <= fStack_58`, the
// radius an int the routine widens to a float), nearest first, at most
// AggroLinkMaxHelpers of them (the pop loop's `< 10`). srrevamp's own,
// disclosed: the ground-plane distance (the engine's sums three axes and
// srrevamp's monsters carry no height, as acquire measures), and ties broken
// by id (the engine's sorted container keeps the region walk's order).
func GatherWithin(cands []Candidate, x, z float64, radius int) []Candidate {
	type at struct {
		c Candidate
		d float32
	}
	limit := float32(radius)
	var in []at
	for _, c := range cands {
		if d := float32(math.Hypot(c.X-x, c.Z-z)); d <= limit {
			in = append(in, at{c, d})
		}
	}
	sort.Slice(in, func(i, j int) bool {
		if in[i].d != in[j].d {
			return in[i].d < in[j].d
		}
		return in[i].c.ID < in[j].c.ID
	})
	if len(in) > AggroLinkMaxHelpers {
		in = in[:AggroLinkMaxHelpers]
	}
	out := make([]Candidate, len(in))
	for i, a := range in {
		out[i] = a.c
	}
	return out
}

// The aggro link, read off CAIState::OnAttacked (0x558ea0) and
// AITactics_ExtRoutine::LinkAggroToNearbyMonsters (0x547570, behaviour
// +0xf0), round 258, re-read whole in round 553 (docs/protocol/monster_ai.md
// "The aggro link"). OnAttacked -- the base slot 6 that IDLE, WANDER, FLEE
// and HOMING use; BATTLE's own slot 6 has no link -- runs the link first
// (the +0xf0 call at 0x558ebb), then the attacker accounting and the victim's
// own SetTarget and ChangeState(3). The attack record is {attacker, damage
// (+4), hate (+8), hatePercent (+0xc)} (AITactics_CreditAttacker 0x5473c0:
// +4 goes to the seat's damage, +8 and +0xc to its hate). The link:
//
//  1. returns before gathering when the record's HATE is zero or the attacker
//     is not a PC (0x547570's opening tests: `param_2[2] == 0`, then vtable
//     slot 7), and when the attacker has no party (pc+0x1cb8, `piVar4[0x72e]`)
//     or the party's +0x10 bit 0 -- EXP sharing, named in party.md -- is clear;
//  2. gathers the ten nearest OTHER monsters within LevelScaledRadius(the
//     victim's detection radius, victim level - attacker level) of the
//     victim (AITactics_CollectNearbyMonsters 0x540580 -> GatherWithin);
//  3. counts the party members AT MOST 1000.0 units from the attacker
//     (`fcomp QWORD 0xb45c68; fnstsw; test ah,0x41; jp` 0x5476e9..0x5476f4:
//     below or equal), the attacker itself counted without measuring
//     (0x5476f6 through the `member == attacker` arm), a member only when
//     it resolves in the world and stands in the same or an adjacent region
//     as the attacker or both are in a dungeon (0x430ce0: the region ids'
//     bit 15 equal, then their x and y bytes within 1 -- which 1000 units
//     already implies at a 1920-unit region span);
//  4. clamps that count to the gathered count (AggroLinkCount);
//  5. zeroes the record's damage (`mov [edi+0x4],ebx` with ebx = 0 at
//     0x547797) and, for each of the nearest n: floors the record's hate at 1
//     (`cmp [edi+0x8],0; jg; mov [edi+0x8],1` 0x5477b2..0x5477b8), forwards
//     command 0xe to the monster when AITactics_ValidTargetOrNull (0x540dc0
//     at 0x5477ea) accepts it and it has a command source (0x5477f3..0x54780a),
//     then scales the hate by the decrease ratio (`fild [esi+0x8]; fmul
//     DWORD [0xc8252c]` -> _ftol2_sse -> `mov [esi+0x8],eax`, 0x54780c..
//     0x54781a; AggroLinkHate).
//
// Command 0xe is slot 29: CAIState::OnAggroLinked (0x559bb0) credits,
// SetTarget(attacker)s and ChangeState(3)s with no +0xf0 call of its own, so
// a link never cascades; CAIState_BATTLE::OnAggroLinked (0x55a320) only
// credits, so a gathered monster already in BATTLE keeps its target under
// rule 0 and still uses up its place among the n. OnAttacked saves the hate
// before the link (`mov eax,[esi+0x8]` 0x558ea6) and stores ftol(hate x
// 1.15f) back over it afterwards (0x558ebd..0x558ecc). So under a link
// neither the neighbours nor the victim book the blow's damage (round 537's
// correction of round 258's "damage"), and a solo player never links.
const (
	// AggroLinkMaxHelpers is the gather's cap: the ten nearest monsters.
	AggroLinkMaxHelpers = 10
	// AggroLinkMemberRange is how near a party member must stand to the
	// attacker to count: at most this (0xb45c68, the double 1000.0; the
	// compare above is inclusive).
	AggroLinkMemberRange = 1000.0
	// AggroLinkDecreaseRatio is MONSTER_AGGRO_LINK_DECREASE_RATIO's default,
	// 0.5 (0xb45b68, the float 0x3f000000): the factor each link's hate
	// shrinks by. A configured value is a percentage over 100 with no floor.
	AggroLinkDecreaseRatio = 0.5
	// AggroVictimDamageFactor is what the struck monster itself books the
	// record's HATE at in its attacker accounting: hate x 1.15f -- 0xb46300 is
	// 0x3ff2666660000000, the float literal widened (1.14999997615814), read
	// off .rdata in round 553 -- chopped by _ftol2_sse from the extended
	// product with no float store between (0x558ebd..0x558ecc), so a hate of
	// 20 books 22, not 23. The links get the raw hate and its halvings; the
	// victim weighs its own attacker 15 % heavier. The name predates round
	// 537's correction from "raw damage".
	AggroVictimDamageFactor = float64(float32(1.15))
)

// AggroLinkCount is how many gathered monsters a hit links: the party
// members near the attacker (the attacker included), clamped to the gathered
// count -- the routine's own CLAMP (AITactics_ExtRoutine.cpp:0x662: a
// negative count becomes 0 at 0x54782b..0x547839, one above the gathered
// count becomes that count at 0x547778..0x54778c).
func AggroLinkCount(membersNear, gathered int) int {
	if membersNear < 0 {
		membersNear = 0
	}
	if gathered > AggroLinkMaxHelpers {
		gathered = AggroLinkMaxHelpers
	}
	if membersNear > gathered {
		return gathered
	}
	return membersNear
}

// AggroLinkHate is the hate the i-th linked monster (0-based) is forwarded:
// the record's hate, floored at 1 before each forward (0x5477b2..0x5477b8)
// and scaled by the decrease ratio after it, truncated toward zero as
// _ftol2_sse does (0x54780c..0x54781a) -- 45 hate reaches the links as 45,
// 22, 11, 5, 2, 1, 1, ... and never 0. Named AggroLinkDamage until round 553
// (the factor acts on the hate, +8, not the damage, +4: round 537). Nothing
// forwards a hate yet: srrevamp's blows carry no hate value, and the
// magnitudes are the threat table's (mob-threat-retarget).
func AggroLinkHate(hate int, link int, ratio float64) int {
	for i := 0; i < link; i++ {
		if hate < 1 {
			hate = 1
		}
		hate = int(float64(hate) * ratio)
	}
	if hate < 1 {
		hate = 1
	}
	return hate
}

// HOMING, read off CAIState_HOMING::OnEnter/MoveHome/OnUpdate and
// AITactics_HomingStep (round 261, docs/protocol/monster_ai.md "HOMING";
// MoveHome's offset corrected in round 535).
const (
	// HomingArrivalRadius: within this many units of the destination the
	// monster is home (0xb45b28, fld DWORD 5.0).
	HomingArrivalRadius = 5.0
	// HomingWobbleMin/Max scale the heading blended into the direction while
	// the monster is still outside its roam radius: (rand % 101 + 50) / 100.
	HomingWobbleMin = 0.5
	HomingWobbleMax = 1.5
)

// HomingScatterRange is how far from home CAIState_HOMING::MoveHome
// (0x00545c50) puts the homing destination, along the line from home toward
// the monster -- normalize(monster - home): FUN_00430ad0 with esi = the
// monster's position and edi = home's (0x545ccd/0x545cd1), then FUN_004328c0
// -- for a nest radius (or roam radius) R:
//
//	offset = rand % (1 + trunc(R/3)) + R/3     ; [R/3, R/3 + trunc(R/3)]
//
// so 66.7 .. 132.7 units toward the monster for R = 200. The engine holds R
// and R/3 as floats (fstp DWORD at 0x545cf6 and 0x545d68). The destination
// is exactly home when the owner's vtable slot 243 (+0x3cc) answers non-zero.
//
// Corrected in round 535. Round 261 read rand % (1 + ftol(R/3)) - R/9 off
// the decompiler, whose extraout_ST0 / 3.0 assumed _ftol2_sse (0x009fbb40)
// leaves its argument on the x87 stack. It pops it (fstp QWORD at 0x9fbb52;
// the x87 path from 0x9fbb7f consumes st0 too), and the stack at
// 0x545cff..0x545d70 balances only this way: fld R; fld -3.0 (0xb45e08);
// fdivr -> st0 = R/-3, st1 = R; ftol pops, ecx = 1 - trunc(-R/3); fild rem;
// fxch; fdiv 3.0 (0xb45ab8) -> R/3; fstp; fadd -> rem + R/3; fstp.
func HomingScatterRange(radius float64) (min, max float64) {
	third := radius / 3
	return third, third + float64(int(radius/3))
}

// HomingReaggroDelayMs is how long a homing monster ignores players: the
// time to cover its detection radius at its run speed (units per second),
// TRUNCATED to milliseconds. CAIState_HOMING::OnEnter (0x55a540) computes the
// state's +0x1c at 0x55a60e..0x55a63e as `fld [ctx+0x15c]; fdiv [owner+
// 0x170]; fmul QWORD 0xb45c68` (1000.0) under the control word it found, then
// `or eax,0xc00; fldcw; fistp QWORD` -- RC=chop for the conversion alone --
// and ReaggroWindowPassed (0x55a720) is `now - enteredAt > +0x1c`, strict.
// Corrected in round 552: round 261 read it as rounded, and the helper added
// 0.5 (5/3 s gave 1667; the engine's is 1666). Zero speed means never (the
// engine would divide by zero; an immobile monster does not home). The two
// roundings before the conversion are float64's here as the x87's at its
// default 53-bit precision; the roster's values (106/22 -> 4818.18) are
// nowhere near an integer.
func HomingReaggroDelayMs(detectionRadius, runSpeed float64) int {
	if runSpeed <= 0 {
		return 0
	}
	return int(detectionRadius / runSpeed * 1000)
}
