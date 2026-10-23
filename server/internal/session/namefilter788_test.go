package session

// Round 788 (lane N): the lobby and the guild create through the name filter
// SR_ShardManager applies (0x40f300 / 0x43b810 -> 0x40f200), with a small
// AbuseFilter.txt built here (never the real one).

import (
	"bufio"
	"context"
	"strings"
	"testing"
	"unicode/utf16"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/namefilter"
)

// synthFilter is group 4 of a 36-cell file: [0-9A-Za-z_], the substring word
// "gm" and the whole word "admin".
func synthFilter(t *testing.T) *namefilter.Filter {
	t.Helper()
	row := func(cells ...string) string {
		all := make([]string, 36)
		copy(all[24:], cells)
		return strings.Join(all, "\t")
	}
	text := strings.Join([]string{
		row("#ALLOW_ID_TABLE", "0x0030", "0x0039"),
		row("#ALLOW_ID_TABLE", "0x0041", "0x005A"),
		row("#ALLOW_ID_TABLE", "0x005F", "0x005F"),
		row("#ALLOW_ID_TABLE", "0x0061", "0x007A"),
		row("GM", "2", "0", "0", "0"),
		row("Admin", "1", "0", "0", "0"),
	}, "\r\n") + "\r\n"
	data := []byte{0xff, 0xfe}
	for _, u := range utf16.Encode([]rune(text)) {
		data = append(data, byte(u), byte(u>>8))
	}
	f, err := namefilter.Load(data, 4)
	if err != nil {
		t.Fatal(err)
	}
	return f
}

func useFilter(t *testing.T, f *namefilter.Filter) {
	t.Helper()
	SetNameFilter(f)
	t.Cleanup(func() { SetNameFilter(nil) })
}

func TestLobbyNameRuleWithAbuseFilter(t *testing.T) {
	useFilter(t, synthFilter(t))
	h := newLobbyHarness(t, testCatalogue(), true)
	check := func(name string) *LobbyRequest { return &LobbyRequest{Action: LobbyNameCheck, Name: name} }

	for _, ok := range []string{"Tester", "Bob_1", "Admins", "ab"} {
		if r := h.lobby(check(ok)); !r.OK {
			t.Errorf("%q refused %#x", ok, r.Code)
		}
	}
	// Length first (0x40c), whatever the characters.
	h.wantCode(check("a"), LobbyErrNameLength, "1 byte")
	h.wantCode(check("Thirteen_char"), LobbyErrNameLength, "13 bytes")
	h.wantCode(check("x y"), LobbyErrNameInvalid, "a space")
	// 0x40d for each of 0x40f200's tests.
	h.wantCode(check("GMBob"), LobbyErrNameInvalid, "a substring word, case folded")
	h.wantCode(check("ADMIN"), LobbyErrNameInvalid, "a whole word")
	h.wantCode(check("Bob-1"), LobbyErrNameInvalid, "'-' outside the group's charset")
	h.wantCode(check("Ariä"), LobbyErrNameInvalid, "a byte >= 0x80")
	h.wantCode(check("Bob_char"), LobbyErrNameInvalid, "the SQL word _char")
	h.wantCode(check("xp_Bob"), LobbyErrNameInvalid, "the SQL word xp_")
	// A create applies the same rule (0x40f300 for both).
	h.wantCode(chinaManCreate("TheGM"), LobbyErrNameInvalid, "create: a substring word")
	// The name-taken test after the filter, case-insensitive (READ: the
	// shard's Latin1_General_CI_AS collation).
	if r := h.lobby(chinaManCreate("Tester")); !r.OK {
		t.Fatalf("create Tester refused %#x", r.Code)
	}
	h.wantCode(check("TESTER"), LobbyErrNameExists, "taken in another case")
	h.wantCode(chinaManCreate("tester"), LobbyErrNameExists, "create: taken in another case")
}

func TestGuildCreateNameFilter(t *testing.T) {
	useFilter(t, synthFilter(t))
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	aria, _ := chars.Create(ctx, 1, "Aria")
	qualifyFounder(t, chars, aria)
	guilds := guild.NewMemStore()

	handle := gateway.Chain(LoginHandler(accounts), testGuildHandler(t, chars, guilds, nil))
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)
	resp := doSend(t, conn, r, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}
	create := func(name string) *GuildResult {
		t.Helper()
		resp := doSend(t, conn, r, OpGuildCreate, (&GuildCreateRequest{CharacterName: "Aria", GuildName: name}).Encode())
		gr, err := DecodeGuildResult(resp.Data)
		if err != nil {
			t.Fatal(err)
		}
		return gr
	}
	notAllowed := guildErrorMessage(guild.ErrNameNotAllowed)
	for _, name := range []string{"Silk Legion", "GMguild", "admin", "my_guild", "Guild-1"} {
		if gr := create(name); gr.Error != notAllowed || gr.GuildID != 0 {
			t.Errorf("create %q answered %+v, want %q (0x4c19)", name, gr, notAllowed)
		}
	}
	// The length test comes first (0x4c18), filter or not.
	if gr := create("G"); gr.Error != guildErrorMessage(guild.ErrInvalidNameLength) {
		t.Errorf("a 1-byte name answered %+v, want the length refusal", gr)
	}
	if gr := create("SilkLegion"); gr.Error != "" || gr.GuildID == 0 {
		t.Fatalf("a clean name answered %+v, want a guild", gr)
	}
	// In a guild already: that refusal (0x4c17, the game server's pre-check)
	// comes ahead of the filter's. (Gold again, so the pre-check's gold test
	// passes.)
	if err := chars.AddGold(ctx, aria.ID, guild.CreateGoldRequired); err != nil {
		t.Fatal(err)
	}
	if gr := create("GMguild"); gr.Error != guildErrorMessage(guild.ErrAlreadyInGuild) {
		t.Errorf("a founder in a guild with a refused name answered %+v, want %q", gr, guildErrorMessage(guild.ErrAlreadyInGuild))
	}
}
