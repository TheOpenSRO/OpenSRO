package session

import (
	"bufio"
	"context"
	"net"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/grounditem"
	"github.com/OpenSRO/OpenSRO/server/internal/guild"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/party"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/skill"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// partyWorld is five characters in one zone behind the real party handler
// (round 710): Aria (level 10), Bram, Cato, Dara and Eli (level 7), every one
// at the spawn point unless a test moves it.
type partyWorld struct {
	hub     *world.Hub
	parties *party.Hub
	chars   *character.MemStore
	// ground is the ground-item hub behind GroundItemHandler (round 716's
	// gold-split test drops piles into it).
	ground *grounditem.Hub
	deps   PartyDeps
	ids    map[string]int64
	c      map[string]*chatClient
}

func newPartyWorld(t *testing.T) *partyWorld {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	chars := character.NewMemStore()
	w := &partyWorld{hub: world.NewHub(), parties: party.NewHub(), chars: chars, ids: map[string]int64{}, c: map[string]*chatClient{}}
	names := []string{"Aria", "Bram", "Cato", "Dara", "Eli"}
	for i, n := range names {
		accounts.Add(n, "pw")
		c, err := chars.Create(ctx, int64(i+1), n)
		if err != nil {
			t.Fatal(err)
		}
		lvl := 7
		if n == "Aria" {
			lvl = 10
		}
		chars.SetLeveling(ctx, c.ID, lvl, 0, 0, character.StartingStr, character.StartingInt)
		w.ids[n] = c.ID
	}
	skills := skill.NewMemStore()
	w.deps = PartyDeps{Chars: chars, Hub: w.hub, Parties: w.parties, Guilds: guild.NewMemStore(), Skills: skills}
	w.ground = grounditem.NewHub()
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, nil, w.hub), PartyHandler(w.deps),
		ChatHandler(ChatDeps{Hub: w.hub, Parties: w.parties}),
		GroundItemHandler(chars, w.hub, w.ground, inventory.NewMemStore(nil), w.parties))
	worldGone := WorldDisconnectHandler(w.hub, nil)
	partyGone := PartyDisconnectHandler(w.deps)
	srv := &gateway.Server{Addr: freeAddr(t), Handle: handle, OnDisconnect: func(s *gateway.Session) { worldGone(s); partyGone(s) }}
	sctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go srv.ListenAndServe(sctx)
	for _, n := range names {
		conn := dialTestServer(t, srv.Addr)
		t.Cleanup(func() { conn.Close() })
		c := &chatClient{t: t, conn: conn, r: bufio.NewReader(conn)}
		c.send(OpLogin, (&LoginRequest{Username: n, Password: "pw"}).Encode())
		if lr, err := DecodeLoginResult(c.next(OpLoginResult).Data); err != nil || !lr.OK {
			t.Fatalf("%s login: %v %+v", n, err, lr)
		}
		c.send(OpEnterWorld, (&EnterWorldRequest{CharacterName: n}).Encode())
		if er, err := DecodeEnterWorldResult(c.next(OpEnterWorldResult).Data); err != nil || !er.OK {
			t.Fatalf("%s enter: %v %+v", n, err, er)
		}
		w.c[n] = c
	}
	return w
}

func freeAddr(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	return addr
}

func (w *partyWorld) jid(name string) uint32 { return party.JIDOf(w.ids[name]) }

// move puts name at (x, z) on the server's side.
func (w *partyWorld) move(t *testing.T, name string, x, z float64) {
	t.Helper()
	e, ok := w.hub.FindByName(name)
	if !ok {
		t.Fatalf("%s not in the world", name)
	}
	w.hub.Relocate(e.Session, world.Position{X: x, Z: z}, world.MoveRelocate, 0)
}

func expectAck(t *testing.T, c *chatClient, op uint16) party.Ack {
	t.Helper()
	a, err := party.DecodeIDAck(c.next(op).Data)
	if err != nil {
		t.Fatalf("0x%04x: %v", op, err)
	}
	return a
}

func expectEvent(t *testing.T, c *chatClient) party.Event {
	t.Helper()
	e, err := party.DecodeEvent(c.next(party.OpEvent).Data)
	if err != nil {
		t.Fatal(err)
	}
	return e
}

