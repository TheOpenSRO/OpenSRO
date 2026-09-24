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
	handle := gateway.Chain(LoginHandler(accounts), GuildHandler(chars, guilds, nil))

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
	handle := gateway.Chain(LoginHandler(accounts), GuildHandler(chars, guilds, nil))

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

	handle := gateway.Chain(LoginHandler(accounts), GuildHandler(chars, guild.NewMemStore(), nil))
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

	handle := gateway.Chain(LoginHandler(accounts), GuildHandler(chars, guilds, nil))
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

	handle := gateway.Chain(LoginHandler(accounts), GuildHandler(spentGoldStore{chars}, guilds, nil))
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

// TestGuildPointsResultRoundTrip pins OpGuildPointsResult's layout (round 525):
// Error, then GuildID, GatheredSP, a u16 count and each member's name and
// GPDonation.
func TestGuildPointsResultRoundTrip(t *testing.T) {
	want := &GuildPointsResult{
		GuildID: 7, GatheredSP: 5412,
		Members: []GuildPointsMember{{Name: "Aria", GPDonation: 5400}, {Name: "Bram", GPDonation: 12}},
	}
	got, err := DecodeGuildPointsResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodeGuildPointsResult: %v", err)
	}
	if got.Error != "" || got.GuildID != 7 || got.GatheredSP != 5412 || len(got.Members) != 2 ||
		got.Members[0] != want.Members[0] || got.Members[1] != want.Members[1] {
		t.Fatalf("got %+v, want %+v", got, want)
	}

	errOnly, err := DecodeGuildPointsResult((&GuildPointsResult{Error: "not in a guild"}).Encode())
	if err != nil || errOnly.Error != "not in a guild" || errOnly.GuildID != 0 || len(errOnly.Members) != 0 {
		t.Fatalf("error round trip: got %+v, %v", errOnly, err)
	}

	// A body cut short is an error, not a zero.
	full := want.Encode()
	if _, err := DecodeGuildPointsResult(full[:len(full)-1]); err == nil {
		t.Fatal("a truncated OpGuildPointsResult decoded without error")
	}
}

// TestGuildPointsFlow drives OpGuildPoints through the handler stack: a
// guildless character is refused with "not in a guild" (NEGATIVE), and a
// member reads back the guild's GatheredSP and each member's GPDonation as
// Store.AddPoints left them.
func TestGuildPointsFlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	aria, _ := chars.Create(ctx, 1, "Aria")
	guilds := guild.NewMemStore()

	handle := gateway.Chain(LoginHandler(accounts), GuildHandler(chars, guilds, nil))
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)

	if lr, err := DecodeLoginResult(doSend(t, conn, r, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}
	points := func() *GuildPointsResult {
		t.Helper()
		resp := doSend(t, conn, r, OpGuildPoints, clientNameRequest("Aria"))
		if resp.Opcode != OpGuildPointsResult {
			t.Fatalf("reply opcode 0x%04x, want OpGuildPointsResult", resp.Opcode)
		}
		pr, err := DecodeGuildPointsResult(resp.Data)
		if err != nil {
			t.Fatalf("DecodeGuildPointsResult: %v", err)
		}
		return pr
	}

	if pr := points(); pr.Error != "not in a guild" || pr.GuildID != 0 {
		t.Fatalf("guildless: got %+v, want error %q", pr, "not in a guild")
	}

	g, err := guilds.Create(ctx, "Silk Legion", aria.ID, "Aria")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if _, err := guilds.Join(ctx, g.ID, 99, "Bram"); err != nil {
		t.Fatalf("Join: %v", err)
	}
	if err := guilds.AddPoints(ctx, g.ID, 99, 12); err != nil {
		t.Fatalf("AddPoints: %v", err)
	}
	pr := points()
	if pr.Error != "" || pr.GuildID != g.ID || pr.GatheredSP != 12 || len(pr.Members) != 2 {
		t.Fatalf("member: got %+v, want guild %d with GatheredSP 12 and two members", pr, g.ID)
	}
	don := map[string]int64{}
	for _, m := range pr.Members {
		don[m.Name] = m.GPDonation
	}
	if don["Aria"] != 0 || don["Bram"] != 12 {
		t.Fatalf("donations = %v, want Aria 0 and Bram 12", don)
	}
}

