package session

import (
	"bufio"
	"bytes"
	"context"
	"strconv"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/gm"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/party"
	"github.com/OpenSRO/srrevamp/server/internal/quest"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// Round 657: the unique notices. Synthetic ids and names throughout; 1954 is
// only a number here.

// TestUniqueNoticeWire: the payload is retail 0x300C's -- u16 word, u32
// RefObjID and, for a kill, a u16-length name -- and decodes back.
func TestUniqueNoticeWire(t *testing.T) {
	spawn := (&UniqueNotice{Kind: UniqueNoticeSpawn, RefObjID: 1954}).Encode()
	if want := []byte{0x05, 0x0c, 0xa2, 0x07, 0, 0}; !bytes.Equal(spawn, want) {
		t.Fatalf("spawn = % x, want % x", spawn, want)
	}
	kill := (&UniqueNotice{Kind: UniqueNoticeKill, RefObjID: 1954, Killer: "Aria"}).Encode()
	if want := []byte{0x06, 0x0c, 0xa2, 0x07, 0, 0, 4, 0, 'A', 'r', 'i', 'a'}; !bytes.Equal(kill, want) {
		t.Fatalf("kill = % x, want % x", kill, want)
	}
	for _, n := range []UniqueNotice{{Kind: UniqueNoticeSpawn, RefObjID: 5871}, {Kind: UniqueNoticeKill, RefObjID: 3875, Killer: UnknownKiller}} {
		got, err := DecodeUniqueNotice(n.Encode())
		if err != nil || *got != n {
			t.Fatalf("round trip %+v -> %+v, %v", n, got, err)
		}
	}
	for name, bad := range map[string][]byte{
		"short":           {0x05, 0x0c, 1},
		"unknown kind":    {0x07, 0x0c, 1, 0, 0, 0},
		"spawn trailing":  append(append([]byte{}, spawn...), 9),
		"kill no name":    {0x06, 0x0c, 1, 0, 0, 0},
		"kill name short": {0x06, 0x0c, 1, 0, 0, 0, 5, 0, 'A'},
	} {
		if _, err := DecodeUniqueNotice(bad); err == nil {
			t.Fatalf("%s: decoded % x without an error", name, bad)
		}
	}
}

// TestUniqueKillerRule: the top-damage member of the top-damage group
// (CGObjMob vslot 399, 0x4c44a0).
func TestUniqueKillerRule(t *testing.T) {
	// 1 and 2 share party 50; 3 and 4 are alone.
	groupOf := func(id int64) int64 {
		if id == 1 || id == 2 {
			return 50
		}
		return 0
	}
	cases := []struct {
		name string
		hits []combat.Hit
		want int64
		ok   bool
	}{
		{"no one hit it: no killer", nil, 0, false},
		{"only uncredited blows", []combat.Hit{{AttackerID: 0, Damage: 99}}, 0, false},
		{"alone, the most damage", []combat.Hit{{AttackerID: 3, Damage: 10}, {AttackerID: 4, Damage: 25}}, 4, true},
		// The party's 40 + 30 beats the lone 60, and within the party 1's 40
		// beats 2's 30: 1 is named though 3 dealt the most on its own.
		{"a party beats a bigger lone attacker", []combat.Hit{{AttackerID: 3, Damage: 60}, {AttackerID: 1, Damage: 40}, {AttackerID: 2, Damage: 30}}, 1, true},
		{"the party's top member", []combat.Hit{{AttackerID: 1, Damage: 10}, {AttackerID: 2, Damage: 45}, {AttackerID: 3, Damage: 50}}, 2, true},
		{"a lone attacker beats a smaller party", []combat.Hit{{AttackerID: 1, Damage: 10}, {AttackerID: 2, Damage: 20}, {AttackerID: 4, Damage: 31}}, 4, true},
		// Ties keep the first met, in first-hit order (OURS).
		{"tied groups: the first", []combat.Hit{{AttackerID: 4, Damage: 20}, {AttackerID: 3, Damage: 20}}, 4, true},
		{"tied members: the first", []combat.Hit{{AttackerID: 2, Damage: 20}, {AttackerID: 1, Damage: 20}}, 2, true},
	}
	for _, c := range cases {
		got, ok := UniqueKiller(c.hits, groupOf)
		if got != c.want || ok != c.ok {
			t.Fatalf("%s: killer %d ok %v, want %d %v", c.name, got, ok, c.want, c.ok)
		}
	}
	// Without a party hub nobody is grouped.
	if got, _ := UniqueKiller([]combat.Hit{{AttackerID: 3, Damage: 60}, {AttackerID: 1, Damage: 40}, {AttackerID: 2, Damage: 30}}, nil); got != 3 {
		t.Fatalf("ungrouped: killer %d, want 3", got)
	}
}

// TestUniqueNoticeOnlyForClassThree: rank 3 only (not the rank-8 bosses), and
// the suppress flag silences it.
func TestUniqueNoticeOnlyForClassThree(t *testing.T) {
	for rarity, want := range map[int]bool{0: false, 1: false, 3: true, 4: false, 6: false, 8: false} {
		if got := UniqueNoticeFor(rarity); got != want {
			t.Fatalf("UniqueNoticeFor(%d) = %v, want %v", rarity, got, want)
		}
	}
	SetUniqueNoticeOff(true)
	defer SetUniqueNoticeOff(false)
	if UniqueNoticeFor(3) {
		t.Fatal("UniqueNoticeFor(3) with the notices off")
	}
}

// TestHubDamageList: the hub books each attacker's blows in first-hit order
// and hands the list to the killing blow only.
func TestHubDamageList(t *testing.T) {
	h := combat.NewHub()
	m := h.SpawnSpecies("z", combat.Species{Name: "U", RefObjID: 1954, Rarity: 3}, 0, 0, 0, 100, 0, 0, 0)
	if _, died, _, hits := h.ApplyDamageFrom(m.ID, 7, 30); died || hits != nil {
		t.Fatalf("first blow: died %v hits %v", died, hits)
	}
	h.ApplyDamageFrom(m.ID, 8, 20)
	h.ApplyDamage(m.ID, 5) // credited to nobody
	h.ApplyDamageFrom(m.ID, 7, 10)
	if got := h.Hits(m.ID); len(got) != 2 || got[0] != (combat.Hit{AttackerID: 7, Damage: 40}) || got[1] != (combat.Hit{AttackerID: 8, Damage: 20}) {
		t.Fatalf("list so far = %+v", got)
	}
	_, died, ok, hits := h.ApplyDamageFrom(m.ID, 8, 500)
	if !died || !ok || len(hits) != 2 || hits[1] != (combat.Hit{AttackerID: 8, Damage: 520}) {
		t.Fatalf("killing blow: died %v ok %v hits %+v", died, ok, hits)
	}
	if got := h.Hits(m.ID); len(got) != 0 {
		t.Fatalf("list kept after death: %+v", got)
	}
}

// uniqueWorld is three characters in one world behind the GM console (alice
// is the GM) and the combat handler, all in memory.
type uniqueWorld struct {
	hub      *world.Hub
	monsters *combat.Hub
	parties  *party.Hub
	a, b, c  *chatClient
}

func newUniqueWorld(t *testing.T) *uniqueWorld {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "pw1")
	accounts.Add("bob", "pw2")
	accounts.Add("carol", "pw3")
	chars := character.NewMemStore()
	aria, _ := chars.Create(ctx, 1, "Aria")
	chars.Create(ctx, 2, "Bram")
	chars.Create(ctx, 3, "Cato")

	items := stubCombatItems{100: {ID: 100, PhysAttackMax: 30}}
	inv := inventory.NewMemStore(items)
	if err := inv.AddItem(ctx, aria.ID, 100, 1); err != nil {
		t.Fatalf("seeding inventory: %v", err)
	}
	eq := equipment.NewMemStore(inv)
	if err := eq.Equip(ctx, aria.ID, equipment.SlotWeapon, 0); err != nil {
		t.Fatalf("equipping weapon: %v", err)
	}
	w := &uniqueWorld{hub: world.NewHub(), monsters: combat.NewHub(), parties: party.NewHub()}
	deps := &gm.Deps{Chars: chars, Monsters: w.monsters, Parties: w.parties, Uniques: []gm.Species{
		{Species: combat.Species{Name: "Test Unique", CodeName: "MOB_TEST_UNIQUE", RefObjID: 1954, Level: 20, Rarity: 3}, MaxHP: 5000, Defense: 1},
	}}
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, eq, w.hub),
		GMCommandHandler(chars, gm.ParseAccounts("alice"), deps, w.hub, nil),
		CombatHandler(chars, eq, items, w.hub, w.monsters, quest.NewMemStore(), inv, skill.NewMemStore(), nil, nil, w.parties))
	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)
	login := func(user, pw, name string) *chatClient {
		conn := dialTestServer(t, addr)
		t.Cleanup(func() { conn.Close() })
		c := &chatClient{t: t, conn: conn, r: bufio.NewReader(conn)}
		c.send(OpLogin, (&LoginRequest{Username: user, Password: pw}).Encode())
		if lr, err := DecodeLoginResult(c.next(OpLoginResult).Data); err != nil || !lr.OK {
			t.Fatalf("%s login: %v %+v", user, err, lr)
		}
		c.send(OpEnterWorld, (&EnterWorldRequest{CharacterName: name}).Encode())
		if er, err := DecodeEnterWorldResult(c.next(OpEnterWorldResult).Data); err != nil || !er.OK {
			t.Fatalf("%s enter world: %v %+v", name, err, er)
		}
		return c
	}
	w.a = login("alice", "pw1", "Aria")
	w.b = login("bob", "pw2", "Bram")
	w.c = login("carol", "pw3", "Cato")
	return w
}

