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

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/ai"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/OpenSRO/OpenSRO/server/internal/party"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/quest"
	"github.com/OpenSRO/OpenSRO/server/internal/skill"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
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
	monsters.StepCells(1, nil, nil)
	monsters.StepCells(1, nil, nil)
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
	hub.Enter(gateway.NewTestSession(91001), attacker, "Aria", 1, "jangan", world.Position{})
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
	hub.Enter(gateway.NewTestSession(91002), attacker, "Aria", 1, "jangan", world.Position{})
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
	hub.Enter(gateway.NewTestSession(91003), attacker, "Aria", 1, "jangan", world.Position{})
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
	hub.Enter(gateway.NewTestSession(91004), attacker, "Aria", 1, "jangan", world.Position{})
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
	hub.Enter(gateway.NewTestSession(91005), aChar, "Aria", 1, "jangan", world.Position{})
	hub.Enter(gateway.NewTestSession(91006), bChar, "Bora", 1, "jangan", world.Position{})
	hub.Enter(gateway.NewTestSession(91007), cChar, "Cato", 1, "donwhang", world.Position{})
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
// monster_ai.md, "OpenSRO's own monster protocol"): monster 31 "Mob" /
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
	// potions is the queue a kill empties under -player-dead-state (round 549).
	potions *PotionQueue
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
	hub.Enter(gateway.NewTestSession(uint64(91100+seed)), c.ID, "Aria", 1, "jangan", world.Position{X: ariaX, Z: ariaZ})
	monsters := newAIHub(seed)
	rec := &pushRecorder{}
	potions := NewPotionQueue()
	a := newMonsterAI(hub, monsters, nil, MonsterAIConfig{Chars: chars, Equipment: eq, Items: items, Potions: potions},
		rand.New(rand.NewSource(seed)), rec.push)
	monsterAIRuntime.Store(a)
	t.Cleanup(func() { monsterAIRuntime.Store(nil) })
	return &battleFixture{a: a, hub: hub, monsters: monsters, chars: chars, aria: c.ID, rec: rec, potions: potions}
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
		g.monsters.StepCells(1, nil, nil)
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

// panicOnceChars is a character store whose first ApplyDamage panics -- a
// store's own fault, as a strike worker would meet it -- and behaves after
// that. ApplyDamage is the first store call a swing makes: until round 555 it
// was the level read, a GetByID, which now comes off the world entity.
type panicOnceChars struct {
	character.Store
	panicked atomic.Bool
}

