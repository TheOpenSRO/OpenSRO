package session

import (
	"bufio"
	"bytes"
	"context"
	"net"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
	"github.com/OpenSRO/OpenSRO/server/internal/worldclock"
)

// The two layouts, byte for byte (READ: SR_GameServer 0x4e3eb0 appends 4, 2,
// 1 and 1 bytes; 0x4f8240 appends 2, 1 and 1).
func TestRound786CelestialPayloads(t *testing.T) {
	ts := worldclock.Time{Day: 0x0506, Hour: 7, Minute: 8, Second: 59}
	if got, want := EncodeCelestialPosition(0x01020304, ts), []byte{0x04, 0x03, 0x02, 0x01, 0x06, 0x05, 0x07, 0x08}; !bytes.Equal(got, want) {
		t.Fatalf("0x3020 payload %x, want %x", got, want)
	}
	if got, want := EncodeCelestialUpdate(ts), []byte{0x06, 0x05, 0x07, 0x08}; !bytes.Equal(got, want) {
		t.Fatalf("0x3027 payload %x, want %x", got, want)
	}
	if OpCelestialPosition != 0x3020 || OpCelestialUpdate != 0x3027 {
		t.Fatalf("opcodes %#x %#x", OpCelestialPosition, OpCelestialUpdate)
	}
}

type celestialRig struct {
	t      *testing.T
	addr   string
	hub    *world.Hub
	chars  character.Store
	accts  *account.MemStore
	cancel context.CancelFunc
}

func newCelestialRig(t *testing.T) *celestialRig {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	chars := character.NewMemStore()
	eq := equipment.NewMemStore(inventory.NewMemStore(nil))
	hub := world.NewHub()
	handle := gateway.Chain(LoginHandler(accounts), WorldHandlerWithHook(chars, eq, hub, nil, nil))
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()
	srv := &gateway.Server{Addr: addr, Handle: handle, OnDisconnect: WorldDisconnectHandler(hub, nil)}
	srvCtx, cancel := context.WithCancel(ctx)
	t.Cleanup(cancel)
	go srv.ListenAndServe(srvCtx)
	return &celestialRig{t: t, addr: addr, hub: hub, chars: chars, accts: accounts, cancel: cancel}
}

type celestialClient struct {
	t    *testing.T
	conn net.Conn
	r    *bufio.Reader
	id   int64
}

// enter registers user, makes a character and sends OpEnterWorld; it reads
// up to and including the result and returns the client.
func (rig *celestialRig) enter(user, name string) *celestialClient {
	t := rig.t
	t.Helper()
	ctx := context.Background()
	if _, err := rig.accts.Register(ctx, user, "pw"); err != nil {
		t.Fatalf("Register: %v", err)
	}
	acct, _ := rig.accts.Authenticate(ctx, user, "pw")
	c, err := rig.chars.Create(ctx, acct.ID, name)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	// Raw: dialTestServer drops OpSelfID, which these tests read as the end
	// of the entry's frames.
	conn := dialTestServerRaw(t, rig.addr)
	t.Cleanup(func() { conn.Close() })
	cl := &celestialClient{t: t, conn: conn, r: bufio.NewReader(conn), id: c.ID}
	cl.write(OpLogin, (&LoginRequest{Username: user, Password: "pw"}).Encode())
	cl.read()
	cl.write(OpEnterWorld, (&EnterWorldRequest{CharacterName: name}).Encode())
	if p := cl.read(); p.Opcode != OpEnterWorldResult {
		t.Fatalf("got %#x, want the enter result", p.Opcode)
	}
	return cl
}

func (c *celestialClient) write(op uint16, data []byte) {
	c.t.Helper()
	if err := proto.Write(c.conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
		c.t.Fatalf("Write: %v", err)
	}
}

func (c *celestialClient) read() *proto.Packet {
	c.t.Helper()
	c.conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	p, err := proto.Read(c.r, nil, nil)
	if err != nil {
		c.t.Fatalf("Read: %v", err)
	}
	return p
}

