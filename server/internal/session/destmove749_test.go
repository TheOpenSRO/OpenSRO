package session

import (
	"bufio"
	"bytes"
	"math"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/pcspawn"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// Round 749: moving by destination (destmove.go). Aria and Bram enter the
// dead-world fixture at jangan's spawnPos, world (0, 0, 0): region 97/168
// (0x61a8), local (960, 960).

const janganRegion uint16 = 0x61a8

// stopWorld reads a 0xB023 (OpMovementStop) payload back into zone's frame:
// the character (the uid's low 32 bits), its position in the world frame and
// its heading.
func stopWorld(t testing.TB, zone string, data []byte) (id int64, pos world.Position, heading float64) {
	t.Helper()
	s, ok := DecodeMoveStop(data)
	if !ok {
		t.Fatalf("0xB023 of %d bytes does not decode", len(data))
	}
	x, z := worldOfRegionLocal(zone, s.Region, float64(s.X), float64(s.Z))
	return int64(s.UID), world.Position{X: x, Y: float64(s.Y), Z: z}, world.HeadingFromWire(s.Angle)
}

// nearPos reports whether a and b agree on x, y and z to within eps.
func nearPos(a, b world.Position, eps float64) bool {
	return math.Abs(a.X-b.X) <= eps && math.Abs(a.Y-b.Y) <= eps && math.Abs(a.Z-b.Z) <= eps
}

// strictPositions turns -trust-client-positions off for one test (the suite
// runs with it on: TestMain).
func strictPositions(t *testing.T) {
	t.Helper()
	trustPositions.Store(false)
	t.Cleanup(func() { trustPositions.Store(true) })
}

// clickTo is a 0x7021 to the world point (x, y, z) of jangan, as the client
// builds it: the region and the local coordinates truncated (0x9ec080).
func clickTo(x, y, z float64) []byte {
	region, lx, lz := regionLocalOf(spawnZone, world.Position{X: x, Z: z})
	return (&proto.Movement{Kind: 1, Region: region, LocalX: int16(lx), LocalY: int16(y), LocalZ: int16(lz)}).Encode()
}

// readOp reads frames from conn until one of opcode op (failing on a
// timeout) and returns it; anything else read on the way is returned too.
func readOp(t *testing.T, f *deadWorldFixture, conn net.Conn, r *bufio.Reader, op uint16) (*proto.Packet, []*proto.Packet) {
	t.Helper()
	var skipped []*proto.Packet
	for i := 0; i < 50; i++ {
		p := f.read(t, conn, r)
		if p.Opcode == op {
			return p, skipped
		}
		skipped = append(skipped, p)
	}
	t.Fatalf("no %#04x in 50 frames", op)
	return nil, nil
}

// The two payloads, byte for byte (READ: 0xB021's asm 0x4b0ff8..0x4b1197 and
// its client reader 0x8a5750; 0xB023's FUN_004a9430 + FUN_00487c80 and its
// client reader FUN_008a4f80, 4 + 2 + 0xe bytes).
func TestRound749TheEchoAndTheStopAreRetailsBytes(t *testing.T) {
	mv := &proto.Movement{Kind: 1, Region: janganRegion, LocalX: 1000, LocalY: -3, LocalZ: 900}
	got := encodeMoveEcho(0x01020304, movementBytes(mv, 0), janganRegion, world.Position{Y: 5.5}, 960.25, 959.9)
	want := []byte{
		0x04, 0x03, 0x02, 0x01, // uid
		0x01, 0xa8, 0x61, 0xe8, 0x03, 0xfd, 0xff, 0x84, 0x03, // kind 1, region, i16 x y z
		0x01,       // flag: the source follows
		0xa8, 0x61, // source region
		0x82, 0x25, // x * 10 = 9602
		0x00, 0x00, 0xb0, 0x40, // y 5.5
		0x7f, 0x25, // z * 10 = 9599
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("0xB021 = % x\nwant      % x", got, want)
	}
	e, ok := DecodeMoveEcho(got)
	if !ok || e.UID != 0x01020304 || e.Move.LocalX != 1000 || e.Move.LocalY != -3 || e.Flag != 1 || e.SrcX != 9602 || e.SrcZ != 9599 || e.SrcY != 5.5 {
		t.Fatalf("decoded %+v %+v", e, e.Move)
	}
	// The heading form carries the wire angle as it came.
	if got := movementBytes(&proto.Movement{Kind: 0, HeadingByte: 1}, 0xbeef); !bytes.Equal(got, []byte{0, 1, 0xef, 0xbe}) {
		t.Fatalf("heading form % x", got)
	}
	stop := encodeMoveStop(world.Entity{CharacterID: 0x0a0b0c0d, Zone: spawnZone, Pos: world.Position{Y: 5}, Heading: math.Pi / 2})
	wantStop := []byte{
		0x0d, 0x0c, 0x0b, 0x0a, // uid
		0xa8, 0x61, // region 97/168
		0x00, 0x00, 0x70, 0x44, // x 960
		0x00, 0x00, 0xa0, 0x40, // y 5
		0x00, 0x00, 0x70, 0x44, // z 960
		0x00, 0x00, // heading pi/2 is wire angle 0
	}
	if !bytes.Equal(stop, wantStop) {
		t.Fatalf("0xB023 = % x\nwant      % x", stop, wantStop)
	}
}

// A click is answered with one 0xB021 to the window, the mover included,
// carrying the destination as asked and the source where the server had the
// mover; the hub then has the leg, and positions follow it.
func TestRound749AClickIsEchoedToTheWindowAndTheMover(t *testing.T) {
	f := startDeadWorldFixture(t)
	var now atomic.Int64
	now.Store(time.Now().UnixNano())
	f.hub.SetClock(func() time.Time { return time.Unix(0, now.Load()) })
	t.Cleanup(func() { f.hub.SetClock(nil) })
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(40, 2, 0))
	for _, side := range []struct {
		conn net.Conn
		r    *bufio.Reader
	}{{f.connA, f.rA}, {f.connB, f.rB}} {
		p := f.read(t, side.conn, side.r)
		if p.Opcode != proto.OpMovementResponse {
			t.Fatalf("got %#04x, want 0xB021", p.Opcode)
		}
		e, ok := DecodeMoveEcho(p.Data)
		if !ok || int64(e.UID) != f.aria || e.Move.Kind != 1 || e.Move.Region != janganRegion || e.Move.LocalX != 1000 || e.Move.LocalY != 2 || e.Move.LocalZ != 960 {
			t.Fatalf("echo %+v %+v", e, e.Move)
		}
		if e.Flag != 1 || e.SrcRegion != janganRegion || e.SrcX != 9600 || e.SrcZ != 9600 {
			t.Fatalf("echo source %+v", e)
		}
	}
	e, _ := f.hub.EntityByCharacterID(f.aria)
	if e.Move == nil || e.Move.Dest != (world.Position{X: 40, Y: 2, Z: 0}) || e.Move.Speed != PlayerRunSpeed {
		t.Fatalf("the hub's leg %+v", e.Move)
	}
	if math.Abs(e.Heading-math.Pi/2) > 1e-9 {
		t.Fatalf("Aria faces %v, want pi/2 (toward +x)", e.Heading)
	}
	now.Add(int64(300 * time.Millisecond))
	if e, _ := f.hub.EntityByCharacterID(f.aria); math.Abs(e.Pos.X-15) > 1e-9 || math.Abs(e.Pos.Y-0.75) > 1e-9 {
		t.Fatalf("0.3 s into a 0.8 s leg Aria is at %+v, want (15, 0.75, 0)", e.Pos)
	}
	now.Add(int64(700 * time.Millisecond))
	if e, _ := f.hub.EntityByCharacterID(f.aria); e.Pos != (world.Position{X: 40, Y: 2}) || e.Move != nil {
		t.Fatalf("after the leg Aria is at %+v (leg %v)", e.Pos, e.Move)
	}
	// Nothing on arrival (READ: the stop FUN_004a9430(angle, 0) sends none).
	if !f.nothing(t, f.connA, f.rA) || !f.nothing(t, f.connB, f.rB) {
		t.Fatal("something was sent at the arrival")
	}
}

