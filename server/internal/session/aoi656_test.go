package session

import (
	"errors"
	"math/rand"
	"net"
	"sort"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// Round 656: the monsters' area of interest (aoi.go). A cell k spans world
// [1920k - 960, 1920k + 960) on each axis, so cellX(k) is a point well
// inside it.
func cellX(k int) float64 { return float64(k) * 1920 }

func spawnAt(t *testing.T, monsters *combat.Hub, zone string, x, z float64) int64 {
	t.Helper()
	return monsters.SpawnSpecies(zone, testMangyang, x, 0, z, 30, 1, 1, 1).ID
}

func installAOIForTest(t *testing.T, hub *world.Hub, monsters *combat.Hub) *monsterAOI {
	t.Helper()
	v := newMonsterAOI(hub, monsters, nil)
	monsterAOIRuntime.Store(v)
	t.Cleanup(func() { monsterAOIRuntime.Store(nil) })
	return v
}

func idsOf(snaps []MonsterSnapshot) []int64 {
	out := make([]int64, 0, len(snaps))
	for _, s := range snaps {
		out = append(out, s.ID)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

func sameIDs(a, b []int64) bool {
	if len(a) != len(b) {
		return false
	}
	a = append([]int64(nil), a...)
	b = append([]int64(nil), b...)
	sort.Slice(a, func(i, j int) bool { return a[i] < a[j] })
	sort.Slice(b, func(i, j int) bool { return b[i] < b[j] })
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// quiet reads frames until none arrives for d, returning them.
func (c *listClient) quiet(t *testing.T, d time.Duration) []*proto.Packet {
	t.Helper()
	var out []*proto.Packet
	for {
		c.conn.SetReadDeadline(time.Now().Add(d))
		p, err := proto.Read(c.r, nil, nil)
		if err != nil {
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				return out
			}
			t.Fatalf("reading: %v", err)
		}
		out = append(out, p)
	}
}

// aoiFrames sorts frames into the ids left, the ids entered (OpMonsterSpawned)
// and the legs (OpMonsterMoved), in arrival order.
func aoiFrames(t *testing.T, frames []*proto.Packet) (left, entered []int64, legs []MonsterMoved) {
	t.Helper()
	for _, p := range frames {
		switch p.Opcode {
		case OpMonsterLeft:
			l, err := DecodeMonsterLeft(p.Data)
			if err != nil {
				t.Fatal(err)
			}
			left = append(left, l.IDs...)
		case OpMonsterSpawned:
			s, err := DecodeMonsterSpawned(p.Data)
			if err != nil {
				t.Fatal(err)
			}
			entered = append(entered, s.Monster.ID)
		case OpMonsterMoved:
			m, err := DecodeMonsterMoved(p.Data)
			if err != nil {
				t.Fatal(err)
			}
			legs = append(legs, *m)
		default:
			t.Errorf("unexpected opcode %#04x", p.Opcode)
		}
	}
	return left, entered, legs
}

// The list is the window: the monsters of the 5x5 cells around the player,
// in its zone -- not the one two cells out, nor another zone's.
func TestMonsterListIsTheAreaOfInterest(t *testing.T) {
	monsters := combat.NewHub()
	here := spawnAt(t, monsters, "jangan", 10, 10)
	edgeE := spawnAt(t, monsters, "jangan", cellX(2)+900, 0) // cell (2, 0), 4,740 away
	edgeS := spawnAt(t, monsters, "jangan", 0, cellX(-2))    // cell (0, -2)
	spawnAt(t, monsters, "jangan", cellX(3)-900, 0)          // cell (3, 0): 4,860 away, out
	spawnAt(t, monsters, "jangan", cellX(1), cellX(-3))      // cell (1, -3): out
	spawnAt(t, monsters, "donwhang", 0, 0)                   // another bucket
	r := newListRig(t, monsters)
	c := r.join(t, 1, 0, 0)
	got, _ := r.list(t, c, 3)
	if want := []int64{here, edgeE, edgeS}; !sameIDs(idsOf(got), want) {
		t.Fatalf("listed %v, want the window's %v", idsOf(got), want)
	}
	for _, extra := range c.quiet(t, 150*time.Millisecond) {
		t.Errorf("unexpected frame after the list: %#04x", extra.Opcode)
	}
}

// A player walking over a region line is sent the difference: the monsters of
// the column of cells its window gained, each as an OpMonsterSpawned (and its
// leg, when it walks), and an OpMonsterLeft for those of the column it lost.
// Monsters in both windows are not mentioned. Walking back reverses it.
func TestAOIEnterLeaveAsThePlayerMoves(t *testing.T) {
	monsters := combat.NewHub()
	west := spawnAt(t, monsters, "jangan", cellX(-2), 0)  // in the window at 0, out at 1
	east := spawnAt(t, monsters, "jangan", cellX(3), 300) // out at 0, in at 1
	both := spawnAt(t, monsters, "jangan", cellX(1), 0)   // in both
	if _, ok := monsters.SetMotion(east, cellX(3)+200, 300, 8, 0); !ok {
		t.Fatal("precondition: the east monster walks")
	}
	r := newListRig(t, monsters)
	v := installAOIForTest(t, r.hub, monsters)
	c := r.join(t, 1, 0, 0)
	got, _ := r.list(t, c, 2)
	if !sameIDs(idsOf(got), []int64{west, both}) {
		t.Fatalf("first list %v, want %v", idsOf(got), []int64{west, both})
	}
	v.reconcile() // the view is where the list put it: nothing owed
	if extra := c.quiet(t, 150*time.Millisecond); len(extra) != 0 {
		t.Fatalf("%d frame(s) with nobody moved", len(extra))
	}

	sess := r.session(1)
	r.hub.Move(sess, world.Position{X: cellX(1) - 900, Z: 0}) // over the line at x = 960
	v.reconcile()
	left, entered, legs := aoiFrames(t, c.quiet(t, 200*time.Millisecond))
	if !sameIDs(left, []int64{west}) || !sameIDs(entered, []int64{east}) {
		t.Fatalf("crossing east: left %v entered %v, want left [%d] entered [%d]", left, entered, west, east)
	}
	if len(legs) != 1 || legs[0].MonsterID != east || legs[0].DestX != float32(cellX(3)+200) {
		t.Fatalf("the walking monster's leg: %+v, want one leg for %d to x %.0f", legs, east, cellX(3)+200)
	}

	r.hub.Move(sess, world.Position{X: 0, Z: 0})
	v.reconcile()
	left, entered, _ = aoiFrames(t, c.quiet(t, 200*time.Millisecond))
	if !sameIDs(left, []int64{east}) || !sameIDs(entered, []int64{west}) {
		t.Fatalf("crossing back: left %v entered %v, want left [%d] entered [%d]", left, entered, east, west)
	}
}

// A monster the step carries over a region line enters or leaves a player's
// window through the AI tick: the one walking out is named in an
// OpMonsterLeft, the one walking in arrives as an OpMonsterSpawned followed by
// its leg. And the tick's pushes about monsters outside the window do not
// reach the player at all.
func TestAOIEnterLeaveAsAMonsterCrosses(t *testing.T) {
	monsters := combat.NewHub()
	out := spawnAt(t, monsters, "jangan", cellX(2)+900, 0) // cell 2, walking into cell 3
	in := spawnAt(t, monsters, "jangan", cellX(3)-900, 50) // cell 3, walking into cell 2
	far := spawnAt(t, monsters, "jangan", cellX(6), 0)
	r := newListRig(t, monsters)
	v := installAOIForTest(t, r.hub, monsters)
	c := r.join(t, 1, 0, 0)
	v.reconcile()
	a := installMonsterAIForTest(t, r.hub, monsters, 1, nil) // nil: the production push
	a.tick(aiT0)                                             // brains; no step on the first pass
	c.quiet(t, 100*time.Millisecond)
	monsters.SetMotion(out, cellX(3)-800, 0, 1000, 1)
	monsters.SetMotion(in, cellX(2)+800, 50, 1000, 1)
	a.tick(aiT0.Add(MonsterAITick)) // one 160-unit step each, over x = 4,800
	left, entered, legs := aoiFrames(t, c.quiet(t, 200*time.Millisecond))
	if !sameIDs(left, []int64{out}) || !sameIDs(entered, []int64{in}) {
		t.Fatalf("left %v entered %v, want left [%d] entered [%d]", left, entered, out, in)
	}
	if len(legs) != 1 || legs[0].MonsterID != in {
		t.Fatalf("legs %+v, want the entering monster's", legs)
	}

	// The pass's pushes are the watchers' only.
	a.emit(monsterPush{zone: "jangan", cell: combat.CellOf("jangan", cellX(6), 0),
		packet: &proto.Packet{Opcode: OpMonsterMoved, Data: (&MonsterMoved{MonsterID: far}).Encode()}}, nil)
	if got := c.quiet(t, 150*time.Millisecond); len(got) != 0 {
		t.Fatalf("a push about a monster six regions away reached the player: %d frame(s)", len(got))
	}
	a.emit(monsterPush{zone: "jangan", cell: combat.CellOf("jangan", cellX(2), 0),
		packet: &proto.Packet{Opcode: OpMonsterMoved, Data: (&MonsterMoved{MonsterID: in}).Encode()}}, nil)
	if got := c.quiet(t, 150*time.Millisecond); len(got) != 1 {
		t.Fatalf("a push about a monster in the window: %d frame(s), want 1", len(got))
	}
}

// A GM /kill or a combat death is announced to the watchers only: the
// request path's recipients (monsterWatchers) are the players whose window
// holds the monster.
func TestMonsterWatchersAreTheWindowsHolders(t *testing.T) {
	hub := world.NewHub()
	monsters := combat.NewHub()
	near := gateway.NewTestSession(1)
	farAway := gateway.NewTestSession(2)
	other := gateway.NewTestSession(3)
	hub.Enter(near, 1, "near", 1, "jangan", world.Position{X: cellX(2), Z: 0})
	hub.Enter(farAway, 2, "far", 1, "jangan", world.Position{X: cellX(5), Z: 0})
	hub.Enter(other, 3, "other", 1, "donwhang", world.Position{})
	m, _ := monsters.Get(spawnAt(t, monsters, "jangan", 0, 0))
	var got []int64
	for _, e := range monsterWatchers(hub, monsters, m) {
		got = append(got, e.CharacterID)
	}
	if !sameIDs(got, []int64{1}) {
		t.Fatalf("watchers %v, want [1]", got)
	}
}

// With sleep on, a monster no player is near has no brain and does not move;
// the one beside the player wanders. When the player walks to the sleeper it
// wakes, and the monster left behind keeps its brain but stops.
func TestSleepingBrainsWaitForAPlayer(t *testing.T) {
	hub := world.NewHub()
	monsters := newAIHub(3)
	sess := gateway.NewTestSession(1)
	hub.Enter(sess, 1, "p", 1, "jangan", world.Position{})
	near := spawnAt(t, monsters, "jangan", 100, 0)
	sleeper := spawnAt(t, monsters, "jangan", cellX(10), 0)
	rec := &pushRecorder{}
	a := newMonsterAI(hub, monsters, nil, MonsterAIConfig{Sleep: true}, rand.New(rand.NewSource(3)), rec.push)
	monsterAIRuntime.Store(a)
	t.Cleanup(func() { monsterAIRuntime.Store(nil) })

	now := aiT0
	nearMoved := false
	for i := 0; i < 600; i++ { // a minute
		a.tick(now)
		now = now.Add(MonsterAITick)
		if m, _ := monsters.Get(near); m.X != 100 || m.Z != 0 {
			nearMoved = true
		}
	}
	if !nearMoved {
		t.Fatal("the monster beside the player never moved in a minute")
	}
	if a.brains[sleeper] != nil {
		t.Fatal("the monster ten regions away has a brain")
	}
	if m, _ := monsters.Get(sleeper); m.X != cellX(10) || m.Z != 0 || m.Moving {
		t.Fatalf("the sleeper moved: %+v", m)
	}

	hub.Move(sess, world.Position{X: cellX(10) - 300})
	parked, _ := monsters.Get(near)
	sleeperMoved := false
	for i := 0; i < 600; i++ {
		a.tick(now)
		now = now.Add(MonsterAITick)
		if m, _ := monsters.Get(sleeper); m.X != cellX(10) || m.Z != 0 {
			sleeperMoved = true
		}
	}
	if a.brains[sleeper] == nil || !sleeperMoved {
		t.Fatalf("the sleeper did not wake: brain %v, moved %v", a.brains[sleeper] != nil, sleeperMoved)
	}
	if a.brains[near] == nil {
		t.Fatal("the monster left behind lost its brain; it should only sleep")
	}
	if m, _ := monsters.Get(near); m.X != parked.X || m.Z != parked.Z {
		t.Fatalf("the monster left behind kept walking: %.1f,%.1f -> %.1f,%.1f", parked.X, parked.Z, m.X, m.Z)
	}
}

// Sleep off (the zero config, every test before round 656): a monster with no
// player anywhere still runs, as before.
func TestSleepOffRunsEveryMonster(t *testing.T) {
	monsters := newAIHub(4)
	far := spawnAt(t, monsters, "jangan", cellX(10), 0)
	a := installMonsterAIForTest(t, world.NewHub(), monsters, 4, (&pushRecorder{}).push)
	now := aiT0
	moved := false
	for i := 0; i < 600 && !moved; i++ {
		a.tick(now)
		now = now.Add(MonsterAITick)
		if m, _ := monsters.Get(far); m.X != cellX(10) || m.Z != 0 {
			moved = true
		}
	}
	if !moved {
		t.Fatal("with sleep off a monster nobody is near never moved")
	}
}
