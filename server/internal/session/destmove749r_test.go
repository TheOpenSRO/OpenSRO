package session

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/grounditem"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/quest"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
	"github.com/TheOpenSRO/OpenSRO/server/internal/statuseffect"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 749's review (docs/rounds/r749_review.md): the attacks on the position
// bound, run with the production bound (-trust-client-positions off). Each
// failed before the fixes (F1: no clock; MEASURED there: x 1650, z 1650, x
// 810) and must hold now: no chain of stops, placements or click + stop pairs
// moves a character faster than its run speed allows -- a free slack of
// claimSlack about where the server has it, plus at most a second of run
// (world.AllowanceSeconds) banked while it stood.

// drainQuiet reads conn until nothing comes for 200 ms.
func drainQuiet(t *testing.T, conn net.Conn, r *bufio.Reader) int {
	t.Helper()
	n := 0
	for {
		conn.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
		if _, err := proto.Read(r, nil, nil); err != nil {
			return n
		}
		n++
	}
}

// boundReach is the farthest a character standing still for any time can be
// put from where the server had it by claims alone: the free slack plus a
// second of run at the base run speed, with a unit of float room.
const boundReach = claimSlack + PlayerRunSpeed*1.0 + 1

func TestRound749ReviewIdleCreepIsBounded(t *testing.T) {
	strictPositions(t)
	f := startDeadWorldFixture(t)
	start, _ := f.hub.EntityByCharacterID(f.aria)
	t0 := time.Now()
	for i := 1; i <= 300; i++ {
		f.send(t, f.connA, OpMove, (&MoveRequest{X: float32(start.Pos.X + 5.5*float64(i)), Z: float32(start.Pos.Z), Stopped: true}).Encode())
	}
	drainQuiet(t, f.connA, f.rA)
	drainQuiet(t, f.connB, f.rB)
	e, _ := f.hub.EntityByCharacterID(f.aria)
	moved := e.Pos.X - start.Pos.X
	t.Logf("300 stop reports of 5.5: Aria moved %.1f (bound %.1f)", moved, boundReach)
	if moved > boundReach {
		t.Fatalf("300 stop reports of 5.5 moved Aria %.1f in %v; the bound is %.1f", moved, time.Since(t0), boundReach)
	}
}

func TestRound749ReviewPlacementCreepIsBounded(t *testing.T) {
	strictPositions(t)
	f := startDeadWorldFixture(t)
	start, _ := f.hub.EntityByCharacterID(f.aria)
	for i := 1; i <= 300; i++ {
		f.send(t, f.connA, OpMove, (&MoveRequest{X: float32(start.Pos.X), Z: float32(start.Pos.Z + 5.5*float64(i)), Relocated: true}).Encode())
	}
	drainQuiet(t, f.connA, f.rA)
	drainQuiet(t, f.connB, f.rB)
	e, _ := f.hub.EntityByCharacterID(f.aria)
	moved := e.Pos.Z - start.Pos.Z
	t.Logf("300 placements of 5.5: Aria moved %.1f (bound %.1f)", moved, boundReach)
	if moved > boundReach {
		t.Fatalf("300 placements of 5.5 moved Aria %.1f; the bound is %.1f", moved, boundReach)
	}
}

func TestRound749ReviewLegHopIsBounded(t *testing.T) {
	strictPositions(t)
	f := startDeadWorldFixture(t)
	start, _ := f.hub.EntityByCharacterID(f.aria)
	t0 := time.Now()
	for k := 0; k < 15; k++ {
		x := start.Pos.X + 54*float64(k)
		f.send(t, f.connA, proto.OpMovementRequest, clickTo(x+1000, 0, start.Pos.Z))
		f.send(t, f.connA, OpMove, (&MoveRequest{X: float32(x + 54), Z: float32(start.Pos.Z), Stopped: true}).Encode())
	}
	drainQuiet(t, f.connA, f.rA)
	drainQuiet(t, f.connB, f.rB)
	elapsed := time.Since(t0).Seconds()
	e, _ := f.hub.EntityByCharacterID(f.aria)
	// What the leg itself may have walked meanwhile, plus the bound.
	moved, limit := e.Pos.X-start.Pos.X, boundReach+PlayerRunSpeed*elapsed
	t.Logf("15 click + stop pairs: Aria moved %.1f in %.2f s (bound %.1f)", moved, elapsed, limit)
	if moved > limit {
		t.Fatalf("15 click + stop pairs moved Aria %.1f in %.2f s; the bound is %.1f", moved, elapsed, limit)
	}
}

