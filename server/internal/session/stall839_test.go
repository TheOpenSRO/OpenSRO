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
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/stall"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 839, lane S: the players' stalls (stall.go, docs/protocol/stall.md).
// The fixture is the exchange's: Aria with a sword (100) in bag slot 0, Bram
// with five of item 200, both in view of each other at the same spot.

type stallFixture struct {
	*tradeTestFixture
	stalls *stall.Hub
	sales  *stall.MemStore
}

func setupStallTest(t *testing.T) *stallFixture {
	t.Helper()
	return setupStallTestWrapped(t, nil)
}

func setupStallTestWrapped(t *testing.T, wrap func(*inventory.SQLStore) inventory.Store) *stallFixture {
	t.Helper()
	sf := &stallFixture{stalls: stall.NewHub(), sales: stall.NewMemStore()}
	sf.tradeTestFixture = setupTradeTestWrapped(t, func(d tradeFixtureDeps) []gateway.Handler {
		var bag inventory.Store = d.inv
		if wrap != nil {
			bag = wrap(d.inv)
		}
		return []gateway.Handler{
			StallHandler(StallDeps{Chars: d.chars, Inv: bag, Items: exchangeItems(), Hub: d.hub, Stalls: sf.stalls,
				Trades: d.trades, Sales: sf.sales}),
			ChatHandler(ChatDeps{Hub: d.hub}),
		}
	}, nil)
	t.Cleanup(func() { stallRT.Store(nil) })
	return sf
}

func stallStr(s string) []byte { return stallAppendString(nil, s) }

// openStall has Aria open "Aria's stall": 0xB0B1 {1} to her, 0x30B8 to
// both.
func (f *stallFixture) openStall(t *testing.T) {
	t.Helper()
	f.send(t, "A", OpStallOpen, stallStr("Aria's stall"))
	want := EncodeStallAppear(uint32(f.ariaID), "Aria's stall", 0)
	for _, who := range []string{"A", "B"} {
		if got := f.next(t, who, OpStallAppear); !bytes.Equal(got, want) {
			t.Fatalf("%s's 0x30B8 % x, want % x", who, got, want)
		}
	}
	if got := f.next(t, "A", OpStallOpenResult); !bytes.Equal(got, []byte{1}) {
		t.Fatalf("0xB0B1 % x", got)
	}
}

// addBody is 0x70BA type 2's body.
func addBody(slot, wire byte, qty uint16, price uint64, group uint32) []byte {
	out := []byte{StallUpdateAdd, slot, wire}
	out = binary.LittleEndian.AppendUint16(out, qty)
	out = binary.LittleEndian.AppendUint64(out, price)
	out = binary.LittleEndian.AppendUint32(out, group)
	return binary.LittleEndian.AppendUint16(out, 0)
}

func (f *stallFixture) update(t *testing.T, body []byte) []byte {
	t.Helper()
	f.send(t, "A", OpStallUpdate, body)
	return f.next(t, "A", OpStallUpdateResult)
}

func (f *stallFixture) listSword(t *testing.T, price uint64) {
	t.Helper()
	if got := f.update(t, addBody(0, 13, 1, price, 7)); got[0] != 1 || got[1] != StallUpdateAdd {
		t.Fatalf("listing the sword: % x", got)
	}
}

func (f *stallFixture) enter(t *testing.T) []byte {
	t.Helper()
	f.send(t, "B", OpStallEnter, binary.LittleEndian.AppendUint32(nil, uint32(f.ariaID)))
	return f.next(t, "B", OpStallEnterResult)
}

func (f *stallFixture) setOpen(t *testing.T, open byte) {
	t.Helper()
	got := f.update(t, []byte{StallUpdateOpen, open, 0, 0})
	if !bytes.Equal(got, []byte{1, StallUpdateOpen, open, 0, 0}) {
		t.Fatalf("type 5 % x", got)
	}
}

