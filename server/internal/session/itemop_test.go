package session

import (
	"bufio"
	"bytes"
	"context"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/shop"
	"github.com/OpenSRO/OpenSRO/server/internal/storage"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// The 0x7034 bodies decode as the client's serializer writes them (c:0x7923a0,
// r728_review.md), bag slots + 13.
func TestItemMoveWire(t *testing.T) {
	cases := []struct {
		req  ItemMoveRequest
		wire []byte
	}{
		{ItemMoveRequest{Type: 0, Src: 0, Dst: 2, Count: 250}, []byte{0, 13, 15, 0xfa, 0}},
		{ItemMoveRequest{Type: 9, Src: 1, Count: 20, NPC: 0x01020304}, []byte{9, 14, 20, 0, 4, 3, 2, 1}},
		{ItemMoveRequest{Type: 2, Src: 0, Dst: 5, NPC: 7}, []byte{2, 13, 5, 7, 0, 0, 0}},
	}
	for _, c := range cases {
		if got := encodeItemMove(c.req); !bytes.Equal(got, c.wire) {
			t.Errorf("encode %+v = % x, want % x", c.req, got, c.wire)
		}
		got, err := DecodeItemMove(c.wire)
		if err != nil || *got != c.req {
			t.Errorf("decode % x = %+v, %v; want %+v", c.wire, got, err, c.req)
		}
	}
	if got := EncodeSellResult(1, 20, 7, 0xFF); !bytes.Equal(got, []byte{1, 9, 14, 20, 0, 7, 0, 0, 0, 0xFF}) {
		t.Errorf("sell result % x", got)
	}
	if got := EncodeBuybackResult(1, 0, 20); !bytes.Equal(got, []byte{1, 0x22, 14, 0, 20, 0}) {
		t.Errorf("buy back result % x", got)
	}
	if got := EncodeItemFail(0x180f); !bytes.Equal(got, []byte{2, 0x0f, 0x18}) {
		t.Errorf("fail % x", got)
	}
}

// Round 728 end to end on the retail messages: split, sell (booked), buy back
// into the first empty slot, the deposit fee for the whole stack, and the
// refusals.
func TestItemOpFlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	items := stubShopItems{100: {ID: 100, MaxStack: 5000, SellPrice: 10, CanSell: true, KeepingFee: 11, TypeID1: 3, TypeID2: 3, TypeID3: 1}}
	inv := inventory.NewMemStore(items)
	if err := inv.AddItem(ctx, c.ID, 100, 50); err != nil {
		t.Fatal(err)
	}
	warehouse := inventory.NewMemStore(items)
	warehouse.SetCapacity(storage.DefaultCapacity)
	hub := world.NewHub()
	deps := ItemOpDeps{
		Hub: hub, Inv: inv,
		Shop:    &shop.Service{Gold: chars, Inv: inv, Items: items},
		Storage: &storage.Service{Bag: inv, Warehouse: warehouse, Gold: chars, Accounts: accounts, Items: items},
	}
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, nil, hub), ItemOpHandler(deps))
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)
	send := func(op uint16, data []byte) *proto.Packet {
		t.Helper()
		if err := proto.Write(conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
			t.Fatalf("write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		return resp
	}
	expect := func(what string, p *proto.Packet, op uint16, want []byte) {
		t.Helper()
		if p.Opcode != op || !bytes.Equal(p.Data, want) {
			t.Fatalf("%s: %#04x % x, want %#04x % x", what, p.Opcode, p.Data, op, want)
		}
	}
	bag := func() map[int]int {
		out := map[int]int{}
		list, _ := inv.List(ctx, c.ID)
		for _, s := range list {
			out[s.Index] = s.Quantity
		}
		return out
	}
	gold := func() int64 { ch, _ := chars.GetByID(ctx, c.ID); return ch.Gold }
	g0 := gold()

	if lr, err := DecodeLoginResult(send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login: %+v %v", lr, err)
	}
	if ewr, err := DecodeEnterWorldResult(send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode()).Data); err != nil || !ewr.OK {
		t.Fatalf("enter world: %+v %v", ewr, err)
	}

	// Split 20 of 50 into slot 1; the refusals (gs:0x4b2450).
	expect("split", send(OpItemMove, encodeItemMove(ItemMoveRequest{Type: 0, Src: 0, Dst: 1, Count: 20})), OpItemMoveResult, []byte{1, 0, 13, 14, 20, 0, 0})
	if b := bag(); b[0] != 30 || b[1] != 20 {
		t.Fatalf("after the split: %v", b)
	}
	expect("count 0", send(OpItemMove, encodeItemMove(ItemMoveRequest{Type: 0, Src: 0, Dst: 2, Count: 0})), OpItemMoveResult, EncodeItemFail(ItemErrCountBelowOne))
	expect("past the stack", send(OpItemMove, encodeItemMove(ItemMoveRequest{Type: 0, Src: 0, Dst: 2, Count: 31})), OpItemMoveResult, EncodeItemFail(ItemErrPastStack))

	// Sell slot 1's 20: booked, the book holds 1.
	expect("sell", send(OpItemMove, encodeItemMove(ItemMoveRequest{Type: 9, Src: 1, Count: 20, NPC: 7})), OpItemMoveResult, []byte{1, 9, 14, 20, 0, 7, 0, 0, 0, 1})
	if g := gold() - g0; g != 200 {
		t.Fatalf("the sale paid %d, want 200", g)
	}
	// Buy it back: into the first empty slot (1), 200 gold.
	expect("buy back", send(OpItemBuyback, []byte{7, 0, 0, 0, 0}), OpItemMoveResult, []byte{1, 0x22, 14, 0, 20, 0})
	if b, g := bag(), gold(); b[0] != 30 || b[1] != 20 || g != g0 {
		t.Fatalf("after the buy back: %v, gold %d", b, g)
	}
	expect("nothing to buy back", send(OpItemBuyback, []byte{7, 0, 0, 0, 0}), OpItemBuybackFail, EncodeItemFail(ItemErrNoSuchEntry))

	// Deposit slot 0: the whole 30, 11 x 30 = 330, into warehouse slot 4.
	expect("deposit", send(OpItemMove, encodeItemMove(ItemMoveRequest{Type: 2, Src: 0, Dst: 4, NPC: 7})), OpItemMoveResult, []byte{1, 2, 13, 4})
	if g := g0 - gold(); g != 330 {
		t.Fatalf("the deposit cost %d, want 330", g)
	}
	// Short of the fee: 0x180f, nothing moves.
	if err := chars.DeductGold(ctx, c.ID, gold()-100); err != nil {
		t.Fatal(err)
	}
	expect("short of the fee", send(OpItemMove, encodeItemMove(ItemMoveRequest{Type: 2, Src: 1, Dst: 5, NPC: 7})), OpItemMoveResult, EncodeItemFail(ItemErrNotEnoughGold))
	if b := bag(); b[1] != 20 {
		t.Fatalf("a refused deposit moved the stack: %v", b)
	}
}
