package session

// Round 788: LoginService's rules, each against its READ source
// (docs/protocol/opcodes/login.md, "The login reply, READ (round 788)").

import (
	"bufio"
	"bytes"
	"context"
	"encoding/hex"
	"errors"
	"io"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

var login788T0 = time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)

// login788Fixture is a service on a MemStore with alice/bob (password "pw")
// and gm (password "pw", staff), a settable clock and status, the wire's
// time zone UTC.
type login788Fixture struct {
	store  *account.MemStore
	svc    *LoginService
	now    time.Time
	status ServerStatus
}

func newLogin788(t *testing.T, rules LoginRules) *login788Fixture {
	t.Helper()
	f := &login788Fixture{store: account.NewMemStore(), now: login788T0}
	for _, n := range []string{"alice", "bob", "gm"} {
		if _, err := f.store.Add(n, "pw"); err != nil {
			t.Fatal(err)
		}
	}
	f.store.Now = func() time.Time { return f.now }
	f.svc = &LoginService{
		Accounts: f.store, Rules: rules, Online: NewOnlineAccounts(),
		Status: func() ServerStatus { return f.status },
		Staff:  func(u string) bool { return u == "gm" },
		Now:    func() time.Time { return f.now }, Location: time.UTC,
	}
	return f
}

func (f *login788Fixture) login(user, pw string, sess *gateway.Session, ip string) LoginOutcome {
	var remote net.Addr
	if ip != "" {
		remote = &net.TCPAddr{IP: net.ParseIP(ip), Port: 40000}
	}
	return f.svc.Login(context.Background(), LoginAttempt{Username: user, Password: pw, Remote: remote, Session: sess})
}

func ackHex(o LoginOutcome) string { return hex.EncodeToString(o.Ack.Encode()) }

// Wrong passwords: [2,1,max,used] per account NAME, the connection open
// below the tolerance; the attempt that reaches it closes, clears the count
// and raises the automatic block, which the right password then meets as
// [2,2,1, guide, end].
func TestLogin788WrongPasswordCounterAndBlock(t *testing.T) {
	f := newLogin788(t, LoginRules{BlockMinutes: 10})
	for used, want := range []string{"0201" + "03000000" + "01000000", "0201" + "03000000" + "02000000"} {
		out := f.login("alice", "nope", nil, "")
		if ackHex(out) != want || out.Close {
			t.Fatalf("wrong password %d: %s close=%v, want %s open", used+1, ackHex(out), out.Close, want)
		}
	}
	// Another name has its own count.
	if out := f.login("bob", "nope", nil, ""); out.Ack.UsedAttempts != 1 {
		t.Fatalf("bob's first wrong password counted %d", out.Ack.UsedAttempts)
	}
	out := f.login("alice", "nope", nil, "")
	if ackHex(out) != "0201"+"03000000"+"03000000" || !out.Close {
		t.Fatalf("the third: %s close=%v, want used 3 and close", ackHex(out), out.Close)
	}
	ps, _ := f.store.Punishments(context.Background(), 1)
	if len(ps) != 1 || ps[0].Type != account.PunishLogin || ps[0].Executor != account.AutomatedPunisher ||
		ps[0].Guide != DefaultLoginPunishmentGuide || !ps[0].EndAt.Equal(login788T0.Add(10*time.Minute)) {
		t.Fatalf("the automatic block: %+v", ps)
	}
	// Blocked now, even with the right password; the connection stays open.
	f.now = login788T0.Add(time.Minute)
	out = f.login("alice", "pw", nil, "")
	want := LoginAck{Code: LoginErrBlocked, BlockKind: LoginBlockPunished, BlockReason: DefaultLoginPunishmentGuide,
		BlockEnd: login788T0.Add(10 * time.Minute)}
	if !bytes.Equal(out.Ack.Encode(), want.Encode()) || out.Close || out.Account != nil {
		t.Fatalf("blocked: %s close=%v, want %x", ackHex(out), out.Close, want.Encode())
	}
	// The count was cleared: a wrong password starts again at 1 (and, the
	// account being blocked, the password is still checked first).
	if out := f.login("alice", "nope", nil, ""); out.Ack.UsedAttempts != 1 {
		t.Fatalf("after the block, a wrong password counted %d", out.Ack.UsedAttempts)
	}
	// The block ends by itself.
	f.now = login788T0.Add(10 * time.Minute)
	if out := f.login("alice", "pw", nil, ""); !out.Ack.OK {
		t.Fatalf("at the block's end: %s", ackHex(out))
	}
}

