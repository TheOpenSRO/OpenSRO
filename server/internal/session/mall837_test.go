package session

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"net"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gm"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mall"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 837: the item mall through the session handlers, on real connections
// (mall.go): the balances, the GM's /silk, a purchase into the bag with
// 0x3153 before its 0xB034, the refusals, the chest when the bag is short,
// take one, take all, the take log, the silk history and 0x7121. Every table
// is synthetic (internal/mall's tests' layout), never a real archive's rows.

const mallGroup = 901

// mallTestItems are the exchange fixture's items 200 (a 3/3 expendable) and
// 100 (a 3/1 sword) as the mall's catalogue knows them.
func mallTestCatalogue() *mall.Catalogue {
	items := map[string]mall.Item{
		"ITEM_T_POTION": {ID: 200, Code: "ITEM_T_POTION", TypeID: [4]int{3, 3, 1, 1}, MaxStack: 100},
		"ITEM_T_SWORD":  {ID: 100, Code: "ITEM_T_SWORD", TypeID: [4]int{3, 1, 6, 1}, MaxStack: 1},
	}
	r := func(cols ...string) []string { return cols }
	pad := func(c []string) []string { return append(c, "-1", "xxx", "-1", "xxx", "-1", "xxx", "-1", "xxx") }
	scrap := func(pkg, item, data string) []string {
		c := r("1", "15", pkg, item, "0", "0", data, "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0")
		return append(pad(c), "1")
	}
	price := func(pkg, dev, cost string) []string { return pad(r("1", "15", pkg, dev, "0", cost)) }
	pkg := func(id, code string) []string {
		return pad(r("1", "15", id, code, "0", mall.ExpandTermAll, "SN", "SN_TT_DESC", "icon"))
	}
	return mall.Build(mall.Tables{
		ShopGroup: [][]string{pad(r("1", "15", "901", "GROUP_T", "xxx"))},
		MapGroup:  [][]string{r("1", "15", "GROUP_T", "SHOP_T")},
		MapTab:    [][]string{r("1", "15", "SHOP_T", "SHOP_T_G1")},
		Tab:       [][]string{r("1", "15", "1", "TAB_T", "SHOP_T_G1", "K")},
		Goods: [][]string{pad(r("1", "15", "TAB_T", "PKG_POTION", "0")), pad(r("1", "15", "TAB_T", "PKG_SWORD", "1")),
			pad(r("1", "15", "TAB_T", "PKG_DEAR", "2"))},
		Package: [][]string{pkg("7001", "PKG_POTION"), pkg("7002", "PKG_SWORD"), pkg("7003", "PKG_DEAR")},
		Scrap: [][]string{scrap("PKG_POTION", "ITEM_T_POTION", "0"), scrap("PKG_SWORD", "ITEM_T_SWORD", "0"),
			scrap("PKG_DEAR", "ITEM_T_POTION", "0")},
		Price: [][]string{price("PKG_POTION", "2", "3"), price("PKG_POTION", "4", "3"),
			price("PKG_SWORD", "2", "100"), price("PKG_SWORD", "4", "100"), price("PKG_DEAR", "2", "5000")},
	}, func(code string) (mall.Item, bool) { it, ok := items[code]; return it, ok })
}

type mallFixture struct {
	*tradeTestFixture
	store *mall.MemStore
}

// setupMall is the exchange's two-player fixture with the mall's handler and
// the GM console (alice a GM). The silk store is wired in after the world
// entries, so the fixture's own reads see no 0x3153 (TestMallBalancesAtEntry
// has that).
func setupMall(t *testing.T) *mallFixture {
	t.Helper()
	store := mall.NewMemStore()
	f := setupTradeTestWith(t, func(d tradeFixtureDeps) []gateway.Handler {
		return []gateway.Handler{
			MallHandler(MallDeps{Catalogue: mallTestCatalogue(), Store: store, Chars: d.chars, Inv: d.inv,
				Items: exchangeItems(), Hub: d.hub, Trades: d.trades}),
			GMCommandHandler(d.chars, gm.ParseAccounts("alice"), &gm.Deps{Silk: d.accounts}, d.hub, nil),
		}
	})
	t.Cleanup(func() { mallRT.Store(nil) })
	mallRT.Load().Silk = f.accounts
	return &mallFixture{tradeTestFixture: f, store: store}
}

