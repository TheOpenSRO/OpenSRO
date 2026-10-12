package session

// Sitting down and standing up (round 607): the N key's request, the 1.5 s
// transition, the broadcast, and the motion state passive regeneration reads.
//
// READ from SR_GameServer.exe (docs/protocol/opcodes/motion.md has the
// addresses in full):
//
//   - 0x704f is handler index 0x04f: the registration at 0x4b0cc8 stores the
//     thunk 0x4b23f0 (`jmp [eax+0x5f4]`) in the table at 0xccf110 + 0x4f*8,
//     and CGObjPC's vtable slot 0x5f4 is 0x4b1450, which reads one u8 and
//     calls GObjPC::FUN_004b1480 with it.
//   - FUN_004b1480 refuses in the CHANGEMOTION state (0x12); a request of
//     4 while SIT becomes 0 (stand), 4 while STAND stays 4 (sit), and 4 from
//     any other state is refused; a request equal to the state is refused.
//     Sit is SetMotionState(CHANGEMOTION, SIT, 1.5) and stand
//     SetMotionState(CHANGEMOTION, STAND, 1.5); 1.5 is `.rdata 0x00b45c10`.
//     Then it broadcasts 0x30bf {id, kind 1, value} with the resolved value
//     (`mov ebx,0x1` at 0x4b15e6, the call to 0x4a8340).
//   - The transition ends when AJStateChanger's record runs out
//     (0x405f70 case 1: SetMotionState(kind, 0xff, 0.0)); that call does not
//     broadcast.
//   - The movement handler (index 0x021 -> slot 0x5e4 -> 0x4b0ea0) refuses a
//     move in states 8, 0x10 and 0x12 only, so a move while SIT is ACCEPTED,
//     and it sets WALK or RUN directly -- SetMotionState(2 + run, 0xff, 0.0)
//     at 0x4b11b6, with no transition and no 0x30bf.
//   - A blow stands a sitter up: Combat_ApplyActionEffects calls
//     FUN_004b1480(0) when the target's motion is SIT (0x593ae8).
//   - The skill-use gate refuses a cast to a seated caster only for the skills
//     that carry 'ao'/'pw' (SIT and CHANGEMOTION among other states, 0x58e0cb)
//     or a kind-1 'msch' (SIT, 0x58ded4), answering 0x3009 -- 59 of the
//     33,660 skill rows (measured). The plain attacks are not refused.
//   - GObjPC::Revive sets STAND (0x4df427).
//
// OURS, disclosed:
//
//   - OpenSRO has no WALK or RUN state on the server: its client streams
//     positions (OpMove) rather than a destination. A character is counted
//     as walking while an accepted OpMove is younger than movingWindow.
//     Round 781: the run flag the Walk/Run request sets is kept
//     (motionEntry.walkMode), and a request of 2 or 3 is judged against the
//     WALK or RUN that flag makes of a mover (walkRunLocked).
//   - The request gates this server does not have the state for are not
//     modelled: vtable slot 0x5a0 (0x4ef880, unread), a running action at
//     +0xc20 and chardata+0xe == 1 (both unread).
//   - A dead character's request is dropped, as every OpenSRO handler drops
//     a dead character's.
//   - What makes a blow stand the sitter is narrowed to a blow that landed
//     damage: the engine also tests the per-target record's +0x10 and status
//     bit 0x40, neither read.
//   - A zone change stands the character (the teleported character is
//     entered anew; the retail object's re-creation is inferred, not read).
//   - The 0x30bf id field is OpenSRO's character id in the retail u32.