// BlockMinutes 0 (the package's server.cfg): no block, but the close and the
// cleared count stay.
func TestLogin788NoAutomaticBlock(t *testing.T) {
	f := newLogin788(t, LoginRules{FailureTolerance: 2})
	f.login("alice", "x", nil, "")
	if out := f.login("alice", "x", nil, ""); ackHex(out) != "0201"+"02000000"+"02000000" || !out.Close {
		t.Fatalf("tolerance 2: %s close=%v", ackHex(out), out.Close)
	}
	if ps, _ := f.store.Punishments(context.Background(), 1); len(ps) != 0 {
		t.Fatalf("a block was raised with BlockMinutes 0: %+v", ps)
	}
	if out := f.login("alice", "x", nil, ""); out.Ack.UsedAttempts != 1 {
		t.Fatalf("the count after the close: %d", out.Ack.UsedAttempts)
	}
	// A name with no account counts the same and raises nothing.
	f.svc.Rules.BlockMinutes = 10
	f.login("ghost", "x", nil, "")
	if out := f.login("ghost", "x", nil, ""); !out.Close || out.Ack.UsedAttempts != 2 {
		t.Fatalf("an unknown name: %s", ackHex(out))
	}
}

// A success forgets the name's wrong passwords (OURS: retail forgets them on
// the image code's success); an hour without one forgets them too (OURS).
func TestLogin788CountClearedBySuccessAndExpiry(t *testing.T) {
	f := newLogin788(t, LoginRules{})
	f.login("alice", "x", nil, "")
	f.login("alice", "x", nil, "")
	if out := f.login("alice", "pw", nil, ""); !out.Ack.OK {
		t.Fatalf("right password: %s", ackHex(out))
	}
	if out := f.login("alice", "x", nil, ""); out.Ack.UsedAttempts != 1 {
		t.Fatalf("after a success: used %d, want 1", out.Ack.UsedAttempts)
	}
	f.now = f.now.Add(LoginFailureExpiry - time.Second)
	if out := f.login("alice", "x", nil, ""); out.Ack.UsedAttempts != 2 {
		t.Fatalf("within the hour: used %d, want 2", out.Ack.UsedAttempts)
	}
	f.now = f.now.Add(LoginFailureExpiry)
	if out := f.login("alice", "x", nil, ""); out.Ack.UsedAttempts != 1 || out.Close {
		t.Fatalf("an hour later: used %d close=%v, want 1, open", out.Ack.UsedAttempts, out.Close)
	}
}

// An infinite punishment's end on the wire is its begin plus 100 years (READ:
// the SMC's "Set Infinite Duration"), in the service's zone; a guide longer
// than the gateway's 0x200-byte field is cut.
func TestLogin788InfiniteBlockEnd(t *testing.T) {
	f := newLogin788(t, LoginRules{})
	est := time.FixedZone("EST", -5*3600)
	f.svc.Location = est
	long := strings.Repeat("x", 600)
	if _, err := f.store.AddPunishment(context.Background(), account.Punishment{AccountID: 2, Type: account.PunishLoginInspection,
		Guide: long, BeginAt: login788T0}); err != nil {
		t.Fatal(err)
	}
	out := f.login("bob", "pw", nil, "")
	if out.Ack.Code != LoginErrBlocked || out.Ack.BlockKind != LoginBlockPunished || len(out.Ack.BlockReason) != 511 {
		t.Fatalf("type 2 is a login block: %+v", out.Ack)
	}
	// 12:00 UTC is 07:00 EST; the wire carries 2126-10-15 07:00:00.
	enc := out.Ack.Encode()
	ts := enc[len(enc)-16:]
	if hex.EncodeToString(ts) != "4e08"+"0a00"+"0f00"+"0700"+"0000"+"0000"+"00000000" {
		t.Fatalf("end time bytes %x", ts)
	}
}

