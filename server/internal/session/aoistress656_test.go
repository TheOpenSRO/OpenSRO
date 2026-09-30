package session

// Round 656's review: the reviewer's stress test, kept as a regression test.
// Four goroutines -- a player that walks, jumps and lists, the view
// reconcile, the AI tick with forced legs over region lines, and kills and
// respawns -- run at once for three seconds against a client model that
// applies every monster message; after it settles, the client must hold
// exactly the monsters of its window: no ghost, none missing, and no spawn of
// a dead monster. It drives the production paths: the blow through
// damageMonsterWatched, the death to its watchers under the wire lock, the
// respawn through BroadcastMonsterSpawned. The reviewer's version gated the
// fixed kill and spawn paths behind RV_FIXKILL / RV_FIXSPAWN; both are the
// code now. Then the two orderings the review found, step against view move.

import (
	"math/rand"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

func TestAOIStressClientMatchesTheWindow(t *testing.T) {
	monsters := combat.NewHub()
	rng := rand.New(rand.NewSource(1))
	span := 1920.0
	randPos := func(r *rand.Rand, cells float64) (float64, float64) {
		return (r.Float64()*2 - 1) * cells * span, (r.Float64()*2 - 1) * cells * span
	}
	for i := 0; i < 400; i++ {
		x, z := randPos(rng, 4.5)
		spawnAt(t, monsters, "jangan", x, z)
	}
	SetMonsterSpawnPush(true)
	t.Cleanup(func() { SetMonsterSpawnPush(false) })
	r := newListRig(t, monsters)
	go func() {
		for range r.errs {
		}
	}()
	v := installAOIForTest(t, r.hub, monsters)
	c := r.join(t, 1, 0, 0)
	a := installMonsterAIForTest(t, r.hub, monsters, 1, nil)
	v.reconcile()

	// The client model.
	var (
		mu                                         sync.Mutex
		bodies                                     = map[int64]bool{}
		dead                                       = map[int64]bool{}
		unknownMoves, spawnAfterDeath, leftUnknown int
		pages                                      []int64
		frames                                     int64
	)
	readerDone := make(chan struct{})
	go func() {
		defer close(readerDone)
		for {
			c.conn.SetReadDeadline(time.Now().Add(5 * time.Second))
			p, err := proto.Read(c.r, nil, nil)
			if err != nil {
				return
			}
			atomic.AddInt64(&frames, 1)
			mu.Lock()
			switch p.Opcode {
			case OpMonsterListResult:
				lr, _ := DecodeMonsterListResult(p.Data)
				ids := []int64{}
				for _, m := range lr.Monsters {
					ids = append(ids, m.ID)
				}
				if lr.Pages > 1 {
					if lr.Page == 0 {
						pages = nil
					}
					pages = append(pages, ids...)
					if int(lr.Page)+1 < int(lr.Pages) {
						mu.Unlock()
						continue
					}
					ids, pages = pages, nil
				}
				bodies = map[int64]bool{}
				for _, id := range ids {
					bodies[id] = true
				}
			case OpMonsterSpawned:
				s, _ := DecodeMonsterSpawned(p.Data)
				if dead[s.Monster.ID] {
					spawnAfterDeath++
				} else {
					bodies[s.Monster.ID] = true
				}
			case OpMonsterMoved:
				m, _ := DecodeMonsterMoved(p.Data)
				if !bodies[m.MonsterID] {
					unknownMoves++
				}
			case OpMonsterLeft:
				l, _ := DecodeMonsterLeft(p.Data)
				for _, id := range l.IDs {
					if !bodies[id] {
						leftUnknown++
					}
					delete(bodies, id)
				}
			case OpMonsterDied:
				d, _ := DecodeMonsterDied(p.Data)
				delete(bodies, d.MonsterID)
				dead[d.MonsterID] = true
			}
			mu.Unlock()
		}
	}()

	stop := make(chan struct{})
	var wg sync.WaitGroup
	run := func(f func(r *rand.Rand), seed int64) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r := rand.New(rand.NewSource(seed))
			for {
				select {
				case <-stop:
					return
				default:
				}
				f(r)
			}
		}()
	}
	sess := r.session(1)
	// The player: walks, and now and then jumps across the map; lists sometimes.
	run(func(rr *rand.Rand) {
		x, z := randPos(rr, 3.5)
		r.hub.Move(sess, world.Position{X: x, Z: z})
		if rr.Intn(20) == 0 {
			proto.Write(c.conn, &proto.Packet{Opcode: OpMonsterList, Data: []byte{MonsterListFlagPaged}}, nil, nil)
		}
		time.Sleep(time.Duration(rr.Intn(3)) * time.Millisecond)
	}, 2)
	// The reconcile.
	run(func(rr *rand.Rand) { v.reconcile(); time.Sleep(200 * time.Microsecond) }, 3)
	// The AI tick with forced long legs over region lines.
	now := aiT0
	var tickMu sync.Mutex
	run(func(rr *rand.Rand) {
		all := monsters.AppendAll(nil)
		for i := 0; i < 20 && len(all) > 0; i++ {
			m := all[rr.Intn(len(all))]
			dx, dz := randPos(rr, 4.5)
			monsters.SetMotion(m.ID, dx, dz, 1600, 1)
		}
		tickMu.Lock()
		now = now.Add(MonsterAITick)
		a.tick(now)
		tickMu.Unlock()
	}, 4)
	// Kills (as performAttack: ApplyDamage, then the watchers, each under the
	// wire lock) and respawns (BroadcastMonsterSpawned).
	run(func(rr *rand.Rand) {
		all := monsters.AppendAll(nil)
		if len(all) == 0 {
			return
		}
		m := all[rr.Intn(len(all))]
		_, died, ok, watchers, _ := damageMonsterWatched(r.hub, monsters, m.ID, 0, 1<<30)
		if ok && died {
			msg := (&MonsterDied{MonsterID: m.ID}).Encode()
			for _, e := range watchers {
				sendMonsterPush(e.Session, &proto.Packet{Opcode: OpMonsterDied, Data: msg})
			}
		}
		x, z := randPos(rr, 4.5)
		BroadcastMonsterSpawned(r.hub, monsters, spawnAt(t, monsters, "jangan", x, z))
		time.Sleep(time.Duration(rr.Intn(2)) * time.Millisecond)
	}, 5)

	time.Sleep(3 * time.Second)
	close(stop)
	wg.Wait()
	// Settle: stop every leg so nothing moves, then one reconcile.
	for _, m := range monsters.AppendAll(nil) {
		monsters.StopMotion(m.ID)
	}
	v.reconcile()
	time.Sleep(500 * time.Millisecond)

	mu.Lock()
	defer mu.Unlock()
	cell, _ := v.viewCell(sess.ID())
	e, _ := r.hub.EntityBySession(sess.ID())
	standCell := combat.CellOf(e.Zone, e.Pos.X, e.Pos.Z)
	truth := map[int64]bool{}
	for _, m := range monsterWindow(monsters, cell) {
		truth[m.ID] = true
	}
	var ghosts, missing []int64
	for id := range bodies {
		if !truth[id] {
			ghosts = append(ghosts, id)
		}
	}
	for id := range truth {
		if !bodies[id] {
			missing = append(missing, id)
		}
	}
	t.Logf("frames %d, view %v stand %v, client bodies %d, truth %d, ghosts %d %v, missing %d %v, unknown moves %d, spawn-after-death %d, leave-unknown %d, dead %d",
		atomic.LoadInt64(&frames), cell, standCell, len(bodies), len(truth), len(ghosts), ghosts, len(missing), missing, unknownMoves, spawnAfterDeath, leftUnknown, len(dead))
	if len(ghosts) > 0 || len(missing) > 0 || spawnAfterDeath > 0 {
		t.Errorf("client diverged from the server's window")
	}
}