import (
	"context"
	"encoding/binary"
	"sync"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/mana"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// The retail opcodes (docs/protocol/PROTOCOL_DECISION.md: real opcodes where
// the payload is read).
const (
	// OpMotionRequest is the client's request, one u8: 4 toggles sit and
	// stand. The retail client sends it from the N key (0x793b00 ->
	// 0x81e750(4)).
	OpMotionRequest uint16 = 0x704F
	// OpStateChange is GObjPC::BroadcastStateChange (0x4a8340): u32 object
	// id, u8 kind, u8 value. Kind 1 is the motion state.
	OpStateChange uint16 = 0x30BF
)

// The MOTIONSTATE values this server uses, named by the engine's own table at
// .rdata 0x00c63f90.
const (
	MotionStand        byte = 0x00 // MOTIONSTATE_STAND
	MotionWalk         byte = 0x02 // MOTIONSTATE_WALK
	MotionRun          byte = 0x03 // MOTIONSTATE_RUN
	MotionSit          byte = 0x04 // MOTIONSTATE_SIT
	MotionChangeMotion byte = 0x12 // MOTIONSTATE_CHANGEMOTION
)

// StateKindMotion is 0x30bf's kind for the motion state: FUN_004b1480's
// broadcast passes 1.
const StateKindMotion byte = 1

// StateKindBodyMode is 0x30bf's kind for CGObjChar::SetBodyMode (0x4a9fc0),
// whose value 1 is berserk and 0 its end (round 629's review). READ from
// GObjPC::BroadcastStateChange (0x4a8340): for kind 4 value 1 it appends one
// more byte, chardata+5, and the client's handler 0x8a80a0 reads that byte
// only then.
const StateKindBodyMode byte = 4

// MotionChangeDuration is the sit/stand transition, `.rdata 0x00b45c10` = 1.5,
// in seconds (the AJStateChanger record is counted down by the update's dt).
const MotionChangeDuration = 1500 * time.Millisecond

// movingWindow is how recent an accepted OpMove must be for the character to
// count as walking. OURS: the client sends a move at most every 0.05 s while it
// moves (World3D.MIN_SEND_INTERVAL), so ten intervals without one is a stop.
const movingWindow = 500 * time.Millisecond

// StateChange is the OpStateChange payload. Extra is the byte a kind-4
// value-1 change carries after the value; it is on the wire only for that
// pair. READ, what it is: chardata+5, which CGObjChar::SetBodyMode (0x4a9fc0)
// sets to its FIFTH argument just before it broadcasts -- the flag that, at
// 1, grants param 189 its 0.3 base (the berserk damage bonus) -- and the
// berserk activation passes 0 there (`push 0x0` at 0x515cc6, the first push
// of SetBodyMode(1, 0, duration, 0)). So OpenSRO's 0 is the activation's own
// value.
type StateChange struct {
	ObjectID uint32
	Kind     byte
	Value    byte
	Extra    byte
}

func (s *StateChange) hasExtra() bool {
	return s.Kind == StateKindBodyMode && s.Value == 1
}

func (s *StateChange) Encode() []byte {
	out := make([]byte, 6)
	binary.LittleEndian.PutUint32(out[0:4], s.ObjectID)
	out[4] = s.Kind
	out[5] = s.Value
	if s.hasExtra() {
		out = append(out, s.Extra)
	}
	return out
}

func DecodeStateChange(data []byte) (*StateChange, bool) {
	if len(data) < 6 {
		return nil, false
	}
	s := &StateChange{ObjectID: binary.LittleEndian.Uint32(data[0:4]), Kind: data[4], Value: data[5]}
	if s.hasExtra() {
		if len(data) < 7 {
			return nil, false
		}
		s.Extra = data[6]
	}
	return s, true
}

// motionEntry is one character's motion: STAND, SIT or CHANGEMOTION (with the
// state it lands on and when), the last accepted move, and the next regen tick.
type motionEntry struct {
	state     byte
	target    byte
	until     time.Time
	lastMove  time.Time
	nextRegen time.Time
	// legEnd is when the character's leg arrives (round 749, destmove.go):
	// it walks until then, as retail's WALK/RUN motion state lasts the move.
	legEnd time.Time
	// walkMode is the mover's run flag cleared (round 781): the action
	// window's Walk/Run request 0x704f [02] set it, [03] cleared it. READ:
	// FUN_004b1480 case 2/3 calls slot 0x4bc (CGObjPC::vslot_303 ->
	// GObjPC::FUN_004aa3c0 -> CGObjMobile::vslot_303) with (value != 2).
	walkMode bool
}

type motionTracker struct {
	mu sync.Mutex
	m  map[int64]*motionEntry
}

var motions = &motionTracker{m: map[int64]*motionEntry{}}

// entryLocked returns characterID's entry, making a standing one first seen
// now, and settles a finished transition.
func (t *motionTracker) entryLocked(characterID int64, now time.Time) *motionEntry {
	e := t.m[characterID]
	if e == nil {
		e = &motionEntry{state: MotionStand, nextRegen: now.Add(mana.RegenInterval)}
		t.m[characterID] = e
	}
	if e.state == MotionChangeMotion && !now.Before(e.until) {
		e.state = e.target
	}
	return e
}

// enter starts characterID afresh: standing, its regen timer at 0 elapsed, as
// the engine's constructor registers it.
func (t *motionTracker) enter(characterID int64, now time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.m[characterID] = &motionEntry{state: MotionStand, nextRegen: now.Add(mana.RegenInterval)}
}

// clear forgets characterID, on disconnect.
func (t *motionTracker) clear(characterID int64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.m, characterID)
}

