package session

import (
	"bufio"
	"bytes"
	"context"
	"log/slog"
	"math"
	"math/rand"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/ai"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/quest"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// The monster AI tick (round 537). The AI tests below run on a seeded rng,
// an injected clock stepped by MonsterAITick and a recorder in place of the
// zone broadcast, and never sleep. The two wire-order tests near the end are
// about goroutines, and they wait a bounded 300 ms for a goroutine to block.

// testMangyang is the roster's Mangyang as the AI sees it: walk 8 and run 22
// (characterdata cols 46/47, docs/protocol/monster_ai.md "The roster's real
// walk and run speeds") and BCRadius 6 (col 50, cmd/server's roster).
var testMangyang = combat.Species{Name: "Mangyang", CodeName: "MOB_CH_MANGNYANG", RefObjID: 1933, Level: 1,
	BCRadius: 6, WalkSpeed: 8, RunSpeed: 22}

// aiT0 is the injected clock's start.
var aiT0 = time.Date(2026, 9, 24, 12, 0, 0, 0, time.UTC)

// installMonsterAIForTest installs a runtime over hub and monsters with a
// seeded rng and push (nil: the zone broadcast), and puts the runtime back to
// nil when the test ends, so no other test's one-reply helper ever meets a
// motion list or a push.
func installMonsterAIForTest(t *testing.T, hub *world.Hub, monsters *combat.Hub, seed int64, push func(zone string, p *proto.Packet)) *monsterAI {
	t.Helper()
	a := newMonsterAI(hub, monsters, nil, MonsterAIConfig{}, rand.New(rand.NewSource(seed)), push)
	monsterAIRuntime.Store(a)
	t.Cleanup(func() { monsterAIRuntime.Store(nil) })
	return a
}

// newAIHub is a monster hub with Nest_Hatch's roll (ai.SpawnHeading) installed
// over an rng seeded with seed, so the monsters the seeded AI tests hatch face
// varied headings again. Round 542 moved the heading roll out of the brain
// into the hub, and a hub given no roll hatches every monster at 0
// (combat.Hub.SpawnSpecies), which had these tests start every WANDER from
// heading 0 (round 544).
func newAIHub(seed int64) *combat.Hub {
	monsters := combat.NewHub()
	recordingHeadingRoll(monsters, seed)
	return monsters
}

// pushRecorder stands in for the zone broadcast: the legs and stops
// (OpMonsterMoved) and, since round 546, the monster's own blows
// (OpMonsterAttacked, which the strike worker pushes off the tick).
type pushRecorder struct {
	mu      sync.Mutex
	moves   []MonsterMoved
	strikes []MonsterAttacked
	other   int
}

func (r *pushRecorder) push(_ string, p *proto.Packet) {
	r.mu.Lock()
	defer r.mu.Unlock()
	switch p.Opcode {
	case OpMonsterMoved:
		if mv, err := DecodeMonsterMoved(p.Data); err == nil {
			r.moves = append(r.moves, *mv)
			return
		}
	case OpMonsterAttacked:
		if s, err := DecodeMonsterAttacked(p.Data); err == nil {
			r.strikes = append(r.strikes, *s)
			return
		}
	}
	r.other++
}

func (r *pushRecorder) of(id int64) []MonsterMoved {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []MonsterMoved
	for _, mv := range r.moves {
		if mv.MonsterID == id {
			out = append(out, mv)
		}
	}
	return out
}

// strikesOf is the blows monster id has pushed so far.
func (r *pushRecorder) strikesOf(id int64) []MonsterAttacked {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []MonsterAttacked
	for _, s := range r.strikes {
		if s.MonsterID == id {
			out = append(out, s)
		}
	}
	return out
}

func (r *pushRecorder) reset() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.moves, r.strikes, r.other = nil, nil, 0
}

func isStop(mv MonsterMoved) bool { return mv.DestX == mv.X && mv.DestZ == mv.Z }

// stateOf is monster id's AI state.
func stateOf(t *testing.T, a *monsterAI, id int64) ai.State {
	t.Helper()
	a.mu.Lock()
	defer a.mu.Unlock()
	b := a.brains[id]
	if b == nil {
		t.Fatalf("monster %d has no brain", id)
	}
	return b.machine.State()
}

func TestMonsterAIRuntimeNilByDefault(t *testing.T) {
	if monsterAIRuntime.Load() != nil {
		t.Fatal("the monster AI is installed with nothing having asked for it: -monster-ai is off by default")
	}
}

// A Mangyang left to itself for two minutes walks legs at its walk speed in
// the walk clip -- and runs home at its run speed only if it strays -- and no
// leg starts farther from its spawn than the roam radius plus one longest
// leg, the most a leg IDLE did not stop can carry it past the radius.
func TestMonsterAIWandersAtWalkSpeedInsideTheRoamRadius(t *testing.T) {
	monsters := newAIHub(1)
	m := monsters.SpawnSpecies("jangan", testMangyang, 0, 0, 0, 1000, 0, 0, 0)
	rec := &pushRecorder{}
	installMonsterAIForTest(t, world.NewHub(), monsters, 1, rec.push)

	now := aiT0
	for i := 0; i <= 1200; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	moves := rec.of(m.ID)
	if len(moves) == 0 {
		t.Fatal("two minutes and not one leg")
	}
	_, longest := ai.WanderDistanceRange()
	walked := 0
	for _, mv := range moves {
		switch mv.Mode {
		case 0:
			walked++
			if mv.Speed != 8 {
				t.Errorf("a walk-clip leg at %g, want the walk speed 8", mv.Speed)
			}
		case 1:
			if mv.Speed != 22 {
				t.Errorf("a run-clip leg at %g, want the run speed 22", mv.Speed)
			}
		default:
			t.Errorf("mode %d", mv.Mode)
		}
		if isStop(mv) {
			t.Errorf("a stop push with no blow: %+v", mv)
		}
		if d := math.Hypot(float64(mv.X), float64(mv.Z)); d > MonsterRoamRadius+longest {
			t.Errorf("a leg starts %.1f from home, beyond %g + %g", d, MonsterRoamRadius, longest)
		}
	}
	if walked == 0 {
		t.Error("no WANDER leg (mode 0) in two minutes")
	}
	t.Logf("%d legs, %d of them walked", len(moves), walked)
}

// A Mangyang 300 units from its spawn is not given another outward leg: its
// next push runs it home (mode 1, the run speed) toward a point MoveHome puts
// R/3 .. R/3 + trunc(R/3) from home along the line to the monster, and it is
// in IDLE on the tick it arrives.
func TestMonsterAIHomingFromBeyondTheRoamRadius(t *testing.T) {
	monsters := newAIHub(2)
	m := monsters.SpawnSpecies("jangan", testMangyang, 0, 0, 0, 1000, 0, 0, 0)
	// Carry it 300 units east: two mover steps (the 160-unit cap).
	monsters.SetMotion(m.ID, 300, 0, 300, 1)
	monsters.StepAll(1)
	monsters.StepAll(1)
	if got, _ := monsters.Get(m.ID); got.X != 300 || got.Moving {
		t.Fatalf("setup: the monster is at %g (moving %v), want standing at 300", got.X, got.Moving)
	}
	rec := &pushRecorder{}
	a := installMonsterAIForTest(t, world.NewHub(), monsters, 2, rec.push)

	now := aiT0
	monsterAITick(now)
	moves := rec.of(m.ID)
	if len(moves) != 1 {
		t.Fatalf("the first tick pushed %d moves, want exactly the homing leg: %+v", len(moves), moves)
	}
	leg := moves[0]
	if leg.Mode != 1 || leg.Speed != 22 {
		t.Fatalf("the homing leg is mode %d at %g, want mode 1 at the run speed 22", leg.Mode, leg.Speed)
	}
	lo, hi := ai.HomingScatterRange(MonsterRoamRadius)
	if leg.X != 300 || leg.Z != 0 || math.Abs(float64(leg.DestZ)) > 1e-3 ||
		float64(leg.DestX) < lo-1e-3 || float64(leg.DestX) > hi+1e-3 {
		t.Fatalf("the homing leg %+v: want from (300, 0) to x in [%.2f, %.2f] on the line home", leg, lo, hi)
	}
	if st := stateOf(t, a, m.ID); st != ai.StateHoming {
		t.Fatalf("state %v, want HOMING", st)
	}

	arrived := false
	for i := 0; i < 200 && !arrived; i++ {
		now = now.Add(MonsterAITick)
		monsterAITick(now)
		cur, _ := monsters.Get(m.ID)
		st := stateOf(t, a, m.ID)
		if ai.HasArrived(cur.X, cur.Z, float64(leg.DestX), float64(leg.DestZ)) {
			if st != ai.StateIdle {
				t.Fatalf("arrived at (%.1f, %.1f) and still %v", cur.X, cur.Z, st)
			}
			arrived = true
		} else if st != ai.StateHoming {
			t.Fatalf("left HOMING for %v at (%.1f, %.1f) before arriving", st, cur.X, cur.Z)
		}
	}
	if !arrived {
		t.Fatal("never arrived home in 20 s")
	}
	if n := len(rec.of(m.ID)); n != 1 {
		t.Fatalf("%d pushes on the way home, want the one leg", n)
	}
}

