package session

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/academy"
	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/charmsg"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/timedjob"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 865 stage 2: the academy's requests in their refusal orders and the
// measured sequences (docs/protocol/academy.md sections 6 and 7), over real
// sessions: Aria the guardian (70), Bram an apprentice (1), Cora an
// assistant (40), Dora a bystander (60).

type acPlayer struct {
	id   int64
	user string
	name string
	conn net.Conn
	r    *bufio.Reader
}

type acFix struct {
	chars *character.MemStore
	hub   *world.Hub
	store *academy.MemStore
	timed *timedjob.MemStore
	addr  string
	npc   uint32
	mu    sync.Mutex
	clock time.Time
	p     map[string]*acPlayer
}

func (f *acFix) now() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.clock
}

func (f *acFix) advance(d time.Duration) {
	f.mu.Lock()
	f.clock = f.clock.Add(d)
	f.mu.Unlock()
}

func startAcademy865(t *testing.T) *acFix {
	t.Helper()
	ctx := context.Background()
	f := &acFix{chars: character.NewMemStore(), hub: world.NewHub(), store: academy.NewMemStore(),
		timed: timedjob.NewMemStore(), clock: time.Date(2026, 1, 1, 0, 0, 2, 149_000_000, time.Local), p: map[string]*acPlayer{}}
	accounts := account.NewMemStore()
	keeper := npcAt(9, 100, 0, npcspawn.FromNest)
	keeper.Code = "NPC_CH_WAREHOUSE_M"
	keeper.Flags, keeper.Interact = npcspawn.FlagInteractions, []byte{1, 3}
	installNPCsForTest(t, keeper)
	f.npc = keeper.UID
	SetAcademy(AcademyDeps{Store: f.store, Chars: f.chars, Hub: f.hub, Timed: f.timed, Now: f.now})
	t.Cleanup(func() { SetAcademy(AcademyDeps{}) })
	oldWait := academyInviteTimeout
	academyInviteTimeout = 300 * time.Millisecond
	t.Cleanup(func() { academyInviteTimeout = oldWait })
	handle := gateway.Chain(LoginHandler(accounts), WorldHandlerWithHook(f.chars, nil, f.hub, nil, nil),
		NPCTalkHandler(f.hub, nil), PartyHandler(PartyDeps{Chars: f.chars, Hub: f.hub, Parties: party.NewHub()}),
		AcademyHandler(), ChatHandler(ChatDeps{Hub: f.hub}))
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	f.addr = ln.Addr().String()
	ln.Close()
	srv := &gateway.Server{Addr: f.addr, Handle: handle, OnDisconnect: WorldDisconnectHandler(f.hub, f.chars)}
	sctx, cancel := context.WithCancel(ctx)
	go srv.ListenAndServe(sctx)
	t.Cleanup(cancel)
	for i, who := range []struct {
		user, name string
		level      int
	}{{"alice", "Aria", 70}, {"bob", "Bram", 1}, {"carol", "Cora", 40}, {"dave", "Dora", 60}} {
		accounts.Add(who.user, "pw")
		c, err := f.chars.Create(ctx, int64(i+1), who.name)
		if err != nil {
			t.Fatal(err)
		}
		if err := f.chars.SetLeveling(ctx, c.ID, who.level, 0, 0, c.Str, c.Int); err != nil {
			t.Fatal(err)
		}
		f.p[who.name] = &acPlayer{id: c.ID, user: who.user, name: who.name}
	}
	for _, n := range []string{"Aria", "Bram", "Cora", "Dora"} {
		f.login(t, f.p[n])
	}
	if e, _ := f.hub.FindByName("Aria"); e.Zone != "jangan" {
		t.Skipf("the test NPC stands in the jangan frame; the world put Aria in %q", e.Zone)
	}
	return f
}

func (f *acFix) login(t *testing.T, p *acPlayer) {
	t.Helper()
	p.conn = dialTestServer(t, f.addr)
	t.Cleanup(func() { p.conn.Close() })
	p.r = bufio.NewReader(p.conn)
	f.send(t, p, OpLogin, (&LoginRequest{Username: p.user, Password: "pw"}).Encode())
	nextOp(t, p.conn, p.r, OpLoginResult)
	f.send(t, p, OpEnterWorld, (&EnterWorldRequest{CharacterName: p.name}).Encode())
	if r, err := DecodeEnterWorldResult(nextOp(t, p.conn, p.r, OpEnterWorldResult).Data); err != nil || !r.OK {
		t.Fatalf("%s: enter world %v %+v", p.name, err, r)
	}
	e, _ := f.hub.FindByName(p.name)
	f.hub.Relocate(e.Session, world.Position{X: 50 + float64(p.id), Z: 0}, world.MoveRelocate, 0)
}

