package session

import (
	"bufio"
	"context"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// newMatchWorld is newPartyWorld's five characters (Aria level 10, the rest
// level 7, all at the spawn point) behind the real party and party-match
// handlers (round 713). Eli is Europe, the rest China.
func newMatchWorld(t *testing.T) (*partyWorld, *party.Matcher) {
	t.Helper()
	return newMatchWorldOf(t, []string{"Aria", "Bram", "Cato", "Dara", "Eli"})
}

// newMatchWorldOf is newMatchWorld with these characters (round 752's
// crowd): Aria at level 10 and Eli Europe where present, the rest level 7.
func newMatchWorldOf(t *testing.T, names []string) (*partyWorld, *party.Matcher) {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	chars := character.NewMemStore()
	w := &partyWorld{hub: world.NewHub(), parties: party.NewHub(), chars: chars, ids: map[string]int64{}, c: map[string]*chatClient{}}
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
		if n == "Eli" {
			chars.SetGender(ctx, c.ID, character.GenderEuropeWoman)
		}
		w.ids[n] = c.ID
	}
	w.deps = PartyDeps{Chars: chars, Hub: w.hub, Parties: w.parties, Guilds: guild.NewMemStore(), Skills: skill.NewMemStore()}
	m := party.NewMatcher(w.parties)
	md := PartyMatchDeps{PartyDeps: w.deps, Match: m}
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, nil, w.hub), PartyHandler(w.deps), PartyMatchHandler(md))
	worldGone := WorldDisconnectHandler(w.hub, nil)
	partyGone := PartyDisconnectHandler(w.deps)
	matchGone := PartyMatchDisconnectHandler(md)
	// cmd/server's order: the party removal, the match entry, then the world.
	srv := &gateway.Server{Addr: freeAddr(t), Handle: handle, OnDisconnect: func(s *gateway.Session) { partyGone(s); matchGone(s); worldGone(s) }}
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
	return w, m
}

func matchEntry(purpose, lo, hi uint8, flags party.Flags, title string) []byte {
	return party.AppendEntry(nil, &party.Entry{Flags: flags, Purpose: purpose, MinLevel: lo, MaxLevel: hi, Title: title})
}

// register has name list an entry and returns the 0xb069 reply's entry.
func register(t *testing.T, w *partyWorld, name string, purpose, lo, hi uint8, flags party.Flags) party.Entry {
	t.Helper()
	w.c[name].send(party.OpMatchRegister, matchEntry(purpose, lo, hi, flags, "For open hunting"))
	b := w.c[name].next(party.OpMatchRegAck).Data
	if len(b) < 1 || b[0] != party.ResultOK {
		t.Fatalf("%s register refused: % x", name, b)
	}
	e, _, err := party.ReadEntry(b[1:])
	if err != nil {
		t.Fatal(err)
	}
	return e
}

func refusal(t *testing.T, c *chatClient, op uint16) uint16 {
	t.Helper()
	b := c.next(op).Data
	if len(b) != 3 || b[0] != party.ResultError {
		t.Fatalf("0x%04x: % x, want [2][code]", op, b)
	}
	return uint16(b[1]) | uint16(b[2])<<8
}

func joinResult(t *testing.T, c *chatClient) uint16 {
	t.Helper()
	b := c.next(party.OpMatchJoinAck).Data
	if len(b) != 3 || b[0] != party.ResultOK {
		t.Fatalf("0xb06d: % x, want [1][outcome]", b)
	}
	return uint16(b[1]) | uint16(b[2])<<8
}

type page struct {
	pages, at uint8
	rows      []party.ListEntry
}

func listPage(t *testing.T, c *chatClient, index uint8) page {
	t.Helper()
	c.send(party.OpMatchList, []byte{index})
	b := c.next(party.OpMatchListAck).Data
	if len(b) < 4 || b[0] != party.ResultOK {
		t.Fatalf("0xb06c: % x", b)
	}
	p := page{pages: b[1], at: b[2]}
	rest := b[4:]
	for i := 0; i < int(b[3]); i++ {
		r, more, err := party.ReadListEntry(rest)
		if err != nil {
			t.Fatal(err)
		}
		p.rows = append(p.rows, r)
		rest = more
	}
	return p
}

// request has name ask to join entry and returns the job the leader's 0x706d
// carries.
func request(t *testing.T, w *partyWorld, name, leader string, entry uint32) *party.JoinRequest {
	t.Helper()
	w.c[name].send(party.OpMatchJoin, party.EncodeTarget(entry))
	j, err := party.DecodeJoinRequest(w.c[leader].next(party.OpMatchJoin).Data)
	if err != nil {
		t.Fatal(err)
	}
	return j
}