// The handler's gates (READ, GObjPC::FUN_004b0ea0), each refused silently.
func TestRound749TheClickGatesRefuseSilently(t *testing.T) {
	f := startDeadWorldFixture(t)
	quiet := func(what string, data []byte) {
		t.Helper()
		f.send(t, f.connA, proto.OpMovementRequest, data)
		if !f.nothing(t, f.connA, f.rA) || !f.nothing(t, f.connB, f.rB) {
			t.Fatalf("%s was answered", what)
		}
	}
	quiet("kind 2", append([]byte{2}, clickTo(40, 0, 0)[1:]...))
	// Region 97/170: two regions away (FUN_0048c2d0).
	quiet("a destination outside the 3 x 3 regions", (&proto.Movement{Kind: 1, Region: 0x61aa, LocalX: 10, LocalZ: 10}).Encode())
	quiet("a dungeon destination", (&proto.Movement{Kind: 1, Region: 0x8001, X: 1, Z: 1}).Encode())
	quiet("a turn-only heading command", []byte{0, 0x10, 0, 0})
	if e, _ := f.hub.EntityByCharacterID(f.aria); e.Move != nil {
		t.Fatal("a refused click gave a leg")
	}
	// While moving, a destination within 5.0 of the one set (0xb45b28).
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(400, 0, 0))
	readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
	readOp(t, f, f.connB, f.rB, proto.OpMovementResponse)
	quiet("a destination 4 from the one set", clickTo(404, 0, 0))
	// The sit transition (CHANGEMOTION, 0x4b0f83).
	if _, ok := motions.request(f.aria, MotionSit, time.Now()); !ok {
		t.Fatal("setup: no sit")
	}
	quiet("a click in the sit transition", clickTo(100, 0, 100))
	motions.stand(f.aria, time.Now())
	// Dead.
	f.kill(t, f.aria, time.Now())
	quiet("a dead character's click", clickTo(-100, 0, 0))
}