func (f *acFix) send(t *testing.T, p *acPlayer, op uint16, data []byte) {
	t.Helper()
	if err := proto.Write(p.conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
		t.Fatalf("write: %v", err)
	}
}

// ask sends op and returns the next reply on reply.
func (f *acFix) ask(t *testing.T, p *acPlayer, op uint16, data []byte, reply uint16) []byte {
	t.Helper()
	f.send(t, p, op, data)
	return nextOp(t, p.conn, p.r, reply).Data
}

func (f *acFix) push(t *testing.T, p *acPlayer) []byte {
	t.Helper()
	return nextOp(t, p.conn, p.r, proto.OpAcademyUpdate).Data
}

func (f *acFix) setLevel(t *testing.T, name string, level int) {
	t.Helper()
	p := f.p[name]
	c, _ := f.chars.GetByID(context.Background(), p.id)
	f.chars.SetLeveling(context.Background(), p.id, level, 0, 0, c.Str, c.Int)
	f.hub.SetLevel(p.id, level)
}

func (f *acFix) selectNPC(t *testing.T, p *acPlayer) {
	t.Helper()
	f.ask(t, p, npctalk.OpSelect, acU32(f.npc), npctalk.OpSelectResult)
}

func acU32(v uint32) []byte { return binary.LittleEndian.AppendUint32(nil, v) }

func acStr(s string) []byte {
	return append(binary.LittleEndian.AppendUint16(nil, uint16(len(s))), s...)
}

func acWant(t *testing.T, what string, got []byte, parts ...[]byte) {
	t.Helper()
	w := bytes.Join(parts, nil)
	if !bytes.Equal(got, w) {
		t.Fatalf("%s:\n got % x\nwant % x", what, got, w)
	}
}

func acB(v ...byte) []byte { return v }

func acFailB(code uint16) []byte { return academy.EncodeFail(code) }

// found makes Aria's camp at the keeper and drains its sequence.
func (f *acFix) found(t *testing.T) *academy.Camp {
	t.Helper()
	a := f.p["Aria"]
	ctx := context.Background()
	f.chars.AddGold(ctx, a.id, 150_000)
	before, _ := f.chars.GetByID(ctx, a.id)
	f.selectNPC(t, a)
	f.send(t, a, proto.OpAcademyOpenRequest, acU32(f.npc))
	gold := nextOp(t, a.conn, a.r, charmsg.OpCharInfo).Data
	acWant(t, "0x304E", gold, charmsg.EncodeGold(before.Gold-academy.FoundingGold, false))
	res := nextOp(t, a.conn, a.r, proto.OpAcademyOpenAck).Data
	c, err := f.store.CampOf(ctx, a.id)
	if err != nil {
		t.Fatal(err)
	}
	if res[0] != 1 || binary.LittleEndian.Uint32(res[1:]) != uint32(c.ID) {
		t.Fatalf("0xB470 % x", res)
	}
	acWant(t, "05 online", f.push(t, a), academy.EncodeFieldU8(a.id, academy.FieldPlayState, academy.PlayOnline))
	return c
}

// invite has Aria invite name and name accept; the joiner's 0a is returned.
func (f *acFix) invite(t *testing.T, name string) []byte {
	t.Helper()
	a, p := f.p["Aria"], f.p[name]
	f.send(t, a, proto.OpAcademyInviteRequest, acU32(uint32(p.id)))
	q := nextOp(t, p.conn, p.r, party.OpInvitation).Data
	acWant(t, "0x3080 kind 9", q, acB(9), acU32(uint32(a.id)), acStr("Aria"))
	f.send(t, p, party.OpInvitation, acB(1, 1))
	join := f.push(t, p)
	if join[0] != academy.PushJoin || join[1] != 1 {
		t.Fatalf("0a % x", join)
	}
	acWant(t, "05 joiner online (to itself)", f.push(t, p), academy.EncodeFieldU8(p.id, academy.FieldPlayState, academy.PlayOnline))
	return join
}

