package session

import (
	"bufio"
	"context"
	"database/sql"
	"errors"
	"net"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/testdb"
	"github.com/OpenSRO/OpenSRO/server/internal/trade"
)

// Round 743: the trade duplication the architecture spec (round 742, 3.1)
// INFERRED by reading, reproduced against real Postgres.
//
// The path: Aria offers her one sword and confirms. Bram confirms, and his
// handler starts executing the trade. Aria's client sends its confirm again
// while that runs. trade.Hub.Confirm had no "executing" latch, so the resent
// confirm answered both-confirmed a second time and a second executeTrade
// ran beside the first. Both removed the sword (RemoveItem read the quantity,
// then deleted, with no row lock and no affected-row check, so both
// "succeeded"), and both credited Bram: two swords from one.
//
// To make the interleaving certain rather than lucky, the test holds the
// sword's row lock from its own connection until both executions are blocked
// on it (or until the second has visibly not started), then lets go.
func TestTradeResentConfirmDuplicatesItem(t *testing.T) {
	f := setupTradeTest(t)
	ctx := context.Background()
	// Bram already holds one of the item (it stacks in this fixture), so
	// both credits land as a merge into his stack rather than racing for
	// the same free slot -- the race the duplication needs to complete.
	if err := f.inv.AddItem(ctx, f.bramID, 100, 1); err != nil {
		t.Fatalf("seeding Bram's stack: %v", err)
	}
	startTrade(t, f)

	resp := doSend(t, f.connA, f.rA, OpTradeSetOffer, (&TradeSetOfferRequest{CharacterName: "Aria", Offer: TradeOffer{ItemSlot: 0, Quantity: 1}}).Encode())
	if or, err := DecodeTradeOfferResult(resp.Data); err != nil || !or.OK {
		t.Fatalf("Aria's offer failed: err=%v result=%+v", err, or)
	}
	f.connB.SetReadDeadline(time.Now().Add(2 * time.Second))
	if pkt, err := proto.Read(f.rB, nil, nil); err != nil || pkt.Opcode != OpTradeOfferUpdated {
		t.Fatalf("reading Bram's OpTradeOfferUpdated: %v %v", pkt, err)
	}
	resp = doSend(t, f.connA, f.rA, OpTradeConfirm, (&TradeConfirmRequest{CharacterName: "Aria"}).Encode())
	if cr, err := DecodeTradeConfirmResult(resp.Data); err != nil || !cr.OK {
		t.Fatalf("Aria's confirm failed: err=%v result=%+v", err, cr)
	}

	db, err := sql.Open("pgx", inventoryTestDSN())
	if err != nil {
		t.Fatalf("opening the race connection: %v", err)
	}
	defer db.Close()
	hold, err := testdb.HoldRow(ctx, db, `SELECT 1 FROM inventory_slots WHERE character_id = $1 AND slot = 0 FOR UPDATE`, f.ariaID)
	if err != nil {
		t.Fatalf("holding the sword's row: %v", err)
	}
	released := false
	defer func() {
		if !released {
			hold.Rollback()
		}
	}()

	// Bram confirms: his handler executes the trade and blocks on the row.
	writeOnly(t, f.connB, OpTradeConfirm, (&TradeConfirmRequest{CharacterName: "Bram"}).Encode())
	if n, err := testdb.WaitLockWaiters(ctx, db, 1, nil, 5*time.Second); err != nil || n < 1 {
		t.Fatalf("Bram's execution never reached the sword's row (waiters %d, err %v)", n, err)
	}
	// Aria's client sends its confirm again while that execution runs.
	writeOnly(t, f.connA, OpTradeConfirm, (&TradeConfirmRequest{CharacterName: "Aria"}).Encode())
	n, err := testdb.WaitLockWaiters(ctx, db, 2, nil, 2*time.Second)
	if err != nil {
		t.Fatalf("counting waiters: %v", err)
	}
	t.Logf("executions blocked on the sword's row: %d", n)
	if err := hold.Commit(); err != nil {
		t.Fatalf("releasing the row: %v", err)
	}
	released = true
	drainUntilQuiet(f.connA, f.rA, 700*time.Millisecond)
	drainUntilQuiet(f.connB, f.rB, 700*time.Millisecond)

	swords := func(characterID int64) int {
		slots, err := f.inv.List(ctx, characterID)
		if err != nil {
			t.Fatalf("listing %d's bag: %v", characterID, err)
		}
		n := 0
		for _, s := range slots {
			if s.ItemID == 100 {
				n += s.Quantity
			}
		}
		return n
	}
	if a, b := swords(f.ariaID), swords(f.bramID); a != 0 || b != 2 {
		t.Fatalf("after one trade of one sword: Aria holds %d, Bram holds %d; want 0 and 2 (his own and the traded one)", a, b)
	}
}