// fakeHubClock puts hub on a clock the test moves; restored at cleanup.
func fakeHubClock(t *testing.T, hub *world.Hub) func(time.Duration) {
	t.Helper()
	var now atomic.Int64
	now.Store(time.Now().UnixNano())
	hub.SetClock(func() time.Time { return time.Unix(0, now.Load()) })
	t.Cleanup(func() { hub.SetClock(nil) })
	return func(d time.Duration) { now.Add(int64(d)) }
}

// F2: an arrival's named points are taken once and only within the grace; a
// logout spot is no free recall.
func TestRound749ReviewANamedPointIsTakenOnceAndExpires(t *testing.T) {
	strictPositions(t)
	f := startDeadWorldFixture(t)
	noteArrivalLanding(f.aria, spawnZone, world.Position{X: -300, Z: 100})
	f.send(t, f.connA, OpMove, (&MoveRequest{X: -300, Y: 1, Z: 100, Relocated: true}).Encode())
	readOp(t, f, f.connB, f.rB, OpMovementStop)
	if e, _ := f.hub.EntityByCharacterID(f.aria); e.Pos.X != -300 {
		t.Fatalf("the arrival point was not taken: %+v", e.Pos)
	}
	// Walk off (a server leg), then ask for the same point again: refused.
	advance := fakeHubClock(t, f.hub)
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(-100, 0, 100))
	readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
	advance(5 * time.Second)
	f.send(t, f.connA, OpMove, (&MoveRequest{X: -300, Y: 1, Z: 100, Relocated: true}).Encode())
	p, _ := readOp(t, f, f.connA, f.rA, OpMovementStop)
	if _, at, _ := stopWorld(t, spawnZone, p.Data); at.X < -101 {
		t.Fatalf("the used arrival point was taken again: Aria put at %+v", at)
	}
	// A point named past its grace is refused.
	noteLandings(f.aria, time.Now().Add(-landingGrace-time.Second), true, [2]float64{-600, 100})
	f.send(t, f.connA, OpMove, (&MoveRequest{X: -600, Y: 1, Z: 100, Relocated: true}).Encode())
	p, _ = readOp(t, f, f.connA, f.rA, OpMovementStop)
	if _, at, _ := stopWorld(t, spawnZone, p.Data); at.X < -101 {
		t.Fatalf("an expired point was taken: %+v", at)
	}
}

// F4: a stopping state refuses the click, and one landing mid-walk ends the
// leg with 0xB023 to the window and the mover; an established trade refuses
// the click.
func TestRound749ReviewStatesStopTheMove(t *testing.T) {
	f := startDeadWorldFixture(t)
	setStun := func(on bool) {
		statusFX.mu.Lock()
		defer statusFX.mu.Unlock()
		if !on {
			delete(statusFX.pcs, f.aria)
			return
		}
		h := &statuseffect.Holder{}
		h.Put(statuseffect.Record{Code: "stun", Slot: 7, Bit: 7, DurationMs: 60000}) // mask 0x80, in 0xc1
		statusFX.pcs[f.aria] = h
	}
	t.Cleanup(func() { setStun(false) })
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(300, 0, 0))
	readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
	readOp(t, f, f.connB, f.rB, proto.OpMovementResponse)
	setStun(true)
	haltForState(f.hub, f.aria)
	for _, side := range []struct {
		conn net.Conn
		r    *bufio.Reader
	}{{f.connA, f.rA}, {f.connB, f.rB}} {
		if p := f.read(t, side.conn, side.r); p.Opcode != OpMovementStop {
			t.Fatalf("a stun mid-walk sent %#04x, want 0xB023", p.Opcode)
		}
	}
	if e, _ := f.hub.EntityByCharacterID(f.aria); e.Move != nil {
		t.Fatal("the leg runs on under a stun")
	}
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(-300, 0, 0))
	if !f.nothing(t, f.connA, f.rA) || !f.nothing(t, f.connB, f.rB) {
		t.Fatal("a stunned character's click was answered")
	}
	setStun(false)
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(-300, 0, 0))
	readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
}

func TestRound749ReviewAnEstablishedTradeRefusesTheClick(t *testing.T) {
	f := setupTradeTest(t)
	startTrade(t, f)
	if err := proto.Write(f.connA, &proto.Packet{Opcode: proto.OpMovementRequest, Data: clickTo(100, 0, 0)}, nil, nil); err != nil {
		t.Fatal(err)
	}
	f.connA.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
	if p, err := proto.Read(f.rA, nil, nil); err == nil {
		t.Fatalf("a click in an established trade was answered %#04x", p.Opcode)
	}
	if e, _ := f.hub.EntityByCharacterID(f.ariaID); e.Move != nil {
		t.Fatal("a click in an established trade gave a leg")
	}
}

