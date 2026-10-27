package session

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"net"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/charmsg"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/trade"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 834: the exchange on the retail wire (exchange.go,
// docs/protocol/exchange.md, exchange_verify.md).

// tradeTestFixture is two characters in the world, Aria with one sword (item
// 100) and Bram with a stack of five (item 200), both with the starting
// gold, the exchange's handlers on two real connections.
type tradeTestFixture struct {
	chars          *character.MemStore
	inv            *inventory.SQLStore
	trades         *trade.Hub
	ariaID, bramID int64
	connA, connB   net.Conn
	rA, rB         *bufio.Reader
	accounts       *account.MemStore
	addr           string
	hub            *world.Hub
}

type tradeFixtureDeps struct {
	accounts *account.MemStore
	chars    *character.MemStore
	inv      *inventory.SQLStore
	trades   *trade.Hub
	hub      *world.Hub // round 837: the mall's handler needs it
}

// exchangeItems is the reference rows the fixture's items have: tradeable
// unless a test says otherwise.
func exchangeItems() stubCombatItems {
	return stubCombatItems{
		100: {ID: 100, PhysAttackMax: 30, CanTrade: true, TypeID1: 3, TypeID2: 1, TypeID3: 6},
		200: {ID: 200, PhysAttackMax: 10, CanTrade: true, TypeID1: 3, TypeID2: 3, TypeID3: 1},
		300: {ID: 300, CanTrade: false, TypeID1: 3, TypeID2: 3, TypeID3: 1},
	}
}

func setupTradeTest(t *testing.T) *tradeTestFixture {
	t.Helper()
	return setupTradeTestWrapped(t, nil, nil)
}

func setupTradeTestWith(t *testing.T, extra func(d tradeFixtureDeps) []gateway.Handler) *tradeTestFixture {
	t.Helper()
	return setupTradeTestWrapped(t, extra, nil)
}

func setupTradeTestWrapped(t *testing.T, extra func(d tradeFixtureDeps) []gateway.Handler, wrap func(*inventory.SQLStore) inventory.Store) *tradeTestFixture {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	accounts.Add("bob", "hunter3")
	chars := character.NewMemStore()
	aria, _ := chars.Create(ctx, 1, "Aria")
	bram, _ := chars.Create(ctx, 2, "Bram")
	items := exchangeItems()
	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), items)
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	t.Cleanup(func() { inv.Close() })
	if err := inv.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating inventory: %v", err)
	}
	if err := inv.AddItem(ctx, aria.ID, 100, 1); err != nil {
		t.Fatal(err)
	}
	if err := inv.AddItem(ctx, bram.ID, 200, 5); err != nil {
		t.Fatal(err)
	}
	hub := world.NewHub()
	trades := trade.NewHub()
	var bag inventory.Store = inv
	if wrap != nil {
		bag = wrap(inv)
	}
	parties := party.NewHub()
	handlers := []gateway.Handler{LoginHandler(accounts), WorldHandler(chars, nil, hub),
		PartyHandler(PartyDeps{Chars: chars, Hub: hub, Parties: parties, Trades: trades}),
		ItemOpHandler(ItemOpDeps{Hub: hub, Inv: bag, Trades: trades, Items: items, Chars: chars}),
		ExchangeHandler(ExchangeDeps{Chars: chars, Inv: bag, Items: items, Hub: hub, Trades: trades, Parties: parties})}
	if extra != nil {
		handlers = append(handlers, extra(tradeFixtureDeps{accounts: accounts, chars: chars, inv: inv, trades: trades, hub: hub})...)
	}
	addr, cleanup := startTestServer(t, gateway.Chain(handlers...))
	t.Cleanup(cleanup)
	t.Cleanup(func() { exchangeRT.Store(nil) })
	f := &tradeTestFixture{chars: chars, inv: inv, trades: trades, ariaID: aria.ID, bramID: bram.ID,
		accounts: accounts, addr: addr, hub: hub}
	f.connA = dialTestServer(t, addr)
	t.Cleanup(func() { f.connA.Close() })
	f.rA = bufio.NewReader(f.connA)
	f.connB = dialTestServer(t, addr)
	t.Cleanup(func() { f.connB.Close() })
	f.rB = bufio.NewReader(f.connB)
	login := func(c net.Conn, r *bufio.Reader, user, pass, name string) {
		if lr, err := DecodeLoginResult(doSend(t, c, r, OpLogin, (&LoginRequest{Username: user, Password: pass}).Encode()).Data); err != nil || !lr.OK {
			t.Fatalf("%s login: %v %+v", user, err, lr)
		}
		if ewr, err := DecodeEnterWorldResult(doSend(t, c, r, OpEnterWorld, (&EnterWorldRequest{CharacterName: name}).Encode()).Data); err != nil || !ewr.OK {
			t.Fatalf("%s enter world: %v %+v", name, err, ewr)
		}
	}
	login(f.connA, f.rA, "alice", "hunter2", "Aria")
	login(f.connB, f.rB, "bob", "hunter3", "Bram")
	drainPlayerSpawn(t, f.connA, f.rA)
	drainPlayerSpawn(t, f.connB, f.rB)
	return f
}

