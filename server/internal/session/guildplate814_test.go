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
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// testGuildHandler is GuildHandler for a test: the guild store it names for
// every character's line (SetGuildPlateStore) is a package global, so it is
// dropped again when t ends. Left in place, a later test's character 1 would
// still be in this test's guild and be sent an unasked 0x30FF on entering the
// world.
func testGuildHandler(t testing.TB, chars character.Store, guilds guild.Store, hub *world.Hub) gateway.Handler {
	t.Helper()
	t.Cleanup(func() { SetGuildPlateStore(nil); SetGuildJoinGate(nil) })
	// Round 822: join-by-id is a GM's; the tests that join by id are.
	SetGuildJoinGate(func(string) bool { return true })
	return GuildHandler(chars, guilds, hub)
}

// Round 814: the grant name's messages, byte for byte as the original's
// readers take them (guildplate.go has each address).
func TestGuildPlateMessagesBytes(t *testing.T) {
	req := &GuildGrantNameRequest{TargetID: 0x01020304, Nickname: "Roaster"}
	b := req.Encode()
	if !bytes.Equal(b, append([]byte{4, 3, 2, 1, 7, 0}, "Roaster"...)) {
		t.Fatalf("0x7256 % x", b)
	}
	back, err := DecodeGuildGrantNameRequest(b)
	if err != nil || *back != *req {
		t.Fatalf("decoded %+v %v", back, err)
	}
	if _, err := DecodeGuildGrantNameRequest(b[:len(b)-1]); err == nil {
		t.Error("a short name decoded")
	}
	if b := (&GuildGrantNameResult{Code: 0x4c4d}).Encode(); !bytes.Equal(b, []byte{2, 0x4d, 0x4c}) {
		t.Errorf("0xB256 refusal % x", b)
	}
	ok := (&GuildGrantNameResult{OK: true, GuildID: 9, TargetID: 5, Nickname: "Ro"}).Encode()
	if !bytes.Equal(ok, []byte{1, 9, 0, 0, 0, 5, 0, 0, 0, 2, 0, 'R', 'o'}) {
		t.Errorf("0xB256 ok % x", ok)
	}
	nu := (&GuildNicknameUpdate{GuildID: 9, CharacterName: "Bram", Nickname: "Ro"}).Encode()
	if !bytes.Equal(nu, []byte{9, 0, 0, 0, 4, 0, 'B', 'r', 'a', 'm', 2, 0, 'R', 'o'}) {
		t.Errorf("0x3256 % x", nu)
	}
	eg := (&EntityGuildUpdate{UID: 5, GuildID: 9, GuildName: "Vz", Nickname: "Ro"}).Encode()
	want := []byte{5, 0, 0, 0, 9, 0, 0, 0, 2, 0, 'V', 'z', 2, 0, 'R', 'o'}
	want = append(want, make([]byte, 14)...)
	if !bytes.Equal(eg, want) {
		t.Errorf("0x30FF % x\nwant % x", eg, want)
	}
	if none := (&EntityGuildUpdate{UID: 5}).Encode(); !bytes.Equal(none, []byte{5, 0, 0, 0, 0, 0, 0, 0, 0, 0}) {
		t.Errorf("0x30FF without a guild % x", none)
	}
}

// expectGuildLine reads conn's next packet as an OpEntityGuildUpdate for uid.
func expectGuildLine(t *testing.T, f *deadWorldFixture, conn net.Conn, r *bufio.Reader, uid int64, name, nick string) {
	t.Helper()
	p := f.read(t, conn, r)
	want := (&EntityGuildUpdate{UID: uint32(uid), GuildName: name, Nickname: nick}).Encode()
	if p.Opcode != OpEntityGuildUpdate || len(p.Data) < 8 {
		t.Fatalf("got %#04x, want the guild line 0x30FF", p.Opcode)
	}
	// The guild id (bytes 4..8) is the store's; the rest must match.
	got := append(append([]byte(nil), p.Data[:4]...), p.Data[8:]...)
	if !bytes.Equal(got, append(want[:4:4], want[8:]...)) {
		t.Fatalf("0x30FF % x, want uid %d %q %q", p.Data, uid, name, nick)
	}
}

