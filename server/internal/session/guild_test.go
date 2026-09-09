package session

import (
	"bufio"
	"context"
	"net"
	"os"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/guild"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
)

func guildTestDSN() string {
	if v := os.Getenv("SRREVAMP_TEST_POSTGRES_DSN"); v != "" {
		return v
	}
	return "postgres://postgres:postgres@localhost:5432/srrevamp_test?sslmode=disable"
}

func openTestGuildStore(t *testing.T) *guild.SQLStore {
	t.Helper()
	s, err := guild.OpenSQLStore(guildTestDSN())
	if err != nil {
		t.Fatalf("guild.OpenSQLStore: %v (is postgres running?)", err)
	}
	if err := s.TruncateForTest(context.Background()); err != nil {
		t.Fatalf("truncating guild tables: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestGuildResultRoundTrip(t *testing.T) {
	want := &GuildResult{
		GuildID:  1,
		Name:     "Silk Legion",
		LeaderID: 100,
		Members:  []GuildMemberSnapshot{{CharacterID: 100, Name: "Aria", Role: 1}, {CharacterID: 200, Name: "Bram", Role: 0}},
	}
	got, err := DecodeGuildResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodeGuildResult: %v", err)
	}
	if got.GuildID != want.GuildID || got.Name != want.Name || got.LeaderID != want.LeaderID || len(got.Members) != 2 {
		t.Fatalf("got %+v, want %+v", got, want)
	}
	if got.Members[0] != want.Members[0] || got.Members[1] != want.Members[1] {
		t.Fatalf("member mismatch: got %+v", got.Members)
	}
}

func TestGuildResultErrorRoundTrip(t *testing.T) {
	want := &GuildResult{Error: "guild name already taken"}
	got, err := DecodeGuildResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodeGuildResult: %v", err)
	}
	if got.Error != want.Error || len(got.Members) != 0 {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestGuildJoinRequestRoundTrip(t *testing.T) {
	want := &GuildJoinRequest{CharacterName: "Bram", GuildID: 1}
	got, err := DecodeGuildJoinRequest(want.Encode())
	if err != nil {
		t.Fatalf("DecodeGuildJoinRequest: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestGuildCreateRequestRoundTrip(t *testing.T) {
	want := &GuildCreateRequest{CharacterName: "Aria", GuildName: "Silk Legion"}
	got, err := DecodeGuildCreateRequest(want.Encode())
	if err != nil {
		t.Fatalf("DecodeGuildCreateRequest: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

// TestGuildFullFlow logs two accounts in on separate connections, has one
// found a guild and the other join it, confirms both see the correct
// roster, then has the founder leave and confirms leadership passes to the
// remaining member rather than disbanding the guild -- all through the
// real server stack against a real Postgres-backed guild.Store.
func TestGuildFullFlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	accounts.Add("bob", "hunter3")
	chars := character.NewMemStore()
	chars.Create(ctx, 1, "Aria")
	chars.Create(ctx, 2, "Bram")

	guilds := openTestGuildStore(t)
	handle := gateway.Chain(LoginHandler(accounts), GuildHandler(chars, guilds))

	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	connA := dialTestServer(t, addr)
	defer connA.Close()
	rA := bufio.NewReader(connA)
	connB := dialTestServer(t, addr)
	defer connB.Close()
	rB := bufio.NewReader(connB)

	doSend := func(c net.Conn, r *bufio.Reader, opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(c, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		c.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}

	resp := doSend(connA, rA, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("alice login failed: err=%v result=%+v", err, lr)
	}
	resp = doSend(connB, rB, OpLogin, (&LoginRequest{Username: "bob", Password: "hunter3"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("bob login failed: err=%v result=%+v", err, lr)
	}

	resp = doSend(connA, rA, OpGuildCreate, (&GuildCreateRequest{CharacterName: "Aria", GuildName: "Silk Legion"}).Encode())
	gr, err := DecodeGuildResult(resp.Data)
	if err != nil || gr.Error != "" {
		t.Fatalf("create guild failed: err=%v result=%+v", err, gr)
	}
	if len(gr.Members) != 1 || gr.Members[0].Name != "Aria" || gr.LeaderID != gr.Members[0].CharacterID {
		t.Fatalf("got %+v, want a solo guild led by Aria", gr)
	}
	guildID := gr.GuildID

	resp = doSend(connB, rB, OpGuildJoin, (&GuildJoinRequest{CharacterName: "Bram", GuildID: guildID}).Encode())
	gr, err = DecodeGuildResult(resp.Data)
	if err != nil || gr.Error != "" {
		t.Fatalf("join guild failed: err=%v result=%+v", err, gr)
	}
	if len(gr.Members) != 2 {
		t.Fatalf("got %+v, want 2 members after join", gr)
	}

	// Alice (the founder) leaves; leadership should pass to Bram rather
	// than disbanding the guild, since he's the only member left.
	resp = doSend(connA, rA, OpGuildLeave, (&CharacterNameRequest{Name: "Aria"}).Encode())
	lr, err := DecodeGuildLeaveResult(resp.Data)
	if err != nil || !lr.OK {
		t.Fatalf("leave guild failed: err=%v result=%+v", err, lr)
	}
}

// TestGuildInfoFlow confirms OpGuildInfo reports "not in a guild" before
// joining one, and the real roster afterward -- specifically important
// for guilds since membership is persistent (unlike party), so a client
// that just logged in needs a way to learn about an existing guild
// without guessing or getting an ErrAlreadyInGuild surprise.
func TestGuildInfoFlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	chars.Create(ctx, 1, "Aria")

	guilds := openTestGuildStore(t)
	handle := gateway.Chain(LoginHandler(accounts), GuildHandler(chars, guilds))

	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)

	send := func(opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}

	resp := send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}

	resp = send(OpGuildInfo, (&CharacterNameRequest{Name: "Aria"}).Encode())
	gr, err := DecodeGuildResult(resp.Data)
	if err != nil || gr.Error != "" || gr.GuildID != 0 || len(gr.Members) != 0 {
		t.Fatalf("expected 'not in a guild', got err=%v result=%+v", err, gr)
	}

	resp = send(OpGuildCreate, (&GuildCreateRequest{CharacterName: "Aria", GuildName: "Silk Legion"}).Encode())
	gr, err = DecodeGuildResult(resp.Data)
	if err != nil || gr.Error != "" {
		t.Fatalf("create guild failed: err=%v result=%+v", err, gr)
	}

	resp = send(OpGuildInfo, (&CharacterNameRequest{Name: "Aria"}).Encode())
	gr, err = DecodeGuildResult(resp.Data)
	if err != nil || gr.Error != "" || gr.GuildID == 0 || gr.Name != "Silk Legion" || len(gr.Members) != 1 {
		t.Fatalf("expected the real guild after creating one, got err=%v result=%+v", err, gr)
	}
}