// TestMatchListRequestAndAcceptFormsAParty is the whole flow with a party-less
// entry: the register echo, the page (the owner's own entry first and again
// in its place), the leader's 0x706d, the accept -- 0xb06d [1][1] twice to the
// requester (SM 0x45003d), none to the leader -- then the formation in the
// GameServer's order with the entry's flags.
func TestMatchListRequestAndAcceptFormsAParty(t *testing.T) {
	w, _ := newMatchWorld(t)
	flags := party.FlagExpShare | party.FlagItemShare
	e := register(t, w, "Aria", party.PurposeHunting, 1, 110, flags)
	if e.Number != 1 || e.PartyID != 0 || e.Flags != flags || e.MaxLevel != 110 || e.Title != "For open hunting" {
		t.Fatalf("register echo %+v", e)
	}
	if st := w.parties.State(w.ids["Aria"]); st != party.StateListed {
		t.Fatalf("Aria's state %d, want 4", st)
	}
	p := listPage(t, w.c["Bram"], 0)
	if p.pages != 1 || p.at != 0 || len(p.rows) != 1 {
		t.Fatalf("Bram's page %+v", p)
	}
	r := p.rows[0]
	if r.Number != 1 || r.Name != "Aria" || r.Race != 0 || r.Count != 1 || r.Flags != flags || r.Purpose != 0 || r.MinLevel != 1 || r.MaxLevel != 110 || r.Time == 0 {
		t.Fatalf("row %+v", r)
	}
	if own := listPage(t, w.c["Aria"], 0); len(own.rows) != 2 || own.rows[0].Number != 1 || own.rows[1].Number != 1 {
		t.Fatalf("Aria's own page %+v", own)
	}
	j := request(t, w, "Bram", "Aria", e.Number)
	if j.JobID == 0 || j.Requester != w.jid("Bram") || j.Entry != 1 || j.Job != party.JobNone || j.Record.Mask != party.MaskFull || j.Record.Name != "Bram" || j.Record.Level != 7 {
		t.Fatalf("0x706d to the leader %+v", j)
	}
	if st := w.parties.State(w.ids["Bram"]); st != party.StatePending {
		t.Fatalf("Bram's state %d, want 1", st)
	}
	w.c["Aria"].send(party.OpMatchAnswer, party.EncodeJoinAnswer(j.JobID, j.Requester, party.AnswerConfirm))
	if o := joinResult(t, w.c["Bram"]); o != party.JoinJoined {
		t.Fatalf("Bram's first 0xb06d %d", o)
	}
	if o := joinResult(t, w.c["Bram"]); o != party.JoinJoined {
		t.Fatalf("Bram's second 0xb06d %d", o)
	}
	// The formation, in GS 0x5bb460's order.
	if a := expectAck(t, w.c["Aria"], party.OpCreateAck); !a.OK || a.ID != w.jid("Aria") {
		t.Fatalf("Aria 0xb060 %+v", a)
	}
	if in := expectInfo(t, w.c["Aria"]); len(in.Members) != 1 || in.Flags != flags {
		t.Fatalf("Aria 0x3065 %+v", in)
	}
	if ev := expectEvent(t, w.c["Aria"]); ev.Kind != party.EventJoined || ev.Record.JID != w.jid("Bram") {
		t.Fatalf("Aria kind 2 %+v", ev)
	}
	w.c["Aria"].none(party.OpMatchJoinAck)
	if a := expectAck(t, w.c["Bram"], party.OpJoinAck); !a.OK || a.ID != w.jid("Bram") {
		t.Fatalf("Bram 0xb067 %+v", a)
	}
	if in := expectInfo(t, w.c["Bram"]); len(in.Members) != 2 || in.Leader != w.jid("Aria") || in.Flags != flags {
		t.Fatalf("Bram 0x3065 %+v", in)
	}
	pt, ok := w.parties.Get(w.ids["Aria"])
	if !ok || pt.LeaderID != w.ids["Aria"] || pt.Flags != flags {
		t.Fatalf("party %+v", pt)
	}
	if p := listPage(t, w.c["Cato"], 0); len(p.rows) != 1 || p.rows[0].Count != 2 {
		t.Fatalf("after the join %+v", p)
	}
	if st := w.parties.State(w.ids["Bram"]); st != party.StateInParty {
		t.Fatalf("Bram's state %d, want 2", st)
	}
}

