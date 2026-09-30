package session

import (
	"context"
	"fmt"
	"log/slog"
	"math"
	"math/rand"
	"runtime/debug"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/ai"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/mana"
	"github.com/OpenSRO/srrevamp/server/internal/party"
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
//
// With -monster-battle on as well (SetMonsterBattle, round 546; OFF by
// default, and cmd/server forces it off unless -monster-ai and
// -monster-strike-push are both on), BATTLE is the engine's own instead of
// the hold: the monster chases its attacker to its attack band at its run
// speed and swings on its own timer, each blow pushed to the zone as an
// OpMonsterAttacked, and leaves by the engine's exits (battleTick). The
// synchronous counter in performAttack is then skipped. The same flag carries
// the aggro link (linkAggro, round 553): a party member's first hit on a
// monster not yet fighting pulls as many of the ten nearest monsters as the
// party has members within 1000 units of the attacker into BATTLE against
// the attacker, each engaged by that chase and those swings.
//
// With -monster-aggro on as well (SetMonsterAggro, round 552; OFF by
// default, and cmd/server forces it off unless -monster-battle is in effect
// and -player-dead-state is on), a monster notices players on its own
// (acquire): idle, wandering or, once its blackout has passed, running home,
// it scans on tactics timer 1 for the nearest living player inside its
// acquisition radius -- BCRadius + ai.TacticsDetectionDistance, 104..111 for
// the roster -- and engages it as a blow would, through BATTLE's chase and
// swings. Off, a monster fights only when struck, and the runtime draws
// nothing new from its rng.

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
	// What a monster's own swing reads and writes (monsterStrike's strikeDeps):
	// the target's character row, the gear it wears and wears down, the item
	// table that gear resolves against, and the mana pool a death refills.
	// Used only with -monster-battle on (SetMonsterBattle); with any of Chars,
	// Equipment or Items nil the chase runs but no swing is made (queueStrike;
	// round 547: the blow reads all three -- defenderDefence's eq.Get has no
	// nil guard -- so a partial set would panic the strike worker). Mana may
	// be nil: monsterStrike guards it. cmd/server passes all four.
	Chars     character.Store
	Equipment equipment.Store
	Items     combat.ItemLookup
	Mana      *mana.Tracker
	// Potions is the potion queue a kill empties under -player-dead-state
	// (round 549, markDead); nil leaves nothing to empty. The world hub the
	// life state lives in is the runtime's own.
	Potions *PotionQueue
	// Parties is the party hub the aggro link reads (round 553, linkAggro):
	// a blow links only for a member of a party. nil links nothing. Read only
	// with -monster-battle on. cmd/server passes the one hub every handler
	// shares.
	Parties *party.Hub
	// Sleep lets the brains of monsters no player is near sleep (round 656,
	// cmd/server's -monster-sleep, on by default there): a monster whose
	// region cell is outside every player's window -- the AOIRadius square of
	// cells around the cell each player stands in -- is neither stepped nor
	// updated, and picks up where it stopped when a player comes within that
	// window. OURS: retail's rule for which objects it runs is unread; this
	// one runs every monster any player could see and no other, so nothing a
	// client draws behaves differently. Off (the zero value, every unit test
	// that does not ask for it), every monster runs every tick, as before.
	Sleep bool
}

// monsterBattle is cmd/server's -monster-battle (SRREVAMP_MONSTER_BATTLE),
// OFF by default. An atomic because cmd/server sets it on the boot goroutine
// while performAttack reads it on session readers and keep-up goroutines and
// the tick reads it on its own.
var monsterBattle atomic.Bool

// SetMonsterBattle turns the monster's own BATTLE -- the chase to its attack
// band and the swing on its own timer, pushed to the zone -- on or off.
// cmd/server calls it once at boot, before the gateway serves, and only
// passes true when -monster-ai and -monster-strike-push are both on: the
// chase needs the tick, and a swing nobody is told about is silent HP loss.
// With it on, performAttack skips the synchronous counter; with it off, the
// counter and the interim hold are what they were.
func SetMonsterBattle(on bool) { monsterBattle.Store(on) }

// monsterAggro is cmd/server's -monster-aggro (SRREVAMP_MONSTER_AGGRO), OFF
// by default. An atomic for the same reason monsterBattle is one: set on the
// boot goroutine, read by the tick on its own.
var monsterAggro atomic.Bool

// SetMonsterAggro turns target acquisition -- a monster noticing the nearest
// living player inside its acquisition radius and engaging it unstruck -- on
// or off. cmd/server calls it once at boot, before the AI starts, and only
// passes true when -monster-battle is in effect (a noticed player is engaged
// by the chase and the monster's own swings; under the interim hold the
// monster would only stand where it noticed) and -player-dead-state is on (a
// monster that seeks players out kills ones who never struck it, and a kill
// must leave them dead rather than respawned in place). With it off nothing
// scans, and the brains draw nothing new from the rng.
func SetMonsterAggro(on bool) { monsterAggro.Store(on) }

// ChaseReaimDistance is how far a BATTLE target must have moved since the
// chase last aimed at it before the leg is re-issued to the zone (chase). OWN
// DESIGN, an engineering choice: the engine re-aims its walk on every AI
// update; pushing a new OpMonsterMoved every tick for a target that has not
// moved would be ten pushes a second per chasing monster for no new
// information. A monster that stopped short (a blow's stop, an arrival) is
// re-issued whatever the target did.
const ChaseReaimDistance = 1.0

// monsterAIRuntime is the running monster AI, nil while -monster-ai is off.
// An atomic pointer rather than a plain variable: RunMonsterAI stores it on
// the boot goroutine while session readers and keep-up goroutines load it
// (noteStruck, handleMonsterList, the keep-up trace), and each reader loads it
// once into a local.
var monsterAIRuntime atomic.Pointer[monsterAI]

