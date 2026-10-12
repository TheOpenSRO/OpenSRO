// Command partybot drives characters on the party's real wire against a
// running server (round 710), for live tests where a second Godot client is
// not available: qa_shot.sh stops every client on the render box before it
// starts, so the other side of a party is played by this.
//
// Each bot registers an account, logs in, creates a character through the
// retail lobby (0x7007), enters the world (0x7001) and, as a GM account,
// raises itself to -level with the console's /level. The server needs a
// creatable catalogue (-chargen-csv) and must list the bots' accounts in
// -gm-accounts (or the level stays 1, and a level-1 character cannot form a
// party).
//
// Two modes:
//
//	partybot -mode scenario -addr HOST:PORT [-prefix pb]
//	    The round-710 acceptance run with five characters: forming by
//	    invitation, the 4-member cap of a non-shared party, a kick (reason 4),
//	    a leave (reason 2) with the leadership passing, the two-member
//	    dissolution, party chat reaching members only, and a logout (reason 1).
//	    Prints every party message each character receives and exits 1 on the
//	    first expectation that fails.
//
//	partybot -mode match -addr HOST:PORT [-prefix pm]
//	    The round-713 party-match acceptance run with four characters: a
//	    party-less entry registered, paged and requested; a request outside
//	    the level range refused 0x2c1e; a second request while one is pending
//	    refused 0x2c1f; the leader's confirm forming the party with the
//	    entry's flags; a request left unanswered until the 15 s backstop
//	    answers 2; the entry deleted. Takes about 20 s (the backstop).
//
//	partybot -mode share -addr HOST:PORT [-prefix ps] [-monster NAME] [-level N]
//	    The round-712 sharing run: a solo kill as the baseline, then a kill by
//	    one member of an Exp Auto Share party of two (both must gain the
//	    baseline x 0.55), then one by a member of an Exp Free-For-All party
//	    of two (the killer gains the baseline x 1.03, the other nothing). The
//	    kills are real blows: a GM /damage (credited to the killer on the
//	    monster's damage list, paying nothing itself) leaves the monster at 1
//	    HP and a swing kills it. Needs -leveldata-csv and -monsters-csv. The
//	    x0.55 relation holds for a species less than 5 levels above the bots:
//	    from 5 up an exp-share member also earns the party gap bonus
//	    (leveldata.ExpDiffPartyBonus), which the solo baseline does not.
//
//	partybot -mode pickup -addr HOST:PORT [-prefix r785] [-monster NAME] [-kills N]
//	         [-pick] [-at "x y z"] [-wait D]
//	    The round-785 drop run (pickup.go): one character kills N monsters
//	    beside itself and prints where each kill's stacks landed and how far
//	    apart; with -pick it walks up to each and picks it, checking the 0x3036
//	    pick-up motion the zone is sent. -at and -wait stand it beside a QA
//	    client first, which then draws its pick-ups as another player's.
//
//	partybot -mode bot -addr HOST:PORT -name Bram [-accept=true] [-invite NAME]
//	         [-register] [-request NAME]
//	    One character that stays online: answers every invitation and every
//	    party-match join request (yes with -accept, no without), optionally
//	    invites NAME once it sees it, registers a party-match entry
//	    (-register: Exp+Item Auto Share, Hunting, levels 1..110), or asks to
//	    join NAME's entry once it is on page 0 (-request NAME), and prints the
//	    party traffic -- the other side of a live client test.
package main

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"github.com/OpenSRO/OpenSRO/server/internal/charmsg"
	"net"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/OpenSRO/OpenSRO/server/internal/party"
	"github.com/OpenSRO/OpenSRO/server/internal/pcspawn"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/session"
)

type bot struct {
	name string
	conn net.Conn
	r    *bufio.Reader
	wmu  sync.Mutex
	id   int64
	in   chan *proto.Packet
	// other carries the replies the share mode waits on (attack, GM, stats).
	other chan *proto.Packet
	// ground carries the ground-item traffic the pickup mode waits on
	// (round 785, isGround).
	ground chan *proto.Packet
	mu     sync.Mutex
	seen   map[string]int64 // character name -> id, from the world messages
	// group is the group spawn being received (round 737).
	group []npcspawn.GroupFrame
	// zone and x, y, z are where the character entered the world.
	zone    string
	x, y, z float32
	// gains are the 0x3056 EXP gains this character was sent (round 716).
	gains []charmsg.ExpGain
}

// lastGain is the newest 0x3056 b was sent, and how many it has had.
func (b *bot) lastGain() (charmsg.ExpGain, int) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if len(b.gains) == 0 {
		return charmsg.ExpGain{}, 0
	}
	return b.gains[len(b.gains)-1], len(b.gains)
}