type failingStore struct{}

func (failingStore) Authenticate(context.Context, string, string) (*account.Account, error) {
	return nil, errors.New("connection refused")
}

// A store error is the gateway's generic failure [2,6], connection open.
func TestLogin788StoreError(t *testing.T) {
	svc := &LoginService{Accounts: failingStore{}}
	out := svc.Login(context.Background(), LoginAttempt{Username: "a", Password: "b"})
	if ackHex(out) != "0206" || out.Close {
		t.Fatalf("store error: %s close=%v", ackHex(out), out.Close)
	}
}

// Full: [2,5], connection open; inspection: [2,2,2], closed; a GM account
// passes both. The password comes first: a wrong one under inspection is a
// wrong password.
func TestLogin788FullInspectionAndGM(t *testing.T) {
	f := newLogin788(t, LoginRules{})
	f.status = ServerStatus{Current: 5, Max: 5}
	if out := f.login("alice", "pw", nil, ""); ackHex(out) != "0205" || out.Close {
		t.Fatalf("full: %s close=%v", ackHex(out), out.Close)
	}
	if out := f.login("gm", "pw", nil, ""); !out.Ack.OK {
		t.Fatalf("a GM when full: %s", ackHex(out))
	}
	f.status = ServerStatus{Current: 0, Max: 5, Inspection: true}
	if out := f.login("alice", "pw", nil, ""); ackHex(out) != "020202" || !out.Close {
		t.Fatalf("inspection: %s close=%v", ackHex(out), out.Close)
	}
	if out := f.login("alice", "x", nil, ""); out.Ack.Code != LoginErrPassword {
		t.Fatalf("a wrong password under inspection: %s", ackHex(out))
	}
	if out := f.login("gm", "pw", gateway.NewTestSession(90), ""); !out.Ack.OK {
		t.Fatalf("a GM under inspection: %s", ackHex(out))
	}
	// Not counted: inspection refused alice without entering her.
	if f.svc.Online.Count() != 1 {
		t.Fatalf("online %d, want the GM alone", f.svc.Online.Count())
	}
}

// Already connected: a live session anywhere refuses the new one with [2,3]
// and closes it; the old one is not touched. Its end frees the account. A
// second login on a logged-in connection is refused without a close (OURS).
func TestLogin788AlreadyConnected(t *testing.T) {
	f := newLogin788(t, LoginRules{})
	s1, s2 := gateway.NewTestSession(1), gateway.NewTestSession(2)
	if out := f.login("alice", "pw", s1, "10.0.0.1"); !out.Ack.OK || out.Account == nil || out.Account.Username != "alice" {
		t.Fatalf("first: %s", ackHex(out))
	}
	if id, ok := AuthenticatedAccountID(s1); !ok || id != 1 {
		t.Fatalf("s1 not logged in: %d %v", id, ok)
	}
	if out := f.login("alice", "pw", s2, "10.0.0.2"); ackHex(out) != "0203" || !out.Close {
		t.Fatalf("second session: %s close=%v", ackHex(out), out.Close)
	}
	if _, ok := AuthenticatedAccountID(s2); ok {
		t.Fatal("the refused session was logged in")
	}
	if got, _ := f.svc.Online.Session(1); got != s1 {
		t.Fatal("the old session was replaced")
	}
	// The same connection again, any account.
	if out := f.login("bob", "pw", s1, "10.0.0.1"); ackHex(out) != "0203" || out.Close {
		t.Fatalf("a second login on s1: %s close=%v", ackHex(out), out.Close)
	}
	// A session that never logged in ending changes nothing.
	f.svc.SessionEnded(s2)
	if f.svc.Online.Count() != 1 {
		t.Fatal("s2's end released alice")
	}
	f.svc.SessionEnded(s1)
	s3 := gateway.NewTestSession(3)
	if out := f.login("alice", "pw", s3, "10.0.0.2"); !out.Ack.OK {
		t.Fatalf("after s1 ended: %s", ackHex(out))
	}
}