func (s *panicOnceChars) ApplyDamage(ctx context.Context, id int64, amount int) (int, bool, error) {
	if s.panicked.CompareAndSwap(false, true) {
		panic("test: the character store fell over")
	}
	return s.Store.ApplyDamage(ctx, id, amount)
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

// ---- The player's dead state, the server half (round 549) ----

// deadStateForTest turns -player-dead-state on for the rest of the test and
// puts it back when the test ends.
func deadStateForTest(t *testing.T, on bool) {
	t.Helper()
	was := playerDeadState.Load()
	SetPlayerDeadState(on)
	t.Cleanup(func() { SetPlayerDeadState(was) })
}

func TestPlayerDeadStateOffByDefault(t *testing.T) {
	if playerDeadState.Load() {
		t.Fatal("the player dead state is on with nothing having asked for it: -player-dead-state is off by default")
	}
}

// THE RED (round 549): with -player-dead-state on, a Mangyang's killing blow
// from the AI tick leaves Aria DEAD -- HP 0 in the store and in the push
// (TargetDied with TargetHP 0, which is how round 548's client knows), life
// state 2 in the world hub with the time of death, her queued potion gone --
// and the monster, finding no valid target (IsValidTarget's life state 1),
// goes to IDLE and swings no more. revivePlayer then brings her back where
// she lies at character.RespawnFraction of her maximum, life state 1, and the
// Mangyang fights her again. Before this round the same blow put her back on
// her feet in the same call: the push carried the respawn HP (80, above 0),
// the store read 80, and the hub knew no life state -- which is exactly what
// TestMonsterBattleKillSendsItToIdle still pins with the flag off (the
// control).
func TestMonsterKillLeavesThePlayerDead(t *testing.T) {
	battleForTest(t, true)
	deadStateForTest(t, true)
	ctx := context.Background()
	f := startBattleFixture(t, 27, 0, 0)
	// A potion step queued before the kill: the engine empties both lists at
	// death (GObjPC::FUN_004e67b0).
	f.potions.pushLocked(f.aria, potionPoolHP, potionEntry{step: 25, count: 4})
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
	if !got.TargetDied || got.TargetHP != 0 {
		t.Errorf("the killing blow %+v; want the death with TargetHP 0 (no respawn)", got)
	}
	after, err := f.chars.GetByID(ctx, f.aria)
	if err != nil {
		t.Fatal(err)
	}
	if after.HP != 0 {
		t.Errorf("Aria's HP after the kill = %d, want 0: she stays dead", after.HP)
	}
	e, ok := f.hub.EntityByCharacterID(f.aria)
	if !ok || e.Life != world.LifeDead || e.DiedAt.IsZero() {
		t.Errorf("Aria's entity after the kill: in world %v, life %d, died at %v; want life state 2 with a time of death", ok, e.Life, e.DiedAt)
	}
	if ids := f.potions.characters(); len(ids) != 0 {
		t.Errorf("Aria's potion queue survived her death: %v (FUN_004e67b0 empties both lists)", ids)
	}

	// The tick after: no valid target (life state 2), the 0x23 exit to IDLE,
	// and nothing more is swung at a dead player over 4 s of ticks.
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	if st := stateOf(t, f.a, m.ID); st != ai.StateIdle {
		t.Fatalf("state %v on the tick after the kill, want IDLE (a dead target is invalid)", st)
	}
	for i := 0; i < 40; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	time.Sleep(50 * time.Millisecond)
	if n := len(f.rec.strikesOf(m.ID)); n != 1 {
		t.Errorf("%d blows after the kill, want none: the dead are no target", n-1)
	}
	// A step queued on a dead character lands nothing (ApplyHPMPDelta wants
	// life state 1, 0x4a87e8) and the list goes.
	f.potions.pushLocked(f.aria, potionPoolHP, potionEntry{step: 25, count: 4})
	potionQueueTick(ctx, f.hub, f.chars, f.potions, RegenDeps{}, nil)
	if c, _ := f.chars.GetByID(ctx, f.aria); c.HP != 0 {
		t.Errorf("a potion step healed a dead character to %d", c.HP)
	}
	if ids := f.potions.characters(); len(ids) != 0 {
		t.Errorf("a dead character's potion queue was kept: %v", ids)
	}
	// Regen leaves the dead at zero (mana.RegenPerTick's cap of 0 at 0).
	regenPass(ctx, f.hub, f.chars, RegenDeps{}, nil, time.Now(), true)
	if c, _ := f.chars.GetByID(ctx, f.aria); c.HP != 0 {
		t.Errorf("regen raised a dead character to %d", c.HP)
	}

	// The revive: in place, the retail handler's arithmetic from HP 0 --
	// 1 + trunc(0.4 x MaxHP) (reviveHPDelta, round 550) -- life state 1, the
	// time of death cleared; a second one finds nobody dead.
	c, _, err := revivePlayer(ctx, f.chars, nil, f.hub, f.aria)
	if err != nil {
		t.Fatalf("revivePlayer: %v", err)
	}
	if want := reviveHPDelta(c.MaxHP()); c.HP != want {
		t.Errorf("revived at HP %d, want %d (1 + trunc(0.4 x %d))", c.HP, want, c.MaxHP())
	}
	if e, ok := f.hub.EntityByCharacterID(f.aria); !ok || e.Life != world.LifeAlive || !e.DiedAt.IsZero() {
		t.Errorf("Aria's entity after the revive: life %d, died at %v; want life state 1 and no time of death", e.Life, e.DiedAt)
	}
	if _, _, err := revivePlayer(ctx, f.chars, nil, f.hub, f.aria); err != errNotDead {
		t.Errorf("a second revive: %v, want errNotDead", err)
	}
	// Alive again, she is a target again: the next blow she draws lands.
	noteStruck(f.monsters, m.ID, f.aria)
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	if !waitFor(t, 2*time.Second, func() bool { return len(f.rec.strikesOf(m.ID)) == 2 }) {
		t.Fatalf("no blow on the revived player within 2 s (%d pushed)", len(f.rec.strikesOf(m.ID)))
	}
	if second := f.rec.strikesOf(m.ID)[1]; !second.TargetDied || second.TargetHP != 0 {
		t.Errorf("the second blow %+v; want another kill at HP 0", second)
	}
}

// A swing already handed to a strike worker when its target died -- another
// monster's kill inside the hand-off window -- is dropped, not made: a blow on
// a dead character would charge the death penalty a second time (round 549,
// runStrike). Two Mangyangs in BATTLE on Aria at once; the first kills her,
// the second's swing of the same pass finds her dead.
//
// The wait is on the two workers' completion (observeStrikes / awaitStrikes),
// not a sleep: CI run 36061784919 on round 549's tree failed this test on the
// slower kakariko runner with "2 blows landed on one player from two
// monsters' first swings, want exactly 1" -- the double kill the store's
// transition rule closes (round 550) -- and its 300 ms sleep was the only
// thing standing between the tick and the assertion.
func TestSwingOnAPlayerAlreadyDeadIsDropped(t *testing.T) {
	battleForTest(t, true)
	deadStateForTest(t, true)
	f := startBattleFixture(t, 28, 0, 0)
	finished := observeStrikes(f.a)
	first := f.monsters.SpawnSpecies("jangan", chaseMangyang, 8, 0, 0, 100000, 0, 100000, 0)
	second := f.monsters.SpawnSpecies("jangan", chaseMangyang, -8, 0, 0, 100000, 0, 100000, 0)
	now := aiT0
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	noteStruck(f.monsters, first.ID, f.aria)
	noteStruck(f.monsters, second.ID, f.aria)
	f.rec.reset()
	monsterAITick(now) // both enter BATTLE in reach: two swings handed over this pass
	now = now.Add(MonsterAITick)
	awaitStrikes(t, finished, first.ID, second.ID)
	blows := len(f.rec.strikesOf(first.ID)) + len(f.rec.strikesOf(second.ID))
	if blows != 1 {
		t.Fatalf("%d blows landed on one player from two monsters' first swings, want exactly 1: the second found her dead", blows)
	}
	if c, _ := f.chars.GetByID(context.Background(), f.aria); c.HP != 0 {
		t.Errorf("HP %d after the kill, want 0", c.HP)
	}
	for i := 0; i < 20; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	for _, id := range []int64{first.ID, second.ID} {
		if st := stateOf(t, f.a, id); st != ai.StateIdle {
			t.Errorf("monster %d in %v two seconds after the kill, want IDLE", id, st)
		}
	}
}

// observeStrikes hooks the runtime's strike workers (monsterAI.strikeDone)
// and returns the channel each finished swing's monster id arrives on. Set
// before the first tick: a worker starts on its monster's first swing and
// reads the hook from then on. The hook never blocks a worker: a swing
// nobody waits for is dropped once the buffer is full.
func observeStrikes(a *monsterAI) <-chan int64 {
	finished := make(chan int64, 64)
	a.strikeDone = func(id int64) {
		select {
		case finished <- id:
		default:
		}
	}
	return finished
}

// awaitStrikes waits until each monster in ids has finished one swing --
// landed or dropped -- and fails the test after 5 s otherwise: the workers'
// completion is what the assertions after a tick's hand-off wait for, not a
// sleep (round 550: CI run 36061784919).
func awaitStrikes(t *testing.T, finished <-chan int64, ids ...int64) {
	t.Helper()
	pending := map[int64]bool{}
	for _, id := range ids {
		pending[id] = true
	}
	deadline := time.After(5 * time.Second)
	for len(pending) > 0 {
		select {
		case id := <-finished:
			delete(pending, id)
		case <-deadline:
			t.Fatalf("%d of %d strike workers had not finished a swing after 5 s: %v", len(pending), len(ids), pending)
		}
	}
}

// ---- Batch-17 review follow-ups (round 550) ----

// twoBlowStore interleaves two strike workers' blows on one character
// deterministically: the first ApplyDamage to arrive waits until the second
// has arrived, then runs; the second runs right after it and BEFORE the first
// worker's next store call (its penalty's GetByID) -- the window in which both
// blows have read the pool and neither has written the penalty or the respawn.
type twoBlowStore struct {
	character.Store
	arrivals                    atomic.Int32
	both, firstDone, secondDone chan struct{}
}

func newTwoBlowStore(inner character.Store) *twoBlowStore {
	return &twoBlowStore{Store: inner, both: make(chan struct{}), firstDone: make(chan struct{}), secondDone: make(chan struct{})}
}

func (s *twoBlowStore) ApplyDamage(ctx context.Context, id int64, amount int) (int, bool, error) {
	switch s.arrivals.Add(1) {
	case 1:
		<-s.both
		hp, died, err := s.Store.ApplyDamage(ctx, id, amount)
		close(s.firstDone)
		return hp, died, err
	case 2:
		close(s.both)
		<-s.firstDone
		hp, died, err := s.Store.ApplyDamage(ctx, id, amount)
		close(s.secondDone)
		return hp, died, err
	}
	return s.Store.ApplyDamage(ctx, id, amount)
}

func (s *twoBlowStore) GetByID(ctx context.Context, id int64) (*character.Character, error) {
	select {
	case <-s.firstDone:
		<-s.secondDone // the first worker's penalty read waits for the second blow
	default:
	}
	return s.Store.GetByID(ctx, id)
}

// ONE DEATH PENALTY PER KILL (round 550). Two monsters' swings land on Aria
// inside each other's window: both pass runStrike's dead check, both reach
// chars.ApplyDamage before either has written the penalty. The store admits
// one transition to 0 (Store.ApplyDamage's contract), so exactly one blow is
// a kill: one push, TargetDied once, the experience penalty charged ONCE
// (level 11, exp_unit 259 x 100 = 25900 of her 30000), and the other blow
// lands nothing and pushes nothing. Flag on: she is dead at HP 0 after it;
// flag off: back on her feet at the respawn HP. Before this round both blows
// read died=true (the store reported a character already at 0 as died) and
// both charged the penalty -- her exp went to 0 -- and both pushed a death;
// with the flag on the second's compare-and-swap in markDead failed only
// after the penalty had landed.
func TestTwoKillsChargeOneDeathPenalty(t *testing.T) {
	tbl, err := leveldata.ParseCSV(strings.NewReader("level,exp,mastery_sp,exp_unit\n10,23500,9,235\n11,34898,12,259\n"))
	if err != nil {
		t.Fatalf("ParseCSV: %v", err)
	}
	loss, ok := tbl.DeathPenaltyExp(11, leveldata.DeathPenaltyKilledByMonster)
	if !ok || loss <= 0 {
		t.Fatalf("setup: no death penalty at level 11 (%d, %v)", loss, ok)
	}
	for _, flag := range []bool{true, false} {
		t.Run(map[bool]string{true: "dead state on", false: "dead state off"}[flag], func(t *testing.T) {
			battleForTest(t, true)
			deadStateForTest(t, flag)
			prev := levelTable
			SetLevelTable(tbl)
			t.Cleanup(func() { SetLevelTable(prev) })
			ctx := context.Background()
			f := startBattleFixture(t, 36, 0, 0)
			c, _ := f.chars.GetByID(ctx, f.aria)
			const startExp = 30000
			if err := f.chars.SetLeveling(ctx, f.aria, 11, startExp, c.StatPoints, c.Str, c.Int); err != nil {
				t.Fatal(err)
			}
			store := newTwoBlowStore(f.chars)
			f.a.deps.chars = store
			first := f.monsters.SpawnSpecies("jangan", chaseMangyang, 8, 0, 0, 100000, 0, 100000, 0)
			second := f.monsters.SpawnSpecies("jangan", chaseMangyang, -8, 0, 0, 100000, 0, 100000, 0)
			var wg sync.WaitGroup
			for _, m := range []combat.Monster{*first, *second} {
				wg.Add(1)
				go func(m combat.Monster) {
					defer wg.Done()
					f.a.runStrike(m.ID, strikeJob{m: m, target: f.aria})
				}(m)
			}
			done := make(chan struct{})
			go func() { wg.Wait(); close(done) }()
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				t.Fatal("the two workers did not both finish within 5 s: the interleaving deadlocked")
			}
			blows := append(f.rec.strikesOf(first.ID), f.rec.strikesOf(second.ID)...)
			deaths := 0
			for _, b := range blows {
				if b.TargetDied {
					deaths++
				}
			}
			if len(blows) != 1 || deaths != 1 {
				t.Errorf("%d blow(s) pushed, %d of them a death (%+v); want exactly one blow, the kill: the other found her at 0 and landed nothing", len(blows), deaths, blows)
			}
			after, _ := f.chars.GetByID(ctx, f.aria)
			if after.Exp != startExp-loss {
				t.Errorf("Aria's exp after two simultaneous kills = %d, want %d (one penalty of %d from %d, not two)", after.Exp, startExp-loss, loss, startExp)
			}
			if after.Level != 11 {
				t.Errorf("Aria's level = %d, want 11 untouched", after.Level)
			}
			e, _ := f.hub.EntityByCharacterID(f.aria)
			if flag {
				if after.HP != 0 || e.Life != world.LifeDead {
					t.Errorf("flag on: HP %d, life %d; want dead at 0", after.HP, e.Life)
				}
				if len(blows) == 1 && blows[0].TargetHP != 0 {
					t.Errorf("flag on: the kill's push carries TargetHP %d, want 0", blows[0].TargetHP)
				}
			} else {
				if want := int(float64(after.MaxHP()) * character.RespawnFraction); after.HP != want || e.Life != world.LifeAlive {
					t.Errorf("flag off: HP %d, life %d; want the respawn HP %d, alive", after.HP, e.Life, want)
				}
			}
		})
	}
}

// A push that panics inside gateway.Session.Send -- here a test session with
// no connection, through the real zone broadcast -- is swallowed by
// runStrike's recover, and since round 550 leaves that session's wire lock
// FREE: broadcast releases it by defer. Until this round the unlock came after
// the Send, so the swallowed panic left the lock held and the next tick's
// push to that session (and handleMonsterList on it) blocked for ever instead
// of the process crashing. The blow itself had landed before the push.
func TestPanickingPushLeavesTheWireLockFree(t *testing.T) {
	battleForTest(t, true)
	f := startBattleFixture(t, 37, 0, 0)
	f.a.push = nil // the real push (deliver, round 656): each watcher's Send under its wire lock
	var log lockedBuffer
	f.a.logger = slog.New(slog.NewTextHandler(&log, nil))
	m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 8, 0, 0, 1000, 0, 15, 0)
	f.a.runStrike(m.ID, strikeJob{m: *m, target: f.aria})
	if !strings.Contains(log.String(), "strike panicked") {
		t.Fatalf("no 'strike panicked' line: the test session's Send did not panic inside the push; log:\n%s", log.String())
	}
	if c, _ := f.chars.GetByID(context.Background(), f.aria); c.HP != character.StartingMaxHP-15 {
		t.Errorf("Aria's HP %d, want %d: the blow lands before the push", c.HP, character.StartingMaxHP-15)
	}
	e, ok := f.hub.EntityByCharacterID(f.aria)
	if !ok || e.Session == nil {
		t.Fatal("setup: Aria has no session in the hub")
	}
	l := f.a.wireLock(e.Session)
	if !l.TryLock() {
		t.Fatal("Aria's wire lock is still held after a push that panicked inside Send: the next push to her, and her monster list, would block for ever")
	}
	l.Unlock()
}