// writeOnly sends one packet without waiting for an answer.
func writeOnly(t *testing.T, c net.Conn, opcode uint16, data []byte) {
	t.Helper()
	if err := proto.Write(c, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
		t.Fatalf("Write: %v", err)
	}
}

// drainUntilQuiet reads and discards packets until none arrives for quiet.
func drainUntilQuiet(c net.Conn, r *bufio.Reader, quiet time.Duration) {
	for {
		c.SetReadDeadline(time.Now().Add(quiet))
		if _, err := proto.Read(r, nil, nil); err != nil {
			return
		}
	}
}

// failingCredit is the bag store with one credit refused: AddItemInstance to
// failFor errors, as a lost connection or a full disk would after the
// giver's removal has committed.
type failingCredit struct {
	*inventory.SQLStore
	failFor int64
}

func (f failingCredit) AddItemInstance(ctx context.Context, characterID, itemID int64, quantity int, inst inventory.Instance) error {
	if characterID == f.failFor {
		return errors.New("injected: the credit's write failed")
	}
	return f.SQLStore.AddItemInstance(ctx, characterID, itemID, quantity, inst)
}

// TestTradeFailedCreditLosesNothing: the spec's other half of 3.1. Gold and
// items went through separate commits, so a failure after the debits left
// the giver without the sword and the gold, and the receiver with the gold
// but no sword -- value destroyed. A trade must be all or nothing.
func TestTradeFailedCreditLosesNothing(t *testing.T) {
	ctx := context.Background()
	db, err := sql.Open("pgx", inventoryTestDSN())
	if err != nil {
		t.Fatalf("opening: %v", err)
	}
	defer db.Close()
	chars, err := character.OpenSQLStore(inventoryTestDSN())
	if err != nil {
		t.Fatalf("character.OpenSQLStore: %v", err)
	}
	defer chars.Close()
	if _, err := db.ExecContext(ctx, `TRUNCATE TABLE characters RESTART IDENTITY CASCADE`); err != nil {
		t.Fatalf("truncating characters: %v", err)
	}
	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), stubCombatItems{100: {ID: 100}})
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v", err)
	}
	defer inv.Close()
	if err := inv.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating: %v", err)
	}
	aria, _ := chars.Create(ctx, 1, "Aria")
	bram, _ := chars.Create(ctx, 2, "Bram")
	if err := inv.AddItem(ctx, aria.ID, 100, 1); err != nil {
		t.Fatalf("seeding: %v", err)
	}

	sess := &trade.Session{
		A: trade.Member{CharacterID: aria.ID, Name: "Aria"}, B: trade.Member{CharacterID: bram.ID, Name: "Bram"},
		OfferA: trade.Offer{Gold: 50, ItemSlot: 0, Quantity: 1}, OfferB: trade.Offer{ItemSlot: -1},
		ConfirmedA: true, ConfirmedB: true,
	}
	_, _, reason, err := executeTrade(ctx, chars, failingCredit{inv, bram.ID}, nil, sess)
	t.Logf("executeTrade: reason %q, err %v", reason, err)

	a, _ := chars.GetByID(ctx, aria.ID)
	b, _ := chars.GetByID(ctx, bram.ID)
	ariaBag, _ := inv.List(ctx, aria.ID)
	bramBag, _ := inv.List(ctx, bram.ID)
	if a.Gold != character.StartingGold || b.Gold != character.StartingGold || len(ariaBag) != 1 || len(bramBag) != 0 {
		t.Fatalf("a failed trade moved value: Aria gold %d bag %+v, Bram gold %d bag %+v; want both purses at %d and the sword still Aria's",
			a.Gold, ariaBag, b.Gold, bramBag, character.StartingGold)
	}
}