// entry finds charID's MemberEntry in a CampInfo (from its camp id) and
// returns its play state, world and display name.
func acEntryOf(t *testing.T, info []byte, charID int64) (state byte, worldID uint32, display string) {
	t.Helper()
	off := 4 + 16 + 1
	for i := 0; i < 2; i++ {
		n := int(binary.LittleEndian.Uint16(info[off:]))
		off += 2 + n
	}
	count := int(info[off])
	off++
	for i := 0; i < count; i++ {
		id := int64(binary.LittleEndian.Uint32(info[off+4:]))
		off += 12
		off += 2 + int(binary.LittleEndian.Uint16(info[off:]))
		off += 2 + 16 + 2 + 4
		st := info[off]
		wid := binary.LittleEndian.Uint32(info[off+1:])
		off += 1 + 4 + 2 + 6
		n := int(binary.LittleEndian.Uint16(info[off:]))
		name := string(info[off+2 : off+2+n])
		off += 2 + n
		if id == charID {
			return st, wid, name
		}
	}
	t.Fatalf("no entry for %d in % x", charID, info)
	return
}

func TestAcademy865OpenRefusalsAndFounding(t *testing.T) {
	f := startAcademy865(t)
	ctx := context.Background()
	d, a := f.p["Dora"], f.p["Aria"]
	// Level under 60 first (Bram), then gold (Dora at 60 has none).
	acWant(t, "level", f.ask(t, f.p["Bram"], proto.OpAcademyOpenRequest, acU32(f.npc), proto.OpAcademyOpenAck), acFailB(academy.ErrOpenLevel))
	acWant(t, "gold", f.ask(t, d, proto.OpAcademyOpenRequest, acU32(f.npc), proto.OpAcademyOpenAck), acFailB(academy.ErrOpenGold))
	// With gold but no talk with the keeper: 3.
	f.chars.AddGold(ctx, d.id, 100_000)
	acWant(t, "no NPC", f.ask(t, d, proto.OpAcademyOpenRequest, acU32(f.npc), proto.OpAcademyOpenAck), acFailB(3))
	// The founding sequence: 0x304E, 0xB470 {1, CampInfo} with the founder's
	// own entry at play state 1, then 05 field 1 = 0.
	c := f.found(t)
	if c.Rank != academy.RankNone || len(c.Members) != 1 || c.Members[0].Class != academy.MemberClassGuardian {
		t.Fatalf("camp %+v", c)
	}
	// In a camp already: 0x6812.
	f.chars.AddGold(ctx, a.id, 150_000)
	acWant(t, "in a camp", f.ask(t, a, proto.OpAcademyOpenRequest, acU32(f.npc), proto.OpAcademyOpenAck), acFailB(academy.ErrAlreadyInCamp))
}

func TestAcademy865FoundingEntryCarriesPlayStateOne(t *testing.T) {
	f := startAcademy865(t)
	a := f.p["Aria"]
	f.chars.AddGold(context.Background(), a.id, 150_000)
	f.selectNPC(t, a)
	res := f.ask(t, a, proto.OpAcademyOpenRequest, acU32(f.npc), proto.OpAcademyOpenAck)
	st, wid, name := acEntryOf(t, res[1:], a.id)
	if st != academy.PlayOffline || wid != academy.WorldOpen || name != "Aria" {
		t.Fatalf("founder's own entry: state %d world %#x name %q", st, wid, name)
	}
}