// ---- Round-550 follow-up: a living character at 0 HP is killable (round 551) ----

// zeroAria takes Aria's pool to 0 through the store WITHOUT a kill -- the
// state an HP-cost cast leaves its caster in (session/skill.go pays through
// Store.ApplyDamage and treats no transition as a death; the engine's gate
// passes on HP == cost, `cmp eax,[esp+0x10]; jge` at 0x58e28c/0x58e290,
// combat.CanPaySkillHealth): life state 1, HP 0.
func zeroAria(t *testing.T, chars character.Store, hub *world.Hub, aria int64) {
	t.Helper()
	ctx := context.Background()
	c, err := chars.GetByID(ctx, aria)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := chars.ApplyDamage(ctx, aria, c.HP); err != nil {
		t.Fatal(err)
	}
	if c, _ = chars.GetByID(ctx, aria); c.HP != 0 {
		t.Fatalf("setup: Aria's HP %d, want 0", c.HP)
	}
	if e, ok := hub.EntityByCharacterID(aria); !ok || e.Life != world.LifeAlive {
		t.Fatalf("setup: Aria's life state %d (in world %v), want 1: alive at 0", e.Life, ok)
	}
}

// penaltyTableForTest is a two-row level table on which a level-11 death by
// a monster costs 25900 experience (exp_unit 259 x 100), the number
// TestTwoKillsChargeOneDeathPenalty pins.
func penaltyTableForTest(t *testing.T) (*leveldata.Table, int64) {
	t.Helper()
	tbl, err := leveldata.ParseCSV(strings.NewReader("level,exp,mastery_sp,exp_unit\n10,23500,9,235\n11,34898,12,259\n"))
	if err != nil {
		t.Fatalf("ParseCSV: %v", err)
	}
	loss, ok := tbl.DeathPenaltyExp(11, leveldata.DeathPenaltyKilledByMonster)
	if !ok || loss <= 0 {
		t.Fatalf("setup: no death penalty at level 11 (%d, %v)", loss, ok)
	}
	prev := levelTable
	SetLevelTable(tbl)
	t.Cleanup(func() { SetLevelTable(prev) })
	return tbl, loss
}

// A LIVING CHARACTER AT 0 HP IS KILLED BY THE NEXT BLOW (round 551). Aria's
// pool is at 0 without a death -- an HP-cost cast's caster -- and a
// Mangyang's swing lands on her: one push, TargetDied, the death penalty
// charged once (level 11: 25900 of 30000), and then the dead state (flag on:
// life state 2 at HP 0) or the respawn (flag off: RespawnFraction, alive).
// On round 550's tree the swing read (0, false) from the store, was dropped,
// and she stayed alive at 0 with her experience intact -- unkillable, for
// ever (the batch-18 review's blocking note); the kill lock decides now.
func TestSwingOnACharacterAliveAtZeroKills(t *testing.T) {
	for _, flag := range []bool{true, false} {
		t.Run(map[bool]string{true: "dead state on", false: "dead state off"}[flag], func(t *testing.T) {
			battleForTest(t, true)
			deadStateForTest(t, flag)
			_, loss := penaltyTableForTest(t)
			ctx := context.Background()
			f := startBattleFixture(t, 38, 0, 0)
			c, _ := f.chars.GetByID(ctx, f.aria)
			const startExp = 30000
			if err := f.chars.SetLeveling(ctx, f.aria, 11, startExp, c.StatPoints, c.Str, c.Int); err != nil {
				t.Fatal(err)
			}
			zeroAria(t, f.chars, f.hub, f.aria)
			m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 8, 0, 0, 100000, 0, 15, 0)
			f.a.runStrike(m.ID, strikeJob{m: *m, target: f.aria})
			blows := f.rec.strikesOf(m.ID)
			if len(blows) != 1 || !blows[0].TargetDied || blows[0].DeathExpLost != loss {
				t.Fatalf("a swing on a character alive at 0 pushed %+v; want exactly one killing blow costing %d exp", blows, loss)
			}
			after, _ := f.chars.GetByID(ctx, f.aria)
			if after.Exp != startExp-loss || after.Level != 11 {
				t.Errorf("Aria after the kill: level %d exp %d, want level 11 exp %d (one penalty of %d)", after.Level, after.Exp, startExp-loss, loss)
			}
			e, _ := f.hub.EntityByCharacterID(f.aria)
			if flag {
				if after.HP != 0 || e.Life != world.LifeDead || blows[0].TargetHP != 0 {
					t.Errorf("flag on: HP %d, life %d, pushed TargetHP %d; want dead at 0", after.HP, e.Life, blows[0].TargetHP)
				}
			} else {
				want := int(float64(after.MaxHP()) * character.RespawnFraction)
				if after.HP != want || e.Life != world.LifeAlive || int(blows[0].TargetHP) != want {
					t.Errorf("flag off: HP %d, life %d, pushed TargetHP %d; want the respawn HP %d, alive", after.HP, e.Life, blows[0].TargetHP, want)
				}
			}
		})
	}
}

// TWO SWINGS ON A CHARACTER ALIVE AT 0 STILL CHARGE ONE PENALTY (round 551).
// The same interleaving as TestTwoKillsChargeOneDeathPenalty (both blows read
// the pool before either reads it back), on a pool that is ALREADY at 0: both
// ApplyDamages report (0, false), so the store's transition cannot arbitrate
// at all, and the kill lock must -- one push, one death, one penalty; flag
// on: dead at 0; flag off: respawned. On round 550's tree both blows were
// dropped: no push, no penalty, alive at 0.
func TestTwoSwingsOnACharacterAliveAtZeroChargeOnePenalty(t *testing.T) {
	for _, flag := range []bool{true, false} {
		t.Run(map[bool]string{true: "dead state on", false: "dead state off"}[flag], func(t *testing.T) {
			battleForTest(t, true)
			deadStateForTest(t, flag)
			_, loss := penaltyTableForTest(t)
			ctx := context.Background()
			f := startBattleFixture(t, 39, 0, 0)
			c, _ := f.chars.GetByID(ctx, f.aria)
			const startExp = 30000
			if err := f.chars.SetLeveling(ctx, f.aria, 11, startExp, c.StatPoints, c.Str, c.Int); err != nil {
				t.Fatal(err)
			}
			zeroAria(t, f.chars, f.hub, f.aria)
			store := newTwoBlowStore(f.chars)
			f.a.deps.chars = store
			first := f.monsters.SpawnSpecies("jangan", chaseMangyang, 8, 0, 0, 100000, 0, 15, 0)
			second := f.monsters.SpawnSpecies("jangan", chaseMangyang, -8, 0, 0, 100000, 0, 15, 0)
			var wg sync.WaitGroup
			for _, m := range []combat.Monster{*first, *second} {
				wg.Add(1)
				go func(m combat.Monster) {
					defer wg.Done()
					f.a.runStrike(m.ID, strikeJob{m: m, target: f.aria})
				}(m)
			}
			done := make(chan struct{})
			go func() { wg.Wait(); close(done) }()
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				t.Fatal("the two workers did not both finish within 5 s: the interleaving deadlocked")
			}
			blows := append(f.rec.strikesOf(first.ID), f.rec.strikesOf(second.ID)...)
			deaths := 0
			for _, b := range blows {
				if b.TargetDied {
					deaths++
				}
			}
			if len(blows) != 1 || deaths != 1 {
				t.Errorf("%d blow(s) pushed, %d of them a death (%+v); want exactly one blow, the kill, on a character alive at 0", len(blows), deaths, blows)
			}
			after, _ := f.chars.GetByID(ctx, f.aria)
			if after.Exp != startExp-loss {
				t.Errorf("Aria's exp after two simultaneous blows at 0 = %d, want %d (one penalty of %d, not none and not two)", after.Exp, startExp-loss, loss)
			}
			e, _ := f.hub.EntityByCharacterID(f.aria)
			if flag {
				if after.HP != 0 || e.Life != world.LifeDead {
					t.Errorf("flag on: HP %d, life %d; want dead at 0", after.HP, e.Life)
				}
			} else if want := int(float64(after.MaxHP()) * character.RespawnFraction); after.HP != want || e.Life != world.LifeAlive {
				t.Errorf("flag off: HP %d, life %d; want the respawn HP %d, alive", after.HP, e.Life, want)
			}
		})
	}
}

// --- Target acquisition, -monster-aggro (round 552) --------------------------

// aggroForTest turns -monster-aggro on or off for the rest of the test and
// puts it back when the test ends. Production only ever passes true with the
// battle in effect and the dead state on (cmd/server's monsterAggroAllowed),
// so the tests below set all three.
func aggroForTest(t *testing.T, on bool) {
	t.Helper()
	was := monsterAggro.Load()
	SetMonsterAggro(on)
	t.Cleanup(func() { SetMonsterAggro(was) })
}

// standingMangyang is chaseMangyang with no speed at all: it can neither
// WANDER (the leg needs a run speed) nor chase, so a control about the
// acquisition radius is measured from where it was spawned.
var standingMangyang = func() combat.Species {
	s := chaseMangyang
	s.WalkSpeed, s.RunSpeed = 0, 0
	return s
}()

// ariaSession is Aria's session in the fixture's hub, for a walk (hub.Move).
func (f *battleFixture) ariaSession(t *testing.T) *gateway.Session {
	t.Helper()
	e, ok := f.hub.EntityByCharacterID(f.aria)
	if !ok {
		t.Fatal("Aria is not in the world")
	}
	return e.Session
}