// F8: past the bucket's burst, clicks are dropped.
func TestRound749ReviewTheClickBucket(t *testing.T) {
	f := startDeadWorldFixture(t)
	const n = int(moveBucketBurst) + 20
	for i := 0; i < n; i++ {
		x := 100.0
		if i%2 == 1 {
			x = -100
		}
		f.send(t, f.connA, proto.OpMovementRequest, clickTo(x, 0, 0))
	}
	echoes := 0
	for {
		f.connA.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
		p, err := proto.Read(f.rA, nil, nil)
		if err != nil {
			break
		}
		if p.Opcode == proto.OpMovementResponse {
			echoes++
		}
	}
	drainQuiet(t, f.connB, f.rB)
	// The burst, and what refilled while they were read (at most a few).
	if echoes < int(moveBucketBurst) || echoes >= n {
		t.Fatalf("%d clicks in a burst were echoed %d times; want the burst of %v (and a few refilled), not all", n, echoes, moveBucketBurst)
	}
	if !moveBucketTake(gateway.NewTestSession(9), time.Now()) {
		t.Fatal("a fresh session's bucket is empty")
	}
}

// F10: a destination or a claim whose height is out of bounds is refused.
func TestRound749ReviewHeightIsBounded(t *testing.T) {
	strictPositions(t)
	f := startDeadWorldFixture(t)
	// Fresh from the entry the server has no height of the client's own (its
	// arrival's is a guess): only the sanity range applies (round 749's
	// verification, FP1).
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(10, claimSanity+1000, 0))
	if !f.nothing(t, f.connA, f.rA) {
		t.Fatal("a destination past the sanity range was taken")
	}
	// The client gives a height (its click's ground, 0); from it, a point
	// 5000 up ten units on is refused.
	advance := fakeHubClock(t, f.hub)
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(10, 0, 0))
	readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
	advance(time.Second)
	drainQuiet(t, f.connB, f.rB)
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(20, 5000, 0))
	if !f.nothing(t, f.connA, f.rA) {
		t.Fatal("a destination 5000 up was taken")
	}
	f.send(t, f.connA, OpMove, (&MoveRequest{X: 1, Y: 900, Z: 0, Stopped: true}).Encode())
	p := f.read(t, f.connA, f.rA)
	if p.Opcode != OpMovementStop {
		t.Fatalf("a stop 900 up answered %#04x, want the correction", p.Opcode)
	}
	if e, _ := f.hub.EntityByCharacterID(f.aria); e.Pos.Y > claimHeight {
		t.Fatalf("Aria stands at height %v", e.Pos.Y)
	}
}

// F10: the server ends a heading run at world.HeadingRunLimit.
func TestRound749ReviewAHeadingRunEnds(t *testing.T) {
	f := startDeadWorldFixture(t)
	moverPassAuto.Store(false)
	t.Cleanup(func() { moverPassAuto.Store(true) })
	advance := fakeHubClock(t, f.hub)
	f.send(t, f.connA, proto.OpMovementRequest, []byte{0, proto.MovementCommandForward, 0, 0})
	readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
	readOp(t, f, f.connB, f.rB, proto.OpMovementResponse)
	advance(world.HeadingRunLimit + time.Second)
	moverPass(f.hub)
	if f.hub.Moving() != 0 {
		t.Fatal("the heading run runs on past the limit")
	}
	p, _ := readOp(t, f, f.connA, f.rA, OpMovementStop)
	if _, at, _ := stopWorld(t, spawnZone, p.Data); at.X < 50*float64(world.HeadingRunLimit/time.Second)-1 {
		t.Fatalf("the run was stopped at %+v", at)
	}
}

