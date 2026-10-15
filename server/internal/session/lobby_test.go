package session

import (
	"bufio"
	"context"
	"net"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/guild"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
	"github.com/OpenSRO/OpenSRO/server/internal/worldmap"
)

// Round 682's lobby: the create checks and their codes, the 4-slot limit, the
// name check, delete -> minutes left -> restore -> purge, and Start refused
// while deleting. NEGATIVE: before round 682 none of OpLobby, LobbyDeps or
// character.LobbyStore exists and this file does not compile; the old
// 0x0012 create answered every one of these with "create failed" or a
// success.

type lobbyHarness struct {
	t      *testing.T
	chars  *character.MemStore
	inv    *inventory.MemStore
	eq     *equipment.MemStore
	guilds *guild.MemStore
	clock  time.Time
	conn   net.Conn
	r      *bufio.Reader
}

func newLobbyHarness(t *testing.T, catalogue *refdata.CreatableSet, login bool) *lobbyHarness {
	t.Helper()
	return newLobbyHarnessWith(t, catalogue, login, nil)
}

// newLobbyHarnessWith is newLobbyHarness with mod applied to the deps before
// the handler is built (round 692: the character defaults).
func newLobbyHarnessWith(t *testing.T, catalogue *refdata.CreatableSet, login bool, mod func(*LobbyDeps)) *lobbyHarness {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	if _, err := accounts.Register(ctx, "alice", "pw"); err != nil {
		t.Fatal(err)
	}
	h := &lobbyHarness{t: t, chars: character.NewMemStore(), guilds: guild.NewMemStore(),
		clock: time.Date(2026, 10, 2, 12, 0, 0, 0, time.UTC)}
	refItems := refdata.NewMemStore()
	// The two ammunition rows, so a stack fits one bag slot (the inventory
	// reads MaxStack from refdata; synthetic rows).
	if err := refItems.ImportItems(ctx, []refdata.Item{{ID: 3655, MaxStack: 250}, {ID: 10885, MaxStack: 250}}); err != nil {
		t.Fatal(err)
	}
	h.inv = inventory.NewMemStore(refItems)
	h.eq = equipment.NewMemStore(h.inv)
	deps := LobbyDeps{Chars: h.chars, Catalogue: catalogue, Inv: h.inv, Eq: h.eq, Guilds: h.guilds,
		Now: func() time.Time { return h.clock }, Pick: func(int) int { return 0 }}
	if mod != nil {
		mod(&deps)
	}
	handle := gateway.Chain(LoginHandler(accounts), LobbyHandler(deps), WorldHandler(h.chars, h.eq, world.NewHub()))
	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)
	h.conn = dialTestServer(t, addr)
	t.Cleanup(func() { h.conn.Close() })
	h.r = bufio.NewReader(h.conn)
	if login {
		p := h.send(OpLogin, (&LoginRequest{Username: "alice", Password: "pw"}).Encode())
		if lr, err := DecodeLoginResult(p.Data); err != nil || !lr.OK {
			t.Fatalf("login: %v %+v", err, lr)
		}
	}
	return h
}

func (h *lobbyHarness) send(op uint16, data []byte) *proto.Packet {
	h.t.Helper()
	if err := proto.Write(h.conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
		h.t.Fatal(err)
	}
	return h.read()
}

func (h *lobbyHarness) read() *proto.Packet {
	h.t.Helper()
	h.conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	p, err := proto.Read(h.r, nil, nil)
	if err != nil {
		h.t.Fatalf("read: %v", err)
	}
	return p
}

func (h *lobbyHarness) lobby(req *LobbyRequest) *LobbyResult {
	h.t.Helper()
	p := h.send(OpLobby, req.Encode())
	if p.Opcode != OpLobbyResult {
		h.t.Fatalf("reply opcode %#x, want 0xB007", p.Opcode)
	}
	r, err := DecodeLobbyResult(p.Data)
	if err != nil {
		h.t.Fatal(err)
	}
	if r.Action != req.Action {
		h.t.Fatalf("reply action %d, want %d", r.Action, req.Action)
	}
	return r
}