func TestStallWireLayouts(t *testing.T) {
	check := func(what string, got, want []byte) {
		t.Helper()
		if !bytes.Equal(got, want) {
			t.Errorf("%s: % x, want % x", what, got, want)
		}
	}
	check("0x30B8", EncodeStallAppear(5, "ab", 3847), []byte{5, 0, 0, 0, 2, 0, 'a', 'b', 0x07, 0x0f, 0, 0})
	check("0x30B9", EncodeStallGone(5, StallErrClosedByHost), []byte{5, 0, 0, 0, 0x17, 0x3c})
	check("0x30BB", EncodeStallRenamed(5, "x"), []byte{5, 0, 0, 0, 1, 0, 'x'})
	check("0x30B7 kind 2", EncodeStallMember(StallEventCame, 9), []byte{2, 9, 0, 0, 0})
	check("{2, code}", stallResult(StallErrNotOwner), []byte{2, 0x2a, 0x3c})
	var slots [stall.MaxSlots]stall.Listing
	slots[3] = stall.Listing{Used: true, BagSlot: 2, ItemID: 200, Quantity: 5, Price: 1234}
	list := appendStallList(context.Background(), exchangeItems(), nil, slots)
	rec := AppendItemRecord(nil, ItemInfo{RefItemID: 200, Tail: u16(5)})
	want := append([]byte{3}, rec...)
	want = append(want, 15, 5, 0)
	want = binary.LittleEndian.AppendUint64(want, 1234)
	want = append(want, 0xFF)
	check("the list", list, want)
	check("an empty list", appendStallList(context.Background(), exchangeItems(), nil, [stall.MaxSlots]stall.Listing{}), []byte{0xFF})
	s := stall.Stall{Owner: stall.Member{CharacterID: 5}, Welcome: "hi", Open: true, Value4: 2,
		Visitors: []stall.Member{{CharacterID: 7}, {CharacterID: 8}}}
	got := EncodeStallEntered(context.Background(), exchangeItems(), s, 8)
	check("0xB0B3", got, []byte{1, 5, 0, 0, 0, 2, 0, 'h', 'i', 1, 2, 0xFF, 1, 7, 0, 0, 0})
	sold := EncodeStallSold(context.Background(), exchangeItems(), 3, "Bram", [stall.MaxSlots]stall.Listing{})
	check("0x30B7 kind 3", sold, []byte{3, 3, 4, 0, 'B', 'r', 'a', 'm', 0xFF})
}

// The whole flow: open, greeting, list, a visitor, open for business, the
// sale moving the sword and the gold, the close.
func TestStallFullFlow(t *testing.T) {
	f := setupStallTest(t)
	ctx := context.Background()
	f.openStall(t)
	if m := f.stalls.Mode(f.ariaID); m != stall.ModeOwner {
		t.Fatalf("Aria's mode %d", m)
	}
	if got := f.update(t, append([]byte{StallUpdateWelcome}, stallStr("Welcome")...)); !bytes.Equal(got, append([]byte{1, 6}, stallStr("Welcome")...)) {
		t.Fatalf("type 6 % x", got)
	}
	f.listSword(t, 50)
	got := f.enter(t)
	if got[0] != 1 || binary.LittleEndian.Uint32(got[1:]) != uint32(f.ariaID) {
		t.Fatalf("0xB0B3 % x", got)
	}
	if !bytes.Contains(got, stallStr("Welcome")) {
		t.Fatalf("0xB0B3 without the greeting: % x", got)
	}
	if ev := f.next(t, "A", OpStallEvent); !bytes.Equal(ev, EncodeStallMember(StallEventCame, uint32(f.bramID))) {
		t.Fatalf("Aria's 0x30B7 % x", ev)
	}
	if m := f.stalls.Mode(f.bramID); m != stall.ModeVisitor {
		t.Fatalf("Bram's mode %d", m)
	}
	// Not open yet: 0x3c2e.
	f.send(t, "B", OpStallBuy, []byte{0})
	if got := f.next(t, "B", OpStallBuyResult); !bytes.Equal(got, stallResult(StallErrNotOpen)) {
		t.Fatalf("a buy before the open: % x", got)
	}
	f.setOpen(t, 1)
	if got := f.next(t, "B", OpStallUpdateResult); !bytes.Equal(got, []byte{1, 5, 1, 0, 0}) {
		t.Fatalf("Bram's copy of type 5: % x", got)
	}
	// Open: listing is refused 0x3c2b.
	if got := f.update(t, addBody(1, 14, 1, 1, 7)); !bytes.Equal(got, stallResult(StallErrHostState)) {
		t.Fatalf("an add while open: % x", got)
	}
	f.send(t, "B", OpStallBuy, []byte{0})
	f.next(t, "B", OpCharInfoGold())
	if got := f.next(t, "B", OpStallBuyResult); !bytes.Equal(got, []byte{1, 0}) {
		t.Fatalf("0xB0B4 % x", got)
	}
	for _, who := range []string{"A", "B"} {
		ev := f.next(t, who, OpStallEvent)
		if !bytes.Equal(ev, []byte{3, 0, 4, 0, 'B', 'r', 'a', 'm', 0xFF}) {
			t.Fatalf("%s's 0x30B7 kind 3 % x", who, ev)
		}
	}
	if a, b := f.gold(t, f.ariaID), f.gold(t, f.bramID); a != character.StartingGold+50 || b != character.StartingGold-50 {
		t.Fatalf("gold: Aria %d, Bram %d", a, b)
	}
	al, _ := f.inv.List(ctx, f.ariaID)
	bl, _ := f.inv.List(ctx, f.bramID)
	if len(al) != 0 || len(bl) != 2 {
		t.Fatalf("bags: Aria %+v, Bram %+v", al, bl)
	}
	for _, sl := range bl {
		if sl.ItemID == 100 && sl.Index != 1 {
			t.Fatalf("the sword went to slot %d, want the first empty, 1", sl.Index)
		}
	}
	sales, _ := f.sales.Sales(ctx, f.ariaID, 0)
	if len(sales) != 1 || sales[0].BuyerID != f.bramID || sales[0].ItemID != 100 || sales[0].Price != 50 || sales[0].ToSlot != 1 {
		t.Fatalf("sale rows %+v", sales)
	}
	// The visitor leaves: 0x30B7 {1} to Aria, 0xB0B5 {1}.
	f.send(t, "B", OpStallLeave, nil)
	if got := f.next(t, "B", OpStallLeaveResult); !bytes.Equal(got, []byte{1}) {
		t.Fatalf("0xB0B5 % x", got)
	}
	if ev := f.next(t, "A", OpStallEvent); !bytes.Equal(ev, EncodeStallMember(StallEventLeft, uint32(f.bramID))) {
		t.Fatalf("0x30B7 kind 1 % x", ev)
	}
	// The close: 0x30B9 {owner, 0x3c17} to the view, then 0xB0B2 {1}.
	f.send(t, "A", OpStallClose, nil)
	for _, who := range []string{"A", "B"} {
		if got := f.next(t, who, OpStallGone); !bytes.Equal(got, EncodeStallGone(uint32(f.ariaID), StallErrClosedByHost)) {
			t.Fatalf("%s's 0x30B9 % x", who, got)
		}
	}
	if got := f.next(t, "A", OpStallCloseResult); !bytes.Equal(got, []byte{1}) {
		t.Fatalf("0xB0B2 % x", got)
	}
	if f.stalls.Mode(f.ariaID) != 0 || f.trades.Busy(f.ariaID) {
		t.Fatal("Aria still busy after the close")
	}
}