func doSend(t *testing.T, c net.Conn, r *bufio.Reader, opcode uint16, data []byte) *proto.Packet {
	t.Helper()
	if err := proto.Write(c, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
		t.Fatalf("Write: %v", err)
	}
	c.SetReadDeadline(time.Now().Add(2 * time.Second))
	resp, err := readSkippingGuildBlock(r)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	return resp
}

func (f *tradeTestFixture) side(who string) (net.Conn, *bufio.Reader) {
	if who == "B" {
		return f.connB, f.rB
	}
	return f.connA, f.rA
}

func (f *tradeTestFixture) send(t *testing.T, who string, op uint16, data []byte) {
	t.Helper()
	c, _ := f.side(who)
	if err := proto.Write(c, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
		t.Fatal(err)
	}
}

func (f *tradeTestFixture) next(t *testing.T, who string, op uint16) []byte {
	t.Helper()
	c, r := f.side(who)
	return nextOp(t, c, r, op).Data
}

func (f *tradeTestFixture) none(t *testing.T, who string, op uint16) {
	t.Helper()
	c, r := f.side(who)
	noOp(t, c, r, op)
}

func u16(v uint16) []byte { return binary.LittleEndian.AppendUint16(nil, v) }

// requestTrade has Aria ask Bram; Bram gets the request box.
func requestTrade(t *testing.T, f *tradeTestFixture) {
	t.Helper()
	f.send(t, "A", OpExchangeRequest, binary.LittleEndian.AppendUint32(nil, uint32(f.bramID)))
	if got := f.next(t, "B", OpRequestBox); !bytes.Equal(got, EncodeExchangeRequestBox(uint32(f.ariaID))) {
		t.Fatalf("Bram's box % x", got)
	}
}

// acceptTrade has Bram accept: 0xB081 {1, Bram} to Aria, 0x3085 {Aria} to Bram.
func acceptTrade(t *testing.T, f *tradeTestFixture) {
	t.Helper()
	f.send(t, "B", OpRequestBox, []byte{1, 1})
	if got := f.next(t, "A", OpExchangeRequestResult); !bytes.Equal(got, EncodeExchangeAccepted(uint32(f.bramID))) {
		t.Fatalf("Aria's 0xB081 % x", got)
	}
	if got := f.next(t, "B", OpExchangeStarted); binary.LittleEndian.Uint32(got) != uint32(f.ariaID) {
		t.Fatalf("Bram's 0x3085 % x", got)
	}
}

func startTrade(t *testing.T, f *tradeTestFixture) {
	t.Helper()
	requestTrade(t, f)
	acceptTrade(t, f)
}

func (f *tradeTestFixture) offer(t *testing.T, who string, bagIndex int) []byte {
	t.Helper()
	f.send(t, who, OpItemMove, []byte{ItemMoveExchangeAdd, byte(bagIndex + ItemWireBagOffset)})
	return f.next(t, who, OpItemMoveResult)
}

func (f *tradeTestFixture) gold(t *testing.T, id int64) int64 {
	t.Helper()
	c, err := f.chars.GetByID(context.Background(), id)
	if err != nil {
		t.Fatal(err)
	}
	return c.Gold
}