// tickUntilBattle ticks from now until monster id is in BATTLE or n ticks
// have passed, and returns the clock and whether it got there.
func tickUntilBattle(t *testing.T, a *monsterAI, id int64, now time.Time, n int) (time.Time, bool) {
	t.Helper()
	for i := 0; i < n; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
		if stateOf(t, a, id) == ai.StateBattle {
			return now, true
		}
	}
	return now, false
}

func TestMonsterAggroOffByDefault(t *testing.T) {
	if monsterAggro.Load() {
		t.Fatal("the monster aggro is on with nothing having asked for it: -monster-aggro is off by default")
	}
}

// THE RED (round 552): with -monster-aggro on, a player who walks to 50
// units of an idle Mangyang (acquisition radius 6 + 100 = 106) is noticed
// within one scan period (at most 1500 ms, 15 ticks), the monster enters
// BATTLE with her as its target, its first push is the chase leg toward her
// (mode 1 at the run speed), and its first swing lands once it reaches its
// band. Standing 200 units off she is never noticed. Before this round
// nothing noticed anyone: a monster entered BATTLE only when struck.
func TestMonsterNoticesAPlayerWalkingIntoRange(t *testing.T) {
	battleForTest(t, true)
	deadStateForTest(t, true)
	aggroForTest(t, true)
	f := startBattleFixture(t, 31, 200, 0)
	m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 0, 0, 0, 1000, 0, 15, 0)
	now := aiT0
	// 3 s out of range: a WANDER leg at 8 u/s moves the monster at most 24
	// units, so she stays beyond 106.
	for i := 0; i < 30; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
		if st := stateOf(t, f.a, m.ID); st == ai.StateBattle {
			t.Fatalf("tick %d: BATTLE with Aria 200 units off (radius 106)", i)
		}
	}
	// She walks to 50 units of wherever the monster stands now.
	cur, _ := f.monsters.Get(m.ID)
	f.hub.Move(f.ariaSession(t), world.Position{X: cur.X + 50, Z: cur.Z})
	f.rec.reset()
	now, noticed := tickUntilBattle(t, f.a, m.ID, now, 16)
	if !noticed {
		t.Fatalf("not in BATTLE 1.6 s after Aria walked to 50 units (the scan period is at most 1500 ms); state %v", stateOf(t, f.a, m.ID))
	}
	f.a.mu.Lock()
	target := f.a.brains[m.ID].target
	f.a.mu.Unlock()
	if target != f.aria {
		t.Fatalf("the target is %d, want Aria %d", target, f.aria)
	}
	// The next tick's push is the chase toward her: mode 1 at 22.
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	moves := f.rec.of(m.ID)
	if len(moves) == 0 {
		t.Fatal("no leg pushed on the tick after the monster noticed her")
	}
	leg := moves[len(moves)-1]
	if leg.Mode != 1 || leg.Speed != 22 {
		t.Errorf("the leg after noticing is mode %d at %g, want the chase: mode 1 at the run speed 22", leg.Mode, leg.Speed)
	}
	e, _ := f.hub.EntityByCharacterID(f.aria)
	if d := math.Hypot(float64(leg.DestX)-e.Pos.X, float64(leg.DestZ)-e.Pos.Z); math.Abs(d-10) > 1.5 {
		t.Errorf("the chase leg ends %.1f from Aria, want about 10 (the stop distance)", d)
	}
	// 40 units at 22 u/s is under 2 s; then the first swing.
	for i := 0; i < 40 && len(f.rec.strikesOf(m.ID)) == 0; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
		time.Sleep(2 * time.Millisecond)
	}
	if !waitFor(t, 2*time.Second, func() bool { return len(f.rec.strikesOf(m.ID)) >= 1 }) {
		t.Fatal("no blow on Aria within 4 s of the monster noticing her")
	}
	if s := f.rec.strikesOf(m.ID)[0]; s.TargetCharacterID != f.aria || s.Damage != 15 {
		t.Errorf("the first blow %+v, want 15 on Aria %d", s, f.aria)
	}
}

// Two players in range: the NEARER one is the target, not the first by id.
// Aria (the lower id) stands 80 units off and Bram 50, so Bram is picked,
// and the chase leg aims at him. The first scan is immediate (timer 1 starts
// fired), so the monster is in BATTLE on its first tick.
func TestMonsterNoticesTheNearerOfTwoPlayers(t *testing.T) {
	battleForTest(t, true)
	deadStateForTest(t, true)
	aggroForTest(t, true)
	f := startBattleFixture(t, 32, -80, 0)
	bram, err := f.chars.Create(context.Background(), 1, "Bram")
	if err != nil {
		t.Fatalf("creating Bram: %v", err)
	}
	if bram.ID <= f.aria {
		t.Fatalf("setup: Bram's id %d is not above Aria's %d", bram.ID, f.aria)
	}
	f.hub.Enter(gateway.NewTestSession(91232), bram.ID, "Bram", 1, "jangan", world.Position{X: 50, Z: 0})
	m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 0, 0, 0, 1000, 0, 15, 0)
	now := aiT0
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	if st := stateOf(t, f.a, m.ID); st != ai.StateBattle {
		t.Fatalf("state %v after the first tick, want BATTLE: the first scan is immediate", st)
	}
	f.a.mu.Lock()
	target := f.a.brains[m.ID].target
	f.a.mu.Unlock()
	if target != bram.ID {
		t.Fatalf("the target is %d, want Bram %d (50 units off; Aria is 80 off)", target, bram.ID)
	}
	monsterAITick(now)
	moves := f.rec.of(m.ID)
	if len(moves) != 1 || moves[0].Mode != 1 || math.Abs(float64(moves[0].DestX)-40) > 1e-3 || math.Abs(float64(moves[0].DestZ)) > 1e-3 {
		t.Fatalf("the chase leg %+v, want one leg to (40, 0), the stop distance from Bram", moves)
	}
}

// CONTROL, the default: with -monster-aggro off the same player 50 units
// from a Mangyang is never noticed -- no BATTLE, no leg but its own wandering,
// no blow -- exactly as before this round. The battle and dead-state flags
// are on, as they would be in production alongside the aggro.
func TestMonsterAggroOffLeavesPlayersUnnoticed(t *testing.T) {
	battleForTest(t, true)
	deadStateForTest(t, true)
	aggroForTest(t, false)
	f := startBattleFixture(t, 33, 50, 0)
	m := f.monsters.SpawnSpecies("jangan", standingMangyang, 0, 0, 0, 1000, 0, 15, 0)
	now := aiT0
	for i := 0; i < 60; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
		if st := stateOf(t, f.a, m.ID); st != ai.StateIdle {
			t.Fatalf("tick %d: state %v with the aggro off, want IDLE throughout", i, st)
		}
	}
	if n := len(f.rec.strikesOf(m.ID)); n != 0 {
		t.Errorf("%d blow(s) on Aria with the aggro off", n)
	}
	if c, _ := f.chars.GetByID(context.Background(), f.aria); c.HP != character.StartingMaxHP {
		t.Errorf("Aria's HP %d, want untouched %d", c.HP, character.StartingMaxHP)
	}
}

// The radius truncates and is inclusive: a player at 110 units of a standing
// Mangyang (radius 106) is not noticed in 3 s, while one at exactly 106 is on
// the first tick. The 110 half is a control (it holds before this round too);
// the 106 half is not.
func TestMonsterAcquisitionRadiusIsInclusive(t *testing.T) {
	battleForTest(t, true)
	deadStateForTest(t, true)
	aggroForTest(t, true)
	f := startBattleFixture(t, 34, 110, 0)
	m := f.monsters.SpawnSpecies("jangan", standingMangyang, 0, 0, 0, 1000, 0, 15, 0)
	now := aiT0
	if now2, noticed := tickUntilBattle(t, f.a, m.ID, now, 30); noticed {
		t.Fatal("a player at 110 units was noticed (radius 106)")
	} else {
		now = now2
	}
	f.hub.Move(f.ariaSession(t), world.Position{X: 106, Z: 0})
	if _, noticed := tickUntilBattle(t, f.a, m.ID, now, 16); !noticed {
		t.Fatalf("a player at exactly 106 units was not noticed within a scan period; state %v", stateOf(t, f.a, m.ID))
	}
}

// A dead player is no candidate (IsValidTarget 0x540de0 wants life state 1,
// asked inside the selector's PC branch and again by the 0x22 handler): dead
// at 10 units she is not noticed in 3 s; revived, she is within a scan
// period. The dead half is a control; the revived half is not.
func TestMonsterDoesNotNoticeADeadPlayer(t *testing.T) {
	battleForTest(t, true)
	deadStateForTest(t, true)
	aggroForTest(t, true)
	f := startBattleFixture(t, 35, 10, 0)
	if !f.hub.SetLifeState(f.aria, world.LifeAlive, world.LifeDead, aiT0) {
		t.Fatal("setup: could not mark Aria dead")
	}
	m := f.monsters.SpawnSpecies("jangan", standingMangyang, 0, 0, 0, 1000, 0, 15, 0)
	now := aiT0
	now2, noticed := tickUntilBattle(t, f.a, m.ID, now, 30)
	if noticed {
		t.Fatal("a dead player at 10 units was noticed")
	}
	now = now2
	if !f.hub.SetLifeState(f.aria, world.LifeDead, world.LifeAlive, now) {
		t.Fatal("setup: could not revive Aria")
	}
	if _, noticed := tickUntilBattle(t, f.a, m.ID, now, 16); !noticed {
		t.Fatalf("revived at 10 units she was not noticed within a scan period; state %v", stateOf(t, f.a, m.ID))
	}
}

