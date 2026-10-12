package session

import (
	"bufio"
	"bytes"
	"context"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/OpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/shop"
	"github.com/OpenSRO/OpenSRO/server/internal/testnpc"
	"github.com/OpenSRO/OpenSRO/server/internal/trade"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// The Test Items NPC end to end over a real socket (round 783): the select
// sends its shop definition (OpNpcShopDef) and then the 0xB045 reply offering
// the store alone; the store opens; its goods list at 0 and a character with
// no gold buys one of each kind (an alchemy stone, a Seal of Nova weapon, a
// Seal of Nova armour piece) and keeps 0 gold. A retail NPC's select sends no
// definition, and the same goods bought with no Test Items store open, or at
// a retail store, keep their own price.
func TestTestItemsNPCSelectOpenBuyFree(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	chars := character.NewMemStore()
	accounts.Add("Aria", "pw")
	if _, err := chars.Create(ctx, 1, "Aria"); err != nil {
		t.Fatal(err)
	}
	// Synthetic items (OURS fixture): a Seal of Nova sword and helm, the
	// sword's look-alike switch variant, and an 11th degree magic stone.
	const sword, swordSwitch, stone, helm = 901, 902, 903, 904
	refs := refdata.NewMemStore()
	if err := refs.ImportItems(ctx, []refdata.Item{
		{ID: sword, CodeName: "ITEM_CH_SWORD_11_A_RARE", TypeID1: 3, TypeID2: 1, TypeID3: 6, TypeID4: 2, ItemClass: 31, MaxStack: 1, Price: 250000, SellPrice: 250000},
		{ID: swordSwitch, CodeName: "ITEM_CH_SWORD_11_A_RARE_SWITCH01", TypeID1: 3, TypeID2: 1, TypeID3: 6, TypeID4: 2, ItemClass: 31, MaxStack: 1, Price: 250000},
		{ID: stone, CodeName: "ITEM_ETC_ARCHEMY_MAGICSTONE_STR_11", TypeID1: 3, TypeID2: 3, TypeID3: 11, TypeID4: 1, MaxStack: 500, Price: 432095, SellPrice: 1000},
		{ID: helm, CodeName: "ITEM_CH_M_HEAVY_11_HA_A_RARE", TypeID1: 3, TypeID2: 1, TypeID3: 3, TypeID4: 1, ItemClass: 31, MaxStack: 1, Price: 250000, SellPrice: 250000},
	}); err != nil {
		t.Fatal(err)
	}
	all, _ := refs.ListAll(ctx)
	def, err := testnpc.Builtin()
	if err != nil {
		t.Fatal(err)
	}
	shopDef := def.Resolve(all)
	if !shopDef.Free {
		t.Fatal("the builtin definition is not free")
	}
	if got := shopDef.Lines[2].Tabs[0].ItemIDs; len(got) != 1 || got[0] != sword {
		t.Fatalf("CH weapons %v, want [%d]", got, sword)
	}

	hub := world.NewHub()
	retail := npcAt(5, 100, 0, npcspawn.FromNest)
	retail.Code, retail.Shop = "NPC_CH_POTION", true
	retail.Flags, retail.Interact = npcspawn.FlagInteractions, []byte{1}
	test := def.NPC(26823, npcspawn.UIDBase+6)
	test.X, test.Z = 960+120, 960 // beside the retail one, in the test frame
	installNPCsForTest(t, retail, test)
	InstallNPCShopDefs(map[uint32]NPCShopDef{test.UID: {Payload: shopDef.Encode(test.UID), Goods: shopDef.Goods(), Free: shopDef.Free}})
	t.Cleanup(func() { InstallNPCShopDefs(nil); ForgetNPCInteraction(1) })

	inv := inventory.NewMemStore(refs)
	svc := &shop.Service{Gold: chars, Inv: inv, Items: refs}
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, nil, hub), NPCTalkHandler(hub, trade.NewHub()),
		ShopHandler(chars, svc, nil))
	srv := &gateway.Server{Addr: freeAddr(t), Handle: handle}
	sctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go srv.ListenAndServe(sctx)
	conn := dialTestServer(t, srv.Addr)
	t.Cleanup(func() { conn.Close() })
	c := &chatClient{t: t, conn: conn, r: bufio.NewReader(conn)}
	c.send(OpLogin, (&LoginRequest{Username: "Aria", Password: "pw"}).Encode())
	if lr, err := DecodeLoginResult(c.next(OpLoginResult).Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}
	c.send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if er, err := DecodeEnterWorldResult(c.next(OpEnterWorldResult).Data); err != nil || !er.OK {
		t.Fatalf("enter: %v %+v", err, er)
	}
	e, ok := hub.FindByName("Aria")
	if !ok {
		t.Fatal("Aria not in the world")
	}
	if e.Zone != "jangan" {
		t.Skipf("the test NPCs stand in the jangan frame; the world put Aria in %q", e.Zone)
	}
	hub.Relocate(e.Session, world.Position{X: 50, Z: 0}, world.MoveRelocate, 0)
	// No gold at all.
	if ch, _ := chars.GetByID(ctx, e.CharacterID); ch.Gold > 0 {
		if err := chars.DeductGold(ctx, e.CharacterID, ch.Gold); err != nil {
			t.Fatal(err)
		}
	}
	gold := func() int64 {
		ch, err := chars.GetByID(ctx, e.CharacterID)
		if err != nil {
			t.Fatal(err)
		}
		return ch.Gold
	}
	list := func(id int64) int64 {
		t.Helper()
		c.send(OpShopList, (&ShopListRequest{ItemIDs: []int64{id}}).Encode())
		lr, err := DecodeShopListResult(c.next(OpShopListResult).Data)
		if err != nil || len(lr.Entries) != 1 {
			t.Fatalf("list %d: %+v %v", id, lr, err)
		}
		return lr.Entries[0].Price
	}
	buy := func(id int64) *ShopBuyResult {
		t.Helper()
		c.send(OpShopBuy, (&ShopBuyRequest{CharacterName: "Aria", ItemID: id, Quantity: 1}).Encode())
		br, err := DecodeShopBuyResult(c.next(OpShopBuyResult).Data)
		if err != nil {
			t.Fatal(err)
		}
		return br
	}

	// Before any store: the sword lists at its own price and a buy with no
	// gold is refused.
	if p := list(sword); p != 250000 {
		t.Fatalf("sword with no store open lists at %d, want its own 250,000", p)
	}
	if br := buy(sword); br.OK || br.Reason != "insufficient gold" {
		t.Fatalf("sword with no store open and no gold: %+v", br)
	}

	// The retail NPC: no definition, straight to its reply; its store keeps
	// the sword's price.
	c.send(npctalk.OpSelect, npctalk.EncodeEntity(retail.UID))
	c.next(npctalk.OpSelectResult)
	c.none(testnpc.OpNpcShopDef)
	c.send(npctalk.OpOpen, npctalk.EncodeOpen(retail.UID, 1))
	c.next(npctalk.OpOpenResult)
	if p := list(sword); p != 250000 {
		t.Fatalf("sword at a retail store lists at %d", p)
	}
	c.send(npctalk.OpEnd, npctalk.EncodeEntity(retail.UID))
	c.next(npctalk.OpEndResult)

	// The Test Items NPC: the definition, then the reply offering {1}.
	c.send(npctalk.OpSelect, npctalk.EncodeEntity(test.UID))
	uid, got, err := testnpc.Decode(c.next(testnpc.OpNpcShopDef).Data)
	if err != nil || uid != test.UID || len(got.Lines) != 8 || got.Lines[2].Tabs[0].Label != "SN_TAB_WEAPON" ||
		len(got.Lines[2].Tabs[0].ItemIDs) != 1 || got.Lines[2].Tabs[0].ItemIDs[0] != sword {
		t.Fatalf("shop def: uid %d %+v %v", uid, got, err)
	}
	sel, err := npctalk.DecodeSelectNPC(c.next(npctalk.OpSelectResult).Data)
	if err != nil || sel.Entity != test.UID || !bytes.Equal(sel.IDs, []byte{1}) {
		t.Fatalf("select: %+v %v", sel, err)
	}
	c.send(npctalk.OpOpen, npctalk.EncodeOpen(test.UID, 1))
	if got := c.next(npctalk.OpOpenResult).Data; !bytes.Equal(got, []byte{1, 1}) {
		t.Fatalf("open the store: % x", got)
	}

	// Its goods list at 0; the switch variant is not one of them.
	for _, id := range []int64{sword, stone, helm} {
		if p := list(id); p != 0 {
			t.Fatalf("good %d lists at %d at the Test Items store, want 0", id, p)
		}
	}
	if p := list(swordSwitch); p != 250000 {
		t.Fatalf("a non-good lists at %d", p)
	}
	// One of each kind, with 0 gold: each lands, the purse stays 0.
	for _, id := range []int64{stone, sword, helm} {
		if br := buy(id); !br.OK {
			t.Fatalf("free buy of %d: %+v", id, br)
		}
		if g := gold(); g != 0 {
			t.Fatalf("gold %d after buying %d, want 0", g, id)
		}
	}
	if br := buy(swordSwitch); br.OK {
		t.Fatal("a non-good was bought free at the Test Items store")
	}
	slots, err := inv.List(ctx, e.CharacterID)
	if err != nil {
		t.Fatal(err)
	}
	have := map[int64]int{}
	for _, s := range slots {
		have[s.ItemID] += s.Quantity
	}
	if have[stone] != 1 || have[sword] != 1 || have[helm] != 1 || have[swordSwitch] != 0 {
		t.Fatalf("bag %v, want one stone, one sword, one helm", have)
	}

	// The store closed: the goods are priced again.
	c.send(npctalk.OpEnd, npctalk.EncodeEntity(test.UID))
	c.next(npctalk.OpEndResult)
	if p := list(sword); p != 250000 {
		t.Fatalf("sword after the Test Items store closed lists at %d", p)
	}
	if br := buy(sword); br.OK {
		t.Fatal("a buy after the Test Items store closed was free")
	}
}