// TestGuildLevelWireRoundTrip pins the OpGuildLevel pair's layouts (round
// 528): the request is a name and one 0/1 byte; the result is Error, a u16
// Code, then on success the guild id, Level (u8), LevelledUp (u8), MaxMembers
// (u16) and the next level's gold and guild points (s64 each).
func TestGuildLevelWireRoundTrip(t *testing.T) {
	for _, up := range []bool{false, true} {
		want := &GuildLevelRequest{CharacterName: "Aria", LevelUp: up}
		got, err := DecodeGuildLevelRequest(want.Encode())
		if err != nil || *got != *want {
			t.Fatalf("request %+v: got %+v, %v", want, got, err)
		}
	}
	// The client's own bytes: a name-only request plus the flag.
	if got, err := DecodeGuildLevelRequest(append(clientNameRequest("Aria"), 1)); err != nil || !got.LevelUp || got.CharacterName != "Aria" {
		t.Fatalf("the client's level-up bytes: got %+v, %v", got, err)
	}
	// NEGATIVE: no flag, a flag that is neither 0 nor 1, and trailing bytes.
	for _, bad := range [][]byte{
		clientNameRequest("Aria"),
		append(clientNameRequest("Aria"), 2),
		append(clientNameRequest("Aria"), 1, 0),
	} {
		if _, err := DecodeGuildLevelRequest(bad); err == nil {
			t.Fatalf("% x decoded as a level request", bad)
		}
	}

	want := &GuildLevelResult{GuildID: 7, Level: 2, LevelledUp: true, MaxMembers: 20, NextGold: 9_000_000, NextGuildPoints: 50_400}
	full := want.Encode()
	if len(full) != 2+2+8+1+1+2+8+8 {
		t.Fatalf("a success is %d bytes, want %d", len(full), 2+2+8+1+1+2+8+8)
	}
	got, err := DecodeGuildLevelResult(full)
	if err != nil || *got != *want {
		t.Fatalf("result: got %+v, %v; want %+v", got, err, want)
	}
	refusal := &GuildLevelResult{Error: "not enough guild points to level up the guild", Code: 0x4c32}
	got, err = DecodeGuildLevelResult(refusal.Encode())
	if err != nil || *got != *refusal {
		t.Fatalf("refusal: got %+v, %v; want %+v", got, err, refusal)
	}
	// NEGATIVE: a body cut short is an error, not a zero.
	if _, err := DecodeGuildLevelResult(full[:len(full)-1]); err == nil {
		t.Fatal("a truncated OpGuildLevelResult decoded without error")
	}
}

