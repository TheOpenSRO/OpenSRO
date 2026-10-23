package session

import (
	"bufio"
	"context"
	"net"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/charlock"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 788 (lane P): the account PIN on the wire and the lobby gate.
// NEGATIVE: before round 788 there is no CharacterLockGate and this file does
// not compile; Start, delete and restore went through on any logged-in
// session.

const lockToken = "0123456789abcdef0123456789abcdef"

type lockRig struct {
	t     *testing.T
	addr  string
	svc   *charlock.Service
	store *charlock.MemStore
	clock time.Time
}

func newLockRig(t *testing.T, required bool) *lockRig {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	if _, err := accounts.Register(ctx, "alice", "pw"); err != nil {
		t.Fatal(err)
	}
	chars := character.NewMemStore()
	acc, _ := accounts.Authenticate(ctx, "alice", "pw")
	for _, name := range []string{"Aria", "Bram"} {
		if _, err := chars.CreateCharacter(ctx, acc.ID, character.NewCharacter{Name: name, RefObjID: 1907, StartZone: "jangan"}); err != nil {
			t.Fatal(err)
		}
	}
	rig := &lockRig{t: t, store: charlock.NewMemStore(), clock: time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)}
	rig.svc = &charlock.Service{Store: rig.store, Required: required, Now: func() time.Time { return rig.clock }}
	inv := inventory.NewMemStore(refdata.NewMemStore())
	eq := equipment.NewMemStore(inv)
	deps := LobbyDeps{Chars: chars, Now: func() time.Time { return rig.clock }}
	handle := CharacterLockGate(rig.svc, nil,
		gateway.Chain(LoginHandler(accounts), LobbyHandler(deps), WorldHandler(chars, eq, world.NewHub())))
	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)
	rig.addr = addr
	return rig
}

type lockSession struct {
	t    *testing.T
	conn net.Conn
	r    *bufio.Reader
}

// login opens a new connection (a new session) and logs alice in.
func (rig *lockRig) login() *lockSession {
	rig.t.Helper()
	s := rig.dial()
	p := s.send(OpLogin, (&LoginRequest{Username: "alice", Password: "pw"}).Encode())
	if lr, err := DecodeLoginResult(p.Data); err != nil || !lr.OK {
		rig.t.Fatalf("login: %v %+v", err, lr)
	}
	return s
}

func (rig *lockRig) dial() *lockSession {
	conn := dialTestServer(rig.t, rig.addr)
	rig.t.Cleanup(func() { conn.Close() })
	return &lockSession{t: rig.t, conn: conn, r: bufio.NewReader(conn)}
}

func (s *lockSession) send(op uint16, data []byte) *proto.Packet {
	s.t.Helper()
	if err := proto.Write(s.conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
		s.t.Fatal(err)
	}
	s.conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	p, err := proto.Read(s.r, nil, nil)
	if err != nil {
		s.t.Fatalf("read: %v", err)
	}
	return p
}

func (s *lockSession) lock(op uint16, r *CharLockRequest) *CharLockReply {
	s.t.Helper()
	p := s.send(op, encodeCharLockRequest(op, r))
	if p.Opcode != OpCharLockReply {
		s.t.Fatalf("reply opcode %#x, want 0x0121", p.Opcode)
	}
	rep, err := DecodeCharLockReply(p.Data)
	if err != nil {
		s.t.Fatal(err)
	}
	return rep
}

func (s *lockSession) status(token string) *CharLockReply {
	return s.lock(OpCharLockStatus, &CharLockRequest{Token: token})
}

func (s *lockSession) start(name string) *StartResult {
	s.t.Helper()
	p := s.send(OpStart, (&StartRequest{Name: name}).Encode())
	if p.Opcode != OpStartResult {
		s.t.Fatalf("start reply %#x, want 0xB001", p.Opcode)
	}
	r, err := DecodeStartResult(p.Data)
	if err != nil {
		s.t.Fatal(err)
	}
	return r
}

func (s *lockSession) lobby(action uint8, name string) *LobbyResult {
	s.t.Helper()
	p := s.send(OpLobby, (&LobbyRequest{Action: action, Name: name}).Encode())
	if p.Opcode != OpLobbyResult {
		s.t.Fatalf("lobby reply %#x", p.Opcode)
	}
	r, err := DecodeLobbyResult(p.Data)
	if err != nil {
		s.t.Fatal(err)
	}
	return r
}