func (c *chatClient) uniqueNotice() *UniqueNotice {
	c.t.Helper()
	n, err := DecodeUniqueNotice(c.next(OpUniqueNotice).Data)
	if err != nil {
		c.t.Fatalf("DecodeUniqueNotice: %v", err)
	}
	return n
}

func (c *chatClient) gm(line string, selected int64) *GMCommandResult {
	c.t.Helper()
	c.send(OpGMCommand, (&GMCommandRequest{Name: "Aria", Line: line, SelectedMonster: selected}).Encode())
	r, err := DecodeGMCommandResult(c.next(OpGMCommandResult).Data)
	if err != nil {
		c.t.Fatalf("DecodeGMCommandResult: %v", err)
	}
	return r
}

// TestUniqueNoticeGMSpawnAndKill: a GM's /spawnunique reaches every character
// as 0x0C05 with the RefObjID; /damage kills it and names the GM; a /kill
// with no one on the list names "???".
func TestUniqueNoticeGMSpawnAndKill(t *testing.T) {
	w := newUniqueWorld(t)
	if r := w.a.gm("/spawnunique test unique", 0); r.Refused {
		t.Fatalf("/spawnunique refused: %q", r.Text)
	}
	for _, c := range []*chatClient{w.a, w.b, w.c} {
		if n := c.uniqueNotice(); *n != (UniqueNotice{Kind: UniqueNoticeSpawn, RefObjID: 1954}) {
			t.Fatalf("spawn notice = %+v", n)
		}
	}
	id := w.monsters.All()[0].ID
	if r := w.a.gm("/damage 100", id); r.Refused {
		t.Fatalf("/damage refused: %q", r.Text)
	}
	if r := w.a.gm("/damage 999999 #"+strconv.FormatInt(id, 10), 0); r.Refused {
		t.Fatalf("/damage refused: %q", r.Text)
	}
	for _, c := range []*chatClient{w.a, w.b, w.c} {
		if n := c.uniqueNotice(); *n != (UniqueNotice{Kind: UniqueNoticeKill, RefObjID: 1954, Killer: "Aria"}) {
			t.Fatalf("kill notice = %+v", n)
		}
	}
	// By id this time, then /kill: nobody on the list.
	if r := w.a.gm("/spawnunique 1954", 0); r.Refused {
		t.Fatalf("/spawnunique 1954 refused: %q", r.Text)
	}
	w.b.uniqueNotice()
	var second int64
	for _, m := range w.monsters.All() {
		second = m.ID
	}
	if r := w.a.gm("/kill", second); r.Refused {
		t.Fatalf("/kill refused: %q", r.Text)
	}
	if n := w.b.uniqueNotice(); *n != (UniqueNotice{Kind: UniqueNoticeKill, RefObjID: 1954, Killer: UnknownKiller}) {
		t.Fatalf("/kill notice = %+v", n)
	}
	if r := w.a.gm("/spawnunique nobody", 0); !r.Refused {
		t.Fatalf("/spawnunique nobody = %+v, want refused", r)
	}
}