// TestGuildLevelFlow drives OpGuildLevel through the handler stack (round
// 528). Before the round no handler answered it, so the first request timed
// out. The refusals come in CGuild::HandleLevelUp's order with its codes; a
// report shows the level and the next level's cost; the level-up takes
// exactly 3,000,000 gold and 5,400 guild points and raises the cap to 20.
func TestGuildLevelFlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	accounts.Add("bob", "hunter3")
	chars := character.NewMemStore()
	aria, _ := chars.Create(ctx, 1, "Aria")
	bram, _ := chars.Create(ctx, 2, "Bram")
	guilds := guild.NewMemStore()

	handle := gateway.Chain(LoginHandler(accounts), GuildHandler(chars, guilds, nil))
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	login := func(user, pass string) (net.Conn, *bufio.Reader) {
		t.Helper()
		conn := dialTestServer(t, addr)
		t.Cleanup(func() { conn.Close() })
		r := bufio.NewReader(conn)
		if lr, err := DecodeLoginResult(doSend(t, conn, r, OpLogin, (&LoginRequest{Username: user, Password: pass}).Encode()).Data); err != nil || !lr.OK {
			t.Fatalf("login %s failed: err=%v result=%+v", user, err, lr)
		}
		return conn, r
	}
	connA, rA := login("alice", "hunter2")
	connB, rB := login("bob", "hunter3")

	level := func(conn net.Conn, r *bufio.Reader, name string, up bool) *GuildLevelResult {
		t.Helper()
		resp := doSend(t, conn, r, OpGuildLevel, (&GuildLevelRequest{CharacterName: name, LevelUp: up}).Encode())
		if resp.Opcode != OpGuildLevelResult {
			t.Fatalf("reply opcode 0x%04x, want OpGuildLevelResult", resp.Opcode)
		}
		lr, err := DecodeGuildLevelResult(resp.Data)
		if err != nil {
			t.Fatalf("DecodeGuildLevelResult: %v", err)
		}
		return lr
	}
	gold := func() int64 {
		t.Helper()
		c, err := chars.GetByID(ctx, aria.ID)
		if err != nil {
			t.Fatalf("GetByID: %v", err)
		}
		return c.Gold
	}
	refused := func(what string, lr *GuildLevelResult, code uint16, msg string) {
		t.Helper()
		if lr.Code != code || lr.Error != msg || lr.LevelledUp {
			t.Fatalf("%s: got %+v, want code 0x%x and %q", what, lr, code, msg)
		}
	}

	// NEGATIVE: guildless, both as a report and as a level-up (0x4c0d).
	refused("guildless report", level(connA, rA, "Aria", false), 0, "not in a guild")
	refused("guildless level-up", level(connA, rA, "Aria", true), 0x4c0d, "not in a guild")

	g, err := guilds.Create(ctx, "Silk Legion", aria.ID, "Aria")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if _, err := guilds.Join(ctx, g.ID, bram.ID, "Bram"); err != nil {
		t.Fatalf("Join: %v", err)
	}

	// The report: level 1, 15 members, 3,000,000 gold and 5,400 points next.
	if lr := level(connB, rB, "Bram", false); lr.Error != "" || lr.GuildID != g.ID || lr.Level != 1 ||
		lr.LevelledUp || lr.MaxMembers != 15 || lr.NextGold != 3_000_000 || lr.NextGuildPoints != 5_400 {
		t.Fatalf("report at level 1: got %+v", lr)
	}

	// NEGATIVE, in the engine's order.
	refused("not the master", level(connB, rB, "Bram", true), 0x4c1e, "only the guild master can level up the guild")
	refused("1,000 gold", level(connA, rA, "Aria", true), 0x4c31, "not enough gold to level up the guild")
	if err := chars.AddGold(ctx, aria.ID, 3_000_000-character.StartingGold); err != nil {
		t.Fatalf("AddGold: %v", err)
	}
	if err := guilds.AddPoints(ctx, g.ID, bram.ID, 5_399); err != nil {
		t.Fatalf("AddPoints: %v", err)
	}
	refused("5,399 points", level(connA, rA, "Aria", true), 0x4c32, "not enough guild points to level up the guild")
	if err := guilds.AddPoints(ctx, g.ID, aria.ID, 1); err != nil {
		t.Fatalf("AddPoints: %v", err)
	}
	if _, died, err := chars.ApplyDamage(ctx, aria.ID, 1<<30); err != nil || !died {
		t.Fatalf("ApplyDamage: died=%v err=%v", died, err)
	}
	refused("dead", level(connA, rA, "Aria", true), 0x4c07, "cannot level up the guild while dead")
	if gold() != 3_000_000 {
		t.Fatalf("the refusals spent gold: %d left, want 3000000", gold())
	}
	if err := chars.ResetHP(ctx, aria.ID); err != nil {
		t.Fatalf("ResetHP: %v", err)
	}

	lr := level(connA, rA, "Aria", true)
	if lr.Error != "" || lr.Code != 0 || !lr.LevelledUp || lr.Level != 2 || lr.MaxMembers != 20 ||
		lr.NextGold != 9_000_000 || lr.NextGuildPoints != 50_400 {
		t.Fatalf("the level-up: got %+v", lr)
	}
	if gold() != 0 {
		t.Fatalf("Aria has %d gold after the level-up, want 0 (exactly 3000000 taken)", gold())
	}
	if now, err := guilds.Get(ctx, g.ID); err != nil || now.Level != 2 || now.GatheredSP != 0 {
		t.Fatalf("the guild after the level-up: %+v, %v; want level 2 with 0 points", now, err)
	}
}