// stand puts characterID on its feet at once, without a transition: a revive
// (GObjPC::Revive's SetMotionState(STAND)) or a zone change. It reports whether
// the character was sitting or getting up or down.
func (t *motionTracker) stand(characterID int64, now time.Time) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	e := t.entryLocked(characterID, now)
	was := e.state != MotionStand
	e.state = MotionStand
	return was
}

// state is characterID's motion now.
func (t *motionTracker) state(characterID int64, now time.Time) byte {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.entryLocked(characterID, now).state
}

// request is FUN_004b1480 for the requests OpenSRO has: 4 (the toggle) and 0
// (stand, what a blow asks for). It returns the value to broadcast, or false
// when the engine would do nothing.
func (t *motionTracker) request(characterID int64, req byte, now time.Time) (byte, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	e := t.entryLocked(characterID, now)
	cur := e.state
	if cur == MotionChangeMotion {
		return 0, false
	}
	if req == MotionWalk || req == MotionRun {
		return t.walkRunLocked(e, req, now)
	}
	if req == MotionSit {
		switch cur {
		case MotionSit:
			req = MotionStand
		case MotionStand:
		default:
			return 0, false
		}
	} else if req == cur {
		return 0, false
	}
	switch req {
	case MotionStand:
		if cur != MotionSit {
			return 0, false
		}
	case MotionSit:
		if cur != MotionStand {
			return 0, false
		}
	default:
		// 0xc (REQ_HELP) has no OpenSRO state.
		return 0, false
	}
	e.state = MotionChangeMotion
	e.target = req
	e.until = now.Add(MotionChangeDuration)
	return req, true
}

// walkRunLocked is FUN_004b1480 for a request of 2 (walk) or 3 (run), READ
// (0x4b155d, the case 2/3 at the switch): refused when the state equals the
// request, refused unless the state is STAND, WALK or RUN; otherwise slot
// 0x4bc sets the run flag to (value != 2) -- a mover's state becoming WALK or
// RUN with it (GObjPC::FUN_004aa3c0's SetMotionState(2 + run) while slot
// 0x4c0 answers 1), no transition -- and 0x30bf {id, 1, value} goes out.
// OpenSRO counts a mover as STAND (motionEntry.lastMove / legEnd), so its
// WALK or RUN is computed here from the leg and the flag.
func (t *motionTracker) walkRunLocked(e *motionEntry, req byte, now time.Time) (byte, bool) {
	cur := e.state
	if cur == MotionStand && e.moving(now) {
		cur = MotionRun
		if e.walkMode {
			cur = MotionWalk
		}
	}
	if cur == req {
		return 0, false
	}
	if cur != MotionStand && cur != MotionWalk && cur != MotionRun {
		return 0, false
	}
	e.walkMode = req == MotionWalk
	return req, true
}

// moving reports whether the character is on a leg now: an accepted move
// inside movingWindow, or a leg still running (round 749).
func (e *motionEntry) moving(now time.Time) bool {
	return (!e.lastMove.IsZero() && now.Sub(e.lastMove) < movingWindow) || now.Before(e.legEnd)
}

// walking reports whether characterID's run flag is cleared: it moves at its
// walk speed (motionSpeed) and its spawn record says so.
func (t *motionTracker) walkingMode(characterID int64) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	e := t.m[characterID]
	return e != nil && e.walkMode
}

// runAgain sets characterID's run flag back (a zone change, OURS: the retail
// object is re-created by a teleport, INFERRED, and its mover's constructor
// default is the run, pcrecord.go's RunFlag 1; the client resets its own on
// the same change).
func (t *motionTracker) runAgain(characterID int64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if e := t.m[characterID]; e != nil {
		e.walkMode = false
	}
}

// motionSpeed is the speed characterID's legs move at now: the walk speed
// while its run flag is cleared, else its run speed (the buff book's, a GM's
// /speed included). OURS, disclosed: the walk is the base PlayerWalkSpeed
// (param 23, characterdata column 46); no buff OpenSRO models changes it.
func motionSpeed(characterID int64) float64 {
	if motions.walkingMode(characterID) {
		return PlayerWalkSpeed
	}
	return float64(buffBooks.RunSpeed(characterID))
}