// 0x70B1's refusals in their order.
func TestStallOpenRefusals(t *testing.T) {
	f := setupStallTest(t)
	open := func(name string) []byte {
		f.send(t, "A", OpStallOpen, stallStr(name))
		return f.next(t, "A", OpStallOpenResult)
	}
	if got := open(""); !bytes.Equal(got, stallResult(StallErrName)) {
		t.Fatalf("an empty name: % x", got)
	}
	long := string(bytes.Repeat([]byte{'x'}, stall.MaxText+1))
	if got := open(long); !bytes.Equal(got, stallResult(StallErrName)) {
		t.Fatalf("a 65-byte name: % x", got)
	}
	if got := open(string(bytes.Repeat([]byte{'x'}, stall.MaxText))); !bytes.Equal(got, []byte{1}) {
		t.Fatalf("a 64-byte name: % x", got)
	}
	// Already in a stall: the world check, 0x3c16.
	if got := open("again"); !bytes.Equal(got, stallResult(StallErrBusy)) {
		t.Fatalf("a second open: % x", got)
	}
	f.send(t, "A", OpStallClose, nil)
	f.next(t, "A", OpStallCloseResult)
	// In an exchange (INTERACTMODE 1): 0x3c16.
	requestTrade(t, f.tradeTestFixture)
	if got := open("busy"); !bytes.Equal(got, stallResult(StallErrBusy)) {
		t.Fatalf("an open with an exchange pending: % x", got)
	}
	f.send(t, "A", OpExchangeCancel, nil)
	f.next(t, "A", OpExchangeCancelResult)
	// Dead: 0x3c16.
	f.hub.SetLifeState(f.ariaID, world.LifeAlive, world.LifeDead, time.Now())
	if got := open("dead"); !bytes.Equal(got, stallResult(StallErrBusy)) {
		t.Fatalf("an open while dead: % x", got)
	}
	f.hub.SetLifeState(f.ariaID, world.LifeDead, world.LifeAlive, time.Now())
	// The close of a stall Aria does not own: 0x3c2a.
	f.send(t, "B", OpStallClose, nil)
	if got := f.next(t, "B", OpStallCloseResult); !bytes.Equal(got, stallResult(StallErrNotOwner)) {
		t.Fatalf("a non-owner's close: % x", got)
	}
}