func TestExchangeWireLayouts(t *testing.T) {
	check := func(what string, got, want []byte) {
		t.Helper()
		if !bytes.Equal(got, want) {
			t.Errorf("%s: % x, want % x", what, got, want)
		}
	}
	check("0x3080 kind 1", EncodeExchangeRequestBox(7), []byte{1, 7, 0, 0, 0})
	check("0xB081 {1, target}", EncodeExchangeAccepted(9), []byte{1, 9, 0, 0, 0})
	check("0x3089 {2, u64}", EncodeExchangeGold(100), []byte{2, 100, 0, 0, 0, 0, 0, 0, 0})
	check("{1}", exchangeResult(ExchangeOK), []byte{1})
	check("{2, code}", exchangeResult(ExchangeErrState), []byte{2, 0x1f, 0x18})
	bay := []trade.Item{{Slot: 2, ItemID: 200, Quantity: 5}}
	own := EncodeExchangeOffer(context.Background(), exchangeItems(), 5, bay, true)
	other := EncodeExchangeOffer(context.Background(), exchangeItems(), 5, bay, false)
	if !bytes.Equal(own[:7], []byte{5, 0, 0, 0, 1, 15, 0}) || !bytes.Equal(other[:6], []byte{5, 0, 0, 0, 1, 0}) {
		t.Errorf("0x308C: own % x, other % x -- the bag slot (15) only to the owner", own, other)
	}
	if !bytes.Equal(own[7:], other[6:]) || !bytes.Equal(own[7:], AppendItemRecord(nil, ItemInfo{RefItemID: 200, Tail: u16(5)})) {
		t.Errorf("0x308C's record % x: want the full record, the stack's count", own[7:])
	}
}

// The whole flow: offers seen only at the confirm, Confirm then Approve, the
// deal on the second Approve, the stores changed and the window closed.
func TestExchangeFullFlow(t *testing.T) {
	f := setupTradeTest(t)
	ctx := context.Background()
	startTrade(t, f)
	if got := f.offer(t, "A", 0); !bytes.Equal(got, []byte{1, ItemMoveExchangeAdd, 13, 0}) {
		t.Fatalf("Aria's add % x", got)
	}
	f.send(t, "A", OpItemMove, binary.LittleEndian.AppendUint64([]byte{ItemMoveExchangeGold}, 100))
	if got := f.next(t, "A", OpItemMoveResult); !bytes.Equal(got, binary.LittleEndian.AppendUint64([]byte{1, ItemMoveExchangeGold}, 100)) {
		t.Fatalf("Aria's gold % x", got)
	}
	f.none(t, "B", OpExchangeOffer) // nothing of Aria's offer before her confirm
	if got := f.offer(t, "B", 0); !bytes.Equal(got, []byte{1, ItemMoveExchangeAdd, 13, 0}) {
		t.Fatalf("Bram's add % x", got)
	}
	f.send(t, "A", OpExchangeConfirm, nil)
	ownList := f.next(t, "A", OpExchangeOffer)
	if got := f.next(t, "A", OpExchangeConfirmResult); !bytes.Equal(got, []byte{1}) {
		t.Fatalf("Aria's 0xB082 % x", got)
	}
	seen := f.next(t, "B", OpExchangeOffer)
	if binary.LittleEndian.Uint32(seen) != uint32(f.ariaID) || seen[4] != 1 || len(seen) != len(ownList)-1 {
		t.Fatalf("Bram sees Aria's list % x (Aria's own % x)", seen, ownList)
	}
	if got := f.next(t, "B", OpExchangeUpdate); !bytes.Equal(got, EncodeExchangeGold(100)) {
		t.Fatalf("Bram's 0x3089 % x", got)
	}
	f.next(t, "B", OpExchangeConfirmed)
	// Aria's offer is locked now: a move is 0x181f, which would close it --
	// not tried here (TestExchangeMoveAfterConfirmCloses).
	f.send(t, "A", OpExchangeApprove, nil)
	if got := f.next(t, "A", OpExchangeApproveResult); !bytes.Equal(got, exchangeResult(ExchangeErrState)) {
		t.Fatalf("an approve before both confirmed: % x, want 0x181f", got)
	}
	// ... and that closed the session (0x181f is in the close list).
	if got := f.next(t, "B", OpExchangeClosed); !bytes.Equal(got, u16(ExchangeErrState)) {
		t.Fatalf("Bram's 0x3088 % x", got)
	}
	if f.trades.Busy(f.ariaID) {
		t.Fatal("the session is still open")
	}
	// Again, in order this time.
	startTrade(t, f)
	f.offer(t, "A", 0)
	f.send(t, "A", OpItemMove, binary.LittleEndian.AppendUint64([]byte{ItemMoveExchangeGold}, 100))
	f.next(t, "A", OpItemMoveResult)
	f.offer(t, "B", 0)
	f.send(t, "A", OpExchangeConfirm, nil)
	f.next(t, "A", OpExchangeConfirmResult)
	f.next(t, "B", OpExchangeConfirmed)
	f.send(t, "B", OpExchangeConfirm, nil)
	f.next(t, "B", OpExchangeConfirmResult)
	f.next(t, "A", OpExchangeConfirmed)
	f.send(t, "A", OpExchangeApprove, nil)
	if got := f.next(t, "A", OpExchangeApproveResult); !bytes.Equal(got, []byte{1}) {
		t.Fatalf("Aria's approve % x", got)
	}
	f.none(t, "B", OpExchangeDone)
	start := character.StartingGold
	f.send(t, "B", OpExchangeApprove, nil)
	if got := f.next(t, "B", OpCharInfoGold()); !bytes.Equal(got, charmsg.EncodeGold(int64(start)+100, false)) {
		t.Fatalf("Bram's 0x304E % x", got)
	}
	if got := f.next(t, "B", OpExchangeApproveResult); !bytes.Equal(got, []byte{1}) {
		t.Fatalf("Bram's approve % x", got)
	}
	f.next(t, "B", OpExchangeDone)
	f.next(t, "A", OpExchangeDone)
	if a, b := f.gold(t, f.ariaID), f.gold(t, f.bramID); a != int64(start)-100 || b != int64(start)+100 {
		t.Fatalf("gold after: Aria %d, Bram %d", a, b)
	}
	al, _ := f.inv.List(ctx, f.ariaID)
	bl, _ := f.inv.List(ctx, f.bramID)
	if len(al) != 1 || al[0].ItemID != 200 || al[0].Quantity != 5 || al[0].Index != 1 {
		t.Fatalf("Aria's bag %+v: want the five in her first empty slot, 1 (her sword's 0 was not free at the deal)", al)
	}
	if len(bl) != 1 || bl[0].ItemID != 100 || bl[0].Index != 1 {
		t.Fatalf("Bram's bag %+v: want the sword in slot 1", bl)
	}
	// A resent approve finds no session and moves nothing (round 743's
	// duplicate).
	f.send(t, "B", OpExchangeApprove, nil)
	if got := f.next(t, "B", OpExchangeApproveResult); !bytes.Equal(got, exchangeResult(ExchangeErrNoSession)) {
		t.Fatalf("a resent approve: % x", got)
	}
	if b := f.gold(t, f.bramID); b != int64(start)+100 {
		t.Fatalf("Bram's gold after a resent approve: %d", b)
	}
}