func expectInfo(t *testing.T, c *chatClient) *party.Info {
	t.Helper()
	in, err := party.DecodeInfo(c.next(party.OpInfo).Data)
	if err != nil {
		t.Fatal(err)
	}
	return in
}

// nextParty reads the next party message (any of the party opcodes), skipping
// everything else, so an order can be checked.
func nextParty(t *testing.T, c *chatClient) *proto.Packet {
	t.Helper()
	for {
		c.conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		p, err := proto.Read(c.r, nil, nil)
		if err != nil {
			t.Fatalf("waiting for a party message: %v", err)
		}
		switch p.Opcode {
		case party.OpCreateAck, party.OpInviteAck, party.OpJoinAck, party.OpInfo, party.OpInvitation, party.OpEvent:
			return p
		}
	}
}

// form has a invite b to a new party with flags, b accept, and drains the
// formation's messages from both.
func (w *partyWorld) form(t *testing.T, a, b string, flags party.Flags) {
	t.Helper()
	w.c[a].send(party.OpCreate, party.EncodeCreate(w.jid(b), flags))
	w.c[b].next(party.OpInvitation)
	w.c[b].send(party.OpInvitation, party.EncodeAnswerYes())
	expectAck(t, w.c[a], party.OpCreateAck)
	expectInfo(t, w.c[a])
	expectEvent(t, w.c[a])
	expectAck(t, w.c[b], party.OpJoinAck)
	expectInfo(t, w.c[b])
}

// join has inviter invite name into its party, name accept, and drains the
// join's messages from the joiner and every member listed in others.
func (w *partyWorld) join(t *testing.T, inviter, name string, others ...string) {
	t.Helper()
	w.c[inviter].send(party.OpInvite, party.EncodeTarget(w.jid(name)))
	w.c[name].next(party.OpInvitation)
	w.c[name].send(party.OpInvitation, party.EncodeAnswerYes())
	expectAck(t, w.c[name], party.OpJoinAck)
	expectInfo(t, w.c[name])
	for _, o := range others {
		if e := expectEvent(t, w.c[o]); e.Kind != party.EventJoined || e.Record.JID != w.jid(name) {
			t.Fatalf("%s heard %+v, want %s's join", o, e, name)
		}
	}
}

// TestPartyFormedByInvitation is the 0x7060 flow end to end, in the
// GameServer's order (trs_sm_partyjob::FUN_005be710): the invitee sees 0x3080
// kind 2; on yes the inviter gets 0xb060 [1][own JID], a 0x3065 of itself,
// then the invitee's kind 2; the invitee 0xb067 [1][own JID] and the 0x3065
// of both.
func TestPartyFormedByInvitation(t *testing.T) {
	w := newPartyWorld(t)
	w.c["Aria"].send(party.OpCreate, party.EncodeCreate(w.jid("Bram"), party.FlagExpShare|party.FlagItemShare))
	kind, inviter, flags, err := party.DecodeInvitation(w.c["Bram"].next(party.OpInvitation).Data)
	if err != nil || kind != party.InviteForm || inviter != w.jid("Aria") || flags != 0x03 {
		t.Fatalf("invitation %d %d %#x %v", kind, inviter, flags, err)
	}
	if st := w.parties.State(w.ids["Bram"]); st != party.StatePending {
		t.Fatalf("invitee state %d, want 1", st)
	}
	w.c["Bram"].send(party.OpInvitation, party.EncodeAnswerYes())

	p := nextParty(t, w.c["Aria"])
	if a, _ := party.DecodeIDAck(p.Data); p.Opcode != party.OpCreateAck || !a.OK || a.ID != w.jid("Aria") {
		t.Fatalf("inviter's first: 0x%04x % x", p.Opcode, p.Data)
	}
	p = nextParty(t, w.c["Aria"])
	in, err := party.DecodeInfo(p.Data)
	if p.Opcode != party.OpInfo || err != nil || in.Leader != w.jid("Aria") || in.Flags != 0x03 || len(in.Members) != 1 || in.Members[0].JID != w.jid("Aria") {
		t.Fatalf("inviter's 0x3065: %+v %v", in, err)
	}
	if in.Members[0].Mask != party.MaskFull || in.Members[0].Name != "Aria" || in.Members[0].Level != 10 || in.Members[0].Job != party.JobNone || in.Members[0].WorldID != 1 {
		t.Fatalf("inviter's record %+v", in.Members[0])
	}
	p = nextParty(t, w.c["Aria"])
	ev, _ := party.DecodeEvent(p.Data)
	if p.Opcode != party.OpEvent || ev.Kind != party.EventJoined || ev.Record.JID != w.jid("Bram") || ev.Record.Name != "Bram" {
		t.Fatalf("inviter's third: %+v", ev)
	}

	p = nextParty(t, w.c["Bram"])
	if a, _ := party.DecodeIDAck(p.Data); p.Opcode != party.OpJoinAck || !a.OK || a.ID != w.jid("Bram") {
		t.Fatalf("invitee's first: 0x%04x % x", p.Opcode, p.Data)
	}
	p = nextParty(t, w.c["Bram"])
	in, _ = party.DecodeInfo(p.Data)
	if p.Opcode != party.OpInfo || len(in.Members) != 2 || in.Members[0].JID != w.jid("Aria") || in.Members[1].JID != w.jid("Bram") || in.PartyID == 0 {
		t.Fatalf("invitee's 0x3065: %+v", in)
	}
	pt, ok := w.parties.Get(w.ids["Bram"])
	if !ok || pt.LeaderID != w.ids["Aria"] || pt.Flags != 0x03 {
		t.Fatalf("hub party %+v", pt)
	}
}

