package session

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"strings"
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

// qualifyFounder lifts a character to what FUN_00514b20 asks of a guild
// founder: guild.MinCreatorLevel, and guild.CreateGoldRequired on top of the
// gold it already carries, so founding leaves it where it started.
func qualifyFounder(t *testing.T, chars *character.MemStore, c *character.Character) {
	t.Helper()
	ctx := context.Background()
	if err := chars.SetLeveling(ctx, c.ID, guild.MinCreatorLevel, 0, c.StatPoints, c.Str, c.Int); err != nil {
		t.Fatalf("SetLeveling(%s): %v", c.Name, err)
	}
	if err := chars.AddGold(ctx, c.ID, guild.CreateGoldRequired); err != nil {
		t.Fatalf("AddGold(%s): %v", c.Name, err)
	}
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
	aria, _ := chars.Create(ctx, 1, "Aria")
	chars.Create(ctx, 2, "Bram")
	qualifyFounder(t, chars, aria)

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
	aria, _ := chars.Create(ctx, 1, "Aria")
	qualifyFounder(t, chars, aria)

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

// TestGuildCreateRejectsBadNameLength drives OpGuildCreate through the real
// handler stack: a name outside 2-12 bytes (0x00514ce0's `len - 2u < 0xb`,
// else 0x4c18 GUILDERR_INVALID_GUILDNAME_LEN) comes back as an error and no
// guild, and a 12-byte name still founds one.
func TestGuildCreateRejectsBadNameLength(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	aria, _ := chars.Create(ctx, 1, "Aria")
	// A founder who passes FUN_00514b20, so the length test is what answers.
	qualifyFounder(t, chars, aria)

	handle := gateway.Chain(LoginHandler(accounts), GuildHandler(chars, guild.NewMemStore()))
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

	const want = "guild name must be 2 to 12 characters"
	for _, name := range []string{"A", strings.Repeat("a", 13)} {
		resp = send(OpGuildCreate, (&GuildCreateRequest{CharacterName: "Aria", GuildName: name}).Encode())
		gr, err := DecodeGuildResult(resp.Data)
		if err != nil {
			t.Fatalf("DecodeGuildResult: %v", err)
		}
		if gr.Error != want || gr.GuildID != 0 {
			t.Fatalf("create %q (%d bytes): got %+v, want error %q and no guild", name, len(name), gr, want)
		}
	}

	resp = send(OpGuildCreate, (&GuildCreateRequest{CharacterName: "Aria", GuildName: strings.Repeat("a", 12)}).Encode())
	gr, err := DecodeGuildResult(resp.Data)
	if err != nil || gr.Error != "" || gr.GuildID == 0 {
		t.Fatalf("create with a 12-byte name failed: err=%v result=%+v", err, gr)
	}
}

// TestGuildCreateRequiresLevelAndGold drives OpGuildCreate through the real
// handler stack against FUN_00514b20's founder ladder -- alive (0x4c07), level
// 20 (0x4c0a), 500,000 gold (0x4c0c), in that order -- and the 500,000 the
// create job's reply then takes (trs_sm_guildjob::FUN_005c8bf0 ->
// GObjPC::FUN_004e4140, OffsetGold(-500000)).
func TestGuildCreateRequiresLevelAndGold(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	aria, _ := chars.Create(ctx, 1, "Aria")
	bram, _ := chars.Create(ctx, 1, "Bram")
	cyra, _ := chars.Create(ctx, 1, "Cyra")
	guilds := guild.NewMemStore()

	handle := gateway.Chain(LoginHandler(accounts), GuildHandler(chars, guilds))
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)

	resp := doSend(t, conn, r, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}

	found := func(who, name string) *GuildResult {
		t.Helper()
		resp := doSend(t, conn, r, OpGuildCreate, (&GuildCreateRequest{CharacterName: who, GuildName: name}).Encode())
		gr, err := DecodeGuildResult(resp.Data)
		if err != nil {
			t.Fatalf("DecodeGuildResult: %v", err)
		}
		return gr
	}
	gold := func(c *character.Character) int64 {
		t.Helper()
		now, err := chars.GetByID(ctx, c.ID)
		if err != nil {
			t.Fatalf("GetByID(%s): %v", c.Name, err)
		}
		return now.Gold
	}
	refused := func(step string, c *character.Character, name, want string, wantGold int64) {
		t.Helper()
		gr := found(c.Name, name)
		if gr.Error != want || gr.GuildID != 0 {
			t.Fatalf("%s: %s founding %q got %+v, want error %q and no guild", step, c.Name, name, gr, want)
		}
		if _, err := guilds.GetByCharacter(ctx, c.ID); !errors.Is(err, guild.ErrNotInGuild) {
			t.Fatalf("%s: %s is in a guild after a refusal (err=%v)", step, c.Name, err)
		}
		if g := gold(c); g != wantGold {
			t.Fatalf("%s: %s has %d gold after a refusal, want %d untouched", step, c.Name, g, wantGold)
		}
	}
	accepted := func(step string, c *character.Character, name string, wantGold int64) {
		t.Helper()
		gr := found(c.Name, name)
		if gr.Error != "" || gr.GuildID == 0 || gr.LeaderID != c.ID {
			t.Fatalf("%s: %s founding %q got %+v, want a guild led by it", step, c.Name, name, gr)
		}
		if g := gold(c); g != wantGold {
			t.Fatalf("%s: %s has %d gold after founding, want %d", step, c.Name, g, wantGold)
		}
	}
	setLevel := func(c *character.Character, level int) {
		t.Helper()
		if err := chars.SetLeveling(ctx, c.ID, level, 0, c.StatPoints, c.Str, c.Int); err != nil {
			t.Fatalf("SetLeveling(%s, %d): %v", c.Name, level, err)
		}
	}
	addGold := func(c *character.Character, n int64) {
		t.Helper()
		if err := chars.AddGold(ctx, c.ID, n); err != nil {
			t.Fatalf("AddGold(%s, %d): %v", c.Name, n, err)
		}
	}

	levelMsg := fmt.Sprintf("a guild founder must be at least level %d", guild.MinCreatorLevel)
	goldMsg := fmt.Sprintf("founding a guild requires %d gold", guild.CreateGoldRequired)
	const deadMsg = "cannot found a guild while dead"

	if aria.Level != 1 || aria.Gold != 1000 {
		t.Fatalf("fixture: a fresh character is level %d with %d gold, want level 1 with 1000", aria.Level, aria.Gold)
	}

	// 1. Level 1 with 1,000 gold: the level refusal, which comes before gold.
	refused("level 1", aria, "Silk Legion", levelMsg, 1000)
	// 2. Level 20, still 1,000 gold.
	setLevel(aria, 20)
	refused("level 20, 1000 gold", aria, "Silk Legion", goldMsg, 1000)
	// 3. One short: 499,999.
	addGold(aria, 498_999)
	refused("499999 gold", aria, "Silk Legion", goldMsg, 499_999)
	// 4. Exactly 500,000 founds it, and founding spends all of it.
	addGold(aria, 1)
	accepted("500000 gold", aria, "Silk Legion", 0)

	// 5. Level 19 with 500,000: level, not gold.
	setLevel(bram, 19)
	addGold(bram, 499_000)
	refused("level 19", bram, "Iron Vow", levelMsg, 500_000)

	// 6. Level 20 with 500,000 but dead: dead is asked first.
	setLevel(cyra, 20)
	addGold(cyra, 499_000)
	if _, died, err := chars.ApplyDamage(ctx, cyra.ID, 1<<30); err != nil || !died {
		t.Fatalf("ApplyDamage(Cyra): died=%v err=%v", died, err)
	}
	refused("dead", cyra, "Ash Court", deadMsg, 500_000)

	// 7. A richer founder keeps the change: 1,234,567 - 500,000.
	setLevel(bram, 20)
	addGold(bram, 734_567)
	accepted("1234567 gold", bram, "Iron Vow", 734_567)
}