// OpCharInfoGold is 0x304E, the gold total (charmsg.OpCharInfo).
func OpCharInfoGold() uint16 { return charmsg.OpCharInfo }

// The request ladder and the answer.
func TestExchangeRequestAndAnswer(t *testing.T) {
	f := setupTradeTest(t)
	f.send(t, "A", OpExchangeRequest, binary.LittleEndian.AppendUint32(nil, uint32(f.ariaID)))
	if got := f.next(t, "A", OpExchangeRequestResult); !bytes.Equal(got, exchangeResult(ExchangeErrTarget)) {
		t.Fatalf("asking yourself: % x, want 3", got)
	}
	f.send(t, "A", OpExchangeRequest, binary.LittleEndian.AppendUint32(nil, 999999))
	if got := f.next(t, "A", OpExchangeRequestResult); !bytes.Equal(got, exchangeResult(ExchangeErrTarget)) {
		t.Fatalf("asking no one: % x, want 3", got)
	}
	requestTrade(t, f)
	// The same request again is dropped; Bram, asking Aria back, is busy.
	f.send(t, "A", OpExchangeRequest, binary.LittleEndian.AppendUint32(nil, uint32(f.bramID)))
	f.none(t, "B", OpRequestBox)
	// Refuse: 0x1828 to both.
	f.send(t, "B", OpRequestBox, []byte{1, 0})
	for _, who := range []string{"A", "B"} {
		if got := f.next(t, who, OpExchangeClosed); !bytes.Equal(got, u16(ExchangeErrDenied)) {
			t.Fatalf("%s after a refusal: % x, want 0x1828", who, got)
		}
	}
	// The box's own code ({2, code}) closes it with that code.
	requestTrade(t, f)
	f.send(t, "B", OpRequestBox, append([]byte{2}, u16(0x1234)...))
	if got := f.next(t, "A", OpExchangeClosed); !bytes.Equal(got, u16(0x1234)) {
		t.Fatalf("the client's code: % x", got)
	}
	// The asker withdraws a pending request: 0x3088 {0x182c} to both, then
	// 0xB084 {1}.
	requestTrade(t, f)
	f.send(t, "A", OpExchangeCancel, nil)
	if got := f.next(t, "A", OpExchangeClosed); !bytes.Equal(got, u16(ExchangeErrCancelled)) {
		t.Fatalf("withdraw: % x", got)
	}
	if got := f.next(t, "A", OpExchangeCancelResult); !bytes.Equal(got, []byte{1}) {
		t.Fatalf("withdraw's 0xB084 % x", got)
	}
	f.next(t, "B", OpExchangeClosed)
}