// TestPartyCreateLadder is CheckCanCreate and the 0x7060 handler's order
// (READ, GS 0x513f90, 0x5143b0): level 5 first, the self-target dropped
// silently, the target not found 0, out of 600 units 4, an NPC uid 3, a target
// already invited 0x2c1f, in another party 0x2c18.
func TestPartyCreateLadder(t *testing.T) {
	w := newPartyWorld(t)
	w.chars.SetLeveling(context.Background(), w.ids["Eli"], 4, 0, 0, character.StartingStr, character.StartingInt)
	w.hub.SetLevel(w.ids["Eli"], 4)
	refusal := func(from string) uint16 {
		t.Helper()
		a := expectAck(t, w.c[from], party.OpCreateAck)
		if a.OK {
			t.Fatalf("%s's create was accepted", from)
		}
		return a.Code
	}
	w.c["Eli"].send(party.OpCreate, party.EncodeCreate(w.jid("Bram"), 0))
	if c := refusal("Eli"); c != party.CodeTooLowCreator {
		t.Fatalf("level 4 = %#x, want 0x2c0a", c)
	}
	w.c["Aria"].send(party.OpCreate, party.EncodeCreate(w.jid("Aria"), 0))
	w.c["Aria"].none(party.OpCreateAck)
	w.c["Aria"].send(party.OpCreate, party.EncodeCreate(99999, 0))
	if c := refusal("Aria"); c != party.CodeNotFound {
		t.Fatalf("nobody = %#x, want 0", c)
	}
	w.c["Aria"].send(party.OpCreate, party.EncodeCreate(0x7f000005, 0))
	if c := refusal("Aria"); c != party.CodeWrongType {
		t.Fatalf("an NPC = %#x, want 3", c)
	}
	w.move(t, "Cato", 601, 0)
	w.c["Aria"].send(party.OpCreate, party.EncodeCreate(w.jid("Cato"), 0))
	if c := refusal("Aria"); c != party.CodeTooFar {
		t.Fatalf("601 away = %#x, want 4", c)
	}
	w.move(t, "Cato", 600, 0)
	w.c["Aria"].send(party.OpCreate, party.EncodeCreate(w.jid("Cato"), 0))
	w.c["Cato"].next(party.OpInvitation) // exactly 600 is in range
	w.c["Dara"].send(party.OpCreate, party.EncodeCreate(w.jid("Cato"), 0))
	if c := refusal("Dara"); c != party.CodeDuplicate {
		t.Fatalf("an invited target = %#x, want 0x2c1f", c)
	}
	// The inviter, with a formation invitation out, is state 1 too.
	w.c["Dara"].send(party.OpCreate, party.EncodeCreate(w.jid("Aria"), 0))
	if c := refusal("Dara"); c != party.CodeDuplicate {
		t.Fatalf("a target with an invitation out = %#x, want 0x2c1f", c)
	}
	w.c["Cato"].send(party.OpInvitation, party.EncodeAnswerYes())
	expectAck(t, w.c["Aria"], party.OpCreateAck)
	w.c["Dara"].send(party.OpCreate, party.EncodeCreate(w.jid("Cato"), 0))
	if c := refusal("Dara"); c != party.CodeOtherParty {
		t.Fatalf("a member of another party = %#x, want 0x2c18", c)
	}
}