// 0x70BA's rules, type by type.
func TestStallUpdateRules(t *testing.T) {
	f := setupStallTest(t)
	ctx := context.Background()
	for _, id := range []int64{300, 400} {
		if err := f.inv.AddItem(ctx, f.ariaID, id, 1); err != nil {
			t.Fatal(err)
		}
	}
	if err := f.inv.AddItem(ctx, f.ariaID, 200, 4); err != nil {
		t.Fatal(err)
	}
	// Bram, not an owner: 0x3c2a.
	f.send(t, "B", OpStallUpdate, []byte{StallUpdateOpen, 1, 0, 0})
	if got := f.next(t, "B", OpStallUpdateResult); !bytes.Equal(got, stallResult(StallErrNotOwner)) {
		t.Fatalf("a non-owner's update: % x", got)
	}
	f.openStall(t)
	cases := []struct {
		what string
		body []byte
		want uint16
	}{
		{"slot 10", addBody(10, 13, 1, 1, 7), StallErrSlot},
		{"a worn slot", addBody(0, 12, 1, 1, 7), StallErrBagSlot},
		{"an empty bag slot", addBody(0, 40, 1, 1, 7), StallErrBagSlot},
		{"not tradable", addBody(0, 14, 1, 1, 7), StallErrCannotTrade},
		{"a trade good", addBody(0, 15, 1, 1, 7), StallErrCannotTrade},
		{"part of a stack", addBody(0, 16, 3, 1, 7), StallErrCount},
		{"past the price bound", addBody(0, 16, 4, uint64(stall.MaxPrice)+1, 7), StallErrPrice},
		{"no group", addBody(0, 16, 4, 1, 0), StallErrNoGroup},
		{"type 0", []byte{0}, StallErrOperation},
		{"type 8", []byte{8}, StallErrOperation},
		{"type 4 value 3", []byte{StallUpdateValue4, 3}, StallErrHostState},
		{"type 5 value 2", []byte{StallUpdateOpen, 2, 0, 0}, StallErrOpenValue},
		{"type 6 past 64", append([]byte{StallUpdateWelcome}, stallStr(string(bytes.Repeat([]byte{'w'}, 65)))...), StallErrWelcome},
		{"type 7 empty", append([]byte{StallUpdateRename}, stallStr("")...), StallErrName},
		{"type 1 empty slot", []byte{StallUpdatePrice, 3, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0}, StallErrSlot},
		{"type 3 empty slot", []byte{StallUpdateRemove, 3, 0, 0}, StallErrSlot},
	}
	for _, c := range cases {
		if got := f.update(t, c.body); !bytes.Equal(got, stallResult(c.want)) {
			t.Errorf("%s: % x, want %#x", c.what, got, c.want)
		}
	}
	// A price of 0 and the bound itself are accepted (s:0x4719c0).
	f.listSword(t, 0)
	if got := f.update(t, addBody(0, 16, 4, uint64(stall.MaxPrice), 7)); got[0] != 1 {
		t.Fatalf("the bound price: % x", got)
	}
	s, _ := f.stalls.Get(f.ariaID)
	if !s.Slots[1].Used || s.Slots[1].BagSlot != 3 {
		t.Fatalf("an occupied slot 0 takes the first free one: %+v", s.Slots[:2])
	}
	// The same bag slot twice: 0x3c13.
	if got := f.update(t, addBody(5, 13, 1, 1, 7)); !bytes.Equal(got, stallResult(StallErrListed)) {
		t.Fatalf("listed twice: % x", got)
	}
	// Type 1: the count must be the stack's (0x3c07), the price within bound.
	price := func(slot byte, qty uint16, p uint64) []byte {
		out := binary.LittleEndian.AppendUint16([]byte{StallUpdatePrice, slot}, qty)
		return binary.LittleEndian.AppendUint16(binary.LittleEndian.AppendUint64(out, p), 0)
	}
	if got := f.update(t, price(1, 3, 10)); !bytes.Equal(got, stallResult(StallErrCount)) {
		t.Fatalf("type 1 wrong count: % x", got)
	}
	if got := f.update(t, price(1, 4, uint64(stall.MaxPrice)+1)); !bytes.Equal(got, stallResult(StallErrPrice)) {
		t.Fatalf("type 1 past the bound: % x", got)
	}
	if got := f.update(t, price(1, 4, 99)); !bytes.Equal(got, append([]byte{1}, price(1, 4, 99)...)) {
		t.Fatalf("type 1: % x", got)
	}
	// Type 3 clears, type 4 keeps its byte, type 7 renames to the view.
	if got := f.update(t, []byte{StallUpdateRemove, 1, 0, 0}); got[0] != 1 || got[1] != StallUpdateRemove {
		t.Fatalf("type 3: % x", got)
	}
	if got := f.update(t, []byte{StallUpdateValue4, 2}); !bytes.Equal(got, []byte{1, 4, 2}) {
		t.Fatalf("type 4: % x", got)
	}
	f.send(t, "A", OpStallUpdate, append([]byte{StallUpdateRename}, stallStr("New name")...))
	if got := f.next(t, "A", OpStallUpdateResult); !bytes.Equal(got, []byte{1, 7}) {
		t.Fatalf("type 7: % x", got)
	}
	if got := f.next(t, "B", OpStallRenamed); !bytes.Equal(got, EncodeStallRenamed(uint32(f.ariaID), "New name")) {
		t.Fatalf("0x30BB % x", got)
	}
	// Ten slots, then 0x3c30.
	for i := 0; i < 10; i++ {
		if err := f.inv.PlaceItemInstance(ctx, f.ariaID, 10+i, 100, 1, inventory.Instance{}); err != nil {
			t.Fatalf("a sword more: %v", err)
		}
	}
	bag, _ := f.inv.List(ctx, f.ariaID)
	n := 1
	for _, sl := range bag {
		if sl.ItemID == 100 && sl.Index != 0 {
			if n < stall.MaxSlots {
				if got := f.update(t, addBody(byte(n), byte(sl.Index+13), 1, 5, 7)); got[0] != 1 {
					t.Fatalf("slot %d: % x", n, got)
				}
			} else if got := f.update(t, addBody(0, byte(sl.Index+13), 1, 5, 7)); !bytes.Equal(got, stallResult(StallErrNoFreeSlot)) {
				t.Fatalf("an eleventh item: % x", got)
			}
			n++
		}
	}
	if n <= stall.MaxSlots {
		t.Fatalf("only %d items listed", n)
	}
}

