package retailsrv

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log/slog"
	"net"
	"strconv"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/retailgw"
	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
)

// The test client: the archive's values as the render box MEASURED them.
var info = retailgw.ClientInfo{ContentID: 22, Version: 1000}

type harness struct {
	t        *testing.T
	cfg      *Config
	accounts *account.MemStore
	chars    *character.MemStore
	gwAddr   string
	agAddr   string
	now      time.Time
}

func freeAddr(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	return ln.Addr().String()
}

func waitListening(t *testing.T, addr string) {
	t.Helper()
	for range 200 {
		if c, err := net.Dial("tcp", addr); err == nil {
			c.Close()
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("%s never listened", addr)
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	return newHarnessWith(t, nil)
}

// newHarnessWith is newHarness on login (nil: a bare LoginService on the
// harness's accounts), whose SessionEnded the agent's disconnects run (round
// 788, lane S: the logged-in table).
func newHarnessWith(t *testing.T, login func(*account.MemStore) *session.LoginService) *harness {
	t.Helper()
	return newHarnessLobby(t, login, nil)
}

// newHarnessLobby is newHarnessWith with the lobby handler wrapped (nil: as
// is) -- main.go hands the agent the lobby behind the account PIN's gate.
func newHarnessLobby(t *testing.T, login func(*account.MemStore) *session.LoginService, wrap func(gateway.Handler) gateway.Handler) *harness {
	t.Helper()
	h := &harness{t: t, accounts: account.NewMemStore(), chars: character.NewMemStore(), now: time.Now()}
	h.gwAddr, h.agAddr = freeAddr(t), freeAddr(t)
	_, portStr, _ := net.SplitHostPort(h.agAddr)
	port, _ := strconv.Atoi(portStr)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	h.cfg = &Config{
		ContentID: 22, Version: 1000, ShardID: 7, ShardName: "OpenSRO", FarmName: "OpenSRO",
		AgentHost: "127.0.0.1", AgentPort: uint16(port),
		Status: func() session.ServerStatus { return session.ServerStatus{Current: 3, Max: 500} },
		Login:  &session.LoginService{Accounts: h.accounts},
		Lobby:  session.LobbyHandler(session.LobbyDeps{Chars: h.chars, Logger: logger}),
		Tokens: &Tokens{Now: func() time.Time { return h.now }},
		Logger: logger,
	}
	if wrap != nil {
		h.cfg.Lobby = wrap(h.cfg.Lobby)
	}
	var ended func(*gateway.Session)
	if login != nil {
		h.cfg.Login = login(h.accounts)
		ended = h.cfg.Login.SessionEnded
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{}, 2)
	for _, s := range []*gateway.Server{GatewayServer(h.cfg, h.gwAddr), AgentServer(h.cfg, h.agAddr, ended)} {
		go func(s *gateway.Server) { _ = s.ListenAndServe(ctx); done <- struct{}{} }(s)
	}
	t.Cleanup(func() { cancel(); <-done; <-done })
	waitListening(t, h.gwAddr)
	waitListening(t, h.agAddr)
	return h
}

func (h *harness) dial(addr string) *retailgw.ClientConn {
	h.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	h.t.Cleanup(cancel)
	c, err := retailgw.DialClient(ctx, addr, info)
	if err != nil {
		h.t.Fatalf("handshake with %s: %v", addr, err)
	}
	h.t.Cleanup(func() { c.Close() })
	return c
}

// gatewayReady runs the gateway as the client does up to the list: the
// identity, 0x6100 and 0x6101.
func (h *harness) gatewayReady() (*retailgw.ClientConn, retailgw.ShardList) {
	h.t.Helper()
	c := h.dial(h.gwAddr)
	if name, err := c.ReadIdentity(); err != nil || name != GatewayModule {
		h.t.Fatalf("gateway identity %q, %v", name, err)
	}
	h.send(c, OpPatchRequest, retailgw.EncodePatchRequest(info.ContentID, info.Version))
	m := h.expect(c, OpPatchReply)
	if !m.Massive || !bytes.Equal(m.Payload, []byte{1}) {
		h.t.Fatalf("0xA100 %+v, want a massive [1]", m)
	}
	h.send(c, OpShardListReq, nil)
	m = h.expect(c, OpShardList)
	l, err := retailgw.DecodeShardList(m.Payload, true)
	if err != nil {
		h.t.Fatalf("0xA101: %v", err)
	}
	return c, l
}

func (h *harness) send(c *retailgw.ClientConn, op uint16, payload []byte) {
	h.t.Helper()
	if err := c.Send(op, payload, true); err != nil {
		h.t.Fatalf("send 0x%04x: %v", op, err)
	}
}

func (h *harness) expect(c *retailgw.ClientConn, op uint16) retailgw.Message {
	h.t.Helper()
	m, err := c.Expect(op)
	if err != nil {
		h.t.Fatalf("0x%04x: %v", op, err)
	}
	return m
}

func (h *harness) login(c *retailgw.ClientConn, user, pw string, shard uint16) *session.LoginAck {
	h.t.Helper()
	req := session.GatewayLoginRequest{ContentID: info.ContentID, Username: user, Password: pw, ShardID: shard}
	h.send(c, OpLogin, req.Encode())
	m := h.expect(c, OpLoginReply)
	ack, err := session.DecodeLoginAck(m.Payload)
	if err != nil {
		h.t.Fatalf("0xA102: %v", err)
	}
	// READ: a success goes encrypted (0x405e7d), the handler's refusals plain.
	if m.Encrypted != ack.OK {
		h.t.Errorf("0xA102 ok=%v sent encrypted=%v", ack.OK, m.Encrypted)
	}
	return ack
}

func TestGatewayListsOurShard(t *testing.T) {
	h := newHarness(t)
	_, l := h.gatewayReady()
	want := retailgw.ShardList{
		Farms:  []retailgw.Farm{{ID: 1, Name: "OpenSRO"}},
		Shards: []retailgw.Shard{{ID: 7, Name: "OpenSRO", Current: 3, Capacity: 500, State: 1, Farm: 1}},
	}
	if fmt.Sprint(l) != fmt.Sprint(want) {
		t.Fatalf("list %+v, want %+v", l, want)
	}
}

func TestGatewayRefusesAnotherClient(t *testing.T) {
	h := newHarness(t)
	for _, tc := range []struct {
		name string
		cid  byte
		ver  uint32
		want []byte
	}{
		// READ (0x4051a0): the content id is only logged; a newer client or
		// version 0 is [2, 1]; an older one with no patch server [2, 3].
		{"content id", 9, 1000, []byte{1}},
		{"newer", 22, 1001, []byte{2, 1}},
		{"zero", 22, 0, []byte{2, 1}},
		{"older", 22, 999, []byte{2, 3}},
	} {
		c := h.dial(h.gwAddr)
		if _, err := c.ReadIdentity(); err != nil {
			t.Fatal(err)
		}
		h.send(c, OpPatchRequest, retailgw.EncodePatchRequest(tc.cid, tc.ver))
		m := h.expect(c, OpPatchReply)
		if !bytes.Equal(m.Payload, tc.want) || !m.Massive {
			t.Errorf("%s: 0xA100 %v (massive %v), want massive %v", tc.name, m.Payload, m.Massive, tc.want)
		}
		if tc.want[0] != 1 {
			// Refused: the list is not given.
			h.send(c, OpShardListReq, nil)
			if m, err := c.Recv(); err == nil {
				t.Errorf("%s: 0x6101 after a refusal answered 0x%04x", tc.name, m.Opcode)
			}
		}
	}
}

// TestGatewayNoticesAndFarms: 0xA104 with no notice is a massive [0], 0xA106
// a plain [0] (READ 0x406380 / 0x405740).
func TestGatewayNoticesAndFarms(t *testing.T) {
	h := newHarness(t)
	c, _ := h.gatewayReady()
	h.send(c, OpNoticeRequest, []byte{22})
	if m := h.expect(c, OpNoticeReply); !m.Massive || !bytes.Equal(m.Payload, []byte{0}) {
		t.Errorf("0xA104 %+v", m)
	}
	h.send(c, OpFarmRequest, nil)
	if m := h.expect(c, OpFarmReply); m.Massive || m.Encrypted || !bytes.Equal(m.Payload, []byte{0}) {
		t.Errorf("0xA106 %+v", m)
	}
}

func TestGatewayLoginOutcomes(t *testing.T) {
	h := newHarness(t)
	if _, err := h.accounts.Add("Alice", "secret"); err != nil {
		t.Fatal(err)
	}
	if _, err := h.accounts.Add("bob", "pw"); err != nil {
		t.Fatal(err)
	}
	_ = h.accounts.SetBlocked("bob", true, "")
	c, _ := h.gatewayReady()

	if ack := h.login(c, "Alice", "wrong", 7); ack.OK || ack.Code != session.LoginErrPassword {
		t.Errorf("wrong password: %+v", ack)
	}
	if ack := h.login(c, "bob", "pw", 7); ack.OK || ack.Code != session.LoginErrBlocked {
		t.Errorf("blocked: %+v", ack)
	}
	if ack := h.login(c, "Alice", "secret", 8); ack.OK || ack.Code != session.LoginErrNoShard {
		t.Errorf("another shard: %+v", ack)
	}
	ack := h.login(c, "Alice", "secret", 7)
	if !ack.OK || ack.Token == 0 || ack.AgentHost != "127.0.0.1" || int(ack.AgentPort) != int(h.cfg.AgentPort) {
		t.Fatalf("ok: %+v", ack)
	}
	if h.cfg.Tokens.Len() != 1 {
		t.Errorf("%d logins queued, want 1", h.cfg.Tokens.Len())
	}
}

// TestRetailLoginToTheCharacterList drives the whole path the original client
// takes: gateway, token, agent, the list, and a refused Start.
func TestRetailLoginToTheCharacterList(t *testing.T) {
	h := newHarness(t)
	acc, err := h.accounts.Add("Alice", "secret")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.chars.CreateCharacter(context.Background(), acc.ID, character.NewCharacter{Name: "Hero", RefObjID: 1907, Scale: 0x22, Gender: "male"}); err != nil {
		t.Fatal(err)
	}
	gw, _ := h.gatewayReady()
	ack := h.login(gw, "Alice", "secret", 7)
	if !ack.OK {
		t.Fatalf("login: %+v", ack)
	}
	gw.Close()

	ag := h.dial(net.JoinHostPort(ack.AgentHost, strconv.Itoa(int(ack.AgentPort))))
	if name, err := ag.ReadIdentity(); err != nil || name != AgentModule {
		t.Fatalf("agent identity %q, %v", name, err)
	}
	// The ID lower-cased, as the client sends it (READ 0x4c9374).
	req := AgentLogin{Token: ack.Token, ID: "alice", PW: "secret", ContentID: 22}
	h.send(ag, OpAgentLogin, req.Encode())
	if m := h.expect(ag, OpAgentLoginReply); !bytes.Equal(m.Payload, []byte{1}) || !m.Encrypted {
		t.Fatalf("0xA103 %v (encrypted %v), want an encrypted [1]", m.Payload, m.Encrypted)
	}
	// The client's keep-alive, unanswered (READ 0x42d2a0), in between.
	if err := ag.Send(OpKeepAlive, nil, false); err != nil {
		t.Fatal(err)
	}
	// The select screen's requests go plain (READ: only 0x704C is encrypted,
	// 0x841590).
	plain := func(op uint16, payload []byte) {
		t.Helper()
		if err := ag.Send(op, payload, false); err != nil {
			t.Fatal(err)
		}
	}
	plain(OpLobby, (&session.LobbyRequest{Action: session.LobbyList}).Encode())
	m := h.expect(ag, OpLobbyResult)
	r, err := session.DecodeLobbyResult(m.Payload)
	if err != nil || !r.OK || len(r.Characters) != 1 || r.Characters[0].Name != "Hero" || m.Encrypted || m.Massive {
		t.Fatalf("list %+v, %v (encrypted %v, massive %v)", r, err, m.Encrypted, m.Massive)
	}
	plain(OpStart, (&session.StartRequest{Name: "Hero"}).Encode())
	sr, err := session.DecodeStartResult(h.expect(ag, OpStartResult).Payload)
	if err != nil || sr.OK || sr.Code != StartRefusal {
		t.Fatalf("start %+v, %v; want refused with 0x%x", sr, err, StartRefusal)
	}
	// The list follows unasked (OURS: it unlocks the select screen) ...
	m, err = ag.Recv()
	if err != nil || m.Opcode != OpLobbyResult {
		t.Fatalf("after the refusal: 0x%04x, %v; want the list", m.Opcode, err)
	}
	if r, err := session.DecodeLobbyResult(m.Payload); err != nil || !r.OK || r.Action != session.LobbyList || len(r.Characters) != 1 {
		t.Fatalf("the list after the refusal: %+v, %v", r, err)
	}
	// ... and the session stays: Start can be pressed again.
	plain(OpStart, (&session.StartRequest{Name: "Hero"}).Encode())
	h.expect(ag, OpStartResult)
}

func TestAgentRefusals(t *testing.T) {
	h := newHarness(t)
	if _, err := h.accounts.Add("alice", "secret"); err != nil {
		t.Fatal(err)
	}
	token := func() uint32 {
		gw, _ := h.gatewayReady()
		ack := h.login(gw, "alice", "secret", 7)
		if !ack.OK {
			t.Fatalf("login: %+v", ack)
		}
		gw.Close()
		return ack.Token
	}
	// agentLogin returns the 0xA103 and checks that a refusal ends the
	// connection (READ 0x402608).
	agentLogin := func(req AgentLogin) []byte {
		t.Helper()
		ag := h.dial(h.agAddr)
		if _, err := ag.ReadIdentity(); err != nil {
			t.Fatal(err)
		}
		h.send(ag, OpAgentLogin, req.Encode())
		m := h.expect(ag, OpAgentLoginReply)
		if !m.Encrypted {
			t.Errorf("0xA103 %v went plain", m.Payload)
		}
		if m.Payload[0] != 1 {
			if next, err := ag.Recv(); err == nil {
				t.Errorf("after a refusal: 0x%04x, want the connection closed", next.Opcode)
			}
		}
		return m.Payload
	}
	if got := agentLogin(AgentLogin{Token: 12345, ID: "alice", PW: "secret", ContentID: 22}); !bytes.Equal(got, []byte{2, 3}) {
		t.Errorf("unknown token: %v, want [2 3]", got)
	}
	tok := token()
	if got := agentLogin(AgentLogin{Token: tok, ID: "alice", PW: "other", ContentID: 22}); !bytes.Equal(got, []byte{2, 1}) {
		t.Errorf("wrong password: %v, want [2 1]", got)
	}
	if got := agentLogin(AgentLogin{Token: tok, ID: "alice", PW: "secret", ContentID: 22}); !bytes.Equal(got, []byte{2, 3}) {
		t.Errorf("a spent token: %v, want [2 3]", got)
	}
	tok = token()
	h.now = h.now.Add(DefaultTokenTTL + time.Second)
	if got := agentLogin(AgentLogin{Token: tok, ID: "alice", PW: "secret", ContentID: 22}); !bytes.Equal(got, []byte{2, 3}) {
		t.Errorf("an expired token: %v, want [2 3]", got)
	}
	// Another content id: no reply, the connection ends (READ 0x402225).
	tok = token()
	ag := h.dial(h.agAddr)
	if _, err := ag.ReadIdentity(); err != nil {
		t.Fatal(err)
	}
	h.send(ag, OpAgentLogin, (&AgentLogin{Token: tok, ID: "alice", PW: "secret", ContentID: 9}).Encode())
	if m, err := ag.Recv(); err == nil {
		t.Errorf("another content id: got 0x%04x, want the connection closed", m.Opcode)
	}
	// The lobby before 0x6103: dropped, no reply (READ 0x4315d0). A second
	// 0x2001 after it is answered, so the two identities arrive back to back
	// with nothing for the list between them.
	ag = h.dial(h.agAddr)
	if err := ag.Send(OpLobby, (&session.LobbyRequest{Action: session.LobbyList}).Encode(), false); err != nil {
		t.Fatal(err)
	}
	h.send(ag, OpIdentity, retailgw.EncodeIdentity(retailgw.ClientModule, 0))
	for i := range 2 {
		if m, err := ag.Recv(); err != nil || m.Opcode != OpIdentity {
			t.Errorf("message %d after a lobby message before login: 0x%04x, %v; want the identity", i, m.Opcode, err)
		}
	}
}
