package session

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/guild"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// Round 682's review. NEGATIVES against 8e54648: the quoted name was refused
// 0x408 / 0x402, the in-world list answered, a failing guild lookup let the
// delete through, the legacy opcodes went unanswered, and a European
// character was given the China kit.

// A pre-682 name with a quote (grandfathered) can be deleted, restored and
// started: the quote refusal is for new names only.
func TestGrandfatheredQuotedNameIsNotLockedOut(t *testing.T) {
	h := newLobbyHarness(t, testCatalogue(), true)
	// The migrated row: made by the old path, which applied no name rule.
	if _, err := h.chars.Create(context.Background(), 1, "O'Brien"); err != nil {
		t.Fatal(err)
	}
	if r := h.lobby(&LobbyRequest{Action: LobbyDelete, Name: "O'Brien"}); !r.OK {
		t.Fatalf("delete of a grandfathered quoted name refused %#x", r.Code)
	}
	if r := h.lobby(&LobbyRequest{Action: LobbyRestore, Name: "O'Brien"}); !r.OK {
		t.Fatalf("restore refused %#x", r.Code)
	}
	p := h.send(OpStart, (&StartRequest{Name: "O'Brien"}).Encode())
	if r, err := DecodeStartResult(p.Data); err != nil || !r.OK {
		t.Fatalf("start of a grandfathered quoted name: %+v %v", r, err)
	}
	if p := h.read(); p.Opcode != OpEnterWorldResult {
		t.Fatalf("after Start %#x", p.Opcode)
	}
	// New names still may not carry one.
	h2 := newLobbyHarness(t, testCatalogue(), true)
	h2.wantCode(chinaManCreate("Ar'ia"), LobbyErrNameInvalid, "a new quoted name")
	h2.wantCode(&LobbyRequest{Action: LobbyNameCheck, Name: "Ar'ia"}, LobbyErrNameInvalid, "name check of a quoted name")
}

// Every lobby action is refused once the session is in the world.
func TestLobbyRefusedInTheWorld(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Register(ctx, "alice", "pw")
	chars := character.NewMemStore()
	inv := inventory.NewMemStore(refdata.NewMemStore())
	eq := equipment.NewMemStore(inv)
	hub := world.NewHub()
	handle := gateway.Chain(LoginHandler(accounts),
		LobbyHandler(LobbyDeps{Chars: chars, Catalogue: testCatalogue(), Inv: inv, Eq: eq, Hub: hub}),
		WorldHandler(chars, eq, hub))
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	h := &lobbyHarness{t: t, conn: conn, r: bufio.NewReader(conn)}
	h.send(OpLogin, (&LoginRequest{Username: "alice", Password: "pw"}).Encode())
	if r := h.lobby(chinaManCreate("Aria")); !r.OK {
		t.Fatalf("create before entering: %#x", r.Code)
	}
	h.send(OpStart, (&StartRequest{Name: "Aria"}).Encode())
	h.read() // the enter-world result
	for _, req := range []*LobbyRequest{{Action: LobbyList}, chinaManCreate("Bram"), {Action: LobbyNameCheck, Name: "Bram"},
		{Action: LobbyDelete, Name: "Aria"}, {Action: LobbyRestore, Name: "Aria"}} {
		h.wantCode(req, LobbyErrBusy, "in the world")
	}
}

type failingGuilds struct{}

func (failingGuilds) GetByCharacter(context.Context, int64) (*guild.Guild, error) {
	return nil, errors.New("the guild store is down")
}

// A guild lookup that errs refuses the delete (fails closed) and lists the
// character as guildless.
func TestDeleteFailsClosedOnAGuildError(t *testing.T) {
	ctx := context.Background()
	chars := character.NewMemStore()
	c, _ := chars.Create(ctx, 1, "Aria")
	d := &LobbyDeps{Chars: chars, Guilds: failingGuilds{}}
	if r := d.remove(ctx, 1, &LobbyRequest{Action: LobbyDelete, Name: "Aria"}); r.OK || r.Code != LobbyErrRefused {
		t.Fatalf("delete with the guild store down: %+v", r)
	}
	if got, _ := chars.GetByID(ctx, c.ID); got.Deleting() {
		t.Fatal("the character was marked deleted anyway")
	}
	if rec := d.record(ctx, c, time.Now()); rec.GuildClass != 0 {
		t.Errorf("listed with guild class %d", rec.GuildClass)
	}
	// "Not in a guild" is not an error.
	d.Guilds = guild.NewMemStore()
	if r := d.remove(ctx, 1, &LobbyRequest{Action: LobbyDelete, Name: "Aria"}); !r.OK {
		t.Fatalf("delete of a guildless character: %+v", r)
	}
}

// The removed 0x0010/0x0012/0x0014 are answered in their old formats with a
// notice the older client shows (its list error, its create/delete reason).
func TestLegacyLobbyIsToldToUpdate(t *testing.T) {
	addr, cleanup := startTestServer(t, LegacyLobbyHandler(nil))
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	h := &lobbyHarness{t: t, conn: conn, r: bufio.NewReader(conn)}

	// 0x0010 -> 0x0011: u16 length + error text, then a u16 count of 0 (the
	// pre-682 decoder, CharacterNet.decode_list_result).
	p := h.send(0x0010, nil)
	n := int(binary.LittleEndian.Uint16(p.Data))
	if p.Opcode != 0x0011 || string(p.Data[2:2+n]) != LegacyLobbyNotice || len(p.Data) != 2+n+2 || binary.LittleEndian.Uint16(p.Data[2+n:]) != 0 {
		t.Fatalf("legacy list reply %#x % x", p.Opcode, p.Data)
	}
	for _, op := range [][2]uint16{{0x0012, 0x0013}, {0x0014, 0x0015}} {
		p := h.send(op[0], encodeStrings("Aria"))
		ok, reason, err := decodeOKReason(p.Data)
		if p.Opcode != op[1] || err != nil || ok || reason != LegacyLobbyNotice {
			t.Errorf("legacy %#x reply %#x ok=%v %q %v", op[0], p.Opcode, ok, reason, err)
		}
	}
}

// A European character with nothing is not given the China legacy kit.
func TestLegacyKitSkipsEurope(t *testing.T) {
	ctx := context.Background()
	inv := inventory.NewMemStore(refdata.NewMemStore())
	eq := equipment.NewMemStore(inv)
	if err := equipment.GiveStartingKit(ctx, inv, eq, 7, character.GenderEuropeWoman); err != nil {
		t.Fatal(err)
	}
	if worn, _ := eq.Get(ctx, 7); len(worn) != 0 {
		t.Errorf("a European character was dressed in %+v", worn)
	}
	if bag, _ := inv.List(ctx, 7); len(bag) != 0 {
		t.Errorf("a European character was given %+v", bag)
	}
}