// HOMING's blackout: a Mangyang running home ignores players for
// trunc(106 / 22 x 1000) = 4818 ms (a value derived from the detection
// stand-in), then notices them. Carried 300 units east, it runs home at 22
// past Aria at 150: she is inside 106 from about 2 s on and ignored through
// the tick at 4800 ms (the window is strict: elapsed > 4818), and noticed on
// the tick at 4900 ms. The first half is a control; the second is not.
func TestHomingMonsterNoticesNobodyInsideItsBlackout(t *testing.T) {
	battleForTest(t, true)
	deadStateForTest(t, true)
	aggroForTest(t, true)
	f := startBattleFixture(t, 36, 150, 0)
	m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 0, 0, 0, 1000, 0, 15, 0)
	f.monsters.SetMotion(m.ID, 300, 0, 300, 1)
	f.monsters.StepCells(1, nil, nil)
	f.monsters.StepCells(1, nil, nil)
	if got, _ := f.monsters.Get(m.ID); got.X != 300 || got.Moving {
		t.Fatalf("setup: the monster is at %g (moving %v), want standing at 300", got.X, got.Moving)
	}
	now := aiT0
	monsterAITick(now) // hatches, IDLE's roam check sends it home: enteredAt = aiT0
	if st := stateOf(t, f.a, m.ID); st != ai.StateHoming {
		t.Fatalf("state %v after the first tick, want HOMING", st)
	}
	f.a.mu.Lock()
	blackout := f.a.brains[m.ID].homingBlackoutMs
	f.a.mu.Unlock()
	if blackout != 4818 {
		t.Fatalf("the blackout is %d ms, want 4818 (trunc(106 / 22 x 1000))", blackout)
	}
	for i := 1; i <= 48; i++ { // the ticks at 100 .. 4800 ms
		now = now.Add(MonsterAITick)
		monsterAITick(now)
		cur, _ := f.monsters.Get(m.ID)
		if d := math.Hypot(cur.X-150, cur.Z); i >= 25 && d > 106 {
			t.Fatalf("setup: at %d ms the monster is %.1f from Aria, outside 106", i*100, d)
		}
		if st := stateOf(t, f.a, m.ID); st != ai.StateHoming {
			t.Fatalf("at %d ms the state is %v, want HOMING through the 4818 ms blackout", i*100, st)
		}
	}
	now = now.Add(MonsterAITick) // 4900 ms: past the window
	monsterAITick(now)
	if st := stateOf(t, f.a, m.ID); st != ai.StateBattle {
		t.Fatalf("at 4900 ms, past the blackout, the state is %v, want BATTLE", st)
	}
}

// --- The aggro link (round 553, rides -monster-battle) -----------------------

// linkStage is the aggro-link tests' stage: Aria at the origin (level 1, the
// fixture's) with `members - 1` party mates standing together where each test
// puts them, and Mangyangs (level 1; detection radius 6 + 100 = 106) at the
// spots given, the first of which is A, the one Aria strikes. The standard
// spots (standardSpots) are:
//
//	A (30, 0)     the struck one
//	B (30, 30)    30 from A
//	C (30, -50)   50 from A
//	D (-40, 0)    70 from A -- but 40 from ARIA, nearer to her than C is: the
//	              gather measures from the victim, and D tells that apart
//	E (150, 0)    120 from A: outside its radius
//	F (30, 130)   130 from A, outside its radius; 100 from B, inside B's --
//	              the no-cascade witness
//
// so a party of two within 1000 units links exactly B and C, and a party of
// three B, C and D.
type linkStage struct {
	f       *battleFixture
	seed    int64
	parties *party.Hub
	partyID uint32
	leader  party.Member
	mates   []int64
	ids     []int64 // the monsters, A first
}

var standardSpots = [][2]float64{{30, 0}, {30, 30}, {30, -50}, {-40, 0}, {150, 0}, {30, 130}}

// startLinkStage builds the stage; members 0 or 1 leaves Aria solo.
func startLinkStage(t *testing.T, seed int64, members int, mateX, mateZ float64, spots [][2]float64) *linkStage {
	t.Helper()
	f := startBattleFixture(t, seed, 0, 0)
	s := &linkStage{f: f, seed: seed}
	if members >= 2 {
		s.parties = party.NewHub()
		f.a.parties = s.parties
		s.leader = party.Member{Session: f.ariaSession(t), CharacterID: f.aria, Name: "Aria", Level: party.MinCreatorLevel}
		for i := 1; i < members; i++ {
			s.addMate(t, []string{"", "Bram", "Cass", "Dara"}[i], mateX, mateZ)
		}
	}
	for _, p := range spots {
		s.ids = append(s.ids, f.monsters.SpawnSpecies("jangan", chaseMangyang, p[0], 0, p[1], 1000, 0, 15, 0).ID)
	}
	return s
}

// addMate creates a level-1 character, stands it in jangan at (x, z) and
// joins it to Aria's party.
func (s *linkStage) addMate(t *testing.T, name string, x, z float64) {
	t.Helper()
	mate, err := s.f.chars.Create(context.Background(), 1, name)
	if err != nil {
		t.Fatalf("creating %s: %v", name, err)
	}
	sess := gateway.NewTestSession(uint64(91300 + 10*s.seed + int64(len(s.mates)+1)))
	s.f.hub.Enter(sess, mate.ID, name, 1, "jangan", world.Position{X: x, Z: z})
	m := party.Member{Session: sess, CharacterID: mate.ID, Name: name, Level: 1}
	if s.partyID == 0 {
		// The first mate forms the party with Aria (round 710: there is no
		// party of one), exp-shared as the aggro link needs.
		pt, err := s.parties.Form(s.leader, m, party.FlagExpShare)
		if err != nil {
			t.Fatalf("%s forming the party: %v", name, err)
		}
		s.partyID = pt.ID
	} else if _, err := s.parties.Add(s.partyID, m); err != nil {
		t.Fatalf("%s joining: %v", name, err)
	}
	s.mates = append(s.mates, mate.ID)
}

// strike is every link test's first two ticks: the brains hatch into IDLE,
// Aria's blow lands on A, and the next tick drains it. It returns the clock
// after that tick.
func (s *linkStage) strike(t *testing.T) time.Time {
	t.Helper()
	now := aiT0
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	for i, id := range s.ids {
		if st := stateOf(t, s.f.a, id); st != ai.StateIdle {
			t.Fatalf("setup: monster %c is %v after the first tick, want IDLE", 'A'+i, st)
		}
	}
	noteStruck(s.f.monsters, s.ids[0], s.f.aria)
	s.f.rec.reset()
	monsterAITick(now)
	return now.Add(MonsterAITick)
}

// battling names the stage's monsters in BATTLE, as letters in spot order.
func (s *linkStage) battling(t *testing.T) string {
	t.Helper()
	out := ""
	for i, id := range s.ids {
		if stateOf(t, s.f.a, id) == ai.StateBattle {
			out += string(rune('A' + i))
		}
	}
	return out
}

func (s *linkStage) targetOf(t *testing.T, id int64) int64 {
	t.Helper()
	s.f.a.mu.Lock()
	defer s.f.a.mu.Unlock()
	return s.f.a.brains[id].target
}

// levelAria sets Aria's level the way the level-up path does (round 555): the
// row through SetLeveling and the world entity's cache through SetLevel.
func (s *linkStage) levelAria(t *testing.T, level int) {
	t.Helper()
	if err := s.f.chars.SetLeveling(context.Background(), s.f.aria, level, 0, 0, 0, 0); err != nil {
		t.Fatalf("setting Aria's level: %v", err)
	}
	if !s.f.hub.SetLevel(s.f.aria, level) {
		t.Fatal("Aria is not in the world")
	}
}

// countingStore counts the GetByID reads made through a character store.
type countingStore struct {
	character.Store
	reads atomic.Int32
}

func (s *countingStore) GetByID(ctx context.Context, id int64) (*character.Character, error) {
	s.reads.Add(1)
	return s.Store.GetByID(ctx, id)
}

// NO CHARACTER-STORE READ ON THE TICK OR ON THE SWING (round 555): the
// attacker's level for the gather's radius and the target's level for the
// blow are the world entity's cached level, not a GetByID. A level-5 Aria (the
// row and the entity both, as the level-up path writes them) in a party of
// two strikes A: the radius is 84, so B at 84 links and C at 85 does not --
// the level was read -- and the character store saw NO GetByID through the
// link tick, the chase and A's first blow on her. Until this round linkAggro
// read the row under a.mu on the tick (one slow store read stalled every
// monster's tick) and runStrike read it again on every swing.
func TestAggroLinkAndSwingReadNoCharacterRow(t *testing.T) {
	battleForTest(t, true)
	spots := [][2]float64{{30, 0}, {114, 0}, {30, 85}} // B 84 from A, C 85
	s := startLinkStage(t, 49, 2, 0, 500, spots)
	s.levelAria(t, 5)
	// The swap takes a.mu: deps is the tick's, read under it (no strike worker
	// exists yet at this point, but a -race run should not have to know that).
	s.f.a.mu.Lock()
	counting := &countingStore{Store: s.f.a.deps.chars}
	s.f.a.deps.chars = counting
	s.f.a.mu.Unlock()
	now := s.strike(t)
	if got := s.battling(t); got != "AB" {
		t.Fatalf("level-5 Aria: in BATTLE %q, want AB (the entity's level 5 gave the radius 84)", got)
	}
	if n := counting.reads.Load(); n != 0 {
		t.Fatalf("the link tick made %d GetByID read(s) on the character store, want none: the level is the entity's", n)
	}
	for i := 0; i < 30 && len(s.f.rec.strikesOf(s.ids[0])) == 0; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
		time.Sleep(2 * time.Millisecond)
	}
	if !waitFor(t, 2*time.Second, func() bool { return len(s.f.rec.strikesOf(s.ids[0])) >= 1 }) {
		t.Fatal("A never swung at Aria within 3 s of AI time")
	}
	if n := counting.reads.Load(); n != 0 {
		t.Fatalf("the chase and the swing made %d GetByID read(s) on the character store, want none: the target's level is the entity's", n)
	}
}