func TestAcademy865InviteJoinSequence(t *testing.T) {
	f := startAcademy865(t)
	f.found(t)
	a, br := f.p["Aria"], f.p["Bram"]
	join := f.invite(t, "Bram")
	// The joiner's own copy: play state 1, its place and its name; the
	// guardian online with its name.
	if st, wid, name := acEntryOf(t, join[2:], br.id); st != academy.PlayOffline || wid != academy.WorldOpen || name != "Bram" {
		t.Fatalf("joiner's own entry: %d %#x %q", st, wid, name)
	}
	if st, _, name := acEntryOf(t, join[2:], a.id); st != academy.PlayOnline || name != "Aria" {
		t.Fatalf("guardian's entry: %d %q", st, name)
	}
	// The guardian: 02 (play state 1, no place, no name), then 0d, then 05.
	m, _ := f.store.CampOf(context.Background(), br.id)
	bm, _ := m.Member(br.id)
	acWant(t, "02", f.push(t, a), academy.EncodeJoined(bm, academy.Unplaced))
	pos := f.push(t, a)
	if pos[0] != academy.PushPosition || binary.LittleEndian.Uint32(pos[1:]) != uint32(br.id) || !bytes.Contains(pos, acStr("Bram")) {
		t.Fatalf("0d % x", pos)
	}
	acWant(t, "05", f.push(t, a), academy.EncodeFieldU8(br.id, academy.FieldPlayState, academy.PlayOnline))
	// No 0xB472 to the inviter on success.
	noOp(t, a.conn, a.r, proto.OpAcademyInviteAck)
	if bm.Class != academy.MemberClassStudent || bm.JoinedLevel != 1 {
		t.Fatalf("stored %+v", bm)
	}
	// Cora at 40 joins as an assistant.
	f.invite(t, "Cora")
	cm, _ := f.store.CampOf(context.Background(), f.p["Cora"].id)
	if mm, _ := cm.Member(f.p["Cora"].id); mm.Class != academy.MemberClassSecondGuardian {
		t.Fatalf("Cora %+v", mm)
	}
}

func TestAcademy865InviteRefusals(t *testing.T) {
	f := startAcademy865(t)
	a, br, d := f.p["Aria"], f.p["Bram"], f.p["Dora"]
	inv := func(from *acPlayer, to int64) []byte {
		return f.ask(t, from, proto.OpAcademyInviteRequest, acU32(uint32(to)), proto.OpAcademyInviteAck)
	}
	acWant(t, "no camp", inv(a, br.id), acFailB(3))
	f.found(t)
	acWant(t, "self", inv(a, a.id), acFailB(3))
	acWant(t, "not found", inv(a, 999), acFailB(0))
	acWant(t, "an NPC", inv(a, int64(f.npc)), acFailB(3))
	// MEASURED: a level-60 target, 02 03 00.
	acWant(t, "level 60", inv(a, d.id), acFailB(3))
	f.invite(t, "Bram")
	acWant(t, "in this camp", inv(a, br.id), acFailB(0x680f))
	acWant(t, "not the guardian", inv(br, f.p["Cora"].id), acFailB(academy.ErrOrderWork))
	// A refusal: code 0 both ways (round 866, MEASURED).
	c := f.p["Cora"]
	f.send(t, a, proto.OpAcademyInviteRequest, acU32(uint32(c.id)))
	nextOp(t, c.conn, c.r, party.OpInvitation)
	f.send(t, c, party.OpInvitation, acB(2, 0, 0))
	acWant(t, "refused (inviter)", nextOp(t, a.conn, a.r, proto.OpAcademyInviteAck).Data, acFailB(academy.InviteRefusedCode))
	acWant(t, "refused (invitee)", f.push(t, c), academy.EncodeJoinFail(academy.InviteRefusedCode))
	// The timeout: 0x000E both ways.
	f.send(t, a, proto.OpAcademyInviteRequest, acU32(uint32(c.id)))
	nextOp(t, c.conn, c.r, party.OpInvitation)
	acWant(t, "timeout (inviter)", nextOp(t, a.conn, a.r, proto.OpAcademyInviteAck).Data, acB(2, 0x0e, 0))
	acWant(t, "timeout (invitee)", f.push(t, c), acB(0x0a, 2, 0x0e, 0))
}

func TestAcademy865Chat(t *testing.T) {
	f := startAcademy865(t)
	f.found(t)
	f.invite(t, "Bram")
	a, br := f.p["Aria"], f.p["Bram"]
	f.send(t, br, OpChatSend, (&ChatSendRequest{Type: ChatAcademy, Index: 3, Message: "hi"}).Encode())
	res, _ := DecodeChatResult(nextOp(t, br.conn, br.r, OpChatResult).Data)
	if !res.OK || res.Type != ChatAcademy || res.Index != 3 {
		t.Fatalf("result %+v", res)
	}
	for _, p := range []*acPlayer{a, br} {
		u, _ := DecodeChatUpdate(nextOp(t, p.conn, p.r, OpChatUpdate).Data)
		if u.Type != ChatAcademy || u.Sender != "Bram" || u.Message != "hi" {
			t.Fatalf("%s heard %+v", p.name, u)
		}
	}
	// A non-member keeps the OURS 0xf002.
	c := f.p["Cora"]
	f.send(t, c, OpChatSend, (&ChatSendRequest{Type: ChatAcademy, Index: 1, Message: "x"}).Encode())
	if r, _ := DecodeChatResult(nextOp(t, c.conn, c.r, OpChatResult).Data); r.OK || r.Code != ChatErrNoAcademy {
		t.Fatalf("non-member %+v", r)
	}
}