// 0x70B3's and 0x70B4's refusals.
func TestStallVisitAndBuyRefusals(t *testing.T) {
	f := setupStallTest(t)
	ctx := context.Background()
	// Not a stall: 0x3c2a; a monster's uid: 3; nobody: 0.
	if got := f.enter(t); !bytes.Equal(got, stallResult(StallErrNotOwner)) {
		t.Fatalf("entering a non-stall: % x", got)
	}
	f.send(t, "B", OpStallEnter, binary.LittleEndian.AppendUint32(nil, 0x7f000001))
	if got := f.next(t, "B", OpStallEnterResult); !bytes.Equal(got, stallResult(StallErrInvalidTarget)) {
		t.Fatalf("a monster's uid: % x", got)
	}
	f.send(t, "B", OpStallEnter, binary.LittleEndian.AppendUint32(nil, 999999))
	if got := f.next(t, "B", OpStallEnterResult); !bytes.Equal(got, []byte{2, 0, 0}) {
		t.Fatalf("nobody: % x", got)
	}
	// Buying outside a stall: 0x3c0f.
	f.send(t, "B", OpStallBuy, []byte{0})
	if got := f.next(t, "B", OpStallBuyResult); !bytes.Equal(got, stallResult(StallErrNotVisitor)) {
		t.Fatalf("a buy outside: % x", got)
	}
	f.openStall(t)
	f.listSword(t, character.StartingGold+1)
	// The owner buying: 0x3c0f.
	f.send(t, "A", OpStallBuy, []byte{0})
	if got := f.next(t, "A", OpStallBuyResult); !bytes.Equal(got, stallResult(StallErrNotVisitor)) {
		t.Fatalf("the owner's buy: % x", got)
	}
	// Too far: 4 (the 100-unit bound, s:0x5163c1).
	e, _ := f.hub.EntityByCharacterID(f.bramID)
	far := e.Pos
	far.X += StallEnterRange + 1
	f.hub.Relocate(e.Session, far, world.MoveRelocate, 0)
	if got := f.enter(t); !bytes.Equal(got, stallResult(StallErrTooFar)) {
		t.Fatalf("101 away: % x", got)
	}
	f.hub.Relocate(e.Session, e.Pos, world.MoveRelocate, 0)
	f.enter(t)
	// Inside already: the world check 0x3c16.
	if got := f.enter(t); !bytes.Equal(got, stallResult(StallErrBusy)) {
		t.Fatalf("entering twice: % x", got)
	}
	f.setOpen(t, 1)
	// Not enough gold: 0x3c11; an empty slot: 0x3c10; slot 10: 0x3c10.
	for _, c := range []struct {
		slot byte
		want uint16
	}{{0, StallErrGold}, {4, StallErrSlot}, {10, StallErrSlot}} {
		f.send(t, "B", OpStallBuy, []byte{c.slot})
		if got := f.next(t, "B", OpStallBuyResult); !bytes.Equal(got, stallResult(c.want)) {
			t.Errorf("slot %d: % x, want %#x", c.slot, got, c.want)
		}
	}
	// A full bag: 0x3c12. Bram's bag is held to his one stack.
	_ = f.chars.AddGold(ctx, f.bramID, 10)
	for i := 1; i < inventory.PlacementCapacityOf(ctx, f.inv, f.bramID); i++ {
		if err := f.inv.PlaceItemInstance(ctx, f.bramID, i, 100, 1, inventory.Instance{}); err != nil {
			t.Fatalf("filling Bram's bag at %d: %v", i, err)
		}
	}
	f.send(t, "B", OpStallBuy, []byte{0})
	if got := f.next(t, "B", OpStallBuyResult); !bytes.Equal(got, stallResult(StallErrBagFull)) {
		t.Fatalf("a full bag: % x", got)
	}
	al, _ := f.inv.List(ctx, f.ariaID)
	if len(al) != 1 || f.gold(t, f.ariaID) != character.StartingGold {
		t.Fatalf("a refused sale moved something: %+v, %d", al, f.gold(t, f.ariaID))
	}
	// Moving the item out of the bag meanwhile is refused: the bag is locked
	// at INTERACTMODE 4 (StorageOperation 0x1834).
	if !f.trades.Established(f.ariaID) || !f.trades.Established(f.bramID) || !f.trades.Busy(f.ariaID) {
		t.Fatal("the stall's modes do not reach the trade hub's gates")
	}
}