// Round 814: Aria founds a guild and both clients get her line; Bram joins
// and both get his; a member names only themselves -- the master's grant over
// others is gone (OURS) -- the level-4 gate, the length and the filter refuse
// in the original's order; a name set reaches the guild (0x3256) and those who
// see him (0x30FF), and his spawn record carries it.
func TestRound814GrantNameFlow(t *testing.T) {
	guilds := guild.NewMemStore()
	f := startDeadWorldFixtureWith(t, func(chars character.Store, hub *world.Hub) gateway.Handler {
		return testGuildHandler(t, chars, guilds, hub)
	})
	ctx := context.Background()
	aria, _ := f.chars.GetByID(ctx, f.aria)
	qualifyFounder(t, f.chars, aria)

	f.send(t, f.connA, OpGuildCreate, (&GuildCreateRequest{CharacterName: "Aria", GuildName: "Verizon"}).Encode())
	gr, err := DecodeGuildResult(f.read(t, f.connA, f.rA).Data)
	if err != nil || gr.Error != "" {
		t.Fatalf("create: %+v %v", gr, err)
	}
	expectGuildLine(t, f, f.connA, f.rA, f.aria, "Verizon", "")
	expectGuildLine(t, f, f.connB, f.rB, f.aria, "Verizon", "")

	// Bram asks before he is in a guild.
	grant := func(conn net.Conn, target int64, nick string) {
		f.send(t, conn, OpGuildGrantName, (&GuildGrantNameRequest{TargetID: uint32(target), Nickname: nick}).Encode())
	}
	refusal := func(conn net.Conn, r *bufio.Reader, code uint16) {
		t.Helper()
		p := f.read(t, conn, r)
		if p.Opcode != OpGuildGrantNameResult || !bytes.Equal(p.Data, []byte{2, byte(code), byte(code >> 8)}) {
			t.Fatalf("got %#04x % x, want the refusal %#x", p.Opcode, p.Data, code)
		}
	}
	grant(f.connB, f.bram, "Roaster")
	refusal(f.connB, f.rB, 0x4c0d)

	f.send(t, f.connB, OpGuildJoin, (&GuildJoinRequest{CharacterName: "Bram", GuildID: gr.GuildID}).Encode())
	if jr, err := DecodeGuildResult(f.read(t, f.connB, f.rB).Data); err != nil || jr.Error != "" {
		t.Fatalf("join: %+v %v", jr, err)
	}
	expectGuildLine(t, f, f.connB, f.rB, f.bram, "Verizon", "")
	expectGuildLine(t, f, f.connA, f.rA, f.bram, "Verizon", "")

	// Round 815: no level gate -- Bram's level-1 guild may grant names.
	grant(f.connA, f.bram, "Roaster") // the master naming Bram: OURS, refused
	refusal(f.connA, f.rA, 0x4c1e)
	grant(f.connB, f.bram, "ABCDEFGHIJKLM")
	refusal(f.connB, f.rB, 0x4c4d)
	grant(f.connB, f.bram, "Bad Name") // the filter: no space (0x40f200)
	refusal(f.connB, f.rB, 0x4c4d)

	grant(f.connB, f.bram, "Roaster")
	p := f.read(t, f.connB, f.rB)
	if p.Opcode != OpGuildGrantNameResult || p.Data[0] != 1 || binary.LittleEndian.Uint32(p.Data[5:]) != uint32(f.bram) {
		t.Fatalf("got %#04x % x, want the grant's success", p.Opcode, p.Data)
	}
	for _, c := range []struct {
		conn net.Conn
		r    *bufio.Reader
	}{{f.connB, f.rB}, {f.connA, f.rA}} {
		u := f.read(t, c.conn, c.r)
		if u.Opcode != OpGuildNicknameUpdate || !bytes.HasSuffix(u.Data, []byte{4, 0, 'B', 'r', 'a', 'm', 7, 0, 'R', 'o', 'a', 's', 't', 'e', 'r'}) {
			t.Fatalf("got %#04x % x, want 0x3256 for Bram", u.Opcode, u.Data)
		}
	}
	expectGuildLine(t, f, f.connB, f.rB, f.bram, "Verizon", "Roaster")
	expectGuildLine(t, f, f.connA, f.rA, f.bram, "Verizon", "Roaster")

	// The spawn record's source: read back from the store with the cache
	// dropped.
	SetGuildPlateStore(guilds)
	if gp := guildPlateOf(ctx, f.bram); gp.Name != "Verizon" || gp.Nickname != "Roaster" || gp.ID == 0 {
		t.Fatalf("Bram's line from the store: %+v", gp)
	}
	if gp := guildPlateOf(ctx, 999); gp != (guildPlate{}) {
		t.Fatalf("a guildless character's line: %+v", gp)
	}
	// What he is told of himself entering the world (sendOwnGuildLine).
	if own := ownGuildLine(ctx, f.bram); own == nil || own.Opcode != OpEntityGuildUpdate ||
		!bytes.HasSuffix(own.Data[:len(own.Data)-14], []byte{7, 0, 'V', 'e', 'r', 'i', 'z', 'o', 'n', 7, 0, 'R', 'o', 'a', 's', 't', 'e', 'r'}) {
		t.Fatalf("Bram's own line: %+v", own)
	}
	if ownGuildLine(ctx, 999) != nil {
		t.Fatal("a guildless character is told a line")
	}
	// And his spawn record (pcrecord.go) carries it.
	e, ok := f.hub.EntityByCharacterID(f.bram)
	if !ok {
		t.Fatal("Bram is not in the hub")
	}
	rec, _, err := pcspawn.Decode(playerRecord(viewDeps{ctx: ctx, hub: f.hub, chars: f.chars}, e, time.Now()), nil)
	if err != nil || rec.GuildName != "Verizon" || rec.Nickname != "Roaster" || int64(rec.GuildID) != gr.GuildID {
		t.Fatalf("Bram's spawn record: %+v %v", rec, err)
	}

	// He leaves: the line goes, to both.
	f.send(t, f.connB, OpGuildLeave, (&CharacterNameRequest{Name: "Bram"}).Encode())
	if lr, err := DecodeGuildLeaveResult(f.read(t, f.connB, f.rB).Data); err != nil || !lr.OK {
		t.Fatalf("leave: %+v %v", lr, err)
	}
	// Round 822: as the original's 0x3100 {u32 uid}.
	for _, c := range []struct {
		conn net.Conn
		r    *bufio.Reader
	}{{f.connB, f.rB}, {f.connA, f.rA}} {
		p := f.read(t, c.conn, c.r)
		if p.Opcode != guild.OpObjectLeft || !bytes.Equal(p.Data, guild.EncodeObjectLeft(uint32(f.bram))) {
			t.Fatalf("the line taken away: %#04x % x", p.Opcode, p.Data)
		}
	}
}
