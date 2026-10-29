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
//	partybot -mode job -addr HOST:PORT -name Rook -npcs-csv F -npcpos-csv F [-job 2]
//	         [-guild CODE] [-suit ID] [-fight "region lx lz"] [-attack NAME]
//	    The round-802 job-PvP partner (job.go): joins a job at its guild
//	    NPC, takes an alias, wears the suit, stands at -fight and swings at
//	    -attack on OpAttack's job-PvP target kind, printing every blow.
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
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"github.com/TheOpenSRO/OpenSRO/server/internal/charmsg"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/pcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
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
	// quest carries the quest-side messages (round 785, quest.go), and
	// uidByRef the NPCs spawned, by reference id.
	quest    chan *proto.Packet
	uidByRef map[uint32]uint32
	// hurtDone: job mode's -hurt-when-struck has run (round 802).
	hurtDone bool
	// tap, when set, sees every packet the reader reads, first (round 786's
	// latency mode, latency.go).
	tap func(*proto.Packet)
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
		if isQuestOp(p.Opcode) && b.quest != nil {
			select {
			case b.quest <- p:
			default:
			}
		}
		if p.Opcode == op {
			return p, nil
		}
	}
}

// note learns names and ids from the world messages.
func (b *bot) note(p *proto.Packet) {
	b.noteGuild(p)
	b.noteSocial(p.Opcode, p.Data)
	b.noteStall(p.Opcode, p.Data)
	b.noteMall(p.Opcode, p.Data)
	b.noteUse(p.Opcode, p.Data)
	switch p.Opcode {
	case session.OpSelfID:
		if s, err := session.DecodeSelfID(p.Data); err == nil {
			b.id = s.CharacterID
		}
	case npcspawn.OpSingleDespawn:
		if watchViews && len(p.Data) == 4 {
			fmt.Printf("%s [%s] WATCH despawn uid %d\n", time.Now().Format("15:04:05.000"), b.name, binary.LittleEndian.Uint32(p.Data))
		}
	case session.OpStateChange:
		if s, ok := session.DecodeStateChange(p.Data); ok && watchViews && s.Kind == session.StateKindBodyMode {
			fmt.Printf("%s [%s] WATCH body mode uid %d = %d\n", time.Now().Format("15:04:05.000"), b.name, s.ObjectID, s.Value)
		}
	case session.OpEnterWorldResult:
		if r, err := session.DecodeEnterWorldResult(p.Data); err == nil {
			b.mu.Lock()
			for _, o := range r.Others {
				b.seen[o.Name] = o.CharacterID
			}
			b.mu.Unlock()
			// Round 834: a player already in the world counts as seen.
			for _, o := range r.Others {
				b.socialSteps(o.Name, o.CharacterID)
			}
			// Round 786: a bot loads nothing, so its loading is done at
			// once: the server holds it out of the world until this 0x3012
			// (session/arrival.go).
			if r.OK {
				_ = b.send(session.OpReadyToPlay, nil)
			}
		}
	case session.OpChangeZoneResult:
		if r, err := session.DecodeChangeZoneResult(p.Data); err == nil && r.OK {
			// Round 786 (QA aid): where the zone change put the bot, so a
			// later -tp2 in a dungeon keeps the dungeon's height, not the
			// field's it entered the world at.
			b.mu.Lock()
			b.zone, b.x, b.y, b.z = r.Zone, r.X, r.Y, r.Z
			b.mu.Unlock()
			fmt.Printf("[%s] arrived in %s at %.0f, %.0f, %.0f (0x3012 sent)\n", b.name, r.Zone, r.X, r.Y, r.Z)
			_ = b.send(session.OpReadyToPlay, nil)
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
		if p.Opcode == npcspawn.OpGroupEnd {
			b.noteNPCs(frames)
		}
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
	b.socialSteps(rec.Name, int64(rec.UID))
	b.stallSaw(rec)
	if watchViews {
		fmt.Printf("%s [%s] WATCH spawn %s uid %d body mode %d\n", time.Now().Format("15:04:05.000"), b.name, rec.Name, rec.UID, rec.BodyMode)
	}
	// Round 838: the body each spawn carries (a skin change respawns it).
	fmt.Printf("%s [%s] MODEL spawn %s uid %d ref %d scale 0x%02x\n", time.Now().Format("15:04:05.000"), b.name, rec.Name, rec.UID, rec.RefObjID, rec.Scale)
	// Round 814: a player's guild line as its spawn carries it.
	if rec.GuildName != "" {
		fmt.Printf("[%s] GUILD spawn %s uid %d guild %d %q grant %q\n", b.name, rec.Name, rec.UID, rec.GuildID, rec.GuildName, rec.Nickname)
	}
}

// noteGuild prints the round-814 guild messages this bot is sent: a
// character's guild line (0x30FF), a member's grant name (0x3256) and the
// answer to its own grant-name request (0xB256).
func (b *bot) noteGuild(p *proto.Packet) {
	switch p.Opcode {
	case session.OpEntityGuildUpdate, session.OpGuildNicknameUpdate, session.OpGuildGrantNameResult:
		fmt.Printf("[%s] GUILD %#04x % x\n", b.name, p.Opcode, p.Data)
	}
}

// botGuild (round 814, OURS, a QA aid): -guild-create founds a guild (the
// bot raises itself to the founder's level and gold with the GM console),
// -guild-join joins one by id, -guild-level raises it (/guildlevel), and
// -grant-name sets the bot's own grant name (0x7256).
var botGuild struct {
	create string
	join   int64
	level  int
	grant  string
	// Round 822: -guild-invite NAME invites NAME (0x70F3) once it is in
	// view, and -guild-expel-after expels it (0x70F4) that long after its
	// record arrives (0x38F5 type 2; 0: never).
	invite      string
	inviteAfter time.Duration
	expelAfter  time.Duration
}

// guildSteps runs botGuild's steps, in that order.
func (b *bot) guildSteps(name string) {
	gm := func(line string) {
		b.send(session.OpGMCommand, (&session.GMCommandRequest{Name: name, Line: line}).Encode())
		time.Sleep(300 * time.Millisecond)
	}
	if botGuild.create != "" {
		gm(fmt.Sprintf("/level %d", guild.MinCreatorLevel))
		gm(fmt.Sprintf("/gold %d", guild.CreateGoldRequired))
		b.send(session.OpGuildCreate, (&session.GuildCreateRequest{CharacterName: name, GuildName: botGuild.create}).Encode())
		fmt.Printf("[%s] -> found guild %q\n", name, botGuild.create)
		time.Sleep(500 * time.Millisecond)
	}
	if botGuild.join != 0 {
		b.send(session.OpGuildJoin, (&session.GuildJoinRequest{CharacterName: name, GuildID: botGuild.join}).Encode())
		fmt.Printf("[%s] -> join guild %d\n", name, botGuild.join)
		time.Sleep(500 * time.Millisecond)
	}
	if botGuild.level > 0 {
		gm(fmt.Sprintf("/guildlevel %d", botGuild.level))
	}
	if botGuild.grant != "" {
		b.send(session.OpGuildGrantName, (&session.GuildGrantNameRequest{TargetID: uint32(b.id), Nickname: botGuild.grant}).Encode())
		fmt.Printf("[%s] -> 0x7256 grant name %q\n", name, botGuild.grant)
	}
}

// watchViews is -watch (round 786): print every player spawn, despawn and
// body mode this bot is sent, with the time -- the other side of a live
// test of the arrival hold (session/arrival.go).
var watchViews bool

func (b *bot) idOf(name string) (int64, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	id, ok := b.seen[name]
	return id, ok
}

func isGuildOp(op uint16) bool {
	switch op {
	case guild.OpUpdate, guild.OpCreateResult, guild.OpDisbandResult, guild.OpLeaveResult,
		guild.OpInviteResult, guild.OpExpelResult, guild.OpJoinResult:
		return true
	}
	return false
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
			if os.Getenv("PARTYBOT_TRACE") != "" {
				fmt.Printf("[%s] read ended: %v\n", b.name, err)
			}
			close(b.in)
			return
		}
		b.note(p)
		if b.tap != nil {
			b.tap(p)
		}
		if os.Getenv("PARTYBOT_TRACE") != "" {
			fmt.Printf("[%s] trace 0x%04x %d bytes\n", b.name, p.Opcode, len(p.Data))
		}
		if p.Opcode == charmsg.OpExpGain {
			if g, err := charmsg.DecodeExpGain(p.Data); err == nil {
				fmt.Printf("[%s] <- 0x3056 source %d EXP %d skill EXP %d level-up %v\n", b.name, g.Source, g.Exp, g.SkillExp, g.LevelUp)
				b.mu.Lock()
				b.gains = append(b.gains, g)
				b.mu.Unlock()
			}
		}
		if isQuestOp(p.Opcode) {
			select {
			case b.quest <- p:
			default:
			}
		}
		if isParty(p.Opcode) || p.Opcode == session.OpChatUpdate || p.Opcode == party.OpItemNotice {
			fmt.Printf("[%s] <- %s\n", b.name, describe(p))
			b.in <- p
		} else if isGuildOp(p.Opcode) {
			// Round 822: the membership replies and updates (botMode prints them).
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
	return connectAs(addr, user, name, level, chinaKit)
}

// connectAs is connect with the character made from kit (round 785: a
// European for the quest run).
func connectAs(addr, user, name string, level int, kit session.LobbyRequest) (*bot, error) {
	conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		return nil, err
	}
	b := &bot{name: name, conn: conn, r: bufio.NewReader(conn), in: make(chan *proto.Packet, 256), other: make(chan *proto.Packet, 64), ground: make(chan *proto.Packet, 256), seen: map[string]int64{},
		quest: make(chan *proto.Packet, 4096), uidByRef: map[uint32]uint32{}}
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
	// A character in the starting kit (the same ids lobby tests use); an
	// existing character of that name is simply started.
	kit.Name = name
	b.send(session.OpLobby, kit.Encode())
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

// botWalk (round 832, OURS, a QA aid): waypoints the bot walks in a loop with
// real 0x7021 destination moves, one every botWalkEvery -- a target for the
// trace. Each is "region:localX,localZ", the region word as Go reads an
// integer literal (0x61a8 is Jangan).
var botWalk string
var botWalkEvery time.Duration

// walkStep sends the destination move to waypoint n of botWalk.
func (b *bot) walkStep(name string, n int) {
	points := strings.Split(botWalk, ";")
	p := points[n%len(points)]
	var region int64
	var lx, lz float64
	head, tail, ok := strings.Cut(p, ":")
	if !ok {
		return
	}
	region, err := strconv.ParseInt(head, 0, 32)
	if err != nil {
		return
	}
	if _, err := fmt.Sscanf(tail, "%f,%f", &lx, &lz); err != nil {
		return
	}
	b.mu.Lock()
	y := b.y
	b.mu.Unlock()
	m := &proto.Movement{Kind: 1, Region: uint16(region), LocalX: int16(lx), LocalY: int16(y), LocalZ: int16(lz)}
	b.send(proto.OpMovementRequest, m.Encode())
	fmt.Printf("[%s] -> 0x7021 walk to %s\n", name, p)
}

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
	kit := chinaKit
	if botRace == "europe" {
		// Round 839 (QA aid): a European bot (its race's default booth).
		kit = europeKit
	}
	b, err := connectAs(addr, strings.ToLower(name), name, level, kit)
	if err != nil {
		return err
	}
	fmt.Printf("[%s] in the world, character %d, JID %d\n", name, b.id, b.jid())
	// Round 834 (QA aid): GM lines run once in the world (-gm-lines), e.g.
	// "/give 2 3;/gold 100000" for the exchange's offers.
	for _, line := range strings.Split(botGMLines, ";") {
		if line = strings.TrimSpace(line); line != "" {
			b.send(session.OpGMCommand, (&session.GMCommandRequest{Name: name, Line: line}).Encode())
			fmt.Printf("[%s] GM %s\n", name, line)
		}
	}
	// -tp / -tp2 (round 715, OURS, a QA aid): the GM teleport, so a live run
	// can stand bots at chosen distances from the rendered client.
	// The GM /tp only tells a client where to stand; the client then sends
	// the move (session/gm.go), so the bot sends it too, as a relocation.
	gmTP := func(at string) {
		// Round 838 (QA aid): "x y z" stands the bot at that height too (the
		// GM /tp takes x z; the relocation carries the height).
		var x, y, z float32
		if _, err := fmt.Sscanf(at, "%f %f %f", &x, &y, &z); err == nil {
			b.send(session.OpGMCommand, (&session.GMCommandRequest{Name: name, Line: fmt.Sprintf("/tp %g %g", x, z)}).Encode())
			b.moveTo(x, y, z)
			fmt.Printf("[%s] -> /tp %s and a relocated move there\n", name, at)
			return
		}
		b.send(session.OpGMCommand, (&session.GMCommandRequest{Name: name, Line: "/tp " + at}).Encode())
		if _, err := fmt.Sscanf(at, "%f %f", &x, &z); err == nil {
			b.mu.Lock()
			y := b.y
			b.mu.Unlock()
			b.moveTo(x, y, z)
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
	b.guildSteps(name)
	b.mallSteps()
	b.useSteps()
	b.stallSteps()
	b.netSteps()
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
	guildInvited := false
	var guildSeen time.Time
	var expelC <-chan time.Time
	tick := time.NewTicker(500 * time.Millisecond)
	defer tick.Stop()
	var walkC <-chan time.Time
	walkN := 0
	if botWalk != "" {
		w := time.NewTicker(botWalkEvery)
		defer w.Stop()
		walkC = w.C
	}
	for {
		select {
		case <-walkC:
			b.walkStep(name, walkN)
			walkN++
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
			switch p.Opcode {
			case guild.OpUpdate, guild.OpCreateResult, guild.OpDisbandResult, guild.OpLeaveResult,
				guild.OpInviteResult, guild.OpExpelResult, guild.OpJoinResult:
				fmt.Printf("[%s] GUILD %#04x % x\n", name, p.Opcode, p.Data)
				if p.Opcode == guild.OpUpdate && len(p.Data) > 0 && p.Data[0] == guild.UpdateMemberAdd &&
					botGuild.expelAfter > 0 && expelC == nil {
					expelC = time.After(botGuild.expelAfter)
				}
			}
			// Round 834: kind 1 is the exchange's, answered by -exchange-answer
			// (social.go).
			if p.Opcode == party.OpInvitation && len(p.Data) > 0 && p.Data[0] != guild.RequestGuildInvite && p.Data[0] != 1 {
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
		case <-expelC:
			n := botGuild.invite
			b.send(guild.OpExpel, append(binary.LittleEndian.AppendUint16(nil, uint16(len(n))), n...))
			fmt.Printf("[%s] -> 0x70F4 expel %s\n", name, n)
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
			if botGuild.invite != "" && !guildInvited {
				if _, ok := b.idOf(botGuild.invite); ok && guildSeen.IsZero() {
					guildSeen = time.Now()
				}
				if id, ok := b.idOf(botGuild.invite); ok && time.Since(guildSeen) >= botGuild.inviteAfter {
					b.send(guild.OpInvite, binary.LittleEndian.AppendUint32(nil, uint32(id)))
					fmt.Printf("[%s] -> 0x70F3 guild invite %s(%d)\n", name, botGuild.invite, uint32(id))
					guildInvited = true
				}
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
	flag.StringVar(&botWalk, "walk-loop", "", "bot (round 832): \"region:lx,lz;...\" waypoints walked in a loop with 0x7021, e.g. 0x61a8:1002,1060;0x61a8:1060,1060")
	flag.DurationVar(&botWalkEvery, "walk-loop-every", 6*time.Second, "bot -walk-loop: the time between waypoints")
	flag.StringVar(&botZone, "zone", "", "bot: a zone label to change to once in the world (0x0026), e.g. dungeon/32769")
	tp := flag.String("tp", "", "bot: \"x z\" -- /tp there once in the world (a GM account)")
	flag.StringVar(&botGuild.create, "guild-create", "", "bot: found a guild of this name once in the world (raises itself to the founder's level and gold; a GM account)")
	flag.Int64Var(&botGuild.join, "guild-join", 0, "bot: join this guild id once in the world")
	flag.IntVar(&botGuild.level, "guild-level", 0, "bot: raise its guild to this level with /guildlevel (a GM account)")
	flag.StringVar(&botGuild.grant, "grant-name", "", "bot: set its own grant name (0x7256) once in its guild")
	flag.StringVar(&botGuild.invite, "guild-invite", "", "bot (round 822): invite this character into its guild (0x70F3) once it is in view")
	flag.DurationVar(&botGuild.inviteAfter, "guild-invite-after", 0, "bot (round 822): wait this long after first seeing the -guild-invite character before inviting it")
	flag.DurationVar(&botGuild.expelAfter, "guild-expel-after", 0, "bot (round 822): expel the -guild-invite character (0x70F4) this long after it joins")
	flag.StringVar(&botGMLines, "gm-lines", "", "bot (round 834): GM lines run once in the world, \";\"-separated (a GM account)")
	flag.StringVar(&botSocial.friendAsk, "friend-ask", "", "bot (round 834): ask this character to be friends (0x7302) once it is in view")
	flag.StringVar(&botSocial.friendAnswer, "friend-answer", "", "bot (round 834): answer friend requests: accept, refuse, or nothing")
	flag.StringVar(&botSocial.exchangeWith, "exchange-with", "", "bot (round 834): ask this character to exchange (0x7081) once it is in view")
	flag.StringVar(&botSocial.exchangeAnswer, "exchange-answer", "", "bot (round 834): answer exchange requests: accept, refuse, or nothing")
	flag.StringVar(&botSocial.exchangeSlots, "exchange-slots", "", "bot (round 834): the bag indexes it offers, \"0,1\"; it then confirms and approves")
	flag.Int64Var(&botSocial.exchangeGold, "exchange-gold", 0, "bot (round 834): the gold it offers")
	flag.DurationVar(&botSocial.askAfter, "exchange-ask-after", 0, "bot (round 834): wait this long more before -exchange-with's request (to walk into reach first)")
	flag.StringVar(&botSocial.confirmWhen, "exchange-confirm", "first", "bot (round 834): when it confirms -- first (right after offering), second (once the partner confirmed, 0x3086) or never")
	flag.DurationVar(&botSocial.hold, "exchange-hold", 0, "bot (round 834): wait this long after the exchange opens before offering")
	flag.StringVar(&botMall.buy, "mall-buy", "", "bot (round 837): buy a mall good once in the world: \"<group>,<shop>,<tab>,<slot>,<packageCode>,<qty>[,<points>]\" (0x7034 type 0x18)")
	flag.IntVar(&botMall.repeat, "mall-buy-times", 1, "bot (round 837): send -mall-buy this many times")
	flag.StringVar(&botMall.chest, "mall-chest", "", "bot (round 837): after the buy, list the item chest (\"list\"), take all (\"all\") or take one entry id")
	flag.StringVar(&botMall.history, "mall-history", "", "bot (round 837): ask the silk history \"<kind>,<period>\" (0x711a), e.g. 1,4")
	flag.IntVar(&botMall.open, "mall-open", 0, "bot (round 837): send 0x7121 with this shop group first")
	flag.StringVar(&botMall.use, "use-slots", "", "bot (round 838): bag slots to use (0x008a) once in the world, \"0,1\", after the mall steps")
	flag.DurationVar(&botMall.delay, "mall-delay", 2*time.Second, "bot (round 837): the wait before each mall step")
	flag.DurationVar(&botSocial.delay, "social-delay", 2*time.Second, "bot (round 834): the wait before each friend or exchange step")
	flag.StringVar(&botUse.items, "use-items", "", "bot (round 838): use these items from the bag once in the world, \"<item id>,...\" (after -gm-lines)")
	flag.DurationVar(&botUse.every, "use-items-every", 3*time.Second, "bot (round 838): the wait before each -use-items use")
	flag.BoolVar(&botUse.watchBuffs, "watch-buffs", false, "bot (round 838): print every buff start and end the bot is sent")
	flag.StringVar(&botUse.text, "use-text", "", "bot (round 838): send each -use-items use with this custom title (the Custom Title Scroll)")
	flag.StringVar(&botStall.open, "stall-open", "", "bot (round 839): open a stall with this title once in the world")
	flag.StringVar(&botStall.items, "stall-items", "", "bot (round 839): what -stall-open lists, \"i<item id>:<price>,...\" or \"<bag index>:<price>\"")
	flag.StringVar(&botStall.greeting, "stall-greeting", "", "bot (round 839): -stall-open's greeting")
	flag.BoolVar(&botStall.modify, "stall-modify", false, "bot (round 839): leave -stall-open's stall in the modify state")
	flag.UintVar(&botStall.group, "stall-group", 1, "bot (round 839): the u32 group 0x70BA type 2 carries (the server refuses 0)")
	flag.DurationVar(&botStall.closeAfter, "stall-close-after", 0, "bot (round 839): close -stall-open's stall after this long")
	flag.StringVar(&botStall.visit, "stall-visit", "", "bot (round 839): enter this character's stall once it is seen stalling")
	flag.StringVar(&botStall.buy, "stall-buy", "", "bot (round 839): the stall slots -stall-visit buys, \"0,1\"")
	flag.DurationVar(&botStall.buyAfter, "stall-buy-after", 0, "bot (round 839): wait this long after entering before -stall-buy")
	flag.DurationVar(&botStall.leaveAfter, "stall-leave-after", 0, "bot (round 839): leave the visited stall after this long")
	flag.StringVar(&botStall.chat, "stall-chat", "", "bot (round 839): a stall chat line once open or inside")
	flag.DurationVar(&botStall.delay, "stall-delay", 2*time.Second, "bot (round 839): the wait before each stall step")
	flag.BoolVar(&botStall.network, "stall-net", false, "bot (round 840): open -stall-open's stall on the stall network (0x70BA 5 {1, net 1})")
	flag.StringVar(&botStall.netSearch, "net-search", "", "bot (round 840): search the stall network once in the world, \"<group>,<degree>\" (0x7461)")
	flag.IntVar(&botStall.netPage, "net-page", 0, "bot (round 840): after -net-search, ask this page (0x7461 mode 3)")
	flag.IntVar(&botStall.netBuy, "net-buy", -1, "bot (round 840): buy this record (0-based) of -net-search's first answer (0x7463)")
	flag.DurationVar(&botStall.netAfter, "net-after", 5*time.Second, "bot (round 840): the wait before -net-search")
	flag.BoolVar(&botStall.netLeave, "net-leave", false, "bot (round 840): leave the stall network (0x7462) after the search")
	flag.BoolVar(&watchViews, "watch", false, "print every player spawn, despawn and body mode the bots are sent, timed (round 786)")
	tp2 := flag.String("tp2", "", "bot: \"x z\" -- /tp there again after -tp2-after")
	tp2After := flag.Duration("tp2-after", 30*time.Second, "bot: how long after joining a party -tp2 happens")
	flag.IntVar(&pickupOpts.kills, "kills", 10, "pickup: how many monsters to kill")
	flag.BoolVar(&pickupOpts.pick, "pick", false, "pickup: walk up to each stack and pick it up")
	flag.DurationVar(&pickupOpts.wait, "wait", 0, "pickup: wait this long in the world before the first kill")
	flag.StringVar(&pickupOpts.at, "at", "", "pickup: \"x y z\" -- stand there (a relocation) before the first kill")
	flag.DurationVar(&latOpts.walk, "walk", 0, "latency: run a straight line this long, timing the monsters' enters")
	flag.Float64Var(&latOpts.speed, "speed", 105, "latency: the walk's speed, units a second")
	flag.Float64Var(&latOpts.heading, "heading", 0, "latency: the walk's heading in degrees from +x toward +z")
	flag.IntVar(&latOpts.attacks, "attacks", 0, "latency: attacks to time after the walk")
	flag.BoolVar(&latOpts.noDelay, "nodelay", true, "latency: TCP_NODELAY on the bot's socket (false: Nagle on, the client before round 786)")
	flag.IntVar(&latOpts.crowd, "crowd", 0, "latency: this many more bots moving around the spot")
	flag.DurationVar(&latOpts.crowdPace, "crowd-pace", 150*time.Millisecond, "latency: the time between two crowd bots' logins")
	flag.DurationVar(&latOpts.attackTo, "attack-timeout", 5*time.Second, "latency: how long to wait for an attack's result")
	questRace := flag.String("race", "china", "quest: the character's race, china or europe")
	flag.StringVar(&botRace, "bot-race", "china", "bot (round 839): the bot's race, china or europe")
	questsDir := flag.String("quests-dir", "", "quest: the catalogue directory (export-refdata -mode quests)")
	npcsCSV := flag.String("npcs-csv", "", "quest: the NPC table (export-refdata -mode npcs)")
	npcposCSV := flag.String("npcpos-csv", "", "quest: the NPC placements (export-refdata -mode npcpos)")
	flag.IntVar(&jobRun.kind, "job", 2, "job: the kind to join (1 trader, 2 thief, 3 hunter)")
	flag.StringVar(&jobRun.guild, "guild", "NPC_TD_THIEF_SELL", "job: the guild NPC's code")
	flag.Int64Var(&jobRun.suit, "suit", 2163, "job: the suit's item id (2163 ITEM_CH_M_TRADE_THIEF_02)")
	flag.StringVar(&jobRun.alias, "alias", "Rooky", "job: the job alias")
	flag.StringVar(&jobRun.fight, "fight", "", "job: \"region localX localZ\" -- where to stand once suited")
	flag.StringVar(&jobRun.attack, "attack", "", "job: a character to attack at -fight")
	flag.Int64Var(&jobRun.attackID, "attack-id", 0, "job: the character id to attack at -fight (instead of -attack's name)")
	flag.IntVar(&jobRun.hurt, "hurt-when-struck", 0, "job: /hurt this much HP off the bot at the first blow it takes")
	flag.DurationVar(&jobRun.attackFor, "attack-for", 30*time.Second, "job: how long to keep attacking")
	flag.DurationVar(&jobRun.stay, "stay", 5*time.Minute, "job: how long to stay online after")
	flag.Parse()
	jobRun.npcsCSV, jobRun.npcposCSV = *npcsCSV, *npcposCSV
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
	case "latency":
		err = latencyScenario(*addr, *name, *level, *tp)
	case "job":
		err = jobScenario(*addr, *name, *level, jobRun)
	case "quest":
		err = questScenario(*addr, *name, *questRace, *level, *questsDir, *npcsCSV, *npcposCSV, flag.Args())
	default:
		err = fmt.Errorf("unknown -mode %q", *mode)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "partybot:", err)
		os.Exit(1)
	}
}
