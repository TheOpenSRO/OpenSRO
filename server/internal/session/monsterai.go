package session

import (
	"context"
	"fmt"
	"log/slog"
	"math"
	"math/rand"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/ai"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// The monster AI tick (round 537): the runtime that drives internal/ai's
// state machine over the live monsters, behind cmd/server's -monster-ai kill
// switch (SRREVAMP_MONSTER_AI), which is OFF by default. With it off
// RunMonsterAI is never called, monsterAIRuntime stays nil, noteStruck does
// nothing and the monster list is answered exactly as before, byte for byte.
//
// With it on, every monster runs SPAWN -> IDLE, rolls WANDER or another IDLE
// when its idle spell ends (CAIState_IDLE::OnMsg_0x25, 76 of 100 wander),
// walks each leg at its walk speed and pushes it to its zone as an
// OpMonsterMoved (monstermove.go), runs home (HOMING) once it strays past the
// roam radius, and -- the interim hold -- stands still where a player's blow
// found it while a keep-up of any player in its zone is on it (round 539; the
// first attacker's only in round 537). The rules are internal/ai's,
// each cited where it is defined; the runtime's own choices are the stand-ins
// in docs/protocol/monster_ai.md, "srrevamp's runtime", and each is marked
// OWN DESIGN at the line that makes it.

// MonsterAITick is how often the runtime steps the monsters and runs their
// states. OWN DESIGN: the engine's AI period is unread; the one period read
// on this path is CGObjChar::Update's 30 ms floor for an actor (keepup.go's
// clampDelay). A dwell is therefore honoured to within one tick.
const MonsterAITick = 100 * time.Millisecond

// MonsterRoamRadius is the roam radius every placement is given, measured
// from its spawn point under roam rule 0 (ai.WithinRoamRadius). OWN DESIGN and
// a user decision: it is the number AI::CTactics::Attach (0x0053f2a0) stores
// at ctx+0x1cc (the float 200.0 at 0xb45d68, `fld` at 0x53f367) when there is
// no nest, no caller radius and the tactics row's +0x84 (column 38) is not
// positive -- and exactly then AITactics_IsWithinRoamRadius (0x00545f70)
// answers "within" without measuring (`cmp [row+0x84],0; jg` at 0x545fde)
// unless the owner's slot 242 or 243 answers non-zero. So retail never
// applies 200 to such a monster. The real per-nest radius is _RefNest column
// 9 (+0x20), which is server-database only; srrevamp treats each placement as
// a nest with this radius.
const MonsterRoamRadius = 200.0

// MonsterHoldReleaseTicks is how many ticks in a row the interim hold's
// release must find no keep-up on a held monster, with no blow drained on it
// in between, before it lets the monster go (round 539). OWN DESIGN, the
// hold's second half: 2, so the release waits out one whole MonsterAITick
// after it first finds none.
//
// Both request paths leave a gap in which a monster that is still being
// fought has no keep-up on it. An OpAttack notes its blow inside
// performAttack (noteStruck) and arms the keep-up only after performAttack
// returns, past the weapon wear, the counterattack and the reply
// (combatHandler's armKeepUp). A cast cancels the keep-up before its blow
// (useSkillHandler's keepUp.Cancel) and re-arms it only at the hand-off,
// after performAttack. Round 537's release -- the first tick that found no
// keep-up -- let a tick landing in either gap release the monster to IDLE,
// and IDLE's roam check sends one strayed past the radius home at its run
// speed until the next blow stops it. Now an OpAttack's gap must outlast
// two tick periods from the blow, and a cast's must outlast one period from
// its Cancel to its blow (the drained blow restarts the count) or two from
// its blow to the re-arm, before either releases the monster.
const MonsterHoldReleaseTicks = 2

// MonsterAIConfig is what the operator sets on the runtime.
type MonsterAIConfig struct {
	// Trace logs every state change, leg, strike, release and out-of-reach
	// keep-up end (SRREVAMP_AI_TRACE). Off by default: at about 350 monsters
	// in Jangan it is several lines a second.
	Trace bool
}

// monsterAIRuntime is the running monster AI, nil while -monster-ai is off.
// An atomic pointer rather than a plain variable: RunMonsterAI stores it on
// the boot goroutine while session readers and keep-up goroutines load it
// (noteStruck, handleMonsterList, the keep-up trace), and each reader loads it
// once into a local.
var monsterAIRuntime atomic.Pointer[monsterAI]

// monsterAI is the runtime's state.
type monsterAI struct {
	// mu serialises the tick's pass -- from StepAll to the last push it
	// collects -- with noteStruck, so a blow's stop and the struck record
	// land wholly before or wholly after a pass. Nothing is sent under it.
	mu sync.Mutex
	// struck holds the blows since the last tick, keyed by monster id,
	// keeping the FIRST attacker. It is drained every tick and so holds at
	// most one entry per live monster; there is no queue.
	struck map[int64]struckEvent

	// wireMu guards only the creation of a session's wire lock (wireLock).
	wireMu sync.Mutex

	// The rest belongs to the tick (monsterAITick), which holds mu while it
	// touches it.
	brains     map[int64]*brain
	rng        *rand.Rand
	monsters   *combat.Hub
	world      *world.Hub
	push       func(zone string, p *proto.Packet)
	logger     *slog.Logger
	trace      bool
	roamRadius float64
	last, now  time.Time
	tickN      uint64
	pending    []monsterPush
}

// struckEvent is a blow the tick has not seen yet.
type struckEvent struct {
	attacker int64 // the character who struck first
	// wasMoving is whether the blow stopped the monster mid-leg (noteStruck),
	// so the tick owes the zone one stop push.
	wasMoving bool
}

// brain is one monster's AI.
type brain struct {
	id      int64
	m       combat.Monster // as of this tick, refreshed after every move
	machine *ai.Machine
	// heading is the unit heading the engine keeps at the owner's
	// +0x24/+0x2c, in radians from +x toward +z: the one the monster hatched
	// facing at first (combat.Monster.Heading, Nest_Hatch's ai.SpawnHeading
	// rolled at the spawn since round 542, so OpMonsterSpawned and the brain
	// agree), then each leg's direction.
	heading float64
	// enteredAt and dwellMs are the state's +0x10 and +0x14
	// (CAIState::OnEnter 0x00558b70).
	enteredAt time.Time
	dwellMs   int
	// target is the character id SetTarget (0x0053ffe0) holds, 0 for none.
	target int64
	// lastBlowTick is the last tick that drained a blow on this monster
	// (BATTLE's entry among them); the hold's release tests skip that tick.
	lastBlowTick uint64
	// unheldTicks counts the ticks in a row BATTLE found no keep-up on the
	// monster since the last blow (MonsterHoldReleaseTicks).
	unheldTicks int
	// homingDestX/Z is where HOMING is walking (MoveHome 0x00545c50).
	homingDestX, homingDestZ float64
}

// monsterPush is one push collected during a pass, sent after it.
type monsterPush struct {
	zone   string
	packet *proto.Packet
}

// RunMonsterAI installs the monster AI before it returns, then ticks it every
// MonsterAITick on its own goroutine until ctx ends. cmd/server calls it only
// with -monster-ai on, before the gateway starts serving.
func RunMonsterAI(ctx context.Context, hub *world.Hub, monsters *combat.Hub, logger *slog.Logger, cfg MonsterAIConfig) {
	a := newMonsterAI(hub, monsters, logger, cfg, rand.New(rand.NewSource(time.Now().UnixNano())), nil)
	monsterAIRuntime.Store(a)
	go a.run(ctx)
}

func (a *monsterAI) run(ctx context.Context) {
	ticker := time.NewTicker(MonsterAITick)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			monsterAITick(now)
		}
	}
}