func (h *lobbyHarness) wantCode(req *LobbyRequest, code uint16, why string) {
	h.t.Helper()
	r := h.lobby(req)
	if r.OK || r.Code != code {
		h.t.Errorf("%s: OK=%v code %#x, want refused with %#x", why, r.OK, r.Code, code)
	}
}

func (h *lobbyHarness) list() []LobbyCharacter {
	h.t.Helper()
	r := h.lobby(&LobbyRequest{Action: LobbyList})
	if !r.OK {
		h.t.Fatalf("list refused %#x", r.Code)
	}
	return r.Characters
}

func TestLobbyCreateRefusals(t *testing.T) {
	h := newLobbyHarness(t, testCatalogue(), true)
	with := func(f func(r *LobbyRequest)) *LobbyRequest {
		r := chinaManCreate("Aria")
		f(r)
		return r
	}
	h.wantCode(with(func(r *LobbyRequest) { r.RefObjID = 1907 }), LobbyErrBadChargen, "a body outside the catalogue")
	h.wantCode(with(func(r *LobbyRequest) { r.RefObjID = 3643 }), LobbyErrBadChargen, "an item id as the body")
	h.wantCode(with(func(r *LobbyRequest) { r.Chest = 9999 }), LobbyErrBadChargen, "an item outside the catalogue")
	h.wantCode(with(func(r *LobbyRequest) { r.Chest, r.Legs, r.Feet = 11620, 11621, 11622 }), LobbyErrBadChargen, "European armour on a Chinese body")
	h.wantCode(with(func(r *LobbyRequest) { r.Weapon = 10888 }), LobbyErrBadChargen, "a European weapon on a Chinese body")
	h.wantCode(with(func(r *LobbyRequest) { r.Chest, r.Legs, r.Feet = 3652, 3653, 3654 }), LobbyErrBadChargen, "a woman's set on a man")
	h.wantCode(with(func(r *LobbyRequest) { r.Chest = 3644 }), LobbyErrBadChargen, "trousers in the chest field")
	h.wantCode(with(func(r *LobbyRequest) { r.Weapon = 10886 }), LobbyErrBadChargen, "a shield as the weapon")
	h.wantCode(with(func(r *LobbyRequest) { r.Feet = 0 }), LobbyErrBadChargen, "no boots (Protector none is not offered)")
	h.wantCode(with(func(r *LobbyRequest) { r.Scale = 0x25 }), LobbyErrBadChargen, "a height of 5")
	h.wantCode(with(func(r *LobbyRequest) { r.Weapon = 0 }), LobbyErrNoWeapon, "no weapon")
	h.wantCode(with(func(r *LobbyRequest) { r.Name = "A" }), LobbyErrNameLength, "a one-byte name")
	h.wantCode(with(func(r *LobbyRequest) { r.Name = "ThirteenChars" }), LobbyErrNameLength, "a 13-byte name")
	h.wantCode(with(func(r *LobbyRequest) { r.Name = "Ar ia" }), LobbyErrNameInvalid, "a space")
	h.wantCode(with(func(r *LobbyRequest) { r.Name = "Ar'ia" }), LobbyErrNameInvalid, "a quote")
	h.wantCode(with(func(r *LobbyRequest) { r.Name = "Ar\"ia" }), LobbyErrNameInvalid, "a double quote")
	h.wantCode(with(func(r *LobbyRequest) { r.Name = "Ariä" }), LobbyErrNameInvalid, "a byte >= 0x80 (outside [0-9A-Za-z_])")
	h.wantCode(with(func(r *LobbyRequest) { r.Legs, r.Feet = 3641, 3642 }), LobbyErrCreateFailed, "pieces of two armour classes")
	if n := len(h.list()); n != 0 {
		t.Fatalf("%d characters after only refusals", n)
	}
	if r := h.lobby(chinaManCreate("Aria")); !r.OK {
		t.Fatalf("a valid create refused %#x", r.Code)
	}
	h.wantCode(with(func(r *LobbyRequest) { r.Name = "ARIA" }), LobbyErrNameExists, "a name taken, in another case")

	// Without a catalogue the server cannot tell what it may make.
	bare := newLobbyHarness(t, nil, true)
	bare.wantCode(chinaManCreate("Bram"), LobbyErrBadChargen, "no catalogue loaded")
	// And without a login, nothing.
	anon := newLobbyHarness(t, testCatalogue(), false)
	anon.wantCode(chinaManCreate("Bram"), LobbyErrNoUser, "not logged in")
	anon.wantCode(&LobbyRequest{Action: LobbyList}, LobbyErrNoUser, "list, not logged in")
}