func TestAcademy865Notice(t *testing.T) {
	f := startAcademy865(t)
	f.found(t)
	f.invite(t, "Bram")
	a, br := f.p["Aria"], f.p["Bram"]
	note := append(acStr("Hello Academy"), acStr("Test notice line")...)
	acWant(t, "not the guardian", f.ask(t, br, proto.OpAcademyNoticeRequest, note, proto.OpAcademyNoticeAck), acFailB(academy.ErrOrderWork))
	acWant(t, "no camp", f.ask(t, f.p["Cora"], proto.OpAcademyNoticeRequest, note, proto.OpAcademyNoticeAck), acFailB(academy.ErrOrderWork))
	acWant(t, "empty", f.ask(t, a, proto.OpAcademyNoticeRequest, append(acStr(""), acStr("x")...), proto.OpAcademyNoticeAck), acFailB(0x6817))
	// A quote: dropped, no reply.
	f.send(t, a, proto.OpAcademyNoticeRequest, append(acStr("it's"), acStr("x")...))
	noOp(t, a.conn, a.r, proto.OpAcademyNoticeAck)
	// 07 to every member, the writer included, then 0xB477 {1}.
	f.send(t, a, proto.OpAcademyNoticeRequest, note)
	acWant(t, "07 (writer)", f.push(t, a), academy.EncodeNotice("Hello Academy", "Test notice line"))
	acWant(t, "B477", nextOp(t, a.conn, a.r, proto.OpAcademyNoticeAck).Data, acB(1))
	acWant(t, "07 (member)", f.push(t, br), academy.EncodeNotice("Hello Academy", "Test notice line"))
}

func TestAcademy865LeaveBanAndPenalties(t *testing.T) {
	f := startAcademy865(t)
	f.found(t)
	f.invite(t, "Bram")
	f.invite(t, "Cora")
	a, br, c := f.p["Aria"], f.p["Bram"], f.p["Cora"]
	// Inside 24 h: leave 0x6821 on 0xB473, ban 0x6820 (MEASURED).
	acWant(t, "leave < 24 h", f.ask(t, br, proto.OpAcademyLeaveRequest, nil, proto.OpAcademyBanAck), acB(2, 0x21, 0x68))
	acWant(t, "ban < 24 h", f.ask(t, a, proto.OpAcademyBanRequest, acStr("bram"), proto.OpAcademyBanAck), acB(2, 0x20, 0x68))
	acWant(t, "ban self", f.ask(t, a, proto.OpAcademyBanRequest, acStr("Aria"), proto.OpAcademyBanAck), acFailB(academy.ErrOrderWork))
	acWant(t, "ban a stranger", f.ask(t, a, proto.OpAcademyBanRequest, acStr("Dora"), proto.OpAcademyBanAck), acFailB(0x6815))
	acWant(t, "ban by a member", f.ask(t, br, proto.OpAcademyBanRequest, acStr("Cora"), proto.OpAcademyBanAck), acFailB(academy.ErrOrderWork))
	acWant(t, "guardian leaves", f.ask(t, a, proto.OpAcademyLeaveRequest, nil, proto.OpAcademyLeaveAck), acFailB(academy.ErrOrderWork))
	acWant(t, "stranger leaves", f.ask(t, f.p["Dora"], proto.OpAcademyLeaveRequest, nil, proto.OpAcademyLeaveAck), acFailB(academy.ErrNoCamp))
	f.advance(24*time.Hour + time.Minute)
	// Ban Bram (an apprentice): 0xB473 {1}, 03 to both, the guardian's invite
	// penalty.
	acWant(t, "ban", f.ask(t, a, proto.OpAcademyBanRequest, acStr("Bram"), proto.OpAcademyBanAck), acB(1))
	acWant(t, "03 (guardian)", f.push(t, a), academy.EncodeRemoved(br.id, academy.RemoveBanned))
	acWant(t, "03 (banned)", f.push(t, br), academy.EncodeRemoved(br.id, academy.RemoveBanned))
	acWant(t, "invite penalty", f.ask(t, a, proto.OpAcademyInviteRequest, acU32(uint32(br.id)), proto.OpAcademyInviteAck), acFailB(academy.ErrNotInvite24T))
	// Cora (an assistant) leaves: 0xB474 {1}, 03 reason 1, the 72 h entry
	// penalty.
	acWant(t, "leave", f.ask(t, c, proto.OpAcademyLeaveRequest, nil, proto.OpAcademyLeaveAck), acB(1))
	acWant(t, "03 (leaver)", f.push(t, c), academy.EncodeRemoved(c.id, academy.RemoveLeft))
	if left := academyRT.Load().penaltyLeft(context.Background(), c.id, academy.PenaltyIDEnter3D); left != 259200 {
		t.Fatalf("assistant's entry penalty %d s", left)
	}
	f.advance(24*time.Hour + time.Second)
	acWant(t, "entry penalty", f.ask(t, a, proto.OpAcademyInviteRequest, acU32(uint32(c.id)), proto.OpAcademyInviteAck), acFailB(0x681e))
}