// TestPartyDecline: a no to a formation refuses 0x2c0c to both sides; to a
// join, 0x2c17 (inviter on 0xb062).
func TestPartyDecline(t *testing.T) {
	w := newPartyWorld(t)
	w.c["Aria"].send(party.OpCreate, party.EncodeCreate(w.jid("Bram"), 0))
	w.c["Bram"].next(party.OpInvitation)
	w.c["Bram"].send(party.OpInvitation, party.EncodeAnswerNo(party.CodeCreateRefused))
	if a := expectAck(t, w.c["Aria"], party.OpCreateAck); a.OK || a.Code != party.CodeCreateRefused {
		t.Fatalf("inviter %+v", a)
	}
	if a := expectAck(t, w.c["Bram"], party.OpJoinAck); a.OK || a.Code != party.CodeCreateRefused {
		t.Fatalf("invitee %+v", a)
	}
	w.form(t, "Aria", "Bram", party.FlagExpShare)
	w.c["Aria"].send(party.OpInvite, party.EncodeTarget(w.jid("Cato")))
	if _, inv, _, _ := party.DecodeInvitation(w.c["Cato"].next(party.OpInvitation).Data); inv != w.jid("Aria") {
		t.Fatal("join invitation's inviter")
	}
	w.c["Cato"].send(party.OpInvitation, party.EncodeAnswerNo(party.CodeJoinRefused))
	if a := expectAck(t, w.c["Aria"], party.OpInviteAck); a.OK || a.Code != party.CodeJoinRefused {
		t.Fatalf("inviter %+v", a)
	}
	if a := expectAck(t, w.c["Cato"], party.OpJoinAck); a.OK || a.Code != party.CodeJoinRefused {
		t.Fatalf("invitee %+v", a)
	}
}

// TestPartyInviteTimesOut: no answer within the timeout gives 0x2c10 to both,
// and a late yes forms nothing.
func TestPartyInviteTimesOut(t *testing.T) {
	w := newPartyWorld(t)
	w.parties.Timeout = 150 * time.Millisecond
	w.c["Aria"].send(party.OpCreate, party.EncodeCreate(w.jid("Bram"), 0))
	w.c["Bram"].next(party.OpInvitation)
	if a := expectAck(t, w.c["Aria"], party.OpCreateAck); a.OK || a.Code != party.CodeTimeout {
		t.Fatalf("inviter %+v", a)
	}
	if a := expectAck(t, w.c["Bram"], party.OpJoinAck); a.OK || a.Code != party.CodeTimeout {
		t.Fatalf("invitee %+v", a)
	}
	w.c["Bram"].send(party.OpInvitation, party.EncodeAnswerYes())
	w.c["Aria"].none(party.OpCreateAck)
	if _, in := w.parties.Get(w.ids["Aria"]); in {
		t.Fatal("a yes after the timeout formed a party")
	}
}