// The trap: IDLE::OnEnter (0x559c80) does not stop a leg under way. A
// WANDER spell that ends before its leg does leaves the monster in IDLE and
// still walking, and nothing is pushed.
func TestMonsterAIIdleDoesNotStopALegUnderWay(t *testing.T) {
	monsters := newAIHub(3)
	m := monsters.SpawnSpecies("jangan", testMangyang, 0, 0, 0, 1000, 0, 0, 0)
	rec := &pushRecorder{}
	a := installMonsterAIForTest(t, world.NewHub(), monsters, 3, rec.push)

	now := aiT0
	monsterAITick(now)
	prev := stateOf(t, a, m.ID)
	walkingIdles := 0
	for i := 0; i < 1200; i++ {
		now = now.Add(MonsterAITick)
		before := len(rec.of(m.ID))
		monsterAITick(now)
		st := stateOf(t, a, m.ID)
		if prev == ai.StateWander && st == ai.StateIdle {
			cur, _ := monsters.Get(m.ID)
			if cur.Moving {
				walkingIdles++
			}
			if n := len(rec.of(m.ID)); n != before {
				t.Fatalf("entering IDLE pushed %d move(s)", n-before)
			}
		}
		prev = st
	}
	if walkingIdles == 0 {
		t.Fatal("no WANDER spell ended mid-leg in two minutes, so the trap was never exercised")
	}
	for _, mv := range rec.of(m.ID) {
		if isStop(mv) {
			t.Fatalf("a stop push: %+v", mv)
		}
	}
}

// Control: a species that cannot run never wanders (WANDER::OnEnter refuses
// on a run speed not above 0, and the refusal drops it back into IDLE) and
// never goes home (IDLE's roam check is skipped).
func TestMonsterAIRunSpeedZeroNeverWalks(t *testing.T) {
	monsters := newAIHub(4)
	still := testMangyang
	still.WalkSpeed, still.RunSpeed = 0, 0
	m := monsters.SpawnSpecies("jangan", still, 0, 0, 0, 1000, 0, 0, 0)
	rec := &pushRecorder{}
	a := installMonsterAIForTest(t, world.NewHub(), monsters, 4, rec.push)
	now := aiT0
	for i := 0; i <= 1200; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	if n := len(rec.of(m.ID)); n != 0 {
		t.Fatalf("%d pushes for a monster with no run speed", n)
	}
	if cur, _ := monsters.Get(m.ID); cur.Moving || cur.X != 0 || cur.Z != 0 {
		t.Fatalf("it moved: %+v", cur)
	}
	if st := stateOf(t, a, m.ID); st != ai.StateIdle {
		t.Fatalf("state %v, want IDLE", st)
	}
}

// tickUntilWandering ticks until monster id is in WANDER and on a leg.
func tickUntilWandering(t *testing.T, a *monsterAI, monsters *combat.Hub, id int64, now time.Time) time.Time {
	t.Helper()
	for i := 0; i < 600; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
		if cur, _ := monsters.Get(id); cur.Moving && stateOf(t, a, id) == ai.StateWander {
			return now
		}
	}
	t.Fatal("no WANDER leg in a minute")
	return now
}

// NEGATIVE N1, the keep-up regression. A Mangyang struck mid-leg by a player
// whose keep-up is on it gets exactly one stop push on the next tick, then no
// leg and no step for a minute (BATTLE has no dwell: 0x558b70/0x558b90), and
// goes back to IDLE once the keep-up ends. Without the hold the leg goes on
// and new ones start, and keepup.go's reach test would end the player's run.
func TestMonsterAIHoldsAStruckMonsterWhileTheKeepUpRuns(t *testing.T) {
	monsters := combat.NewHub()
	m := monsters.SpawnSpecies("jangan", testMangyang, 0, 0, 0, 1000, 0, 0, 0)
	hub := world.NewHub()
	const attacker int64 = 91001
	hub.Enter(gateway.NewTestSession(91001), attacker, "Aria", "jangan", world.Position{})
	rec := &pushRecorder{}
	a := installMonsterAIForTest(t, hub, monsters, 5, rec.push)

	now := tickUntilWandering(t, a, monsters, m.ID, aiT0)
	keepUp.Arm(attacker, m.ID, time.Hour, func() (time.Duration, bool) { return 0, false })
	t.Cleanup(func() { keepUp.Cancel(attacker) })
	noteStruck(monsters, m.ID, attacker)
	rec.reset()

	monsterAITick(now)
	now = now.Add(MonsterAITick)
	moves := rec.of(m.ID)
	if len(moves) != 1 || !isStop(moves[0]) {
		t.Fatalf("the tick after the blow pushed %+v, want exactly one stop (destination = position)", moves)
	}
	if st := stateOf(t, a, m.ID); st != ai.StateBattle {
		t.Fatalf("state %v after the blow, want BATTLE", st)
	}
	held, _ := monsters.Get(m.ID)
	if float64(moves[0].X) != float64(float32(held.X)) || float64(moves[0].Z) != float64(float32(held.Z)) {
		t.Fatalf("the stop push is at (%g, %g), the monster at (%g, %g)", moves[0].X, moves[0].Z, held.X, held.Z)
	}

	rec.reset()
	for i := 0; i < 600; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
		cur, _ := monsters.Get(m.ID)
		if cur.X != held.X || cur.Z != held.Z || cur.Moving {
			t.Fatalf("after %d ticks the held monster is at (%.2f, %.2f), moving %v; it was struck at (%.2f, %.2f)",
				i+1, cur.X, cur.Z, cur.Moving, held.X, held.Z)
		}
	}
	if n := len(rec.of(m.ID)); n != 0 {
		t.Fatalf("%d moves pushed for a held monster in a minute: %+v", n, rec.of(m.ID))
	}
	if st := stateOf(t, a, m.ID); st != ai.StateBattle {
		t.Fatalf("state %v a minute into the hold, want BATTLE (no dwell expires it)", st)
	}

	keepUp.Cancel(attacker)
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	monsterAITick(now)
	if st := stateOf(t, a, m.ID); st != ai.StateIdle {
		t.Fatalf("state %v two ticks after the keep-up ended, want IDLE", st)
	}
}

// NEGATIVE N1b, the stop is at the blow, not at the next tick. A Mangyang
// walking straight away from its attacker at 8 u/s is struck at
// int(reach) + 2.9, the edge of the band. One tick and one re-use delay later
// it is still in reach and the keep-up still names it. Stopped only when the
// tick drains the blow, it would first walk 0.8 units -- to int(reach) + 3.7,
// out of reach -- and the next repeat would end the run.
func TestMonsterAIStrikeAtTheReachEdgeKeepsTheKeepUpInReach(t *testing.T) {
	const weaponRange = 6 // a sword's Range (itemdata col 94), as keepup_test.go
	_, reach := combat.ApproachBand(combat.PlayerBCRadius, testMangyang.BCRadius, combat.EffectiveRange(0, weaponRange))
	edge := float64(int(reach)) + 2.9
	monsters := combat.NewHub()
	m := monsters.SpawnSpecies("jangan", testMangyang, edge, 0, 0, 1000, 0, 0, 0)
	hub := world.NewHub()
	const attacker int64 = 91002
	hub.Enter(gateway.NewTestSession(91002), attacker, "Aria", "jangan", world.Position{})
	rec := &pushRecorder{}
	a := installMonsterAIForTest(t, hub, monsters, 6, rec.push)

	now := aiT0
	monsterAITick(now) // the brain hatches into IDLE
	now = now.Add(MonsterAITick)
	// Walking directly away at the walk speed (IDLE does not stop a leg).
	monsters.SetMotion(m.ID, edge+500, 0, 8, 0)
	me := world.Position{}
	if cur, _ := monsters.Get(m.ID); !keepUpInReach(me, cur, weaponRange) {
		t.Fatalf("setup: %.1f units is not in reach %g", cur.X, reach)
	}
	keepUp.Arm(attacker, m.ID, time.Hour, func() (time.Duration, bool) { return 0, false })
	t.Cleanup(func() { keepUp.Cancel(attacker) })
	noteStruck(monsters, m.ID, attacker)

	monsterAITick(now)
	now = now.Add(MonsterAITick)
	// One re-use delay: a second (the test's; the check holds for any).
	for i := 0; i < 10; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	cur, _ := monsters.Get(m.ID)
	if !keepUpInReach(me, cur, weaponRange) {
		t.Fatalf("struck at %.1f, the monster is at %.2f a second later: out of reach (int %d > %d + 2), so the keep-up ends",
			edge, cur.X, int(cur.X), int(reach))
	}
	if tgt, ok := keepUp.Target(attacker); !ok || tgt != m.ID {
		t.Fatalf("keep-up target %d,%v, want monster %d", tgt, ok, m.ID)
	}
	if st := stateOf(t, a, m.ID); st != ai.StateBattle {
		t.Fatalf("state %v, want BATTLE", st)
	}
}

