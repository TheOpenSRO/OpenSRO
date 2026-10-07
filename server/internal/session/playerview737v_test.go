package session

import (
	"bufio"
	"context"
	"fmt"
	"runtime/debug"
	"sync"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// Round 737's verification: the regressions its findings N1-N5 name, kept as
// tests (N1 and N2 from the verifier's own probes).

// N1, the verifier's TestVerify737ClosedViewSelfCrossing: the mover's OWN
// crossing while its view is closed -- a zone change run off the session's
// goroutine (returnAfterKill from a monster's strike worker, the status
// tick) racing the session's own move. The closed view had no stores, and
// crossPlayer ran on a nil hub and panicked, which ended the process. Now
// the crossing waits for the view to open, and arrivePlayer spawns both ways
// from the window as it then is.
func TestACrossingWhileTheViewIsClosedWaitsForTheArrival(t *testing.T) {
	SetSingleFrame(true)
	t.Cleanup(func() { SetSingleFrame(false) })
	f := startDeadWorldFixture(t)
	ea, _ := f.hub.EntityByCharacterID(f.aria)
	eb, _ := f.hub.EntityByCharacterID(f.bram)
	home := ea.Pos
	far := world.Position{X: home.X + 5000, Y: home.Y, Z: home.Z}
	f.send(t, f.connA, OpMove, (&MoveRequest{X: float32(far.X), Y: float32(far.Y), Z: float32(far.Z), Relocated: true}).Encode())
	expectPlayerDespawn(t, f.connB, f.rB, f.aria)
	expectPlayerDespawn(t, f.connA, f.rA, f.bram)

	var mu sync.Mutex
	var got any
	crossed := false
	warpBeforeResultHook = func(sess *gateway.Session) {
		if sess != eb.Session {
			return
		}
		moved, ok := f.hub.Relocate(sess, far, world.MoveRelocate, 0)
		func() {
			defer func() {
				mu.Lock()
				crossed = ok && moved.Crossed
				if got = recover(); got != nil {
					t.Logf("%s", debug.Stack())
				}
				mu.Unlock()
			}()
			afterRelocate(sess, moved, false, gateway.MustFrame(&proto.Packet{Opcode: OpEntityMoved, Data: (&EntityMoved{CharacterID: f.bram}).Encode()}))
		}()
	}
	t.Cleanup(func() { warpBeforeResultHook = nil })
	if czr := changeZone(t, f, f.connB, f.rB, "jangan"); !czr.OK {
		t.Fatalf("Bram's warp: %+v", czr)
	}
	mu.Lock()
	if got != nil {
		mu.Unlock()
		t.Fatalf("PANIC in afterRelocate with a closed view: %v", got)
	}
	if !crossed {
		mu.Unlock()
		t.Fatal("setup: Bram's move in the gap did not cross a block line")
	}
	mu.Unlock()
	// The arrival spawns them to each other, once.
	expectPlayerSpawn(t, f.connB, f.rB, f.aria)
	expectPlayerSpawn(t, f.connA, f.rA, f.bram)
	if !f.nothing(t, f.connA, f.rA) || !f.nothing(t, f.connB, f.rB) {
		t.Fatal("more followed the arrival's spawns")
	}
	if !holds(f.aria, f.bram) || !holds(f.bram, f.aria) {
		t.Fatalf("Aria holds Bram %v; Bram holds Aria %v -- want both", holds(f.aria, f.bram), holds(f.bram, f.aria))
	}
}

// blockingEq blocks its first Get after reading, until released.
type blockingEq struct {
	equipment.Store
	once    sync.Once
	read    chan struct{}
	release chan struct{}
}

func (b *blockingEq) Get(ctx context.Context, id int64) ([]equipment.Equipped, error) {
	out, err := b.Store.Get(ctx, id)
	b.once.Do(func() {
		close(b.read)
		<-b.release
	})
	return out, err
}

// N2, the verifier's TestVerify737LookCacheStaleAfterRace: an unequip landing
// while a spawn record's look is being read. The read stored the OLD look
// after the unequip's invalidation, and every later spawn served it.
func TestALookReadBeforeAnUnequipIsNotServedAfterIt(t *testing.T) {
	ctx := context.Background()
	SetSpawnItemRefs(nil)
	inv := inventory.NewMemStore(nil)
	inner := equipment.NewMemStore(inv)
	chars := character.NewMemStore()
	c, _ := chars.Create(ctx, 1, "Racer")
	if err := inv.AddItemInstance(ctx, c.ID, 3643, 1, inventory.Instance{OptLevel: 5}); err != nil {
		t.Fatal(err)
	}
	slots, _ := inv.List(ctx, c.ID)
	if err := inner.Equip(ctx, c.ID, equipment.SlotMail, slots[0].Index); err != nil {
		t.Fatal(err)
	}
	invalidateLook(c.ID)
	t.Cleanup(func() { invalidateLook(c.ID) })
	b := &blockingEq{Store: inner, read: make(chan struct{}), release: make(chan struct{})}
	d := viewDeps{ctx: ctx, eq: b, chars: chars}
	done := make(chan look)
	go func() { done <- lookOf(ctx, d, c.ID) }()
	<-b.read
	// The unequip, as handleUnequip does it: the store, then broadcastUnworn's
	// invalidation -- both inside the read's gap.
	if err := inner.Unequip(ctx, c.ID, equipment.SlotMail); err != nil {
		t.Fatal(err)
	}
	invalidateLook(c.ID)
	close(b.release)
	if old := <-done; len(old.items) != 1 {
		t.Fatalf("setup: the read in the gap saw %d item(s), want the 1 worn when it read", len(old.items))
	}
	lk := lookOf(ctx, d, c.ID)
	if len(lk.items) != 0 {
		t.Fatalf("STALE: the store wears nothing, the look served is %s", fmt.Sprint(lk.items))
	}
	// And a look read after the change is cached again.
	if v, ok := looks.Load(c.ID); !ok || len(v.(lookEntry).look.items) != 0 {
		t.Fatal("the fresh look was not cached")
	}
}

// N3: a character that left one session and is in the world on a newer one
// keeps its state number and its cached look.
func TestALeaveKeepsTheStateOfACharacterLiveElsewhere(t *testing.T) {
	ctx := context.Background()
	hub := world.NewHub()
	const id = 737_003
	live := gateway.NewTestSession(73703)
	hub.Enter(live, id, "Keeper", 1, "jangan", world.Position{})
	t.Cleanup(func() { forgetPlayerState(id); invalidateLook(id) })
	bumpPlayerState(id)
	bumpPlayerState(id)
	lookOf(ctx, viewDeps{}, id)
	forgetLeftPlayer(hub, id)
	if v := playerStateVersion(id); v != 2 {
		t.Fatalf("state number %d after a stale leave, want 2 (kept)", v)
	}
	if _, ok := looks.Load(int64(id)); !ok {
		t.Fatal("the cached look was dropped by a stale leave")
	}
	hub.Leave(live)
	forgetLeftPlayer(hub, id)
	if v := playerStateVersion(id); v != 0 {
		t.Fatalf("state number %d after the real leave, want 0", v)
	}
	if _, ok := looks.Load(int64(id)); ok {
		t.Fatal("the cached look outlived the real leave")
	}
}

// N4: a reconnect's stale session that changes zone moves its own entity
// and hears its own result, and touches nothing of the live session's: the
// view, the character in the hub, the bodies the zone holds.
func TestAStaleSessionsZoneChangeLeavesTheLiveSessionAlone(t *testing.T) {
	f := startDeadWorldFixture(t)
	addr := f.connA.RemoteAddr().String()
	conn2 := dialTestServer(t, addr)
	t.Cleanup(func() { conn2.Close() })
	r2 := bufio.NewReader(conn2)
	f.login(t, conn2, r2, "alice", "hunter2", "Aria")
	expectPlayerSpawn(t, conn2, r2, f.bram)
	expectPlayerSpawn(t, f.connB, f.rB, f.aria)
	liveE, _ := f.hub.EntityByCharacterID(f.aria)
	liveView := playerViewOf(f.aria)

	// The stale connection asks for a zone change.
	if czr := changeZone(t, f, f.connA, f.rA, "donwhang"); !czr.OK {
		t.Fatalf("the stale session's zone change: %+v", czr)
	}
	if e, ok := f.hub.EntityByCharacterID(f.aria); !ok || e.Session != liveE.Session {
		t.Fatal("the stale session's zone change took the character from the live session")
	}
	if v := playerViewOf(f.aria); v != liveView {
		t.Fatal("the stale session's zone change replaced the live session's view")
	}
	if !holds(f.aria, f.bram) || !holds(f.bram, f.aria) {
		t.Fatalf("Aria holds Bram %v; Bram holds Aria %v -- want both", holds(f.aria, f.bram), holds(f.bram, f.aria))
	}
	if !f.nothing(t, f.connB, f.rB) || !f.nothing(t, conn2, r2) {
		t.Fatal("Bram or Aria's live client was told of the stale session's zone change")
	}
	// A stale arrival opens no view either.
	var stale world.Entity
	for _, e := range f.hub.AllEntities() {
		if e.CharacterID == f.aria && e.Session != liveE.Session {
			stale = e
		}
	}
	if stale.Session == nil {
		t.Fatal("setup: the stale session's entity is not in the hub")
	}
	arrivePlayer(viewDeps{hub: f.hub}, stale)
	if v := playerViewOf(f.aria); v != liveView {
		t.Fatal("a stale arrival replaced the live session's view")
	}
}

// N5: the zone notice goes only where its spawn or despawn goes. A session
// in view with no view of its own, or one that already holds the arrival,
// hears neither (NewTestSession panics on any send).
func TestAZoneNoticeGoesOnlyWithItsSpawnOrDespawn(t *testing.T) {
	f := startDeadWorldFixture(t)
	ea, _ := f.hub.EntityByCharacterID(f.aria)
	noView := gateway.NewTestSession(73751)
	f.hub.Enter(noView, 300, "Cyra", 1, ea.Zone, ea.Pos)
	defer f.hub.Leave(noView)
	holder := gateway.NewTestSession(73752)
	f.hub.Enter(holder, 301, "Dara", 1, ea.Zone, ea.Pos)
	defer f.hub.Leave(holder)
	d := viewDeps{hub: f.hub}
	hv := startPlayerView(301, holder, d)
	t.Cleanup(func() { forgetPlayerView(301, holder) })
	hv.mu.Lock()
	hv.known[f.aria] = ea.Arrival // already holds this very arrival
	hv.mu.Unlock()
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("a zone notice was sent without its spawn or despawn (%v)", r)
		}
	}()
	recips := []world.Entity{{Session: noView, CharacterID: 300}, {Session: holder, CharacterID: 301}}
	spawnPlayerToOthersAs(d, ea, recips, true, zoneNoticeFrame(zoneNoticeEntered, ea))
	hv.mu.Lock()
	delete(hv.known, f.aria) // holds nothing now: no despawn, so no notice
	hv.mu.Unlock()
	departPlayer(f.hub, ea, world.WatchersOf(recips))
}