// setWall is EngageSkill's SetMotionState(0x11, 0xff, 0) for a 'pw' row
// (round 640, walls.go): SKILL_PROTECTIONWALL at once, no transition.
func (t *motionTracker) setWall(characterID int64, now time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.entryLocked(characterID, now).state = MotionProtectionWall
}

// endWall is the wall's end's SetMotionState(0, 0xff, 0): STAND, when the
// character is still in SKILL_PROTECTIONWALL. A move since the wall went up
// has already left the state (the movement handler's SetMotionState(WALK or
// RUN), `moved`), and OpenSRO counts a walker as standing, so a character in
// any other state is left as it is.
func (t *motionTracker) endWall(characterID int64, now time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if e := t.m[characterID]; e != nil && e.state == MotionProtectionWall {
		e.state = MotionStand
	}
}

// moved records an OpMove. It is refused in the transition, as the movement
// handler refuses state 0x12, and (round 640, OURS) while a wall roots the
// character; otherwise a sitter is on its feet at once (the
// handler's SetMotionState(WALK/RUN)) and the move is accepted. leftSit
// reports that it was sitting.
func (t *motionTracker) moved(characterID int64, now time.Time) (accepted, leftSit bool) {
	// Round 640, OURS (the user's request, not in retail's binaries): a
	// character its own protection wall holds does not move (walls.go
	// wallRoots). Refused like the transition: nothing stored, nothing
	// relayed, no answer.
	if wallRoots(characterID) {
		return false, false
	}
	return t.movedUnrooted(characterID, now)
}

// movedUnrooted is moved without the wall's root (round 646): a warp's own
// landing (walls.go warpLandingAdmits) is taken while the wall stands.
func (t *motionTracker) movedUnrooted(characterID int64, now time.Time) (accepted, leftSit bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	e := t.entryLocked(characterID, now)
	if e.state == MotionChangeMotion {
		return false, false
	}
	leftSit = e.state == MotionSit
	e.state = MotionStand
	e.lastMove = now
	return true, leftSit
}

// walking records that characterID's leg runs until `until` (round 749): an
// accepted 0x7021 sets it to the leg's arrival, a stop to the stop's time.
func (t *motionTracker) walking(characterID int64, until time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.entryLocked(characterID, time.Now()).legEnd = until
}

// regenRate is the 'hprg'/'mprg' a tick would use now, and false when the tick
// does nothing in this motion state: only STAND and SIT regenerate.
func (t *motionTracker) regenRate(characterID int64, now time.Time) (float32, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	e := t.entryLocked(characterID, now)
	switch e.state {
	case MotionSit:
		return mana.SitRegenPercent, true
	case MotionStand:
		if !e.lastMove.IsZero() && now.Sub(e.lastMove) < movingWindow {
			return 0, false // walking or running
		}
		if now.Before(e.legEnd) {
			return 0, false // a leg still running (round 749)
		}
		return mana.StandRegenPercent, true
	default:
		return 0, false
	}
}

// regenDue reports whether characterID's 4 s timer fires at now, advancing it
// by one interval when it does -- the list tick's `elapsed -= interval`, at most
// one fire a pass. A timer that has fallen more than an interval behind (a
// stalled loop) restarts from now rather than firing a burst.
func (t *motionTracker) regenDue(characterID int64, now time.Time) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	e := t.entryLocked(characterID, now)
	if now.Before(e.nextRegen) {
		return false
	}
	e.nextRegen = e.nextRegen.Add(mana.RegenInterval)
	if !now.Before(e.nextRegen) {
		e.nextRegen = now.Add(mana.RegenInterval)
	}
	return true
}