func TestLobbyFourCharactersPerAccount(t *testing.T) {
	h := newLobbyHarness(t, testCatalogue(), true)
	for _, name := range []string{"One", "Two", "Three", "Four"} {
		if r := h.lobby(chinaManCreate(name)); !r.OK {
			t.Fatalf("create %s refused %#x", name, r.Code)
		}
	}
	h.wantCode(chinaManCreate("Five"), LobbyErrAccountFull, "a fifth character")
	if character.MaxPerAccount != 4 {
		t.Errorf("MaxPerAccount %d, want retail's 4", character.MaxPerAccount)
	}
	// A character pending deletion still holds its slot.
	if r := h.lobby(&LobbyRequest{Action: LobbyDelete, Name: "Four"}); !r.OK {
		t.Fatalf("delete refused %#x", r.Code)
	}
	h.wantCode(chinaManCreate("Five"), LobbyErrAccountFull, "a fifth beside one pending deletion")
}

func TestLobbyCreateDressesAndPlaces(t *testing.T) {
	h := newLobbyHarness(t, testCatalogue(), true)
	ctx := context.Background()
	cases := []struct {
		req    *LobbyRequest
		gender string
		worn   map[equipment.Slot]int64
		bag    int64 // an item left in the bag, 0 for none
		zone   string
		spawn  StartSpawn
	}{
		{chinaManCreate("Sword"), character.GenderChinaMan,
			map[equipment.Slot]int64{equipment.SlotMail: 3643, equipment.SlotPants: 3644, equipment.SlotBoots: 3645, equipment.SlotWeapon: 3632, equipment.SlotShield: 10886},
			0, "jangan", StartSpawns[character.RaceChina][0]},
		{&LobbyRequest{Action: LobbyCreate, Name: "Archer", RefObjID: 1909, Scale: 0x40, Chest: 3640, Legs: 3641, Feet: 3642, Weapon: 3636}, character.GenderChinaMan,
			map[equipment.Slot]int64{equipment.SlotMail: 3640, equipment.SlotPants: 3641, equipment.SlotBoots: 3642, equipment.SlotWeapon: 3636},
			3655, "jangan", StartSpawns[character.RaceChina][0]},
		{&LobbyRequest{Action: LobbyCreate, Name: "Spear", RefObjID: 1923, Scale: 0x04, Chest: 3652, Legs: 3653, Feet: 3654, Weapon: 3634}, character.GenderChinaWoman,
			map[equipment.Slot]int64{equipment.SlotMail: 3652, equipment.SlotPants: 3653, equipment.SlotBoots: 3654, equipment.SlotWeapon: 3634},
			0, "jangan", StartSpawns[character.RaceChina][0]},
		{&LobbyRequest{Action: LobbyCreate, Name: "Xbow", RefObjID: 14875, Scale: 0x22, Chest: 11620, Legs: 11621, Feet: 11622, Weapon: 10891}, character.GenderEuropeMan,
			map[equipment.Slot]int64{equipment.SlotMail: 11620, equipment.SlotPants: 11621, equipment.SlotBoots: 11622, equipment.SlotWeapon: 10891},
			10885, "constantinople", StartSpawns[character.RaceEurope][0]},
	}
	for _, c := range cases {
		if r := h.lobby(c.req); !r.OK {
			t.Fatalf("%s refused %#x", c.req.Name, r.Code)
		}
		list, _ := h.chars.ListByAccount(ctx, 1)
		got := findOwned(list, c.req.Name)
		if got == nil {
			t.Fatalf("%s not stored", c.req.Name)
		}
		if got.RefObjID != int64(c.req.RefObjID) || got.Scale != int(c.req.Scale) || got.Gender != c.gender {
			t.Errorf("%s stored as model %d scale %#x gender %q", c.req.Name, got.RefObjID, got.Scale, got.Gender)
		}
		wx, wz, _ := worldmap.ToZoneWorld(c.zone, c.spawn.RegionX, c.spawn.RegionY, c.spawn.X, c.spawn.Z)
		if got.StartZone != c.zone || got.StartX != wx || got.StartZ != wz || got.StartY != c.spawn.Y {
			t.Errorf("%s starts at %q (%v, %v, %v), want %q (%v, %v, %v)", c.req.Name, got.StartZone, got.StartX, got.StartY, got.StartZ, c.zone, wx, c.spawn.Y, wz)
		}
		worn, _ := h.eq.Get(ctx, got.ID)
		if len(worn) != len(c.worn) {
			t.Errorf("%s wears %d items, want %d: %+v", c.req.Name, len(worn), len(c.worn), worn)
		}
		for _, w := range worn {
			if c.worn[w.Slot] != w.ItemID {
				t.Errorf("%s wears %d in slot %d, want %d", c.req.Name, w.ItemID, w.Slot, c.worn[w.Slot])
			}
		}
		bag, _ := h.inv.List(ctx, got.ID)
		switch {
		case c.bag == 0 && len(bag) != 0:
			t.Errorf("%s carries %+v, want nothing", c.req.Name, bag)
		case c.bag != 0 && (len(bag) != 1 || bag[0].ItemID != c.bag):
			t.Errorf("%s carries %+v, want its ammunition %d", c.req.Name, bag, c.bag)
		}
	}
	// The list record carries what the row and the worn items say.
	for _, rec := range h.list() {
		if rec.Name == "Sword" {
			if rec.RefObjID != 1909 || rec.Scale != 0x22 || rec.Level != 1 || rec.Str != character.StartingStr ||
				rec.HP != character.StartingMaxHP || rec.MP != character.StartingMaxMP || rec.Deleting || len(rec.Items) != 5 {
				t.Errorf("Sword's record %+v", rec)
			}
			if rec.Items[0].RefItemID != 3643 || rec.Items[4].RefItemID != 10886 {
				t.Errorf("Sword's items not in slot order: %+v", rec.Items)
			}
		}
	}
}

