package session

import (
	"bufio"
	"context"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/shop"
)

func TestShopBuyRequestRoundTrip(t *testing.T) {
	want := &ShopBuyRequest{CharacterName: "Aria", ItemID: 100, Quantity: 3}
	got, err := DecodeShopBuyRequest(want.Encode())
	if err != nil {
		t.Fatalf("DecodeShopBuyRequest: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestShopBuyResultRoundTrip(t *testing.T) {
	want := &ShopBuyResult{OK: false, Reason: "insufficient gold"}
	got, err := DecodeShopBuyResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodeShopBuyResult: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestShopListResultRoundTrip(t *testing.T) {
	want := &ShopListResult{
		Entries: []ShopCatalogEntry{
			{ItemID: 100, Price: 250, ItemClass: 3, PhysAttackMax: 30.5, PhysDefenseMax: 0},
		},
	}
	got, err := DecodeShopListResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodeShopListResult: %v", err)
	}
	if len(got.Entries) != 1 || got.Entries[0] != want.Entries[0] {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestShopListResultErrorRoundTrip(t *testing.T) {
	want := &ShopListResult{Error: "failed to load catalog"}
	got, err := DecodeShopListResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodeShopListResult: %v", err)
	}
	if got.Error != want.Error || len(got.Entries) != 0 {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

// stubShopItems is a fixed-answer shop.ItemLookup + inventory.MaxStackLookup
// for the end-to-end test below.
type stubShopItems map[int64]*refdata.Item

func (s stubShopItems) GetItem(_ context.Context, id int64) (*refdata.Item, error) {
	item, ok := s[id]
	if !ok {
		return nil, errNoSuchItem
	}
	return item, nil
}

func (s stubShopItems) GetMaxStack(_ context.Context, id int64) (int, error) {
	if _, ok := s[id]; !ok {
		return 0, errNoSuchItem
	}
	return 100, nil
}

func (s stubShopItems) ListAll(_ context.Context) ([]*refdata.Item, error) {
	out := make([]*refdata.Item, 0, len(s))
	for _, item := range s {
		out = append(out, item)
	}
	return out, nil
}

// TestShopFullFlow logs in, creates a character, buys an item, and
// confirms gold was deducted and the item landed in the inventory -- all
// through the real server stack over TCP.
func TestShopFullFlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	if _, err := chars.Create(ctx, 1, "Aria"); err != nil {
		t.Fatalf("creating character: %v", err)
	}

	items := stubShopItems{100: {ID: 100}} // costs shop.basePrice (100 gold)
	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), items)
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer inv.Close()
	if err := inv.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating inventory: %v", err)
	}

	svc := &shop.Service{Gold: chars, Inv: inv, Items: items}
	handle := gateway.Chain(LoginHandler(accounts), ShopHandler(chars, svc))
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

	resp = send(OpShopList, nil)
	listResult, err := DecodeShopListResult(resp.Data)
	if err != nil || listResult.Error != "" {
		t.Fatalf("shop list failed: err=%v result=%+v", err, listResult)
	}
	if len(listResult.Entries) != 1 || listResult.Entries[0].ItemID != 100 || listResult.Entries[0].Price != shop.Price(items[100]) {
		t.Fatalf("got %+v, want a single entry for item 100 at its computed price", listResult.Entries)
	}

	resp = send(OpShopBuy, (&ShopBuyRequest{CharacterName: "Aria", ItemID: 100, Quantity: 2}).Encode())
	buyResult, err := DecodeShopBuyResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeShopBuyResult: %v", err)
	}
	if !buyResult.OK {
		t.Fatalf("buy failed: %+v", buyResult)
	}

	list, err := chars.ListByAccount(ctx, 1)
	if err != nil {
		t.Fatalf("ListByAccount: %v", err)
	}
	wantGold := int64(character.StartingGold) - 200 // 2x basePrice(100)
	if list[0].Gold != wantGold {
		t.Fatalf("got Gold %d, want %d", list[0].Gold, wantGold)
	}

	invList, err := inv.List(ctx, list[0].ID)
	if err != nil {
		t.Fatalf("inv.List: %v", err)
	}
	if len(invList) != 1 || invList[0].ItemID != 100 || invList[0].Quantity != 2 {
		t.Fatalf("got %+v, want a single slot with 2x item 100", invList)
	}
}

type stubItemErr string

func (e stubItemErr) Error() string { return string(e) }

const errNoSuchItem = stubItemErr("no such item")