// A seller whose gold would overflow is refused 2 (OURS) and nothing moves.
func TestStallSellerGoldOverflow(t *testing.T) {
	f := setupStallTest(t)
	ctx := context.Background()
	_ = f.chars.AddGold(ctx, f.ariaID, math.MaxInt64-character.StartingGold-10)
	f.openStall(t)
	f.listSword(t, 100)
	f.enter(t)
	f.setOpen(t, 1)
	f.send(t, "B", OpStallBuy, []byte{0})
	if got := f.next(t, "B", OpStallBuyResult); !bytes.Equal(got, stallResult(StallErrGeneric)) {
		t.Fatalf("an overflowing sale: % x", got)
	}
	bl, _ := f.inv.List(ctx, f.bramID)
	if len(bl) != 1 || f.gold(t, f.bramID) != character.StartingGold {
		t.Fatalf("the refused sale moved something: %+v", bl)
	}
}

// Two buyers racing for one listing: one sale, never two -- at the hub
// (the second sees the sale pending) and in the stores (two sells of one
// listing move the item once).
func TestStallSaleRaceSellsOnce(t *testing.T) {
	f := setupStallTest(t)
	ctx := context.Background()
	cara, _ := f.chars.Create(ctx, 3, "Cara")
	f.openStall(t)
	f.listSword(t, 10)
	d := stallRT.Load()
	s, _ := f.stalls.Get(f.ariaID)
	l := s.Slots[0]
	var wg sync.WaitGroup
	codes := make([]uint16, 2)
	for i, buyer := range []int64{f.bramID, cara.ID} {
		wg.Add(1)
		go func(i int, buyer int64) {
			defer wg.Done()
			codes[i], _ = d.sell(ctx, f.ariaID, buyer, 0, l)
		}(i, buyer)
	}
	wg.Wait()
	ok := 0
	for _, c := range codes {
		if c == 1 {
			ok++
		} else if c != StallErrSlot {
			t.Errorf("the loser's code %#x, want 0x3c10", c)
		}
	}
	if ok != 1 {
		t.Fatalf("%d sales of one listing (codes %v)", ok, codes)
	}
	total := 0
	for _, id := range []int64{f.ariaID, f.bramID, cara.ID} {
		bag, _ := f.inv.List(ctx, id)
		for _, sl := range bag {
			if sl.ItemID == 100 {
				total++
			}
		}
	}
	gold := f.gold(t, f.ariaID) + f.gold(t, f.bramID) + f.gold(t, cara.ID)
	if total != 1 || gold != 3*character.StartingGold {
		t.Fatalf("after the race: %d swords, %d gold in all", total, gold)
	}
	// The hub's flag: a buy while a sale is pending is refused 2.
	f.enter(t)
	f.stalls.Do(f.ariaID, func(s *stall.Stall) { s.Open, s.Selling = true, true })
	f.send(t, "B", OpStallBuy, []byte{0})
	if got := f.next(t, "B", OpStallBuyResult); !bytes.Equal(got, stallResult(StallErrGeneric)) {
		t.Fatalf("a buy during a sale: % x", got)
	}
}