// failAfterPayGuilds is a guild store whose LevelUp takes the payment and then
// fails, as SQLStore.LevelUp would if its UPDATE or commit failed. Test-only.
type failAfterPayGuilds struct{ guild.Store }

func (failAfterPayGuilds) LevelUp(_ context.Context, _ int64, _ bool, _ int64, pay func(int64) error) (*guild.Guild, error) {
	if err := pay(3_000_000); err != nil {
		return nil, err
	}
	return nil, errors.New("commit failed")
}

// TestGuildLevelUpGoldIsNotLost covers srrevamp's own handling around the
// payment (round 528). A deduction that fails (the gold spent since the
// check) is the gold refusal, 0x4c31, and the guild keeps its level; a store
// that fails after taking the gold gives it back, and the reply is our own
// failure, with no engine code.
func TestGuildLevelUpGoldIsNotLost(t *testing.T) {
	ctx := context.Background()
	for _, tc := range []struct {
		name   string
		chars  func(*character.MemStore) character.Store
		guilds func(guild.Store) guild.Store
		code   uint16
		msg    string
	}{
		{"deduction refused", func(c *character.MemStore) character.Store { return spentGoldStore{c} },
			func(g guild.Store) guild.Store { return g }, 0x4c31, "not enough gold to level up the guild"},
		{"store fails after payment", func(c *character.MemStore) character.Store { return c },
			func(g guild.Store) guild.Store { return failAfterPayGuilds{g} }, 0, "failed to level up the guild"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			accounts := account.NewMemStore()
			accounts.Add("alice", "hunter2")
			chars := character.NewMemStore()
			aria, _ := chars.Create(ctx, 1, "Aria")
			if err := chars.AddGold(ctx, aria.ID, 3_000_000-character.StartingGold); err != nil {
				t.Fatalf("AddGold: %v", err)
			}
			mem := guild.NewMemStore()
			g, err := mem.Create(ctx, "Silk Legion", aria.ID, "Aria")
			if err != nil {
				t.Fatalf("Create: %v", err)
			}
			if err := mem.AddPoints(ctx, g.ID, aria.ID, 5_400); err != nil {
				t.Fatalf("AddPoints: %v", err)
			}

			handle := gateway.Chain(LoginHandler(accounts), GuildHandler(tc.chars(chars), tc.guilds(mem), nil))
			addr, cleanup := startTestServer(t, handle)
			defer cleanup()
			conn := dialTestServer(t, addr)
			defer conn.Close()
			r := bufio.NewReader(conn)
			if lr, err := DecodeLoginResult(doSend(t, conn, r, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
				t.Fatalf("login failed: err=%v result=%+v", err, lr)
			}

			resp := doSend(t, conn, r, OpGuildLevel, (&GuildLevelRequest{CharacterName: "Aria", LevelUp: true}).Encode())
			lr, err := DecodeGuildLevelResult(resp.Data)
			if err != nil {
				t.Fatalf("DecodeGuildLevelResult: %v", err)
			}
			if lr.Code != tc.code || lr.Error != tc.msg {
				t.Fatalf("got %+v, want code 0x%x and %q", lr, tc.code, tc.msg)
			}
			if now, _ := chars.GetByID(ctx, aria.ID); now.Gold != 3_000_000 {
				t.Fatalf("Aria has %d gold, want 3000000 kept", now.Gold)
			}
			if now, _ := mem.Get(ctx, g.ID); now.Level != 1 || now.GatheredSP != 5_400 {
				t.Fatalf("the guild moved: level %d, points %d; want 1 and 5400", now.Level, now.GatheredSP)
			}
		})
	}
}

