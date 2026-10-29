package session

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"math"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/stall"
	"github.com/TheOpenSRO/OpenSRO/server/internal/trade"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 840, lane N: the stall network (stallnet.go,
// docs/protocol/stall_network.md). Round 839's fixture: Aria (the stall
// owner) with a sword (100) in bag slot 0, Bram with five of item 200; Cara,
// a third player, logs in where a test needs two buyers.

// netTestItems is the exchange's items with the sword made a 2nd-degree
// (ItemClass 4), level-12 item, and item 200 standing in for the event item.
type netTestItems struct{ stubCombatItems }

func (n netTestItems) GetItemByCode(_ context.Context, code string) (*refdata.Item, error) {
	if code == StallNetEventItem {
		return n.stubCombatItems[200], nil
	}
	return nil, errNoSuchItem
}

func newNetTestItems() netTestItems {
	items := exchangeItems()
	sword := *items[100]
	sword.ItemClass, sword.ReqLevel1 = 4, 12
	items[100] = &sword
	return netTestItems{items}
}

type netFixture struct {
	*stallFixture
	t     *testing.T
	town  atomic.Bool
	clock time.Time
	clkMu sync.Mutex
}

func setupNetTest(t *testing.T, wrap func(*inventory.SQLStore) inventory.Store) *netFixture {
	t.Helper()
	nf := &netFixture{t: t, clock: time.Unix(1_000_000, 0)}
	nf.town.Store(true)
	sf := &stallFixture{stalls: stall.NewHub(), sales: stall.NewMemStore()}
	sf.tradeTestFixture = setupTradeTestWrapped(t, func(d tradeFixtureDeps) []gateway.Handler {
		var bag inventory.Store = d.inv
		if wrap != nil {
			bag = wrap(d.inv)
		}
		return []gateway.Handler{
			StallHandler(StallDeps{Chars: d.chars, Inv: bag, Items: newNetTestItems(), Hub: d.hub, Stalls: sf.stalls,
				Trades: d.trades, Sales: sf.sales}),
			StallNetHandler(),
		}
	}, nil)
	nf.stallFixture = sf
	stallNetTown = func(world.Entity) bool { return nf.town.Load() }
	stallNetNow = func() time.Time {
		nf.clkMu.Lock()
		defer nf.clkMu.Unlock()
		return nf.clock
	}
	stallNetRand = func(int) int { return 0 }
	t.Cleanup(func() {
		stallRT.Store(nil)
		stallNetTown, stallNetNow, stallNetRand = nil, time.Now, defaultStallNetRand
		stallNetViewers.mu.Lock()
		stallNetViewers.m = map[uint64]*stallNetViewer{}
		stallNetViewers.mu.Unlock()
	})
	return nf
}

var defaultStallNetRand = stallNetRand

// tick moves the search clock past the 10 s guard.
func (f *netFixture) tick(d time.Duration) {
	f.clkMu.Lock()
	f.clock = f.clock.Add(d)
	f.clkMu.Unlock()
}

// register lists the sword at price (group 7) and opens the stall on the
// network: the answer's u16 is 1.
func (f *netFixture) register(t *testing.T, price uint64) {
	t.Helper()
	f.openStall(t)
	f.listSword(t, price)
	if got := f.update(t, []byte{StallUpdateOpen, 1, 1, 0}); !bytes.Equal(got, []byte{1, 5, 1, 1, 0}) {
		t.Fatalf("type 5 {1, net 1}: % x", got)
	}
}

func (f *netFixture) search(t *testing.T, who string, r StallNetSearch) StallNetResult {
	t.Helper()
	if r.Mode != StallNetModePage {
		f.tick(stallNetSearchGap)
	}
	f.send(t, who, OpStallNetSearch, r.Encode())
	res, err := DecodeStallNetResult(f.next(t, who, OpStallNetSearchResult))
	if err != nil {
		t.Fatalf("0xB461: %v", err)
	}
	return res
}

func (f *netFixture) buy(t *testing.T, who string, b StallNetBuy) []byte {
	t.Helper()
	f.send(t, who, OpStallNetBuy, b.Encode())
	return f.next(t, who, OpStallNetBuyResult)
}

// swordBuy is the 0x7463 for Aria's sword as the search shows it.
func (f *netFixture) swordBuy(t *testing.T) StallNetBuy {
	t.Helper()
	res := f.search(t, "B", StallNetSearch{Mode: StallNetModeEnter, Group: 7})
	if !res.OK || len(res.Records) != 1 {
		t.Fatalf("the sword's search: %+v", res)
	}
	return res.Records[0].Buy()
}

// loginCara logs a third player in beside the other two.
func (f *netFixture) loginCara(t *testing.T) (int64, net.Conn, *bufio.Reader) {
	t.Helper()
	ctx := context.Background()
	cara, err := f.chars.Create(ctx, 3, "Cara")
	if err != nil {
		t.Fatal(err)
	}
	f.accounts.Add("cara", "pw")
	conn := dialTestServer(t, f.addr)
	t.Cleanup(func() { conn.Close() })
	r := bufio.NewReader(conn)
	if lr, err := DecodeLoginResult(doSend(t, conn, r, OpLogin, (&LoginRequest{Username: "cara", Password: "pw"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login %v %+v", err, lr)
	}
	if ewr, err := DecodeEnterWorldResult(doSend(t, conn, r, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Cara"}).Encode()).Data); err != nil || !ewr.OK {
		t.Fatalf("enter %v %+v", err, ewr)
	}
	drainPlayerSpawn(t, conn, r)
	return cara.ID, conn, r
}

func (f *netFixture) session(t *testing.T, id int64) *gateway.Session {
	t.Helper()
	e, ok := f.hub.EntityByCharacterID(id)
	if !ok {
		t.Fatalf("no entity %d", id)
	}
	return e.Session
}

// swords counts item 100 over the characters' bags.
func (f *netFixture) swords(t *testing.T, ids ...int64) int {
	t.Helper()
	n := 0
	for _, id := range ids {
		bag, _ := f.inv.List(context.Background(), id)
		for _, sl := range bag {
			if sl.ItemID == 100 {
				n += sl.Quantity
			}
		}
	}
	return n
}

func TestStallNetCommission(t *testing.T) {
	for _, c := range []struct{ price, fee int64 }{
		{0, 0}, {1, 1}, {99, 1}, {100, 1}, {101, 1}, {199, 1}, {200, 1}, {201, 2}, {1000, 9}, {1001, 10},
		{100_000, 999}, {10_000_000, 99_999}, {10_000_003, 100_000}, {9_999_999_999, 100_000},
	} {
		if got := StallNetCommission(c.price); got != c.fee {
			t.Errorf("commission(%d) = %d, want %d", c.price, got, c.fee)
		}
	}
	// The rate is the float 0.01 widened, not 0.01.
	if stallNetFeeRate != 0.009999999776482582 {
		t.Fatalf("rate %v", stallNetFeeRate)
	}
}

func TestStallNetWireLayouts(t *testing.T) {
	check := func(what string, got, want []byte) {
		t.Helper()
		if !bytes.Equal(got, want) {
			t.Errorf("%s: % x, want % x", what, got, want)
		}
	}
	s := StallNetSearch{Mode: 3, Page: 2, Group: 0x01020304, Degree: 5}
	check("0x7461", s.Encode(), []byte{3, 2, 4, 3, 2, 1, 5})
	if back, ok := DecodeStallNetSearch(s.Encode()); !ok || back != s {
		t.Fatalf("0x7461 round trip %+v", back)
	}
	if _, ok := DecodeStallNetSearch([]byte{1, 0, 0}); ok {
		t.Fatal("a short 0x7461 decoded")
	}
	b := StallNetBuy{Owner: 7, Slot: 3, Price: 500, Count: 2, Level: 9, Serial: 0x1122}
	want := []byte{7, 0, 0, 0, 3}
	want = binary.LittleEndian.AppendUint64(want, 500)
	want = append(want, 2, 0, 9)
	want = binary.LittleEndian.AppendUint64(want, 0x1122)
	check("0x7463", b.Encode(), want)
	if back, ok := DecodeStallNetBuy(b.Encode()); !ok || back != b {
		t.Fatalf("0x7463 round trip %+v", back)
	}
	// 0xB461 with an equipment record and an expendable's, decoded back.
	ctx := context.Background()
	items := newNetTestItems()
	r1 := StallNetRecord{Owner: 5, Seller: "Aria", Slot: 0, Count: 1, Level: 12, Price: 300, Serial: 9}
	r2 := StallNetRecord{Owner: 6, Seller: "Bo", Slot: 4, Count: 5, Level: 0, Price: 20, Serial: 10}
	e1 := appendStallNetTail(exchangeRecord(ctx, items, tradeItem(0, 100, 1)), r1)
	e2 := appendStallNetTail(exchangeRecord(ctx, items, tradeItem(2, 200, 5)), r2)
	out := EncodeStallNetResult(3, [][]byte{e1, e2})
	if out[0] != 1 || out[1] != 2 || out[2] != 3 {
		t.Fatalf("0xB461 head % x", out[:3])
	}
	res, err := DecodeStallNetResult(out)
	if err != nil || !res.OK || res.Pages != 3 || len(res.Records) != 2 {
		t.Fatalf("0xB461 decoded %+v %v", res, err)
	}
	if got := res.Records[0]; got.Item.RefItemID != 100 || got.Buy() != r1.Buy() || got.Seller != "Aria" {
		t.Errorf("record 1 %+v", got)
	}
	if got := res.Records[1]; got.Item.RefItemID != 200 || got.Buy() != r2.Buy() || got.Seller != "Bo" {
		t.Errorf("record 2 %+v", got)
	}
	check("0xB461 refusal", stallResult(StallNetErrUseCity), []byte{2, 0x49, 0x3c})
	if res, _ := DecodeStallNetResult([]byte{2, 0x49, 0x3c}); res.OK || res.Code != StallNetErrUseCity {
		t.Fatalf("decoded refusal %+v", res)
	}
	check("0x30B7 kind 4", EncodeStallNetSold(ctx, items, 3, "Bram", [stall.MaxSlots]stall.Listing{}),
		[]byte{4, 3, 4, 0, 'B', 'r', 'a', 'm', 0xFF})
}

// 0xB0BA's network answers (stall_network.md §4, §5).
func TestStallNetRegistration(t *testing.T) {
	f := setupNetTest(t, nil)
	ctx := context.Background()
	if err := f.inv.AddItem(ctx, f.ariaID, 200, 4); err != nil {
		t.Fatal(err)
	}
	f.openStall(t)
	// Not registered: the edits' net values answer 0.
	if got := f.update(t, addBodyNet(0, 13, 1, 50, 7, StallNetAdd)); got[0] != 1 || binary.LittleEndian.Uint16(got[2:]) != 0 {
		t.Fatalf("an add off the network: % x", got)
	}
	// Outside a town: the stall opens, the network refuses 0x3c4a.
	f.town.Store(false)
	if got := f.update(t, []byte{StallUpdateOpen, 1, 1, 0}); !bytes.Equal(got, []byte{1, 5, 1, 0x4a, 0x3c}) {
		t.Fatalf("a register outside a town: % x", got)
	}
	if s, _ := f.stalls.Get(f.ariaID); !s.Open || s.Network {
		t.Fatalf("after the refusal: open %v network %v", s.Open, s.Network)
	}
	f.town.Store(true)
	f.setOpen(t, 0)
	// In a town: 1, registered.
	if got := f.update(t, []byte{StallUpdateOpen, 1, 1, 0}); !bytes.Equal(got, []byte{1, 5, 1, 1, 0}) {
		t.Fatalf("a register: % x", got)
	}
	// Back to modify while registered: 3, still registered.
	if got := f.update(t, []byte{StallUpdateOpen, 0, 3, 0}); !bytes.Equal(got, []byte{1, 5, 0, 3, 0}) {
		t.Fatalf("modify {0, 3}: % x", got)
	}
	if s, _ := f.stalls.Get(f.ariaID); s.Open || !s.Network {
		t.Fatalf("modifying: open %v network %v", s.Open, s.Network)
	}
	// The edits echo 4 / 2 / 5 while registered.
	price := binary.LittleEndian.AppendUint16([]byte{StallUpdatePrice, 0}, 1)
	price = binary.LittleEndian.AppendUint16(binary.LittleEndian.AppendUint64(price, 70), StallNetPrice)
	if got := f.update(t, price); binary.LittleEndian.Uint16(got[len(got)-2:]) != StallNetPrice {
		t.Fatalf("type 1 net 4: % x", got)
	}
	if got := f.update(t, addBodyNet(1, 14, 4, 5, 7, StallNetAdd)); got[0] != 1 || binary.LittleEndian.Uint16(got[2:]) != StallNetAdd {
		t.Fatalf("type 2 net 2: % x", got)
	}
	if got := f.update(t, []byte{StallUpdateRemove, 1, 5, 0}); got[0] != 1 || binary.LittleEndian.Uint16(got[2:]) != StallNetRemove {
		t.Fatalf("type 3 net 5: % x", got)
	}
	// A wrong value answers 0; the net u16 left out answers 0.
	if got := f.update(t, []byte{StallUpdateRemove, 5, 2, 0}); got[0] != 2 {
		t.Fatalf("an empty slot is still refused: % x", got)
	}
	if got := f.update(t, []byte{StallUpdateOpen, 1}); !bytes.Equal(got, []byte{1, 5, 1, 0, 0}) {
		t.Fatalf("type 5 without its u16: % x", got)
	}
	if s, _ := f.stalls.Get(f.ariaID); s.Network {
		t.Fatal("an open with net 0 kept the registration")
	}
	// Modify with net 0 drops it too.
	f.update(t, []byte{StallUpdateOpen, 0, 0, 0})
	f.update(t, []byte{StallUpdateOpen, 1, 1, 0})
	if got := f.update(t, []byte{StallUpdateOpen, 0, 0, 0}); !bytes.Equal(got, []byte{1, 5, 0, 0, 0}) {
		t.Fatalf("modify {0, 0}: % x", got)
	}
	if s, _ := f.stalls.Get(f.ariaID); s.Network {
		t.Fatal("a modify with net 0 kept the registration")
	}
}

func addBodyNet(slot, wire byte, qty uint16, price uint64, group uint32, net uint16) []byte {
	b := addBody(slot, wire, qty, price, group)
	return binary.LittleEndian.AppendUint16(b[:len(b)-2], net)
}

// The search's filters (group, degree), what it leaves out, and its
// snapshot.
func TestStallNetSearchFilters(t *testing.T) {
	f := setupNetTest(t, nil)
	f.register(t, 300)
	res := f.search(t, "B", StallNetSearch{Mode: StallNetModeEnter, Group: 7})
	if !res.OK || res.Pages != 1 || len(res.Records) != 1 {
		t.Fatalf("group 7: %+v", res)
	}
	r := res.Records[0]
	if r.Owner != uint32(f.ariaID) || r.Seller != "Aria" || r.Slot != 0 || r.Count != 1 || r.Level != 12 ||
		r.Price != 300 || r.Item.RefItemID != 100 || r.Serial == 0 {
		t.Fatalf("the record %+v", r)
	}
	for _, c := range []struct {
		what string
		req  StallNetSearch
		n    int
	}{
		{"another group", StallNetSearch{Mode: 2, Group: 8}, 0},
		{"degree 2", StallNetSearch{Mode: 2, Group: 7, Degree: 2}, 1},
		{"degree 1", StallNetSearch{Mode: 2, Group: 7, Degree: 1}, 0},
	} {
		if res := f.search(t, "B", c.req); !res.OK || len(res.Records) != c.n {
			t.Errorf("%s: %+v", c.what, res)
		}
	}
	// Nothing found: {1, 0, 0}.
	if got := f.search(t, "B", StallNetSearch{Mode: 2, Group: 8}); got.Pages != 0 {
		t.Fatalf("an empty result's pages %d", got.Pages)
	}
	// The owner's own stall is left out.
	if res := f.search(t, "A", StallNetSearch{Mode: 1, Group: 7}); !res.OK || len(res.Records) != 0 {
		t.Fatalf("the owner's own search: %+v", res)
	}
	// Modifying: hidden; open again off the network: hidden.
	f.update(t, []byte{StallUpdateOpen, 0, 3, 0})
	if res := f.search(t, "B", StallNetSearch{Mode: 2, Group: 7}); len(res.Records) != 0 {
		t.Fatalf("a modifying stall found: %+v", res)
	}
	f.update(t, []byte{StallUpdateOpen, 1, 0, 0})
	if res := f.search(t, "B", StallNetSearch{Mode: 2, Group: 7}); len(res.Records) != 0 {
		t.Fatalf("a stall off the network found: %+v", res)
	}
	// Registered again, searched, then the listing goes: the page re-read
	// leaves it out, the page count stays the snapshot's.
	f.update(t, []byte{StallUpdateOpen, 0, 0, 0})
	f.update(t, []byte{StallUpdateOpen, 1, 1, 0})
	if res := f.search(t, "B", StallNetSearch{Mode: 2, Group: 7}); len(res.Records) != 1 {
		t.Fatalf("registered again: %+v", res)
	}
	f.update(t, []byte{StallUpdateOpen, 0, 3, 0})
	f.update(t, []byte{StallUpdateRemove, 0, 5, 0})
	f.update(t, []byte{StallUpdateOpen, 1, 1, 0})
	if res := f.search(t, "B", StallNetSearch{Mode: 3, Page: 0, Group: 7}); !res.OK || res.Pages != 1 || len(res.Records) != 0 {
		t.Fatalf("a page after the listing went: %+v", res)
	}
}

// Fifteen a page, newest first, a page past the end empty, at most 255
// pages. The stalls are put straight into the hub (no sessions needed).
func TestStallNetPaging(t *testing.T) {
	f := setupNetTest(t, nil)
	next := int64(100_000)
	put := func(stalls int) {
		for i := 0; i < stalls; i++ {
			next++
			owner := next
			if _, err := f.stalls.Open(stall.Member{CharacterID: owner, Name: "Bot"}, "s", 0); err != nil {
				t.Fatal(err)
			}
			f.stalls.Do(owner, func(s *stall.Stall) {
				s.Open, s.Network = true, true
				for k := range s.Slots {
					s.Slots[k] = stall.Listing{Used: true, BagSlot: k, ItemID: 200, Quantity: 1, Price: int64(k + 1),
						Group: 9, Seq: f.stalls.NextSeq()}
				}
			})
		}
	}
	put(4) // 40 listings: pages 15, 15, 10
	res := f.search(t, "B", StallNetSearch{Mode: 1, Group: 9})
	if res.Pages != 3 || len(res.Records) != 15 {
		t.Fatalf("page 0: %d pages, %d records", res.Pages, len(res.Records))
	}
	for i := 1; i < len(res.Records); i++ {
		if res.Records[i].Serial >= res.Records[i-1].Serial {
			t.Fatalf("not newest first at %d", i)
		}
	}
	last := f.search(t, "B", StallNetSearch{Mode: 3, Page: 2, Group: 9})
	if last.Pages != 3 || len(last.Records) != 10 {
		t.Fatalf("page 2: %+v", last)
	}
	if past := f.search(t, "B", StallNetSearch{Mode: 3, Page: 3, Group: 9}); !past.OK || past.Pages != 3 || len(past.Records) != 0 {
		t.Fatalf("page 3: %+v", past)
	}
	// Mode 3 is not held by the 10 s guard.
	f.send(t, "B", OpStallNetSearch, StallNetSearch{Mode: 3, Page: 1, Group: 9}.Encode())
	if got := f.next(t, "B", OpStallNetSearchResult); got[0] != 1 || got[1] != 15 {
		t.Fatalf("an early page: % x", got[:3])
	}
	// 4000 listings: capped at 255 pages.
	put(400)
	if res := f.search(t, "B", StallNetSearch{Mode: 2, Group: 9}); res.Pages != StallNetMaxPages {
		t.Fatalf("%d pages, want the cap", res.Pages)
	}
}

// The 10 s guard (0x3c46), the town (0x3c49) and a bad mode (5).
func TestStallNetSearchRefusals(t *testing.T) {
	f := setupNetTest(t, nil)
	f.search(t, "B", StallNetSearch{Mode: 1, Group: 7})
	f.tick(9 * time.Second)
	f.send(t, "B", OpStallNetSearch, StallNetSearch{Mode: 2, Group: 7}.Encode())
	if got := f.next(t, "B", OpStallNetSearchResult); !bytes.Equal(got, stallResult(StallNetErrScanFail)) {
		t.Fatalf("a search 9 s later: % x", got)
	}
	f.tick(time.Second)
	f.send(t, "B", OpStallNetSearch, StallNetSearch{Mode: 2, Group: 7}.Encode())
	if got := f.next(t, "B", OpStallNetSearchResult); got[0] != 1 {
		t.Fatalf("a search 10 s later: % x", got)
	}
	f.town.Store(false)
	f.send(t, "B", OpStallNetSearch, StallNetSearch{Mode: 3, Group: 7}.Encode())
	if got := f.next(t, "B", OpStallNetSearchResult); !bytes.Equal(got, stallResult(StallNetErrUseCity)) {
		t.Fatalf("outside a town: % x", got)
	}
	f.town.Store(true)
	for _, bad := range [][]byte{{0, 0, 7, 0, 0, 0, 0}, {4, 0, 7, 0, 0, 0, 0}, {1, 0}} {
		f.send(t, "B", OpStallNetSearch, bad)
		if got := f.next(t, "B", OpStallNetSearchResult); !bytes.Equal(got, stallResult(StallErrOperation)) {
			t.Errorf("% x: % x", bad, got)
		}
	}
	// 0x7462 leaves, the disconnect forgets.
	f.send(t, "B", OpStallNetLeave, nil)
	if got := f.next(t, "B", OpStallNetLeaveResult); !bytes.Equal(got, []byte{1}) {
		t.Fatalf("0xB462 % x", got)
	}
	f.search(t, "B", StallNetSearch{Mode: 1, Group: 7})
	StallNetDisconnectHandler()(f.session(t, f.bramID))
	stallNetViewers.mu.Lock()
	n := len(stallNetViewers.m)
	stallNetViewers.mu.Unlock()
	if n != 0 {
		t.Fatalf("%d viewers after the disconnect", n)
	}
}

// The remote sale: the sword to Bram's first free slot, the price from him,
// the price less the commission to Aria, the sale row, 0xB463 {1} and
// 0x30B7 kind 4 to the stall.
func TestStallNetBuy(t *testing.T) {
	f := setupNetTest(t, nil)
	ctx := context.Background()
	f.register(t, 1000)
	b := f.swordBuy(t)
	f.send(t, "B", OpStallNetBuy, b.Encode())
	f.next(t, "B", OpCharInfoGold())
	if got := f.next(t, "B", OpStallNetBuyResult); !bytes.Equal(got, []byte{1}) {
		t.Fatalf("0xB463 % x", got)
	}
	if ev := f.next(t, "A", OpStallEvent); !bytes.Equal(ev, []byte{4, 0, 4, 0, 'B', 'r', 'a', 'm', 0xFF}) {
		t.Fatalf("0x30B7 kind 4 % x", ev)
	}
	if a, bg := f.gold(t, f.ariaID), f.gold(t, f.bramID); a != character.StartingGold+1000-9 || bg != character.StartingGold-1000 {
		t.Fatalf("gold: Aria %d, Bram %d", a, bg)
	}
	bl, _ := f.inv.List(ctx, f.bramID)
	found := false
	for _, sl := range bl {
		if sl.ItemID == 100 && sl.Index == 1 {
			found = true
		}
	}
	if !found || f.swords(t, f.ariaID) != 0 {
		t.Fatalf("Bram's bag %+v", bl)
	}
	sales, _ := f.sales.Sales(ctx, f.ariaID, 0)
	if len(sales) != 1 || !sales[0].Network || sales[0].Commission != 9 || sales[0].Price != 1000 || sales[0].BuyerID != f.bramID {
		t.Fatalf("sale rows %+v", sales)
	}
	if s, _ := f.stalls.Get(f.ariaID); s.Slots[0].Used || s.Selling {
		t.Fatalf("the slot after the sale %+v, selling %v", s.Slots[0], s.Selling)
	}
	// The same record again: the stall's slot is empty now.
	if got := f.buy(t, "B", b); !bytes.Equal(got, stallResult(StallNetErrChanged)) {
		t.Fatalf("a second buy: % x", got)
	}
}

// Every refusal, and nothing moves.
func TestStallNetBuyRefusals(t *testing.T) {
	f := setupNetTest(t, nil)
	ctx := context.Background()
	// No stall: 0x3c4f; Aria naming herself (no stall of her own): 5.
	none := StallNetBuy{Owner: uint32(f.ariaID), Count: 1}
	if got := f.buy(t, "B", none); !bytes.Equal(got, stallResult(StallNetErrGone)) {
		t.Fatalf("no stall: % x", got)
	}
	if got := f.buy(t, "A", none); !bytes.Equal(got, stallResult(StallErrOperation)) {
		t.Fatalf("her own: % x", got)
	}
	f.register(t, character.StartingGold+1)
	b := f.swordBuy(t)
	cases := []struct {
		what string
		req  StallNetBuy
		want uint16
	}{
		{"an empty slot", func() StallNetBuy { r := b; r.Slot = 4; return r }(), StallNetErrChanged},
		{"slot 10", func() StallNetBuy { r := b; r.Slot = 10; return r }(), StallNetErrChanged},
		{"another serial", func() StallNetBuy { r := b; r.Serial++; return r }(), StallNetErrChanged},
		{"another count", func() StallNetBuy { r := b; r.Count = 2; return r }(), StallNetErrChanged},
		{"another price", func() StallNetBuy { r := b; r.Price--; return r }(), StallNetErrPrice},
		{"too little gold", b, StallNetErrGold},
		{"a short request", StallNetBuy{}, StallErrOperation},
	}
	for _, c := range cases {
		data := c.req.Encode()
		if c.what == "a short request" {
			data = data[:10]
		}
		f.send(t, "B", OpStallNetBuy, data)
		if got := f.next(t, "B", OpStallNetBuyResult); !bytes.Equal(got, stallResult(c.want)) {
			t.Errorf("%s: % x, want %#x", c.what, got, c.want)
		}
	}
	// Outside a town: 0x3c49.
	f.town.Store(false)
	if got := f.buy(t, "B", b); !bytes.Equal(got, stallResult(StallNetErrUseCity)) {
		t.Fatalf("outside a town: % x", got)
	}
	f.town.Store(true)
	// A sale running: 2.
	f.stalls.Do(f.ariaID, func(s *stall.Stall) { s.Selling = true })
	if got := f.buy(t, "B", b); !bytes.Equal(got, stallResult(StallErrGeneric)) {
		t.Fatalf("a sale running: % x", got)
	}
	f.stalls.Do(f.ariaID, func(s *stall.Stall) { s.Selling = false })
	// A full bag: 0x3c53.
	_ = f.chars.AddGold(ctx, f.bramID, 10)
	for i := 1; i < inventory.PlacementCapacityOf(ctx, f.inv, f.bramID); i++ {
		if err := f.inv.PlaceItemInstance(ctx, f.bramID, i, 100, 1, inventory.Instance{}); err != nil {
			t.Fatalf("filling Bram's bag at %d: %v", i, err)
		}
	}
	if got := f.buy(t, "B", b); !bytes.Equal(got, stallResult(StallNetErrBagFull)) {
		t.Fatalf("a full bag: % x", got)
	}
	if f.swords(t, f.ariaID) != 1 || f.gold(t, f.ariaID) != character.StartingGold {
		t.Fatal("a refused buy moved something")
	}
	// Bram inside a stall (Aria's, as a visitor): 0x3c16.
	f.enter(t)
	if got := f.buy(t, "B", b); !bytes.Equal(got, stallResult(StallErrBusy)) {
		t.Fatalf("a visitor's remote buy: % x", got)
	}
	f.send(t, "B", OpStallLeave, nil)
	f.next(t, "B", OpStallLeaveResult)
	// Modifying: 0x3c4f; off the network: 0x3c4f.
	f.update(t, []byte{StallUpdateOpen, 0, 3, 0})
	if got := f.buy(t, "B", b); !bytes.Equal(got, stallResult(StallNetErrGone)) {
		t.Fatalf("a modifying stall: % x", got)
	}
	f.update(t, []byte{StallUpdateOpen, 1, 0, 0})
	if got := f.buy(t, "B", b); !bytes.Equal(got, stallResult(StallNetErrGone)) {
		t.Fatalf("off the network: % x", got)
	}
}

// Two remote buyers at once: one sale, the other refused, the totals kept.
func TestStallNetRaceTwoBuyers(t *testing.T) {
	f := setupNetTest(t, nil)
	ctx := context.Background()
	f.register(t, 100)
	b := f.swordBuy(t)
	caraID, connC, rC := f.loginCara(t)
	d := stallRT.Load()
	sB, sC := f.session(t, f.bramID), f.session(t, caraID)
	var wg sync.WaitGroup
	for _, s := range []*gateway.Session{sB, sC} {
		wg.Add(1)
		go func(s *gateway.Session) { defer wg.Done(); d.netBuy(ctx, s, b.Encode()) }(s)
	}
	wg.Wait()
	answers := [][]byte{f.next(t, "B", OpStallNetBuyResult), nextOp(t, connC, rC, OpStallNetBuyResult).Data}
	ok := 0
	for _, a := range answers {
		switch {
		case bytes.Equal(a, []byte{1}):
			ok++
		case bytes.Equal(a, stallResult(StallErrGeneric)), bytes.Equal(a, stallResult(StallNetErrChanged)):
		default:
			t.Errorf("the loser's answer % x", a)
		}
	}
	if ok != 1 {
		t.Fatalf("%d sales of one listing: % x", ok, answers)
	}
	gold := f.gold(t, f.ariaID) + f.gold(t, f.bramID) + f.gold(t, caraID)
	if n := f.swords(t, f.ariaID, f.bramID, caraID); n != 1 || gold != 3*character.StartingGold-1 {
		t.Fatalf("after the race: %d swords, %d gold (want %d, the commission gone)", n, gold, 3*character.StartingGold-1)
	}
}

// A remote buyer against a visitor at the stall: one sale.
func TestStallNetRaceRemoteVsVisitor(t *testing.T) {
	f := setupNetTest(t, nil)
	ctx := context.Background()
	f.register(t, 100)
	caraID, connC, rC := f.loginCara(t)
	// Cara searches, Bram walks in.
	f.tick(stallNetSearchGap)
	if err := writePacket(connC, OpStallNetSearch, StallNetSearch{Mode: 1, Group: 7}.Encode()); err != nil {
		t.Fatal(err)
	}
	res, err := DecodeStallNetResult(nextOp(t, connC, rC, OpStallNetSearchResult).Data)
	if err != nil || len(res.Records) != 1 {
		t.Fatalf("Cara's search %+v %v", res, err)
	}
	f.enter(t)
	d := stallRT.Load()
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); d.buy(ctx, f.session(t, f.bramID), []byte{0}) }()
	go func() { defer wg.Done(); d.netBuy(ctx, f.session(t, caraID), res.Records[0].Buy().Encode()) }()
	wg.Wait()
	visitor := f.next(t, "B", OpStallBuyResult)
	remote := nextOp(t, connC, rC, OpStallNetBuyResult).Data
	sold := 0
	if visitor[0] == 1 {
		sold++
	}
	if bytes.Equal(remote, []byte{1}) {
		sold++
	}
	if sold != 1 {
		t.Fatalf("visitor % x, remote % x", visitor, remote)
	}
	gold := f.gold(t, f.ariaID) + f.gold(t, f.bramID) + f.gold(t, caraID)
	want := int64(3 * character.StartingGold)
	if bytes.Equal(remote, []byte{1}) {
		want-- // the commission
	}
	if n := f.swords(t, f.ariaID, f.bramID, caraID); n != 1 || gold != want {
		t.Fatalf("after the race: %d swords, %d gold, want %d", n, gold, want)
	}
}

// The owner closing the stall in the middle of a remote sale: the sale
// completes, the owner still hears of it, nothing is lost.
func TestStallNetOwnerClosesMidBuy(t *testing.T) {
	var lp *leavingPlace
	f := setupNetTest(t, func(s *inventory.SQLStore) inventory.Store {
		lp = &leavingPlace{SQLStore: s}
		return lp
	})
	lp.owner = f.ariaID
	f.register(t, 500)
	b := f.swordBuy(t)
	if got := f.buy(t, "B", b); !bytes.Equal(got, []byte{1}) {
		t.Fatalf("0xB463 % x", got)
	}
	if got := f.next(t, "A", OpStallGone); !bytes.Equal(got, EncodeStallGone(uint32(f.ariaID), StallErrHostLeft)) {
		t.Fatalf("0x30B9 % x", got)
	}
	if ev := f.next(t, "A", OpStallEvent); ev[0] != StallEventNetSold {
		t.Fatalf("the owner's 0x30B7 % x", ev)
	}
	if f.swords(t, f.bramID) != 1 || f.swords(t, f.ariaID) != 0 || f.gold(t, f.ariaID) != character.StartingGold+500-StallNetCommission(500) {
		t.Fatal("the sale did not complete")
	}
	if f.stalls.Mode(f.ariaID) != 0 {
		t.Fatal("the stall outlived its owner")
	}
}

// The owner's gold would overflow: 2, nothing moves.
func TestStallNetOwnerGoldOverflow(t *testing.T) {
	f := setupNetTest(t, nil)
	ctx := context.Background()
	_ = f.chars.AddGold(ctx, f.ariaID, math.MaxInt64-character.StartingGold-10)
	f.register(t, 1000)
	if got := f.buy(t, "B", f.swordBuy(t)); !bytes.Equal(got, stallResult(StallErrGeneric)) {
		t.Fatalf("an overflowing sale: % x", got)
	}
	if f.swords(t, f.ariaID) != 1 || f.gold(t, f.bramID) != character.StartingGold {
		t.Fatal("the refused sale moved something")
	}
	if s, _ := f.stalls.Get(f.ariaID); s.Selling || !s.Slots[0].Used {
		t.Fatalf("the stall after the refusal %+v", s.Slots[0])
	}
}

// A failed transaction: 0x3c48, the stall closed 0x3c48, nothing moved; a
// lost commit's answer: the sale stands.
func TestStallNetFailedAndLostCommit(t *testing.T) {
	f := setupNetTest(t, func(s *inventory.SQLStore) inventory.Store { return failingPlace{s} })
	ctx := context.Background()
	f.register(t, 30)
	if got := f.buy(t, "B", f.swordBuy(t)); !bytes.Equal(got, stallResult(StallNetErrJobDB)) {
		t.Fatalf("0xB463 % x", got)
	}
	if got := f.next(t, "A", OpStallGone); !bytes.Equal(got, EncodeStallGone(uint32(f.ariaID), StallNetErrJobDB)) {
		t.Fatalf("0x30B9 % x", got)
	}
	if f.swords(t, f.ariaID) != 1 || f.gold(t, f.ariaID) != character.StartingGold || f.gold(t, f.bramID) != character.StartingGold {
		t.Fatal("a failed sale moved something")
	}
	if s, _ := f.sales.Sales(ctx, f.ariaID, 0); len(s) != 0 {
		t.Fatalf("a failed sale left its row: %+v", s)
	}

	g := setupNetTest(t, nil)
	g.register(t, 30)
	b := g.swordBuy(t)
	restore := txn.SetAfterCommitHookForTest(func(context.Context) error {
		return errors.New("injected: the commit's answer was lost")
	})
	defer restore()
	if got := g.buy(t, "B", b); !bytes.Equal(got, []byte{1}) {
		t.Fatalf("a lost commit's 0xB463 % x", got)
	}
	restore()
	if g.swords(t, g.bramID) != 1 {
		t.Fatal("the lost commit's sword is not Bram's")
	}
}

// The event item: a price of 100,000 or more, each side on its roll.
func TestStallNetEventItem(t *testing.T) {
	f := setupNetTest(t, nil)
	ctx := context.Background()
	count := func(id int64) int {
		bag, _ := f.inv.List(ctx, id)
		n := 0
		for _, sl := range bag {
			if sl.ItemID == 200 {
				n += sl.Quantity
			}
		}
		return n
	}
	_ = f.chars.AddGold(ctx, f.bramID, 200_000)
	f.register(t, 99_999)
	stallNetRand = func(int) int { return 1 }
	if got := f.buy(t, "B", f.swordBuy(t)); !bytes.Equal(got, []byte{1}) {
		t.Fatalf("0xB463 % x", got)
	}
	if count(f.ariaID) != 0 || count(f.bramID) != 5 {
		t.Fatal("an event item below 100,000")
	}
	// The sword back to Aria, listed at 100,000.
	if err := f.inv.AddItem(ctx, f.ariaID, 100, 1); err != nil {
		t.Fatal(err)
	}
	f.update(t, []byte{StallUpdateOpen, 0, 3, 0})
	bag, _ := f.inv.List(ctx, f.ariaID)
	if got := f.update(t, addBodyNet(0, byte(bag[0].Index+13), 1, 100_000, 7, StallNetAdd)); got[0] != 1 {
		t.Fatalf("relisting: % x", got)
	}
	f.update(t, []byte{StallUpdateOpen, 1, 1, 0})
	if got := f.buy(t, "B", f.swordBuy(t)); !bytes.Equal(got, []byte{1}) {
		t.Fatalf("0xB463 % x", got)
	}
	f.next(t, "B", OpInventoryListResult)
	if count(f.ariaID) != 1 || count(f.bramID) != 6 {
		t.Fatalf("event items: Aria %d, Bram %d", count(f.ariaID), count(f.bramID))
	}
	sales, _ := f.sales.Sales(ctx, f.ariaID, 1)
	if len(sales) != 1 || sales[0].Commission != StallNetCommission(100_000) {
		t.Fatalf("the sale row %+v", sales)
	}
}

func writePacket(c net.Conn, op uint16, data []byte) error {
	return proto.Write(c, &proto.Packet{Opcode: op, Data: data}, nil, nil)
}

func tradeItem(slot int, id int64, qty int) trade.Item {
	return trade.Item{Slot: slot, ItemID: id, Quantity: qty}
}