// newMonsterAI builds a runtime. push nil means the zone broadcast
// (monsterAI.broadcast); a test passes a recorder.
func newMonsterAI(hub *world.Hub, monsters *combat.Hub, logger *slog.Logger, cfg MonsterAIConfig, rng *rand.Rand, push func(zone string, p *proto.Packet)) *monsterAI {
	a := &monsterAI{
		struck:     map[int64]struckEvent{},
		brains:     map[int64]*brain{},
		rng:        rng,
		monsters:   monsters,
		world:      hub,
		logger:     logger,
		trace:      cfg.Trace,
		roamRadius: MonsterRoamRadius,
	}
	a.push = push
	if a.push == nil {
		a.push = a.broadcast
	}
	return a
}

// noteStruck records that characterID's blow landed on monsterID and the
// monster survived it. performAttack calls it for every surviving blow -- a
// click, a keep-up repeat or a cast -- and it is a no-op while the monster AI
// is off, or for a hub the runtime does not drive.
//
// It also stops the monster where it stands, AT THE BLOW, in the hub only;
// nothing is sent from the request path. OWN DESIGN, the interim hold's first
// half: were the monster to keep its leg until the tick drained the blow, it
// would walk up to MonsterAITick x speed further first (0.8 units for a
// Mangyang, 2.2 while HOMING at 22), enough to carry a monster struck at the
// edge of reach out of it and end the player's keep-up (keepup.go's reach
// test). The tick then sends the one stop push the zone is owed.
//
// A narrower drift remains, disclosed rather than closed (round 537's review,
// re-checked in round 539): the OpAttack handler measures the reach
// (firstSwingInReach) without this lock, and this stop comes only after
// performAttack's ApplyDamage. A tick whose StepAll lands between the two
// still moves the monster up to MonsterAITick x speed before the stop -- so
// one struck at the very edge of reach can still leave it. The window is the
// handler's own work between the two calls, not a tick. Closing it means
// stopping the monster at the reach test, before the swing is known to be
// ready or to land, which would stop monsters for clicks that deal nothing.
func noteStruck(monsters *combat.Hub, monsterID, characterID int64) {
	a := monsterAIRuntime.Load()
	if a == nil || monsters == nil || monsters != a.monsters {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	moving := false
	if m, ok := monsters.Get(monsterID); ok && m.Moving {
		monsters.StopMotion(monsterID)
		moving = true
	}
	ev, seen := a.struck[monsterID]
	if !seen {
		ev.attacker = characterID
	}
	ev.wasMoving = ev.wasMoving || moving
	a.struck[monsterID] = ev
}

// monsterAITick is one pass of the installed runtime at now, which tests
// drive with their own clock. Nothing when the monster AI is off.
func monsterAITick(now time.Time) {
	if a := monsterAIRuntime.Load(); a != nil {
		a.tick(now)
	}
}

// tick steps the monsters, reconciles the brains, drains the blows, runs
// each brain once, and only then -- outside every lock -- sends what the pass
// collected. Brains run in monster-id order so a seeded rng replays.
func (a *monsterAI) tick(now time.Time) {
	a.mu.Lock()
	dt := 0.0
	if !a.last.IsZero() && now.After(a.last) {
		dt = now.Sub(a.last).Seconds()
	}
	a.last, a.now = now, now
	a.tickN++

	// 1. The mover (combat.MoverStep: the 160 cap and the no-overshoot clamp).
	a.monsters.StepAll(dt)

	// 2. A brain per live monster. A new one faces the heading it hatched
	// with (combat.Monster.Heading) and leaves SPAWN at once: message 0x21's
	// default transition is IDLE. OWN DESIGN: SPAWN::OnUpdate's timing is
	// unread, so it leaves on the first tick that sees it.
	live := a.monsters.All()
	sort.Slice(live, func(i, j int) bool { return live[i].ID < live[j].ID })
	seen := make(map[int64]bool, len(live))
	for _, m := range live {
		seen[m.ID] = true
		if b := a.brains[m.ID]; b != nil {
			b.m = m
			continue
		}
		b := a.newBrain(m)
		a.brains[m.ID] = b
		a.dispatch(b, ai.MsgSpawned)
	}
	for id := range a.brains {
		if !seen[id] {
			delete(a.brains, id)
		}
	}

	// 3. The blows.
	struck := a.struck
	a.struck = map[int64]struckEvent{}
	for _, id := range sortedIDs(struck) {
		a.onStruck(id, struck[id])
	}

	// 4. Each brain once.
	for _, m := range live {
		if b := a.brains[m.ID]; b != nil {
			a.update(b)
		}
	}

	pending := a.pending
	a.pending = nil
	a.mu.Unlock()

	// 5. The pushes, after the pass.
	for _, p := range pending {
		a.push(p.zone, p.packet)
	}
}

// sortedIDs is the keys of a blow set in ascending order.
func sortedIDs(m map[int64]struckEvent) []int64 {
	ids := make([]int64, 0, len(m))
	for id := range m {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	return ids
}

// onStruck is CAIState::OnAttacked (0x00558ea0) for a blow the tick drains:
// SetTarget with push 1 (0x0053ffe0, called at 0x558eef), then ChangeState(3)
// (`lea edi,[ebx+3]` at 0x558f01 into 0x0053ff30) -- no aggression or range
// test. Not modelled: the aggro link (behaviour +0xf0, the call at 0x558ebb)
// and the attacker accounting's refusal (behaviour +0xec,
// AITactics_CreditAttacker 0x005473c0, the test at 0x558edd). A monster
// already in BATTLE ignores the blow: OWN DESIGN, the rule-0 stand-in for
// CAIState_BATTLE::OnAttacked (0x0055a2e0 -> behaviour +0xfc), which under
// the tactics row's rule 0 keeps the first attacker. Every drained blow, one
// on a monster already in BATTLE included, restarts the hold's release count
// (MonsterHoldReleaseTicks).
func (a *monsterAI) onStruck(id int64, ev struckEvent) {
	b := a.brains[id]
	if b == nil {
		return // killed since the blow
	}
	if ev.wasMoving {
		// noteStruck stopped it at the blow; the zone still sees it walking.
		a.queueStop(b.m)
	}
	b.lastBlowTick, b.unheldTicks = a.tickN, 0
	if st := b.machine.State(); st == ai.StateBattle || st.Terminal() {
		return
	}
	b.target = ev.attacker
	a.tracef("ai: monster %d struck by %d, holding", id, ev.attacker)
	a.change(b, ai.StateBattle)
}

// update is one state's OnUpdate.
func (a *monsterAI) update(b *brain) {
	elapsed := int(a.now.Sub(b.enteredAt) / time.Millisecond)
	switch b.machine.State() {
	case ai.StateIdle:
		// CAIState::OnUpdate's expiry (0x00558b90) dispatches 0x25, which IDLE
		// overrides with the roll (slot 41, CAIState_IDLE::OnMsg_0x25
		// 0x00559cf0): another idle spell, or WANDER.
		if ai.DwellExpired(b.dwellMs, elapsed) {
			a.change(b, ai.IdleNext(a.rng))
		}
	case ai.StateWander:
		// CAIState_WANDER::OnUpdate (0x00559eb0): the expiry dispatches 0x25
		// (0x559ec9), whose default is IDLE -- the leg is NOT stopped; then,
		// for a monster that can run, the roam check sends 0x26 (0x559f38..
		// 0x559f65). The acquire (+0xf8) and +0x108 calls between them are
		// not modelled.
		if ai.DwellExpired(b.dwellMs, elapsed) {
			a.dispatch(b, ai.MsgInterrupted)
			return
		}
		if b.m.RunSpeed > 0 && !a.withinRoam(b) {
			a.dispatch(b, ai.MsgReturnHome)
		}
	case ai.StateHoming:
		// CAIState_HOMING::OnUpdate (0x0055a690): the 50 s expiry dispatches
		// 0x25 (0x55a6a8) -> IDLE; AITactics_HomingStep (behaviour +0x118,
		// 0x005496c0) reports arrival (AITactics_HasArrived 0x00541f60, under
		// 5.0) -> 0x24 -> IDLE. OWN DESIGN: HOMING walks one straight leg
		// (below) and the step is tested every tick; the step's heading wobble
		// and the re-aggro window are not modelled.
		if ai.DwellExpired(b.dwellMs, elapsed) {
			a.dispatch(b, ai.MsgInterrupted)
			return
		}
		if ai.HasArrived(b.m.X, b.m.Z, b.homingDestX, b.homingDestZ) {
			a.dispatch(b, ai.MsgArrived)
		}
	case ai.StateBattle:
		// BATTLE has no dwell (ai.BattleDwellMs), so nothing expires it. Not
		// on a tick that drained a blow on it, its entry among them:
		if b.lastBlowTick == a.tickN {
			return
		}
		// The target must still be in the world and in this zone: the
		// engine's 0x23 exit, when CAIState_BATTLE::OnUpdate (0x0055a090)
		// finds its target invalid through FUN_00540dc0 (which wraps
		// FUN_00540de0's alive and life-state-1 tests). srrevamp's validity
		// test is its own, disclosed: in world.Hub, same zone.
		var e world.Entity
		ok := false
		if a.world != nil {
			e, ok = a.world.EntityByCharacterID(b.target)
		}
		// Only the first attacker is the target (the rule-0 stand-in in
		// onStruck), so when that player leaves, the monster goes by this
		// exit even while another player's keep-up is on it; that player's
		// next blow holds it again. In between, IDLE's roam check sends one
		// strayed past the radius home. Disclosed (round 539): the engine's
		// retarget is the threat table's (mob-threat-retarget).
		if !ok || e.Zone != b.m.Zone {
			a.tracef("ai: monster %d released (%s)", b.id, "target gone")
			a.dispatch(b, ai.MsgCombatEnded)
			return
		}
		// OWN DESIGN, the interim hold's release: the monster stays while
		// any player in its zone has a keep-up on it -- not only the first
		// attacker's (round 539: with two players on one monster it was
		// released when the first one's keep-up ended) -- and goes only once
		// MonsterHoldReleaseTicks ticks in a row have found none.
		// mob-battle-chase replaces this with the chase and the engine's own
		// exits.
		if a.keptUpOn(b) {
			b.unheldTicks = 0
			return
		}
		b.unheldTicks++
		if b.unheldTicks < MonsterHoldReleaseTicks {
			return
		}
		a.tracef("ai: monster %d released (%s)", b.id, "keep-up ended")
		a.change(b, ai.StateIdle)
	}
}

// keptUpOn reports whether any player in b's zone has a keep-up running
// against it (keepUp.Target), the hold's release test. Only players this
// runtime's world hub places in the monster's zone count: a keep-up whose
// attacker is elsewhere ends at its next swing anyway (armKeepUp's zone test).
func (a *monsterAI) keptUpOn(b *brain) bool {
	if a.world == nil {
		return false
	}
	for _, e := range a.world.EntitiesInZone(b.m.Zone) {
		if t, ok := keepUp.Target(e.CharacterID); ok && t == b.id {
			return true
		}
	}
	return false
}

// newBrain builds a monster's machine in SPAWN (AI::CTactics::Init's one
// ChangeState(0), ai.NewMachine) with the four states the runtime runs. It
// adopts the heading the monster hatched with (combat.Monster.Heading, rolled
// at the spawn by the hub's Nest_Hatch roll) rather than rolling its own:
// until round 542 it drew ai.SpawnHeading here, a heading nothing outside the
// brain knew, so a spawn push could not have carried it.
func (a *monsterAI) newBrain(m combat.Monster) *brain {
	b := &brain{id: m.ID, m: m, heading: m.Heading}
	var states [ai.StateCount]ai.Enterer
	states[ai.StateIdle] = &brainState{a: a, b: b, state: ai.StateIdle, enter: func() { a.enterIdle(b) }}
	states[ai.StateWander] = &brainState{a: a, b: b, state: ai.StateWander, enter: func() { a.enterWander(b) },
		refuses: func() bool { return !(b.m.RunSpeed > 0) }}
	states[ai.StateBattle] = &brainState{a: a, b: b, state: ai.StateBattle, enter: func() { a.enterBattle(b) }}
	states[ai.StateHoming] = &brainState{a: a, b: b, state: ai.StateHoming, enter: func() { a.enterHoming(b) }}
	b.machine = ai.NewMachine(states)
	return b
}

// brainState adapts one of a brain's states to ai.Enterer.
type brainState struct {
	a     *monsterAI
	b     *brain
	state ai.State
	enter func()
	// refuses is the state's OnEnter refusal, tested before the base OnEnter
	// runs (WANDER's, 0x00559df0..0x00559e30).
	refuses func() bool
}

// OnEnter is slot 2: the refusal, then CAIState::OnEnter (0x00558b70:
// enteredAt = now, timeout = 0), then the state's own body.
func (s *brainState) OnEnter(from ai.State) bool {
	if s.refuses != nil && s.refuses() {
		return false
	}
	s.a.tracef("ai: monster %d %s->%s", s.b.id, from, s.state)
	s.b.enteredAt, s.b.dwellMs = s.a.now, 0
	s.enter()
	return true
}

// OnLeave is slot 4. BATTLE's override (0x0055a240) is not modelled; the
// base is `return 0`.
func (s *brainState) OnLeave(ai.State) {}

// change is AI::CTactics::ChangeState (0x0053ff30), refusal fallback and
// all (ai.Machine). The states asked for here are constants, always valid.
func (a *monsterAI) change(b *brain, next ai.State) {
	if _, err := b.machine.ChangeState(next); err != nil && a.logger != nil {
		a.logger.Warn("ai: state change refused", "monster", b.id, "state", next, "err", err)
	}
}

// dispatch is CAIState::Dispatch (0x005597b0) for a message whose handler
// the current state does not override: the message's default transition.
func (a *monsterAI) dispatch(b *brain, msg ai.Message) {
	if next, ok := msg.DefaultTransition(); ok {
		a.change(b, next)
	}
}

// withinRoam is AITactics_IsWithinRoamRadius (0x00545f70) from the spawn
// point, rule 0, MonsterRoamRadius (OWN DESIGN, see there).
func (a *monsterAI) withinRoam(b *brain) bool {
	return ai.WithinRoamRadius(b.m.HomeX, b.m.HomeZ, b.m.X, b.m.Z, a.roamRadius, 0)
}

// enterIdle is CAIState_IDLE::OnEnter (0x00559c80): the dwell
// (AIState_DwellMs at 0x559c9e), SetTarget(0) (0x559cad) and, for a monster
// that can run (`fldz; fcomp [owner+0x170]`, 0x559cb5..0x559cc5), the roam
// check (0x559cca) with 0x26 when it has strayed (0x559cdf). It does NOT stop
// a leg under way: nothing in 0x559c80..0x559ce8 touches the mover.
func (a *monsterAI) enterIdle(b *brain) {
	b.dwellMs = ai.DwellMs(a.rng, ai.StateIdle)
	b.target = 0
	if b.m.RunSpeed > 0 && !a.withinRoam(b) {
		a.dispatch(b, ai.MsgReturnHome)
	}
}

// enterWander is CAIState_WANDER::OnEnter (0x00559df0) past its refusal
// (brainState.refuses: run speed not above 0; the COS-not-mercenary refusal
// is not modelled, no roster species is a COS): SetTarget(0) (0x559e4c), the
// leg (PickWanderLeg at 0x559e63), its dwell (AIState_DwellMs(2) at 0x559e72,
// or 1000 ms with no leg: `mov ebp,0x3e8` at 0x559e5e, stored at 0x559e9b),
// the clip (FUN_00541820 at 0x559e82 -> AITactics_Handler_110) and the move
// (FUN_00541730 at 0x559e95).
func (a *monsterAI) enterWander(b *brain) {
	b.target = 0
	destX, destZ, _, ok := ai.PickWanderLeg(a.rng, b.m.X, b.m.Z, b.heading, b.m.RunSpeed)
	if !ok {
		b.dwellMs = ai.WanderNoLegTimeoutMs
		return
	}
	b.dwellMs = ai.DwellMs(a.rng, ai.StateWander)
	a.startLeg(b, destX, destZ, ai.MotionMode(ai.StateWander, b.m.WalkSpeed, b.m.RunSpeed))
}

// enterHoming is CAIState_HOMING::OnEnter (0x0055a540): the dwell
// (AIState_DwellMs at 0x55a5f1, the 50 000 ms default arm), MoveHome
// (0x55a602, ai.HomeDestination with MonsterRoamRadius), the clip
// (FUN_00541820 at 0x55a64a: Handler_110 gives 1, the run clip, for HOMING)
// and SetTarget(0) (0x55a67a). Not modelled: the timer armed at 0x55a5e0,
// the re-aggro window (+0x1c) and the +0x164 sign.
func (a *monsterAI) enterHoming(b *brain) {
	b.dwellMs = ai.DwellMs(a.rng, ai.StateHoming)
	b.homingDestX, b.homingDestZ = ai.HomeDestination(a.rng, b.m.HomeX, b.m.HomeZ, b.m.X, b.m.Z, a.roamRadius)
	a.startLeg(b, b.homingDestX, b.homingDestZ, ai.MotionMode(ai.StateHoming, b.m.WalkSpeed, b.m.RunSpeed))
	b.target = 0
}

// enterBattle is CAIState_BATTLE::OnEnter (0x00559fb0), which calls only the
// base OnEnter for its timeout: none (ai.BattleDwellMs). Its timers, clip,
// gathering and slot-11 call are not modelled. OWN DESIGN, the interim hold:
// a monster still on a leg is stopped here with one stop push. The engine's
// BATTLE::OnEnter issues no stop -- its chase replaces the leg, which is
// mob-battle-chase. A monster struck mid-leg was already stopped at the blow
// (noteStruck), so this finds it standing.
func (a *monsterAI) enterBattle(b *brain) {
	b.dwellMs = ai.BattleDwellMs
	b.unheldTicks = 0
	if b.m.Moving {
		if m, ok := a.monsters.StopMotion(b.id); ok {
			b.m = m
			a.queueStop(m)
		}
	}
}

// startLeg starts a leg to (destX, destZ) in clip mode (0 walk, 1 run) and
// queues its push. The speed follows the mode: the walk speed for 0, the run
// speed for 1 -- an inference (docs/protocol/monster_ai.md, "srrevamp's own
// monster protocol": the mover's use of +0x155/+0x174 is untraced). The
// heading turns toward the destination, as the move's start does
// (CGObjMoverByDest 0x0048c330 -> its slot 10, 0x0048c660, SetHeading).
func (a *monsterAI) startLeg(b *brain, destX, destZ float64, mode uint8) {
	speed := b.m.WalkSpeed
	if mode != 0 {
		speed = b.m.RunSpeed
	}
	m, ok := a.monsters.SetMotion(b.id, destX, destZ, speed, mode)
	if !ok {
		return
	}
	if dx, dz := destX-m.X, destZ-m.Z; dx != 0 || dz != 0 {
		b.heading = math.Atan2(dz, dx)
	}
	b.m = m
	a.queue(m.Zone, &MonsterMoved{
		MonsterID: m.ID, X: float32(m.X), Z: float32(m.Z),
		DestX: float32(destX), DestZ: float32(destZ), Speed: float32(speed), Mode: mode,
	})
	a.tracef("ai: monster %d leg to (%.0f,%.0f) speed %.0f mode %d", m.ID, destX, destZ, speed, mode)
}

// queueStop queues the stop push for a monster standing at m's position:
// destination = position, with the leg's own speed and mode
// (docs/protocol/monster_ai.md, "srrevamp's own monster protocol", the stop).
func (a *monsterAI) queueStop(m combat.Monster) {
	a.queue(m.Zone, &MonsterMoved{
		MonsterID: m.ID, X: float32(m.X), Z: float32(m.Z),
		DestX: float32(m.X), DestZ: float32(m.Z), Speed: float32(m.MoveSpeed), Mode: m.MoveMode,
	})
}

func (a *monsterAI) queue(zone string, mv *MonsterMoved) {
	a.pending = append(a.pending, monsterPush{zone: zone, packet: &proto.Packet{Opcode: OpMonsterMoved, Data: mv.Encode()}})
}

// broadcast is the default push: every session in the zone, each under its
// wire lock. OWN DESIGN: zone-wide, no interest management. A stalled client
// blocks the send, as RunRegen's do (gateway.Session.Send has no write
// deadline); the kill switch is the mitigation.
func (a *monsterAI) broadcast(zone string, p *proto.Packet) {
	if a.world == nil {
		return
	}
	for _, e := range a.world.EntitiesInZone(zone) {
		if e.Session == nil {
			continue
		}
		l := a.wireLock(e.Session)
		l.Lock()
		_ = e.Session.Send(p)
		l.Unlock()
	}
}

// monsterWireKey is where a session keeps its wire lock.
const monsterWireKey = "session.monsterAIWire"

// wireLock is sess's motion-wire lock. The tick holds it while it writes a
// push to sess, and handleMonsterList holds it from reading the hub until
// both of its replies are written, so a push for a newer leg can never reach
// a client ahead of a list built before that leg began: the client would take
// the list's older destination last and walk the body there (round 537).
// Per session, so a stalled client holds up only its own replies and the
// tick, never another session's reader. It lives on the session and goes
// with it.
func (a *monsterAI) wireLock(sess *gateway.Session) *sync.Mutex {
	a.wireMu.Lock()
	defer a.wireMu.Unlock()
	if v, ok := sess.Get(monsterWireKey); ok {
		if l, ok := v.(*sync.Mutex); ok {
			return l
		}
	}
	l := &sync.Mutex{}
	sess.Set(monsterWireKey, l)
	return l
}

// motionListOf is the OpMonsterMotionList for a list's monsters: the legs of
// those still walking one.
func motionListOf(listed []combat.Monster) *MonsterMotionList {
	l := &MonsterMotionList{Entries: []MonsterMotion{}}
	for _, m := range listed {
		if !m.Moving {
			continue
		}
		l.Entries = append(l.Entries, MonsterMotion{
			ID: m.ID, DestX: float32(m.DestX), DestZ: float32(m.DestZ), Speed: float32(m.MoveSpeed), Mode: m.MoveMode,
		})
	}
	return l
}

// tracef logs one AI trace line when the operator asked for them
// (SRREVAMP_AI_TRACE).
func (a *monsterAI) tracef(format string, args ...any) {
	if a.trace && a.logger != nil {
		a.logger.Info(fmt.Sprintf(format, args...))
	}
}