func TestCharLockCodecs(t *testing.T) {
	for _, op := range []uint16{OpCharLockStatus, OpCharLockCreate, OpCharLockVerify, OpCharLockRemove} {
		in := &CharLockRequest{Pin: "1234", Remember: true, Token: lockToken}
		got, err := DecodeCharLockRequest(op, encodeCharLockRequest(op, in))
		if err != nil {
			t.Fatalf("%#x: %v", op, err)
		}
		switch op {
		case OpCharLockStatus:
			if got.Token != lockToken || got.Pin != "" {
				t.Errorf("status: %+v", got)
			}
		case OpCharLockVerify:
			if *got != *in {
				t.Errorf("verify: %+v", got)
			}
		default:
			if got.Pin != "1234" || got.Token != "" || got.Remember {
				t.Errorf("%#x: %+v", op, got)
			}
		}
	}
	// The verify layout, byte for byte: u16 4 "1234", u8 1, u16 2 "ab".
	b := encodeCharLockRequest(OpCharLockVerify, &CharLockRequest{Pin: "1234", Remember: true, Token: "ab"})
	if want := []byte{4, 0, '1', '2', '3', '4', 1, 2, 0, 'a', 'b'}; string(b) != string(want) {
		t.Errorf("verify bytes % x, want % x", b, want)
	}
	rep := &CharLockReply{Op: 2, Code: charlock.Locked, Flags: 9, AttemptsLeft: 0, LockedSeconds: 1800}
	if b := rep.Encode(); string(b) != string([]byte{2, 2, 9, 0, 0x08, 0x07, 0, 0}) {
		t.Errorf("reply bytes % x", b)
	}
	if got, _ := DecodeCharLockReply(rep.Encode()); *got != *rep {
		t.Errorf("reply round trip %+v", got)
	}
	if _, err := DecodeCharLockRequest(OpCharLockVerify, []byte{4, 0, '1'}); err == nil {
		t.Error("a short verify decoded")
	}
}

// No PIN, not required: the lobby is open; the status says so.
func TestCharLockNoPinPasses(t *testing.T) {
	rig := newLockRig(t, false)
	s := rig.login()
	if st := s.status(""); st.Code != charlock.OK || st.Flags != CharLockFlagUnlocked || st.AttemptsLeft != 0 {
		t.Fatalf("status: %+v", st)
	}
	if r := s.lobby(LobbyDelete, "Bram"); !r.OK {
		t.Fatalf("delete refused %#x", r.Code)
	}
	if r := s.start("Aria"); !r.OK {
		t.Fatalf("start refused %#x", r.Code)
	}
}

// Not logged in: the PIN requests are answered NotLoggedIn and the gate
// leaves Start to the handlers behind it (0x407).
func TestCharLockNotLoggedIn(t *testing.T) {
	rig := newLockRig(t, true)
	s := rig.dial()
	if st := s.status(""); st.Code != charlock.NotLoggedIn {
		t.Fatalf("status: %+v", st)
	}
	if r := s.start("Aria"); r.OK || r.Code != LobbyErrNoUser {
		t.Fatalf("start before login: %+v, want 0x407", r)
	}
}