// holdForTest puts attacker in the zone, installs the runtime, hatches the
// Mangyang into IDLE and returns the runtime, the hub, the monster id and the
// clock after that tick.
func holdForTest(t *testing.T, hub *world.Hub, seed int64) (*monsterAI, *combat.Hub, int64, time.Time) {
	t.Helper()
	monsters := newAIHub(seed)
	m := monsters.SpawnSpecies("jangan", testMangyang, 0, 0, 0, 1000, 0, 0, 0)
	a := installMonsterAIForTest(t, hub, monsters, seed, (&pushRecorder{}).push)
	now := aiT0
	monsterAITick(now) // the brain hatches into IDLE
	return a, monsters, m.ID, now.Add(MonsterAITick)
}

// armForTest arms a keep-up that never swings and cancels it when the test
// ends.
func armForTest(t *testing.T, characterID, monsterID int64) {
	t.Helper()
	keepUp.Arm(characterID, monsterID, time.Hour, func() (time.Duration, bool) { return 0, false })
	t.Cleanup(func() { keepUp.Cancel(characterID) })
}

// NEGATIVE R1 (round 539), the OpAttack gap. performAttack notes the blow,
// and the handler arms the keep-up only after performAttack returns. A tick
// that drains the blow and a second tick that lands before the arm must not
// release the monster: round 537 released it on the first tick that found no
// keep-up.
func TestMonsterAIHoldOutlastsTheGapBeforeTheKeepUpIsArmed(t *testing.T) {
	hub := world.NewHub()
	const attacker int64 = 91003
	hub.Enter(gateway.NewTestSession(91003), attacker, "Aria", "jangan", world.Position{})
	a, _, id, now := holdForTest(t, hub, 11)

	noteStruck(a.monsters, id, attacker)
	monsterAITick(now) // drains the blow: BATTLE
	now = now.Add(MonsterAITick)
	if st := stateOf(t, a, id); st != ai.StateBattle {
		t.Fatalf("state %v after the blow, want BATTLE", st)
	}
	monsterAITick(now) // the keep-up is not armed yet
	now = now.Add(MonsterAITick)
	if st := stateOf(t, a, id); st != ai.StateBattle {
		t.Fatalf("state %v one tick into the gap before the keep-up is armed, want BATTLE", st)
	}
	armForTest(t, attacker, id)
	for i := 0; i < 50; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	if st := stateOf(t, a, id); st != ai.StateBattle {
		t.Fatalf("state %v with the keep-up armed, want BATTLE", st)
	}
}

// NEGATIVE R2 (round 539), the cast gap. A cast cancels the keep-up before
// its blow and re-arms it only at the hand-off, after performAttack. A tick
// between the Cancel and the blow must not release the monster, and the
// drained blow restarts the count: one more tick without the keep-up after it
// is still not a release. Without the restart the count would reach 2 there.
func TestMonsterAIHoldOutlastsACastsCancelAndReArm(t *testing.T) {
	hub := world.NewHub()
	const attacker int64 = 91004
	hub.Enter(gateway.NewTestSession(91004), attacker, "Aria", "jangan", world.Position{})
	a, _, id, now := holdForTest(t, hub, 12)
	armForTest(t, attacker, id)
	noteStruck(a.monsters, id, attacker)
	for i := 0; i < 5; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	if st := stateOf(t, a, id); st != ai.StateBattle {
		t.Fatalf("state %v, want BATTLE before the cast", st)
	}

	keepUp.Cancel(attacker) // the cast's Cancel
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	if st := stateOf(t, a, id); st != ai.StateBattle {
		t.Fatalf("state %v on the tick between the cast's Cancel and its blow, want BATTLE", st)
	}
	noteStruck(a.monsters, id, attacker) // the cast's blow
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	monsterAITick(now) // the hand-off has not re-armed yet
	now = now.Add(MonsterAITick)
	if st := stateOf(t, a, id); st != ai.StateBattle {
		t.Fatalf("state %v one tick after the cast's blow, before the hand-off, want BATTLE (the blow restarts the count)", st)
	}
	armForTest(t, attacker, id) // the hand-off
	for i := 0; i < 50; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	if st := stateOf(t, a, id); st != ai.StateBattle {
		t.Fatalf("state %v after the hand-off re-armed the keep-up, want BATTLE", st)
	}
}

// NEGATIVE R3 (round 539), two players on one monster. A struck first, and B
// keeps up on it too. When A's keep-up ends the monster stays held while B's
// runs -- round 537 released it at once. CONTROL: a keep-up on it from a
// player in another zone does not hold it, and once B's ends it goes on the
// second tick, not the first.
func TestMonsterAIHoldStaysWhileAnyKeepUpInTheZoneIsOnIt(t *testing.T) {
	hub := world.NewHub()
	const aChar, bChar, cChar int64 = 91005, 91006, 91007
	hub.Enter(gateway.NewTestSession(91005), aChar, "Aria", "jangan", world.Position{})
	hub.Enter(gateway.NewTestSession(91006), bChar, "Bora", "jangan", world.Position{})
	hub.Enter(gateway.NewTestSession(91007), cChar, "Cato", "donwhang", world.Position{})
	a, _, id, now := holdForTest(t, hub, 13)
	armForTest(t, aChar, id)
	armForTest(t, bChar, id)
	noteStruck(a.monsters, id, aChar)
	noteStruck(a.monsters, id, bChar)
	for i := 0; i < 5; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	a.mu.Lock()
	target := a.brains[id].target
	a.mu.Unlock()
	if st := stateOf(t, a, id); st != ai.StateBattle || target != aChar {
		t.Fatalf("state %v targeting %d, want BATTLE on the first attacker %d", st, target, aChar)
	}

	keepUp.Cancel(aChar)
	for i := 0; i < 50; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
		if st := stateOf(t, a, id); st != ai.StateBattle {
			t.Fatalf("state %v %d tick(s) after the first attacker's keep-up ended, with the second one's still on it; want BATTLE", st, i+1)
		}
	}

	armForTest(t, cChar, id) // another zone's keep-up
	keepUp.Cancel(bChar)
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	if st := stateOf(t, a, id); st != ai.StateBattle {
		t.Fatalf("state %v one tick after the last keep-up in the zone ended, want BATTLE until the second", st)
	}
	monsterAITick(now)
	if st := stateOf(t, a, id); st != ai.StateIdle {
		t.Fatalf("state %v two ticks after the last keep-up in the zone ended (another zone's still on it), want IDLE", st)
	}
}

// aiTestServer is a gateway over in-memory stores with the login, world and
// combat handlers, and Aria in the world. It returns her connection, the
// world hub and her zone and position.
type aiTestServer struct {
	conn  net.Conn
	r     *bufio.Reader
	hub   *world.Hub
	zone  string
	x, z  float64
	charA int64
}