// The review's two orderings (a monster's step over a region line, the view
// moving over another). Before the fix the tick's step, a reconcile and the
// tick's crossings could interleave in that order and lose the enter or the
// leave. The step and its crossings are now one step under the view lock
// (monsterAOI.step), so a reconcile lands wholly before or wholly after it;
// both orders must end with the right message.
func rv656Interleave(t *testing.T, reconcileFirst bool, playerFrom, playerTo, monFrom, monTo float64) (left, entered []int64, id int64) {
	monsters := combat.NewHub()
	id = spawnAt(t, monsters, "jangan", monFrom, 0)
	r := newListRig(t, monsters)
	v := installAOIForTest(t, r.hub, monsters)
	c := r.join(t, 1, playerFrom, 0)
	r.list(t, c, 0)
	c.quiet(t, 100*time.Millisecond)
	monsters.SetMotion(id, monTo, 0, 1600, 1)
	r.hub.Move(r.session(1), world.Position{X: playerTo, Z: 0})
	if reconcileFirst {
		v.reconcile()
	}
	changes, owed := v.step(0.1, nil, nil) // 160 units: over the line
	if len(changes) != 1 {
		t.Fatalf("precondition: one crossing, got %v", changes)
	}
	for _, ev := range owed {
		v.deliverViewEvents(ev)
	}
	if !reconcileFirst {
		v.reconcile()
	}
	left, entered, _ = aoiFrames(t, c.quiet(t, 200*time.Millisecond))
	return left, entered, id
}

// The enter: M walks from cell 3 (outside the window at 0) into cell 2 while
// the player moves from cell 0 to cell 1 (whose window holds both).
func TestAOIStepAndViewMoveKeepTheEnter(t *testing.T) {
	for _, first := range []bool{true, false} {
		left, entered, id := rv656Interleave(t, first, 0, cellX(1)-900, cellX(3)-900+50, cellX(2))
		if !sameIDs(entered, []int64{id}) || len(left) != 0 {
			t.Errorf("reconcile first %v: left %v entered %v, want monster %d entered once", first, left, entered, id)
		}
	}
}

// The leave: M walks from cell 2 into cell 3 while the player moves from cell
// 0 to cell -1 (whose window holds neither).
func TestAOIStepAndViewMoveKeepTheLeave(t *testing.T) {
	for _, first := range []bool{true, false} {
		left, entered, id := rv656Interleave(t, first, 0, cellX(-1), cellX(3)-960-50, cellX(3))
		if !sameIDs(left, []int64{id}) || len(entered) != 0 {
			t.Errorf("reconcile first %v: left %v entered %v, want monster %d left once", first, left, entered, id)
		}
	}
}