// The whole path: create (unlocks this login), a new login is locked --
// list passes, Start, delete, restore and OpEnterWorld are refused -- a wrong
// PIN, the right one, then everything passes.
func TestCharLockGateCreateVerify(t *testing.T) {
	rig := newLockRig(t, false)
	s := rig.login()
	if r := s.lock(OpCharLockCreate, &CharLockRequest{Pin: "12a4"}); r.Code != charlock.BadFormat {
		t.Fatalf("create 12a4: %+v", r)
	}
	r := s.lock(OpCharLockCreate, &CharLockRequest{Pin: "2580"})
	if r.Code != charlock.OK || r.Flags != CharLockFlagHasPin|CharLockFlagUnlocked || r.AttemptsLeft != 5 {
		t.Fatalf("create: %+v", r)
	}
	if r := s.lock(OpCharLockCreate, &CharLockRequest{Pin: "1111"}); r.Code != charlock.PinExists {
		t.Fatalf("second create: %+v", r)
	}
	if r := s.lobby(LobbyDelete, "Bram"); !r.OK {
		t.Fatalf("the session that set the PIN was refused %#x", r.Code)
	}

	s2 := rig.login()
	if st := s2.status(""); st.Flags != CharLockFlagHasPin || st.AttemptsLeft != 5 {
		t.Fatalf("new login: %+v", st)
	}
	if r := s2.lobby(LobbyList, ""); !r.OK || len(r.Characters) != 2 {
		t.Fatalf("list refused: %+v", r)
	}
	if r := s2.start("Aria"); r.OK || r.Code != LobbyErrBusy {
		t.Fatalf("start before the PIN: %+v, want 0x40e", r)
	}
	if r := s2.lobby(LobbyDelete, "Aria"); r.OK || r.Code != LobbyErrBusy || r.Action != LobbyDelete {
		t.Fatalf("delete before the PIN: %+v", r)
	}
	if r := s2.lobby(LobbyRestore, "Bram"); r.OK || r.Code != LobbyErrBusy || r.Action != LobbyRestore {
		t.Fatalf("restore before the PIN: %+v", r)
	}
	p := s2.send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ew, err := DecodeEnterWorldResult(p.Data); p.Opcode != OpEnterWorldResult || err != nil || ew.OK {
		t.Fatalf("OpEnterWorld before the PIN: %#x %+v %v", p.Opcode, ew, err)
	}
	if r := s2.lock(OpCharLockVerify, &CharLockRequest{Pin: "0000"}); r.Code != charlock.WrongPin || r.AttemptsLeft != 4 || r.Flags&CharLockFlagUnlocked != 0 {
		t.Fatalf("wrong PIN: %+v", r)
	}
	if r := s2.start("Aria"); r.OK {
		t.Fatal("start after a wrong PIN")
	}
	if r := s2.lock(OpCharLockVerify, &CharLockRequest{Pin: "2580"}); r.Code != charlock.OK || r.Flags&CharLockFlagUnlocked == 0 || r.AttemptsLeft != 5 {
		t.Fatalf("right PIN: %+v", r)
	}
	if r := s2.lobby(LobbyRestore, "Bram"); !r.OK {
		t.Fatalf("restore after the PIN: %#x", r.Code)
	}
	if r := s2.start("Aria"); !r.OK {
		t.Fatalf("start after the PIN: %#x", r.Code)
	}
}

// Five wrong entries lock the PIN for 30 minutes on every login; the lock
// ends at 30 minutes.
func TestCharLockLockoutAcrossSessions(t *testing.T) {
	rig := newLockRig(t, false)
	rig.login().lock(OpCharLockCreate, &CharLockRequest{Pin: "2580"})
	s := rig.login()
	for i := 1; i <= 4; i++ {
		if r := s.lock(OpCharLockVerify, &CharLockRequest{Pin: "1111"}); r.Code != charlock.WrongPin || int(r.AttemptsLeft) != 5-i {
			t.Fatalf("wrong %d: %+v", i, r)
		}
	}
	r := s.lock(OpCharLockVerify, &CharLockRequest{Pin: "1111"})
	if r.Code != charlock.Locked || r.Flags&CharLockFlagLocked == 0 || r.LockedSeconds != 1800 || r.AttemptsLeft != 0 {
		t.Fatalf("5th wrong: %+v, want locked 1800 s", r)
	}
	// Another login, 10 minutes on: still locked, the right PIN refused.
	rig.clock = rig.clock.Add(10 * time.Minute)
	s2 := rig.login()
	if st := s2.status(""); st.Flags&CharLockFlagLocked == 0 || st.LockedSeconds != 1200 {
		t.Fatalf("status on a new login: %+v", st)
	}
	if r := s2.lock(OpCharLockVerify, &CharLockRequest{Pin: "2580"}); r.Code != charlock.Locked {
		t.Fatalf("right PIN while locked: %+v", r)
	}
	if r := s2.lock(OpCharLockRemove, &CharLockRequest{Pin: "2580"}); r.Code != charlock.Locked {
		t.Fatalf("remove while locked: %+v", r)
	}
	if r := s2.start("Aria"); r.OK {
		t.Fatal("start while locked")
	}
	// 30 minutes after the lock: open again, five fresh tries.
	rig.clock = rig.clock.Add(20 * time.Minute)
	if st := s2.status(""); st.Flags&CharLockFlagLocked != 0 || st.AttemptsLeft != 5 {
		t.Fatalf("status at 30 min: %+v", st)
	}
	if r := s2.lock(OpCharLockVerify, &CharLockRequest{Pin: "2580"}); r.Code != charlock.OK {
		t.Fatalf("right PIN after the lock: %+v", r)
	}
	if r := s2.start("Aria"); !r.OK {
		t.Fatalf("start after the lock: %#x", r.Code)
	}
}