// moveTo puts the character at (x, y, z), as a relocation (OpMove with the
// relocated flag: the server takes the position as sent).
func (b *bot) moveTo(x, y, z float32) error {
	return b.send(session.OpMove, (&session.MoveRequest{X: x, Y: y, Z: z, Relocated: true}).Encode())
}

func (b *bot) jid() uint32 { return party.JIDOf(b.id) }

func (b *bot) send(op uint16, data []byte) error {
	b.wmu.Lock()
	defer b.wmu.Unlock()
	return proto.Write(b.conn, &proto.Packet{Opcode: op, Data: data}, nil, nil)
}

// readSync reads until op arrives (the login steps, before the reader runs).
func (b *bot) readSync(op uint16) (*proto.Packet, error) {
	for {
		b.conn.SetReadDeadline(time.Now().Add(5 * time.Second))
		p, err := proto.Read(b.r, nil, nil)
		if err != nil {
			return nil, fmt.Errorf("%s waiting for 0x%04x: %w", b.name, op, err)
		}
		b.note(p)
		if p.Opcode == op {
			return p, nil
		}
	}
}

// note learns names and ids from the world messages.
func (b *bot) note(p *proto.Packet) {
	switch p.Opcode {
	case session.OpSelfID:
		if s, err := session.DecodeSelfID(p.Data); err == nil {
			b.id = s.CharacterID
		}
	case session.OpEnterWorldResult:
		if r, err := session.DecodeEnterWorldResult(p.Data); err == nil {
			b.mu.Lock()
			for _, o := range r.Others {
				b.seen[o.Name] = o.CharacterID
			}
			b.mu.Unlock()
		}
	case session.OpEntityEntered:
		if e, err := session.DecodeEntityEntered(p.Data); err == nil {
			b.mu.Lock()
			b.seen[e.Name] = e.CharacterID
			b.mu.Unlock()
		}
	// Round 737: the players in view arrive as retail's spawns, a 0x3015 or a
	// group (0x3017 / 0x3019 / 0x3018) of pcspawn records.
	case npcspawn.OpSingleSpawn:
		if rec, _, err := pcspawn.Decode(p.Data, nil); err == nil {
			b.saw(rec)
		}
	case npcspawn.OpGroupBegin:
		b.mu.Lock()
		b.group = []npcspawn.GroupFrame{{Opcode: p.Opcode, Data: p.Data}}
		b.mu.Unlock()
	case npcspawn.OpGroupData, npcspawn.OpGroupEnd:
		b.mu.Lock()
		b.group = append(b.group, npcspawn.GroupFrame{Opcode: p.Opcode, Data: p.Data})
		frames := b.group
		b.mu.Unlock()
		if p.Opcode == npcspawn.OpGroupEnd && len(frames) >= 2 && len(frames[0].Data) == 3 && frames[0].Data[0] == npcspawn.GroupSpawn {
			var body []byte
			for _, f := range frames[1 : len(frames)-1] {
				body = append(body, f.Data...)
			}
			n := int(frames[0].Data[1]) | int(frames[0].Data[2])<<8
			for i := 0; i < n; i++ {
				rec, rest, err := pcspawn.Decode(body, nil)
				if err != nil {
					break // an NPC's record: the rest is not this bot's
				}
				b.saw(rec)
				body = rest
			}
		}
	}
}

// saw files a spawned player's name under its uid (the character id's low
// 32 bits, as OpenSRO names players on retail messages).
func (b *bot) saw(rec pcspawn.Record) {
	b.mu.Lock()
	b.seen[rec.Name] = int64(rec.UID)
	b.mu.Unlock()
}

func (b *bot) idOf(name string) (int64, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	id, ok := b.seen[name]
	return id, ok
}

func isParty(op uint16) bool {
	switch op {
	case party.OpCreateAck, party.OpInviteAck, party.OpJoinAck, party.OpInfo, party.OpInvitation, party.OpEvent,
		party.OpMatchRegAck, party.OpMatchChgAck, party.OpMatchDelAck, party.OpMatchListAck, party.OpMatchJoin, party.OpMatchJoinAck:
		return true
	}
	return false
}

