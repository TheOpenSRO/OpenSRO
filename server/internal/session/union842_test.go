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
	"github.com/TheOpenSRO/OpenSRO/server/internal/pcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// unionOfLine is the union id a 0x30FF carries (after the grant name and
// the crest revision); -1 when it carries no guild.
func unionOfLine(t *testing.T, data []byte) (uid uint32, union int64) {
	t.Helper()
	uid = binary.LittleEndian.Uint32(data)
	at := 8
	n := int(binary.LittleEndian.Uint16(data[at:]))
	at += 2 + n
	if n == 0 {
		return uid, -1
	}
	n = int(binary.LittleEndian.Uint16(data[at:]))
	at += 2 + n + 4
	if len(data) < at+8+2 {
		t.Fatalf("0x30FF too short: % x", data)
	}
	return uid, int64(binary.LittleEndian.Uint32(data[at:]))
}

// readN reads n packets from conn.
func readN(t *testing.T, f *deadWorldFixture, conn net.Conn, r *bufio.Reader, n int) []*proto.Packet {
	t.Helper()
	out := make([]*proto.Packet, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, f.read(t, conn, r))
	}
	return out
}

// Round 842: a union as the client colours by it. Aria's Alpha and Bram's
// Beta form one through the GM's /union: both are sent the union (0x3102,
// the client's FUN_0099a810 layout) and every member's line again with the
// union id (0x30FF), and the spawn record carries it; Beta leaves: 0x38F5
// type 0x12 {1, Beta} to both and the lines with no union; they ally again
// and Beta's last member leaves, deleting it: Alpha is told 0x12 too.
func TestRound842UnionFlow(t *testing.T) {
	guilds := guild.NewMemStore()
	f := startDeadWorldFixtureWith(t, func(chars character.Store, hub *world.Hub) gateway.Handler {
		return testGuildHandler(t, chars, guilds, hub)
	})
	ctx := context.Background()
	for _, id := range []int64{f.aria, f.bram} {
		c, _ := f.chars.GetByID(ctx, id)
		qualifyFounder(t, f.chars, c)
	}
	f.send(t, f.connA, OpGuildCreate, (&GuildCreateRequest{CharacterName: "Aria", GuildName: "Alpha"}).Encode())
	ga, err := DecodeGuildResult(f.read(t, f.connA, f.rA).Data)
	if err != nil || ga.Error != "" {
		t.Fatalf("Alpha: %+v %v", ga, err)
	}
	expectGuildLine(t, f, f.connA, f.rA, f.aria, "Alpha", "")
	expectGuildLine(t, f, f.connB, f.rB, f.aria, "Alpha", "")
	f.send(t, f.connB, OpGuildCreate, (&GuildCreateRequest{CharacterName: "Bram", GuildName: "Beta"}).Encode())
	gb, err := DecodeGuildResult(f.read(t, f.connB, f.rB).Data)
	if err != nil || gb.Error != "" {
		t.Fatalf("Beta: %+v %v", gb, err)
	}
	expectGuildLine(t, f, f.connB, f.rB, f.bram, "Beta", "")
	expectGuildLine(t, f, f.connA, f.rA, f.bram, "Beta", "")
	if unionInfoPacket(ctx, &guild.Guild{ID: ga.GuildID}) != nil {
		t.Fatal("a union before any was formed")
	}

	// Bram's Beta joins Alpha's union (none yet: formed, Alpha in slot 0).
	cmds := UnionCommands{}
	if text, err := cmds.Join(ctx, f.bram, "alpha"); err != nil {
		t.Fatalf("/union alpha: %v", err)
	} else {
		t.Log(text)
	}
	if _, err := cmds.Join(ctx, f.bram, "Alpha"); err == nil {
		t.Fatal("joining twice was taken")
	}
	if _, err := cmds.Join(ctx, f.bram, "Nobody"); err == nil {
		t.Fatal("a guild nobody has was taken")
	}
	u, _ := guilds.UnionOf(ctx, gb.GuildID)
	if u == nil || u.LeaderGuildID() != ga.GuildID {
		t.Fatalf("the union: %+v", u)
	}
	wantInfo := guild.EncodeUnionInfo(u, unionEntries(ctx, u))
	if !bytes.Contains(wantInfo, []byte{5, 0, 'A', 'l', 'p', 'h', 'a'}) || !bytes.Contains(wantInfo, []byte{4, 0, 'B', 'e', 't', 'a'}) {
		t.Fatalf("0x3102's entries: % x", wantInfo)
	}
	for _, c := range []struct {
		conn net.Conn
		r    *bufio.Reader
	}{{f.connA, f.rA}, {f.connB, f.rB}} {
		ps := readN(t, f, c.conn, c.r, 3)
		if ps[0].Opcode != guild.OpUnionInfo || !bytes.Equal(ps[0].Data, wantInfo) {
			t.Fatalf("first: %#04x % x, want 0x3102 % x", ps[0].Opcode, ps[0].Data, wantInfo)
		}
		seen := map[uint32]int64{}
		for _, p := range ps[1:] {
			if p.Opcode != OpEntityGuildUpdate {
				t.Fatalf("got %#04x, want 0x30FF", p.Opcode)
			}
			uid, un := unionOfLine(t, p.Data)
			seen[uid] = un
		}
		if seen[uint32(f.aria)] != u.ID || seen[uint32(f.bram)] != u.ID {
			t.Fatalf("the lines' union ids: %v, want %d", seen, u.ID)
		}
	}
	// The spawn record carries it.
	e, _ := f.hub.EntityByCharacterID(f.aria)
	rec, _, err := pcspawn.Decode(playerRecord(viewDeps{ctx: ctx, hub: f.hub, chars: f.chars}, e, time.Now()), nil)
	if err != nil || int64(rec.UnionID) != u.ID || rec.GuildName != "Alpha" {
		t.Fatalf("Aria's spawn record: union %d %q, %v", rec.UnionID, rec.GuildName, err)
	}
	// And the guild block's send (world entry, a join) is followed by it.
	if p := unionInfoPacket(ctx, &guild.Guild{ID: ga.GuildID}); p == nil || !bytes.Equal(p.Data, wantInfo) {
		t.Fatalf("Alpha's union packet: %+v", p)
	}

	// Beta leaves: type 0x12 {1, Beta} to both, then the lines with none.
	if _, err := cmds.Leave(ctx, f.bram, ""); err != nil {
		t.Fatalf("/union leave: %v", err)
	}
	out := guild.EncodeUnionOut(guild.UnionOutLeft, gb.GuildID)
	for _, c := range []struct {
		conn net.Conn
		r    *bufio.Reader
	}{{f.connA, f.rA}, {f.connB, f.rB}} {
		ps := readN(t, f, c.conn, c.r, 3)
		if ps[0].Opcode != guild.OpUpdate || !bytes.Equal(ps[0].Data, out) {
			t.Fatalf("first: %#04x % x, want 0x38F5 % x", ps[0].Opcode, ps[0].Data, out)
		}
		for _, p := range ps[1:] {
			if _, un := unionOfLine(t, p.Data); p.Opcode != OpEntityGuildUpdate || un != 0 {
				t.Fatalf("after the leave: %#04x union %d", p.Opcode, un)
			}
		}
	}
	if u, _ := guilds.UnionOf(ctx, ga.GuildID); u != nil {
		t.Fatalf("a one-guild union stands: %+v", u)
	}
	if _, err := cmds.Leave(ctx, f.bram, ""); err == nil {
		t.Fatal("leaving no union was taken")
	}

	// Allied again; Bram, Beta's only member, leaves his guild: it is
	// deleted, and Alpha is told 0x12 {1, Beta}.
	if _, err := cmds.Join(ctx, f.bram, "Alpha"); err != nil {
		t.Fatal(err)
	}
	readN(t, f, f.connA, f.rA, 3)
	readN(t, f, f.connB, f.rB, 3)
	f.send(t, f.connB, OpGuildLeave, (&CharacterNameRequest{Name: "Bram"}).Encode())
	if lr, err := DecodeGuildLeaveResult(f.read(t, f.connB, f.rB).Data); err != nil || !lr.OK {
		t.Fatalf("leave: %+v %v", lr, err)
	}
	var got []*proto.Packet
	for i := 0; i < 3; i++ {
		got = append(got, f.read(t, f.connA, f.rA))
	}
	var told bool
	for _, p := range got {
		if p.Opcode == guild.OpUpdate && bytes.Equal(p.Data, out) {
			told = true
		}
	}
	if !told {
		t.Fatalf("Alpha was not told Beta left: %v", got)
	}
	if u, _ := guilds.UnionOf(ctx, ga.GuildID); u != nil {
		t.Fatalf("Alpha is still in %+v", u)
	}
}