// The link's BATTLE branch (round 553's untested case, pinned in round 555): a
// gathered neighbour already fighting keeps its own target under rule 0 and
// still uses up one of the n places. A solo Cass -- no party, so her blow links
// nothing -- strikes B first; then Aria (a party of two) strikes A: the two
// nearest to A are B and C, so B is one of the two places and C is linked,
// while D, next in line, stays idle. B's target is still Cass, not Aria.
func TestALinkedNeighbourAlreadyInBattleKeepsItsTargetAndUsesAPlace(t *testing.T) {
	battleForTest(t, true)
	s := startLinkStage(t, 50, 2, 0, 500, standardSpots)
	cass, err := s.f.chars.Create(context.Background(), 1, "Cass")
	if err != nil {
		t.Fatalf("creating Cass: %v", err)
	}
	s.f.hub.Enter(gateway.NewTestSession(91350), cass.ID, "Cass", 1, "jangan", world.Position{X: 30, Z: 60})
	now := aiT0
	monsterAITick(now) // the brains hatch into IDLE
	now = now.Add(MonsterAITick)
	noteStruck(s.f.monsters, s.ids[1], cass.ID)
	monsterAITick(now) // B fights Cass; solo, so nothing links
	now = now.Add(MonsterAITick)
	if got := s.battling(t); got != "B" {
		t.Fatalf("after the solo blow on B: in BATTLE %q, want B alone", got)
	}
	noteStruck(s.f.monsters, s.ids[0], s.f.aria)
	monsterAITick(now) // Aria's party blow on A: B (fighting) and C are the two places
	if got := s.battling(t); got != "ABC" {
		t.Fatalf("after the party blow on A: in BATTLE %q, want ABC (B keeps its place, C linked, D idle)", got)
	}
	if tgt := s.targetOf(t, s.ids[1]); tgt != cass.ID {
		t.Errorf("B's target is %d, want Cass %d kept under rule 0 (Aria is %d)", tgt, cass.ID, s.f.aria)
	}
	if tgt := s.targetOf(t, s.ids[2]); tgt != s.f.aria {
		t.Errorf("C's target is %d, want Aria %d", tgt, s.f.aria)
	}
}

// The link's DEAD branch (round 553's other untested case, pinned in round
// 555): a gathered neighbour in the terminal state is passed over -- its brain
// untouched, no target set, no state change attempted -- and still uses up its
// place among the n, as the engine forwards command 0xe to the first n gathered
// whatever each one's state. B's machine is put in DEAD by hand (the runtime
// never enters it: a killed monster's brain is dropped), Aria's party blow on
// A links C alone, and D stays idle.
func TestADeadNeighbourIsSkippedButUsesAPlace(t *testing.T) {
	battleForTest(t, true)
	s := startLinkStage(t, 51, 2, 0, 500, standardSpots)
	now := aiT0
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	s.f.a.mu.Lock()
	if _, err := s.f.a.brains[s.ids[1]].machine.ChangeState(ai.StateDead); err != nil {
		s.f.a.mu.Unlock()
		t.Fatalf("putting B in DEAD: %v", err)
	}
	s.f.a.mu.Unlock()
	if st := stateOf(t, s.f.a, s.ids[1]); st != ai.StateDead {
		t.Fatalf("B is %v, want DEAD", st)
	}
	noteStruck(s.f.monsters, s.ids[0], s.f.aria)
	monsterAITick(now)
	if got := s.battling(t); got != "AC" {
		t.Fatalf("after the party blow on A with B dead: in BATTLE %q, want AC (B's place used, C linked, D idle)", got)
	}
	if st := stateOf(t, s.f.a, s.ids[1]); st != ai.StateDead {
		t.Errorf("B is %v after the link, want still DEAD", st)
	}
	if tgt := s.targetOf(t, s.ids[1]); tgt != 0 {
		t.Errorf("the dead B's target is %d, want 0: the terminal branch touches nothing", tgt)
	}
}

// THE RED (round 553): Aria and Bram are a party of two, Bram 500 units off.
// Aria's first blow on the idle Mangyang A pulls in exactly B and C -- the two
// nearest OTHER monsters to A inside its radius (106: level 1 on level 1) --
// into BATTLE against Aria on the tick that drains the blow, and B's own push
// that tick is the chase toward her (mode 1 at the run speed). D (nearer to
// Aria than C, farther from A), E (outside the radius) and F (inside B's
// radius, outside A's) stay idle, F still two ticks later: a link never
// cascades. Before this round a blow engaged the struck monster alone.
func TestPartyHitLinksTheTwoNearestNeighbours(t *testing.T) {
	battleForTest(t, true)
	s := startLinkStage(t, 41, 2, 0, 500, standardSpots)
	now := s.strike(t)
	if got := s.battling(t); got != "ABC" {
		t.Fatalf("in BATTLE after the blow: %q, want exactly A (struck), B and C (linked)", got)
	}
	for _, i := range []int{1, 2} {
		if tgt := s.targetOf(t, s.ids[i]); tgt != s.f.aria {
			t.Errorf("%c's target is %d, want Aria %d", 'A'+i, tgt, s.f.aria)
		}
	}
	moves := s.f.rec.of(s.ids[1])
	if len(moves) != 1 || moves[0].Mode != 1 || moves[0].Speed != 22 {
		t.Fatalf("B's pushes on the link tick: %+v, want one chase leg, mode 1 at the run speed 22", moves)
	}
	if d := math.Hypot(float64(moves[0].DestX), float64(moves[0].DestZ)); math.Abs(d-10) > 1.5 {
		t.Errorf("B's chase leg ends %.1f from Aria, want about 10 (the stop distance)", d)
	}
	for i := 0; i < 2; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	if got := s.battling(t); got != "ABC" {
		t.Fatalf("in BATTLE two ticks on: %q, want still exactly ABC (F is inside B's radius: no cascade)", got)
	}
}

// A party of three within range links three: B, C and D -- the three nearest
// to A, in that order, so D joins and E (outside the radius) does not.
func TestPartyOfThreeLinksThree(t *testing.T) {
	battleForTest(t, true)
	s := startLinkStage(t, 42, 3, 0, 500, standardSpots)
	s.strike(t)
	if got := s.battling(t); got != "ABCD" {
		t.Fatalf("in BATTLE after the blow: %q, want ABCD", got)
	}
}

// CONTROL: a solo Aria's blow engages A alone -- with no party the routine
// returns before gathering.
func TestSoloHitLinksNothing(t *testing.T) {
	battleForTest(t, true)
	s := startLinkStage(t, 43, 0, 0, 0, standardSpots)
	s.strike(t)
	if got := s.battling(t); got != "A" {
		t.Fatalf("in BATTLE after a solo blow: %q, want A alone", got)
	}
}

// CONTROL: a second blow on A, already in BATTLE, links nothing more. Aria
// and Bram's first blow links B and C; then Cass joins the party beside Bram,
// so a link would now reach three, and D -- idle, 70 from A, inside its
// radius -- would be the third. It is not: BATTLE's slot 6 has no link. Nor
// does Bram's own first blow on the battling A link it.
func TestSecondHitOnABattlingMonsterLinksNothing(t *testing.T) {
	battleForTest(t, true)
	s := startLinkStage(t, 44, 2, 0, 500, standardSpots)
	now := s.strike(t)
	if got := s.battling(t); got != "ABC" {
		t.Fatalf("in BATTLE after the first blow: %q, want ABC", got)
	}
	s.addMate(t, "Cass", 0, 500)
	noteStruck(s.f.monsters, s.ids[0], s.f.aria)
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	if got := s.battling(t); got != "ABC" {
		t.Fatalf("in BATTLE after a second blow on the battling A: %q, want still ABC (three members near, D idle inside the radius, and no link)", got)
	}
	noteStruck(s.f.monsters, s.ids[0], s.mates[0])
	monsterAITick(now)
	if got := s.battling(t); got != "ABC" {
		t.Fatalf("in BATTLE after Bram's blow on the battling A: %q, want still ABC", got)
	}
}

// The member count's edge, the engine's `fcomp; test ah,0x41; jp`: a mate at
// exactly 1000 units counts (two links, B and C), one at 1001 does not (one
// link, B alone).
func TestPartyMateCountsAtAThousandUnitsNotBeyond(t *testing.T) {
	battleForTest(t, true)
	t.Run("1001", func(t *testing.T) {
		s := startLinkStage(t, 45, 2, 0, 1001, standardSpots)
		s.strike(t)
		if got := s.battling(t); got != "AB" {
			t.Fatalf("Bram at 1001: in BATTLE %q, want AB (one member near: one link)", got)
		}
	})
	t.Run("1000", func(t *testing.T) {
		s := startLinkStage(t, 46, 2, 0, 1000, standardSpots)
		s.strike(t)
		if got := s.battling(t); got != "ABC" {
			t.Fatalf("Bram at exactly 1000: in BATTLE %q, want ABC (two members near: two links)", got)
		}
	})
}

// The gather's radius scales by the level gap and chops: a level-5 Aria on a
// level-1 Mangyang gets 106 x 0.8 = 84.8 -> 84. With two members near, the
// neighbour at exactly 84 links and the one at 85 does not; unscaled, both
// would (106) and the party's two links would take both.
func TestAggroLinkRadiusScalesByTheLevelGap(t *testing.T) {
	battleForTest(t, true)
	spots := [][2]float64{{30, 0}, {114, 0}, {30, 85}} // B 84 from A, C 85
	s := startLinkStage(t, 47, 2, 0, 500, spots)
	s.levelAria(t, 5)
	s.strike(t)
	if got := s.battling(t); got != "AB" {
		t.Fatalf("level-5 Aria: in BATTLE %q, want AB (radius 84: B at 84 in, C at 85 out)", got)
	}
}