// TestMatchAcceptIntoAnExistingParty: the requester and then the leader get
// 0xb06d [1][1] (SM 0x450333), then the join as announceJoined sends it.
func TestMatchAcceptIntoAnExistingParty(t *testing.T) {
	w, _ := newMatchWorld(t)
	w.form(t, "Aria", "Cato", party.FlagExpShare)
	e := register(t, w, "Aria", party.PurposeQuest, 1, 110, party.FlagExpShare)
	if e.PartyID == 0 {
		t.Fatal("register echo without the party id")
	}
	j := request(t, w, "Bram", "Aria", e.Number)
	w.c["Aria"].send(party.OpMatchAnswer, party.EncodeJoinAnswer(j.JobID, j.Requester, party.AnswerConfirm))
	if o := joinResult(t, w.c["Bram"]); o != party.JoinJoined {
		t.Fatalf("Bram %d", o)
	}
	if o := joinResult(t, w.c["Aria"]); o != party.JoinJoined {
		t.Fatalf("Aria %d", o)
	}
	if a := expectAck(t, w.c["Bram"], party.OpJoinAck); !a.OK {
		t.Fatalf("Bram 0xb067 %+v", a)
	}
	if in := expectInfo(t, w.c["Bram"]); len(in.Members) != 3 {
		t.Fatalf("Bram 0x3065 %+v", in)
	}
	for _, n := range []string{"Aria", "Cato"} {
		if ev := expectEvent(t, w.c[n]); ev.Kind != party.EventJoined || ev.Record.JID != w.jid("Bram") {
			t.Fatalf("%s heard %+v", n, ev)
		}
	}
}

// TestMatchDenyAndOnlyTheLeaderAnswers: an answer from anyone but the entry's
// leader is ignored (OURS); the leader's cancel gives the requester [1][0].
func TestMatchDenyAndOnlyTheLeaderAnswers(t *testing.T) {
	w, _ := newMatchWorld(t)
	e := register(t, w, "Aria", party.PurposeHunting, 1, 110, 0)
	j := request(t, w, "Bram", "Aria", e.Number)
	w.c["Cato"].send(party.OpMatchAnswer, party.EncodeJoinAnswer(j.JobID, j.Requester, party.AnswerConfirm))
	w.c["Bram"].none(party.OpMatchJoinAck)
	w.c["Aria"].send(party.OpMatchAnswer, party.EncodeJoinAnswer(j.JobID, j.Requester, party.AnswerCancel))
	if o := joinResult(t, w.c["Bram"]); o != party.JoinRefused {
		t.Fatalf("Bram %d, want 0", o)
	}
	if st := w.parties.State(w.ids["Bram"]); st != party.StateFree {
		t.Fatalf("Bram's state %d", st)
	}
	if _, in := w.parties.Get(w.ids["Bram"]); in {
		t.Fatal("a refused requester joined")
	}
}

// TestMatchBackstopGivesNoReply: no answer within the backstop gives the
// requester [1][2]; a late confirm does nothing; the entry takes a new
// request.
func TestMatchBackstopGivesNoReply(t *testing.T) {
	w, m := newMatchWorld(t)
	m.Timeout = 150 * time.Millisecond
	e := register(t, w, "Aria", party.PurposeHunting, 1, 110, 0)
	j := request(t, w, "Bram", "Aria", e.Number)
	if o := joinResult(t, w.c["Bram"]); o != party.JoinNoReply {
		t.Fatalf("Bram %d, want 2", o)
	}
	w.c["Aria"].send(party.OpMatchAnswer, party.EncodeJoinAnswer(j.JobID, j.Requester, party.AnswerConfirm))
	w.c["Bram"].none(party.OpMatchJoinAck)
	if _, in := w.parties.Get(w.ids["Aria"]); in {
		t.Fatal("a late confirm formed a party")
	}
	request(t, w, "Cato", "Aria", e.Number)
}