func startAITestServer(t *testing.T, monsters *combat.Hub) *aiTestServer {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}
	items := stubCombatItems{}
	inv := inventory.NewMemStore(items)
	eq := equipment.NewMemStore(inv)
	hub := world.NewHub()
	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		CombatHandler(chars, eq, items, hub, monsters, quest.NewMemStore(), inv, skill.NewMemStore(), nil, nil, nil),
	)
	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)
	conn := dialTestServer(t, addr)
	t.Cleanup(func() { conn.Close() })
	s := &aiTestServer{conn: conn, r: bufio.NewReader(conn), hub: hub, charA: c.ID}
	s.write(t, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(s.read(t).Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}
	s.write(t, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	ewr, err := DecodeEnterWorldResult(s.read(t).Data)
	if err != nil || !ewr.OK {
		t.Fatalf("enter world failed: err=%v result=%+v", err, ewr)
	}
	s.zone, s.x, s.z = ewr.Zone, float64(ewr.X), float64(ewr.Z)
	return s
}

func (s *aiTestServer) write(t *testing.T, opcode uint16, data []byte) {
	t.Helper()
	if err := proto.Write(s.conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
		t.Fatalf("Write: %v", err)
	}
}

func (s *aiTestServer) read(t *testing.T) *proto.Packet {
	t.Helper()
	s.conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	p, err := proto.Read(s.r, nil, nil)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	return p
}

// session is Aria's server-side session.
func (s *aiTestServer) session(t *testing.T) *gateway.Session {
	t.Helper()
	e, ok := s.hub.EntityByCharacterID(s.charA)
	if !ok {
		t.Fatal("Aria is not in the world")
	}
	return e.Session
}

// CONTROL C1, the kill switch: with no runtime installed, noteStruck does
// nothing and OpMonsterList gets exactly one reply, byte-identical to the
// list result before round 537.
func TestMonsterListWithoutTheAIIsTheOldReply(t *testing.T) {
	if monsterAIRuntime.Load() != nil {
		t.Fatal("precondition: the monster AI is off")
	}
	monsters := combat.NewHub()
	s := startAITestServer(t, monsters)
	m := monsters.SpawnSpecies(s.zone, testMangyang, s.x+40, 0, s.z, 1000, 0, 0, 0)
	monsters.SpawnSpecies("elsewhere", testMangyang, 0, 0, 0, 1000, 0, 0, 0)
	monsters.SetMotion(m.ID, s.x+90, s.z, 8, 0)
	noteStruck(monsters, m.ID, s.charA)
	cur, _ := monsters.Get(m.ID)
	if !cur.Moving {
		t.Fatal("noteStruck stopped a monster with the monster AI off")
	}
	want := (&MonsterListResult{Monsters: []MonsterSnapshot{{
		ID: cur.ID, Name: cur.Name, CodeName: cur.CodeName,
		X: float32(cur.X), Y: float32(cur.Y), Z: float32(cur.Z),
		MaxHP: int32(cur.MaxHP), HP: int32(cur.HP), Level: int32(cur.Level), Rarity: int32(cur.Rarity),
	}}}).Encode()

	s.write(t, OpMonsterList, nil)
	p := s.read(t)
	if p.Opcode != OpMonsterListResult || !bytes.Equal(p.Data, want) {
		t.Fatalf("reply %#04x %x, want %#04x %x", p.Opcode, p.Data, OpMonsterListResult, want)
	}
	// Nothing followed it: the next packet is the next request's reply.
	s.write(t, OpMonsterList, nil)
	if p := s.read(t); p.Opcode != OpMonsterListResult {
		t.Fatalf("after the list result came %#04x, want the next list result", p.Opcode)
	}
}

// With the AI on, one OpMonsterList is answered by the unchanged list result
// and then ONE OpMonsterMotionList carrying the listed monsters' legs --
// nothing more.
func TestMonsterListCarriesTheLegsWithTheAIOn(t *testing.T) {
	monsters := combat.NewHub()
	s := startAITestServer(t, monsters)
	walking := monsters.SpawnSpecies(s.zone, testMangyang, s.x+40, 0, s.z, 1000, 0, 0, 0)
	monsters.SpawnSpecies(s.zone, testMangyang, s.x-40, 0, s.z, 1000, 0, 0, 0)
	monsters.SetMotion(walking.ID, s.x+90, s.z+10, 8, 0)
	installMonsterAIForTest(t, s.hub, monsters, 7, (&pushRecorder{}).push)

	for round := 0; round < 2; round++ {
		s.write(t, OpMonsterList, nil)
		p := s.read(t)
		if p.Opcode != OpMonsterListResult {
			t.Fatalf("round %d: first reply %#04x, want the list result", round, p.Opcode)
		}
		if lr, err := DecodeMonsterListResult(p.Data); err != nil || len(lr.Monsters) != 2 {
			t.Fatalf("round %d: list %+v (err %v), want both monsters", round, lr, err)
		}
		p = s.read(t)
		if p.Opcode != OpMonsterMotionList {
			t.Fatalf("round %d: second reply %#04x, want the motion list", round, p.Opcode)
		}
		ml, err := DecodeMonsterMotionList(p.Data)
		if err != nil {
			t.Fatal(err)
		}
		want := MonsterMotion{ID: walking.ID, DestX: float32(s.x + 90), DestZ: float32(s.z + 10), Speed: 8, Mode: 0}
		if len(ml.Entries) != 1 || ml.Entries[0] != want {
			t.Fatalf("round %d: motion list %+v, want only %+v", round, ml.Entries, want)
		}
	}
}

// The wiring: a player's blow on a walking monster stops it in the hub
// before the reply goes out and records the struck event; the next tick
// pushes the one stop and holds it in BATTLE.
func TestAttackStopsAWalkingMonsterAtTheBlow(t *testing.T) {
	monsters := combat.NewHub()
	s := startAITestServer(t, monsters)
	m := monsters.SpawnSpecies(s.zone, testMangyang, s.x, 0, s.z, 100000, 0, 0, 0)
	monsters.SetMotion(m.ID, s.x+100, s.z, 8, 0)
	rec := &pushRecorder{}
	a := installMonsterAIForTest(t, s.hub, monsters, 8, rec.push)

	s.write(t, OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: m.ID}).Encode())
	ar, err := DecodeAttackResult(s.read(t).Data)
	if err != nil || ar.Error != "" || ar.MonsterDied || ar.MonsterDamage <= 0 {
		t.Fatalf("attack: %+v (err %v), want a hit it survives", ar, err)
	}
	if cur, _ := monsters.Get(m.ID); cur.Moving {
		t.Fatal("the struck monster is still walking after the reply")
	}
	a.mu.Lock()
	ev, ok := a.struck[m.ID]
	a.mu.Unlock()
	if !ok || ev.attacker != s.charA || !ev.wasMoving {
		t.Fatalf("struck event %+v (recorded %v), want attacker %d, stopped mid-leg", ev, ok, s.charA)
	}
	monsterAITick(aiT0)
	if moves := rec.of(m.ID); len(moves) != 1 || !isStop(moves[0]) {
		t.Fatalf("the tick pushed %+v, want exactly one stop", moves)
	}
	if st := stateOf(t, a, m.ID); st != ai.StateBattle {
		t.Fatalf("state %v, want BATTLE", st)
	}
}

// The motion list must never be overtaken by an older view of a leg. A tick
// that changes a monster's leg while a list reply to the same session is in
// flight -- built, not yet written -- must wait for the reply, or the client
// gets the newer push first and then the list's older destination.
func TestMonsterPushWaitsForAListReplyInFlight(t *testing.T) {
	monsters := combat.NewHub()
	s := startAITestServer(t, monsters)
	m := monsters.SpawnSpecies(s.zone, testMangyang, s.x+40, 0, s.z, 1000, 0, 0, 0)
	monsters.SetMotion(m.ID, s.x+90, s.z, 8, 0)
	a := installMonsterAIForTest(t, s.hub, monsters, 9, nil) // the real zone broadcast
	monsterAITick(aiT0)
	noteStruck(monsters, m.ID, s.charA) // the next tick owes the zone a stop

	sess := s.session(t)
	wire := a.wireLock(sess)
	wire.Lock() // a list reply is between reading the hub and writing
	done := make(chan struct{})
	go func() {
		monsterAITick(aiT0.Add(MonsterAITick))
		close(done)
	}()
	select {
	case <-done:
		wire.Unlock()
		t.Fatal("the tick wrote to a session while its list reply was in flight")
	case <-time.After(300 * time.Millisecond):
	}
	marker := (&MonsterListResult{}).Encode()
	if err := sess.Send(&proto.Packet{Opcode: OpMonsterListResult, Data: marker}); err != nil {
		t.Fatal(err)
	}
	wire.Unlock()
	<-done

	if p := s.read(t); p.Opcode != OpMonsterListResult {
		t.Fatalf("first on the wire %#04x, want the list reply that was in flight", p.Opcode)
	}
	p := s.read(t)
	mv, err := DecodeMonsterMoved(p.Data)
	if p.Opcode != OpMonsterMoved || err != nil || mv.MonsterID != m.ID || !isStop(*mv) {
		t.Fatalf("second on the wire %#04x %+v (err %v), want the stop push", p.Opcode, mv, err)
	}
}

// And the other side: a list request that arrives while a push to the same
// session is being written waits for it, so its reply -- built after --
// lands after.
func TestMonsterListWaitsForAPushInFlight(t *testing.T) {
	monsters := combat.NewHub()
	s := startAITestServer(t, monsters)
	m := monsters.SpawnSpecies(s.zone, testMangyang, s.x+40, 0, s.z, 1000, 0, 0, 0)
	a := installMonsterAIForTest(t, s.hub, monsters, 10, (&pushRecorder{}).push)

	sess := s.session(t)
	wire := a.wireLock(sess)
	wire.Lock() // the tick is writing a push to this session
	s.write(t, OpMonsterList, nil)
	<-time.After(300 * time.Millisecond) // the handler, if it honours the lock, is waiting now
	push := &MonsterMoved{MonsterID: m.ID, X: float32(s.x + 40), Z: float32(s.z), DestX: float32(s.x + 90), DestZ: float32(s.z), Speed: 8}
	if err := sess.Send(&proto.Packet{Opcode: OpMonsterMoved, Data: push.Encode()}); err != nil {
		t.Fatal(err)
	}
	wire.Unlock()

	for i, want := range []uint16{OpMonsterMoved, OpMonsterListResult, OpMonsterMotionList} {
		if p := s.read(t); p.Opcode != want {
			t.Fatalf("packet %d on the wire is %#04x, want %#04x", i, p.Opcode, want)
		}
	}
}

// ---- The spawn push (round 542) ----

// spawnFixture is the client's own OpMonsterSpawned fixture
// (client/scripts/net/combat_test.gd, SPAWN_FIXTURE; docs/protocol/
// monster_ai.md, "srrevamp's own monster protocol"): monster 31 "Mob" /
// MOB_TEST (a fixture species) at (100, 0, -200), 100/100 HP, level 1,
// rarity 0, heading pi/2 (f32 0x3fc90fdb, facing +z). The server's encoder
// must produce it byte for byte.
var spawnFixture = []byte{0x1f, 0, 0, 0, 0, 0, 0, 0, 0x03, 0x00, 0x4d, 0x6f, 0x62,
	0x08, 0x00, 0x4d, 0x4f, 0x42, 0x5f, 0x54, 0x45, 0x53, 0x54,
	0x00, 0x00, 0xc8, 0x42, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x48, 0xc3,
	0x64, 0, 0, 0, 0x64, 0, 0, 0, 0x01, 0, 0, 0, 0x00, 0, 0, 0,
	0xdb, 0x0f, 0xc9, 0x3f}