// The per-IP limit: [2,8] and closed once MaxPerIP accounts are in from the
// address; other addresses unaffected; 0 is off.
func TestLogin788IPLimit(t *testing.T) {
	f := newLogin788(t, LoginRules{MaxPerIP: 1})
	if out := f.login("alice", "pw", gateway.NewTestSession(1), "10.0.0.1"); !out.Ack.OK {
		t.Fatalf("alice: %s", ackHex(out))
	}
	if out := f.login("bob", "pw", gateway.NewTestSession(2), "10.0.0.1"); ackHex(out) != "0208" || !out.Close {
		t.Fatalf("bob from the same address: %s close=%v", ackHex(out), out.Close)
	}
	if out := f.login("bob", "pw", gateway.NewTestSession(3), "10.0.0.9"); !out.Ack.OK {
		t.Fatalf("bob from another: %s", ackHex(out))
	}
	f.svc.Rules.MaxPerIP = 0
	if out := f.login("gm", "pw", gateway.NewTestSession(4), "10.0.0.1"); !out.Ack.OK {
		t.Fatalf("limit off: %s", ackHex(out))
	}
}

// The old 0x0001's reason strings for each outcome.
func TestLogin788LegacyReasons(t *testing.T) {
	end := time.Date(2026, 10, 15, 12, 10, 0, 0, time.UTC)
	for _, c := range []struct {
		ack  LoginAck
		want string
	}{
		{LoginAck{OK: true}, ""},
		{LoginAck{Code: LoginErrPassword, MaxAttempts: 3, UsedAttempts: 1}, "invalid username or password"},
		{LoginAck{Code: LoginErrPassword, MaxAttempts: 3, UsedAttempts: 3}, "invalid username or password (3 of 3 attempts: disconnected)"},
		{LoginAck{Code: LoginErrBlocked, BlockKind: LoginBlockPunished, BlockReason: "spam", BlockEnd: end}, "account blocked: spam (until 2026-10-15 12:10:00)"},
		{LoginAck{Code: LoginErrBlocked, BlockKind: LoginBlockInspection}, LoginRefusedInspection},
		{LoginAck{Code: LoginErrFull}, LoginRefusedFull},
		{LoginAck{Code: LoginErrAlreadyConnected}, "this account is already connected"},
		{LoginAck{Code: LoginErrIPLimit}, "too many accounts are connected from your address"},
		{LoginAck{Code: LoginErrFailed}, "login failed"},
	} {
		if got := LegacyReason(LoginOutcome{Ack: c.ack}); got != c.want {
			t.Errorf("%+v: %q, want %q", c.ack, got, c.want)
		}
	}
}