// F10 coverage: combat and the pick-up under the production bound -- the
// character walks by 0x7021 on the hub's clock, and a claim that did not walk
// is corrected and reaches nothing.
func TestRound749ReviewStrictCombatAndPickUp(t *testing.T) {
	strictPositions(t)
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	items := stubCombatItems{100: {ID: 100, PhysAttackMax: 30}, combat.ItemHPPotion: {ID: combat.ItemHPPotion}}
	inv := inventory.NewMemStore(items)
	if err := inv.AddItem(ctx, c.ID, 100, 1); err != nil {
		t.Fatal(err)
	}
	eq := equipment.NewMemStore(inv)
	if err := eq.Equip(ctx, c.ID, equipment.SlotWeapon, 0); err != nil {
		t.Fatal(err)
	}
	hub := world.NewHub()
	advance := fakeHubClock(t, hub)
	monsters := combat.NewHub()
	ground := grounditem.NewHub()
	const monsterX = 120.0
	monster := monsters.Spawn("jangan", "Mangyang", monsterX, 0, 0, 1, 0, 0, 10)
	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		CombatHandlerWithGround(chars, eq, items, hub, monsters, quest.NewMemStore(), inv, skill.NewMemStore(), nil, nil, nil, ground),
		GroundItemHandler(chars, hub, ground, inv, nil),
	)
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)
	write := func(op uint16, data []byte) {
		if err := proto.Write(conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
			t.Fatal(err)
		}
	}
	until := func(op uint16) *proto.Packet {
		for i := 0; i < 12; i++ {
			conn.SetReadDeadline(time.Now().Add(2 * time.Second))
			p, err := proto.Read(r, nil, nil)
			if err != nil {
				t.Fatalf("waiting for %#04x: %v", op, err)
			}
			if p.Opcode == op {
				return p
			}
		}
		t.Fatalf("no %#04x", op)
		return nil
	}
	write(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	until(OpLoginResult)
	write(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	until(OpEnterWorldResult)
	advance(2 * time.Second)

	// A claim beside the monster that did not walk: corrected, and the swing
	// is too far.
	write(OpMove, (&MoveRequest{X: monsterX - 2, Stopped: true}).Encode())
	until(OpMovementStop)
	write(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: monster.ID}).Encode())
	if ar, _ := DecodeAttackResult(until(OpAttackResult).Data); ar.Error != "too far away" {
		t.Fatalf("a swing after a refused claim: %+v, want too far", ar)
	}
	// The walk: one click, the leg's time, the kill.
	write(proto.OpMovementRequest, clickTo(monsterX-2, 0, 0))
	until(proto.OpMovementResponse)
	advance(3 * time.Second)
	write(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: monster.ID}).Encode())
	if ar, _ := DecodeAttackResult(until(OpAttackResult).Data); ar.Error != "" || !ar.MonsterDied {
		t.Fatalf("a swing after the walk: %+v, want the kill", ar)
	}
	s, _, err := decodeGroundItemSnapshot(until(OpGroundItemSpawned).Data)
	if err != nil {
		t.Fatal(err)
	}
	// Walk back to the start, then claim the drop without walking: refused.
	write(proto.OpMovementRequest, clickTo(0, 0, 0))
	until(proto.OpMovementResponse)
	advance(4 * time.Second)
	write(OpMove, (&MoveRequest{X: s.X, Y: s.Y, Z: s.Z, Stopped: true}).Encode())
	until(OpMovementStop)
	write(OpPickUp, (&PickUpRequest{CharacterName: "Aria", GroundItemID: s.ID}).Encode())
	if pr, _ := DecodePickUpResult(until(OpPickUpResult).Data); pr.Code != grounditem.ErrTooFar {
		t.Fatalf("a pick after a refused claim: %+v, want too far", pr)
	}
	// Walk to it and pick.
	write(proto.OpMovementRequest, clickTo(float64(s.X), 0, float64(s.Z)))
	until(proto.OpMovementResponse)
	advance(4 * time.Second)
	write(OpPickUp, (&PickUpRequest{CharacterName: "Aria", GroundItemID: s.ID}).Encode())
	if pr, _ := DecodePickUpResult(until(OpPickUpResult).Data); pr.Code != 0 {
		t.Fatalf("a pick after the walk: %+v, want it", pr)
	}
}

// F10 coverage: trade's range under the production bound, the partner walking
// away and back by 0x7021 on the hub's clock.
func TestRound749ReviewStrictTradeRange(t *testing.T) {
	strictPositions(t)
	f := setupTradeTest(t)
	advance := fakeHubClock(t, f.hub)
	write := func(c net.Conn, op uint16, data []byte) {
		if err := proto.Write(c, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
			t.Fatal(err)
		}
	}
	ask := func() []byte {
		write(f.connA, OpExchangeRequest, binary.LittleEndian.AppendUint32(nil, uint32(f.bramID)))
		return f.next(t, "A", OpExchangeRequestResult)
	}
	write(f.connB, proto.OpMovementRequest, clickTo(400, 0, 0))
	f.next(t, "B", proto.OpMovementResponse)
	f.next(t, "A", proto.OpMovementResponse)
	advance(9 * time.Second)
	// Round 834: the retail request, 0x7081 -> 0xB081 {2, 4}.
	if got := ask(); !bytes.Equal(got, exchangeResult(ExchangeErrTooFar)) {
		t.Fatalf("Bram 400 away by his walk: % x, want {2, 4}", got)
	}
	// A stop beside Aria that he did not walk: corrected; still too far.
	write(f.connB, OpMove, (&MoveRequest{X: 5, Stopped: true}).Encode())
	f.next(t, "B", OpMovementStop)
	f.next(t, "A", OpMovementStop)
	if got := ask(); !bytes.Equal(got, exchangeResult(ExchangeErrTooFar)) {
		t.Fatalf("after a refused claim: % x, want too far", got)
	}
}