// A stop short of the destination, on the leg: taken, the leg ends there, and
// the window hears 0xB023 -- not the mover, whose client is there.
func TestRound749AStopOnTheLegIsTakenAndRelayed(t *testing.T) {
	strictPositions(t)
	f := startDeadWorldFixture(t)
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(500, 0, 0))
	readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
	readOp(t, f, f.connB, f.rB, proto.OpMovementResponse)
	time.Sleep(100 * time.Millisecond)
	f.send(t, f.connA, OpMove, (&MoveRequest{X: 6, Y: 1, Z: 0.5, Stopped: true}).Encode())
	p := f.read(t, f.connB, f.rB)
	if p.Opcode != OpMovementStop {
		t.Fatalf("Bram got %#04x, want 0xB023", p.Opcode)
	}
	if id, at, h := stopWorld(t, spawnZone, p.Data); id != f.aria || !nearPos(at, world.Position{X: 6, Y: 1, Z: 0.5}, 1e-3) || math.Abs(h-math.Pi/2) > 1e-3 {
		t.Fatalf("Bram heard %d at %+v facing %v", id, at, h)
	}
	if !f.nothing(t, f.connA, f.rA) {
		t.Fatal("Aria was sent her own stop")
	}
	if e, _ := f.hub.EntityByCharacterID(f.aria); e.Move != nil || e.Pos.X != 6 {
		t.Fatalf("after the stop: %+v", e)
	}
}