// describe renders a party message for the trace.
func describe(p *proto.Packet) string {
	switch p.Opcode {
	case party.OpCreateAck, party.OpInviteAck, party.OpJoinAck:
		a, err := party.DecodeIDAck(p.Data)
		if err != nil {
			return fmt.Sprintf("0x%04x malformed % x", p.Opcode, p.Data)
		}
		if a.OK {
			return fmt.Sprintf("0x%04x [1] jid=%d", p.Opcode, a.ID)
		}
		return fmt.Sprintf("0x%04x [2] code=0x%x", p.Opcode, a.Code)
	case party.OpInvitation:
		k, inv, f, _ := party.DecodeInvitation(p.Data)
		return fmt.Sprintf("0x3080 kind=%d inviter=%d flags=0x%02x", k, inv, f)
	case party.OpInfo:
		in, err := party.DecodeInfo(p.Data)
		if err != nil {
			return "0x3065 malformed"
		}
		var names []string
		for _, m := range in.Members {
			names = append(names, fmt.Sprintf("%s(%d)", m.Name, m.JID))
		}
		return fmt.Sprintf("0x3065 party=%d leader=%d flags=0x%02x members=[%s]", in.PartyID, in.Leader, in.Flags, strings.Join(names, " "))
	case party.OpEvent:
		e, err := party.DecodeEvent(p.Data)
		if err != nil {
			return "0x3864 malformed"
		}
		switch e.Kind {
		case party.EventDissolved:
			return fmt.Sprintf("0x3864 k1 dissolved code=0x%x", e.Code)
		case party.EventJoined:
			return fmt.Sprintf("0x3864 k2 joined %s(%d)", e.Record.Name, e.Record.JID)
		case party.EventLeft:
			return fmt.Sprintf("0x3864 k3 left jid=%d reason=%d", e.JID, e.Reason)
		case party.EventUpdate:
			return fmt.Sprintf("0x3864 k6 update jid=%d mask=0x%02x", e.JID, e.Record.Mask)
		case party.EventLeader:
			return fmt.Sprintf("0x3864 k9 leader jid=%d", e.JID)
		}
	case party.OpMatchRegAck, party.OpMatchChgAck:
		if len(p.Data) > 0 && p.Data[0] == party.ResultOK {
			e, _, err := party.ReadEntry(p.Data[1:])
			if err == nil {
				return fmt.Sprintf("0x%04x [1] entry=%d party=%d flags=0x%02x purpose=%d levels=%d..%d %q", p.Opcode, e.Number, e.PartyID, e.Flags, e.Purpose, e.MinLevel, e.MaxLevel, e.Title)
			}
		}
		if a, err := party.DecodeIDAck(p.Data); err == nil && !a.OK {
			return fmt.Sprintf("0x%04x [2] code=0x%x", p.Opcode, a.Code)
		}
	case party.OpMatchDelAck:
		if a, err := party.DecodeIDAck(p.Data); err == nil {
			if a.OK {
				return fmt.Sprintf("0xb06b [1] entry=%d", a.ID)
			}
			return fmt.Sprintf("0xb06b [2] code=0x%x", a.Code)
		}
	case party.OpMatchListAck:
		pg, err := decodePage(p.Data)
		if err != nil {
			return fmt.Sprintf("0xb06c % x", p.Data)
		}
		var rows []string
		for _, r := range pg.rows {
			rows = append(rows, fmt.Sprintf("%d:%s(race %d, %d members, flags 0x%02x, purpose %d, %d..%d)", r.Number, r.Name, r.Race, r.Count, r.Flags, r.Purpose, r.MinLevel, r.MaxLevel))
		}
		return fmt.Sprintf("0xb06c [1] pages=%d index=%d rows=[%s]", pg.pages, pg.at, strings.Join(rows, " "))
	case party.OpMatchJoin:
		j, err := party.DecodeJoinRequest(p.Data)
		if err == nil {
			return fmt.Sprintf("0x706d job=%d requester=%s(%d) entry=%d masteries=%d/%d job state=%d level=%d", j.JobID, j.Record.Name, j.Requester, j.Entry, j.Mastery1, j.Mastery2, j.Job, j.Record.Level)
		}
	case party.OpMatchJoinAck:
		if len(p.Data) == 3 {
			v := uint16(p.Data[1]) | uint16(p.Data[2])<<8
			if p.Data[0] == party.ResultOK {
				return fmt.Sprintf("0xb06d [1] outcome=%d", v)
			}
			return fmt.Sprintf("0xb06d [2] code=0x%x", v)
		}
	case session.OpChatUpdate:
		u, err := session.DecodeChatUpdate(p.Data)
		if err == nil {
			return fmt.Sprintf("chat type=%d from=%s %q", u.Type, u.Sender, u.Message)
		}
	}
	return fmt.Sprintf("0x%04x % x", p.Opcode, p.Data)
}

