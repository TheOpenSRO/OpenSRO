package session

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/grounditem"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// Round 743's review, F1: four party members picking up gold piles at once.
// Each pick credits every member's share in one transaction, the picker's
// share first in the message order. Credited in that order, two members'
// picks locked each other's rows in opposite orders and deadlocked: the
// review measured 59 of 200 picks failed and a worst pick of 15 s. Credited
// in character-id order (sharesByCharacter), none may fail or stall.
func TestPartyGoldPickupsDoNotDeadlock(t *testing.T) {
	ctx := context.Background()
	db, err := txn.OpenPool(inventoryTestDSN(), 32)
	if err != nil {
		t.Fatalf("OpenPool: %v", err)
	}
	defer db.Close()
	chars, err := character.NewSQLStore(db)
	if err != nil {
		t.Fatalf("character store: %v", err)
	}
	if _, err := db.Exec(`TRUNCATE characters RESTART IDENTITY CASCADE; TRUNCATE economy_ops`); err != nil {
		t.Fatalf("truncating: %v", err)
	}
	var party []int64
	for i := 0; i < 4; i++ {
		c, err := chars.Create(ctx, int64(i+1), fmt.Sprintf("Member%d", i))
		if err != nil {
			t.Fatalf("creating a member: %v", err)
		}
		party = append(party, c.ID)
	}
	runner := txn.For(chars)
	const picksEach = 50
	var wg sync.WaitGroup
	var mu sync.Mutex
	var failed int
	var worst time.Duration
	for p, picker := range party {
		wg.Add(1)
		go func(p int, picker int64) {
			defer wg.Done()
			// The picker first, then the party in its own order, as splitGold
			// builds the shares.
			shares := []goldShare{{picker, 10}}
			for _, m := range party {
				if m != picker {
					shares = append(shares, goldShare{m, 10})
				}
			}
			for i := 0; i < picksEach; i++ {
				it := grounditem.Item{ItemID: grounditem.GoldItemID, Quantity: 40, Gold: true, Serial: -int64(1_000_000 + p*picksEach + i)}
				start := time.Now()
				err := applyPickup(ctx, runner, chars, nil, it, pickupLedgerKey(it), picker, shares)
				d := time.Since(start)
				mu.Lock()
				if err != nil {
					failed++
				}
				if d > worst {
					worst = d
				}
				mu.Unlock()
			}
		}(p, picker)
	}
	wg.Wait()
	t.Logf("%d picks: %d failed, worst %s", len(party)*picksEach, failed, worst)
	if failed != 0 || worst > 500*time.Millisecond {
		t.Fatalf("party gold pick-ups: %d failed, worst %s; want none failed and none past 0.5 s", failed, worst)
	}
	for _, id := range party {
		c, _ := chars.GetByID(ctx, id)
		if want := int64(character.StartingGold) + int64(len(party)*picksEach*10); c.Gold != want {
			t.Fatalf("member %d holds %d, want %d", id, c.Gold, want)
		}
	}
}

// failingTake is the bag store with every take failing as a store failure
// would (not an orderly refusal).
type failingTake struct{ *inventory.SQLStore }

func (failingTake) TakeItem(context.Context, int64, int, int, int64) (int64, inventory.Instance, error) {
	return 0, inventory.Instance{}, errors.New("injected: the connection dropped")
}

// readOpcode reads packets until one with the opcode arrives.
func readOpcode(t *testing.T, f *tradeTestFixture, side string, opcode uint16) *proto.Packet {
	t.Helper()
	conn, r := f.connA, f.rA
	if side == "B" {
		conn, r = f.connB, f.rB
	}
	for i := 0; i < 6; i++ {
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		p, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("%s waiting for 0x%04x: %v", side, opcode, err)
		}
		if p.Opcode == opcode {
			return p
		}
	}
	t.Fatalf("%s never got 0x%04x", side, opcode)
	return nil
}

// offerSwordAndConfirm has Aria offer her sword and confirm, then Bram
// confirm, which executes the trade.
func offerSwordAndConfirm(t *testing.T, f *tradeTestFixture) {
	t.Helper()
	startTrade(t, f)
	resp := doSend(t, f.connA, f.rA, OpTradeSetOffer, (&TradeSetOfferRequest{CharacterName: "Aria", Offer: TradeOffer{ItemSlot: 0, Quantity: 1}}).Encode())
	if or, err := DecodeTradeOfferResult(resp.Data); err != nil || !or.OK {
		t.Fatalf("Aria's offer: %+v %v", or, err)
	}
	readOpcode(t, f, "B", OpTradeOfferUpdated)
	if cr, err := DecodeTradeConfirmResult(doSend(t, f.connA, f.rA, OpTradeConfirm, (&TradeConfirmRequest{CharacterName: "Aria"}).Encode()).Data); err != nil || !cr.OK {
		t.Fatalf("Aria's confirm: %+v %v", cr, err)
	}
	if cr, err := DecodeTradeConfirmResult(doSend(t, f.connB, f.rB, OpTradeConfirm, (&TradeConfirmRequest{CharacterName: "Bram"}).Encode()).Data); err != nil || !cr.OK {
		t.Fatalf("Bram's confirm: %+v %v", cr, err)
	}
}

// Round 743's review, F2: an execution whose commit is answered with an
// error (a lost acknowledgement). Before the fix the executor's session was
// closed and the partner heard nothing, stuck in the window. Now the ledger
// says the trade applied, and both sides get OpTradeCompleted, sessions open.
func TestTradeExecutionErrorAfterCommitCompletesBothSides(t *testing.T) {
	f := setupTradeTest(t)
	restore := txn.SetAfterCommitHookForTest(func(context.Context) error {
		return errors.New("injected: the commit's answer was lost")
	})
	defer restore()
	offerSwordAndConfirm(t, f)
	for _, side := range []string{"A", "B"} {
		tc, err := DecodeTradeCompleted(readOpcode(t, f, side, OpTradeCompleted).Data)
		if err != nil {
			t.Fatalf("%s's TradeCompleted: %v", side, err)
		}
		if side == "B" && tc.ReceivedItemID != 100 {
			t.Fatalf("Bram's TradeCompleted %+v, want the sword", tc)
		}
	}
	restore()
	if f.trades.Busy(f.ariaID) || f.trades.Busy(f.bramID) {
		t.Fatal("the trade is still open")
	}
	// Both sessions are still served.
	resp := doSend(t, f.connB, f.rB, OpTradeRequest, (&TradeRequestRequest{CharacterName: "Bram", TargetName: "Aria"}).Encode())
	if rr, err := DecodeTradeRequestResult(resp.Data); err != nil || !rr.OK {
		t.Fatalf("Bram's next request: %+v %v", rr, err)
	}
}

// The same with a failure before the commit: nothing moved, both sides get
// OpTradeCancelled, and the trade is closed.
func TestTradeExecutionErrorCancelsBothSides(t *testing.T) {
	f := setupTradeTestWrapped(t, nil, nil, func(s *inventory.SQLStore) inventory.Store { return failingTake{s} })
	offerSwordAndConfirm(t, f)
	readOpcode(t, f, "A", OpTradeCancelled)
	readOpcode(t, f, "B", OpTradeCancelled)
	if f.trades.Busy(f.ariaID) || f.trades.Busy(f.bramID) {
		t.Fatal("the trade is still open")
	}
	list, _ := f.inv.List(context.Background(), f.ariaID)
	if len(list) != 1 || list[0].ItemID != 100 {
		t.Fatalf("Aria's bag after a failed trade: %+v, want her sword", list)
	}
}