func (f *mallFixture) buy(t *testing.T, slot uint8, code string, qty uint16) {
	t.Helper()
	f.send(t, "A", OpItemMove, mall.EncodeBuy(mall.BuyRequest{Group: mallGroup, Slot: slot, Code: code, Quantity: qty}))
}

func (f *mallFixture) silk(t *testing.T) mall.Balances {
	t.Helper()
	b := f.next(t, "A", mall.OpSilk)
	return mall.Balances{Own: int64(binary.LittleEndian.Uint32(b)), Gift: int64(binary.LittleEndian.Uint32(b[4:])),
		Point: int64(binary.LittleEndian.Uint32(b[8:]))}
}

func (f *mallFixture) gm(t *testing.T, line string) {
	t.Helper()
	f.send(t, "A", OpGMCommand, (&GMCommandRequest{Name: "Aria", Line: line}).Encode())
	if r, err := DecodeGMCommandResult(f.next(t, "A", OpGMCommandResult)); err != nil || r.Refused {
		t.Fatalf("%s: %+v %v", line, r, err)
	}
}

func (f *mallFixture) bag(t *testing.T) map[int]inventory.Slot {
	t.Helper()
	slots, err := f.inv.List(context.Background(), f.ariaID)
	if err != nil {
		t.Fatal(err)
	}
	out := map[int]inventory.Slot{}
	for _, s := range slots {
		out[s.Index] = s
	}
	return out
}