// "Remember this PC": the next login's status with the same token unlocks
// without the PIN; another token does not; removing the PIN forgets the PC.
func TestCharLockRememberedPC(t *testing.T) {
	rig := newLockRig(t, false)
	rig.login().lock(OpCharLockCreate, &CharLockRequest{Pin: "2580"})
	s := rig.login()
	if r := s.lock(OpCharLockVerify, &CharLockRequest{Pin: "2580", Remember: true, Token: "short"}); r.Code != charlock.BadFormat {
		t.Fatalf("a bad token: %+v", r)
	}
	if r := s.lock(OpCharLockVerify, &CharLockRequest{Pin: "2580", Remember: true, Token: lockToken}); r.Code != charlock.OK {
		t.Fatalf("verify + remember: %+v", r)
	}
	s2 := rig.login()
	if st := s2.status("fedcba9876543210fedcba9876543210"); st.Flags&CharLockFlagUnlocked != 0 {
		t.Fatalf("another PC unlocked: %+v", st)
	}
	if st := s2.status(lockToken); st.Flags&CharLockFlagUnlocked == 0 {
		t.Fatalf("the remembered PC is asked: %+v", st)
	}
	if r := s2.start("Aria"); !r.OK {
		t.Fatalf("start on a remembered PC: %#x", r.Code)
	}
	// Remove forgets every remembered PC (a new PIN, then the same token).
	s3 := rig.login()
	s3.status(lockToken)
	if r := s3.lock(OpCharLockRemove, &CharLockRequest{Pin: "2580"}); r.Code != charlock.OK || r.Flags&CharLockFlagHasPin != 0 {
		t.Fatalf("remove: %+v", r)
	}
	s3.lock(OpCharLockCreate, &CharLockRequest{Pin: "1357"})
	s4 := rig.login()
	if st := s4.status(lockToken); st.Flags&CharLockFlagUnlocked != 0 {
		t.Fatalf("a PC remembered across a PIN change: %+v", st)
	}
}

// -require-pin: an account with none can list but not start until it sets
// one.
func TestCharLockRequired(t *testing.T) {
	rig := newLockRig(t, true)
	s := rig.login()
	if st := s.status(""); st.Flags != CharLockFlagRequired {
		t.Fatalf("status: %+v", st)
	}
	if r := s.lobby(LobbyList, ""); !r.OK {
		t.Fatal("list refused")
	}
	if r := s.start("Aria"); r.OK || r.Code != LobbyErrBusy {
		t.Fatalf("start with none set: %+v", r)
	}
	if r := s.lock(OpCharLockCreate, &CharLockRequest{Pin: "9876"}); r.Code != charlock.OK || r.Flags != CharLockFlagHasPin|CharLockFlagRequired|CharLockFlagUnlocked {
		t.Fatalf("create: %+v", r)
	}
	if r := s.start("Aria"); !r.OK {
		t.Fatalf("start after create: %#x", r.Code)
	}
}

// A second account logged in on the same connection does not inherit the
// first one's unlock.
func TestCharLockUnlockIsPerAccount(t *testing.T) {
	if charLockUnlocked(gateway.NewTestSession(1), 1) {
		t.Fatal("a fresh session is unlocked")
	}
	g := gateway.NewTestSession(2)
	setCharLockUnlocked(g, 1)
	if !charLockUnlocked(g, 1) || charLockUnlocked(g, 2) {
		t.Fatal("the unlock is not keyed by account")
	}
}

// encodeCharLockRequest writes op's fields of r, as the client does (the
// tests' client; the server only decodes requests).
func encodeCharLockRequest(op uint16, r *CharLockRequest) []byte {
	switch op {
	case OpCharLockStatus:
		return appendLobbyName(nil, r.Token)
	case OpCharLockVerify:
		out := appendLobbyName(nil, r.Pin)
		if r.Remember {
			out = append(out, 1)
		} else {
			out = append(out, 0)
		}
		return appendLobbyName(out, r.Token)
	default:
		return appendLobbyName(nil, r.Pin)
	}
}