// run reads every packet, prints the party traffic and hands it to in.
func (b *bot) run() {
	for {
		b.conn.SetReadDeadline(time.Time{})
		p, err := proto.Read(b.r, nil, nil)
		if err != nil {
			close(b.in)
			return
		}
		b.note(p)
		if p.Opcode == charmsg.OpExpGain {
			if g, err := charmsg.DecodeExpGain(p.Data); err == nil {
				fmt.Printf("[%s] <- 0x3056 source %d EXP %d skill EXP %d level-up %v\n", b.name, g.Source, g.Exp, g.SkillExp, g.LevelUp)
				b.mu.Lock()
				b.gains = append(b.gains, g)
				b.mu.Unlock()
			}
		}
		if isParty(p.Opcode) || p.Opcode == session.OpChatUpdate || p.Opcode == party.OpItemNotice {
			fmt.Printf("[%s] <- %s\n", b.name, describe(p))
			b.in <- p
		}
		switch p.Opcode {
		case session.OpAttackResult, session.OpGMCommandResult, session.OpCharacterStatsResult:
			select {
			case b.other <- p:
			default:
			}
		}
		if isGround(p.Opcode) {
			select {
			case b.ground <- p:
			default:
			}
		}
	}
}

// expect waits for the next party (or chat) message and checks it.
func (b *bot) expect(what string, ok func(*proto.Packet) bool) error {
	select {
	case p, open := <-b.in:
		if !open {
			return fmt.Errorf("%s: connection closed waiting for %s", b.name, what)
		}
		if !ok(p) {
			return fmt.Errorf("%s: got %s, want %s", b.name, describe(p), what)
		}
		return nil
	case <-time.After(3 * time.Second):
		return fmt.Errorf("%s: nothing arrived, want %s", b.name, what)
	}
}

// quiet checks nothing party-related arrives for a moment.
func (b *bot) quiet() error {
	select {
	case p, open := <-b.in:
		if open {
			return fmt.Errorf("%s: unexpected %s", b.name, describe(p))
		}
		return nil
	case <-time.After(400 * time.Millisecond):
		return nil
	}
}

func connect(addr, user, name string, level int) (*bot, error) {
	conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		return nil, err
	}
	b := &bot{name: name, conn: conn, r: bufio.NewReader(conn), in: make(chan *proto.Packet, 256), other: make(chan *proto.Packet, 64), ground: make(chan *proto.Packet, 256), seen: map[string]int64{}}
	const pw = "partybot-pw"
	b.send(session.OpRegister, (&session.RegisterRequest{Username: user, Password: pw}).Encode())
	if _, err := b.readSync(session.OpRegisterResult); err != nil {
		return nil, err
	}
	b.send(session.OpLogin, (&session.LoginRequest{Username: user, Password: pw}).Encode())
	p, err := b.readSync(session.OpLoginResult)
	if err != nil {
		return nil, err
	}
	if lr, err := session.DecodeLoginResult(p.Data); err != nil || !lr.OK {
		return nil, fmt.Errorf("%s: login refused: %+v %v", name, lr, err)
	}
	// A China man in the starting kit (the same ids lobby tests use); an
	// existing character of that name is simply started.
	b.send(session.OpLobby, (&session.LobbyRequest{Action: session.LobbyCreate, Name: name, RefObjID: 1909, Scale: 0x22,
		Chest: 3643, Legs: 3644, Feet: 3645, Weapon: 3632}).Encode())
	if _, err := b.readSync(session.OpLobbyResult); err != nil {
		return nil, err
	}
	b.send(session.OpStart, (&session.StartRequest{Name: name}).Encode())
	p, err = b.readSync(session.OpEnterWorldResult)
	if err != nil {
		return nil, err
	}
	er, err := session.DecodeEnterWorldResult(p.Data)
	if err != nil || !er.OK {
		return nil, fmt.Errorf("%s: enter world refused: %+v %v", name, er, err)
	}
	b.zone, b.x, b.y, b.z = er.Zone, er.X, er.Y, er.Z
	fmt.Printf("[%s] entered %s at %.0f, %.0f, %.0f\n", name, er.Zone, er.X, er.Y, er.Z)
	if _, err := b.readSync(session.OpSelfID); err != nil {
		return nil, err
	}
	if level > 1 {
		b.send(session.OpGMCommand, (&session.GMCommandRequest{Name: name, Line: fmt.Sprintf("/level %d", level)}).Encode())
		p, err := b.readSync(session.OpGMCommandResult)
		if err != nil {
			return nil, err
		}
		if r, err := session.DecodeGMCommandResult(p.Data); err != nil || !r.IsGM {
			return nil, fmt.Errorf("%s: /level %d: not a GM account (list it in -gm-accounts): %+v %v", name, level, r, err)
		}
	}
	go b.run()
	return b, nil
}

func ack(op uint16, okWant bool, val uint32) func(*proto.Packet) bool {
	return func(p *proto.Packet) bool {
		if p.Opcode != op {
			return false
		}
		a, err := party.DecodeIDAck(p.Data)
		if err != nil || a.OK != okWant {
			return false
		}
		if okWant {
			return a.ID == val
		}
		return uint32(a.Code) == val
	}
}