// TestMatchJoinRefusals: the GameServer's and the ShardManager's join
// ladders, each answered 0xb06d [2][code].
func TestMatchJoinRefusals(t *testing.T) {
	w, _ := newMatchWorld(t)
	e := register(t, w, "Aria", party.PurposeHunting, 8, 9, 0)
	// Level 7 against 8..9.
	w.c["Bram"].send(party.OpMatchJoin, party.EncodeTarget(e.Number))
	if c := refusal(t, w.c["Bram"], party.OpMatchJoinAck); c != party.CodeJoinLevel {
		t.Fatalf("level: %#x", c)
	}
	// No such entry.
	w.c["Bram"].send(party.OpMatchJoin, party.EncodeTarget(99))
	if c := refusal(t, w.c["Bram"], party.OpMatchJoinAck); c != party.CodeNoEntry {
		t.Fatalf("no entry: %#x", c)
	}
	// The owner itself, listed with no party: state 4 at the GameServer.
	w.c["Aria"].send(party.OpMatchJoin, party.EncodeTarget(e.Number))
	if c := refusal(t, w.c["Aria"], party.OpMatchJoinAck); c != party.CodeListed {
		t.Fatalf("own entry: %#x", c)
	}
	// A pending request: the next requester gets 0x2c1f from the
	// ShardManager, the same requester again from the GameServer (state 1).
	w.c["Aria"].send(party.OpMatchChange, party.AppendEntry(nil, &party.Entry{Number: e.Number, Purpose: party.PurposeHunting, MinLevel: 1, MaxLevel: 110, Title: "x"}))
	if b := w.c["Aria"].next(party.OpMatchChgAck).Data; b[0] != party.ResultOK {
		t.Fatalf("change refused % x", b)
	}
	request(t, w, "Bram", "Aria", e.Number)
	w.c["Cato"].send(party.OpMatchJoin, party.EncodeTarget(e.Number))
	if c := refusal(t, w.c["Cato"], party.OpMatchJoinAck); c != party.CodeDuplicate {
		t.Fatalf("second requester: %#x", c)
	}
	w.c["Bram"].send(party.OpMatchJoin, party.EncodeTarget(e.Number))
	if c := refusal(t, w.c["Bram"], party.OpMatchJoinAck); c != party.CodeDuplicate {
		t.Fatalf("same requester again: %#x", c)
	}
	// A party member asking: 0x2c12 at the GameServer.
	w.form(t, "Dara", "Eli", 0)
	w.c["Eli"].send(party.OpMatchJoin, party.EncodeTarget(e.Number))
	if c := refusal(t, w.c["Eli"], party.OpMatchJoinAck); c != party.CodeExistingMember {
		t.Fatalf("party member: %#x", c)
	}
}

// TestMatchRegisterLadder: CheckCanCreateForMatch (GS 0x514170), the purpose
// rule, then the ShardManager's register.
func TestMatchRegisterLadder(t *testing.T) {
	w, _ := newMatchWorld(t)
	reg := func(name string, purpose uint8, flags party.Flags) uint16 {
		w.c[name].send(party.OpMatchRegister, matchEntry(purpose, 1, 110, flags, "t"))
		b := w.c[name].next(party.OpMatchRegAck).Data
		if b[0] == party.ResultOK {
			return 1
		}
		return uint16(b[1]) | uint16(b[2])<<8
	}
	w.hub.SetLevel(w.ids["Eli"], 4)
	if c := reg("Eli", 0, 0); c != party.CodeTooLowCreator {
		t.Fatalf("level 4: %#x", c)
	}
	if c := reg("Bram", party.PurposeTrade, 0); c != party.CodeUserMismatch {
		t.Fatalf("trade purpose without a job: %#x", c)
	}
	if c := reg("Bram", 0, 0); c != 1 {
		t.Fatalf("Bram: %#x", c)
	}
	if c := reg("Bram", 0, 0); c != party.CodeMatchStateBusy {
		t.Fatalf("listed, no party (state 4): %#x", c)
	}
	w.form(t, "Aria", "Cato", 0)
	if c := reg("Cato", 0, 0); c != party.CodeNotLeader {
		t.Fatalf("member: %#x", c)
	}
	if c := reg("Aria", 0, party.FlagExpShare); c != party.CodeEntryFlags {
		t.Fatalf("flags not the party's: %#x", c)
	}
	w.join(t, "Aria", "Dara", "Aria", "Cato")
	w.hub.SetLevel(w.ids["Eli"], 7)
	w.join(t, "Aria", "Eli", "Aria", "Cato", "Dara")
	if c := reg("Aria", 0, 0); c != party.CodeMatchFull {
		t.Fatalf("full: %#x", c)
	}
	w.c["Aria"].send(party.OpKick, party.EncodeTarget(w.jid("Eli")))
	if c := reg("Aria", 0, 0); c != 1 {
		t.Fatalf("leader: %#x", c)
	}
	if c := reg("Aria", 0, 0); c != party.CodeRecordAgain {
		t.Fatalf("again in a party: %#x", c)
	}
}