func TestMallPurchaseFlow(t *testing.T) {
	f := setupMall(t)
	// The GM's /silk: 0x3154 {reason 2, cash type, offset}, then 0x3153.
	f.gm(t, "/silk 100 gift")
	if got := f.next(t, "A", mall.OpSilkChange); !bytes.Equal(got, mall.EncodeSilkChange(2, 1, 100)) {
		t.Fatalf("0x3154 % x", got)
	}
	if b := f.silk(t); b != (mall.Balances{Gift: 100}) {
		t.Fatalf("after /silk 100 gift %+v", b)
	}
	f.gm(t, "/silk 1000")
	f.next(t, "A", mall.OpSilkChange)
	f.silk(t)

	// 30 potions (one row, 3/3, Data 0): one stack of 30 in the first empty
	// slot (Aria's sword holds 0), 90 silk, gift first. 0x3153, then 0xB034.
	f.buy(t, 0, "PKG_POTION", 30)
	if b := f.silk(t); b != (mall.Balances{Own: 1000, Gift: 10}) {
		t.Fatalf("0x3153 after the buy %+v", b)
	}
	req := mall.BuyRequest{Group: mallGroup, Slot: 0, Code: "PKG_POTION", Quantity: 30}
	if got := f.next(t, "A", OpItemMoveResult); !bytes.Equal(got, mall.EncodeBuyOK(req, []int{1})) {
		t.Fatalf("0xB034 % x", got)
	}
	if s := f.bag(t)[1]; s.ItemID != 200 || s.Quantity != 30 {
		t.Fatalf("bag slot 1 %+v", s)
	}

	// The refusals: the code name, the silk, the tab, the quantity.
	for _, tc := range []struct {
		r    mall.BuyRequest
		code uint16
	}{
		{mall.BuyRequest{Group: mallGroup, Slot: 0, Code: "PKG_SWORD", Quantity: 1}, mall.CodeCodeName},
		{mall.BuyRequest{Group: mallGroup, Slot: 2, Code: "PKG_DEAR", Quantity: 1}, mall.CodeNoSilk},
		{mall.BuyRequest{Group: mallGroup, Tab: 1, Code: "PKG_POTION", Quantity: 1}, mall.CodeNoTab},
		{mall.BuyRequest{Group: mallGroup, Slot: 0, Code: "PKG_POTION", Quantity: 0}, mall.CodeFail},
		{mall.BuyRequest{Group: 5, Code: "PKG_POTION", Quantity: 1}, mall.CodeFail},
	} {
		f.send(t, "A", OpItemMove, mall.EncodeBuy(tc.r))
		if got := f.next(t, "A", OpItemMoveResult); !bytes.Equal(got, mall.EncodeBuyFail(tc.code)) {
			t.Fatalf("%+v: % x, want code %#x", tc.r, got, tc.code)
		}
	}
	if b, _ := f.accounts.Silk(context.Background(), 1); b != (account.Silk{Own: 1000, Gift: 10}) {
		t.Fatalf("a refusal took silk: %+v", b)
	}

	// The bag short: three slots, two held, two swords wanted -> the chest.
	f.inv.SetCapacityFunc(func(context.Context, int64) int { return 3 })
	f.buy(t, 1, "PKG_SWORD", 2)
	if b := f.silk(t); b != (mall.Balances{Own: 810, Gift: 0}) {
		t.Fatalf("0x3153 after the chest buy %+v", b)
	}
	req = mall.BuyRequest{Group: mallGroup, Slot: 1, Code: "PKG_SWORD", Quantity: 2}
	if got := f.next(t, "A", OpItemMoveResult); !bytes.Equal(got, mall.EncodeBuyOK(req, nil)) {
		t.Fatalf("0xB034 to the chest % x", got)
	}
	for i := 0; i < 2; i++ {
		if got := f.next(t, "A", mall.OpChestReceived); !bytes.Equal(got, mall.EncodeChestReceived(100, 1)) {
			t.Fatalf("0x00D6 % x", got)
		}
	}
	if len(f.bag(t)) != 2 {
		t.Fatal("the chest buy put something in the bag")
	}
	f.send(t, "A", mall.OpChestList, nil)
	list := f.next(t, "A", mall.OpChestListResult)
	if binary.LittleEndian.Uint16(list) != 2 {
		t.Fatalf("0x00D1 % x", list)
	}
	first := binary.LittleEndian.Uint32(list[2:])

	// Take one: {1, 1}, a fresh list of one, the sword in slot 2.
	f.send(t, "A", mall.OpChestTake, binary.LittleEndian.AppendUint32(nil, first))
	if got := f.next(t, "A", mall.OpChestTakeResult); !bytes.Equal(got, mall.EncodeChestTaken(1)) {
		t.Fatalf("take one % x", got)
	}
	if got := f.next(t, "A", mall.OpChestListResult); binary.LittleEndian.Uint16(got) != 1 {
		t.Fatalf("the list after the take % x", got)
	}
	if s := f.bag(t)[2]; s.ItemID != 100 || s.Quantity != 1 {
		t.Fatalf("bag slot 2 %+v", s)
	}
	// The same entry again: 0x1809.
	f.send(t, "A", mall.OpChestTake, binary.LittleEndian.AppendUint32(nil, first))
	if got := f.next(t, "A", mall.OpChestTakeResult); !bytes.Equal(got, mall.EncodeChestTakeFail(mall.CodeNoGood)) {
		t.Fatalf("taken twice % x", got)
	}
	// Take all with the bag full: 0x1807, nothing moves.
	f.send(t, "A", mall.OpChestTake, binary.LittleEndian.AppendUint32(nil, mall.TakeAll))
	if got := f.next(t, "A", mall.OpChestTakeResult); !bytes.Equal(got, mall.EncodeChestTakeFail(mall.CodeBagFull)) {
		t.Fatalf("take all into a full bag % x", got)
	}
	f.inv.SetCapacityFunc(func(context.Context, int64) int { return 6 })
	f.send(t, "A", mall.OpChestTake, binary.LittleEndian.AppendUint32(nil, mall.TakeAll))
	if got := f.next(t, "A", mall.OpChestTakeResult); !bytes.Equal(got, mall.EncodeChestTaken(1)) {
		t.Fatalf("take all % x", got)
	}
	if got := f.next(t, "A", mall.OpChestListResult); !bytes.Equal(got, []byte{0, 0}) {
		t.Fatalf("the emptied chest % x", got)
	}
	f.send(t, "A", mall.OpChestLog, nil)
	if got := f.next(t, "A", mall.OpChestLogResult); binary.LittleEndian.Uint16(got) != 2 {
		t.Fatalf("0x00D5 % x", got)
	}

	// The silk history: kind 1 lists both purchases, kind 2 nothing, a
	// cancel no reply.
	f.send(t, "A", mall.OpHistory, []byte{1, 1})
	h := f.next(t, "A", mall.OpHistoryResult)
	if len(h) != 3+2+16 || h[2] != 0 || binary.LittleEndian.Uint16(h[3:]) != 2 ||
		binary.LittleEndian.Uint32(h[5:]) != 90 || binary.LittleEndian.Uint32(h[13:]) != 200 {
		t.Fatalf("0xB11A % x", h)
	}
	f.send(t, "A", mall.OpHistory, []byte{2, 3})
	if got := f.next(t, "A", mall.OpHistoryResult); !bytes.Equal(got, []byte{2, 3, 0, 0, 0}) {
		t.Fatalf("the obtained list % x", got)
	}
	f.send(t, "A", mall.OpHistory, []byte{1, mall.HistoryCancel})
	f.none(t, "A", mall.OpHistoryResult)

	// 0x7121: {1, key, 0 rows}.
	f.send(t, "A", mall.OpOpen, u16(mallGroup))
	if got := f.next(t, "A", mall.OpOpenResult); !bytes.Equal(got, mall.EncodeOpen(mallGroup)) {
		t.Fatalf("0xB121 % x", got)
	}
	if rows, _ := f.store.Purchases(context.Background(), 1, time.Now().Add(-time.Hour)); len(rows) != 2 || rows[0].Offset != 90 || rows[1].Offset != 200 {
		t.Fatalf("the purchase log %+v", rows)
	}
}