// monsterAI is the runtime's state.
type monsterAI struct {
	// mu serialises the tick's pass -- from StepCells to the last push it
	// collects -- with noteStruck, so a blow's stop and the struck record
	// land wholly before or wholly after a pass. Nothing is sent under it.
	mu sync.Mutex
	// struck holds the blows since the last tick, keyed by monster id,
	// keeping the FIRST attacker. It is drained every tick and so holds at
	// most one entry per live monster; there is no queue.
	struck map[int64]struckEvent

	// kills holds, by monster id, the targets a strike worker killed since the
	// last tick (runStrike writes it, the BATTLE tick drains it): the kill
	// is the 0x23 exit's evidence while -player-dead-state is off and a dead
	// player is back on its feet at once (battleTick); with it on the life
	// state itself is the evidence, and this record is the same exit a tick
	// earlier. Written only while the monster's brain is there to drain it
	// (round 547).
	kills map[int64]struct{}

	// deps is what a monster's own swing reads and writes (MonsterAIConfig);
	// fixed at construction, read by the strike workers.
	deps strikeDeps

	// The rest belongs to the tick (monsterAITick), which holds mu while it
	// touches it.
	brains   map[int64]*brain
	rng      *rand.Rand
	monsters *combat.Hub
	world    *world.Hub
	// parties is the party hub the aggro link reads (MonsterAIConfig.Parties);
	// nil links nothing.
	parties *party.Hub
	push    func(zone string, p *proto.Packet)
	// strikeDone, when set, is told the monster id of each swing a strike
	// worker has finished -- landed, dropped or panicked -- once runStrike
	// has returned. A test's observer (round 550: the two-monster kill test
	// waits on both workers through it instead of sleeping); nil in
	// production. Set before the first tick: a worker starts on its
	// monster's first swing and reads it from then on.
	strikeDone func(monster int64)
	// sleep is MonsterAIConfig.Sleep.
	sleep bool
	// The tick's reusable buffers and per-pass indexes (round 656), so a pass
	// over thousands of monsters allocates next to nothing: live is the pass's
	// monsters in id order, awake the cells some player's window holds (with
	// sleep on), players the living and dead players by the cell they stand
	// in, crossed the region lines this pass's step carried monsters over,
	// cellBuf/candBuf/sessBuf scratch space.
	live  []combat.Monster
	awake map[combat.Cell]struct{}
	// insistent is, with sleep on, the monsters in BATTLE or HOMING this
	// pass: they run wherever they are (round 656's review).
	insistent  map[int64]struct{}
	players    map[combat.Cell][]world.Entity
	crossed    []combat.CellChange
	cellBuf    []combat.Cell
	candBuf    []ai.Candidate
	sessBuf    []*gateway.Session
	logger     *slog.Logger
	trace      bool
	roamRadius float64
	last, now  time.Time
	tickN      uint64
	// battle is -monster-battle as this pass read it (monsterBattle), once,
	// so one pass runs one BATTLE or the other throughout; aggro is
	// -monster-aggro the same way (monsterAggro).
	battle  bool
	aggro   bool
	pending []monsterPush
	// handoffs is the swings this pass decided on (queueStrike), handed to
	// their strike workers after the pass's pushes are out (handStrike).
	handoffs []strikeHandoff
	// held is tick heldTick's keep-up set (keptUpSet), built on that tick's
	// first release test and stale -- rebuilt -- on any other tick.
	held     map[heldKey]struct{}
	heldTick uint64
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
	id int64
	// seenTick is the last pass that ran this brain (round 656): a brain the
	// pass did not see is dead, or with sleep on asleep.
	seenTick uint64
	m        combat.Monster // as of this tick, refreshed after every move
	machine  *ai.Machine
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

	// The monster's own BATTLE (-monster-battle, battleTick):
	//
	// chaseAimX/Z is where the target stood when the chase last issued its
	// leg, and chaseAimed whether one is out (ChaseReaimDistance).
	chaseAimX, chaseAimZ float64
	chaseAimed           bool
	// lastSwing is when the monster last fired its attack skill, zero for
	// never. It is the action machine's cooldown, not BATTLE's timer 5: that
	// timer is armed fired at BATTLE::OnEnter (0x55a018) and after every swing
	// (Handler_0e8 0x547342), so it is due at once each time (ArmTimer
	// 0x53d6c7, round 545), and what spaces the swings is the skill's
	// ReuseDelay through the action machine (round 254). So it persists
	// across BATTLE entries, as the cooldown does. swungReuseMs is the
	// ReuseDelay of the skill that swing fired, the length of the cooldown
	// (round 554: a species with two skills has two).
	lastSwing    time.Time
	swungReuseMs int
	// armed is the attack skill the next swing fires -- the selector's +0x44,
	// which PickSkill (0x561b00) fills through ArmNextAttack (0x5619e0) and
	// Handler_0e8 (0x5472a0) reads first (its slot 4) before it asks for a
	// pick -- and hasArmed whether one is held (round 554). Drawn by armSkill
	// on the first BATTLE tick that finds none, at that tick's distance,
	// cleared when it fires and when BATTLE is left (leaveBattle, round 555:
	// the engine zeroes +0x44 in ResetThreat at BATTLE::OnLeave).
	armed    combat.MonsterSkill
	hasArmed bool
	// giveUpDueAt is when tactics timer 6 is next due (ai.GiveUpCheckPeriodMs):
	// armed once at Init, due at once the first time it is asked, then the
	// period after each consumption -- zero here is "due".
	giveUpDueAt time.Time
	// strikes feeds this monster's strike worker (queueStrike); nil until
	// the first swing, closed when the brain is dropped.
	strikes chan strikeJob

	// Target acquisition (-monster-aggro, acquire):
	//
	// detection is the acquisition radius, ctx+0x15c: BCRadius plus the
	// detection distance (ai.DetectionRadius with ai.TacticsDetectionDistance,
	// the stand-in for _RefTactics column 6); 0 for a species that never
	// acquires. Set for every brain -- it is arithmetic -- and read only
	// under the flag.
	detection float64
	// aggressive is the aggression byte's verdict, ctx+0x168 (ai.Aggressive,
	// rolled at Init 0x53f5be..0x53f5e1), fixed for the monster's life.
	aggressive bool
	// scanPeriodMs is tactics timer 1's period, rolled once at Init
	// (ai.ScanPeriodMs; 1001..1500 ms under the stand-in flags), and scanDueAt
	// is when the timer is next due: zero is "due", the first-table arming's
	// fired start (ArmTimer 0x53d6c7), and each consumption sets it a period
	// on (TimerDue 0x53d765). Both are the flag's: rolled only when this pass
	// read it on, so the flag-off runtime draws nothing new from the rng.
	scanPeriodMs int
	scanDueAt    time.Time
	// homingBlackoutMs is HOMING's re-aggro window, the state's +0x1c
	// (ai.HomingReaggroDelayMs: trunc(detection / run speed x 1000) ms,
	// CAIState_HOMING::OnEnter 0x55a60e..0x55a63e), set on each entry;
	// ReaggroWindowPassed (0x55a720) is `now - enteredAt > +0x1c`, strict.
	homingBlackoutMs int
}

// strikeJob is one swing handed to a monster's strike worker: the monster as
// the tick saw it and the character it swings at.
type strikeJob struct {
	m      combat.Monster
	target int64
	// skill is the attack skill the swing fires (round 554): the brain's
	// armed pick, whose 'att' block the blow rolls; the zero value is a
	// species with no skill list, whose blow is the monster's primary fields.
	skill combat.MonsterSkill
}

// strikeHandoff is a swing a pass decided on, waiting for the pass's pushes to
// go out before its brain's worker is handed it (tick step 6).
type strikeHandoff struct {
	b   *brain
	job strikeJob
}