func TestMonsterSpawnedMatchesTheClientFixture(t *testing.T) {
	m := &MonsterSpawned{Monster: MonsterSnapshot{ID: 31, Name: "Mob", CodeName: "MOB_TEST", X: 100, Y: 0, Z: -200,
		MaxHP: 100, HP: 100, Level: 1, Rarity: 0}, Heading: float32(math.Pi / 2)}
	got := m.Encode()
	if !bytes.Equal(got, spawnFixture) {
		t.Fatalf("MonsterSpawned.Encode:\n got % x\nwant % x", got, spawnFixture)
	}
	// The record is the list's own: an OpMonsterListResult of that one
	// monster is a u16 empty error, a u16 count and then these same bytes.
	list := (&MonsterListResult{Monsters: []MonsterSnapshot{m.Monster}}).Encode()
	if !bytes.Equal(got[:len(got)-4], list[4:]) {
		t.Errorf("the record is not the list's:\n push % x\n list % x", got[:len(got)-4], list[4:])
	}
	back, err := DecodeMonsterSpawned(got)
	if err != nil || *back != *m {
		t.Fatalf("round trip: %+v, %v", back, err)
	}
	// As the client decodes it: a heading or a record cut short is refused.
	for _, n := range []int{54, 40} {
		if _, err := DecodeMonsterSpawned(spawnFixture[:n]); err == nil {
			t.Errorf("a %d-byte MonsterSpawned must be refused", n)
		}
	}
}

// 0x007E is the opcode the client listens on (CombatNet.OP_MONSTER_SPAWNED)
// and collides with no other session opcode in the 0x0060..0x007F block.
func TestMonsterSpawnedOpcode(t *testing.T) {
	if OpMonsterSpawned != 0x007E {
		t.Fatalf("OpMonsterSpawned = 0x%04X; the client decodes 0x007E", OpMonsterSpawned)
	}
	for _, op := range []uint16{OpAttack, OpAttackResult, OpMonsterDamaged, OpMonsterDied, OpLootDropped,
		OpMonsterList, OpMonsterListResult, OpLevelUp, OpBerserk, OpBerserkResult,
		OpLearnSkill, OpLearnSkillResult, OpUseSkill, OpSkillList, OpSkillListResult,
		OpSkillState, OpSkillStateResult, OpRaiseMastery, OpRaiseMasteryResult,
		OpGroundItemList, OpGroundItemListResult, OpGroundItemSpawned, OpGroundItemRemoved,
		OpGroundItemOwnerReleased, OpPickUp, OpPickUpResult, OpRepair, OpRepairResult,
		OpMonsterMoved, OpMonsterAttacked, OpMonsterMotionList} {
		if op == OpMonsterSpawned {
			t.Errorf("OpMonsterSpawned collides with 0x%04X", op)
		}
	}
}

// spawnPushForTest turns -monster-spawn-push on or off for the rest of the
// test and puts it back when the test ends.
func spawnPushForTest(t *testing.T, on bool) {
	t.Helper()
	was := monsterSpawnPush.Load()
	SetMonsterSpawnPush(on)
	t.Cleanup(func() { SetMonsterSpawnPush(was) })
}

// listing asks for the monster list and returns every packet that arrived
// before its reply, and the reply.
func (c *strikeClient) listing(t *testing.T) ([]*proto.Packet, *MonsterListResult) {
	t.Helper()
	c.write(t, OpMonsterList, nil)
	var before []*proto.Packet
	for {
		p := c.read(t)
		if p.Opcode != OpMonsterListResult {
			before = append(before, p)
			continue
		}
		list, err := DecodeMonsterListResult(p.Data)
		if err != nil {
			t.Fatalf("%s: DecodeMonsterListResult: %v", c.name, err)
		}
		return before, list
	}
}

// spawnPushes returns the OpMonsterSpawned pushes among pkts, decoded.
func spawnPushes(t *testing.T, pkts []*proto.Packet) []*MonsterSpawned {
	t.Helper()
	var out []*MonsterSpawned
	for _, p := range pkts {
		if p.Opcode != OpMonsterSpawned {
			continue
		}
		m, err := DecodeMonsterSpawned(p.Data)
		if err != nil {
			t.Fatalf("DecodeMonsterSpawned: %v", err)
		}
		out = append(out, m)
	}
	return out
}

// recordingHeadingRoll installs Nest_Hatch's roll (ai.SpawnHeading) over a
// seeded rng on monsters and returns the headings it has drawn so far.
func recordingHeadingRoll(monsters *combat.Hub, seed int64) func() []float64 {
	var mu sync.Mutex
	var drawn []float64
	rng := rand.New(rand.NewSource(seed))
	monsters.SetSpawnHeadingRoll(func() float64 {
		h := ai.SpawnHeading(rng)
		mu.Lock()
		drawn = append(drawn, h)
		mu.Unlock()
		return h
	})
	return func() []float64 {
		mu.Lock()
		defer mu.Unlock()
		return append([]float64(nil), drawn...)
	}
}

// THE RED (round 542): a respawn in jangan, handed to BroadcastMonsterSpawned
// the way cmd/server's maintainMonster hands it every spawn, reaches both
// jangan sessions at once, before either asks for the list: one
// OpMonsterSpawned each, carrying the new id, the list's own record for it,
// and the heading it hatched facing -- Nest_Hatch's roll, in [0, 2pi]
// (ai.SpawnHeading can return 2pi itself, at rand() = 32767). Before round
// 542 nothing sent 0x007E, so Bram's count was 0 and this fails.
//
// CONTROLS (they pass before the change too, since nothing was sent then):
// Cyra, in donwhang, receives none, and a monster already gone when its push
// is due sends nothing to anyone.
func TestMonsterRespawnReachesTheZone(t *testing.T) {
	spawnPushForTest(t, true)
	z := startStrikeZone(t)
	drawn := recordingHeadingRoll(z.monsters, 542)
	m := z.monsters.SpawnSpecies("jangan", strikeMangyang, z.aria.x+30, 0, z.aria.z, 54, 7, 0, 0)
	BroadcastMonsterSpawned(z.hub, z.monsters, m.ID)

	if d := drawn(); len(d) != 1 || m.Heading != d[0] {
		t.Fatalf("the spawn drew %v and hatched facing %g, want exactly one draw, its heading", d, m.Heading)
	}
	for _, c := range []*strikeClient{z.bram, z.aria} {
		before, list := c.listing(t)
		pushes := spawnPushes(t, before)
		if len(pushes) != 1 {
			t.Fatalf("%s, in jangan, received %d OpMonsterSpawned before the list (packets %#04x), want exactly 1",
				c.name, len(pushes), opcodesOf(before))
		}
		got := pushes[0]
		if got.Monster.ID != m.ID {
			t.Errorf("%s's push is for monster %d, want the new %d", c.name, got.Monster.ID, m.ID)
		}
		var listed *MonsterSnapshot
		for i := range list.Monsters {
			if list.Monsters[i].ID == m.ID {
				listed = &list.Monsters[i]
			}
		}
		if listed == nil || got.Monster != *listed {
			t.Errorf("%s's push record %+v, want the list's own record %+v", c.name, got.Monster, listed)
		}
		if got.Heading != float32(m.Heading) {
			t.Errorf("%s's push faces %g, want the hatch heading %g", c.name, got.Heading, m.Heading)
		}
		if got.Heading < 0 || got.Heading > float32(2*math.Pi) {
			t.Errorf("%s's push faces %g, outside Nest_Hatch's [0, 2pi]", c.name, got.Heading)
		}
	}

	// CONTROL: another zone hears nothing.
	if n := len(spawnPushes(t, z.cyra.barrier(t))); n != 0 {
		t.Errorf("Cyra, in donwhang, received %d OpMonsterSpawned, want 0", n)
	}

	// CONTROL: a monster killed before its push is due sends nothing.
	gone := z.monsters.SpawnSpecies("jangan", strikeMangyang, z.aria.x+60, 0, z.aria.z, 54, 7, 0, 0)
	if _, died, ok := z.monsters.ApplyDamage(gone.ID, 54); !ok || !died {
		t.Fatal("precondition: the second monster dies")
	}
	BroadcastMonsterSpawned(z.hub, z.monsters, gone.ID)
	for _, c := range []*strikeClient{z.aria, z.bram, z.cyra} {
		if n := len(spawnPushes(t, c.barrier(t))); n != 0 {
			t.Errorf("%s received %d OpMonsterSpawned for a monster already gone, want 0", c.name, n)
		}
	}
}

// CONTROL, the default: with -monster-spawn-push off a spawn sends nothing,
// and each session's next packet is its own list reply, as before round 542.
func TestMonsterSpawnPushOffIsTheOldWire(t *testing.T) {
	spawnPushForTest(t, false)
	z := startStrikeZone(t)
	m := z.monsters.SpawnSpecies("jangan", strikeMangyang, z.aria.x+30, 0, z.aria.z, 54, 7, 0, 0)
	BroadcastMonsterSpawned(z.hub, z.monsters, m.ID)
	for _, c := range []*strikeClient{z.aria, z.bram, z.cyra} {
		if got := c.barrier(t); len(got) != 0 {
			t.Errorf("%s received %#04x with the spawn push off, want nothing", c.name, opcodesOf(got))
		}
	}
}