// A stop the leg cannot have reached, or off it, is not taken: the leg ends
// where the server has it and everyone -- the mover too -- hears that.
func TestRound749AStopOffTheLegIsCorrected(t *testing.T) {
	strictPositions(t)
	f := startDeadWorldFixture(t)
	for _, stop := range []world.Position{{X: 300}, {X: 5, Z: 50}} {
		f.send(t, f.connA, proto.OpMovementRequest, clickTo(500, 0, 0))
		readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
		readOp(t, f, f.connB, f.rB, proto.OpMovementResponse)
		before, _ := f.hub.EntityByCharacterID(f.aria)
		f.send(t, f.connA, OpMove, (&MoveRequest{X: float32(stop.X), Z: float32(stop.Z), Stopped: true}).Encode())
		for _, side := range []struct {
			name string
			conn net.Conn
			r    *bufio.Reader
		}{{"Aria", f.connA, f.rA}, {"Bram", f.connB, f.rB}} {
			p := f.read(t, side.conn, side.r)
			if p.Opcode != OpMovementStop {
				t.Fatalf("stop at %+v: %s got %#04x, want the correction", stop, side.name, p.Opcode)
			}
			if _, at, _ := stopWorld(t, spawnZone, p.Data); math.Abs(at.Z-before.Pos.Z) > 1e-3 || at.X < before.Pos.X || at.X > before.Pos.X+30 {
				t.Fatalf("stop at %+v: %s told %+v, want the leg's point (from %+v)", stop, side.name, at, before.Pos)
			}
		}
		if e, _ := f.hub.EntityByCharacterID(f.aria); e.Move != nil || e.Pos.X > 50 {
			t.Fatalf("stop at %+v: the server's leg %+v at %+v", stop, e.Move, e.Pos)
		}
	}
}

// A relocation far from the server's position is refused, unless it is a
// point the server named: a GM's /tp, an arrival.
func TestRound749ARelocationOnlyThroughTheNamedPoints(t *testing.T) {
	strictPositions(t)
	f := startDeadWorldFixture(t)
	f.send(t, f.connA, OpMove, (&MoveRequest{X: 200, Y: 3, Z: 200, Relocated: true}).Encode())
	p := f.read(t, f.connA, f.rA)
	if p.Opcode != OpMovementStop {
		t.Fatalf("a far relocation: Aria got %#04x, want the correction", p.Opcode)
	}
	if _, at, _ := stopWorld(t, spawnZone, p.Data); !nearPos(at, world.Position{}, 1e-3) {
		t.Fatalf("the correction says %+v, want where she stood", at)
	}
	readOp(t, f, f.connB, f.rB, OpMovementStop)
	// The ground snap at the server's own point: taken.
	f.send(t, f.connA, OpMove, (&MoveRequest{X: 0.5, Y: 7, Z: 0, Relocated: true}).Encode())
	if p := f.read(t, f.connB, f.rB); p.Opcode != OpMovementStop {
		t.Fatalf("the ground snap reached Bram as %#04x", p.Opcode)
	}
	// A GM /tp names its point.
	noteGMLanding(f.aria, time.Now(), 200, 200)
	f.send(t, f.connA, OpMove, (&MoveRequest{X: 200, Y: 3, Z: 200.5, Relocated: true}).Encode())
	gmStop, _ := readOp(t, f, f.connB, f.rB, OpMovementStop)
	if _, at, _ := stopWorld(t, spawnZone, gmStop.Data); !nearPos(at, world.Position{X: 200, Y: 3, Z: 200.5}, 1e-3) {
		t.Fatalf("the GM point reached Bram as %+v", at)
	}
	if !f.nothing(t, f.connA, f.rA) {
		t.Fatal("Aria was answered a taken relocation")
	}
	// An arrival names its point and the client's spawn spot there.
	noteArrivalLanding(f.aria, spawnZone, world.Position{X: -300, Z: 100})
	f.send(t, f.connA, OpMove, (&MoveRequest{X: -300, Y: 1, Z: 100, Relocated: true}).Encode())
	if e, _ := f.hub.EntityByCharacterID(f.aria); e.Pos.X != -300 {
		// The move above is in flight; read Bram's relay to order it.
		readOp(t, f, f.connB, f.rB, OpMovementStop)
		if e, _ = f.hub.EntityByCharacterID(f.aria); e.Pos.X != -300 {
			t.Fatalf("the arrival point was not taken: %+v", e.Pos)
		}
	}
}