// TestPartyCapsAndInviteRules: a non-shared party holds 4 and refuses the
// fifth with 0x2c14 on 0xb062; only the leader may invite unless bit 2 is set
// (a member's invite is dropped silently otherwise).
func TestPartyCapsAndInviteRules(t *testing.T) {
	w := newPartyWorld(t)
	w.form(t, "Aria", "Bram", party.FlagItemShare)
	w.c["Bram"].send(party.OpInvite, party.EncodeTarget(w.jid("Cato")))
	w.c["Cato"].none(party.OpInvitation)
	w.c["Bram"].none(party.OpInviteAck)
	w.join(t, "Aria", "Cato", "Aria", "Bram")
	w.join(t, "Aria", "Dara", "Aria", "Bram", "Cato")
	w.c["Aria"].send(party.OpInvite, party.EncodeTarget(w.jid("Eli")))
	if a := expectAck(t, w.c["Aria"], party.OpInviteAck); a.OK || a.Code != party.CodeFullNotShared {
		t.Fatalf("the fifth = %+v, want 0x2c14", a)
	}
	w.c["Eli"].none(party.OpInvitation)

	w2 := newPartyWorld(t)
	w2.form(t, "Aria", "Bram", party.FlagExpShare|party.FlagAnyoneInvite)
	w2.join(t, "Bram", "Cato", "Aria", "Bram")
}

// TestPartyKickLeaveAndSuccession: kick sends kind 3 reason 4 to every member,
// the kicked one too; the leader's leave sends kind 3 reason 2 and kind 9 with
// the longest-standing member; the last two dissolve with kind 1 0x2c0b. A
// non-leader's kick is dropped.
func TestPartyKickLeaveAndSuccession(t *testing.T) {
	w := newPartyWorld(t)
	w.form(t, "Aria", "Bram", party.FlagExpShare)
	w.join(t, "Aria", "Cato", "Aria", "Bram")
	w.join(t, "Aria", "Dara", "Aria", "Bram", "Cato")

	w.c["Bram"].send(party.OpKick, party.EncodeTarget(w.jid("Cato")))
	w.c["Cato"].none(party.OpEvent)

	w.c["Aria"].send(party.OpKick, party.EncodeTarget(w.jid("Dara")))
	for _, n := range []string{"Aria", "Bram", "Cato", "Dara"} {
		if e := expectEvent(t, w.c[n]); e.Kind != party.EventLeft || e.JID != w.jid("Dara") || e.Reason != party.ReasonKicked {
			t.Fatalf("%s heard %+v, want Dara kicked", n, e)
		}
	}
	w.c["Aria"].send(party.OpLeave, nil)
	for _, n := range []string{"Aria", "Bram", "Cato"} {
		if e := expectEvent(t, w.c[n]); e.Kind != party.EventLeft || e.JID != w.jid("Aria") || e.Reason != party.ReasonLeave {
			t.Fatalf("%s heard %+v, want Aria left", n, e)
		}
	}
	for _, n := range []string{"Bram", "Cato"} {
		if e := expectEvent(t, w.c[n]); e.Kind != party.EventLeader || e.JID != w.jid("Bram") {
			t.Fatalf("%s heard %+v, want Bram leading", n, e)
		}
	}
	w.c["Aria"].none(party.OpEvent)
	w.c["Cato"].send(party.OpLeave, nil)
	for _, n := range []string{"Bram", "Cato"} {
		if e := expectEvent(t, w.c[n]); e.Kind != party.EventDissolved || e.Code != party.CodeDissolved {
			t.Fatalf("%s heard %+v, want the dissolution", n, e)
		}
	}
	if _, in := w.parties.Get(w.ids["Bram"]); in {
		t.Fatal("a party of one survived")
	}
}

// TestPartyLogoutRemovesWithReasonOne: a member who disconnects is removed
// with reason 1.
func TestPartyLogoutRemovesWithReasonOne(t *testing.T) {
	w := newPartyWorld(t)
	w.form(t, "Aria", "Bram", party.FlagExpShare)
	w.join(t, "Aria", "Cato", "Aria", "Bram")
	w.c["Cato"].conn.Close()
	for _, n := range []string{"Aria", "Bram"} {
		if e := expectEvent(t, w.c[n]); e.Kind != party.EventLeft || e.JID != w.jid("Cato") || e.Reason != party.ReasonLogout {
			t.Fatalf("%s heard %+v, want Cato logged out", n, e)
		}
	}
}