// The European start spawns are READ in the European frame and land in the
// constantinople bucket; the China ones in Jangan's. Pick's index picks the row.
func TestLobbyStartSpawnTable(t *testing.T) {
	for race, zone := range map[int]string{character.RaceChina: "jangan", character.RaceEurope: "constantinople"} {
		for i := 0; i < 3; i++ {
			z, x, y, wz := startFor(race, i)
			sp := StartSpawns[race][i]
			ex, ez, _ := worldmap.ToZoneWorld(zone, sp.RegionX, sp.RegionY, sp.X, sp.Z)
			if z != zone || x != ex || wz != ez || y != sp.Y {
				t.Errorf("race %d spawn %d: %q (%v, %v, %v)", race, i, z, x, y, wz)
			}
		}
	}
	// 98/168 local (960, 420) is directly north of Jangan's 97/168: world Z
	// -1920 + (960 - 420).
	if _, x, _, z := startFor(character.RaceChina, 0); x != 0 || z != -1920+540 {
		t.Errorf("China spawn 0 at (%v, %v)", x, z)
	}
}

func TestLobbyNameCheck(t *testing.T) {
	h := newLobbyHarness(t, testCatalogue(), true)
	if r := h.lobby(&LobbyRequest{Action: LobbyNameCheck, Name: "Aria"}); !r.OK {
		t.Fatalf("a free name refused %#x", r.Code)
	}
	h.wantCode(&LobbyRequest{Action: LobbyNameCheck, Name: "A"}, LobbyErrNameLength, "too short")
	h.wantCode(&LobbyRequest{Action: LobbyNameCheck, Name: "ABCDEFGHIJKLM"}, LobbyErrNameLength, "too long")
	h.wantCode(&LobbyRequest{Action: LobbyNameCheck, Name: "A ria"}, LobbyErrNameInvalid, "a space")
	if r := h.lobby(chinaManCreate("Aria")); !r.OK {
		t.Fatal(r.Code)
	}
	h.wantCode(&LobbyRequest{Action: LobbyNameCheck, Name: "aria"}, LobbyErrNameExists, "taken")
	// A name pending deletion is still taken.
	h.lobby(&LobbyRequest{Action: LobbyDelete, Name: "Aria"})
	h.wantCode(&LobbyRequest{Action: LobbyNameCheck, Name: "Aria"}, LobbyErrNameExists, "taken while pending deletion")
	anon := newLobbyHarness(t, testCatalogue(), false)
	anon.wantCode(&LobbyRequest{Action: LobbyNameCheck, Name: "Aria"}, LobbyErrNoUser, "not logged in")
}