// CONTROL, the default: with -monster-battle off the same party blow only
// holds A where it stands; nothing is linked, nothing chases.
func TestAggroLinkNeedsTheBattleOn(t *testing.T) {
	battleForTest(t, false)
	s := startLinkStage(t, 48, 2, 0, 500, standardSpots)
	s.strike(t)
	if got := s.battling(t); got != "A" {
		t.Fatalf("battle off: in BATTLE %q, want A alone (the interim hold)", got)
	}
	if n := len(s.f.rec.moves); n != 0 {
		t.Fatalf("battle off: %d move(s) pushed after the blow, want none", n)
	}
}

// The two-skill species of round 554, exactly as cmd/server's roster carries
// them (characterdata cols 83/84 -> skilldata cols 14/21/66 and the 'att'
// block, read on the RE box 2026-09-25): Yeoha's ATTACK01 176 (range 7,
// 67-79) and ATTACK03 177 (range 100, 94-105), both chance 100 and ReuseDelay
// 2500; Water Ghost's ATTACK01 168 (range 16, 47-54, chance 100, 2000 ms) and
// ATTACK02 169 (range 16, att 9,0,0,0,100 -- no damage --, chance 10, 4000 ms).
var testYeoha = combat.Species{Name: "Yeoha", CodeName: "MOB_CH_YEOHA", RefObjID: 1943, Level: 10, BCRadius: 11, WalkSpeed: 9, RunSpeed: 20,
	AttackReuseMs: 2500, AttackRange: 7, AttackMin: 67, AttackMax: 79,
	Skills: []combat.MonsterSkill{{ID: 176, ReuseMs: 2500, Range: 7, AttMin: 67, AttMax: 79, Chance: 100}, {ID: 177, ReuseMs: 2500, Range: 100, AttMin: 94, AttMax: 105, Chance: 100}}}

var testWaterGhost = combat.Species{Name: "Water Ghost", CodeName: "MOB_CH_WATERGHOST", RefObjID: 1939, Level: 7, BCRadius: 6, WalkSpeed: 15, RunSpeed: 55,
	AttackReuseMs: 2000, AttackRange: 16, AttackMin: 47, AttackMax: 54,
	Skills: []combat.MonsterSkill{{ID: 168, ReuseMs: 2000, Range: 16, AttMin: 47, AttMax: 54, Chance: 100}, {ID: 169, ReuseMs: 4000, Range: 16, AttMin: 0, AttMax: 0, Chance: 10}}}

// armedSkillOf is the skill monster id's brain last armed (armSkill).
func armedSkillOf(t *testing.T, a *monsterAI, id int64) (combat.MonsterSkill, bool) {
	t.Helper()
	a.mu.Lock()
	defer a.mu.Unlock()
	b := a.brains[id]
	if b == nil {
		t.Fatalf("monster %d has no brain", id)
	}
	return b.armed, b.hasArmed
}

// THE RED (round 554): a Yeoha in BATTLE against a player 60 units away, its
// dice (seed 2) drawing MSKILL_CH_YEOHA_ATTACK03 -- at 60 units it weighs 100
// + trunc((100 + 11 + 4 - 60) x 5 / 10) = 127 against ATTACK01's 100. Its
// reach is 100 + 11 + 4 = 115, so the Yeoha is in reach where it stands: no
// chase leg is pushed, and its first blow lands at once from 60 units, for at
// least ATTACK03's 94 (Aria is unarmoured: no mitigation, no shield to block;
// the level term and a critical only raise it). Before this round every
// species swung its col-83 skill alone, and a Yeoha at 60 units ran to its
// range-7 band (stop 22) before it could land anything.
func TestYeohaDrawsItsLongSkillAndSwingsFromAfar(t *testing.T) {
	battleForTest(t, true)
	f := startBattleFixture(t, 2, 0, 0)
	m := f.monsters.SpawnSpecies("jangan", testYeoha, 60, 0, 0, 1000, 0, 15, 0)
	now := aiT0
	monsterAITick(now) // the brain hatches into IDLE
	now = now.Add(MonsterAITick)
	noteStruck(f.monsters, m.ID, f.aria)
	f.rec.reset()

	monsterAITick(now) // drains the blow: BATTLE, the draw, and the swing
	if st := stateOf(t, f.a, m.ID); st != ai.StateBattle {
		t.Fatalf("state %v after the blow, want BATTLE", st)
	}
	armed, _ := armedSkillOf(t, f.a, m.ID)
	if armed.ID != 177 {
		t.Fatalf("the Yeoha armed skill %d, want ATTACK03 177 under seed 2 (the draw's dice; re-seed if the rng's consumers change)", armed.ID)
	}
	if moves := f.rec.of(m.ID); len(moves) != 0 {
		t.Fatalf("a Yeoha that drew its 100-unit skill pushed %d move(s) %+v from 60 units, want no chase: it is in reach where it stands", len(moves), moves)
	}
	if !waitFor(t, 2*time.Second, func() bool { return len(f.rec.strikesOf(m.ID)) == 1 }) {
		t.Fatalf("no OpMonsterAttacked within 2 s from 60 units (%d pushed): the swing did not use ATTACK03's range", len(f.rec.strikesOf(m.ID)))
	}
	got := f.rec.strikesOf(m.ID)[0]
	if got.TargetCharacterID != f.aria || got.Damage < 94 || got.Blocked {
		t.Errorf("the blow %+v, want ATTACK03's on Aria: at least its 94, unblocked", got)
	}
	if cur, _ := f.monsters.Get(m.ID); cur.X != 60 || cur.Moving {
		t.Errorf("the Yeoha moved: %+v, want standing at 60", cur)
	}
	if c, _ := f.chars.GetByID(context.Background(), f.aria); c.HP != character.StartingMaxHP-int(got.Damage) && c.HP != 0 {
		t.Errorf("Aria's HP after the blow = %d, want %d less than %d (or 0, dead)", c.HP, got.Damage, character.StartingMaxHP)
	}
}

// The other branch of the same draw (seed 1: ATTACK01 176): the band follows
// the ARMED skill, so this Yeoha chases to the range-7 band -- the leg to
// round(stop) at the run speed 20 -- pushes no blow on the way, and lands
// ATTACK01 (at least its 67) once int(dist) is within that band's reach.
func TestYeohaDrawsItsShortSkillAndChasesToItsBand(t *testing.T) {
	battleForTest(t, true)
	f := startBattleFixture(t, 1, 0, 0)
	m := f.monsters.SpawnSpecies("jangan", testYeoha, 60, 0, 0, 1000, 0, 15, 0)
	now := aiT0
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	noteStruck(f.monsters, m.ID, f.aria)
	f.rec.reset()

	monsterAITick(now)
	now = now.Add(MonsterAITick)
	armed, _ := armedSkillOf(t, f.a, m.ID)
	if armed.ID != 176 {
		t.Fatalf("the Yeoha armed skill %d, want ATTACK01 176 under seed 1 (the draw's dice)", armed.ID)
	}
	stop, reach := combat.ApproachBand(11, combat.PlayerBCRadius, 7)
	moves := f.rec.of(m.ID)
	if len(moves) != 1 {
		t.Fatalf("the tick after the blow pushed %d move(s) %+v, want exactly the chase leg to ATTACK01's band", len(moves), moves)
	}
	if leg := moves[0]; leg.Mode != 1 || leg.Speed != 20 || math.Abs(float64(leg.DestX)-math.Round(stop)) > 1e-3 || math.Abs(float64(leg.DestZ)) > 1e-3 {
		t.Errorf("the chase leg %+v: want mode 1 at 20 to (%g, 0), round(stop) for range 7", leg, math.Round(stop))
	}
	if n := len(f.rec.strikesOf(m.ID)); n != 0 {
		t.Fatalf("%d blow(s) pushed from 60 units with the range-7 skill armed", n)
	}
	inReach := false
	for i := 0; i < 40 && !inReach; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
		cur, _ := f.monsters.Get(m.ID)
		inReach = combat.InReach(cur.X, reach)
		if !inReach {
			if n := len(f.rec.strikesOf(m.ID)); n != 0 {
				t.Fatalf("a blow was pushed with the Yeoha %.1f from the player, outside ATTACK01's band", cur.X)
			}
		}
	}
	if !inReach {
		t.Fatal("the chase never brought the Yeoha into its range-7 band in 4 s")
	}
	if !waitFor(t, 2*time.Second, func() bool { return len(f.rec.strikesOf(m.ID)) == 1 }) {
		t.Fatalf("no OpMonsterAttacked within 2 s of reaching the band (%d pushed)", len(f.rec.strikesOf(m.ID)))
	}
	if got := f.rec.strikesOf(m.ID)[0]; got.Damage < 67 || got.Blocked {
		t.Errorf("the blow %+v, want ATTACK01's: at least its 67, unblocked", got)
	}
}