// TestPartyAnswerAfterTheInviterLeft is refused 0x2c0e, as the engine does.
// Whatever the answer: the GameServer tests the inviter before the answer
// (READ, GS 0x5be350).
func TestPartyAnswerAfterTheInviterLeft(t *testing.T) {
	for _, answer := range [][]byte{party.EncodeAnswerYes(), party.EncodeAnswerNo(party.CodeCreateRefused)} {
		w := newPartyWorld(t)
		w.c["Aria"].send(party.OpCreate, party.EncodeCreate(w.jid("Bram"), 0))
		w.c["Bram"].next(party.OpInvitation)
		w.c["Aria"].conn.Close()
		waitGone(t, w, "Aria")
		w.c["Bram"].send(party.OpInvitation, answer)
		if a := expectAck(t, w.c["Bram"], party.OpJoinAck); a.OK || a.Code != party.CodeCantFindCreator {
			t.Fatalf("answer % x: invitee %+v, want 0x2c0e", answer, a)
		}
	}
}

func waitGone(t *testing.T, w *partyWorld, name string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		if _, on := w.hub.FindByName(name); !on {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("%s never left the world", name)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// TestPartyInviteeDisconnectFreesIt: an invitee who leaves the world no longer
// holds the invitation, and the inviter still hears the timeout (OURS,
// party.Hub.DetachSession).
func TestPartyInviteeDisconnectFreesIt(t *testing.T) {
	w := newPartyWorld(t)
	w.parties.Timeout = 400 * time.Millisecond
	w.c["Aria"].send(party.OpCreate, party.EncodeCreate(w.jid("Eli"), 0))
	w.c["Eli"].next(party.OpInvitation)
	w.c["Eli"].conn.Close()
	waitGone(t, w, "Eli")
	if st := w.parties.State(w.ids["Eli"]); st != party.StateFree {
		t.Fatalf("a departed invitee's state %d, want 0", st)
	}
	if st := w.parties.State(w.ids["Aria"]); st != party.StatePending {
		t.Fatalf("the inviter's state %d, want 1 until the timeout", st)
	}
	if a := expectAck(t, w.c["Aria"], party.OpCreateAck); a.OK || a.Code != party.CodeTimeout {
		t.Fatalf("inviter %+v, want the timeout", a)
	}
}

// TestPartyJoinKeepsOthersPendingUpdates: a join builds only the joiner's
// record (GS 0x5bc210); a member's change the sampler has not sent yet is
// still sent after it.
func TestPartyJoinKeepsOthersPendingUpdates(t *testing.T) {
	w := newPartyWorld(t)
	w.form(t, "Aria", "Bram", party.FlagExpShare)
	w.move(t, "Bram", 150, 10)
	w.join(t, "Aria", "Cato", "Aria", "Bram")
	w.deps.sendPartyUpdates(context.Background())
	for _, n := range []string{"Aria", "Cato"} {
		if e := expectEvent(t, w.c[n]); e.Kind != party.EventUpdate || e.JID != w.jid("Bram") || e.Record.Mask != party.MaskPosition {
			t.Fatalf("%s heard %+v, want Bram's position", n, e)
		}
	}
}

// TestPartyFlagGates: pickup rights need the item-share bit; the gap bonus and
// the nest arming need the exp-share bit (round 710's second review).
func TestPartyFlagGates(t *testing.T) {
	m := func(id int64) party.Member {
		return party.Member{Session: gateway.NewTestSession(uint64(7700 + id)), CharacterID: id, Name: "m", Level: 10}
	}
	h := party.NewHub()
	h.Form(m(1), m(2), party.FlagExpShare)
	h.Form(m(3), m(4), party.FlagItemShare)
	same := samePartyFunc(h)
	if same(1, 2) {
		t.Fatal("an item free-for-all party shared pickup rights")
	}
	if !same(3, 4) || same(1, 3) {
		t.Fatal("item-share pickup rights")
	}
	// Round 712: the exp-share gate is the distributor's grouping
	// (partyGroupOf, planKill); killshare_test covers the gap bonus and the
	// arming through it.
	if group := partyGroupOf(h); group(1) == 0 || group(3) != 0 {
		t.Fatal("the exp-share gate")
	}
}

func TestPartyPositionWithoutAFrame(t *testing.T) {
	if _, _, _, _, ok := partyPosition(world.Entity{Zone: "nowhere"}); ok {
		t.Fatal("a zone with no frame gave a position")
	}
	if _, _, _, _, ok := partyPosition(world.Entity{Zone: "jangan"}); !ok {
		t.Fatal("jangan has a frame")
	}
}

// TestPartyMemberUpdates: a moved member is reported to the others as kind 6
// with only the position bit, and not to itself; an unchanged member is not
// reported.
func TestPartyMemberUpdates(t *testing.T) {
	w := newPartyWorld(t)
	w.form(t, "Aria", "Bram", party.FlagExpShare)
	w.deps.sendPartyUpdates(context.Background())
	w.c["Aria"].none(party.OpEvent)
	w.move(t, "Bram", 120, -40)
	w.deps.sendPartyUpdates(context.Background())
	e := expectEvent(t, w.c["Aria"])
	if e.Kind != party.EventUpdate || e.JID != w.jid("Bram") || e.Record.Mask != party.MaskPosition {
		t.Fatalf("update %+v", e)
	}
	w.c["Bram"].none(party.OpEvent)
	w.deps.sendPartyUpdates(context.Background())
	w.c["Aria"].none(party.OpEvent)
}

// TestPartyChatReachesMembersOnly: a party line reaches every member, the
// sender included, and nobody else.
func TestPartyChatReachesMembersOnly(t *testing.T) {
	w := newPartyWorld(t)
	w.form(t, "Aria", "Bram", party.FlagExpShare)
	w.c["Bram"].say(ChatParty, 1, "", "pull")
	for _, n := range []string{"Aria", "Bram"} {
		if u := w.c[n].update(); *u != (ChatUpdate{Type: ChatParty, Sender: "Bram", Message: "pull"}) {
			t.Fatalf("%s heard %+v", n, u)
		}
	}
	for _, n := range []string{"Cato", "Dara", "Eli"} {
		w.c[n].none(OpChatUpdate)
	}
}

func TestTopMasteries(t *testing.T) {
	a, b := topMasteries(map[int64]int{257: 3, 258: 9, 259: 9, 260: 0, 261: 1})
	if a != 258 || b != 259 {
		t.Fatalf("got %d %d, want 258 259", a, b)
	}
	if a, b := topMasteries(map[int64]int{257: 0}); a != 0 || b != 0 {
		t.Fatalf("level-0 masteries shown: %d %d", a, b)
	}
}

func TestPartyUpdateRules(t *testing.T) {
	rec := party.Record{Level: 10, HPMP: 0xaa, Region: 1, X: 5, Y: 6, Z: 7, WorldID: 1, Guild: "g", Mastery1: 1, Name: "a", RefObjID: 9}
	prev := memberSample{rec: rec, hp: 200, maxHP: 200, mp: 200, maxMP: 200}
	// Nothing moved: no update, though the update formula would give 0xab
	// for the same values (the engine evaluates it only on an HP/MP event).
	if u := partyUpdate(prev, prev); u.Mask != 0 {
		t.Fatalf("nothing changed: %+v", u)
	}
	// HP moved within the same step: evaluated, and the formula's own value
	// for full MP and 199/200 HP is step 1 + 9 = 10 HP, 10 MP -- 0xaa, no change.
	now := prev
	now.hp = 199
	if u := partyUpdate(prev, now); u.Mask != 0 || u.HPMP != 0xaa {
		t.Fatalf("199/200: %+v", u)
	}
	// Back to full: step 11, sent.
	prev199 := now
	now.hp = 200
	if u := partyUpdate(prev199, now); u.Mask != party.MaskHPMP || u.HPMP != 0xab {
		t.Fatalf("full again: %+v, want 0xab", u)
	}
	now = prev
	now.rec.Level, now.rec.Guild, now.rec.Mastery2, now.rec.RefObjID = 11, "h", 2, 10
	u := partyUpdate(prev, now)
	if u.Mask != party.MaskLevel|party.MaskGuild|party.MaskMastery|party.MaskName {
		t.Fatalf("mask %#x", u.Mask)
	}
	if u.Mask&(party.MaskJID|party.MaskJob) != 0 {
		t.Fatal("an update carried the JID or the job")
	}
}