func TestLobbyDeleteRestorePurge(t *testing.T) {
	h := newLobbyHarness(t, testCatalogue(), true)
	ctx := context.Background()
	for _, n := range []string{"Aria", "Bram"} {
		if r := h.lobby(chinaManCreate(n)); !r.OK {
			t.Fatal(r.Code)
		}
	}
	h.wantCode(&LobbyRequest{Action: LobbyDelete, Name: "Nobody"}, LobbyErrNotOnAccount, "a name not on the account")
	h.wantCode(&LobbyRequest{Action: LobbyDelete, Name: ""}, LobbyErrDeleteName, "an empty name")
	h.wantCode(&LobbyRequest{Action: LobbyRestore, Name: "Aria"}, LobbyErrNothingRestore, "restore, not deleting")

	if r := h.lobby(&LobbyRequest{Action: LobbyDelete, Name: "Aria"}); !r.OK {
		t.Fatalf("delete refused %#x", r.Code)
	}
	h.wantCode(&LobbyRequest{Action: LobbyDelete, Name: "Aria"}, LobbyErrRefused, "deleting twice")
	minutes := func() uint32 {
		for _, c := range h.list() {
			if c.Name == "Aria" {
				if !c.Deleting {
					return 0
				}
				return c.MinutesLeft
			}
		}
		t.Fatal("Aria not listed")
		return 0
	}
	if m := minutes(); m != 10080 {
		t.Errorf("just deleted: %d minutes left, want 10080", m)
	}
	h.clock = h.clock.Add(25*time.Hour + 30*time.Second)
	if m := minutes(); m != 10080-25*60-1 {
		t.Errorf("25 h later: %d minutes left, want %d", m, 10080-25*60-1)
	}
	h.clock = h.clock.Add(7 * 24 * time.Hour)
	if m := minutes(); m != 1 {
		t.Errorf("past the end: %d minutes left, want the floor 1", m)
	}

	if r := h.lobby(&LobbyRequest{Action: LobbyRestore, Name: "Aria"}); !r.OK {
		t.Fatalf("restore refused %#x", r.Code)
	}
	if m := minutes(); m != 0 {
		t.Errorf("restored, still deleting with %d minutes", m)
	}
	// Delete again, and the purge removes it only once 10080 minutes pass.
	h.lobby(&LobbyRequest{Action: LobbyDelete, Name: "Aria"})
	deletedAt := h.clock
	stopped, stop := context.WithCancel(ctx)
	stop() // RunLobbyPurge purges once, then returns on the cancelled context
	RunLobbyPurge(stopped, h.chars, time.Hour, func() time.Time { return deletedAt.Add(character.DeleteDelay - time.Second) }, nil)
	if n := len(h.list()); n != 2 {
		t.Fatalf("%d characters after a purge one second early, want 2", n)
	}
	RunLobbyPurge(stopped, h.chars, time.Hour, func() time.Time { return deletedAt.Add(character.DeleteDelay) }, nil)
	if l := h.list(); len(l) != 1 || l[0].Name != "Bram" {
		t.Errorf("after the purge: %+v", l)
	}
	// The name is free again.
	if r := h.lobby(&LobbyRequest{Action: LobbyNameCheck, Name: "Aria"}); !r.OK {
		t.Errorf("Aria still taken after the purge: %#x", r.Code)
	}

	// A guild member cannot be deleted (READ: the server's guild check, 0x402).
	list, _ := h.chars.ListByAccount(ctx, 1)
	bram := findOwned(list, "Bram")
	if _, err := h.guilds.Create(ctx, "Guild", bram.ID, bram.Name); err != nil {
		t.Fatal(err)
	}
	h.wantCode(&LobbyRequest{Action: LobbyDelete, Name: "Bram"}, LobbyErrRefused, "a guild master")
	if l := h.list(); l[0].GuildClass != 2 {
		t.Errorf("a guild master's record has guild class %d, want 2", l[0].GuildClass)
	}
}