func event(kind byte, jid uint32, extra func(party.Event) bool) func(*proto.Packet) bool {
	return func(p *proto.Packet) bool {
		if p.Opcode != party.OpEvent {
			return false
		}
		e, err := party.DecodeEvent(p.Data)
		if err != nil || e.Kind != kind {
			return false
		}
		if kind == party.EventJoined {
			if e.Record.JID != jid {
				return false
			}
		} else if kind != party.EventDissolved && e.JID != jid {
			return false
		}
		return extra == nil || extra(e)
	}
}

func info(n int) func(*proto.Packet) bool {
	return func(p *proto.Packet) bool {
		if p.Opcode != party.OpInfo {
			return false
		}
		in, err := party.DecodeInfo(p.Data)
		return err == nil && len(in.Members) == n
	}
}

func invitation(kind party.InviteKind, from uint32) func(*proto.Packet) bool {
	return func(p *proto.Packet) bool {
		if p.Opcode != party.OpInvitation {
			return false
		}
		k, inv, _, err := party.DecodeInvitation(p.Data)
		return err == nil && k == kind && inv == from
	}
}

func chatLine(sender, text string) func(*proto.Packet) bool {
	return func(p *proto.Packet) bool {
		if p.Opcode != session.OpChatUpdate {
			return false
		}
		u, err := session.DecodeChatUpdate(p.Data)
		return err == nil && u.Type == session.ChatParty && u.Sender == sender && u.Message == text
	}
}

type step struct {
	what string
	do   func() error
}