// monsterPush is one push collected during a pass, sent after it: the zone
// and the region cell of the monster it is about (round 656: the cell picks
// its recipients, deliver).
type monsterPush struct {
	zone   string
	cell   combat.Cell
	id     int64 // the monster (round 656's second review: mayShowLeg)
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
		kills:      map[int64]struct{}{},
		deps:       strikeDeps{chars: cfg.Chars, eq: cfg.Equipment, items: cfg.Items, mp: cfg.Mana, hub: hub, potions: cfg.Potions},
		brains:     map[int64]*brain{},
		rng:        rng,
		monsters:   monsters,
		world:      hub,
		parties:    cfg.Parties,
		logger:     logger,
		trace:      cfg.Trace,
		roamRadius: MonsterRoamRadius,
		sleep:      cfg.Sleep,
		awake:      map[combat.Cell]struct{}{},
		insistent:  map[int64]struct{}{},
		players:    map[combat.Cell][]world.Entity{},
	}
	// nil is the production push, to the players whose window holds the
	// monster (deliver); a test passes a recorder, or sets a.push itself.
	// Round 537's zone-wide broadcast is gone: deliver replaced it.
	a.push = push
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
// performAttack's ApplyDamage. A tick whose StepCells lands between the two
// still moves the monster up to MonsterAITick x speed before the stop -- so
// one struck at the very edge of reach can still leave it. The window is the
// handler's own work between the two calls, not a tick. Closing it means
// stopping the monster at the reach test, before the swing is known to be
// ready or to land, which would stop monsters for clicks that deal nothing.
//
// With -monster-battle on there is no stop here: the engine's BATTLE::OnEnter
// (0x559fb0..0x55a08b) issues none, and the tick's chase replaces the leg or
// stops it in the band (battleTick), so the blow is only recorded. A monster
// struck while walking away then walks on for at most one tick before the
// chase turns it toward its attacker at its run speed.
func noteStruck(monsters *combat.Hub, monsterID, characterID int64) {
	a := monsterAIRuntime.Load()
	if a == nil || monsters == nil || monsters != a.monsters {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	moving := false
	if !monsterBattle.Load() {
		if m, ok := monsters.Get(monsterID); ok && m.Moving {
			monsters.StopMotion(monsterID)
			moving = true
		}
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
// collected and, last, hands the pass's swings to their strike workers.
// Brains run in monster-id order so a seeded rng replays.
//
// Round 656: the pass reads the players once (indexPlayers: by the region
// cell each stands in), and with sleep on (MonsterAIConfig.Sleep) steps and
// runs only the monsters in cells some player's window holds; the step
// reports the region lines it carried monsters over, and the area of
// interest turns those into enter and leave messages (aoi.go crossings),
// sent before the pass's pushes. The monsters are read into a buffer the
// runtime keeps (live), not a fresh copy of the whole hub each tick.
func (a *monsterAI) tick(now time.Time) {
	a.mu.Lock()
	dt := 0.0
	if !a.last.IsZero() && now.After(a.last) {
		dt = now.Sub(a.last).Seconds()
	}
	a.last, a.now = now, now
	a.tickN++
	a.battle = monsterBattle.Load()
	a.aggro = monsterAggro.Load()
	a.indexPlayers()

	// Round 656's review: a monster in BATTLE or HOMING never sleeps, wherever
	// it is -- a chase or a run home is finished, not frozen part-way.
	if a.sleep {
		clear(a.insistent)
		for id, b := range a.brains {
			if st := b.machine.State(); st == ai.StateBattle || st == ai.StateHoming {
				a.insistent[id] = struct{}{}
			}
		}
	}

	// 1. The mover (combat.MoverStep: the 160 cap and the no-overshoot clamp),
	// over the awake cells only when sleep is on. The step and the enter and
	// leave messages its region crossings owe are computed under the area of
	// interest's read lock, as one step (round 656's review): a view that
	// moved between the two would have read the monster's new cell in its own
	// difference and then found no crossing to answer for its old one, and
	// the client would have missed an enter or a leave.
	var awake func(int64, combat.Cell) bool
	if a.sleep {
		awake = a.isAwake
	}
	var entered []viewEvents
	if v := aoiFor(a.monsters); v != nil && a.push == nil {
		a.crossed, entered = v.step(dt, awake, a.crossed[:0])
	} else {
		a.crossed = a.monsters.StepCells(dt, awake, a.crossed[:0])
	}

	// 2. A brain per live monster. A new one faces the heading it hatched
	// with (combat.Monster.Heading) and leaves SPAWN at once: message 0x21's
	// default transition is IDLE. OWN DESIGN: SPAWN::OnUpdate's timing is
	// unread, so it leaves on the first tick that sees it. With sleep on a
	// monster no player is near gets its brain when one first comes near.
	if a.sleep {
		a.cellBuf = a.cellBuf[:0]
		for c := range a.awake {
			a.cellBuf = append(a.cellBuf, c)
		}
		a.live = a.monsters.InCells(a.live[:0], a.cellBuf)
		for id := range a.insistent {
			if m, ok := a.monsters.Get(id); ok {
				if _, inAwakeCell := a.awake[combat.CellOf(m.Zone, m.X, m.Z)]; !inAwakeCell {
					a.live = append(a.live, m)
				}
			}
		}
	} else {
		a.live = a.monsters.AppendAll(a.live[:0])
	}
	live := a.live
	sort.Slice(live, func(i, j int) bool { return live[i].ID < live[j].ID })
	for i := range live {
		m := &live[i]
		if b := a.brains[m.ID]; b != nil {
			b.m = *m
			b.seenTick = a.tickN
			continue
		}
		b := a.newBrain(*m)
		b.seenTick = a.tickN
		a.brains[m.ID] = b
		a.dispatch(b, ai.MsgSpawned)
	}
	for id, b := range a.brains {
		if b.seenTick == a.tickN {
			continue
		}
		// Not in this pass: dead, or -- sleep on -- asleep. A sleeping brain
		// keeps its state for when it wakes.
		if a.sleep && a.monsters.Exists(id) {
			continue
		}
		if b.strikes != nil {
			close(b.strikes) // the strike worker ends after what is queued
		}
		delete(a.brains, id)
		delete(a.kills, id)
	}

	// 3. The blows.
	struck := a.struck
	a.struck = map[int64]struckEvent{}
	for _, id := range sortedIDs(struck) {
		a.onStruck(id, struck[id])
	}

	// 4. Each brain once.
	for i := range live {
		if b := a.brains[live[i].ID]; b != nil && b.seenTick == a.tickN {
			a.update(b)
		}
	}

	pending, handoffs := a.pending, a.handoffs
	a.pending, a.handoffs = nil, nil
	a.mu.Unlock()

	// 5. The pushes, after the pass: first what each player is owed for the
	// monsters that crossed into or out of its window (round 656), then the
	// legs and stops, each to the players whose window holds the monster.
	if len(entered) > 0 {
		v := aoiFor(a.monsters)
		for _, ev := range entered {
			v.deliverViewEvents(ev)
		}
	}
	for _, p := range pending {
		a.sessBuf = a.emit(p, a.sessBuf)
	}
	// 6. The swings, after the pushes (round 547): a stop this pass queued --
	// the in-band stop of a monster still on a leg -- is on the wire before
	// the blow the same pass decided on. Until this round the worker was
	// handed the swing during the pass, under a.mu, and could push the blow
	// before the stop was flushed; a client then drew the first swing on a
	// still-walking body (its walking-body rule leaves it unturned until the
	// stop lands).
	for _, h := range handoffs {
		a.handStrike(h)
	}
}

// indexPlayers files every player by the region cell it stands in (players)
// and, with sleep on, marks the cells within AOIRadius of each as awake. Once
// a pass, under a.mu; the acquire scan reads players instead of copying the
// zone's entities for every monster that scans.
func (a *monsterAI) indexPlayers() {
	for c, list := range a.players {
		a.players[c] = list[:0]
	}
	clear(a.awake)
	if a.world == nil {
		return
	}
	for _, e := range a.world.AllEntities() {
		c := combat.CellOf(e.Zone, e.Pos.X, e.Pos.Z)
		a.players[c] = append(a.players[c], e)
		if !a.sleep {
			continue
		}
		for x := c.X - AOIRadius; x <= c.X+AOIRadius; x++ {
			for z := c.Z - AOIRadius; z <= c.Z+AOIRadius; z++ {
				a.awake[combat.Cell{Zone: c.Zone, X: x, Z: z}] = struct{}{}
			}
		}
	}
}

// isAwake reports whether monster id, standing in cell c, runs this pass:
// c is in some player's window, or the monster is in BATTLE or HOMING
// (insistent).
func (a *monsterAI) isAwake(id int64, c combat.Cell) bool {
	if _, ok := a.awake[c]; ok {
		return true
	}
	_, ok := a.insistent[id]
	return ok
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
// the aggro link (behaviour +0xf0, the call at 0x558ebb; linkAggro, with
// -monster-battle on), then SetTarget with push 1 (0x0053ffe0, called at
// 0x558eef), then ChangeState(3) (`lea edi,[ebx+3]` at 0x558f01 into
// 0x0053ff30) -- no aggression or range test. Not modelled: the attacker
// accounting's refusal (behaviour +0xec, AITactics_CreditAttacker
// 0x005473c0, the test at 0x558edd). A monster already in BATTLE ignores the
// blow, the link included: OWN DESIGN, the rule-0 stand-in for
// CAIState_BATTLE::OnAttacked (0x0055a2e0 -> behaviour +0xfc, which has no
// +0xf0 call), which under the tactics row's rule 0 keeps the first attacker.
// Every drained blow, one on a monster already in BATTLE included, restarts
// the hold's release count (MonsterHoldReleaseTicks).
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
	if a.battle {
		a.linkAggro(b, ev.attacker)
	}
	b.target = ev.attacker
	if a.battle {
		a.tracef("ai: monster %d struck by %d, engaging", id, ev.attacker)
	} else {
		a.tracef("ai: monster %d struck by %d, holding", id, ev.attacker)
	}
	a.change(b, ai.StateBattle)
}

// linkAggro is AITactics_ExtRoutine::LinkAggroToNearbyMonsters (0x547570,
// behaviour +0xf0), which CAIState::OnAttacked (0x558ea0) runs at 0x558ebb
// before the victim's own SetTarget and ChangeState(3) -- so only a blow on a
// monster NOT already in BATTLE links: BATTLE's slot 6 is
// CAIState_BATTLE::OnAttacked (0x55a2e0), which calls behaviour +0xfc
// (AITactics_Handler_0fc 0x548090, `mov edx,[ecx+0xfc]; call edx` at
// 0x55a2ea..0x55a2f3) and, on its non-zero answer -- the 1 Handler_0fc
// returns only when the +0xec accounting refuses -- ChangeState(1)s to IDLE
// (`lea edi,[ebx+1]; call 0x53ff30` at 0x55a302..0x55a305); no +0xf0 call
// is made on it (round 555 corrected "slot 6 is Handler_0fc", one step
// short). It rides
// -monster-battle and needs no flag of its own: a
// linked monster is engaged by the chase and the swings (under the interim
// hold it would only stand where it was, the reason acquire needs the flag
// too), and an older client draws its output -- legs as OpMonsterMoved, blows
// as OpMonsterAttacked -- exactly as it draws a struck monster's. Its rules
// are internal/ai's (state.go, "The aggro link"; docs/protocol/monster_ai.md,
// "The aggro link: the runtime (round 553)"), in the engine's order:
//
//  1. the record's hate must be non-zero and the attacker a PC (0x547570's
//     opening tests). Every srrevamp attacker is a character; a blow carries
//     no hate value here, so every blow is taken as carrying some --
//     DISCLOSED: what hate a plain blow's record holds is unread. The
//     stand-in is the one the runtime already rests on rather than a fresh
//     inference: AITactics_CreditAttacker (0x5473c0) returns 1 -- drop -- for
//     a code-0 record whose hate lands below 1 (`if ((iVar4 == 0) && (iVar3 <
//     1)) return 1`), and CAIState::OnAttacked only SetTargets and
//     ChangeState(3)s when +0xec returns 0, so a zero-hate first blow would
//     not even engage its victim, which round 546's BATTLE entry on every
//     blow already assumes it does; the magnitudes are mob-threat-retarget's;
//  2. the attacker's party must exist (pc+0x1cb8) and share EXP (party+0x10
//     bit 0). Every srrevamp party shares EXP (party.go), and, as killExpFor's
//     gate reads it (round 485), a party is one of two or more: the engine
//     never creates a party of one, srrevamp's create path does;
//  3. the gather (AITactics_CollectNearbyMonsters 0x540580 -> ai.GatherWithin):
//     the ten nearest OTHER monsters within ai.LevelScaledRadius(the victim's
//     detection radius, victim level - attacker level) of the VICTIM. The
//     attacker's level is the character row's (vtable slot 73 in the engine),
//     read off the world entity's cache (world.Entity.Level: the row's at
//     enter-world, moved by the level-up and /level) -- round 555; until then
//     one chars.GetByID per link event under a.mu, so one slow store read
//     stalled every monster's tick. srrevamp's own, disclosed: the candidates
//     are the monsters of the victim's zone (the engine walks the owner's
//     regions), on the ground plane, and a monster hatched since this pass's
//     step 2 has no brain yet and is skipped for this blow;
//  4. n = the party members at most 1000.0 units from the attacker
//     (0x5476e9..0x5476f6, inclusive; ai.AggroLinkMemberRange), the attacker
//     counted without measuring; a member counts only when it resolves in
//     the world and its region is the attacker's or adjacent (0x430ce0) --
//     srrevamp: in world.Hub, in the attacker's zone, on the ground plane;
//  5. n = CLAMP(n, 0, gathered) (ai.AggroLinkCount);
//  6. the record's damage is zeroed (0x547797) and each of the n nearest gets
//     command 0xe -> slot 29 (0x5477fd..0x54780a) when ValidTargetOrNull
//     (0x540dc0 at 0x5477ea) accepts it -- every monster in the hub is alive
//     -- with the hate floored at 1 before and scaled by the decrease ratio
//     after (ai.AggroLinkHate, which nothing forwards yet: no hate value).
//     CAIState::OnAggroLinked (0x559bb0): SetTarget(attacker), ChangeState(3),
//     and NO further link -- a link never cascades. CAIState_BATTLE::
//     OnAggroLinked (0x55a320) credits the attacker (+0xec, `mov
//     edx,[ecx+0xec]; call edx` 0x55a32a..0x55a333) and, when the accounting
//     refuses, ChangeState(1)s to IDLE (`lea edi,[ebx+1]; call 0x53ff30`
//     0x55a342..0x55a345); the refusal is not modelled (as on the victim), so
//     here a gathered monster already in BATTLE keeps its target under rule 0
//     and still uses up its place among the n. DEAD refuses the transition
//     (ai.Machine), and uses up its place too: the engine's forward is to the
//     first n gathered whatever each one's state.
//
// Nothing is sent from here: a linked brain's update this same pass issues
// its chase leg (battleTick), collected with the pass's pushes. Nothing is
// read from a store either (round 555).
func (a *monsterAI) linkAggro(b *brain, attacker int64) {
	if a.parties == nil || a.world == nil {
		return
	}
	p, ok := a.parties.Get(attacker)
	if !ok || p == nil || len(p.Members) < 2 {
		return
	}
	self, ok := a.world.EntityByCharacterID(attacker)
	if !ok {
		return // the attacker must resolve (FUN_00485d90 at the routine's head)
	}
	radius := ai.LevelScaledRadius(b.detection, b.m.Level, self.Level)
	// Round 656: the candidates are the monsters of the cells a radius can
	// reach (combat.CellsWithin), not every monster of the zone -- the same
	// ones GatherWithin keeps, since it drops anything farther than radius.
	var cands []ai.Candidate
	near := a.monsters.InWindow(nil, combat.CellOf(b.m.Zone, b.m.X, b.m.Z), combat.CellsWithin(float64(radius)))
	for _, m := range near {
		if m.ID == b.id || a.brains[m.ID] == nil {
			continue
		}
		cands = append(cands, ai.Candidate{ID: m.ID, X: m.X, Z: m.Z})
	}
	gathered := ai.GatherWithin(cands, b.m.X, b.m.Z, radius)
	members := 0
	for _, mem := range p.Members {
		if mem.CharacterID == attacker {
			members++
			continue
		}
		e, ok := a.world.EntityByCharacterID(mem.CharacterID)
		if !ok || e.Zone != self.Zone {
			continue
		}
		if math.Hypot(e.Pos.X-self.Pos.X, e.Pos.Z-self.Pos.Z) <= ai.AggroLinkMemberRange {
			members++
		}
	}
	n := ai.AggroLinkCount(members, len(gathered))
	a.tracef("ai: monster %d struck by %d of a party: %d member(s) within %.0f, %d neighbour(s) within %d, linking %d",
		b.id, attacker, members, ai.AggroLinkMemberRange, len(gathered), radius, n)
	for i := 0; i < n; i++ {
		nb := a.brains[gathered[i].ID]
		switch st := nb.machine.State(); {
		case st == ai.StateBattle:
			a.tracef("ai: monster %d linked to %d by the hit on monster %d: already in BATTLE, keeps its target", nb.id, attacker, b.id)
		case st.Terminal():
			// ChangeState out of DEAD is the engine's silent no-op.
		default:
			nb.target = attacker
			a.tracef("ai: monster %d linked to %d by the hit on monster %d, engaging", nb.id, attacker, b.id)
			a.change(nb, ai.StateBattle)
		}
	}
}

// update is one state's OnUpdate.
func (a *monsterAI) update(b *brain) {
	elapsed := int(a.now.Sub(b.enteredAt) / time.Millisecond)
	switch b.machine.State() {
	case ai.StateIdle:
		// CAIState_IDLE::OnUpdate (0x0055a8b0, slot 3 of IDLE's vtable
		// 0xaf899c): CAIState::OnUpdate's expiry (0x00558b90) dispatches 0x25,
		// which IDLE overrides with the roll (slot 41, CAIState_IDLE::OnMsg_0x25
		// 0x00559cf0): another idle spell, or WANDER -- and the update ends
		// there. Otherwise the acquire behaviour (+0xf8) and, on its 2, message
		// 0x22 -> BATTLE (acquire). The +0x108 call after it is not modelled.
		if ai.DwellExpired(b.dwellMs, elapsed) {
			a.change(b, ai.IdleNext(a.rng))
			return
		}
		a.acquire(b)
	case ai.StateWander:
		// CAIState_WANDER::OnUpdate (0x00559eb0): the expiry dispatches 0x25
		// (0x559ec9), whose default is IDLE -- the leg is NOT stopped; then
		// the acquire behaviour (+0xf8) and, on its 2, message 0x22 -> BATTLE
		// (acquire); then, for a monster that can run, the roam check sends
		// 0x26 (0x559f38..0x559f65). The +0x108 call between the acquire and
		// the roam check is not modelled.
		if ai.DwellExpired(b.dwellMs, elapsed) {
			a.dispatch(b, ai.MsgInterrupted)
			return
		}
		if a.acquire(b) {
			return
		}
		if b.m.RunSpeed > 0 && !a.withinRoam(b) {
			a.dispatch(b, ai.MsgReturnHome)
		}
	case ai.StateHoming:
		// CAIState_HOMING::OnUpdate (0x0055a690): the 50 s expiry dispatches
		// 0x25 (0x55a6a8) -> IDLE; then, once the state's slot 48 answers
		// (CAIState_HOMING::ReaggroWindowPassed 0x0055a720: now - enteredAt >
		// the +0x1c blackout, strict), the acquire behaviour (+0xf8) and, on
		// its 2, message 0x22 -> BATTLE (acquire); then AITactics_HomingStep
		// (behaviour +0x118, 0x005496c0) reports arrival (AITactics_HasArrived
		// 0x00541f60, under 5.0) -> 0x24 -> IDLE. OWN DESIGN: HOMING walks one
		// straight leg (below) and the step is tested every tick; the step's
		// heading wobble is not modelled.
		if ai.DwellExpired(b.dwellMs, elapsed) {
			a.dispatch(b, ai.MsgInterrupted)
			return
		}
		if elapsed > b.homingBlackoutMs && a.acquire(b) {
			return
		}
		if ai.HasArrived(b.m.X, b.m.Z, b.homingDestX, b.homingDestZ) {
			a.dispatch(b, ai.MsgArrived)
		}
	case ai.StateBattle:
		// BATTLE has no dwell (ai.BattleDwellMs), so nothing expires it.
		// With -monster-battle on it is the engine's own tick, every tick
		// (CAIState_BATTLE::OnUpdate runs on every AI update, its entry
		// tick's blow notwithstanding):
		if a.battle {
			a.battleTick(b)
			return
		}
		// The interim hold. Not on a tick that drained a blow on it, its
		// entry among them:
		if b.lastBlowTick == a.tickN {
			return
		}
		// The target must still be in the world, in this zone and alive: the
		// engine's 0x23 exit, when CAIState_BATTLE::OnUpdate (0x0055a090)
		// finds its target invalid through AITactics_ValidTargetOrNull
		// (0x00540dc0, which wraps AITactics_IsValidTarget 0x00540de0's alive
		// and life-state-1 tests; named in round 545). The life-state test is
		// the engine's own (`GetLifeState() == 1`, round 549: a player dead
		// under -player-dead-state is no target); the rest of srrevamp's
		// validity test is its own, disclosed: in world.Hub, same zone.
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
		if !ok || e.Zone != b.m.Zone || e.Life == world.LifeDead {
			why := "target gone"
			if ok && e.Life == world.LifeDead {
				why = "target dead" // the word battleTick's line uses (round 550)
			}
			a.tracef("ai: monster %d released (%s)", b.id, why)
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

// acquire is the acquire behaviour, AITactics_AcquireTarget (0x005478f0,
// behaviour +0xf8, installed when the tactics row's +0x14 is non-zero),
// followed by the message 0x22 the calling state dispatches on its 2
// (CAIState::OnMsg_0x22 0x00559900), behind -monster-aggro. It reports
// whether the state changed, the 2 the caller returns on. In the engine's
// order (round 552, docs/protocol/monster_ai.md, "Target acquisition: the
// runtime"):
//
//  1. an owner that is a COS never scans (slot 11 at 0x547923..0x54792b); no
//     roster species is one;
//  2. tactics timer 1 must be due (`mov ecx,0x1` 0x54793a, AITactics_TimerDue
//     0x53d6e0 at 0x54793f): armed at Init with ai.ScanPeriodMs, fired at first
//     (ArmTimer 0x53d6c7), and consumed here whenever it is due, found or not
//     -- BEFORE the aggression byte is read, so a non-aggressive monster
//     consumes its timer too (round 555 put the two tests in this order;
//     under the mode-0 stand-in every brain is aggressive and nothing could
//     tell, but a per-species mode would) -- and between the timer and the
//     byte the routine tests its own [ebp+8] argument (`cmp [ebp+8],edi;
//     setne al; cmp al,1; je 0x54796a` 0x54794e..0x547956): non-zero skips
//     the byte gate. What its callers pass there is unread, so it is not
//     modelled (round 564's note; unobservable under mode 0);
//  3. the aggression byte must be 0 or 3 (0x547958..0x547964; ai.Aggressive);
//  4. the scan: the regions within trunc(ctx+0x15c) (RC=chop, `or eax,0xc00`
//     0x547989, `fistp` 0x54799a) for players -- kind mask 1, the nearest
//     selector 2 (0x5479b9..0x5479be under the stand-in flag word) -- through
//     AITactics_ScanForTargets (0x5405b0 at 0x547a07), which hands every
//     player of those regions but the owner to the selector,
//     AITactics_Select_Nearest (0x5464e0, ai.Nearest): the nearest candidate
//     at most the radius away, a player only through
//     AITactics_ValidTargetOrNull (0x540dc0), whose AITactics_IsValidTarget
//     (0x540de0) wants life state 1 -- so a player dead under
//     -player-dead-state is never picked. Read closer in round 555 (the
//     selector's PC branch, 0x546563..0x546675): the validity call's result
//     is stored back OVER the candidate (`mov [ebp+0x10],eax` 0x546590; 0 on
//     the owner's slot-355 refusal, 0x5465a9), a nearer valid summoned
//     object of that player may replace it and its distance (0x546642,
//     0x546646), and the reloaded value (0x546675) goes through the radius
//     and best-so-far compares and into the pick slot with NO null test
//     (`mov [eax],esi` 0x546702) -- so a rejected player is not skipped: it
//     leaves a NULL pick at its own distance, which a later candidate must
//     be strictly nearer than to replace. srrevamp drops dead players before
//     the scan instead, so a dead player nearer the monster than a living
//     one never shadows the living one here as it would in the engine.
//     DISCLOSED, not modelled: a dead body that close is the round-552 live
//     check's own situation, and the flag's operator would want the living
//     player noticed;
//  5. the pick -> SetTarget (0x53ffe0 at 0x547a67) -> 2 -> the state
//     dispatches 0x22, whose handler asks ValidTargetOrNull again and then
//     AITactics_IsTargetWithinChaseRange (0x545e50; ai.TargetWithinChaseRange
//     with battleTick's nest reading) before ChangeState(3). A pick out of
//     chase range stays the target and the state stays.
//
// srrevamp's own, disclosed: the flag gate; the candidates are the world hub's
// entities in the monster's zone (srrevamp has no regions), taken in
// character-id order where the engine walks the region's player list; the
// distance is the ground plane's, as battleTick's (GObj_DistanceBetween
// 0x53d7a0 sums three axes, and srrevamp's monsters carry no height); the
// timer is not polled while the flag is off, which nothing can observe. Not
// modelled: the summoned-object detour and the owner's slot-355 test inside
// the selector (ai.Nearest), and the +0x168 byte's other writers.
func (a *monsterAI) acquire(b *brain) bool {
	if !a.aggro || !(b.detection > 0) || a.world == nil {
		return false
	}
	if a.now.Before(b.scanDueAt) {
		return false
	}
	b.scanDueAt = a.now.Add(time.Duration(b.scanPeriodMs) * time.Millisecond)
	if !b.aggressive {
		return false // the timer consumed, the byte read after it (0x54793f before 0x547958)
	}
	// Round 656: the players of the cells the radius can reach, off the
	// pass's player index (indexPlayers), not a copy of the zone's entities
	// per scan; Nearest drops anything past the radius either way.
	cands := a.candBuf[:0]
	home := combat.CellOf(b.m.Zone, b.m.X, b.m.Z)
	reach := combat.CellsWithin(b.detection)
	for x := home.X - reach; x <= home.X+reach; x++ {
		for z := home.Z - reach; z <= home.Z+reach; z++ {
			for _, e := range a.players[combat.Cell{Zone: home.Zone, X: x, Z: z}] {
				if e.Life != world.LifeAlive {
					continue
				}
				cands = append(cands, ai.Candidate{ID: e.CharacterID, X: e.Pos.X, Z: e.Pos.Z})
			}
		}
	}
	a.candBuf = cands
	sort.Slice(cands, func(i, j int) bool { return cands[i].ID < cands[j].ID })
	pick, dist, ok := ai.Nearest(cands, b.m.X, b.m.Z, b.detection)
	if !ok {
		return false
	}
	b.target = pick.ID
	fromHome := math.Hypot(b.m.X-b.m.HomeX, b.m.Z-b.m.HomeZ)
	if !ai.TargetWithinChaseRange(dist, ai.TacticsChaseSwitch, ai.TacticsGiveUpDistance, true, a.roamRadius, fromHome) {
		a.tracef("ai: monster %d noticed %d at %.0f, out of chase range (%.0f from home)", b.id, pick.ID, dist, fromHome)
		return false
	}
	a.tracef("ai: monster %d noticed %d at %.0f, engaging", b.id, pick.ID, dist)
	a.dispatch(b, ai.MsgEnemyInRange)
	return true
}

// battleTick is CAIState_BATTLE::OnUpdate (0x0055a090) with -monster-battle
// on, in the engine's order (round 545, docs/protocol/monster_ai.md, "The
// pure BATTLE rules and the timer read"):
//
//  1. the target must be valid, else message 0x23 -> IDLE
//     (AITactics_ValidTargetOrNull 0x540dc0 at 0x55a0dc, the exit at 0x55a116);
//  2. the reach test, behaviour +0x100 at 0x55a175 (AITactics_TargetOutOfReach
//     0x548120, under reach rule 0 the negation of IsTargetWithinChaseRange
//     0x545e50): out -> message 0x27 -> IDLE (0x55a187);
//  3. the give-up check, behaviour +0x104 at 0x55a1a2
//     (AITactics_BattleGiveUpCheck 0x5483c0), only when tactics timer 6 is
//     due: code 1 -> message 0x2a -> IDLE (0x55a1b9);
//  4. the swing, behaviour +0xe8 at 0x55a1d0 (AITactics_Handler_0e8 0x5472a0):
//     the walk to the attack band, else the attack skill through the action
//     machine.
//
// Not modelled between 1 and 2: the +0x10c/+0x108 calls at 0x55a12e..0x55a15e
// (message 0x2b, the follow-owner path; no roster species has an owner).
//
// Target validity: the engine's IsValidTarget (0x540de0) wants life state 1,
// which a kill leaves -- under -player-dead-state (round 549) the world hub
// holds that state and a dead player is refused here on it, the engine's own
// test. The rest is srrevamp's own, disclosed: in world.Hub, in this zone, and
// not killed by this monster's last swing -- with the flag off a dead player
// is back on its feet at once (monsterStrike's RespawnHP), so the strike
// worker reports the kill (kills) and the next tick takes the same 0x23 exit.
func (a *monsterAI) battleTick(b *brain) {
	var e world.Entity
	ok := false
	if a.world != nil {
		e, ok = a.world.EntityByCharacterID(b.target)
	}
	_, killed := a.kills[b.id]
	delete(a.kills, b.id)
	if !ok || e.Zone != b.m.Zone || killed || e.Life == world.LifeDead {
		why := "target gone"
		if killed {
			why = "target killed"
		} else if ok && e.Life == world.LifeDead {
			why = "target dead"
		}
		a.tracef("ai: monster %d released (%s)", b.id, why)
		a.dispatch(b, ai.MsgCombatEnded)
		return
	}
	dist := math.Hypot(e.Pos.X-b.m.X, e.Pos.Z-b.m.Z)
	fromHome := math.Hypot(b.m.X-b.m.HomeX, b.m.Z-b.m.HomeZ)

	// 2. The reach test. Every srrevamp placement is a nest whose position is
	// the spawn point and whose radius is the roam radius (MonsterRoamRadius,
	// own design), so this is the nest path: inclusive against the give-up
	// distance reduced by the excess beyond 1.5 x the radius (ai.ChaseRange).
	if !ai.TargetWithinChaseRange(dist, ai.TacticsChaseSwitch, ai.TacticsGiveUpDistance, true, a.roamRadius, fromHome) {
		a.tracef("ai: monster %d released (out of reach: target %.0f away, %.0f from home)", b.id, dist, fromHome)
		a.dispatch(b, ai.MsgUnused27)
		return
	}

	// 3. The give-up check, behind tactics timer 6: due the first time it is
	// asked (Init arms it fired, 0x53f6f6 -> 0x53d6c7) and then
	// GiveUpCheckPeriodMs after each consumption.
	if !a.now.Before(b.giveUpDueAt) {
		b.giveUpDueAt = a.now.Add(ai.GiveUpCheckPeriodMs * time.Millisecond)
		if ai.GiveUpCode(dist, ai.TacticsChaseSwitch, ai.TacticsGiveUpDistance) == 1 {
			a.tracef("ai: monster %d released (give-up: target %.0f away)", b.id, dist)
			a.dispatch(b, ai.MsgBodyChanged) // 0x2a with code 1: IDLE (CAIState::OnMsg_0x2a 0x559ad0)
			return
		}
	}

	// 4. The swing. The skill first (Handler_0e8 0x5472a0: the selector's
	// current pick, else PickSkill; none -> return 1, no swing): the one
	// armed, or a fresh draw at this tick's distance (armSkill, round 554).
	// With none -- a list in which no skill has an AI_AttackChance -- the
	// monster stands here in BATTLE, neither chasing nor swinging, until the
	// give-up check or the target's exit releases it: Handler_0e8's
	// failed-swing tail is not modelled (round 546), and no roster species
	// reaches this (every roster skill's chance is 100 or 10).
	sk, ok := a.armSkill(b, dist)
	if !ok {
		return
	}
	// The band is the attack-distance rule with the monster as the caster
	// (combat.ApproachBand: Tick_Attack 0x4ad8e0 / Tick_UseSkill 0x4ae590,
	// rounds 247/256/488): its BCRadius plus the player's, and the armed
	// skill's Range (skilldata col 21; round 254). A Mangyang's range is
	// exactly 10, the rule's own hole, so stop = reach = 10 and it is in
	// reach at int(dist) <= 12; a Yeoha that drew MSKILL_CH_YEOHA_ATTACK03
	// (range 100) is in reach from 100 + 11 + 4 + 2 units and walks nowhere.
	stop, reach := combat.ApproachBand(b.m.BCRadius, combat.PlayerBCRadius, combat.EffectiveRange(sk.Range, 0))
	if !combat.InReach(dist, reach) {
		a.chase(b, e.Pos, dist, stop)
		return
	}
	// In reach: a monster still on a leg stops here, with the zone's stop.
	if b.m.Moving {
		if m, ok := a.monsters.StopMotion(b.id); ok {
			b.m = m
			a.queueStop(m)
		}
	}
	b.chaseAimed = false
	// The action machine's cooldown: the ReuseDelay of the skill the LAST
	// swing fired (skilldata col 14; round 254), swungReuseMs. The first
	// swing is immediate (timer 5 armed fired at BATTLE::OnEnter, round 545).
	// A species with no known ReuseDelay has no skill row to fire and swings
	// not at all -- disclosed; every roster species carries one (cmd/server's
	// roster). OWN DESIGN: one cooldown per monster, not one per skill --
	// whether the engine's action machine would fire the OTHER skill inside
	// the first's re-use delay is not read (docs/protocol/monster_ai.md, "The
	// second attack skill: the runtime (round 554)").
	if sk.ReuseMs <= 0 {
		return
	}
	if !b.lastSwing.IsZero() && a.now.Sub(b.lastSwing) < time.Duration(b.swungReuseMs)*time.Millisecond {
		return
	}
	b.lastSwing, b.swungReuseMs = a.now, sk.ReuseMs
	b.hasArmed = false
	a.queueStrike(b, e.CharacterID, sk)
}

// armSkill is the attack skill the next swing fires: the one already armed
// (Handler_0e8's slot-4 read of the selector's +0x44), else a fresh draw over
// the monster's skill list at this tick's distance (PickSkill 0x561b00 ->
// ArmNextAttack 0x5619e0, ai.PickSkill), kept until it fires or BATTLE is
// left (leaveBattle). It answers false when no skill has an AI_AttackChance
// -- the engine's PickSkill returns false and Handler_0e8 returns 1, no swing
// (its failed-swing tail is not modelled, round 546's "not modelled"). A
// monster spawned without a list (a test's species, Spawn's) swings its
// primary fields, as it did before round 554: the same numbers as the col-83
// skill's, with no draw to make.
//
// OWN DESIGN, disclosed: the draw is made on the first BATTLE tick that finds
// nothing armed -- the tick BATTLE is entered on (every entry: the last
// fight's pick was cleared on the way out, the engine's own ResetThreat at
// BATTLE::OnLeave), and the tick after each swing -- at that tick's distance.
// When the engine clears +0x44 between two swings of ONE fight (at Execute,
// or at the action's end) is not read; only that Handler_0e8 reads the armed
// pick before it asks for a new one.
func (a *monsterAI) armSkill(b *brain, dist float64) (combat.MonsterSkill, bool) {
	if b.hasArmed {
		return b.armed, true
	}
	if len(b.m.Skills) == 0 {
		return combat.MonsterSkill{ReuseMs: b.m.AttackReuseMs, Range: b.m.AttackRange, AttMin: b.m.AttackMin, AttMax: b.m.AttackMax}, true
	}
	choices := make([]ai.AttackSkill, len(b.m.Skills))
	for i, s := range b.m.Skills {
		choices[i] = ai.AttackSkill{Chance: s.Chance, Range: s.Range}
	}
	i := ai.PickSkill(a.rng, choices, b.m.BCRadius, combat.PlayerBCRadius, dist)
	if i < 0 {
		return combat.MonsterSkill{}, false
	}
	b.armed, b.hasArmed = b.m.Skills[i], true
	if len(b.m.Skills) > 1 {
		a.tracef("ai: monster %d arms skill %d (range %d) at %.0f", b.id, b.armed.ID, b.armed.Range, dist)
	}
	return b.armed, true
}

// chase is Handler_0e8's walk when the target is out of the band: the
// engine's MoveTowardObject to round(stop) (docs/protocol/auto_command.md,
// phase 1; rounds 254/256 for BATTLE's use of it), the point that many units
// from the target on the line back to the monster, in the clip Handler_110
// gives BATTLE -- 1, the run clip (FUN_00541820 at BATTLE::OnEnter 0x55a04a;
// ai.MotionMode) -- at the speed that clip walks (startLeg's inference). The
// leg is re-issued when the monster is standing, or when the target has moved
// ChaseReaimDistance since the last aim. A species with no speed to chase at
// stands where it is and swings only when the target comes to it.
func (a *monsterAI) chase(b *brain, target world.Position, dist, stop float64) {
	if b.m.Moving && b.chaseAimed && math.Hypot(target.X-b.chaseAimX, target.Z-b.chaseAimZ) < ChaseReaimDistance {
		return
	}
	mode := ai.MotionMode(ai.StateBattle, b.m.WalkSpeed, b.m.RunSpeed)
	speed := b.m.WalkSpeed
	if mode != 0 {
		speed = b.m.RunSpeed
	}
	if !(speed > 0) || !(dist > 0) {
		return
	}
	d := math.Round(stop)
	ux, uz := (b.m.X-target.X)/dist, (b.m.Z-target.Z)/dist
	b.chaseAimX, b.chaseAimZ, b.chaseAimed = target.X, target.Z, true
	a.startLeg(b, target.X+ux*d, target.Z+uz*d, mode, "BATTLE chase")
}

// queueStrike records the swing the pass decided on; the tick hands it to the
// monster's strike worker only once the pass's pushes are out (handStrike,
// tick step 6), so a stop queued on the same pass reaches the zone before the
// blow. No swing is made unless the runtime holds every store the blow reads
// (MonsterAIConfig): the character, equipment and item stores.
func (a *monsterAI) queueStrike(b *brain, target int64, skill combat.MonsterSkill) {
	if a.deps.chars == nil || a.deps.eq == nil || a.deps.items == nil {
		return
	}
	a.handoffs = append(a.handoffs, strikeHandoff{b: b, job: strikeJob{m: b.m, target: target, skill: skill}})
}

// handStrike hands a swing to the monster's strike worker, started on its
// first swing. The worker runs the blow's reads and writes (monsterStrike:
// chars.ApplyDamage, the wear, and a kill's whole death under the character's
// kill lock -- killLock, round 551: the read-back, SetLeveling and RespawnHP
// or, under -player-dead-state, markDead) off the tick goroutine, so a slow
// store, or a wait on that lock, never stalls a pass. OWN DESIGN: the
// channel holds one swing; while one runs and one waits, a further swing is
// dropped with a trace line rather than queued -- the cooldown between swings
// (3000 ms for a Mangyang) is far longer than a store write, so a drop means a
// stalled store, not a fight. Runs on the tick goroutine outside a.mu, the
// only goroutine that touches a brain's channel (step 2 closes it there too).
func (a *monsterAI) handStrike(h strikeHandoff) {
	b := h.b
	if b.strikes == nil {
		b.strikes = make(chan strikeJob, 1)
		go a.strikeWorker(b.id, b.strikes)
	}
	select {
	case b.strikes <- h.job:
		a.tracef("ai: monster %d swings at %d", b.id, h.job.target)
	default:
		a.tracef("ai: monster %d swing at %d dropped: the previous strike is still running", b.id, h.job.target)
	}
}

// strikeWorker runs monster id's swings in order until its channel closes,
// telling strikeDone of each one it finishes.
func (a *monsterAI) strikeWorker(id int64, jobs <-chan strikeJob) {
	for job := range jobs {
		a.runStrike(id, job)
		if a.strikeDone != nil {
			a.strikeDone(id)
		}
	}
}

// runStrike resolves one swing -- the same blow the counter dealt
// (monsterStrike, unchanged), on the target's level as the world entity
// caches it (round 555; until then one chars.GetByID per swing) -- pushes it
// to the zone as an OpMonsterAttacked through the runtime's push (the zone
// broadcast under each session's wire lock, or a test's recorder), and
// reports a kill to the tick (kills). The blow resolves at the swing's start;
// the client delays only the drawing, to its clip's hit event. A swing already
// handed over still resolves if the target changed zone or the monster died
// between the tick's validity test and monsterStrike -- the same class of
// window as the flag-off counter's, disclosed (round 547); a target who left
// the world inside that window has no entity to read a level from, and the
// row is read then, the one store read left before the blow.
//
// A panic inside the blow -- a store's own -- is logged and the swing
// dropped, and the worker goes on to the next (round 547): a goroutine's
// panic is the process's, so without this one bad store write would take the
// whole server down. The recover covers the push too, so a panic inside
// gateway.Session.Send is swallowed the same way; broadcast releases each
// session's wire lock by defer for exactly that reason (round 550: with the
// unlock after the Send, a swallowed panic left the lock held and the next
// tick blocked on it for ever). A runtime built without a logger -- only a
// test's -- logs through slog's default rather than dropping the panic
// silently.
func (a *monsterAI) runStrike(id int64, job strikeJob) {
	defer func() {
		if r := recover(); r != nil {
			logger := a.logger
			if logger == nil {
				logger = slog.Default()
			}
			logger.Error("ai: strike panicked, swing dropped", "monster", id, "target", job.target, "panic", r, "stack", string(debug.Stack()))
		}
	}()
	ctx := context.Background()
	// One world-hub read for the dead check and the level. A swing handed
	// over before its target died -- another monster's kill, or this one's
	// own previous swing, landing inside the hand-off window -- is not made:
	// the engine's IsValidTarget refuses a life state other than 1 on every
	// update, and a blow on a dead character would charge the death penalty
	// twice (round 549). Nothing is pushed.
	level, inWorld := 0, false
	if a.world != nil {
		if e, ok := a.world.EntityByCharacterID(job.target); ok {
			if e.Life == world.LifeDead {
				a.tracef("ai: monster %d swing at %d dropped: the target is dead", id, job.target)
				return
			}
			level, inWorld = e.Level, true
		}
	}
	if !inWorld {
		if c, err := a.deps.chars.GetByID(ctx, job.target); err == nil && c != nil {
			level = c.Level
		}
	}
	out, err := monsterStrike(ctx, a.deps, job.m, job.skill, job.target, level)
	if err != nil {
		if a.logger != nil {
			a.logger.Warn("ai: strike failed", "monster", id, "target", job.target, "err", err)
		}
		return
	}
	if out.dropped {
		// The blow left the target at 0 but lost the kill under her kill
		// lock (round 550; killLock since round 551) -- another kill landed
		// between the dead check above and the read-back, and she is dead or
		// respawned already: this blow goes unreported, and nothing is pushed.
		a.tracef("ai: monster %d swing at %d dropped: another blow's kill got there first", id, job.target)
		return
	}
	a.tracef("ai: monster %d strike %d for %d (HP %d)%s%s", id, job.target, out.damage, out.hp,
		map[bool]string{true: " blocked", false: ""}[out.blocked], map[bool]string{true: " killed", false: ""}[out.died])
	if out.died {
		// Only while the brain is there to drain it (battleTick). A worker
		// finishing after the tick dropped the brain -- the monster killed by
		// the player inside the worker's window -- would otherwise leave an
		// entry nothing collects: the removal loop's delete has run, and ids
		// are never reused (combat.Hub's nextID) (round 547).
		a.mu.Lock()
		if _, live := a.brains[id]; live {
			a.kills[id] = struct{}{}
		}
		a.mu.Unlock()
	}
	a.emit(monsterPush{zone: job.m.Zone, cell: combat.CellOf(job.m.Zone, job.m.X, job.m.Z), id: id,
		packet: &proto.Packet{Opcode: OpMonsterAttacked, Data: out.message(id, job.target).Encode()}}, nil)
	// Round 640: a blow that broke the target's wall ends it now, after the
	// push that reports the blow (walls.go endBrokenWall).
	if out.wall.Broke {
		endBrokenWall(a.world, job.target)
	}
}

// heldKey names one keep-up as the release test sees it: the monster it is
// on, and the zone the world hub places its attacker in.
type heldKey struct {
	monster int64
	zone    string
}

// keptUpSet is every keep-up running now, keyed by its monster and its
// attacker's zone: one pass over the world hub (AllEntities) and one
// keepUp.Target per player. nil when no player has one.
func (a *monsterAI) keptUpSet() map[heldKey]struct{} {
	var held map[heldKey]struct{}
	for _, e := range a.world.AllEntities() {
		t, ok := keepUp.Target(e.CharacterID)
		if !ok {
			continue
		}
		if held == nil {
			held = make(map[heldKey]struct{})
		}
		held[heldKey{t, e.Zone}] = struct{}{}
	}
	return held
}

// keptUpOn reports whether any player in b's zone has a keep-up running
// against it (keepUp.Target), the hold's release test. Only players this
// runtime's world hub places in the monster's zone count: a keep-up whose
// attacker is elsewhere ends at its next swing anyway (armKeepUp's zone test).
// The set is built once per tick, on the first BATTLE brain that asks (round
// 544: until then every held monster took its own zone snapshot each tick,
// O(held x players) and one allocation per held monster). The locks are the
// ones it took before, in the same order: under a.mu, the world hub's, then
// the keep-up's.
func (a *monsterAI) keptUpOn(b *brain) bool {
	if a.world == nil {
		return false
	}
	if a.heldTick != a.tickN {
		a.held, a.heldTick = a.keptUpSet(), a.tickN
	}
	_, ok := a.held[heldKey{b.id, b.m.Zone}]
	return ok
}

// newBrain builds a monster's machine in SPAWN (AI::CTactics::Init's one
// ChangeState(0), ai.NewMachine) with the four states the runtime runs. It
// adopts the heading the monster hatched with (combat.Monster.Heading, rolled
// at the spawn by the hub's Nest_Hatch roll) rather than rolling its own:
// until round 542 it drew ai.SpawnHeading here, a heading nothing outside the
// brain knew, so a spawn push could not have carried it.
func (a *monsterAI) newBrain(m combat.Monster) *brain {
	b := &brain{id: m.ID, m: m, heading: m.Heading}
	// The acquisition radius, ctx+0x15c (BindSkillsAndRanges 0x53fa23..
	// 0x53fa4f): BCRadius + the detection distance, the stand-in for a
	// server-database column (ai.TacticsDetectionDistance). Under -monster-
	// aggro, AI::CTactics::Init's two rolls in its order: the aggression byte
	// (0x53f5be..0x53f5e1), then tactics timer 1's period (0x53f745..
	// 0x53f765 -> ArmTimer), which starts fired (scanDueAt zero).
	b.detection, _ = ai.DetectionRadius(m.BCRadius, ai.TacticsDetectionDistance)
	if a.aggro {
		b.aggressive = ai.Aggressive(a.rng, ai.TacticsAggressionMode, ai.TacticsAggressionPct)
		b.scanPeriodMs = ai.ScanPeriodMs(a.rng, ai.TacticsFlags)
	}
	var states [ai.StateCount]ai.Enterer
	states[ai.StateIdle] = &brainState{a: a, b: b, state: ai.StateIdle, enter: func() { a.enterIdle(b) }}
	states[ai.StateWander] = &brainState{a: a, b: b, state: ai.StateWander, enter: func() { a.enterWander(b) },
		refuses: func() bool { return !(b.m.RunSpeed > 0) }}
	states[ai.StateBattle] = &brainState{a: a, b: b, state: ai.StateBattle, enter: func() { a.enterBattle(b) },
		leave: func() { a.leaveBattle(b) }}
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
	// leave is the state's OnLeave override, nil for the base's `return 0`
	// (BATTLE's, 0x0055a240).
	leave func()
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

// OnLeave is slot 4: the state's own override when it has one (BATTLE's,
// leaveBattle), else the base's `return 0`.
func (s *brainState) OnLeave(ai.State) {
	if s.leave != nil {
		s.leave()
	}
}

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
	a.startLeg(b, destX, destZ, ai.MotionMode(ai.StateWander, b.m.WalkSpeed, b.m.RunSpeed), "leg")
}

// enterHoming is CAIState_HOMING::OnEnter (0x0055a540): the dwell
// (AIState_DwellMs at 0x55a5f1, the 50 000 ms default arm), MoveHome
// (0x55a602, ai.HomeDestination with MonsterRoamRadius), the re-aggro window
// (+0x1c at 0x55a60e..0x55a63e: trunc(ctx+0x15c / run speed x 1000) ms,
// ai.HomingReaggroDelayMs, read by the update's ReaggroWindowPassed), the
// clip (FUN_00541820 at 0x55a64a: Handler_110 gives 1, the run clip, for
// HOMING) and SetTarget(0) (0x55a67a). Not modelled: the timer armed at
// 0x55a5e0 and the +0x164 sign.
func (a *monsterAI) enterHoming(b *brain) {
	b.dwellMs = ai.DwellMs(a.rng, ai.StateHoming)
	b.homingDestX, b.homingDestZ = ai.HomeDestination(a.rng, b.m.HomeX, b.m.HomeZ, b.m.X, b.m.Z, a.roamRadius)
	b.homingBlackoutMs = ai.HomingReaggroDelayMs(b.detection, b.m.RunSpeed)
	if a.aggro && b.aggressive {
		a.tracef("ai: monster %d homing, noticing nobody for %d ms", b.id, b.homingBlackoutMs)
	}
	a.startLeg(b, b.homingDestX, b.homingDestZ, ai.MotionMode(ai.StateHoming, b.m.WalkSpeed, b.m.RunSpeed), "leg")
	b.target = 0
}

// enterBattle is CAIState_BATTLE::OnEnter (0x00559fb0), which calls only the
// base OnEnter for its timeout: none (ai.BattleDwellMs). Its timers 3/4
// (0x559fd8/0x559fef), gathering and slot-11 call are not modelled; its clip
// call (FUN_00541820 at 0x55a04a, Handler_110: the run clip) and timer 5
// (0x55a018, armed fired: the first swing is immediate) are what battleTick
// runs. It issues no stop (0x559fb0..0x55a08b): with -monster-battle on the
// chase replaces a leg under way, or the tick stops it in the band.
//
// With the flag off, OWN DESIGN, the interim hold: a monster still on a leg is
// stopped here with one stop push. A monster struck mid-leg was already
// stopped at the blow (noteStruck), so this finds it standing.
func (a *monsterAI) enterBattle(b *brain) {
	b.dwellMs = ai.BattleDwellMs
	b.unheldTicks = 0
	b.chaseAimed = false
	if !a.battle && b.m.Moving {
		if m, ok := a.monsters.StopMotion(b.id); ok {
			b.m = m
			a.queueStop(m)
		}
	}
}

// leaveBattle is CAIState_BATTLE::OnLeave (0x0055a240), which calls only
// AI::CTactics::ResetThreat (0x0053fb20, `call 0x53fb20` at 0x55a243) -- run
// by ai.Machine on every exit from BATTLE, the 0x23/0x27/0x2a releases among
// them (round 555). ResetThreat zeroes the selector's armed pick, `xor
// eax,eax` 0x53fb28 ... `mov ecx,[edi+0x9c]; mov [ecx+0x44],eax`
// 0x53fb78..0x53fb7e (the same +0x44 PickSkill fills through ArmNextAttack
// and Handler_0e8 reads first), so every BATTLE entry draws its skill afresh
// at that fight's distance; until this round a pick armed but not fired --
// a Yeoha that drew its range-7 skill at 60 units and lost its target on the
// way in -- survived the exit and was swung in the next fight without a
// draw. The rest of what ResetThreat zeroes -- the two threat seats
// +0xbc..+0xe0 (the target among them, which IDLE's OnEnter zeroes here
// through SetTarget(0)), the +0xac byte and +0xa4/+0xa8 -- has no counterpart
// in a brain (the threat table is mob-threat-retarget's). The cooldown
// (lastSwing) is the action machine's, not a threat seat, and persists.
func (a *monsterAI) leaveBattle(b *brain) {
	b.armed, b.hasArmed = combat.MonsterSkill{}, false
}

// startLeg starts a leg to (destX, destZ) in clip mode (0 walk, 1 run) and
// queues its push. The speed follows the mode: the walk speed for 0, the run
// speed for 1 -- an inference (docs/protocol/monster_ai.md, "srrevamp's own
// monster protocol": the mover's use of +0x155/+0x174 is untraced). The
// heading turns toward the destination, as the move's start does
// (CGObjMoverByDest 0x0048c330 -> its slot 10, 0x0048c660, SetHeading). what
// names the leg in the trace line: "leg" for WANDER and HOMING, "BATTLE
// chase" for the chase.
func (a *monsterAI) startLeg(b *brain, destX, destZ float64, mode uint8, what string) {
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
	a.queue(m, &MonsterMoved{
		MonsterID: m.ID, X: float32(m.X), Z: float32(m.Z),
		DestX: float32(destX), DestZ: float32(destZ), Speed: float32(speed), Mode: mode,
	})
	a.tracef("ai: monster %d %s to (%.0f,%.0f) speed %.0f mode %d", m.ID, what, destX, destZ, speed, mode)
}

// queueStop queues the stop push for a monster standing at m's position:
// destination = position, with the leg's own speed and mode
// (docs/protocol/monster_ai.md, "srrevamp's own monster protocol", the stop).
func (a *monsterAI) queueStop(m combat.Monster) {
	a.queue(m, &MonsterMoved{
		MonsterID: m.ID, X: float32(m.X), Z: float32(m.Z),
		DestX: float32(m.X), DestZ: float32(m.Z), Speed: float32(m.MoveSpeed), Mode: m.MoveMode,
	})
}

// queue collects mv, a push about m, for after the pass. Its recipients are
// picked by m's cell from m's own float64 position (round 656's review: not
// the push's float32 copy, which can round a monster a hair from a region
// line onto the other side of it).
func (a *monsterAI) queue(m combat.Monster, mv *MonsterMoved) {
	a.pending = append(a.pending, monsterPush{zone: m.Zone, cell: combat.CellOf(m.Zone, m.X, m.Z), id: m.ID,
		packet: &proto.Packet{Opcode: OpMonsterMoved, Data: mv.Encode()}})
}

// emit sends one push: to a.push when a test has installed one, else to the
// players whose window holds the monster's cell (deliver). buf is scratch
// space for the recipients, returned for the caller to keep.
func (a *monsterAI) emit(p monsterPush, buf []*gateway.Session) []*gateway.Session {
	if a.push != nil {
		a.push(p.zone, p.packet)
		return buf
	}
	return a.deliver(p, buf)
}

// deliver is the production push (round 656): every session whose area of
// interest holds p's cell (aoi.go), each under its wire lock -- the AOI
// runtime's watcher index when it is installed, else the zone's players
// filtered by the cell each stands in. Until round 656 it went to every
// session in the zone, which under -single-frame is the whole world.
//
// A stalled client no longer blocks the tick for ever: gateway.Session.Send
// gives up after gateway.SendTimeout and closes that connection, so the
// tick waits at most that long once and then goes on without it (round 656).
func (a *monsterAI) deliver(p monsterPush, buf []*gateway.Session) []*gateway.Session {
	buf = buf[:0]
	if v := aoiFor(a.monsters); v != nil {
		// Each recipient is checked at the send, under its wire lock (round
		// 656's second review): the monster alive, in its window, and no
		// enter for it still owed (mayShowLeg). Without the check a pass could
		// send a leg for a monster a view move had just brought into the
		// window before that view's enter went out, and the client answers a
		// leg for a body it has never been told about by asking for the whole
		// list (World3D._on_monster_moved).
		buf = v.appendWatchers(buf, p.cell)
		for _, sess := range buf {
			a.sendIfShown(v, sess, p)
		}
		return buf
	} else if a.world != nil {
		for _, e := range a.world.EntitiesInZone(p.zone) {
			if e.Session != nil && combat.CellOf(e.Zone, e.Pos.X, e.Pos.Z).Near(p.cell, AOIRadius) {
				buf = append(buf, e.Session)
			}
		}
	}
	for _, sess := range buf {
		a.sendUnderWireLock(sess, p.packet)
	}
	return buf
}

// sendIfShown is sendUnderWireLock for a push about monster p.id, sent only
// when mayShowLeg allows it at the send. A push with no id is sent as it is.
func (a *monsterAI) sendIfShown(v *monsterAOI, sess *gateway.Session, p monsterPush) {
	l := a.wireLock(sess)
	l.Lock()
	defer l.Unlock()
	if p.id != 0 && !v.mayShowLeg(sess.ID(), p.id) {
		return
	}
	_ = sess.Send(p.packet)
}

// sendUnderWireLock writes p to sess under its wire lock, released by defer
// (round 550): a strike worker's push runs under runStrike's recover, so a
// panic inside Send must not leave the lock held -- until this round it did,
// and the next tick's push to that session, and handleMonsterList on it,
// would have blocked for ever instead of the process crashing.
func (a *monsterAI) sendUnderWireLock(sess *gateway.Session, p *proto.Packet) {
	l := a.wireLock(sess)
	l.Lock()
	defer l.Unlock()
	_ = sess.Send(p)
}

// wireLock is sess's motion-wire lock (monsterWireLock, aoi.go). The tick
// holds it while it writes a push to sess, and handleMonsterList holds it
// from reading the hub until both of its replies are written, so a push for a
// newer leg can never reach a client ahead of a list built before that leg
// began: the client would take the list's older destination last and walk
// the body there (round 537). Per session, so a stalled client holds up only
// its own replies and the tick, never another session's reader. It lives on
// the session and goes with it.
func (a *monsterAI) wireLock(sess *gateway.Session) *sync.Mutex {
	return monsterWireLock(sess)
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