// TestUniqueNoticeCombatKill: a player's killing blow through the combat
// handler announces the unique to the whole world by the killer's name; an
// ordinary monster's kill announces nothing; with the notices off neither
// the spawn nor the kill is sent.
func TestUniqueNoticeCombatKill(t *testing.T) {
	w := newUniqueWorld(t)
	u := w.monsters.SpawnSpecies("jangan", combat.Species{Name: "Test Unique", RefObjID: 1954, Rarity: 3}, 0, 0, 0, 20, 0, 0, 0)
	w.a.send(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: u.ID}).Encode())
	if ar, err := DecodeAttackResult(w.a.next(OpAttackResult).Data); err != nil || !ar.MonsterDied {
		t.Fatalf("attack: %+v %v, want the unique dead", ar, err)
	}
	for _, c := range []*chatClient{w.a, w.b, w.c} {
		if n := c.uniqueNotice(); *n != (UniqueNotice{Kind: UniqueNoticeKill, RefObjID: 1954, Killer: "Aria"}) {
			t.Fatalf("kill notice = %+v", n)
		}
	}
	plain := w.monsters.SpawnSpecies("jangan", combat.Species{Name: "Mangyang", RefObjID: 1933}, 0, 0, 0, 20, 0, 0, 0)
	w.a.send(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: plain.ID}).Encode())
	if ar, err := DecodeAttackResult(w.a.next(OpAttackResult).Data); err != nil || !ar.MonsterDied {
		t.Fatalf("attack: %+v %v, want the Mangyang dead", ar, err)
	}
	w.b.none(OpUniqueNotice)

	SetUniqueNoticeOff(true)
	defer SetUniqueNoticeOff(false)
	if r := w.a.gm("/spawnunique 1954", 0); r.Refused {
		t.Fatalf("/spawnunique refused: %q", r.Text)
	}
	var id int64
	for _, m := range w.monsters.All() {
		id = m.ID
	}
	w.a.gm("/damage 999999", id)
	w.b.none(OpUniqueNotice)
}