// until reads frames until op (returning it) or stop (returning nil), and
// counts the frames of opcode count it passed.
func (c *celestialClient) until(op, stop, count uint16) (*proto.Packet, int) {
	c.t.Helper()
	n := 0
	for i := 0; i < 64; i++ {
		p := c.read()
		if p.Opcode == count {
			n++
		}
		if p.Opcode == op {
			return p, n
		}
		if p.Opcode == stop {
			return nil, n
		}
	}
	c.t.Fatalf("neither %#x nor %#x in 64 frames", op, stop)
	return nil, n
}

func withClock(t *testing.T, on bool, c *worldclock.Clock) {
	t.Helper()
	before, beforeOn := GameClock(), clockAtEntry.Load()
	t.Cleanup(func() { SetGameClock(before); clockAtEntry.Store(beforeOn) })
	SetGameClock(c)
	clockAtEntry.Store(on)
}

// 0x3020 is the frame right after the enter-world result (READ: EnterGame
// sends it right after the character data, which the result stands in for),
// once, carrying the uid and the clock's day, hour and minute.
func TestRound786ClockFollowsTheEnterWorldResult(t *testing.T) {
	// A clock that reads day 2, 14:30 now: the test runs well inside one game
	// minute (1.2 s), and the minute is checked against both ends of it.
	withClock(t, true, worldclock.New(time.Now(), 2, 14, 30))
	rig := newCelestialRig(t)
	cl := rig.enter("alice", "Aria")
	p := cl.read()
	if p.Opcode != OpCelestialPosition {
		t.Fatalf("the frame after the result is %#x, want 0x3020", p.Opcode)
	}
	if len(p.Data) != 8 {
		t.Fatalf("0x3020 is %d bytes, want 8", len(p.Data))
	}
	want := EncodeCelestialPosition(uint32(cl.id), worldclock.Time{Day: 2, Hour: 14, Minute: 30})
	next := EncodeCelestialPosition(uint32(cl.id), worldclock.Time{Day: 2, Hour: 14, Minute: 31})
	if !bytes.Equal(p.Data, want) && !bytes.Equal(p.Data, next) {
		t.Fatalf("0x3020 %x, want %x (or the next minute %x)", p.Data, want, next)
	}
	// Once: nothing else carries the clock before the entry's own id frame.
	if _, more := cl.until(OpSelfID, 0xffff, OpCelestialPosition); more != 0 {
		t.Fatalf("%d more 0x3020 before OpSelfID, want none", more)
	}
}

// -world-clock off: no clock frame at all (the kill switch; the client keeps
// its fixed midday).
func TestRound786ClockOffSendsNothing(t *testing.T) {
	withClock(t, false, worldclock.New(time.Now(), 0, 9, 0))
	rig := newCelestialRig(t)
	cl := rig.enter("alice", "Aria")
	if _, n := cl.until(OpSelfID, 0xffff, OpCelestialPosition); n != 0 {
		t.Fatalf("%d 0x3020 with -world-clock off, want none", n)
	}
}

// The operator's set-hour reaches every character in the world as 0x3027,
// with the day and the minute kept (READ, 0x412be0 -> 0x530d60).
func TestRound786SetHourIsBroadcast(t *testing.T) {
	withClock(t, true, worldclock.New(time.Now(), 4, 2, 17))
	rig := newCelestialRig(t)
	a := rig.enter("alice", "Aria")
	b := rig.enter("bob", "Bram")
	a.until(OpSelfID, 0xffff, 0)
	b.until(OpSelfID, 0xffff, 0)
	got, told := SetWorldHour(rig.hub, 19, time.Now())
	if told != 2 {
		t.Fatalf("told %d, want 2", told)
	}
	if got.Day != 4 || got.Hour != 19 || (got.Minute != 17 && got.Minute != 18) || got.Second != 0 {
		t.Fatalf("clock after /hour 19: %v, want day 4 19:17:00", got)
	}
	for _, c := range []*celestialClient{a, b} {
		p, _ := c.until(OpCelestialUpdate, 0xffff, 0)
		if !bytes.Equal(p.Data, EncodeCelestialUpdate(got)) {
			t.Fatalf("0x3027 %x, want %x", p.Data, EncodeCelestialUpdate(got))
		}
	}
	if now := GameClock().At(time.Now()); now.Hour != 19 {
		t.Fatalf("the clock runs on from 19, read %v", now)
	}
}
