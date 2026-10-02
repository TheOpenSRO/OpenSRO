package session

import (
	"bufio"
	"bytes"
	"context"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
)

// Round 679 (OURS): the server list's status. The payload is retail's three
// shard-entry fields (current u16, max u16, state u8; READ) after a version
// byte; the handler answers before login, once per connection, and ends an
// unauthenticated asker's connection.
func TestServerStatusEncodeExact(t *testing.T) {
	for _, c := range []struct {
		s    ServerStatus
		want []byte
	}{
		{ServerStatus{Current: 50, Max: 100}, []byte{1, 50, 0, 100, 0, 1}},
		{ServerStatus{Current: 0x1234, Max: 1000, Inspection: true}, []byte{1, 0x34, 0x12, 0xe8, 0x03, 0}},
		{ServerStatus{Current: 70000, Max: -1}, []byte{1, 0xff, 0xff, 0, 0, 1}},
	} {
		if got := c.s.Encode(); !bytes.Equal(got, c.want) {
			t.Errorf("%+v encodes % x, want % x", c.s, got, c.want)
		}
	}
	got, err := DecodeServerStatus([]byte{1, 3, 0, 10, 0, 0})
	if err != nil || got != (ServerStatus{Current: 3, Max: 10, Inspection: true}) {
		t.Errorf("decoded %+v, %v", got, err)
	}
	for name, data := range map[string][]byte{"short": {1, 0, 0, 0, 0}, "long": {1, 0, 0, 0, 0, 1, 0}, "version 2": {2, 0, 0, 0, 0, 1}} {
		if _, err := DecodeServerStatus(data); err == nil {
			t.Errorf("%s: decoded without an error", name)
		}
	}
}

func TestServerStatusOpcodesAreNew(t *testing.T) {
	if OpServerStatusRequest != 0x0007 || OpServerStatus != 0x0008 {
		t.Errorf("status opcodes moved: %#04x/%#04x, the client sends 0x0007 and reads 0x0008", OpServerStatusRequest, OpServerStatus)
	}
	for _, op := range []uint16{OpLogin, OpLoginResult, OpRegister, OpRegisterResult, OpFrontEndThemeRequest, OpFrontEndTheme} {
		if op == OpServerStatusRequest || op == OpServerStatus {
			t.Errorf("opcode %#04x collides with the server status", op)
		}
	}
}

// Asked on a fresh connection: the status as it is at that moment, then the
// connection ends; the session is never logged in by asking.
func TestServerStatusHandlerOnAFreshSession(t *testing.T) {
	var current atomic.Int64
	current.Store(7)
	now := func() ServerStatus { return ServerStatus{Current: int(current.Load()), Max: 20} }
	addr := startThemeServer(t, gateway.Chain(ServerStatusHandler(now), FrontEndThemeHandler(FrontEndTheme{}), LoginHandler(account.NewMemStore())))
	ask := func() ServerStatus {
		t.Helper()
		conn := dialTheme(t, addr)
		r := bufio.NewReader(conn)
		if err := proto.Write(conn, &proto.Packet{Opcode: OpServerStatusRequest}, nil, nil); err != nil {
			t.Fatal(err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		p, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("no reply to OpServerStatusRequest (0x0007): %v", err)
		}
		if p.Opcode != OpServerStatus {
			t.Fatalf("reply opcode %#04x, want OpServerStatus 0x0008", p.Opcode)
		}
		s, err := DecodeServerStatus(p.Data)
		if err != nil {
			t.Fatal(err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		if p, err := proto.Read(r, nil, nil); err == nil {
			t.Errorf("unexpected extra frame %#04x", p.Opcode)
		} else if ne, ok := err.(net.Error); ok && ne.Timeout() {
			t.Errorf("the connection stayed open after the status")
		}
		return s
	}
	if s := ask(); s != (ServerStatus{Current: 7, Max: 20}) {
		t.Errorf("first answer %+v", s)
	}
	current.Store(19)
	if s := ask(); s.Current != 19 {
		t.Errorf("the status is read when asked: %+v", s)
	}
}

// The gate: under inspection, or full, a login is refused with retail's words
// and never reaches the login handler; otherwise the login goes through.
func TestLoginGate(t *testing.T) {
	store := account.NewMemStore()
	if _, err := store.Add("someone", "secret"); err != nil {
		t.Fatal(err)
	}
	var st atomic.Value
	st.Store(ServerStatus{Current: 0, Max: 2})
	var reached atomic.Int64
	counted := func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode == OpLogin {
			reached.Add(1)
		}
		return LoginHandler(store)(ctx, sess, p)
	}
	statusNow := func() ServerStatus { return st.Load().(ServerStatus) }
	staff := func(u string) bool { return u == "gm" }
	if _, err := store.Add("gm", "secret"); err != nil {
		t.Fatal(err)
	}
	addr := startThemeServer(t, LoginGate(statusNow, staff, counted))
	loginAs := func(user string) *LoginResult {
		t.Helper()
		conn := dialTheme(t, addr)
		if err := proto.Write(conn, &proto.Packet{Opcode: OpLogin, Data: (&LoginRequest{Username: user, Password: "secret"}).Encode()}, nil, nil); err != nil {
			t.Fatal(err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		p, err := proto.Read(bufio.NewReader(conn), nil, nil)
		if err != nil {
			t.Fatal(err)
		}
		res, err := DecodeLoginResult(p.Data)
		if err != nil {
			t.Fatal(err)
		}
		return res
	}
	login := func() *LoginResult { t.Helper(); return loginAs("someone") }
	if r := login(); !r.OK || reached.Load() != 1 {
		t.Errorf("an open server with room: %+v, reached %d", r, reached.Load())
	}
	st.Store(ServerStatus{Current: 0, Max: 2, Inspection: true})
	if r := login(); r.OK || r.Reason != LoginRefusedInspection || reached.Load() != 1 {
		t.Errorf("under inspection: %+v, reached %d", r, reached.Load())
	}
	st.Store(ServerStatus{Current: 2, Max: 2})
	if r := login(); r.OK || r.Reason != LoginRefusedFull || reached.Load() != 1 {
		t.Errorf("full: %+v, reached %d", r, reached.Load())
	}
	// Staff pass both (round 679's review).
	if r := loginAs("gm"); !r.OK || reached.Load() != 2 {
		t.Errorf("a GM account when full: %+v, reached %d", r, reached.Load())
	}
	st.Store(ServerStatus{Current: 0, Max: 2, Inspection: true})
	if r := loginAs("gm"); !r.OK || reached.Load() != 3 {
		t.Errorf("a GM account under inspection: %+v, reached %d", r, reached.Load())
	}
	st.Store(ServerStatus{Current: 1, Max: 2})
	if r := login(); !r.OK || reached.Load() != 4 {
		t.Errorf("room again: %+v, reached %d", r, reached.Load())
	}
}