func TestAcademy865Graduation(t *testing.T) {
	f := startAcademy865(t)
	ctx := context.Background()
	f.found(t)
	f.invite(t, "Bram")
	f.invite(t, "Cora")
	a, br, c := f.p["Aria"], f.p["Bram"], f.p["Cora"]
	acWant(t, "guardian", f.ask(t, a, proto.OpAcademyGraduationRequest, acB(0), proto.OpAcademyGraduationAck), acFailB(5))
	acWant(t, "apprentice at 1", f.ask(t, br, proto.OpAcademyGraduationRequest, acB(3), proto.OpAcademyGraduationAck), acFailB(academy.ErrGraduationLevel))
	// A level change in the game: 05 field 6 then field 2 to all, and the
	// stored levels follow.
	f.setLevel(t, "Bram", 40)
	for _, p := range []*acPlayer{a, br, c} {
		acWant(t, "05 cur", f.push(t, p), academy.EncodeFieldU8(br.id, academy.FieldCurLevel, 40))
		acWant(t, "05 max", f.push(t, p), academy.EncodeFieldU8(br.id, academy.FieldMaxLevel, 40))
	}
	if camp, _ := f.store.CampOf(ctx, br.id); func() bool { m, _ := camp.Member(br.id); return m.CurLevel != 40 || m.MaxLevel != 40 }() {
		t.Fatal("stored levels did not follow")
	}
	// Forced at a stored 40: 0x6822.
	acWant(t, "forced at 40", f.ask(t, a, proto.OpAcademyForceGradRequest, acStr("Bram"), proto.OpAcademyForceGradAck), acFailB(0x6822))
	acWant(t, "forced self", f.ask(t, a, proto.OpAcademyForceGradRequest, acStr("Aria"), proto.OpAcademyForceGradAck), acFailB(5))
	acWant(t, "evaluation 5", f.ask(t, br, proto.OpAcademyGraduationRequest, acB(5), proto.OpAcademyGraduationAck), acFailB(5))
	// Self graduation, very satisfied: 0xB475 {1}, 04 kind 1 to all, the
	// shares (joined at 1: guardian +39, assistant +3) as 05 field 3.
	acWant(t, "graduate", f.ask(t, br, proto.OpAcademyGraduationRequest, acB(4), proto.OpAcademyGraduationAck), acB(1))
	for _, p := range []*acPlayer{a, br, c} {
		acWant(t, "04", f.push(t, p), academy.EncodeGraduated(br.id, 1))
	}
	for _, p := range []*acPlayer{a, c} {
		acWant(t, "honor guardian", f.push(t, p), academy.EncodeFieldU32(a.id, academy.FieldHonor, 39))
		acWant(t, "honor assistant", f.push(t, p), academy.EncodeFieldU32(c.id, academy.FieldHonor, 3))
	}
	camp, _ := f.store.CampOf(ctx, a.id)
	if camp.GraduateCount != 1 || camp.EvaluationPoint != 5 {
		t.Fatalf("camp after %+v", camp)
	}
	// Cora: forced at 41 needs 61; at 61 it goes, kind 0.
	acWant(t, "assistant forced at 40", f.ask(t, a, proto.OpAcademyForceGradRequest, acStr("Cora"), proto.OpAcademyForceGradAck), acFailB(0x6822))
	f.setLevel(t, "Cora", 61)
	f.push(t, a)
	f.push(t, a)
	acWant(t, "forced", f.ask(t, a, proto.OpAcademyForceGradRequest, acStr("cora"), proto.OpAcademyForceGradAck), acB(1))
	acWant(t, "04 forced", f.push(t, a), academy.EncodeGraduated(c.id, 0))
	if n, _ := f.store.Bank(ctx, c.id); n != 3 {
		t.Fatalf("assistant's banked honor %d", n)
	}
}