// TestMatchChangeDeleteAndWithdraw: change echoes the client's entry; delete
// refuses one without an entry of its own (GS 0x5142c0) and a stranger's
// number (SM 0x2c1d); a party-less owner's entry goes when it leaves.
func TestMatchChangeDeleteAndWithdraw(t *testing.T) {
	w, _ := newMatchWorld(t)
	e := register(t, w, "Aria", party.PurposeHunting, 1, 110, 0)
	w.c["Aria"].send(party.OpMatchChange, party.AppendEntry(nil, &party.Entry{Number: e.Number, Purpose: party.PurposeQuest, MinLevel: 5, MaxLevel: 50, Title: "Quests"}))
	b := w.c["Aria"].next(party.OpMatchChgAck).Data
	ce, _, err := party.ReadEntry(b[1:])
	if b[0] != party.ResultOK || err != nil || ce.Number != e.Number || ce.Purpose != party.PurposeQuest || ce.Title != "Quests" {
		t.Fatalf("change echo % x", b)
	}
	if p := listPage(t, w.c["Bram"], 0); p.rows[0].Purpose != party.PurposeQuest || p.rows[0].MinLevel != 5 {
		t.Fatalf("page after change %+v", p.rows[0])
	}
	w.c["Bram"].send(party.OpMatchDelete, party.EncodeTarget(e.Number))
	if c := refusal(t, w.c["Bram"], party.OpMatchDelAck); c != party.CodeNoEntry {
		t.Fatalf("delete without an entry: %#x", c)
	}
	b2 := register(t, w, "Bram", party.PurposeHunting, 1, 110, 0)
	w.c["Bram"].send(party.OpMatchDelete, party.EncodeTarget(e.Number))
	if c := refusal(t, w.c["Bram"], party.OpMatchDelAck); c != party.CodeNotLeader {
		t.Fatalf("delete a stranger's: %#x", c)
	}
	w.c["Bram"].send(party.OpMatchDelete, party.EncodeTarget(b2.Number))
	if a := expectAck(t, w.c["Bram"], party.OpMatchDelAck); !a.OK || a.ID != b2.Number {
		t.Fatalf("delete %+v", a)
	}
	if st := w.parties.State(w.ids["Bram"]); st != party.StateFree {
		t.Fatalf("Bram's state after delete %d", st)
	}
	w.c["Aria"].conn.Close()
	deadline := time.Now().Add(2 * time.Second)
	for {
		if p := listPage(t, w.c["Cato"], 0); p.pages == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("a party-less owner's entry survived its logout")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// TestMatchRaceIsTheOwnersCountry: the row's race byte is the owner's model
// country (SM 0x44f640, char+0x250): Eli is European.
func TestMatchRaceIsTheOwnersCountry(t *testing.T) {
	w, _ := newMatchWorld(t)
	register(t, w, "Eli", party.PurposeHunting, 1, 110, 0)
	if p := listPage(t, w.c["Aria"], 0); p.rows[0].Race != 1 || p.rows[0].Name != "Eli" {
		t.Fatalf("row %+v", p.rows[0])
	}
}

// TestMatchAnswerWithTheWrongRequesterIsDropped: the echoed requester JID
// must be the job's (SM 0x421ec0); a wrong one is dropped with no reply and
// the real answer still resolves the job.
func TestMatchAnswerWithTheWrongRequesterIsDropped(t *testing.T) {
	w, _ := newMatchWorld(t)
	e := register(t, w, "Aria", party.PurposeHunting, 1, 110, 0)
	j := request(t, w, "Bram", "Aria", e.Number)
	w.c["Aria"].send(party.OpMatchAnswer, party.EncodeJoinAnswer(j.JobID, 12345, party.AnswerCancel))
	w.c["Bram"].none(party.OpMatchJoinAck)
	if st := w.parties.State(w.ids["Bram"]); st != party.StatePending {
		t.Fatalf("Bram's state %d after a dropped answer, want 1", st)
	}
	w.c["Aria"].send(party.OpMatchAnswer, party.EncodeJoinAnswer(j.JobID, j.Requester, party.AnswerCancel))
	if o := joinResult(t, w.c["Bram"]); o != party.JoinRefused {
		t.Fatalf("Bram %d", o)
	}
}

// TestMatchChangeNamesTheEntry: change looks up the number the client sent
// (SM 0x4513c0): someone else's is 0x2c1d, an unknown one 0x2c1c.
func TestMatchChangeNamesTheEntry(t *testing.T) {
	w, _ := newMatchWorld(t)
	mine := register(t, w, "Aria", party.PurposeHunting, 1, 110, 0)
	theirs := register(t, w, "Bram", party.PurposeHunting, 1, 110, 0)
	w.c["Aria"].send(party.OpMatchChange, party.AppendEntry(nil, &party.Entry{Number: theirs.Number, Purpose: party.PurposeQuest, MinLevel: 1, MaxLevel: 110, Title: "x"}))
	if c := refusal(t, w.c["Aria"], party.OpMatchChgAck); c != party.CodeNotLeader {
		t.Fatalf("someone else's: %#x", c)
	}
	w.c["Aria"].send(party.OpMatchChange, party.AppendEntry(nil, &party.Entry{Number: 9999, Purpose: party.PurposeQuest, MinLevel: 1, MaxLevel: 110, Title: "x"}))
	if c := refusal(t, w.c["Aria"], party.OpMatchChgAck); c != party.CodeNoEntry {
		t.Fatalf("unknown: %#x", c)
	}
	for _, r := range listPage(t, w.c["Cato"], 0).rows {
		if r.Purpose != party.PurposeHunting {
			t.Fatalf("an entry changed: %+v (mine %d)", r, mine.Number)
		}
	}
}

// TestMatchSweepExpiresSilently: an entry past 60 minutes drops off the
// pages with nothing sent, and its owner may register again at once (OURS:
// the state returns to 0).
func TestMatchSweepExpiresSilently(t *testing.T) {
	w, m := newMatchWorld(t)
	e := register(t, w, "Aria", party.PurposeHunting, 1, 110, 0)
	if gone := m.Sweep(time.Now().Add(62 * time.Minute)); len(gone) != 1 || gone[0] != e.Number {
		t.Fatalf("swept %v", gone)
	}
	w.c["Aria"].none(party.OpMatchDelAck)
	if p := listPage(t, w.c["Bram"], 0); p.pages != 0 {
		t.Fatalf("page after expiry %+v", p)
	}
	if st := w.parties.State(w.ids["Aria"]); st != party.StateFree {
		t.Fatalf("owner state %d", st)
	}
	if e2 := register(t, w, "Aria", party.PurposeHunting, 1, 110, 0); e2.Number <= e.Number {
		t.Fatalf("re-register %+v", e2)
	}
}

// TestMatchLeaderLogoutMovesTheEntry: a listed party leader who leaves the
// world hands the entry to the next leader (SM 0x4296f0 runs the party
// removal before the entry delete).
func TestMatchLeaderLogoutMovesTheEntry(t *testing.T) {
	w, _ := newMatchWorld(t)
	w.form(t, "Aria", "Cato", party.FlagExpShare)
	w.join(t, "Aria", "Dara", "Aria", "Cato")
	e := register(t, w, "Aria", party.PurposeHunting, 1, 110, party.FlagExpShare)
	w.c["Aria"].conn.Close()
	deadline := time.Now().Add(2 * time.Second)
	for {
		p := listPage(t, w.c["Bram"], 0)
		if len(p.rows) == 1 && p.rows[0].Name == "Cato" && p.rows[0].Number == e.Number && p.rows[0].Count == 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("entry did not follow the leader: %+v", p)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// TestMatchRequesterLogoutClearsTheMark: the requester's state byte goes with
// its character; the leader's later accept is answered [2][0x2c0f] (SM
// 0x44fc64), and the entry takes a new request.
func TestMatchRequesterLogoutClearsTheMark(t *testing.T) {
	w, _ := newMatchWorld(t)
	e := register(t, w, "Aria", party.PurposeHunting, 1, 110, 0)
	j := request(t, w, "Bram", "Aria", e.Number)
	w.c["Bram"].conn.Close()
	deadline := time.Now().Add(2 * time.Second)
	for w.parties.State(w.ids["Bram"]) != party.StateFree {
		if time.Now().After(deadline) {
			t.Fatal("requester still pending after its logout")
		}
		time.Sleep(20 * time.Millisecond)
	}
	for {
		if _, ok := w.hub.EntityByCharacterID(w.ids["Bram"]); !ok {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	w.c["Aria"].send(party.OpMatchAnswer, party.EncodeJoinAnswer(j.JobID, j.Requester, party.AnswerConfirm))
	if c := refusal(t, w.c["Aria"], party.OpMatchJoinAck); c != party.CodeInvalidUser {
		t.Fatalf("leader: %#x", c)
	}
	request(t, w, "Cato", "Aria", e.Number)
}