func TestStartRefusedWhileDeleting(t *testing.T) {
	h := newLobbyHarness(t, testCatalogue(), true)
	if r := h.lobby(chinaManCreate("Aria")); !r.OK {
		t.Fatal(r.Code)
	}
	start := func(name string) *StartResult {
		t.Helper()
		p := h.send(OpStart, (&StartRequest{Name: name}).Encode())
		if p.Opcode != OpStartResult {
			t.Fatalf("reply %#x, want 0xB001", p.Opcode)
		}
		r, err := DecodeStartResult(p.Data)
		if err != nil {
			t.Fatal(err)
		}
		return r
	}
	if r := start("Nobody"); r.OK || r.Code != LobbyErrNotOnAccount {
		t.Errorf("start of a stranger: %+v", r)
	}
	if r := start(""); r.OK || r.Code != LobbyErrRefused {
		t.Errorf("start of an empty name: %+v", r)
	}
	h.lobby(&LobbyRequest{Action: LobbyDelete, Name: "Aria"})
	if r := start("Aria"); r.OK || r.Code != LobbyErrRefused {
		t.Errorf("start while deleting: %+v, want 0x402", r)
	}
	// Nor through the older enter-world message.
	p := h.send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if r, err := DecodeEnterWorldResult(p.Data); err != nil || r.OK {
		t.Errorf("OpEnterWorld while deleting: %+v %v", r, err)
	}
	h.lobby(&LobbyRequest{Action: LobbyRestore, Name: "Aria"})
	if r := start("Aria"); !r.OK {
		t.Fatalf("start after restore: %+v", r)
	}
	// 0xB001 [1] is followed by the enter-world result, at the start spawn.
	p = h.read()
	ew, err := DecodeEnterWorldResult(p.Data)
	if p.Opcode != OpEnterWorldResult || err != nil || !ew.OK {
		t.Fatalf("after Start: %#x %+v %v", p.Opcode, ew, err)
	}
	sp := StartSpawns[character.RaceChina][0]
	wx, wz, _ := worldmap.ToZoneWorld("jangan", sp.RegionX, sp.RegionY, sp.X, sp.Z)
	if ew.Zone != "jangan" || ew.X != float32(wx) || ew.Z != float32(wz) || !ew.Restored || ew.FrameRegion != "97/168" {
		t.Errorf("entered at %q (%v, %v) frame %q restored %v, want jangan (%v, %v) 97/168 restored", ew.Zone, ew.X, ew.Z, ew.FrameRegion, ew.Restored, wx, wz)
	}
	anon := newLobbyHarness(t, testCatalogue(), false)
	p = anon.send(OpStart, (&StartRequest{Name: "Aria"}).Encode())
	if r, _ := DecodeStartResult(p.Data); r == nil || r.OK || r.Code != LobbyErrNoUser {
		t.Errorf("start not logged in: %+v", r)
	}
}