func TestExchangeRequestTimesOut(t *testing.T) {
	f := setupTradeTest(t)
	f.trades.Timeout = 150 * time.Millisecond
	requestTrade(t, f)
	for _, who := range []string{"A", "B"} {
		if got := f.next(t, who, OpExchangeClosed); !bytes.Equal(got, u16(ExchangeErrTimeout)) {
			t.Fatalf("%s: % x, want 0x1826", who, got)
		}
	}
}

// Item refusals that keep the session, and a move after the confirm that
// closes it: 0x3088 to both first, then 0xB034 {2} (exchange_verify W5).
func TestExchangeMoveRules(t *testing.T) {
	f := setupTradeTest(t)
	ctx := context.Background()
	if err := f.inv.AddItem(ctx, f.ariaID, 300, 1); err != nil {
		t.Fatal(err)
	}
	startTrade(t, f)
	if got := f.offer(t, "A", 1); !bytes.Equal(got, EncodeItemFail(ExchangeErrCannotTrade)) {
		t.Fatalf("an untradeable item: % x, want 0x183a", got)
	}
	if got := f.offer(t, "A", 5); !bytes.Equal(got, EncodeItemFail(ExchangeErrEmptySlot)) {
		t.Fatalf("an empty slot: % x, want 0x1809", got)
	}
	f.offer(t, "A", 0)
	if got := f.offer(t, "A", 0); !bytes.Equal(got, EncodeItemFail(ExchangeErrSameItem)) {
		t.Fatalf("the same item twice: % x, want 0x182d", got)
	}
	f.send(t, "A", OpItemMove, binary.LittleEndian.AppendUint64([]byte{ItemMoveExchangeGold}, 0))
	if got := f.next(t, "A", OpItemMoveResult); !bytes.Equal(got, EncodeItemFail(ExchangeErrPositive)) {
		t.Fatalf("gold 0: % x, want 0x1829", got)
	}
	f.send(t, "A", OpItemMove, binary.LittleEndian.AppendUint64([]byte{ItemMoveExchangeGold}, uint64(character.StartingGold)+1))
	if got := f.next(t, "A", OpItemMoveResult); !bytes.Equal(got, EncodeItemFail(ExchangeErrGold)) {
		t.Fatalf("more than carried: % x, want 0x180f", got)
	}
	// Take it back: {1, 5, index}; the bay is empty again.
	f.send(t, "A", OpItemMove, []byte{ItemMoveExchangeRemove, 0})
	f.next(t, "A", OpExchangeOffer)
	if got := f.next(t, "A", OpItemMoveResult); !bytes.Equal(got, []byte{1, ItemMoveExchangeRemove, 0}) {
		t.Fatalf("the remove % x", got)
	}
	f.send(t, "A", OpItemMove, []byte{ItemMoveExchangeRemove, 0})
	if got := f.next(t, "A", OpItemMoveResult); !bytes.Equal(got, EncodeItemFail(ExchangeErrBayEmpty)) {
		t.Fatalf("a remove from an empty bay: % x, want 0x1824", got)
	}
	// Another item operation during the exchange: 0x1834.
	f.send(t, "A", OpItemMove, []byte{ItemMoveBagToBag, 13, 20, 1, 0})
	if got := f.next(t, "A", OpItemMoveResult); !bytes.Equal(got, EncodeItemFail(ExchangeErrBlocked)) {
		t.Fatalf("a split during the exchange: % x, want 0x1834", got)
	}
	f.send(t, "A", OpExchangeConfirm, nil)
	f.next(t, "A", OpExchangeConfirmResult)
	f.send(t, "A", OpItemMove, []byte{ItemMoveExchangeAdd, 13})
	if got := f.next(t, "A", OpExchangeClosed); !bytes.Equal(got, u16(ExchangeErrState)) {
		t.Fatalf("a move after the confirm: % x, want 0x3088 {0x181f}", got)
	}
	if got := f.next(t, "A", OpItemMoveResult); !bytes.Equal(got, EncodeItemFail(ExchangeErrState)) {
		t.Fatalf("then 0xB034 % x", got)
	}
	f.next(t, "B", OpExchangeClosed)
}