// The zero-damage skill (round 554's hazard, made explicit): a Water Ghost in
// its band whose dice (seed 21) draw MSKILL_CH_WATERGHOST_ATTACK02 169 --
// att 9,0,0,0,100 -- lands a blow of 0: pushed, unblocked, Aria's HP untouched.
// Its flat disclosed Attack is 15 here, so a swing that fell through
// monsterBlow's "no range" branch would land 15 or more. The cooldown is then
// 169's own ReuseDelay, 4000 ms: no second blow on the 39th tick after it,
// one on the 40th (ATTACK01's 2000 would have swung on the 20th).
func TestWaterGhostZeroDamageSkillLandsNothing(t *testing.T) {
	battleForTest(t, true)
	f := startBattleFixture(t, 21, 0, 0)
	m := f.monsters.SpawnSpecies("jangan", testWaterGhost, 20, 0, 0, 1000, 0, 15, 0)
	now := aiT0
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	noteStruck(f.monsters, m.ID, f.aria)
	f.rec.reset()

	monsterAITick(now) // BATTLE, the draw, and -- in the band at 20 -- the swing
	armed, _ := armedSkillOf(t, f.a, m.ID)
	if armed.ID != 169 {
		t.Fatalf("the Water Ghost armed skill %d, want ATTACK02 169 under seed 21 (the draw's dice)", armed.ID)
	}
	if !waitFor(t, 2*time.Second, func() bool { return len(f.rec.strikesOf(m.ID)) == 1 }) {
		t.Fatalf("no OpMonsterAttacked within 2 s (%d pushed)", len(f.rec.strikesOf(m.ID)))
	}
	got := f.rec.strikesOf(m.ID)[0]
	want := MonsterAttacked{MonsterID: m.ID, TargetCharacterID: f.aria, Damage: 0, TargetHP: int32(character.StartingMaxHP)}
	if got != want {
		t.Fatalf("the zero-damage skill's blow %+v, want %+v (nothing landed, nothing blocked)", got, want)
	}
	if c, _ := f.chars.GetByID(context.Background(), f.aria); c.HP != character.StartingMaxHP {
		t.Errorf("Aria's HP after the zero-damage swing = %d, want %d untouched", c.HP, character.StartingMaxHP)
	}
	for i := 0; i < 39; i++ {
		now = now.Add(MonsterAITick)
		monsterAITick(now)
	}
	time.Sleep(20 * time.Millisecond)
	if n := len(f.rec.strikesOf(m.ID)); n != 1 {
		t.Fatalf("%d blows 3.9 s after the ATTACK02 swing, want none before its 4000 ms ReuseDelay", n)
	}
	now = now.Add(MonsterAITick)
	monsterAITick(now)
	if !waitFor(t, 2*time.Second, func() bool { return len(f.rec.strikesOf(m.ID)) == 2 }) {
		t.Fatalf("no second blow on the 40th tick (4000 ms) after the ATTACK02 swing: %d pushed", len(f.rec.strikesOf(m.ID)))
	}
}

// monsterStrike by skill (round 554), directly: the drawn skill's own 'att'
// block is what the blow rolls -- 169's zero block lands nothing, 168's
// 47-54 lands at least 47 -- and no skill named (performAttack's counter, a
// species without a list) is the monster's primary range, as before. The
// CONTROL of the hazard: a monster with no range and no skill still deals its
// flat disclosed Attack, which is the case that branch exists for.
func TestMonsterStrikeRollsTheNamedSkill(t *testing.T) {
	f := startBattleFixture(t, 44, 0, 0)
	m := f.monsters.SpawnSpecies("jangan", testWaterGhost, 20, 0, 0, 1000, 0, 15, 0)
	cur, _ := f.monsters.Get(m.ID)
	ctx := context.Background()
	out, err := monsterStrike(ctx, f.a.deps, cur, cur.Skills[1], f.aria, 1)
	if err != nil || out.damage != 0 || out.blocked || out.critical || out.died || out.hp != character.StartingMaxHP {
		t.Fatalf("a swing of 169 (att max 0) = %+v (err %v), want 0 damage at HP %d, nothing else", out, err, character.StartingMaxHP)
	}
	if c, _ := f.chars.GetByID(ctx, f.aria); c.HP != character.StartingMaxHP {
		t.Fatalf("Aria's HP after the zero swing = %d, want %d", c.HP, character.StartingMaxHP)
	}
	out, err = monsterStrike(ctx, f.a.deps, cur, cur.Skills[0], f.aria, 1)
	if err != nil || out.damage < 47 {
		t.Fatalf("a swing of 168 (47-54) = %+v (err %v), want at least 47", out, err)
	}
	f.chars.ResetHP(ctx, f.aria)
	out, err = monsterStrike(ctx, f.a.deps, cur, combat.MonsterSkill{}, f.aria, 1)
	if err != nil || out.damage < 47 {
		t.Fatalf("a swing with no skill named = %+v (err %v), want the primary range's at least 47", out, err)
	}
	f.chars.ResetHP(ctx, f.aria)
	bare := cur
	bare.AttackMin, bare.AttackMax, bare.Skills = 0, 0, nil
	out, err = monsterStrike(ctx, f.a.deps, bare, combat.MonsterSkill{}, f.aria, 1)
	if err != nil || out.damage < 15 {
		t.Fatalf("a swing of a monster with no range at all = %+v (err %v), want its flat Attack, at least 15", out, err)
	}
}

// CONTROL, the default: with -monster-battle off a struck Yeoha is in the
// interim hold, exactly as before this round -- it stands where it is through
// the hold's ticks with no skill drawn or armed, and once the release lets
// IDLE have it, it may wander but never runs to the player's band or swings.
// The counter it would answer with is performAttack's, which rolls the
// primary range (TestMonsterStrikeRollsTheNamedSkill's no-skill case).
func TestBattleOffDrawsNoSkill(t *testing.T) {
	battleForTest(t, false)
	f := startBattleFixture(t, 2, 0, 0)
	m := f.monsters.SpawnSpecies("jangan", testYeoha, 60, 0, 0, 1000, 0, 15, 0)
	now := aiT0
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	noteStruck(f.monsters, m.ID, f.aria)
	f.rec.reset()
	for i := 0; i < 2; i++ { // the entry tick and one tick into the hold
		monsterAITick(now)
		now = now.Add(MonsterAITick)
		if st := stateOf(t, f.a, m.ID); st != ai.StateBattle {
			t.Fatalf("state %v %d tick(s) after the blow, want BATTLE (the hold)", st, i+1)
		}
		if _, has := armedSkillOf(t, f.a, m.ID); has {
			t.Fatal("a skill was armed with the battle off: the draw is BATTLE's, under the flag")
		}
		if moves := f.rec.of(m.ID); len(moves) != 0 {
			t.Fatalf("with the battle off the hold pushed %+v, want nothing", moves)
		}
		if cur, _ := f.monsters.Get(m.ID); cur.X != 60 || cur.Moving {
			t.Fatalf("the held Yeoha is at %g (moving %v), want standing at 60", cur.X, cur.Moving)
		}
	}
	stop, _ := combat.ApproachBand(11, combat.PlayerBCRadius, 7)
	for i := 0; i < 50; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	time.Sleep(50 * time.Millisecond)
	if n := len(f.rec.strikesOf(m.ID)); n != 0 {
		t.Fatalf("with the battle off the Yeoha pushed %d blow(s) of its own", n)
	}
	if _, has := armedSkillOf(t, f.a, m.ID); has {
		t.Error("a skill was armed with the battle off")
	}
	for _, mv := range f.rec.of(m.ID) {
		if mv.Mode == 1 && math.Hypot(float64(mv.DestX), float64(mv.DestZ)) <= math.Round(stop)+combat.ReachSlack {
			t.Errorf("with the battle off a run to the player's band was pushed: %+v", mv)
		}
	}
}

// THE ARMED PICK IS CLEARED WITH BATTLE (round 555): CAIState_BATTLE::OnLeave
// calls ResetThreat, which zeroes the selector's +0x44, so every BATTLE entry
// draws its skill afresh. Seed 1's Yeoha arms its range-7 ATTACK01 at 60 units
// and starts its chase; Aria leaves the world before it arrives, the next tick
// takes the 0x23 exit, and the pick is gone with it. She re-enters and strikes
// again: a second draw is made (a second `arms skill` trace line) and a pick
// is armed again. Until this round the unfired 176 survived the exit and the
// second fight swung it with no draw.
func TestBattleExitClearsTheArmedPick(t *testing.T) {
	battleForTest(t, true)
	f := startBattleFixture(t, 1, 0, 0)
	var log lockedBuffer
	f.a.logger = slog.New(slog.NewTextHandler(&log, nil))
	f.a.trace = true
	m := f.monsters.SpawnSpecies("jangan", testYeoha, 60, 0, 0, 1000, 0, 15, 0)
	now := aiT0
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	noteStruck(f.monsters, m.ID, f.aria)
	monsterAITick(now) // BATTLE: the draw (176 under seed 1) and the chase leg
	now = now.Add(MonsterAITick)
	if armed, has := armedSkillOf(t, f.a, m.ID); !has || armed.ID != 176 {
		t.Fatalf("armed %+v (has %v) after the blow, want ATTACK01 176 under seed 1 (the draw's dice)", armed, has)
	}
	if n := strings.Count(log.String(), "arms skill"); n != 1 {
		t.Fatalf("%d `arms skill` trace line(s) after the first fight's entry, want 1", n)
	}
	sess := f.ariaSession(t)
	if _, _, ok := f.hub.Leave(sess); !ok {
		t.Fatal("Aria could not leave the world")
	}
	monsterAITick(now) // the target is gone: the 0x23 exit, and OnLeave's clear
	now = now.Add(MonsterAITick)
	if st := stateOf(t, f.a, m.ID); st != ai.StateIdle {
		t.Fatalf("state %v after Aria left, want IDLE (the 0x23 exit)", st)
	}
	if armed, has := armedSkillOf(t, f.a, m.ID); has {
		t.Fatalf("the pick %+v survived the BATTLE exit; ResetThreat at BATTLE::OnLeave clears the selector's +0x44", armed)
	}
	f.hub.Enter(sess, f.aria, "Aria", 1, "jangan", world.Position{})
	noteStruck(f.monsters, m.ID, f.aria)
	// The second fight: a fresh draw on its entry tick. Whether the pick is
	// still armed after that tick depends on the dice -- IDLE never stopped
	// the chase leg, so from where the Yeoha now stands a drawn 177 is in
	// reach and fires (clearing the pick) on the same tick -- so the draw
	// itself is the evidence: its trace line.
	monsterAITick(now)
	if st := stateOf(t, f.a, m.ID); st != ai.StateBattle {
		t.Fatalf("state %v after the second blow, want BATTLE", st)
	}
	if n := strings.Count(log.String(), "arms skill"); n != 2 {
		t.Fatalf("%d `arms skill` trace line(s) over two fights, want 2: one draw per BATTLE entry", n)
	}
}