// TestMallBlockedInExchange: an established exchange is INTERACTMODE 2,
// which StorageOperation refuses 0x1834 for op 0x18.
func TestMallBlockedInExchange(t *testing.T) {
	f := setupMall(t)
	startTrade(t, f.tradeTestFixture)
	f.buy(t, 0, "PKG_POTION", 1)
	if got := f.next(t, "A", OpItemMoveResult); !bytes.Equal(got, mall.EncodeBuyFail(mall.CodeBlocked)) {
		t.Fatalf("% x", got)
	}
}

// TestMallBalancesAtEntry: the world entry sends the account's balances.
func TestMallBalancesAtEntry(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	a, _ := accounts.Add("carol", "pw")
	accounts.AddSilk(ctx, a.ID, account.SilkPoint, 77)
	chars := character.NewMemStore()
	chars.Create(ctx, a.ID, "Cara")
	hub := world.NewHub()
	addr, cleanup := startTestServer(t, gateway.Chain(LoginHandler(accounts), WorldHandler(chars, nil, hub),
		MallHandler(MallDeps{Silk: accounts, Hub: hub})))
	t.Cleanup(cleanup)
	t.Cleanup(func() { mallRT.Store(nil) })
	c := dialTestServer(t, addr)
	t.Cleanup(func() { c.Close() })
	r := bufio.NewReader(c)
	enterWorldAs(t, c, r, "carol", "pw", "Cara")
	if got := nextOp(t, c, r, mall.OpSilk).Data; !bytes.Equal(got, mall.EncodeBalances(mall.Balances{Point: 77})) {
		t.Fatalf("0x3153 % x", got)
	}
}

func enterWorldAs(t *testing.T, c net.Conn, r *bufio.Reader, user, pass, name string) {
	t.Helper()
	if lr, err := DecodeLoginResult(doSend(t, c, r, OpLogin, (&LoginRequest{Username: user, Password: pass}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}
	if ewr, err := DecodeEnterWorldResult(doSend(t, c, r, OpEnterWorld, (&EnterWorldRequest{CharacterName: name}).Encode()).Data); err != nil || !ewr.OK {
		t.Fatalf("enter world: %v %+v", err, ewr)
	}
}