// The brain starts from the heading the monster hatched with
// (combat.Monster.Heading), the one OpMonsterSpawned carries, instead of
// rolling its own. Before round 542 newBrain drew ai.SpawnHeading(a.rng), so
// the pushed heading and the brain's would have been two different draws.
func TestMonsterAIBrainStartsFromTheSpawnHeading(t *testing.T) {
	monsters := combat.NewHub()
	monsters.SetSpawnHeadingRoll(func() float64 { return 1.25 })
	m := monsters.SpawnSpecies("jangan", testMangyang, 0, 0, 0, 1000, 0, 0, 0)
	a := installMonsterAIForTest(t, world.NewHub(), monsters, 5, (&pushRecorder{}).push)
	monsterAITick(aiT0)
	a.mu.Lock()
	b := a.brains[m.ID]
	a.mu.Unlock()
	if b == nil {
		t.Fatal("no brain after the first tick")
	}
	if st := stateOf(t, a, m.ID); st != ai.StateIdle {
		t.Fatalf("state %v after the first tick, want IDLE (no leg yet)", st)
	}
	a.mu.Lock()
	heading := b.heading
	a.mu.Unlock()
	if heading != 1.25 {
		t.Fatalf("the brain faces %g, want the hatch heading 1.25", heading)
	}
}

// ---- The monster's own BATTLE (round 546, behind -monster-battle) ----

// chaseMangyang is testMangyang with the two numbers the chase reads: its
// primary attack skill's ReuseDelay, 3000 ms, and Range, 10 (skilldata cols
// 14/21 by characterdata col 83, round 254; cmd/server's roster). Range 10 is
// the attack-distance rule's own hole (combat.ApproachBand): stop = reach =
// the bare BC sum, 6 + 4 = 10, so the monster is in reach at int(dist) <= 12.
var chaseMangyang = func() combat.Species {
	s := testMangyang
	s.AttackReuseMs, s.AttackRange = 3000, 10
	return s
}()

// battleForTest turns -monster-battle on or off for the rest of the test and
// puts it back when the test ends.
func battleForTest(t *testing.T, on bool) {
	t.Helper()
	was := monsterBattle.Load()
	SetMonsterBattle(on)
	t.Cleanup(func() { SetMonsterBattle(was) })
}

// battleFixture is Aria standing in jangan under a runtime that can swing at
// her: in-memory character and equipment stores behind the strike, a seeded
// rng and a recorder in place of the zone broadcast.
type battleFixture struct {
	a        *monsterAI
	hub      *world.Hub
	monsters *combat.Hub
	chars    character.Store
	aria     int64
	rec      *pushRecorder
}

func startBattleFixture(t *testing.T, seed int64, ariaX, ariaZ float64) *battleFixture {
	t.Helper()
	ctx := context.Background()
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}
	items := stubCombatItems{}
	inv := inventory.NewMemStore(items)
	eq := equipment.NewMemStore(inv)
	hub := world.NewHub()
	hub.Enter(gateway.NewTestSession(uint64(91100+seed)), c.ID, "Aria", "jangan", world.Position{X: ariaX, Z: ariaZ})
	monsters := newAIHub(seed)
	rec := &pushRecorder{}
	a := newMonsterAI(hub, monsters, nil, MonsterAIConfig{Chars: chars, Equipment: eq, Items: items},
		rand.New(rand.NewSource(seed)), rec.push)
	monsterAIRuntime.Store(a)
	t.Cleanup(func() { monsterAIRuntime.Store(nil) })
	return &battleFixture{a: a, hub: hub, monsters: monsters, chars: chars, aria: c.ID, rec: rec}
}

// waitFor polls cond every few milliseconds for up to d: the strike worker
// runs off the tick, so its push lands a moment after the tick that queued it.
func waitFor(t *testing.T, d time.Duration, cond func() bool) bool {
	t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if cond() {
			return true
		}
		time.Sleep(5 * time.Millisecond)
	}
	return cond()
}

func TestMonsterBattleOffByDefault(t *testing.T) {
	if monsterBattle.Load() {
		t.Fatal("the monster battle is on with nothing having asked for it: -monster-battle is off by default")
	}
}

// THE RED (round 546): a Mangyang in BATTLE against a player 60 units away.
// Its first push is the chase -- mode 1 at the run speed 22, from where it
// stands toward the point 10 units from the player on the line between them
// (MoveTowardObject to round(stop)) -- and after enough ticks it stands
// inside its band and an OpMonsterAttacked arrives: 15 damage on Aria, her HP
// 15 down. Then it swings again exactly its skill's ReuseDelay later, 3000 ms,
// to within a tick: four blows in the first 10 s in reach, and no leg or stop
// pushed while it stands there. Before this round nothing chased and nothing
// swung unstruck: the hold stood the monster where it was, and the only blow
// was performAttack's synchronous counter.
func TestMonsterChasesToItsBand(t *testing.T) {
	battleForTest(t, true)
	f := startBattleFixture(t, 21, 0, 0)
	m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 60, 0, 0, 1000, 0, 15, 0)
	now := aiT0
	monsterAITick(now) // the brain hatches into IDLE
	now = now.Add(MonsterAITick)
	noteStruck(f.monsters, m.ID, f.aria)
	if cur, _ := f.monsters.Get(m.ID); cur.X != 60 {
		t.Fatalf("setup: the monster stands at %g, want 60", cur.X)
	}
	f.rec.reset()

	monsterAITick(now) // drains the blow: BATTLE, and the first chase leg
	now = now.Add(MonsterAITick)
	if st := stateOf(t, f.a, m.ID); st != ai.StateBattle {
		t.Fatalf("state %v after the blow, want BATTLE", st)
	}
	moves := f.rec.of(m.ID)
	if len(moves) != 1 {
		t.Fatalf("the tick after the blow pushed %d move(s) %+v, want exactly the chase leg", len(moves), moves)
	}
	leg := moves[0]
	if leg.Mode != 1 || leg.Speed != 22 {
		t.Errorf("the chase leg is mode %d at %g, want mode 1 at the run speed 22 (Handler_110 gives BATTLE the run clip)", leg.Mode, leg.Speed)
	}
	if leg.X != 60 || leg.Z != 0 || math.Abs(float64(leg.DestX)-10) > 1e-3 || math.Abs(float64(leg.DestZ)) > 1e-3 {
		t.Errorf("the chase leg %+v: want from (60, 0) to (10, 0), the stop distance 10 from the player", leg)
	}
	if n := len(f.rec.strikesOf(m.ID)); n != 0 {
		t.Fatalf("%d blow(s) pushed from 60 units away, before the chase reached the band", n)
	}

	// 50 units at 22 u/s is 2.3 s; the band is entered at int(dist) <= 12.
	inReach := false
	for i := 0; i < 40 && !inReach; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
		cur, _ := f.monsters.Get(m.ID)
		inReach = int(math.Trunc(cur.X)) <= 12
		if !inReach {
			if n := len(f.rec.strikesOf(m.ID)); n != 0 {
				t.Fatalf("a blow was pushed with the monster %.1f from the player, out of the band", cur.X)
			}
		}
	}
	if !inReach {
		t.Fatal("the chase never brought the monster into its band in 4 s")
	}
	cur, _ := f.monsters.Get(m.ID)
	if cur.Moving {
		t.Errorf("in the band the monster is still walking: %+v", cur)
	}
	if !waitFor(t, 2*time.Second, func() bool { return len(f.rec.strikesOf(m.ID)) == 1 }) {
		t.Fatalf("no OpMonsterAttacked within 2 s of the monster reaching its band (%d pushed)", len(f.rec.strikesOf(m.ID)))
	}
	got := f.rec.strikesOf(m.ID)[0]
	want := MonsterAttacked{MonsterID: m.ID, TargetCharacterID: f.aria, Damage: 15, TargetHP: int32(character.StartingMaxHP) - 15}
	if got != want {
		t.Errorf("the blow %+v, want %+v", got, want)
	}
	if c, err := f.chars.GetByID(context.Background(), f.aria); err != nil || c.HP != character.StartingMaxHP-15 {
		t.Errorf("Aria's HP after the blow = %d (err %v), want %d", c.HP, err, character.StartingMaxHP-15)
	}

	// The cadence: the next blows at exactly ReuseDelay, 3000 ms, after the
	// last -- the 30th tick after each, never the 29th -- and nothing else
	// pushed. Each blow's push is waited for before the clock runs on: the
	// ticks take no wall time here, and the strike worker holds one swing
	// while it runs one (queueStrike), which a real 3 s gap never fills.
	movesBefore := len(f.rec.of(m.ID))
	for blow := 2; blow <= 4; blow++ {
		for i := 0; i < 29; i++ {
			monsterAITick(now)
			now = now.Add(MonsterAITick)
		}
		time.Sleep(20 * time.Millisecond)
		if n := len(f.rec.strikesOf(m.ID)); n != blow-1 {
			t.Fatalf("%d blows 2.9 s after blow %d, want none before the 3000 ms ReuseDelay", n, blow-1)
		}
		monsterAITick(now)
		now = now.Add(MonsterAITick)
		if !waitFor(t, 2*time.Second, func() bool { return len(f.rec.strikesOf(m.ID)) == blow }) {
			t.Fatalf("blow %d did not come on the 30th tick (3000 ms) after blow %d: %d pushed", blow, blow-1, len(f.rec.strikesOf(m.ID)))
		}
	}
	if n := len(f.rec.strikesOf(m.ID)); n != 4 {
		t.Errorf("%d blows in the first 9 s in the band, want exactly 4 (the first, then one per 3000 ms)", n)
	}
	if n := len(f.rec.of(m.ID)); n != movesBefore {
		t.Errorf("%d move(s) pushed while the monster stood in its band: %+v", n-movesBefore, f.rec.of(m.ID)[movesBefore:])
	}
	if c, _ := f.chars.GetByID(context.Background(), f.aria); c.HP != character.StartingMaxHP-4*15 {
		t.Errorf("Aria's HP after four blows = %d, want %d", c.HP, character.StartingMaxHP-4*15)
	}
	if st := stateOf(t, f.a, m.ID); st != ai.StateBattle {
		t.Errorf("state %v with the target still in the band, want BATTLE", st)
	}
}