func scenario(addr, prefix string) error {
	names := []string{"Aria", "Bram", "Cato", "Dara", "Eli"}
	bots := map[string]*bot{}
	for _, n := range names {
		full := prefix + n
		b, err := connect(addr, strings.ToLower(full), full, 10)
		if err != nil {
			return err
		}
		bots[n] = b
		fmt.Printf("[%s] in the world, character %d, JID %d\n", full, b.id, b.jid())
	}
	a, br, c, d, e := bots["Aria"], bots["Bram"], bots["Cato"], bots["Dara"], bots["Eli"]
	// Characters enter where they were left; gather them within a few units
	// of Aria, well inside the 600-unit invitation range.
	for i, n := range names[1:] {
		b := bots[n]
		if b.zone != a.zone {
			return fmt.Errorf("%s entered %s, Aria %s: the scenario needs one zone", b.name, b.zone, a.zone)
		}
		if err := b.moveTo(a.x+float32(5*(i+1)), a.y, a.z); err != nil {
			return err
		}
	}
	time.Sleep(300 * time.Millisecond)
	all := func(f func(*bot) error, bs ...*bot) error {
		for _, b := range bs {
			if err := f(b); err != nil {
				return err
			}
		}
		return nil
	}
	steps := []step{
		{"Aria invites Bram to a non-shared party (flags 0x02)", func() error {
			a.send(party.OpCreate, party.EncodeCreate(br.jid(), party.FlagItemShare))
			return br.expect("0x3080 kind 2 from Aria", invitation(party.InviteForm, a.jid()))
		}},
		{"Bram accepts: the GameServer's order on both sides", func() error {
			br.send(party.OpInvitation, party.EncodeAnswerYes())
			for _, x := range []struct {
				b    *bot
				what string
				ok   func(*proto.Packet) bool
			}{
				{a, "0xb060 [1] Aria's JID", ack(party.OpCreateAck, true, a.jid())},
				{a, "0x3065 of Aria alone", info(1)},
				{a, "kind 2 Bram", event(party.EventJoined, br.jid(), nil)},
				{br, "0xb067 [1] Bram's JID", ack(party.OpJoinAck, true, br.jid())},
				{br, "0x3065 of both", info(2)},
			} {
				if err := x.b.expect(x.what, x.ok); err != nil {
					return err
				}
			}
			return nil
		}},
		{"Cato and Dara join (the party fills to 4)", func() error {
			for i, j := range []*bot{c, d} {
				a.send(party.OpInvite, party.EncodeTarget(j.jid()))
				if err := j.expect("0x3080 kind 3", invitation(party.InviteJoin, a.jid())); err != nil {
					return err
				}
				j.send(party.OpInvitation, party.EncodeAnswerYes())
				if err := j.expect("0xb067 [1]", ack(party.OpJoinAck, true, j.jid())); err != nil {
					return err
				}
				if err := j.expect("0x3065", info(3+i)); err != nil {
					return err
				}
				members := []*bot{a, br, c}[:2+i]
				if err := all(func(m *bot) error { return m.expect("kind 2", event(party.EventJoined, j.jid(), nil)) }, members...); err != nil {
					return err
				}
			}
			return nil
		}},
		{"Eli is refused by the cap: 0xb062 [2] 0x2c14", func() error {
			a.send(party.OpInvite, party.EncodeTarget(e.jid()))
			if err := a.expect("0xb062 [2] 0x2c14", ack(party.OpInviteAck, false, uint32(party.CodeFullNotShared))); err != nil {
				return err
			}
			return e.quiet()
		}},
		{"Party chat reaches the four members, the sender included, and not Eli", func() error {
			br.send(session.OpChatSend, (&session.ChatSendRequest{Type: session.ChatParty, Index: 1, Message: "pull"}).Encode())
			if err := all(func(m *bot) error { return m.expect("Bram's party line", chatLine(br.name, "pull")) }, a, br, c, d); err != nil {
				return err
			}
			return e.quiet()
		}},
		{"Aria kicks Dara: kind 3 reason 4 to all four", func() error {
			a.send(party.OpKick, party.EncodeTarget(d.jid()))
			return all(func(m *bot) error {
				return m.expect("kind 3 Dara reason 4", event(party.EventLeft, d.jid(), func(e party.Event) bool { return e.Reason == party.ReasonKicked }))
			}, a, br, c, d)
		}},
		{"Aria leaves: kind 3 reason 2, then kind 9 Bram (the longest-standing)", func() error {
			a.send(party.OpLeave, nil)
			if err := all(func(m *bot) error {
				return m.expect("kind 3 Aria reason 2", event(party.EventLeft, a.jid(), func(e party.Event) bool { return e.Reason == party.ReasonLeave }))
			}, a, br, c); err != nil {
				return err
			}
			return all(func(m *bot) error { return m.expect("kind 9 Bram", event(party.EventLeader, br.jid(), nil)) }, br, c)
		}},
		{"Cato leaves the party of two: kind 1 dissolved to both", func() error {
			c.send(party.OpLeave, nil)
			return all(func(m *bot) error {
				return m.expect("kind 1 0x2c0b", event(party.EventDissolved, 0, func(e party.Event) bool { return e.Code == party.CodeDissolved }))
			}, br, c)
		}},
		{"Dara forms an exp-shared party with Eli and Aria joins; Eli logs out: kind 3 reason 1", func() error {
			d.send(party.OpCreate, party.EncodeCreate(e.jid(), party.FlagExpShare))
			if err := e.expect("0x3080 kind 2", invitation(party.InviteForm, d.jid())); err != nil {
				return err
			}
			e.send(party.OpInvitation, party.EncodeAnswerYes())
			for _, x := range []struct {
				b  *bot
				ok func(*proto.Packet) bool
			}{{d, ack(party.OpCreateAck, true, d.jid())}, {d, info(1)}, {d, event(party.EventJoined, e.jid(), nil)}, {e, ack(party.OpJoinAck, true, e.jid())}, {e, info(2)}} {
				if err := x.b.expect("formation", x.ok); err != nil {
					return err
				}
			}
			d.send(party.OpInvite, party.EncodeTarget(a.jid()))
			if err := a.expect("0x3080 kind 3", invitation(party.InviteJoin, d.jid())); err != nil {
				return err
			}
			a.send(party.OpInvitation, party.EncodeAnswerYes())
			if err := a.expect("0xb067", ack(party.OpJoinAck, true, a.jid())); err != nil {
				return err
			}
			if err := a.expect("0x3065", info(3)); err != nil {
				return err
			}
			if err := all(func(m *bot) error { return m.expect("kind 2 Aria", event(party.EventJoined, a.jid(), nil)) }, d, e); err != nil {
				return err
			}
			// Aria walks 40 units: the others hear a kind-6 update carrying
			// only the position, within the 1 s sampler; Aria hears nothing.
			a.moveTo(a.x+40, a.y, a.z)
			if err := all(func(m *bot) error {
				return m.expect("kind 6 Aria position", event(party.EventUpdate, a.jid(), func(ev party.Event) bool { return ev.Record.Mask == party.MaskPosition }))
			}, d, e); err != nil {
				return err
			}
			if err := a.quiet(); err != nil {
				return err
			}
			e.conn.Close()
			return all(func(m *bot) error {
				return m.expect("kind 3 Eli reason 1", event(party.EventLeft, e.jid(), func(ev party.Event) bool { return ev.Reason == party.ReasonLogout }))
			}, d, a)
		}},
	}
	for i, s := range steps {
		fmt.Printf("--- step %d: %s\n", i+1, s.what)
		if err := s.do(); err != nil {
			return fmt.Errorf("step %d (%s): %w", i+1, s.what, err)
		}
	}
	fmt.Println("--- all steps passed")
	return nil
}

// botEntry is the entry a -register bot lists (round 714: the client lane's
// renders need rows that differ; the defaults are round 713's).
var botEntry struct {
	purpose, minLevel, maxLevel, flags int
	title                              string
}