// A player who comes into view while another walks is spawned walking: the
// record carries the mover's destination (0x48be00, READ) and RUN.
func TestRound749ALateViewerSpawnsTheWalkerWalking(t *testing.T) {
	f := startDeadWorldFixture(t)
	if czr := changeZone(t, f, f.connB, f.rB, "donwhang"); !czr.OK {
		t.Fatalf("Bram's change: %+v", czr)
	}
	expectPlayerDespawn(t, f.connA, f.rA, f.bram)
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(300, 4, -200))
	readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
	if czr := changeZone(t, f, f.connB, f.rB, "jangan"); !czr.OK {
		t.Fatalf("Bram's change back: %+v", czr)
	}
	rec := expectPlayerSpawn(t, f.connB, f.rB, f.aria)[0]
	region, lx, lz := regionLocalOf(spawnZone, world.Position{X: 300, Z: -200})
	if !rec.HasDest || rec.DestRegion != region || rec.DestX != int16(lx) || rec.DestY != 4 || rec.DestZ != int16(lz) || rec.Motion != MotionRun {
		t.Fatalf("Aria's record while walking: dest %v %#x (%d, %d, %d) motion %d", rec.HasDest, rec.DestRegion, rec.DestX, rec.DestY, rec.DestZ, rec.Motion)
	}
}

// A heading run's record carries the mover's command and angle.
func TestRound749AHeadingRunnersRecordCarriesItsCommand(t *testing.T) {
	hub := world.NewHub()
	sess := gateway.NewTestSession(1)
	hub.Enter(sess, 77, "Runner", 1, spawnZone, world.Position{})
	hub.StartMove(sess, world.MoveOrder{Heading: true, HeadingRadians: world.HeadingFromWire(0x1234), Command: 1, WireAngle: 0x1234, Speed: 50})
	e, _ := hub.EntityByCharacterID(77)
	raw := playerRecord(viewDeps{hub: hub, chars: character.NewMemStore()}, e, time.Now())
	rec, _, err := pcspawn.Decode(raw, nil)
	if err != nil || rec.HasDest || rec.MoveCommand != 1 || rec.MoveAngle != 0x1234 || rec.Motion != MotionRun {
		t.Fatalf("%v: %+v", err, rec)
	}
}

// The mover pass: a leg that crosses block lines is refiled as it walks, and
// the players it walks into view of are spawned both ways -- mid-leg, so the
// record carries the destination.
func TestRound749TheMoverPassSpawnsWhoTheWalkerMeets(t *testing.T) {
	f := startDeadWorldFixture(t)
	moverPassAuto.Store(false)
	t.Cleanup(func() { moverPassAuto.Store(true) })
	var now atomic.Int64
	now.Store(time.Now().UnixNano())
	f.hub.SetClock(func() time.Time { return time.Unix(0, now.Load()) })
	t.Cleanup(func() { f.hub.SetClock(nil) })
	// Bram goes five blocks west: out of view.
	f.send(t, f.connB, OpMove, (&MoveRequest{X: -1450, Z: 0, Relocated: true}).Encode())
	expectPlayerDespawn(t, f.connA, f.rA, f.bram)
	expectPlayerDespawn(t, f.connB, f.rB, f.aria)
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(-1200, 0, 0))
	readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
	if !f.nothing(t, f.connB, f.rB) {
		t.Fatal("Bram, out of view, heard the click")
	}
	now.Add(int64(10 * time.Second)) // x -500: block -2, Bram's -5 out of view
	moverPass(f.hub)
	if !f.nothing(t, f.connA, f.rA) || !f.nothing(t, f.connB, f.rB) {
		t.Fatal("a crossing out of view sent something")
	}
	now.Add(int64(10 * time.Second)) // x -1000: block -4, in view of -5
	moverPass(f.hub)
	expectPlayerSpawn(t, f.connA, f.rA, f.bram)
	rec := expectPlayerSpawn(t, f.connB, f.rB, f.aria)[0]
	if !rec.HasDest || rec.Motion != MotionRun {
		t.Fatalf("Aria spawned to Bram mid-leg without her destination: %+v", rec)
	}
	if f.hub.Moving() != 1 {
		t.Fatalf("%d movers, want Aria still walking", f.hub.Moving())
	}
	now.Add(int64(10 * time.Second))
	moverPass(f.hub)
	if f.hub.Moving() != 0 {
		t.Fatal("the leg did not end at its destination")
	}
}

