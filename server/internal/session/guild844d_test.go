package session

import (
	"bufio"
	"context"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mall"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/shop"
)

// Round 844 lane G (part 2): a guild store good costs gold and the guild's GP,
// the master's alone (guildgoods.go: 0x18c4 / 0x18c5 after the gold test).
func TestGuild844GuildGoods(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	accounts.Add("bob", "hunter2")
	chars := character.NewMemStore()
	aria, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	bram, err := chars.Create(ctx, 2, "Bram")
	if err != nil {
		t.Fatal(err)
	}
	const crest = 9268
	items := stubShopItems{crest: {ID: crest, Price: 1000}}
	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), items)
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer inv.Close()
	if err := inv.TruncateForTest(ctx); err != nil {
		t.Fatal(err)
	}
	guilds := guild.NewMemStore()
	g, _ := guilds.Create(ctx, "Akat", aria.ID, "Aria")
	if _, err := guilds.Join(ctx, g.ID, bram.ID, "Bram"); err != nil {
		t.Fatal(err)
	}
	SetGuildGoodsCatalogue(&mall.Catalogue{NPCGP: map[int64]int64{crest: 20000}})
	t.Cleanup(func() { SetGuildGoodsCatalogue(nil) })

	svc := &shop.Service{Gold: chars, Inv: inv, Items: items}
	handle := gateway.Chain(LoginHandler(accounts), ShopHandler(chars, svc, nil), testGuildHandler(t, chars, guilds, nil))
	addr, cleanup := startTestServer(t, handle)
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
		res, _ := DecodeShopBuyResult(send(OpShopBuy, (&ShopBuyRequest{CharacterName: name, ItemID: crest, Quantity: 1}).Encode()).Data)
		return res
	}
	// A member: 0x18c4's text.
	if r := buyAs("bob", "Bram"); r.OK || r.Reason != GuildStoreBuyLimitReason {
		t.Fatalf("a member %+v", r)
	}
	// The master, the guild with no GP: 0x18c5's, and no gold taken.
	before, _ := chars.GetByID(ctx, aria.ID)
	if r := buyAs("alice", "Aria"); r.OK || r.Reason != GuildStoreLackGPReason {
		t.Fatalf("no GP %+v", r)
	}
	if now, _ := chars.GetByID(ctx, aria.ID); now.Gold != before.Gold {
		t.Fatal("gold taken on a refusal")
	}
	if err := guilds.AddPoints(ctx, g.ID, bram.ID, 25000); err != nil {
		t.Fatal(err)
	}
	if r := buyAs("alice", "Aria"); !r.OK {
		t.Fatalf("the master %+v", r)
	}
	after, _ := guilds.Get(ctx, g.ID)
	if after.GatheredSP != 5000 {
		t.Fatalf("GP %d", after.GatheredSP)
	}
	m, _ := memberOf(after, bram.ID)
	if m.GPDonation != 25000 {
		t.Fatal("the donation moved")
	}
	if now, _ := chars.GetByID(ctx, aria.ID); now.Gold != before.Gold-1000 {
		t.Fatalf("gold %d", now.Gold)
	}
	list, _ := guilds.GPHistory(ctx, g.ID, time.Now())
	if len(list) != 1 || list[0].Kind != guild.GPUseGuildItem || list[0].GP != 20000 || list[0].Name != "Aria" {
		t.Fatalf("history %+v", list)
	}
	_ = refdata.Item{}
}