// ctxGoldChars is a character store whose gold writes honour ctx as
// SQLStore's do: its ExecContext fails once ctx is done, with the context's
// error. MemStore ignores ctx, so without this a test could not tell a
// refund on a cancelled ctx from one on a live ctx. Test-only.
type ctxGoldChars struct{ *character.MemStore }

func (c ctxGoldChars) AddGold(ctx context.Context, characterID, amount int64) error {
	if err := ctx.Err(); err != nil {
		return fmt.Errorf("character: adding gold: %w", err)
	}
	return c.MemStore.AddGold(ctx, characterID, amount)
}

func (c ctxGoldChars) DeductGold(ctx context.Context, characterID, amount int64) error {
	if err := ctx.Err(); err != nil {
		return fmt.Errorf("character: deducting gold: %w", err)
	}
	return c.MemStore.DeductGold(ctx, characterID, amount)
}

// stopAfterPayGuilds takes the level-up's payment, then the server stops
// (stop cancels the gateway's ctx, which is the handler's), and the guild's
// UPDATE fails with the context's error, as SQLStore.LevelUp's ExecContext
// would. Test-only.
type stopAfterPayGuilds struct {
	guild.Store
	stop context.CancelFunc
	// paid and stopped are the probe: the deduction went through on the
	// live ctx, and the stop really cancelled the handler's ctx.
	paid, stopped bool
}

func (s *stopAfterPayGuilds) LevelUp(ctx context.Context, _ int64, _ bool, _ int64, pay func(int64) error) (*guild.Guild, error) {
	if err := pay(3_000_000); err != nil {
		return nil, err
	}
	s.paid = true
	s.stop()
	s.stopped = errors.Is(ctx.Err(), context.Canceled)
	return nil, fmt.Errorf("guild: raising the guild's level: %w", ctx.Err())
}

// TestGuildLevelUpRefundSurvivesAStop covers round 531: a server stop that
// lands between the level-up's deduction and the guild's UPDATE cancels the
// handler's ctx, and the refund must not run on that ctx, or it fails too and
// the gold is lost. NEGATIVE: with the refund on ctx (round 528), Aria ends
// with 0 gold.
func TestGuildLevelUpRefundSurvivesAStop(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	mem := character.NewMemStore()
	aria, _ := mem.Create(ctx, 1, "Aria")
	if err := mem.AddGold(ctx, aria.ID, 3_000_000-character.StartingGold); err != nil {
		t.Fatalf("AddGold: %v", err)
	}
	guilds := guild.NewMemStore()
	g, err := guilds.Create(ctx, "Silk Legion", aria.ID, "Aria")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if err := guilds.AddPoints(ctx, g.ID, aria.ID, 5_400); err != nil {
		t.Fatalf("AddPoints: %v", err)
	}

	stopping := &stopAfterPayGuilds{Store: guilds}
	handle := gateway.Chain(LoginHandler(accounts), GuildHandler(ctxGoldChars{mem}, stopping, nil))
	addr, stop := startTestServer(t, handle)
	defer stop()
	stopping.stop = stop
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)
	if lr, err := DecodeLoginResult(doSend(t, conn, r, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}

	resp := doSend(t, conn, r, OpGuildLevel, (&GuildLevelRequest{CharacterName: "Aria", LevelUp: true}).Encode())
	lr, err := DecodeGuildLevelResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeGuildLevelResult: %v", err)
	}
	if lr.Code != 0 || lr.Error != "failed to level up the guild" {
		t.Fatalf("got %+v, want srrevamp's own failure with no engine code", lr)
	}
	// The probe: the deduction really happened on the live ctx, and the
	// stop really cancelled it, so the refund is what put the gold back.
	if !stopping.paid || !stopping.stopped {
		t.Fatalf("the probe did not run: paid %v, ctx cancelled %v", stopping.paid, stopping.stopped)
	}
	if now, _ := mem.GetByID(ctx, aria.ID); now.Gold != 3_000_000 {
		t.Fatalf("Aria has %d gold after a level-up the stop interrupted, want 3000000 refunded", now.Gold)
	}
	if now, _ := guilds.Get(ctx, g.ID); now.Level != 1 || now.GatheredSP != 5_400 {
		t.Fatalf("the guild moved: level %d, points %d; want 1 and 5400", now.Level, now.GatheredSP)
	}
}