// A sit while the server's leg still runs ends it where the server has it;
// the window hears that 0xB023, the sitter only the sit.
func TestRound749ASitEndsALegStillRunning(t *testing.T) {
	f := startDeadWorldFixtureWith(t, func(_ character.Store, hub *world.Hub) gateway.Handler { return MotionHandler(hub) })
	t.Cleanup(func() { motions.clear(f.aria) })
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(500, 0, 0))
	readOp(t, f, f.connA, f.rA, proto.OpMovementResponse)
	readOp(t, f, f.connB, f.rB, proto.OpMovementResponse)
	f.send(t, f.connA, OpMotionRequest, []byte{MotionSit})
	if p := f.read(t, f.connB, f.rB); p.Opcode != OpMovementStop {
		t.Fatalf("Bram got %#04x, want the halt's 0xB023 before the sit", p.Opcode)
	}
	if p := f.read(t, f.connB, f.rB); p.Opcode != OpStateChange {
		t.Fatalf("Bram got %#04x, want the sit", p.Opcode)
	}
	if p := f.read(t, f.connA, f.rA); p.Opcode != OpStateChange {
		t.Fatalf("Aria got %#04x, want only the sit", p.Opcode)
	}
	if e, _ := f.hub.EntityByCharacterID(f.aria); e.Move != nil {
		t.Fatal("the leg runs on under a sitter")
	}
}

// A walker does not regenerate until its leg ends (STAND regen needs the
// WALK/RUN state over: motion.go regenRate).
func TestRound749AWalkerRegeneratesOnlyOnceTheLegEnds(t *testing.T) {
	const id = 749749
	t.Cleanup(func() { motions.clear(id) })
	now := time.Now()
	motions.enter(id, now.Add(-time.Hour))
	motions.walking(id, now.Add(10*time.Second))
	if _, ok := motions.regenRate(id, now.Add(5*time.Second)); ok {
		t.Fatal("a walker regenerates mid-leg")
	}
	if _, ok := motions.regenRate(id, now.Add(11*time.Second)); !ok {
		t.Fatal("no regen after the leg")
	}
	motions.walking(id, now)
	if _, ok := motions.regenRate(id, now.Add(time.Second)); !ok {
		t.Fatal("no regen after a stop")
	}
}

// The OpMove flags: the stop bit rides alone or with the others, and an
// older decoder reads three floats.
func TestRound749TheStopFlag(t *testing.T) {
	b := (&MoveRequest{X: 1, Y: 2, Z: 3, Stopped: true}).Encode()
	if len(b) != 13 || b[12] != moveFlagStopped {
		t.Fatalf("% x", b)
	}
	got, err := DecodeMoveRequest(b)
	if err != nil || !got.Stopped || got.Relocated || got.Run || got.X != 1 {
		t.Fatalf("%+v %v", got, err)
	}
	both, _ := DecodeMoveRequest((&MoveRequest{Stopped: true, Relocated: true}).Encode())
	if !both.Stopped || !both.Relocated {
		t.Fatalf("%+v", both)
	}
	if plain, _ := DecodeMoveRequest((&MoveRequest{X: 1}).Encode()); plain.Stopped {
		t.Fatal("a plain position decoded as a stop")
	}
}

func TestRound749RegionsAdjacent(t *testing.T) {
	for _, c := range []struct {
		a, b uint16
		want bool
	}{{0x61a8, 0x61a8, true}, {0x61a8, 0x62a9, true}, {0x61a8, 0x60a7, true}, {0x61a8, 0x61aa, false}, {0x61a8, 0x63a8, false}} {
		if got := regionsAdjacent(c.a, c.b); got != c.want {
			t.Errorf("%#x %#x: %v", c.a, c.b, got)
		}
	}
}