// CONTROL, the default: with -monster-battle off the same blow puts the
// monster in the interim hold -- it stands where it is, no chase leg, no
// blow of its own in 5 s -- exactly as before this round.
func TestMonsterBattleOffKeepsTheHold(t *testing.T) {
	battleForTest(t, false)
	f := startBattleFixture(t, 22, 0, 0)
	m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 60, 0, 0, 1000, 0, 15, 0)
	now := aiT0
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	noteStruck(f.monsters, m.ID, f.aria)
	f.rec.reset()
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	if st := stateOf(t, f.a, m.ID); st != ai.StateBattle {
		t.Fatalf("state %v after the blow, want BATTLE", st)
	}
	if moves := f.rec.of(m.ID); len(moves) != 0 {
		t.Fatalf("with the battle off the tick after the blow pushed %+v, want nothing (a standing monster held where it is)", moves)
	}
	// The hold: the monster stands through the next tick too, then -- with no
	// keep-up on it -- the release lets IDLE have it (MonsterHoldReleaseTicks),
	// and IDLE may wander; what it never does is chase or swing.
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	if st := stateOf(t, f.a, m.ID); st != ai.StateBattle {
		t.Fatalf("state %v one tick into the hold, want BATTLE", st)
	}
	if cur, _ := f.monsters.Get(m.ID); cur.X != 60 || cur.Moving {
		t.Fatalf("with the battle off the held monster is at %g (moving %v); the hold keeps it standing at 60", cur.X, cur.Moving)
	}
	for i := 0; i < 50; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	time.Sleep(50 * time.Millisecond)
	if n := len(f.rec.strikesOf(m.ID)); n != 0 {
		t.Fatalf("with the battle off the monster pushed %d blow(s) of its own", n)
	}
	for _, mv := range f.rec.of(m.ID) {
		if mv.Mode == 1 && math.Hypot(float64(mv.DestX), float64(mv.DestZ)) <= 12 {
			t.Errorf("with the battle off a run to the player's band was pushed: %+v", mv)
		}
	}
}

// The engine's exits. A target 500 units away is past the give-up distance
// (ai.TacticsGiveUpDistance, 400): the first BATTLE tick takes the 0x27 exit
// to IDLE, and a monster at home pushes nothing. A monster carried 700 units
// from home, struck by a player 60 away, is out of reach too -- the nest
// path's threshold is 400 less the 400 excess beyond 1.5 x 200, zero
// (ai.ChaseRange) -- and IDLE's roam check sends it home at once: HOMING, one
// mode-1 leg at 22 toward a point in MoveHome's band from home.
func TestMonsterBattleReleasesOutOfReachAndWalksHome(t *testing.T) {
	battleForTest(t, true)
	f := startBattleFixture(t, 23, 500, 0)
	m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 0, 0, 0, 1000, 0, 15, 0)
	now := aiT0
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	noteStruck(f.monsters, m.ID, f.aria)
	f.rec.reset()
	monsterAITick(now)
	if st := stateOf(t, f.a, m.ID); st != ai.StateIdle {
		t.Fatalf("state %v with the target 500 away (give-up distance 400), want IDLE by the 0x27 exit", st)
	}
	if n := len(f.rec.of(m.ID)) + len(f.rec.strikesOf(m.ID)); n != 0 {
		t.Fatalf("%d push(es) for a target out of reach from the start: %+v", n, f.rec.of(m.ID))
	}

	g := startBattleFixture(t, 24, 760, 0)
	far := g.monsters.SpawnSpecies("jangan", chaseMangyang, 0, 0, 0, 1000, 0, 15, 0)
	// Carry it 700 units east: five mover steps under the 160 cap.
	g.monsters.SetMotion(far.ID, 700, 0, 700, 1)
	for i := 0; i < 5; i++ {
		g.monsters.StepAll(1)
	}
	if got, _ := g.monsters.Get(far.ID); got.X != 700 || got.Moving {
		t.Fatalf("setup: the monster is at %g (moving %v), want standing at 700", got.X, got.Moving)
	}
	now = aiT0
	monsterAITick(now) // hatches; IDLE's roam check already sends it home
	now = now.Add(MonsterAITick)
	noteStruck(g.monsters, far.ID, g.aria)
	g.rec.reset()
	monsterAITick(now)
	if st := stateOf(t, g.a, far.ID); st != ai.StateHoming {
		t.Fatalf("state %v after a blow 700 units from home, want HOMING (0x27 -> IDLE -> the roam check)", st)
	}
	moves := g.rec.of(far.ID)
	lo, hi := ai.HomingScatterRange(MonsterRoamRadius)
	if len(moves) != 1 || moves[0].Mode != 1 || moves[0].Speed != 22 ||
		float64(moves[0].DestX) < lo-1e-3 || float64(moves[0].DestX) > hi+1e-3 || math.Abs(float64(moves[0].DestZ)) > 1e-3 {
		t.Fatalf("after the release the tick pushed %+v, want one run home (mode 1 at 22) to x in [%.2f, %.2f]", moves, lo, hi)
	}
	if n := len(g.rec.strikesOf(far.ID)); n != 0 {
		t.Errorf("%d blow(s) from a monster that gave up", n)
	}
}

// A killing blow: the push carries the death, the HP the target was put back
// on its feet with, and the next tick takes the 0x23 exit -- the target's
// life state left 1 at the kill (AITactics_IsValidTarget 0x540de0) -- so the
// monster is in IDLE and swings no more.
func TestMonsterBattleKillSendsItToIdle(t *testing.T) {
	battleForTest(t, true)
	f := startBattleFixture(t, 25, 0, 0)
	m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 8, 0, 0, 100000, 0, 100000, 0)
	now := aiT0
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	noteStruck(f.monsters, m.ID, f.aria)
	f.rec.reset()
	monsterAITick(now) // BATTLE, in reach from the start: the swing is immediate
	now = now.Add(MonsterAITick)
	if !waitFor(t, 2*time.Second, func() bool { return len(f.rec.strikesOf(m.ID)) == 1 }) {
		t.Fatalf("no blow within 2 s of a monster entering BATTLE in reach (%d pushed)", len(f.rec.strikesOf(m.ID)))
	}
	got := f.rec.strikesOf(m.ID)[0]
	after, err := f.chars.GetByID(context.Background(), f.aria)
	if err != nil {
		t.Fatal(err)
	}
	if !got.TargetDied || got.TargetHP <= 0 || int(got.TargetHP) != after.HP || got.DeathExpLost != 0 {
		t.Errorf("the killing blow %+v; want the death, the respawn HP %d (character.RespawnFraction) and no exp lost without a level table", got, after.HP)
	}
	monsterAITick(now) // the kill is the 0x23 exit's evidence
	now = now.Add(MonsterAITick)
	if st := stateOf(t, f.a, m.ID); st != ai.StateIdle {
		t.Fatalf("state %v on the tick after the kill, want IDLE", st)
	}
	for i := 0; i < 40; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	time.Sleep(50 * time.Millisecond)
	if n := len(f.rec.strikesOf(m.ID)); n != 1 {
		t.Errorf("%d blows after the kill, want the one that killed", n-1)
	}
}

// ---- Batch-16 review follow-ups (round 547) ----

// lockedBuffer is a bytes.Buffer the strike worker and the test may both
// touch: the worker logs off the tick.
type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// panicOnceChars is a character store whose first GetByID panics -- a store's
// own fault, as a strike worker would meet it -- and behaves after that.
type panicOnceChars struct {
	character.Store
	panicked atomic.Bool
}

func (s *panicOnceChars) GetByID(ctx context.Context, id int64) (*character.Character, error) {
	if s.panicked.CompareAndSwap(false, true) {
		panic("test: the character store fell over")
	}
	return s.Store.GetByID(ctx, id)
}

