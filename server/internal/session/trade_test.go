package session

import (
	"bufio"
	"context"
	"net"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
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
	chars        *character.MemStore
	inv          *inventory.SQLStore
	connA, connB net.Conn
	rA, rB       *bufio.Reader
}

func setupTradeTest(t *testing.T) *tradeTestFixture {
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

	items := stubCombatItems{100: {ID: 100, PhysAttackMax: 30}, 200: {ID: 200, PhysAttackMax: 10}}
	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), items)
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
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, nil, hub), TradeHandler(chars, inv, hub, trades))

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

	return &tradeTestFixture{chars: chars, inv: inv, connA: connA, connB: connB, rA: rA, rB: rB}
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
	// Both sides get OpTradeStarted.
	f.connB.SetReadDeadline(time.Now().Add(2 * time.Second))
	if startedPkt, err := proto.Read(f.rB, nil, nil); err != nil || startedPkt.Opcode != OpTradeStarted {
		t.Fatalf("reading Bram's OpTradeStarted: opcode=%v err=%v", startedPkt, err)
	}
	f.connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	if startedPkt, err := proto.Read(f.rA, nil, nil); err != nil || startedPkt.Opcode != OpTradeStarted {
		t.Fatalf("reading Aria's OpTradeStarted: opcode=%v err=%v", startedPkt, err)
	}

	// Aria offers 50 gold + her weapon (slot 0, qty 1).
	resp = doSend(t, f.connA, f.rA, OpTradeSetOffer, (&TradeSetOfferRequest{CharacterName: "Aria", Offer: TradeOffer{Gold: 50, ItemSlot: 0, Quantity: 1}}).Encode())
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