// The owner leaving in the middle of a sale: the sale completes (the stores
// are the sale), the stall is gone, nothing is duplicated or lost.
type leavingPlace struct {
	*inventory.SQLStore
	once  sync.Once
	owner int64
}

func (p *leavingPlace) PlaceItemInstance(ctx context.Context, characterID int64, slot int, itemID int64, quantity int, inst inventory.Instance) error {
	p.once.Do(func() { stallEnd(p.owner, StallErrHostLeft) })
	return p.SQLStore.PlaceItemInstance(ctx, characterID, slot, itemID, quantity, inst)
}

func TestStallOwnerLeavesMidSale(t *testing.T) {
	var lp *leavingPlace
	f := setupStallTestWrapped(t, func(s *inventory.SQLStore) inventory.Store {
		lp = &leavingPlace{SQLStore: s}
		return lp
	})
	lp.owner = f.ariaID
	ctx := context.Background()
	f.openStall(t)
	f.listSword(t, 30)
	f.enter(t)
	f.setOpen(t, 1)
	f.send(t, "B", OpStallBuy, []byte{0})
	if got := f.next(t, "B", OpStallGone); !bytes.Equal(got, EncodeStallGone(uint32(f.ariaID), StallErrHostLeft)) {
		t.Fatalf("0x30B9 % x", got)
	}
	if got := f.next(t, "B", OpStallBuyResult); !bytes.Equal(got, []byte{1, 0}) {
		t.Fatalf("0xB0B4 % x", got)
	}
	f.next(t, "B", OpStallEvent)
	bl, _ := f.inv.List(ctx, f.bramID)
	al, _ := f.inv.List(ctx, f.ariaID)
	if len(bl) != 2 || len(al) != 0 || f.gold(t, f.ariaID) != character.StartingGold+30 {
		t.Fatalf("after the sale: Aria %+v %d, Bram %+v", al, f.gold(t, f.ariaID), bl)
	}
	if f.stalls.Mode(f.ariaID) != 0 || f.stalls.Mode(f.bramID) != 0 {
		t.Fatal("the stall outlived its owner")
	}
}

// A sale whose transaction fails moves nothing; the stall is closed 0x3c2f.
func TestStallFailedSaleLosesNothing(t *testing.T) {
	f := setupStallTestWrapped(t, func(s *inventory.SQLStore) inventory.Store { return failingPlace{s} })
	ctx := context.Background()
	f.openStall(t)
	f.listSword(t, 30)
	f.enter(t)
	f.setOpen(t, 1)
	f.send(t, "B", OpStallBuy, []byte{0})
	if got := f.next(t, "B", OpStallBuyResult); !bytes.Equal(got, stallResult(StallErrDB)) {
		t.Fatalf("0xB0B4 % x", got)
	}
	if got := f.next(t, "A", OpStallGone); !bytes.Equal(got, EncodeStallGone(uint32(f.ariaID), StallErrDB)) {
		t.Fatalf("0x30B9 % x", got)
	}
	al, _ := f.inv.List(ctx, f.ariaID)
	bl, _ := f.inv.List(ctx, f.bramID)
	if len(al) != 1 || len(bl) != 1 || f.gold(t, f.ariaID) != character.StartingGold || f.gold(t, f.bramID) != character.StartingGold {
		t.Fatalf("after a failed sale: Aria %+v, Bram %+v", al, bl)
	}
	if s, _ := f.sales.Sales(ctx, f.ariaID, 0); len(s) != 0 {
		t.Fatalf("a failed sale left its row: %+v", s)
	}
}

// A commit whose answer was lost: the ledger says it applied, the sale is
// answered as made.
func TestStallLostCommitCompletes(t *testing.T) {
	f := setupStallTest(t)
	f.openStall(t)
	f.listSword(t, 30)
	f.enter(t)
	f.setOpen(t, 1)
	restore := txn.SetAfterCommitHookForTest(func(context.Context) error {
		return errors.New("injected: the commit's answer was lost")
	})
	defer restore()
	f.send(t, "B", OpStallBuy, []byte{0})
	if got := f.next(t, "B", OpStallBuyResult); !bytes.Equal(got, []byte{1, 0}) {
		t.Fatalf("0xB0B4 % x", got)
	}
	restore()
	bl, _ := f.inv.List(context.Background(), f.bramID)
	if len(bl) != 2 {
		t.Fatalf("Bram's bag %+v", bl)
	}
}