// A panic inside a strike worker's blow is logged and the swing dropped, and
// the worker serves the next one (round 547, runStrike's recover). Before this
// round the panic propagated off the worker goroutine and took the whole
// process down: run without the recover, this test dies with the panic
// instead of failing.
func TestStrikeWorkerSurvivesAPanic(t *testing.T) {
	battleForTest(t, true)
	f := startBattleFixture(t, 31, 0, 0)
	chars := &panicOnceChars{Store: f.chars}
	var log lockedBuffer
	f.a.deps.chars = chars
	f.a.logger = slog.New(slog.NewTextHandler(&log, nil))
	m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 8, 0, 0, 1000, 0, 15, 0)
	now := aiT0
	monsterAITick(now) // IDLE
	now = now.Add(MonsterAITick)
	noteStruck(f.monsters, m.ID, f.aria)
	f.rec.reset()
	monsterAITick(now) // BATTLE, in reach: the first swing, which meets the panic
	now = now.Add(MonsterAITick)
	if !waitFor(t, 2*time.Second, func() bool {
		return chars.panicked.Load() && strings.Contains(log.String(), "strike panicked")
	}) {
		t.Fatalf("no 'strike panicked' log line within 2 s of the swing that panicked (store panicked: %v); log:\n%s", chars.panicked.Load(), log.String())
	}
	if n := len(f.rec.strikesOf(m.ID)); n != 0 {
		t.Fatalf("%d blow(s) pushed from a swing that panicked, want none: the swing is dropped", n)
	}
	if c, _ := f.chars.GetByID(context.Background(), f.aria); c.HP != character.StartingMaxHP {
		t.Fatalf("Aria's HP %d after the dropped swing, want %d untouched", c.HP, character.StartingMaxHP)
	}
	// The worker is still there: the next swing, one ReuseDelay on, lands.
	for i := 0; i < 30; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	if !waitFor(t, 2*time.Second, func() bool { return len(f.rec.strikesOf(m.ID)) == 1 }) {
		t.Fatalf("the swing after the panic never landed (%d pushed): the worker died with the panic", len(f.rec.strikesOf(m.ID)))
	}
	if got := f.rec.strikesOf(m.ID)[0]; got.Damage != 15 || got.TargetHP != int32(character.StartingMaxHP)-15 {
		t.Errorf("the blow after the panic %+v, want 15 on Aria from full", got)
	}
}

// A runtime holding the character store but not the equipment and item
// stores makes no swing at all (MonsterAIConfig; queueStrike's guard): the
// blow reads all three and defenderDefence's eq.Get has no nil guard. The
// chase still runs, nothing is pushed and nothing is logged. Before this
// round the swing was made and the worker panicked on the nil equipment
// store, which took the process down: run without the guard and the recover,
// this test dies with the panic; with the recover alone it fails on the log.
func TestStrikeNeedsEveryStore(t *testing.T) {
	battleForTest(t, true)
	f := startBattleFixture(t, 32, 0, 0)
	var log lockedBuffer
	f.a.deps.eq, f.a.deps.items = nil, nil
	f.a.logger = slog.New(slog.NewTextHandler(&log, nil))
	m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 8, 0, 0, 1000, 0, 15, 0)
	now := aiT0
	monsterAITick(now) // IDLE
	now = now.Add(MonsterAITick)
	noteStruck(f.monsters, m.ID, f.aria)
	f.rec.reset()
	for i := 0; i < 35; i++ { // the entry tick and a whole ReuseDelay after it
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	time.Sleep(50 * time.Millisecond)
	if st := stateOf(t, f.a, m.ID); st != ai.StateBattle {
		t.Errorf("state %v, want BATTLE: the chase runs without the stores", st)
	}
	if n := len(f.rec.strikesOf(m.ID)); n != 0 {
		t.Errorf("%d blow(s) pushed by a runtime with no equipment store, want none", n)
	}
	if s := log.String(); s != "" {
		t.Errorf("a runtime with no equipment store logged, want no swing attempted at all:\n%s", s)
	}
	if c, _ := f.chars.GetByID(context.Background(), f.aria); c.HP != character.StartingMaxHP {
		t.Errorf("Aria's HP %d, want %d untouched", c.HP, character.StartingMaxHP)
	}
}

// A strike worker that finishes after the tick dropped its brain -- the
// monster killed by the player inside the worker's window -- leaves nothing in
// kills (round 547): ids are never reused (combat.Hub's nextID), so an entry
// written after the removal loop's delete would never be collected. The blow
// itself was resolved, so it is still pushed.
func TestLateKillAfterTheBrainIsGoneLeavesNoRecord(t *testing.T) {
	battleForTest(t, true)
	f := startBattleFixture(t, 33, 0, 0)
	m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 8, 0, 0, 1000, 0, 100000, 0)
	now := aiT0
	monsterAITick(now) // the brain
	now = now.Add(MonsterAITick)
	asSeen, _ := f.monsters.Get(m.ID)
	if _, died, ok := f.monsters.ApplyDamage(m.ID, 1000); !died || !ok {
		t.Fatal("setup: the monster did not die")
	}
	monsterAITick(now) // the brain is dropped
	now = now.Add(MonsterAITick)
	f.a.mu.Lock()
	_, hasBrain := f.a.brains[m.ID]
	f.a.mu.Unlock()
	if hasBrain {
		t.Fatal("setup: the dead monster still has a brain")
	}
	// The worker's late finish: the killing blow, resolved after the drop.
	f.a.runStrike(m.ID, strikeJob{m: asSeen, target: f.aria})
	if strikes := f.rec.strikesOf(m.ID); len(strikes) != 1 || !strikes[0].TargetDied {
		t.Fatalf("the late blow %+v, want one pushed killing blow", strikes)
	}
	f.a.mu.Lock()
	_, recorded := f.a.kills[m.ID]
	n := len(f.a.kills)
	f.a.mu.Unlock()
	if recorded || n != 0 {
		t.Fatalf("kills holds %d entr(y/ies) and monster %d is recorded (%v) after its brain was dropped: nothing collects it", n, m.ID, recorded)
	}
}

// A monster struck while still on a leg, inside its band: the pass queues the
// in-band stop and the first swing on the same tick, and the stop must reach
// the zone BEFORE the blow -- the client's walking-body rule leaves a body
// unturned until the stop lands, so a blow ahead of it draws the first swing
// on a still-walking body (round 547, tick step 6). Before this round the
// swing was handed to its worker under a.mu, during the pass, and the worker
// pushed the blow while the stop still sat in a.pending. The push here holds
// every stop for up to 300 ms, or until a blow has been recorded, to give a
// racing worker every chance to win -- the same bounded wait as the
// wire-order tests.
func TestStopPrecedesTheFirstInBandBlow(t *testing.T) {
	battleForTest(t, true)
	f := startBattleFixture(t, 34, 0, 0)
	blowSeen := make(chan struct{})
	var once sync.Once
	var mu sync.Mutex
	var order []uint16
	f.a.push = func(zone string, p *proto.Packet) {
		if p.Opcode == OpMonsterMoved {
			select {
			case <-blowSeen:
			case <-time.After(300 * time.Millisecond):
			}
		}
		mu.Lock()
		order = append(order, p.Opcode)
		mu.Unlock()
		if p.Opcode == OpMonsterAttacked {
			once.Do(func() { close(blowSeen) })
		}
		f.rec.push(zone, p)
	}
	m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 8, 0, 0, 1000, 0, 15, 0)
	now := aiT0
	monsterAITick(now) // IDLE
	now = now.Add(MonsterAITick)
	// A leg under way, straight away from Aria, that one tick's step (0.8 at
	// the walk speed 8) leaves inside the band: (8, 0.8) is 8.04 away.
	if _, ok := f.monsters.SetMotion(m.ID, 8, 50, 8, 0); !ok {
		t.Fatal("setup: no leg")
	}
	noteStruck(f.monsters, m.ID, f.aria) // with the flag on, no stop here
	if cur, _ := f.monsters.Get(m.ID); !cur.Moving {
		t.Fatal("setup: the blow stopped the monster; with -monster-battle on it must not")
	}
	f.rec.reset()
	monsterAITick(now) // BATTLE, in reach and walking: the stop and the first swing
	now = now.Add(MonsterAITick)
	if !waitFor(t, 2*time.Second, func() bool { return len(f.rec.strikesOf(m.ID)) == 1 }) {
		t.Fatalf("no blow within 2 s (%d pushed)", len(f.rec.strikesOf(m.ID)))
	}
	if moves := f.rec.of(m.ID); len(moves) != 1 || !isStop(moves[0]) {
		t.Fatalf("the tick pushed %d move(s) %+v, want exactly the in-band stop", len(moves), moves)
	}
	mu.Lock()
	got := append([]uint16(nil), order...)
	mu.Unlock()
	if len(got) != 2 || got[0] != OpMonsterMoved || got[1] != OpMonsterAttacked {
		t.Fatalf("the zone received opcodes %04x, want the stop 0x%04x before the blow 0x%04x", got, OpMonsterMoved, OpMonsterAttacked)
	}
}
