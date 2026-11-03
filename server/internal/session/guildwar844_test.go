package session

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"net"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/jobs"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// warNext reads packets until one with op arrives (others skipped).
func warNext(t *testing.T, f *deadWorldFixture, conn net.Conn, r *bufio.Reader, op uint16) *proto.Packet {
	t.Helper()
	for i := 0; i < 12; i++ {
		p := f.read(t, conn, r)
		if p.Opcode == op {
			return p
		}
	}
	t.Fatalf("no %#04x within 12 packets", op)
	return nil
}

// Round 844: a guild war end to end on the original's rules -- Aria's Alpha
// proclaims on Bram's Beta (0x7110: the target master asked with 0x3080 kind
// 10), the refusals of the ladder, Bram accepts (both stakes taken, 0x38F5
// 0x19 to both, the two now hostile: the blow allowed at any level), a kill
// (0x1d to both, the points 15 d + 100, the counters), the disband refused
// 0x4c46, the surrender (0x1a / 0x1b), the end (0x1c, LodgedGold the
// winner's booty) and the 1 s check by time.
func TestRound844WarFlow(t *testing.T) {
	guilds := guild.NewMemStore()
	f := startDeadWorldFixtureWith(t, func(chars character.Store, hub *world.Hub) gateway.Handler {
		return gateway.Chain(testGuildHandler(t, chars, guilds, hub), GuildWarHandler(chars, guilds, hub))
	})
	t.Cleanup(func() {
		guildWarBox.Store(nil)
		unionHostile.Store(nil)
		loadWarCache(context.Background(), guild.NewMemStore())
	})
	ctx := context.Background()
	for _, id := range []int64{f.aria, f.bram} {
		c, _ := f.chars.GetByID(ctx, id)
		qualifyFounder(t, f.chars, c)
	}
	f.send(t, f.connA, OpGuildCreate, (&GuildCreateRequest{CharacterName: "Aria", GuildName: "Alpha"}).Encode())
	ga, _ := DecodeGuildResult(f.read(t, f.connA, f.rA).Data)
	expectGuildLine(t, f, f.connA, f.rA, f.aria, "Alpha", "")
	expectGuildLine(t, f, f.connB, f.rB, f.aria, "Alpha", "")
	f.send(t, f.connB, OpGuildCreate, (&GuildCreateRequest{CharacterName: "Bram", GuildName: "Beta"}).Encode())
	gb, _ := DecodeGuildResult(f.read(t, f.connB, f.rB).Data)
	expectGuildLine(t, f, f.connB, f.rB, f.bram, "Beta", "")
	expectGuildLine(t, f, f.connA, f.rA, f.bram, "Beta", "")
	if ga == nil || gb == nil || ga.GuildID == 0 || gb.GuildID == 0 {
		t.Fatal("the two guilds")
	}
	for _, id := range []int64{f.aria, f.bram} {
		_ = f.chars.AddGold(ctx, id, 1000000)
	}

	// The ladder: an unknown guild 0x4c25; a stake over 500M 0x4c43 first
	// (the declarer's gold is checked before the cap); bad terms 2.
	dec := guild.WarDeclaration{Target: "Nobody", Period: guild.PackWarPeriod(0, 0, 10), VictoryIndex: 1, Stake: 100000}
	f.send(t, f.connA, guild.OpWarDeclare, dec.Encode())
	if p := warNext(t, f, f.connA, f.rA, guild.OpWarDeclareR); !bytes.Equal(p.Data, guild.EncodeFail(guild.ErrWarCantFindTargetGuild)) {
		t.Fatalf("no such guild: % x", p.Data)
	}
	dec.Target = "Beta"
	bad := dec
	bad.VictoryIndex = 8
	f.send(t, f.connA, guild.OpWarDeclare, bad.Encode())
	if p := warNext(t, f, f.connA, f.rA, guild.OpWarDeclareR); !bytes.Equal(p.Data, guild.EncodeFail(guild.ErrWarBadTerms)) {
		t.Fatalf("index 8: % x", p.Data)
	}
	rich := dec
	rich.Stake = 2000000
	f.send(t, f.connA, guild.OpWarDeclare, rich.Encode())
	if p := warNext(t, f, f.connA, f.rA, guild.OpWarDeclareR); !bytes.Equal(p.Data, guild.EncodeFail(guild.ErrWarDeclarerGold)) {
		t.Fatalf("a stake above the gold: % x", p.Data)
	}
	// The proclamation reaches Bram as 0x3080 kind 10.
	f.send(t, f.connA, guild.OpWarDeclare, dec.Encode())
	p := warNext(t, f, f.connB, f.rB, guild.OpRequest)
	want := guild.EncodeWarProclamation(uint32(f.aria), "Alpha", 0, dec.Period, 1, 100000)
	if !bytes.Equal(p.Data, want) {
		t.Fatalf("0x3080 % x, want % x", p.Data, want)
	}
	// Bram accepts (his 0x3080 {1, 1}; the party chain hands it to
	// guildWarAnswer).
	bramE, _ := f.hub.EntityByCharacterID(f.bram)
	before := map[int64]int64{}
	for _, id := range []int64{f.aria, f.bram} {
		c, _ := f.chars.GetByID(ctx, id)
		before[id] = c.Gold
	}
	if !guildWarAnswer(ctx, nil, bramE, []byte{1, 1}) {
		t.Fatal("the answer was not the war's")
	}
	// Round 860: each guild's first war puts it in its members' "at war" set
	// (0x30EF {0, the guild}, s:0x5c8800), before the 0x19.
	for _, c := range []struct {
		conn net.Conn
		r    *bufio.Reader
		id   uint32
	}{{f.connA, f.rA, uint32(ga.GuildID)}, {f.connB, f.rB, uint32(gb.GuildID)}} {
		p := warNext(t, f, c.conn, c.r, OpGuildWarState)
		if !bytes.Equal(p.Data, binary.LittleEndian.AppendUint32([]byte{0}, c.id)) {
			t.Fatalf("0x30EF at the start % x", p.Data)
		}
	}
	// And a spawn / 0x30FF of a member writes the war flag 0 now.
	if line := ownGuildLine(ctx, f.aria); line == nil || line.Data[len(line.Data)-1] != 0 {
		t.Fatalf("Aria's 0x30FF during the war: %v", line)
	}
	for _, c := range []struct {
		conn net.Conn
		r    *bufio.Reader
		name string
	}{{f.connA, f.rA, "Beta"}, {f.connB, f.rB, "Alpha"}} {
		p := warNext(t, f, c.conn, c.r, guild.OpUpdate)
		if p.Data[0] != guild.UpdateWarStarted || !bytes.HasSuffix(p.Data, append([]byte{byte(len(c.name)), 0}, c.name...)) {
			t.Fatalf("0x19 % x", p.Data)
		}
	}
	for _, id := range []int64{f.aria, f.bram} {
		if c, _ := f.chars.GetByID(ctx, id); c.Gold != before[id]-100000 {
			t.Fatalf("%d's gold after the stake: %d", id, c.Gold)
		}
	}
	wars, _ := guilds.WarsOf(ctx, ga.GuildID)
	if len(wars) != 1 || wars[0].LodgedGold != 200000 || wars[0].GuildA != ga.GuildID || wars[0].EndTime.IsZero() {
		t.Fatalf("the war: %+v", wars)
	}
	w := wars[0]
	if !guildsHostile(ctx, f.aria, f.bram) || guildsHostile(ctx, f.aria, f.aria) {
		t.Fatal("hostility")
	}
	// The union request's test (lane U's unionops.go, 0x4c42) sees the war.
	if !unionGuildsHostile(ctx, ga.GuildID, gb.GuildID) {
		t.Fatal("the union request's hostility test does not see the war")
	}
	// The blow between them is allowed whatever the level (s:0x5293a0).
	low := jobs.Fighter{Job: jobs.StateNone, Level: 1}
	if code := jobs.AttackCode(low, low, false, false, true); code != 0 {
		t.Fatalf("a hostile blow at level 1: %#x", code)
	}
	if code := jobs.AttackCode(low, low, false, false, false); code != jobs.ErrYourLevelLow {
		t.Fatalf("a peaceful blow at level 1: %#x", code)
	}
	if code := jobs.AttackCode(jobs.Fighter{Job: jobs.StateNone, InTown: true}, low, false, false, true); code != jobs.ErrNoBattleField {
		t.Fatalf("war in town: %#x", code)
	}
	// Proclaiming again: already hostile 0x4c3a.
	f.send(t, f.connA, guild.OpWarDeclare, dec.Encode())
	if p := warNext(t, f, f.connA, f.rA, guild.OpWarDeclareR); !bytes.Equal(p.Data, guild.EncodeFail(guild.ErrWarEnemyGuild)) {
		t.Fatalf("again: % x", p.Data)
	}

	// Aria kills Bram: 100 points at equal levels, 0x1d to both.
	ariaE, _ := f.hub.EntityByCharacterID(f.aria)
	guildWarKill(ctx, ariaE, bramE, ariaE.Level, false)
	k := warNext(t, f, f.connA, f.rA, guild.OpUpdate)
	if !bytes.Equal(k.Data, guild.EncodeWarKill(1, w.ID, 100, f.aria, "Bram", "")) {
		t.Fatalf("Alpha's 0x1d % x", k.Data)
	}
	k = warNext(t, f, f.connB, f.rB, guild.OpUpdate)
	if !bytes.Equal(k.Data, guild.EncodeWarKill(2, w.ID, 100, f.bram, "Aria", "")) {
		t.Fatalf("Beta's 0x1d % x", k.Data)
	}
	if got, _ := guilds.WarByID(ctx, w.ID); got.PointsA != 100 {
		t.Fatalf("the points: %+v", got)
	}
	g, _ := guilds.Get(ctx, ga.GuildID)
	if g.Members[0].WarKill != 1 || g.Members[0].Contribution != 100 {
		t.Fatalf("Aria's counters: %+v", g.Members[0])
	}
	if !guildAtWar(ga.GuildID) {
		t.Fatal("disband is not blocked during the war")
	}

	// Bram surrenders: 0x1a to Alpha, 0x1b to Beta.
	f.send(t, f.connB, guild.OpWarEnd, binary.LittleEndian.AppendUint32(nil, uint32(w.ID)))
	if p := warNext(t, f, f.connA, f.rA, guild.OpUpdate); !bytes.Equal(p.Data, guild.EncodeWarEnding(guild.UpdateWarEndingFor, w.ID)) {
		t.Fatalf("0x1a % x", p.Data)
	}
	if p := warNext(t, f, f.connB, f.rB, guild.OpUpdate); !bytes.Equal(p.Data, guild.EncodeWarEnding(guild.UpdateWarEndingBy, w.ID)) {
		t.Fatalf("0x1b % x", p.Data)
	}
	// The 60 s run out (here at once): Alpha wins.
	if v, ok := warSurrenders.LoadAndDelete(w.ID); ok {
		v.(*time.Timer).Stop()
	}
	endGuildWar(ctx, guildWarBox.Load(), w.ID, ga.GuildID, "surrender")
	for _, c := range []struct {
		conn net.Conn
		r    *bufio.Reader
	}{{f.connA, f.rA}, {f.connB, f.rB}} {
		if p := warNext(t, f, c.conn, c.r, guild.OpUpdate); !bytes.Equal(p.Data, guild.EncodeWarEnded(w.ID, ga.GuildID)) {
			t.Fatalf("0x1c % x", p.Data)
		}
	}
	// Round 860: the last war's end takes both out (0x30EF {1, the guild},
	// s:0x5c88d0), and the flag is 1 again.
	for _, c := range []struct {
		conn net.Conn
		r    *bufio.Reader
		id   uint32
	}{{f.connA, f.rA, uint32(ga.GuildID)}, {f.connB, f.rB, uint32(gb.GuildID)}} {
		p := warNext(t, f, c.conn, c.r, OpGuildWarState)
		if !bytes.Equal(p.Data, binary.LittleEndian.AppendUint32([]byte{1}, c.id)) {
			t.Fatalf("0x30EF at the end % x", p.Data)
		}
	}
	if line := ownGuildLine(ctx, f.aria); line == nil || line.Data[len(line.Data)-1] != 1 {
		t.Fatalf("Aria's 0x30FF after the war: %v", line)
	}
	if n, _ := guilds.Booty(ctx, ga.GuildID); n != 200000 {
		t.Fatalf("Alpha's booty %d", n)
	}
	if guildsHostile(ctx, f.aria, f.bram) || guildAtWar(ga.GuildID) || unionGuildsHostile(ctx, ga.GuildID, gb.GuildID) {
		t.Fatal("still hostile after the end")
	}

	// The 1 s check: a war past its end with the totals apart ends.
	w2, err := guilds.BeginWar(ctx, guild.War{GuildA: gb.GuildID, GuildB: ga.GuildID, LodgedGold: 10,
		EndTime: time.Now().Add(-time.Second), PointsA: 1})
	if err != nil {
		t.Fatal(err)
	}
	cacheWar(*w2)
	warTick(ctx, time.Now())
	if p := warNext(t, f, f.connA, f.rA, guild.OpUpdate); !bytes.Equal(p.Data, guild.EncodeWarEnded(w2.ID, gb.GuildID)) {
		t.Fatalf("0x1c by time % x", p.Data)
	}
	if n, _ := guilds.Booty(ctx, gb.GuildID); n != 10 {
		t.Fatalf("Beta's booty %d", n)
	}
	// The reward needs the guild manager in reach (OURS stand-in): 3.
	f.send(t, f.connA, guild.OpWarAsk, binary.LittleEndian.AppendUint32(nil, 0x7f000001))
	if p := warNext(t, f, f.connA, f.rA, guild.OpWarAskR); !bytes.Equal(p.Data, guild.EncodeFail(guild.ErrWarNoTalk)) {
		t.Fatalf("0xB114 with no NPC % x", p.Data)
	}
}