// 0x6102 over a real connection: the A102 bytes, the open connection below
// the tolerance, the close at it and after "already connected", and the
// gateway's OnDisconnect freeing the account.
func TestLogin788GatewayWire(t *testing.T) {
	f := newLogin788(t, LoginRules{BlockMinutes: 10, PunishmentGuide: "slow down"})
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	srv := &gateway.Server{Addr: addr, Handle: GatewayLoginHandler(f.svc), OnDisconnect: f.svc.SessionEnded}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go srv.ListenAndServe(ctx)

	dial := func() (net.Conn, *bufio.Reader) {
		t.Helper()
		var c net.Conn
		var err error
		for i := 0; i < 100; i++ {
			if c, err = net.DialTimeout("tcp", addr, 100*time.Millisecond); err == nil {
				break
			}
			time.Sleep(10 * time.Millisecond)
		}
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { c.Close() })
		return c, bufio.NewReader(c)
	}
	send := func(c net.Conn, r *bufio.Reader, user, pw string) string {
		t.Helper()
		req := &GatewayLoginRequest{ContentID: 22, Username: user, Password: pw, ShardID: 64}
		if err := proto.Write(c, &proto.Packet{Opcode: OpGatewayLogin, Data: req.Encode()}, nil, nil); err != nil {
			t.Fatal(err)
		}
		c.SetReadDeadline(time.Now().Add(2 * time.Second))
		p, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("reading the A102: %v", err)
		}
		if p.Opcode != OpGatewayLoginAck {
			t.Fatalf("opcode 0x%04x", p.Opcode)
		}
		return hex.EncodeToString(p.Data)
	}
	closed := func(c net.Conn, r *bufio.Reader) bool {
		t.Helper()
		c.SetReadDeadline(time.Now().Add(2 * time.Second))
		_, err := r.ReadByte()
		return errors.Is(err, io.EOF)
	}

	c1, r1 := dial()
	if got := send(c1, r1, "alice", "x"); got != "0201"+"03000000"+"01000000" {
		t.Fatalf("1st wrong: %s", got)
	}
	if got := send(c1, r1, "alice", "x"); got != "0201"+"03000000"+"02000000" {
		t.Fatalf("2nd wrong on the same connection: %s", got)
	}
	if got := send(c1, r1, "alice", "x"); got != "0201"+"03000000"+"03000000" {
		t.Fatalf("3rd wrong: %s", got)
	}
	if !closed(c1, r1) {
		t.Fatal("the connection stayed open after the last allowed wrong password")
	}

	// Blocked: [2,2,1] "slow down" (u16 9) and 2026-10-15 12:10:00; open.
	c2, r2 := dial()
	wantBlock := "020201" + "0900" + hex.EncodeToString([]byte("slow down")) +
		"ea07" + "0a00" + "0f00" + "0c00" + "0a00" + "0000" + "00000000"
	if got := send(c2, r2, "alice", "pw"); got != wantBlock {
		t.Fatalf("blocked: %s\nwant      %s", got, wantBlock)
	}
	// Still open: bob logs in on it (success on OpenSRO's connection: token
	// 0, no agent host, port 0).
	if got := send(c2, r2, "bob", "pw"); got != "01"+"00000000"+"0000"+"0000" {
		t.Fatalf("bob on the blocked one's connection: %s", got)
	}

	// Bob again elsewhere: [2,3], closed; c2 untouched.
	c3, r3 := dial()
	if got := send(c3, r3, "bob", "pw"); got != "0203" {
		t.Fatalf("already connected: %s", got)
	}
	if !closed(c3, r3) {
		t.Fatal("the new connection stayed open after [2,3]")
	}
	if got, ok := f.svc.Online.Session(2); !ok || got == nil {
		t.Fatal("bob's first session was dropped")
	}

	// c2 ends; the gateway's OnDisconnect frees bob.
	c2.Close()
	deadline := time.Now().Add(2 * time.Second)
	for f.svc.Online.Count() != 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	c4, r4 := dial()
	if got := send(c4, r4, "bob", "pw"); got != "01"+"00000000"+"0000"+"0000" {
		t.Fatalf("bob after his session ended: %s", got)
	}

	// The GM console's kicks (gmsessions.go): /ban finds bob's character in
	// the world without case and closes his connection; /block's KickAccount
	// finds alice's at character select through the logged-in table.
	bobSess, _ := f.svc.Online.Session(2)
	hub := world.NewHub()
	hub.Enter(bobSess, 70, "Bo", 1, "jangan", world.Position{})
	g := GMSessions{Hub: hub, Online: f.svc.Online}
	if name, ok := g.KickCharacter("bO"); !ok || name != "Bo" {
		t.Fatalf("KickCharacter = %q, %v", name, ok)
	}
	if !closed(c4, r4) {
		t.Fatal("/ban left bob connected")
	}
	if _, ok := g.KickCharacter("Nobody"); ok {
		t.Fatal("kicked nobody")
	}
	f.now = login788T0.Add(10 * time.Minute) // alice's block is over
	c5, r5 := dial()
	if got := send(c5, r5, "alice", "pw"); got != "01"+"00000000"+"0000"+"0000" {
		t.Fatalf("alice: %s", got)
	}
	if !g.KickAccount(1) || !closed(c5, r5) {
		t.Fatal("KickAccount left alice connected")
	}
	deadline = time.Now().Add(2 * time.Second)
	for f.svc.Online.Count() != 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if g.KickAccount(1) || f.svc.Online.Count() != 0 {
		t.Fatalf("after the kicks: %d online", f.svc.Online.Count())
	}
}