// botSilent leaves join requests unanswered (round 714: a requester's
// joining window stays up until the backstop).
var botSilent bool

// botZone (round 780, OURS, a QA aid): a zone label the bot asks for on entry
// (0x0026, the zone box's request), e.g. "dungeon/32769", so a live run can
// stand a party member in a dungeon beside a client sent there by /goto.
var botZone string

// botKill makes a bot, once it is in a party, wait and then kill one monster
// of a species with a real blow (round 716: a live 0x3056 run, where the
// rendered client is the party member who never hits).
var botKill struct {
	species string
	after   time.Duration
}

func botMode(addr, name string, level int, accept bool, inviteName string, registerEntry bool, requestName string,
	tp, tp2 string, tp2After time.Duration) error {
	b, err := connect(addr, strings.ToLower(name), name, level)
	if err != nil {
		return err
	}
	fmt.Printf("[%s] in the world, character %d, JID %d\n", name, b.id, b.jid())
	// -tp / -tp2 (round 715, OURS, a QA aid): the GM teleport, so a live run
	// can stand bots at chosen distances from the rendered client.
	// The GM /tp only tells a client where to stand; the client then sends
	// the move (session/gm.go), so the bot sends it too, as a relocation.
	gmTP := func(at string) {
		b.send(session.OpGMCommand, (&session.GMCommandRequest{Name: name, Line: "/tp " + at}).Encode())
		var x, z float32
		if _, err := fmt.Sscanf(at, "%f %f", &x, &z); err == nil {
			b.moveTo(x, b.y, z)
		}
		fmt.Printf("[%s] -> /tp %s and a relocated move there\n", name, at)
	}
	if botZone != "" {
		b.send(session.OpChangeZone, (&session.ChangeZoneRequest{Zone: botZone}).Encode())
		fmt.Printf("[%s] -> 0x0026 change zone to %s\n", name, botZone)
	}
	if tp != "" {
		gmTP(tp)
	}
	// -tp2 runs -tp2-after once the bot is in a party (its 0x3065), so a run
	// can invite it beside the leader first and then move it away.
	var tp2C <-chan time.Time
	var killC <-chan time.Time
	if registerEntry {
		b.send(party.OpMatchRegister, party.AppendEntry(nil, &party.Entry{Flags: party.Flags(botEntry.flags),
			Purpose: uint8(botEntry.purpose), MinLevel: uint8(botEntry.minLevel), MaxLevel: uint8(botEntry.maxLevel), Title: botEntry.title}))
		fmt.Printf("[%s] -> 0x7069 register\n", name)
	}
	requested := false
	invited := false
	tick := time.NewTicker(500 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case p, open := <-b.in:
			if !open {
				return errors.New("connection closed")
			}
			if p.Opcode == party.OpInfo && botKill.species != "" && killC == nil {
				killC = time.After(botKill.after)
				fmt.Printf("[%s] in a party: killing a %s in %s\n", name, botKill.species, botKill.after)
			}
			if p.Opcode == party.OpInfo && tp2 != "" && tp2C == nil {
				tp2C = time.After(tp2After)
				fmt.Printf("[%s] in a party: /tp %s in %s\n", name, tp2, tp2After)
			}
			if p.Opcode == party.OpMatchJoin && !botSilent {
				if j, err := party.DecodeJoinRequest(p.Data); err == nil {
					answer := party.AnswerCancel
					if accept {
						answer = party.AnswerConfirm
					}
					b.send(party.OpMatchAnswer, party.EncodeJoinAnswer(j.JobID, j.Requester, answer))
					fmt.Printf("[%s] -> 0x306e job=%d answer=%d\n", name, j.JobID, answer)
				}
			}
			if p.Opcode == party.OpMatchListAck && requestName != "" && !requested {
				if pg, err := decodePage(p.Data); err == nil {
					for _, r := range pg.rows {
						if r.Name == requestName {
							b.send(party.OpMatchJoin, party.EncodeTarget(r.Number))
							fmt.Printf("[%s] -> 0x706d entry=%d (%s)\n", name, r.Number, requestName)
							requested = true
							break
						}
					}
				}
			}
			if p.Opcode == party.OpInvitation {
				k, _, _, _ := party.DecodeInvitation(p.Data)
				if accept {
					b.send(party.OpInvitation, party.EncodeAnswerYes())
				} else if k == party.InviteJoin {
					b.send(party.OpInvitation, party.EncodeAnswerNo(party.CodeJoinRefused))
				} else {
					b.send(party.OpInvitation, party.EncodeAnswerNo(party.CodeCreateRefused))
				}
			}
		case <-tp2C:
			gmTP(tp2)
		case <-killC:
			go func() {
				// The -tp's GM reply may still be queued: drop it, or the
				// /spawn would read it as its own.
				for drained := false; !drained; {
					select {
					case <-b.other:
					default:
						drained = true
					}
				}
				ar, err := b.kill(botKill.species)
				if err != nil {
					fmt.Printf("[%s] kill failed: %v\n", name, err)
					return
				}
				fmt.Printf("[%s] killed it: EXP +%d, SP +%d\n", name, ar.ExpGained, ar.SkillExpGained)
			}()
		case <-tick.C:
			if requestName != "" && !requested {
				b.send(party.OpMatchList, []byte{0})
			}
			if inviteName != "" && !invited {
				if id, ok := b.idOf(inviteName); ok {
					b.send(party.OpCreate, party.EncodeCreate(party.JIDOf(id), party.FlagExpShare|party.FlagItemShare))
					fmt.Printf("[%s] -> 0x7060 target=%s(%d)\n", name, inviteName, party.JIDOf(id))
					invited = true
				}
			}
		}
	}
}