func TestAcademy865Disband(t *testing.T) {
	f := startAcademy865(t)
	f.found(t)
	f.invite(t, "Bram")
	a, br := f.p["Aria"], f.p["Bram"]
	acWant(t, "not the guardian (on 0xB470)", f.ask(t, br, proto.OpAcademyDisbandRequest, nil, proto.OpAcademyOpenAck), acFailB(academy.ErrOrderWork))
	acWant(t, "no camp (on 0xB470)", f.ask(t, f.p["Dora"], proto.OpAcademyDisbandRequest, nil, proto.OpAcademyOpenAck), acFailB(3))
	// The measured case, on the test's own clock: founded 2.149 s past a
	// minute (CreationDate on the minute), the disband asked 20 min 11.393 s
	// after the CreationDate: 603,589 s left.
	f.advance(20*time.Minute + 9*time.Second + 244*time.Millisecond)
	acWant(t, "window", f.ask(t, a, proto.OpAcademyDisbandRequest, nil, proto.OpAcademyDisbandAck), academy.EncodeFailSeconds(0x681d, 603589))
	f.advance(7 * 24 * time.Hour)
	acWant(t, "disband", f.ask(t, a, proto.OpAcademyDisbandRequest, nil, proto.OpAcademyDisbandAck), acB(1))
	acWant(t, "01 (guardian)", f.push(t, a), acB(1))
	acWant(t, "01 (member)", f.push(t, br), acB(1))
	// The reopen penalty: 0x681c + 604,800 s.
	f.chars.AddGold(context.Background(), a.id, 150_000)
	acWant(t, "reopen", f.ask(t, a, proto.OpAcademyOpenRequest, acU32(f.npc), proto.OpAcademyOpenAck), academy.EncodeFailSeconds(0x681c, 604800))
}

func TestAcademy865WorldEntryLogoutAndMoves(t *testing.T) {
	f := startAcademy865(t)
	f.found(t)
	f.invite(t, "Bram")
	a, br := f.p["Aria"], f.p["Bram"]
	f.push(t, a) // 02
	f.push(t, a) // 0d
	f.push(t, a) // 05
	// A move: 0d to the others.
	e, _ := f.hub.FindByName("Bram")
	f.hub.Relocate(e.Session, world.Position{X: 120, Z: 30}, world.MoveRelocate, 0)
	academyRT.Load().samplePlaces()
	pos := f.push(t, a)
	if pos[0] != academy.PushPosition || binary.LittleEndian.Uint32(pos[1:]) != uint32(br.id) {
		t.Fatalf("move 0d % x", pos)
	}
	// Logout: 05 field 1 = 1 to the others.
	br.conn.Close()
	acWant(t, "logout", f.push(t, a), academy.EncodeFieldU8(br.id, academy.FieldPlayState, academy.PlayOffline))
	// The guardian's view of an offline member: play state 1, its last
	// place, no name.
	camp, _ := f.store.CampOf(context.Background(), a.id)
	m, _ := camp.Member(br.id)
	if l := academyRT.Load().liveOf(m); l.PlayState != academy.PlayOffline || l.Display != "" || l.World != academy.WorldOpen {
		t.Fatalf("offline entry %+v", l)
	}
	// Login: 0x3C81 (its own entry at play state 1 with its name) then 05 to
	// it; 0d then 05 to the others.
	f.login(t, br)
	info := nextOp(t, br.conn, br.r, proto.OpAcademyInfo).Data
	if st, _, name := acEntryOf(t, info, br.id); st != academy.PlayOffline || name != "Bram" {
		t.Fatalf("login 3C81 own entry %d %q", st, name)
	}
	acWant(t, "05 to itself", f.push(t, br), academy.EncodeFieldU8(br.id, academy.FieldPlayState, academy.PlayOnline))
	if p := f.push(t, a); p[0] != academy.PushPosition {
		t.Fatalf("login 0d % x", p)
	}
	acWant(t, "05 to the guardian", f.push(t, a), academy.EncodeFieldU8(br.id, academy.FieldPlayState, academy.PlayOnline))
	if got := academyLobbyByte(context.Background(), a.id); got != 2 {
		t.Fatalf("guardian's lobby byte %d", got)
	}
	if got := academyLobbyByte(context.Background(), br.id); got != 1 {
		t.Fatalf("apprentice's lobby byte %d", got)
	}
	if got := academyLobbyByte(context.Background(), f.p["Dora"].id); got != 0 {
		t.Fatalf("stranger's lobby byte %d", got)
	}
}