// A second Confirm at state 2 is taken again (exchange_verify W2).
func TestExchangeConfirmTwice(t *testing.T) {
	f := setupTradeTest(t)
	startTrade(t, f)
	for i := 0; i < 2; i++ {
		f.send(t, "A", OpExchangeConfirm, nil)
		if got := f.next(t, "A", OpExchangeConfirmResult); !bytes.Equal(got, []byte{1}) {
			t.Fatalf("confirm %d: % x", i+1, got)
		}
		f.next(t, "B", OpExchangeConfirmed)
	}
}

// Death and the logout close it 0x182b.
func TestExchangeEndsOnDisconnect(t *testing.T) {
	f := setupTradeTest(t)
	startTrade(t, f)
	e, _ := f.hub.EntityByCharacterID(f.ariaID)
	ExchangeDisconnectHandler(f.hub)(e.Session)
	if got := f.next(t, "B", OpExchangeClosed); !bytes.Equal(got, u16(ExchangeErrCancel)) {
		t.Fatalf("Bram: % x, want 0x182b", got)
	}
	if f.trades.Busy(f.bramID) {
		t.Fatal("still open")
	}
	startTrade(t, f)
	exchangeEnd(f.bramID, ExchangeErrCancel)
	f.next(t, "A", OpExchangeClosed)
}

// A deal that fails moves nothing: both keep what they had, and both are
// told 0x1811 (round 743's "failed credit loses nothing").
type failingPlace struct{ *inventory.SQLStore }

func (failingPlace) PlaceItemInstance(context.Context, int64, int, int64, int, inventory.Instance) error {
	return errors.New("injected: the connection dropped")
}

func TestExchangeFailedDealLosesNothing(t *testing.T) {
	f := setupTradeTestWrapped(t, nil, func(s *inventory.SQLStore) inventory.Store { return failingPlace{s} })
	runDeal(t, f)
	for _, who := range []string{"A", "B"} {
		if got := f.next(t, who, OpExchangeClosed); !bytes.Equal(got, u16(ExchangeErrDB)) {
			t.Fatalf("%s: % x, want 0x1811", who, got)
		}
	}
	al, _ := f.inv.List(context.Background(), f.ariaID)
	bl, _ := f.inv.List(context.Background(), f.bramID)
	if len(al) != 1 || al[0].ItemID != 100 || len(bl) != 1 || bl[0].ItemID != 200 {
		t.Fatalf("after a failed deal: Aria %+v, Bram %+v", al, bl)
	}
	if f.gold(t, f.ariaID) != character.StartingGold {
		t.Fatal("gold moved")
	}
}

// A commit whose answer was lost: the ledger says it applied, and both get
// 0x3087 (round 743's review, F2).
func TestExchangeLostCommitCompletes(t *testing.T) {
	f := setupTradeTest(t)
	restore := txn.SetAfterCommitHookForTest(func(context.Context) error {
		return errors.New("injected: the commit's answer was lost")
	})
	defer restore()
	runDeal(t, f)
	f.next(t, "A", OpExchangeDone)
	f.next(t, "B", OpExchangeDone)
	restore()
	bl, _ := f.inv.List(context.Background(), f.bramID)
	if len(bl) != 2 {
		t.Fatalf("Bram's bag %+v, want his stack and the sword", bl)
	}
}

// runDeal: Aria offers her sword, both confirm and approve.
func runDeal(t *testing.T, f *tradeTestFixture) {
	t.Helper()
	startTrade(t, f)
	f.offer(t, "A", 0)
	f.send(t, "A", OpExchangeConfirm, nil)
	f.next(t, "A", OpExchangeConfirmResult)
	f.send(t, "B", OpExchangeConfirm, nil)
	f.next(t, "B", OpExchangeConfirmResult)
	f.send(t, "A", OpExchangeApprove, nil)
	f.next(t, "A", OpExchangeApproveResult)
	f.send(t, "B", OpExchangeApprove, nil)
}

var _ = refdata.Item{}