// A death closes the owner's stall 0x3c0e; a disconnect 0x3c15; a visitor's
// disconnect is a leave (0x30B7 kind 1, no 0xB0B5); a leave outside a stall
// is refused 0x3c0f and the connection closed.
func TestStallLifecycle(t *testing.T) {
	f := setupStallTest(t)
	f.openStall(t)
	f.enter(t)
	f.next(t, "A", OpStallEvent)
	stallEnd(f.ariaID, StallErrClosedDeath)
	if got := f.next(t, "B", OpStallGone); !bytes.Equal(got, EncodeStallGone(uint32(f.ariaID), StallErrClosedDeath)) {
		t.Fatalf("death 0x30B9 % x", got)
	}
	if f.stalls.Mode(f.bramID) != 0 {
		t.Fatal("Bram still inside a closed stall")
	}
	f.openStall(t)
	f.enter(t)
	f.next(t, "A", OpStallEvent)
	stallEnd(f.bramID, StallErrHostLeft)
	if got := f.next(t, "A", OpStallEvent); !bytes.Equal(got, EncodeStallMember(StallEventLeft, uint32(f.bramID))) {
		t.Fatalf("a visitor's disconnect: % x", got)
	}
	f.none(t, "B", OpStallLeaveResult)
	// The owner's connection drops: the disconnect hook closes it 0x3c15.
	ea, _ := f.hub.EntityByCharacterID(f.ariaID)
	StallDisconnectHandler(f.hub)(ea.Session)
	if got := f.next(t, "B", OpStallGone); !bytes.Equal(got, EncodeStallGone(uint32(f.ariaID), StallErrHostLeft)) {
		t.Fatalf("disconnect 0x30B9 % x", got)
	}
	// A leave outside any stall: 0x3c0f, then the connection is closed.
	f.send(t, "B", OpStallLeave, nil)
	if got := f.next(t, "B", OpStallLeaveResult); !bytes.Equal(got, stallResult(StallErrNotVisitor)) {
		t.Fatalf("a stray leave: % x", got)
	}
	f.connB.SetReadDeadline(time.Now().Add(2 * time.Second))
	for {
		if _, err := proto.Read(f.rB, nil, nil); err != nil {
			break
		}
	}
}

// A player who comes into view of a stall gets it in the spawn record
// (InteractMode 4, the name, the booth); the stall chat reaches every
// participant, the sender included.
func TestStallSpawnRecordAndChat(t *testing.T) {
	f := setupStallTest(t)
	ctx := context.Background()
	f.openStall(t)
	cara, _ := f.chars.Create(ctx, 3, "Cara")
	f.accounts.Add("cara", "pw")
	conn := dialTestServer(t, f.addr)
	defer conn.Close()
	r := bufio.NewReader(conn)
	if lr, err := DecodeLoginResult(doSend(t, conn, r, OpLogin, (&LoginRequest{Username: "cara", Password: "pw"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login %v %+v", err, lr)
	}
	if ewr, err := DecodeEnterWorldResult(doSend(t, conn, r, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Cara"}).Encode()).Data); err != nil || !ewr.OK {
		t.Fatalf("enter %v %+v", err, ewr)
	}
	found := false
	for _, rec := range drainPlayerSpawn(t, conn, r) {
		if rec.UID == uint32(f.ariaID) {
			found = true
			if rec.InteractMode != 4 || rec.StallName != "Aria's stall" || rec.StallDecoration != 0 {
				t.Fatalf("Aria's record: mode %d, %q, %d", rec.InteractMode, rec.StallName, rec.StallDecoration)
			}
		}
	}
	if !found {
		t.Fatal("Cara was not sent Aria")
	}
	_ = cara
	f.enter(t)
	chat := (&ChatSendRequest{Type: ChatStall, Index: 1, Message: "how much?"}).Encode()
	f.send(t, "B", OpChatSend, chat)
	for _, who := range []string{"A", "B"} {
		u, err := DecodeChatUpdate(f.next(t, who, OpChatUpdate))
		if err != nil || u.Type != ChatStall || u.Sender != "Bram" || u.Message != "how much?" {
			t.Fatalf("%s's stall line %+v %v", who, u, err)
		}
	}
	// Outside a stall: 5.
	noOp(t, conn, r, OpChatUpdate)
	if err := proto.Write(conn, &proto.Packet{Opcode: OpChatSend, Data: chat}, nil, nil); err != nil {
		t.Fatal(err)
	}
	res, err := DecodeChatResult(nextOp(t, conn, r, OpChatResult).Data)
	if err != nil || res.OK || res.Code != StallErrOperation {
		t.Fatalf("a stall line outside: %+v %v", res, err)
	}
}

var _ net.Conn