func TestAcademy865MatchingBoard(t *testing.T) {
	f := startAcademy865(t)
	a, br := f.p["Aria"], f.p["Bram"]
	reg := func(p *acPlayer) []byte {
		return f.ask(t, p, proto.OpAcademyMatchEntry, append(append(acU32(0), acU32(0)...), append(acB(1), acStr("Join us")...)...),
			proto.OpAcademyMatchEntryAck)
	}
	acWant(t, "empty list", f.ask(t, br, proto.OpAcademyMatchList, acB(0), proto.OpAcademyMatchListAck), acB(1, 0, 0, 0))
	acWant(t, "no camp", reg(a), acFailB(0x6824))
	c := f.found(t)
	acWant(t, "register", reg(a), academy.EncodeMatchEntryOK(academy.MatchEntry{ID: 1, CampID: uint32(c.ID), Flags: 1, Title: "Join us"}, 0))
	acWant(t, "again", reg(a), acFailB(0x6825))
	list := f.ask(t, br, proto.OpAcademyMatchList, acB(0), proto.OpAcademyMatchListAck)
	if list[0] != 1 || list[1] != 1 || list[2] != 0 || list[3] != 1 || !bytes.Contains(list, acStr("Aria")) {
		t.Fatalf("list % x", list)
	}
	// Join refusals: a level-60 requester 3; an assistant to an
	// apprentice-only entry 0x682a.
	acWant(t, "join at 60", f.ask(t, f.p["Dora"], proto.OpAcademyMatchJoin, acU32(1), proto.OpAcademyMatchJoinAck), acFailB(3))
	acWant(t, "join wrong role", f.ask(t, f.p["Cora"], proto.OpAcademyMatchJoin, acU32(1), proto.OpAcademyMatchJoinAck), acFailB(0x682a))
	acWant(t, "no entry", f.ask(t, br, proto.OpAcademyMatchJoin, acU32(9), proto.OpAcademyMatchJoinAck), acFailB(0x6826))
	// A listed camp cannot ban (0x6829) -- checked after the 24 h window.
	f.invite(t, "Bram")
	f.advance(25 * time.Hour)
	acWant(t, "ban while listed", f.ask(t, a, proto.OpAcademyBanRequest, acStr("Bram"), proto.OpAcademyBanAck), acFailB(0x6829))
	acWant(t, "delete", f.ask(t, a, proto.OpAcademyMatchDelete, acU32(1), proto.OpAcademyMatchDeleteAck), acB(1, 1, 0, 0, 0))
	acWant(t, "delete again", f.ask(t, a, proto.OpAcademyMatchDelete, acU32(1), proto.OpAcademyMatchDeleteAck), acFailB(0x6826))
}

func TestAcademy865HonorRankList(t *testing.T) {
	f := startAcademy865(t)
	a := f.p["Aria"]
	acWant(t, "no NPC", f.ask(t, a, proto.OpAcademyHonorRankRequest, acU32(f.npc), proto.OpAcademyHonorRankAck), acFailB(3))
	f.selectNPC(t, a)
	acWant(t, "empty", f.ask(t, a, proto.OpAcademyHonorRankRequest, acU32(f.npc), proto.OpAcademyHonorRankAck), acB(1, 0))
}