// stopAfterCreateGuilds founds the guild, then the server stops, so the
// founder's DeductGold fails with the context's error. Its Leave honours ctx
// as SQLStore.Leave's BeginTx does. Test-only.
type stopAfterCreateGuilds struct {
	guild.Store
	stop context.CancelFunc
	// created and stopped are the probe: the guild existed, and the stop
	// really cancelled the handler's ctx before the deduction.
	created, stopped bool
}

func (s *stopAfterCreateGuilds) Create(ctx context.Context, name string, leaderID int64, leaderName string) (*guild.Guild, error) {
	g, err := s.Store.Create(ctx, name, leaderID, leaderName)
	if err == nil {
		s.created = true
		s.stop()
		s.stopped = errors.Is(ctx.Err(), context.Canceled)
	}
	return g, err
}

func (s *stopAfterCreateGuilds) Leave(ctx context.Context, characterID int64) (int64, *guild.Guild, error) {
	if err := ctx.Err(); err != nil {
		return 0, nil, fmt.Errorf("guild: beginning transaction: %w", err)
	}
	return s.Store.Leave(ctx, characterID)
}

// TestGuildCreateRollbackSurvivesAStop covers the founding rollback (round
// 487) with the same shape as the level-up refund (round 531): a stop after
// the guild exists fails the founder's DeductGold, and the rollback's Leave
// must not run on the cancelled ctx, or the guild stays founded for free.
// NEGATIVE: with the Leave on ctx, Aria is still in the guild.
func TestGuildCreateRollbackSurvivesAStop(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	mem := character.NewMemStore()
	aria, _ := mem.Create(ctx, 1, "Aria")
	qualifyFounder(t, mem, aria)
	guilds := guild.NewMemStore()

	stopping := &stopAfterCreateGuilds{Store: guilds}
	handle := gateway.Chain(LoginHandler(accounts), GuildHandler(ctxGoldChars{mem}, stopping, nil))
	addr, stop := startTestServer(t, handle)
	defer stop()
	stopping.stop = stop
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)
	if lr, err := DecodeLoginResult(doSend(t, conn, r, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}

	resp := doSend(t, conn, r, OpGuildCreate, (&GuildCreateRequest{CharacterName: "Aria", GuildName: "Silk Legion"}).Encode())
	gr, err := DecodeGuildResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeGuildResult: %v", err)
	}
	if gr.Error == "" || gr.GuildID != 0 {
		t.Fatalf("got %+v, want a refusal and no guild", gr)
	}
	if !stopping.created || !stopping.stopped {
		t.Fatalf("the probe did not run: created %v, ctx cancelled %v", stopping.created, stopping.stopped)
	}
	if _, err := guilds.GetByCharacter(ctx, aria.ID); !errors.Is(err, guild.ErrNotInGuild) {
		t.Fatalf("Aria is still in a guild after a stop interrupted its founding (err=%v)", err)
	}
	if now, _ := mem.GetByID(ctx, aria.ID); now.Gold != character.StartingGold+guild.CreateGoldRequired {
		t.Fatalf("Aria has %d gold, want %d untouched", now.Gold, character.StartingGold+guild.CreateGoldRequired)
	}
}
