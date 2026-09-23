package session

import (
	"bufio"
	"context"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/trade"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

func TestTradeRequestRequestRoundTrip(t *testing.T) {
	want := &TradeRequestRequest{CharacterName: "Aria", TargetName: "Bram"}
	got, err := DecodeTradeRequestRequest(want.Encode())
	if err != nil {
		t.Fatalf("DecodeTradeRequestRequest: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestTradeSetOfferRequestRoundTrip(t *testing.T) {
	want := &TradeSetOfferRequest{CharacterName: "Aria", Offer: TradeOffer{Gold: 100, ItemSlot: 3, Quantity: 2}}
	got, err := DecodeTradeSetOfferRequest(want.Encode())
	if err != nil {
		t.Fatalf("DecodeTradeSetOfferRequest: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestTradeSetOfferRequestNoItemRoundTrip(t *testing.T) {
	want := &TradeSetOfferRequest{CharacterName: "Aria", Offer: TradeOffer{Gold: 50, ItemSlot: -1, Quantity: 0}}
	got, err := DecodeTradeSetOfferRequest(want.Encode())
	if err != nil {
		t.Fatalf("DecodeTradeSetOfferRequest: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestTradeCompletedRoundTrip(t *testing.T) {
	want := &TradeCompleted{ReceivedGold: 100, ReceivedItemID: 200, ReceivedQuantity: 3}
	got, err := DecodeTradeCompleted(want.Encode())
	if err != nil {
		t.Fatalf("DecodeTradeCompleted: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestTradeRespondRequestRoundTrip(t *testing.T) {
	want := &TradeRespondRequest{CharacterName: "Bram", RequesterName: "Aria", Accept: true}
	got, err := DecodeTradeRespondRequest(want.Encode())
	if err != nil {
		t.Fatalf("DecodeTradeRespondRequest: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

// tradeTestFixture sets up two characters (Aria, Bram) each with a
// weapon-item stack in their inventory, wires the full trade handler
// chain over two real TCP connections, and gets both through login +
// enter_world. Returns everything a trade test needs.
type tradeTestFixture struct {
	chars          *character.MemStore
	inv            *inventory.SQLStore
	trades         *trade.Hub
	ariaID, bramID int64
	connA, connB   net.Conn
	rA, rB         *bufio.Reader
}

func setupTradeTest(t *testing.T) *tradeTestFixture {
	t.Helper()
	return setupTradeTestWithItems(t, nil)
}

// setupTradeTestWithItems is setupTradeTest with items wired into the trade
// handler as its reference-data lookup (nil means none, as on a server that
// has imported no tables).
func setupTradeTestWithItems(t *testing.T, items ItemLookup) *tradeTestFixture {
	t.Helper()
	return setupTradeTestWith(t, items, nil)
}

// tradeFixtureDeps is what setupTradeTestWith hands an extra-handler builder:
// the fixture's own stores and trade hub, so the handlers it builds (an NPC
// shop, a warehouse, ...) see the same characters and the same trades.
type tradeFixtureDeps struct {
	accounts *account.MemStore
	chars    *character.MemStore
	inv      *inventory.SQLStore
	trades   *trade.Hub
}

// setupTradeTestWith is setupTradeTestWithItems plus whatever handlers extra
// builds, chained after the trade handler (nil adds none).
func setupTradeTestWith(t *testing.T, items ItemLookup, extra func(d tradeFixtureDeps) []gateway.Handler) *tradeTestFixture {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	accounts.Add("bob", "hunter3")
	chars := character.NewMemStore()
	aria, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating Aria: %v", err)
	}
	bram, err := chars.Create(ctx, 2, "Bram")
	if err != nil {
		t.Fatalf("creating Bram: %v", err)
	}

	stacks := stubCombatItems{100: {ID: 100, PhysAttackMax: 30}, 200: {ID: 200, PhysAttackMax: 10}}
	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), stacks)
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	t.Cleanup(func() { inv.Close() })
	if err := inv.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating inventory: %v", err)
	}
	if err := inv.AddItem(ctx, aria.ID, 100, 1); err != nil {
		t.Fatalf("seeding Aria's inventory: %v", err)
	}
	if err := inv.AddItem(ctx, bram.ID, 200, 5); err != nil {
		t.Fatalf("seeding Bram's inventory: %v", err)
	}

	hub := world.NewHub()
	trades := trade.NewHub()
	handlers := []gateway.Handler{LoginHandler(accounts), WorldHandler(chars, nil, hub), TradeHandler(chars, inv, items, hub, trades)}
	if extra != nil {
		handlers = append(handlers, extra(tradeFixtureDeps{accounts: accounts, chars: chars, inv: inv, trades: trades})...)
	}
	handle := gateway.Chain(handlers...)

	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)

	connA := dialTestServer(t, addr)
	t.Cleanup(func() { connA.Close() })
	rA := bufio.NewReader(connA)
	connB := dialTestServer(t, addr)
	t.Cleanup(func() { connB.Close() })
	rB := bufio.NewReader(connB)

	doSend := func(c net.Conn, r *bufio.Reader, opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(c, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		c.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}

	resp := doSend(connA, rA, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("alice login failed: err=%v result=%+v", err, lr)
	}
	resp = doSend(connB, rB, OpLogin, (&LoginRequest{Username: "bob", Password: "hunter3"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("bob login failed: err=%v result=%+v", err, lr)
	}
	resp = doSend(connA, rA, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ewr, err := DecodeEnterWorldResult(resp.Data); err != nil || !ewr.OK {
		t.Fatalf("aria enter world failed: err=%v result=%+v", err, ewr)
	}
	resp = doSend(connB, rB, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Bram"}).Encode())
	if ewr, err := DecodeEnterWorldResult(resp.Data); err != nil || !ewr.OK {
		t.Fatalf("bram enter world failed: err=%v result=%+v", err, ewr)
	}
	connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := proto.Read(rA, nil, nil); err != nil {
		t.Fatalf("draining EntityEntered: %v", err)
	}

	return &tradeTestFixture{chars: chars, inv: inv, trades: trades, ariaID: aria.ID, bramID: bram.ID, connA: connA, connB: connB, rA: rA, rB: rB}
}

// startTrade has Aria request a trade with Bram and Bram accept, and drains
// the invite and both OpTradeStarted packets: the trade is open, Aria is side
// A and Bram side B, and neither has offered anything.
func startTrade(t *testing.T, f *tradeTestFixture) {
	t.Helper()
	requestTrade(t, f)
	acceptTrade(t, f)
}

// requestTrade has Aria ask Bram to trade and drains Bram's OpTradeInvite: the
// request is pending, nothing is open yet.
func requestTrade(t *testing.T, f *tradeTestFixture) {
	t.Helper()
	resp := doSend(t, f.connA, f.rA, OpTradeRequest, (&TradeRequestRequest{CharacterName: "Aria", TargetName: "Bram"}).Encode())
	if rr, err := DecodeTradeRequestResult(resp.Data); err != nil || !rr.OK {
		t.Fatalf("trade request failed: err=%v result=%+v", err, rr)
	}
	f.connB.SetReadDeadline(time.Now().Add(2 * time.Second))
	if invite, err := proto.Read(f.rB, nil, nil); err != nil || invite.Opcode != OpTradeInvite {
		t.Fatalf("reading OpTradeInvite: packet=%v err=%v", invite, err)
	}
}

// acceptTrade has Bram accept Aria's pending request and drains both
// OpTradeStarted packets.
func acceptTrade(t *testing.T, f *tradeTestFixture) {
	t.Helper()
	resp := doSend(t, f.connB, f.rB, OpTradeRespond, (&TradeRespondRequest{CharacterName: "Bram", RequesterName: "Aria", Accept: true}).Encode())
	if rr, err := DecodeTradeRespondResult(resp.Data); err != nil || !rr.OK {
		t.Fatalf("trade respond failed: err=%v result=%+v", err, rr)
	}
	// Both sides get OpTradeStarted.
	f.connB.SetReadDeadline(time.Now().Add(2 * time.Second))
	if startedPkt, err := proto.Read(f.rB, nil, nil); err != nil || startedPkt.Opcode != OpTradeStarted {
		t.Fatalf("reading Bram's OpTradeStarted: opcode=%v err=%v", startedPkt, err)
	}
	f.connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	if startedPkt, err := proto.Read(f.rA, nil, nil); err != nil || startedPkt.Opcode != OpTradeStarted {
		t.Fatalf("reading Aria's OpTradeStarted: opcode=%v err=%v", startedPkt, err)
	}
}

func doSend(t *testing.T, c net.Conn, r *bufio.Reader, opcode uint16, data []byte) *proto.Packet {
	t.Helper()
	if err := proto.Write(c, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
		t.Fatalf("Write: %v", err)
	}
	c.SetReadDeadline(time.Now().Add(2 * time.Second))
	resp, err := proto.Read(r, nil, nil)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	return resp
}

// TestTradeFullFlow has Alice request a trade with Bob, Bob accept, both
// set offers (Alice: 50 gold + her weapon; Bob: his stack of 5 items, no
// gold), both confirm, and verifies the swap actually happened in both
// character.Store and inventory.Store -- not just that the wire messages
// looked right.
func TestTradeFullFlow(t *testing.T) {
	f := setupTradeTest(t)
	ctx := context.Background()

	startTrade(t, f)

	// Aria offers 50 gold + her weapon (slot 0, qty 1).
	resp := doSend(t, f.connA, f.rA, OpTradeSetOffer, (&TradeSetOfferRequest{CharacterName: "Aria", Offer: TradeOffer{Gold: 50, ItemSlot: 0, Quantity: 1}}).Encode())
	if or, err := DecodeTradeOfferResult(resp.Data); err != nil || !or.OK {
		t.Fatalf("Aria's offer failed: err=%v result=%+v", err, or)
	}
	f.connB.SetReadDeadline(time.Now().Add(2 * time.Second))
	updatedPkt, err := proto.Read(f.rB, nil, nil)
	if err != nil || updatedPkt.Opcode != OpTradeOfferUpdated {
		t.Fatalf("reading Bram's OpTradeOfferUpdated: opcode=%v err=%v", updatedPkt, err)
	}
	if ou, err := DecodeTradeOfferUpdated(updatedPkt.Data); err != nil || ou.Offer.Gold != 50 || ou.Offer.ItemSlot != 0 {
		t.Fatalf("unexpected offer update on Bram's side: %+v (err=%v)", ou, err)
	}

	// Bram offers his stack of 5 (slot 0, qty 5), no gold.
	resp = doSend(t, f.connB, f.rB, OpTradeSetOffer, (&TradeSetOfferRequest{CharacterName: "Bram", Offer: TradeOffer{Gold: 0, ItemSlot: 0, Quantity: 5}}).Encode())
	if or, err := DecodeTradeOfferResult(resp.Data); err != nil || !or.OK {
		t.Fatalf("Bram's offer failed: err=%v result=%+v", err, or)
	}
	f.connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	if updatedPkt, err := proto.Read(f.rA, nil, nil); err != nil || updatedPkt.Opcode != OpTradeOfferUpdated {
		t.Fatalf("reading Aria's OpTradeOfferUpdated: opcode=%v err=%v", updatedPkt, err)
	}

	// Aria confirms.
	resp = doSend(t, f.connA, f.rA, OpTradeConfirm, (&TradeConfirmRequest{CharacterName: "Aria"}).Encode())
	if cr, err := DecodeTradeConfirmResult(resp.Data); err != nil || !cr.OK {
		t.Fatalf("Aria's confirm failed: err=%v result=%+v", err, cr)
	}

	// Bram confirms -- this triggers execution and both should get
	// OpTradeCompleted.
	resp = doSend(t, f.connB, f.rB, OpTradeConfirm, (&TradeConfirmRequest{CharacterName: "Bram"}).Encode())
	if cr, err := DecodeTradeConfirmResult(resp.Data); err != nil || !cr.OK {
		t.Fatalf("Bram's confirm failed: err=%v result=%+v", err, cr)
	}

	f.connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	completedA, err := proto.Read(f.rA, nil, nil)
	if err != nil || completedA.Opcode != OpTradeCompleted {
		t.Fatalf("reading Aria's OpTradeCompleted: opcode=%v err=%v", completedA, err)
	}
	tcA, err := DecodeTradeCompleted(completedA.Data)
	if err != nil || tcA.ReceivedGold != 0 || tcA.ReceivedItemID != 200 || tcA.ReceivedQuantity != 5 {
		t.Fatalf("unexpected TradeCompleted for Aria: %+v (err=%v)", tcA, err)
	}

	f.connB.SetReadDeadline(time.Now().Add(2 * time.Second))
	completedB, err := proto.Read(f.rB, nil, nil)
	if err != nil || completedB.Opcode != OpTradeCompleted {
		t.Fatalf("reading Bram's OpTradeCompleted: opcode=%v err=%v", completedB, err)
	}
	tcB, err := DecodeTradeCompleted(completedB.Data)
	if err != nil || tcB.ReceivedGold != 50 || tcB.ReceivedItemID != 100 || tcB.ReceivedQuantity != 1 {
		t.Fatalf("unexpected TradeCompleted for Bram: %+v (err=%v)", tcB, err)
	}

	// Verify actual store state, not just the wire messages.
	list, err := f.chars.ListByAccount(ctx, 1)
	if err != nil {
		t.Fatalf("ListByAccount(1): %v", err)
	}
	if wantGold := int64(character.StartingGold) - 50; list[0].Gold != wantGold {
		t.Fatalf("Aria's gold: got %d, want %d", list[0].Gold, wantGold)
	}
	list, err = f.chars.ListByAccount(ctx, 2)
	if err != nil {
		t.Fatalf("ListByAccount(2): %v", err)
	}
	if wantGold := int64(character.StartingGold) + 50; list[0].Gold != wantGold {
		t.Fatalf("Bram's gold: got %d, want %d", list[0].Gold, wantGold)
	}

	ariaSlots, err := f.inv.List(ctx, 1)
	if err != nil {
		t.Fatalf("Aria's inventory: %v", err)
	}
	var foundItem200 bool
	for _, s := range ariaSlots {
		if s.ItemID == 100 {
			t.Fatal("Aria should no longer have item 100 (traded away)")
		}
		if s.ItemID == 200 && s.Quantity == 5 {
			foundItem200 = true
		}
	}
	if !foundItem200 {
		t.Fatalf("Aria should have received 5x item 200, got %+v", ariaSlots)
	}

	bramSlots, err := f.inv.List(ctx, 2)
	if err != nil {
		t.Fatalf("Bram's inventory: %v", err)
	}
	var foundItem100 bool
	for _, s := range bramSlots {
		if s.ItemID == 200 {
			t.Fatal("Bram should no longer have item 200 (traded away)")
		}
		if s.ItemID == 100 && s.Quantity == 1 {
			foundItem100 = true
		}
	}
	if !foundItem100 {
		t.Fatalf("Bram should have received item 100, got %+v", bramSlots)
	}
}

// TestTradeCancelFlow has Alice request and Bob accept, then Bob cancels
// before confirming -- neither side's gold/items should be touched, and
// both should get OpTradeCancelled.
func TestTradeCancelFlow(t *testing.T) {
	f := setupTradeTest(t)

	resp := doSend(t, f.connA, f.rA, OpTradeRequest, (&TradeRequestRequest{CharacterName: "Aria", TargetName: "Bram"}).Encode())
	if rr, err := DecodeTradeRequestResult(resp.Data); err != nil || !rr.OK {
		t.Fatalf("trade request failed: err=%v result=%+v", err, rr)
	}
	f.connB.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := proto.Read(f.rB, nil, nil); err != nil {
		t.Fatalf("reading OpTradeInvite: %v", err)
	}
	resp = doSend(t, f.connB, f.rB, OpTradeRespond, (&TradeRespondRequest{CharacterName: "Bram", RequesterName: "Aria", Accept: true}).Encode())
	if rr, err := DecodeTradeRespondResult(resp.Data); err != nil || !rr.OK {
		t.Fatalf("trade respond failed: err=%v result=%+v", err, rr)
	}
	f.connB.SetReadDeadline(time.Now().Add(2 * time.Second))
	proto.Read(f.rB, nil, nil) // OpTradeStarted for Bram
	f.connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	proto.Read(f.rA, nil, nil) // OpTradeStarted for Aria

	if err := proto.Write(f.connB, &proto.Packet{Opcode: OpTradeCancel, Data: (&TradeCancelRequest{CharacterName: "Bram"}).Encode()}, nil, nil); err != nil {
		t.Fatalf("Write OpTradeCancel: %v", err)
	}

	f.connB.SetReadDeadline(time.Now().Add(2 * time.Second))
	cancelledB, err := proto.Read(f.rB, nil, nil)
	if err != nil || cancelledB.Opcode != OpTradeCancelled {
		t.Fatalf("reading Bram's OpTradeCancelled: opcode=%v err=%v", cancelledB, err)
	}
	f.connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	cancelledA, err := proto.Read(f.rA, nil, nil)
	if err != nil || cancelledA.Opcode != OpTradeCancelled {
		t.Fatalf("reading Aria's OpTradeCancelled: opcode=%v err=%v", cancelledA, err)
	}
	tc, err := DecodeTradeCancelled(cancelledA.Data)
	if err != nil || tc.CancelledByName != "Bram" {
		t.Fatalf("unexpected TradeCancelled: %+v (err=%v)", tc, err)
	}

	// Trying to set an offer now should fail -- no active trade.
	resp = doSend(t, f.connA, f.rA, OpTradeSetOffer, (&TradeSetOfferRequest{CharacterName: "Aria", Offer: TradeOffer{ItemSlot: -1}}).Encode())
	if or, err := DecodeTradeOfferResult(resp.Data); err != nil || or.OK || or.Reason != "not trading" {
		t.Fatalf("offer after cancel: err=%v result=%+v", err, or)
	}
}

// TestTradeInsufficientGold has Alice offer more gold than she has,
// confirms both sides, and verifies the trade fails cleanly with neither
// side's state touched.
func TestTradeInsufficientGold(t *testing.T) {
	f := setupTradeTest(t)
	ctx := context.Background()

	doSend(t, f.connA, f.rA, OpTradeRequest, (&TradeRequestRequest{CharacterName: "Aria", TargetName: "Bram"}).Encode())
	f.connB.SetReadDeadline(time.Now().Add(2 * time.Second))
	proto.Read(f.rB, nil, nil) // invite

	doSend(t, f.connB, f.rB, OpTradeRespond, (&TradeRespondRequest{CharacterName: "Bram", RequesterName: "Aria", Accept: true}).Encode())
	f.connB.SetReadDeadline(time.Now().Add(2 * time.Second))
	proto.Read(f.rB, nil, nil) // started
	f.connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	proto.Read(f.rA, nil, nil) // started

	// Aria offers way more gold than StartingGold.
	doSend(t, f.connA, f.rA, OpTradeSetOffer, (&TradeSetOfferRequest{CharacterName: "Aria", Offer: TradeOffer{Gold: int64(character.StartingGold) * 100, ItemSlot: -1}}).Encode())
	f.connB.SetReadDeadline(time.Now().Add(2 * time.Second))
	proto.Read(f.rB, nil, nil) // offer updated

	doSend(t, f.connB, f.rB, OpTradeSetOffer, (&TradeSetOfferRequest{CharacterName: "Bram", Offer: TradeOffer{Gold: 0, ItemSlot: -1}}).Encode())
	f.connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	proto.Read(f.rA, nil, nil) // offer updated

	doSend(t, f.connA, f.rA, OpTradeConfirm, (&TradeConfirmRequest{CharacterName: "Aria"}).Encode())
	doSend(t, f.connB, f.rB, OpTradeConfirm, (&TradeConfirmRequest{CharacterName: "Bram"}).Encode())

	f.connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	cancelledA, err := proto.Read(f.rA, nil, nil)
	if err != nil || cancelledA.Opcode != OpTradeCancelled {
		t.Fatalf("reading Aria's OpTradeCancelled: opcode=%v err=%v", cancelledA, err)
	}
	f.connB.SetReadDeadline(time.Now().Add(2 * time.Second))
	cancelledB, err := proto.Read(f.rB, nil, nil)
	if err != nil || cancelledB.Opcode != OpTradeCancelled {
		t.Fatalf("reading Bram's OpTradeCancelled: opcode=%v err=%v", cancelledB, err)
	}

	list, err := f.chars.ListByAccount(ctx, 1)
	if err != nil {
		t.Fatalf("ListByAccount(1): %v", err)
	}
	if list[0].Gold != int64(character.StartingGold) {
		t.Fatalf("Aria's gold should be untouched: got %d, want %d", list[0].Gold, character.StartingGold)
	}
}

// TestTradeRefusesWhenRecipientIsFull closes the gap executeTrade's own comment
// used to describe: items left both givers' inventories before anything checked
// whether the recipients could hold them, so a full recipient meant the item was
// destroyed rather than returned.
//
// The engine refuses first -- its trade handler counts the partner's empty slots
// and returns 0x1836 NOT_ENOUGH_OPPONENT_INV_SPACE -- and this is that rule. The
// test asserts the part that matters: after a refusal, the giver STILL HAS the
// item.
func TestTradeRefusesWhenRecipientIsFull(t *testing.T) {
	ctx := context.Background()
	chars := character.NewMemStore()
	giver, _ := chars.Create(ctx, 1, "Giver")
	taker, _ := chars.Create(ctx, 2, "Taker")

	inv := inventory.NewMemStore(nil)
	if err := inv.AddItem(ctx, giver.ID, 4842, 1); err != nil {
		t.Fatalf("seeding the giver: %v", err)
	}
	// Fill every one of the taker's slots with a distinct non-stacking item.
	for i := 0; i < inventory.SlotsPerCharacter; i++ {
		if err := inv.AddItem(ctx, taker.ID, int64(9000+i), 1); err != nil {
			t.Fatalf("filling the taker at slot %d: %v", i, err)
		}
	}
	occupied, _ := inv.List(ctx, taker.ID)
	if len(occupied) != inventory.SlotsPerCharacter {
		t.Fatalf("the taker holds %d slots, wanted a full %d", len(occupied), inventory.SlotsPerCharacter)
	}

	sess := &trade.Session{
		A:      trade.Member{CharacterID: giver.ID, Name: "Giver"},
		B:      trade.Member{CharacterID: taker.ID, Name: "Taker"},
		OfferA: trade.Offer{ItemSlot: 0, Quantity: 1},
		OfferB: trade.Offer{ItemSlot: -1},
	}

	_, _, failReason, err := executeTrade(ctx, chars, inv, nil, sess)
	if err != nil {
		t.Fatalf("a full recipient is an orderly failure, not an error: %v", err)
	}
	if failReason == "" {
		t.Fatal("the trade was allowed into a full inventory")
	}

	// The whole point: nothing moved.
	after, err := inv.List(ctx, giver.ID)
	if err != nil {
		t.Fatalf("listing the giver: %v", err)
	}
	if len(after) != 1 || after[0].ItemID != 4842 {
		t.Errorf("the giver lost the item to a refused trade: %+v", after)
	}
}

// TestTradeRefusesUntradeableItem covers the engine's first check on an offer:
// its trade handler calls CanTrade (vtable slot 49) and returns 0x183a
// UIIT_MSG_STRGERR_CANNOT_BE_TRADED when the flag is clear.
//
// This matters more than it looks. In a real itemdata the flag is clear on every
// starter item (all 52 `_A_DEF` rows) and every quest item (all 558 `ITEM_QNO_`
// rows), so without it srrevamp let players trade away gear the real game pins
// to the character.
func TestTradeRefusesUntradeableItem(t *testing.T) {
	ctx := context.Background()
	chars := character.NewMemStore()
	giver, _ := chars.Create(ctx, 1, "Giver")
	taker, _ := chars.Create(ctx, 2, "Taker")

	inv := inventory.NewMemStore(nil)
	const boundItem = 3632 // a starter sword: CanTrade is clear on every _A_DEF row
	if err := inv.AddItem(ctx, giver.ID, boundItem, 1); err != nil {
		t.Fatalf("seeding the giver: %v", err)
	}

	items := refdata.NewMemStore()
	items.ImportItems(ctx, []refdata.Item{{ID: boundItem, CanTrade: false}})

	sess := &trade.Session{
		A:      trade.Member{CharacterID: giver.ID, Name: "Giver"},
		B:      trade.Member{CharacterID: taker.ID, Name: "Taker"},
		OfferA: trade.Offer{ItemSlot: 0, Quantity: 1},
		OfferB: trade.Offer{ItemSlot: -1},
	}

	_, _, failReason, err := executeTrade(ctx, chars, inv, items, sess)
	if err != nil {
		t.Fatalf("a bound item is an orderly refusal, not an error: %v", err)
	}
	if failReason == "" {
		t.Fatal("a non-tradeable item was traded")
	}
	after, _ := inv.List(ctx, giver.ID)
	if len(after) != 1 || after[0].ItemID != boundItem {
		t.Errorf("the giver lost a bound item to a refused trade: %+v", after)
	}

	// And a tradeable item still goes through the same path.
	items2 := refdata.NewMemStore()
	items2.ImportItems(ctx, []refdata.Item{{ID: boundItem, CanTrade: true}})
	if _, _, reason, err := executeTrade(ctx, chars, inv, items2, sess); err != nil || reason != "" {
		t.Errorf("a tradeable item was refused: reason=%q err=%v", reason, err)
	}
}

// TestTradeOfferRefusesUntradeableItem drives the offer-time CanTrade check over
// the wire. CGStorage::TradeOfferItem (`0x00526910`) returns 0x183a
// UIIT_MSG_STRGERR_CANNOT_BE_TRADED from the offer itself, before
// TradeMgr::OfferItemToPartner runs, so the refused item is never recorded and
// the partner never sees it. Before round 482 srrevamp accepted the offer,
// showed it to the partner, and only failed the whole trade at the final
// confirm.
func TestTradeOfferRefusesUntradeableItem(t *testing.T) {
	ctx := context.Background()
	items := refdata.NewMemStore()
	items.ImportItems(ctx, []refdata.Item{
		{ID: 100, CanTrade: false}, // Aria's slot 0: bound, like every _A_DEF row
		{ID: 200, CanTrade: true},  // Bram's slot 0: an ordinary stack of 5
	})
	f := setupTradeTestWithItems(t, items)
	startTrade(t, f)

	offerBound := (&TradeSetOfferRequest{CharacterName: "Aria", Offer: TradeOffer{Gold: 50, ItemSlot: 0, Quantity: 1}}).Encode()

	// Aria offers her bound item: refused at once, nothing stored.
	resp := doSend(t, f.connA, f.rA, OpTradeSetOffer, offerBound)
	if resp.Opcode != OpTradeOfferResult {
		t.Fatalf("Aria's answer: opcode 0x%04X, want OpTradeOfferResult", resp.Opcode)
	}
	if or, err := DecodeTradeOfferResult(resp.Data); err != nil || or.OK || !strings.Contains(or.Reason, "cannot be traded") {
		t.Fatalf("an untradeable item was accepted into the offer: err=%v result=%+v", err, or)
	}
	// SessionOf hands back the live *trade.Session and its fields are read
	// here without the hub's lock. That is safe only because every request
	// above has been answered and nothing else is sending; a test that reads
	// them while traffic is in flight needs a locked snapshot instead.
	ts, ok := f.trades.SessionOf(f.ariaID)
	if !ok {
		t.Fatal("the refused offer ended the trade")
	}
	if ts.OfferA.ItemSlot != -1 || ts.OfferA.Gold != 0 {
		t.Fatalf("the refused offer was stored: %+v", ts.OfferA)
	}

	// Bram hears nothing about it: the next packet he reads after his own
	// offer is that offer's result, not an OpTradeOfferUpdated for Aria's item.
	resp = doSend(t, f.connB, f.rB, OpTradeSetOffer, (&TradeSetOfferRequest{CharacterName: "Bram", Offer: TradeOffer{ItemSlot: 0, Quantity: 5}}).Encode())
	if resp.Opcode != OpTradeOfferResult {
		t.Fatalf("Bram's next packet: opcode 0x%04X, want his OpTradeOfferResult (Aria's refused item reached him)", resp.Opcode)
	}
	if or, err := DecodeTradeOfferResult(resp.Data); err != nil || !or.OK {
		t.Fatalf("Bram's tradeable offer was refused: err=%v result=%+v", err, or)
	}

	// A tradeable item still goes through, and reaches the partner.
	f.connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	updated, err := proto.Read(f.rA, nil, nil)
	if err != nil || updated.Opcode != OpTradeOfferUpdated {
		t.Fatalf("reading Aria's OpTradeOfferUpdated: pkt=%v err=%v", updated, err)
	}
	if ou, err := DecodeTradeOfferUpdated(updated.Data); err != nil || ou.Offer.ItemSlot != 0 || ou.Offer.Quantity != 5 {
		t.Fatalf("unexpected offer update on Aria's side: %+v (err=%v)", ou, err)
	}

	// A refusal leaves the partner's confirmation standing: SetOffer, which
	// voids both confirmations, is never reached.
	resp = doSend(t, f.connB, f.rB, OpTradeConfirm, (&TradeConfirmRequest{CharacterName: "Bram"}).Encode())
	if cr, err := DecodeTradeConfirmResult(resp.Data); err != nil || !cr.OK {
		t.Fatalf("Bram's confirm failed: err=%v result=%+v", err, cr)
	}
	resp = doSend(t, f.connA, f.rA, OpTradeSetOffer, offerBound)
	if or, err := DecodeTradeOfferResult(resp.Data); err != nil || or.OK {
		t.Fatalf("the retried untradeable offer was accepted: err=%v result=%+v", err, or)
	}
	if ts, _ := f.trades.SessionOf(f.ariaID); !ts.ConfirmedB || ts.OfferA.ItemSlot != -1 {
		t.Fatalf("a refused offer changed the trade: confirmedB=%v offerA=%+v", ts.ConfirmedB, ts.OfferA)
	}

	// A gold-only offer has no item to check and is accepted.
	resp = doSend(t, f.connA, f.rA, OpTradeSetOffer, (&TradeSetOfferRequest{CharacterName: "Aria", Offer: TradeOffer{Gold: 50, ItemSlot: -1}}).Encode())
	if or, err := DecodeTradeOfferResult(resp.Data); err != nil || !or.OK {
		t.Fatalf("a gold-only offer was refused: err=%v result=%+v", err, or)
	}
	f.connB.SetReadDeadline(time.Now().Add(2 * time.Second))
	updated, err = proto.Read(f.rB, nil, nil)
	if err != nil || updated.Opcode != OpTradeOfferUpdated {
		t.Fatalf("reading Bram's OpTradeOfferUpdated: pkt=%v err=%v", updated, err)
	}
	if ou, err := DecodeTradeOfferUpdated(updated.Data); err != nil || ou.Offer.Gold != 50 || ou.Offer.ItemSlot != -1 {
		t.Fatalf("unexpected offer update on Bram's side: %+v (err=%v)", ou, err)
	}
}

// TestOfferTradeFlagRefusal pins offerTradeFlagRefusal's cases: only an item
// the reference data says is untradeable is refused (0x183a in
// CGStorage::TradeOfferItem, `0x00526910`); every "cannot tell" case refuses
// nothing and leaves validation to executeTrade.
func TestOfferTradeFlagRefusal(t *testing.T) {
	ctx := context.Background()
	const charID = 7
	inv := inventory.NewMemStore(nil)
	if err := inv.AddItem(ctx, charID, 3632, 1); err != nil { // slot 0: bound
		t.Fatalf("seeding slot 0: %v", err)
	}
	if err := inv.AddItem(ctx, charID, 4842, 1); err != nil { // slot 1: tradeable
		t.Fatalf("seeding slot 1: %v", err)
	}
	if err := inv.AddItem(ctx, charID, 5555, 1); err != nil { // slot 2: not in the tables
		t.Fatalf("seeding slot 2: %v", err)
	}
	items := refdata.NewMemStore()
	items.ImportItems(ctx, []refdata.Item{{ID: 3632, CanTrade: false}, {ID: 4842, CanTrade: true}})

	for _, tc := range []struct {
		name   string
		inv    inventory.Store
		items  ItemLookup
		offer  trade.Offer
		refuse bool
	}{
		{"no reference data", inv, nil, trade.Offer{ItemSlot: 0, Quantity: 1}, false},
		{"no inventory", nil, items, trade.Offer{ItemSlot: 0, Quantity: 1}, false},
		{"no item offered", inv, items, trade.Offer{Gold: 10, ItemSlot: -1}, false},
		{"item the tables do not know", inv, items, trade.Offer{ItemSlot: 2, Quantity: 1}, false},
		{"empty slot", inv, items, trade.Offer{ItemSlot: 9, Quantity: 1}, false},
		{"more than the slot holds", inv, items, trade.Offer{ItemSlot: 0, Quantity: 2}, false},
		{"CanTrade clear", inv, items, trade.Offer{ItemSlot: 0, Quantity: 1}, true},
		{"CanTrade set", inv, items, trade.Offer{ItemSlot: 1, Quantity: 1}, false},
	} {
		reason, err := offerTradeFlagRefusal(ctx, tc.inv, tc.items, charID, tc.offer)
		if err != nil {
			t.Errorf("%s: unexpected error %v", tc.name, err)
			continue
		}
		if tc.refuse && !strings.Contains(reason, "cannot be traded") {
			t.Errorf("%s: reason %q, want a cannot-be-traded refusal", tc.name, reason)
		}
		if !tc.refuse && reason != "" {
			t.Errorf("%s: refused with %q, want no refusal", tc.name, reason)
		}
	}

	// A lookup failure that is not "no such item" is a store error, not a
	// silent pass.
	if _, err := offerTradeFlagRefusal(ctx, inv, stubCombatItems{}, charID, trade.Offer{ItemSlot: 0, Quantity: 1}); err == nil {
		t.Error("a failing item lookup was swallowed")
	}
}