// seatedCastRefused is the skill-use gate's motion-state test for a skill
// whose SitGate is gate (refdata.Skill.SitGate), read in
// Skill_CheckUseConditions (0x58d8f0):
//
//   - SitGateActionOff (the skill carries 'ao' at +0x274 or 'pw' at +0x2b4):
//     for a PC, refused in SIT, CHANGEMOTION, KNOCKDOWN, SKILL_ACTIONOFF and
//     SKILL_PROTECTIONWALL (0x58e0a0..0x58e0ed). OpenSRO has SIT,
//     CHANGEMOTION and, since round 640, SKILL_PROTECTIONWALL (walls.go).
//   - SitGateTransform ('msch' value[0] == 1, +0x4a4): refused in SIT
//     (0x58de46..0x58ded4); the same branch also refuses when vtable slot
//     0x540 or the state changer's test 0x406750(1) answers non-zero, neither
//     read nor modelled.
//
// Any other skill -- the plain attacks included -- is not refused for its
// caster's motion state, and nothing in the cast stands the caster up (the only
// callers of FUN_004b1480 are the 0x704f handler, the stall, the open market
// and the blow on a target).
func seatedCastRefused(gate int, characterID int64, now time.Time) bool {
	if gate == 0 {
		return false
	}
	s := motions.state(characterID, now)
	if gate&refdata.SitGateActionOff != 0 && (s == MotionSit || s == MotionChangeMotion || s == MotionProtectionWall) {
		return true
	}
	return gate&refdata.SitGateTransform != 0 && s == MotionSit
}

// seatedRefusal is the AttackResult error for a cast the gate refuses. The
// engine answers 0x3009, whose client string was not identified; the wording
// is ours.
const seatedRefusal = "cannot use that skill while sitting"

// broadcastMotion sends 0x30bf {id, kind 1, value} to everyone in the
// character's zone, the character included -- the engine's broadcast reaches
// the requester's own client too, which is the only way it learns (0x8a80a0).
//
// Round 737: "everyone" is the players in view that hold the character
// (playerview.go, sendAboutPlayer); one arriving later learns the motion
// from its spawn record's motion byte.
func broadcastMotion(hub *world.Hub, e world.Entity, value byte) {
	msg := (&StateChange{ObjectID: uint32(e.CharacterID), Kind: StateKindMotion, Value: value}).Encode()
	bumpPlayerState(e.CharacterID)
	sendAboutPlayerPacket(hub, e.CharacterID, true, OpStateChange, msg)
}

// standOnHit is Combat_ApplyActionEffects' FUN_004b1480(0) for a sitter: a
// blow that landed damage on characterID stands it up through the transition,
// and the zone hears it. Nothing happens unless it is sitting.
func standOnHit(hub *world.Hub, characterID int64, damage int) {
	if hub == nil || damage <= 0 {
		return
	}
	now := time.Now()
	if motions.state(characterID, now) != MotionSit {
		return
	}
	value, ok := motions.request(characterID, MotionStand, now)
	if !ok {
		return
	}
	if e, found := hub.EntityByCharacterID(characterID); found {
		broadcastMotion(hub, e, value)
	}
}

// sittingOrSittingDown reports whether characterID is SIT or in the
// transition that lands on SIT.
func (t *motionTracker) sittingOrSittingDown(characterID int64, now time.Time) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	e, ok := t.m[characterID]
	if !ok {
		return false
	}
	if e.state == MotionChangeMotion && !now.Before(e.until) {
		e.state = e.target
	}
	return e.state == MotionSit || (e.state == MotionChangeMotion && e.target == MotionSit)
}

// MotionHandler answers OpMotionRequest: the N key (4), and the action
// window's Walk/Run (2 / 3, round 781).
func MotionHandler(hub *world.Hub) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpMotionRequest {
			return nil
		}
		if len(p.Data) < 1 || hub == nil {
			return nil
		}
		e, ok := hub.EntityBySession(sess.ID())
		if !ok || e.Life != world.LifeAlive {
			return nil
		}
		now := time.Now()
		value, ok := motions.request(e.CharacterID, p.Data[0], now)
		if !ok {
			return nil
		}
		// The engine sits down from a walk by stopping first (slot 0x4b0);
		// here the client stops itself before it asks, and reports a stop
		// short of its destination first. A leg the server still runs (the
		// client stopped within its stop distance and asked before the
		// server's leg arrived) ends where the server has it, and the window
		// hears that 0xB023 (round 749, destmove.go). A running auto-attack
		// ends: the client does not send N while an action runs (its state-2
		// gate), so a sitter has none.
		// Walk and run (round 781) stop nothing: the engine's case 2/3 only
		// sets the run flag, and a leg in progress goes on at the new speed
		// (moverSpeed re-bases it on the next pass).
		if value != MotionWalk && value != MotionRun {
			haltForSit(sess, hub)
			keepUp.Cancel(e.CharacterID)
		}
		broadcastMotion(hub, e, value)
		return nil
	}
}
