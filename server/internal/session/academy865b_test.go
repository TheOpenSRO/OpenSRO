package session

import (
	"bufio"
	"context"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/academy"
	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mall"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/shop"
)

// Round 865: the list record's academy byte (MEASURED: 2 the guardian, 1 an
// assistant guardian or an apprentice, 0 none), through the record's own
// encoder and decoder (the byte's place is lobby_golden.json's).
func TestLobbyRecordAcademyByte865(t *testing.T) {
	ctx := context.Background()
	chars := character.NewMemStore()
	store := academy.NewMemStore()
	SetAcademy(AcademyDeps{Store: store})
	t.Cleanup(func() { SetAcademy(AcademyDeps{}) })
	var cs []*character.Character
	for i, name := range []string{"Gwen", "Asst", "Appr", "None"} {
		c, err := chars.Create(ctx, int64(i+1), name)
		if err != nil {
			t.Fatal(err)
		}
		cs = append(cs, c)
	}
	camp, err := store.Found(ctx, academy.Joiner{CharID: cs[0].ID, Name: "Gwen", CurLevel: 70, MaxLevel: 70}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	store.AddMember(ctx, camp.ID, academy.Joiner{CharID: cs[1].ID, Name: "Asst", CurLevel: 45, MaxLevel: 45}, time.Now())
	store.AddMember(ctx, camp.ID, academy.Joiner{CharID: cs[2].ID, Name: "Appr", CurLevel: 5, MaxLevel: 5}, time.Now())
	d := &LobbyDeps{Chars: chars}
	for i, want := range []uint8{2, 1, 1, 0} {
		rec := d.record(ctx, cs[i], time.Now())
		if rec.AcademyClass != want {
			t.Errorf("%s: academy byte %d, want %d", cs[i].Name, rec.AcademyClass, want)
		}
		rd := lobbyReader{b: rec.encode(nil)}
		if got := decodeLobbyCharacter(&rd); got.AcademyClass != want {
			t.Errorf("%s: decoded academy byte %d", cs[i].Name, got.AcademyClass)
		}
	}
}

// Round 865: an honor store good costs gold and the buyer's honor points
// (academyshop.go: the gold test first, then 0x18d4's text, the points taken
// only with the item).
func TestAcademy865HonorStore(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	accounts.Add("bob", "hunter2")
	chars := character.NewMemStore()
	aria, _ := chars.Create(ctx, 1, "Aria")
	bram, _ := chars.Create(ctx, 2, "Bram")
	chars.AddGold(ctx, aria.ID, 10_000)
	chars.AddGold(ctx, bram.ID, 10_000)
	const helm = 7711
	items := stubShopItems{helm: {ID: helm, Price: 1000}}
	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), items)
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer inv.Close()
	if err := inv.TruncateForTest(ctx); err != nil {
		t.Fatal(err)
	}
	store := academy.NewMemStore()
	SetAcademy(AcademyDeps{Store: store})
	t.Cleanup(func() { SetAcademy(AcademyDeps{}) })
	camp, _ := store.Found(ctx, academy.Joiner{CharID: aria.ID, Name: "Aria", CurLevel: 70, MaxLevel: 70}, time.Now())
	// An apprentice who joined at 1 graduates: the guardian earns 39.
	store.AddMember(ctx, camp.ID, academy.Joiner{CharID: 50, Name: "Kid", CurLevel: 1, MaxLevel: 1}, time.Now())
	store.Graduate(ctx, 50, 1, time.Now())
	SetGuildGoodsCatalogue(&mall.Catalogue{NPCHonor: map[int64]int64{helm: 30}})
	t.Cleanup(func() { SetGuildGoodsCatalogue(nil) })

	svc := &shop.Service{Gold: chars, Inv: inv, Items: items}
	addr, cleanup := startTestServer(t, gateway.Chain(LoginHandler(accounts), ShopHandler(chars, svc, nil)))
	defer cleanup()
	buyAs := func(user, name string) *ShopBuyResult {
		conn := dialTestServer(t, addr)
		defer conn.Close()
		r := bufio.NewReader(conn)
		send := func(op uint16, data []byte) *proto.Packet {
			if err := proto.Write(conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
				t.Fatal(err)
			}
			conn.SetReadDeadline(time.Now().Add(2 * time.Second))
			p, err := proto.Read(r, nil, nil)
			if err != nil {
				t.Fatal(err)
			}
			return p
		}
		send(OpLogin, (&LoginRequest{Username: user, Password: "hunter2"}).Encode())
		res, _ := DecodeShopBuyResult(send(OpShopBuy, (&ShopBuyRequest{CharacterName: name, ItemID: helm, Quantity: 1}).Encode()).Data)
		return res
	}
	// Not in an academy: no points, 0x18d4's text, no gold taken.
	if r := buyAs("bob", "Bram"); r.OK || r.Reason != HonorLackReason {
		t.Fatalf("a non-member %+v", r)
	}
	if c, _ := chars.GetByID(ctx, bram.ID); c.Gold != bram.Gold+10_000 {
		t.Fatalf("gold taken on a refusal: %d", c.Gold)
	}
	// The guardian: 39 points, 30 spent, then 9 left is short.
	if r := buyAs("alice", "Aria"); !r.OK {
		t.Fatalf("the guardian %+v", r)
	}
	c, _ := store.CampOf(ctx, aria.ID)
	if m, _ := c.Member(aria.ID); m.Honor != 9 {
		t.Fatalf("honor left %d, want 9", m.Honor)
	}
	if now, _ := chars.GetByID(ctx, aria.ID); now.Gold != aria.Gold+10_000-1000 {
		t.Fatalf("gold %d", now.Gold)
	}
	if r := buyAs("alice", "Aria"); r.OK || r.Reason != HonorLackReason {
		t.Fatalf("short of points %+v", r)
	}
}

// Round 865: the daily honor rank update tells a changed camp 0x3C80 0c.
func TestAcademy865RankChangePush(t *testing.T) {
	f := startAcademy865(t)
	ctx := context.Background()
	c := f.found(t)
	for id := int64(100); id < 110; id++ {
		f.store.AddMember(ctx, c.ID, academy.Joiner{CharID: id, Name: "Kid", CurLevel: 1, MaxLevel: 1}, f.now())
		f.store.Graduate(ctx, id, 1, f.now())
	}
	academyRT.Load().updateRanks(ctx, f.now())
	acWant(t, "0c", f.push(t, f.p["Aria"]), academy.EncodeRank(1))
	a := f.p["Aria"]
	f.selectNPC(t, a)
	list := f.ask(t, a, proto.OpAcademyHonorRankRequest, acU32(f.npc), proto.OpAcademyHonorRankAck)
	acWant(t, "B478", list, academy.EncodeHonorList([]academy.HonorRow{{Ranking: 1, Rank: 1, Guardian: "Aria", CurLevel: 70,
		MaxLevel: 70, GraduateCount: 10}}))
}