func main() {
	addr := flag.String("addr", "127.0.0.1:15779", "the server's gateway address")
	mode := flag.String("mode", "scenario", "scenario (the round-710 acceptance run), match (the round-713 party-match run), share (round 712), pickup (round 785: drops and pick-ups) or bot (one character that stays online)")
	prefix := flag.String("prefix", "pb", "scenario: a prefix for the five characters' names and accounts")
	name := flag.String("name", "PartyBot", "bot: the character's name (and lower-cased, the account)")
	level := flag.Int("level", 10, "the level the bot raises itself to with /level (needs -gm-accounts on the server)")
	accept := flag.Bool("accept", true, "bot: answer invitations yes (false: no)")
	invite := flag.String("invite", "", "bot: invite this character to a new party once it is seen")
	register := flag.Bool("register", false, "bot: register a party-match entry once in the world")
	requestEntry := flag.String("request", "", "bot: ask to join this character's party-match entry once it is on page 0")
	monster := flag.String("monster", "chakji", "share: the species to kill")
	flag.IntVar(&botEntry.purpose, "purpose", 0, "bot -register: the entry's purpose (0 hunting, 1 quest, 2 trade, 3 thief)")
	flag.IntVar(&botEntry.minLevel, "min", 1, "bot -register: the entry's lowest level")
	flag.IntVar(&botEntry.maxLevel, "max", 110, "bot -register: the entry's highest level")
	flag.IntVar(&botEntry.flags, "flags", int(party.FlagExpShare|party.FlagItemShare), "bot -register: the entry's type byte")
	flag.StringVar(&botKill.species, "kill", "", "bot: once in a party, kill one monster of this species with a real blow (needs -gm-accounts)")
	flag.DurationVar(&botKill.after, "kill-after", 10*time.Second, "bot -kill: how long after joining the party")
	flag.BoolVar(&botSilent, "silent", false, "bot: leave party-match join requests unanswered (the server's 15 s backstop answers)")
	flag.StringVar(&botEntry.title, "title", "For open hunting", "bot -register: the entry's title")
	flag.StringVar(&botZone, "zone", "", "bot: a zone label to change to once in the world (0x0026), e.g. dungeon/32769")
	tp := flag.String("tp", "", "bot: \"x z\" -- /tp there once in the world (a GM account)")
	tp2 := flag.String("tp2", "", "bot: \"x z\" -- /tp there again after -tp2-after")
	tp2After := flag.Duration("tp2-after", 30*time.Second, "bot: how long after joining a party -tp2 happens")
	flag.IntVar(&pickupOpts.kills, "kills", 10, "pickup: how many monsters to kill")
	flag.BoolVar(&pickupOpts.pick, "pick", false, "pickup: walk up to each stack and pick it up")
	flag.DurationVar(&pickupOpts.wait, "wait", 0, "pickup: wait this long in the world before the first kill")
	flag.StringVar(&pickupOpts.at, "at", "", "pickup: \"x y z\" -- stand there (a relocation) before the first kill")
	flag.Parse()
	var err error
	switch *mode {
	case "scenario":
		err = scenario(*addr, *prefix)
	case "match":
		if *prefix == "pb" {
			*prefix = "pm"
		}
		err = matchScenario(*addr, *prefix)
	case "bot":
		err = botMode(*addr, *name, *level, *accept, *invite, *register, *requestEntry, *tp, *tp2, *tp2After)
	case "share":
		err = shareScenario(*addr, *prefix, *monster, *level)
	case "pickup":
		err = pickupScenario(*addr, *prefix, *monster, *level, pickupOpts)
	default:
		err = fmt.Errorf("unknown -mode %q", *mode)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "partybot:", err)
		os.Exit(1)
	}
}