// spentGoldStore is a character store whose DeductGold always fails the way
// it would if the founder's gold had been spent between the handler's check
// and the deduction. Test-only: nothing in production has this seam.
type spentGoldStore struct{ *character.MemStore }

func (spentGoldStore) DeductGold(context.Context, int64, int64) error {
	return character.ErrInsufficientGold
}

// TestGuildCreateRollsBackWhenGoldCannotBeTaken covers srrevamp's own handling
// of a deduction that fails after the guild exists (the engine's OffsetGold has
// no refusal path): the founder is left guildless, the name is free again, the
// gold is untouched and the reply is the not-enough-gold message.
func TestGuildCreateRollsBackWhenGoldCannotBeTaken(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	aria, _ := chars.Create(ctx, 1, "Aria")
	qualifyFounder(t, chars, aria)
	guilds := guild.NewMemStore()

	handle := gateway.Chain(LoginHandler(accounts), GuildHandler(spentGoldStore{chars}, guilds))
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)

	resp := doSend(t, conn, r, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}

	resp = doSend(t, conn, r, OpGuildCreate, (&GuildCreateRequest{CharacterName: "Aria", GuildName: "Silk Legion"}).Encode())
	gr, err := DecodeGuildResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeGuildResult: %v", err)
	}
	if want := fmt.Sprintf("founding a guild requires %d gold", guild.CreateGoldRequired); gr.Error != want || gr.GuildID != 0 {
		t.Fatalf("got %+v, want error %q and no guild", gr, want)
	}
	if _, err := guilds.GetByCharacter(ctx, aria.ID); !errors.Is(err, guild.ErrNotInGuild) {
		t.Fatalf("Aria is still in a guild after the rollback (err=%v)", err)
	}
	if now, _ := chars.GetByID(ctx, aria.ID); now.Gold != character.StartingGold+guild.CreateGoldRequired {
		t.Fatalf("Aria has %d gold, want %d untouched", now.Gold, character.StartingGold+guild.CreateGoldRequired)
	}
	if _, err := guilds.Create(ctx, "Silk Legion", 99, "Other"); err != nil {
		t.Fatalf("the rolled-back guild's name is still taken: %v", err)
	}
}
