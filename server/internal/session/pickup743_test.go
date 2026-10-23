package session

import (
	"bufio"
	"context"
	"database/sql"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/grounditem"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 743: the pick-up is one transaction with the ground item's ledger
// claim. These run against real Postgres.

func openPickupStores(t *testing.T) (*sql.DB, *inventory.SQLStore) {
	t.Helper()
	db, err := txn.OpenPool(inventoryTestDSN(), 8)
	if err != nil {
		t.Fatalf("OpenPool: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	inv, err := inventory.NewSQLStoreOwned(db, stubCombatItems{100: {ID: 100}}, inventory.DefaultTable, inventory.DefaultOwnerColumn)
	if err != nil {
		t.Fatalf("inventory store: %v", err)
	}
	if _, err := db.Exec(`TRUNCATE inventory_slots; TRUNCATE economy_ops`); err != nil {
		t.Fatalf("truncating: %v", err)
	}
	return db, inv
}

func heldOf(t *testing.T, inv inventory.Store, owner, itemID int64) int {
	t.Helper()
	list, err := inv.List(context.Background(), owner)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	n := 0
	for _, s := range list {
		if s.ItemID == itemID {
			n += s.Quantity
		}
	}
	return n
}

// Picks of one ground item that all reach the grant -- a retry, a second
// process holding a stale copy -- grant it once.
func TestPickupLedgerGrantsOnce(t *testing.T) {
	ctx := context.Background()
	db, inv := openPickupStores(t)
	chars := character.NewMemStore()
	serials := &txn.Serials{DB: db}
	serial, err := serials.Next(ctx)
	if err != nil {
		t.Fatalf("a serial: %v", err)
	}
	it := grounditem.Item{ID: 7, ItemID: 100, Quantity: 3, Serial: serial}
	runner := txn.For(chars, inv)
	key := pickupLedgerKey(it)
	var wg sync.WaitGroup
	errs := make([]error, 6)
	for i := range errs {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			errs[i] = applyPickup(ctx, runner, chars, inv, it, key, 1, nil)
		}(i)
	}
	wg.Wait()
	granted := 0
	for _, err := range errs {
		switch {
		case err == nil:
			granted++
		case errors.Is(err, txn.ErrAlreadyApplied):
		default:
			t.Fatalf("a pick: %v", err)
		}
	}
	if granted != 1 || heldOf(t, inv, 1, 100) != 3 {
		t.Fatalf("%d grants, %d held; want 1 grant of the 3", granted, heldOf(t, inv, 1, 100))
	}
}

// A gold split is every share or none.
func TestPickupGoldSplitIsAllOrNothing(t *testing.T) {
	ctx := context.Background()
	chars := character.NewMemStore()
	a, _ := chars.Create(ctx, 1, "Aria")
	it := grounditem.Item{ID: 9, ItemID: grounditem.GoldItemID, Quantity: 30, Gold: true}
	shares := []goldShare{{a.ID, 10}, {a.ID, 10}, {404, 10}} // the last member does not exist
	err := applyPickup(ctx, txn.Runner{}, chars, inventory.NewMemStore(nil), it, pickupLedgerKey(it), a.ID, shares)
	if err == nil {
		t.Fatal("a split with a failing share succeeded")
	}
	if c, _ := chars.GetByID(ctx, a.ID); c.Gold != character.StartingGold {
		t.Fatalf("a failed split paid %d", c.Gold-character.StartingGold)
	}
	if err := applyPickup(ctx, txn.Runner{}, chars, inventory.NewMemStore(nil), it, pickupLedgerKey(it), a.ID, shares[:2]); err != nil {
		t.Fatalf("the retried split: %v", err)
	}
	if c, _ := chars.GetByID(ctx, a.ID); c.Gold != character.StartingGold+20 {
		t.Fatalf("the split paid %d, want 20", c.Gold-character.StartingGold)
	}
}

// TestPickupCommitThenErrorIsNotPickableAgain: the grant commits but its
// answer is an error (a timeout between the commit and its acknowledgement).
// Before round 743 the handler released the item on any error, and the
// stack could be picked -- and granted -- again. Now the handler asks the
// ledger, answers the pick as done, and takes the item off the ground; and
// a stale copy of the same drop (as another process might hold) grants
// nothing.
func TestPickupCommitThenErrorIsNotPickableAgain(t *testing.T) {
	ctx := context.Background()
	db, inv := openPickupStores(t)
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	aria, _ := chars.Create(ctx, 1, "Aria")
	hub := world.NewHub()
	ground := grounditem.NewHub()
	serials := &txn.Serials{DB: db}
	var fixed int64
	ground.SetSerialSource(func() int64 {
		if fixed != 0 {
			return fixed
		}
		v, _ := serials.Next(ctx)
		return v
	})
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, nil, hub), GroundItemHandler(chars, hub, ground, inv, nil))
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)
	if lr, err := DecodeLoginResult(doSend(t, conn, r, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login: %+v %v", lr, err)
	}
	if ewr, err := DecodeEnterWorldResult(doSend(t, conn, r, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode()).Data); err != nil || !ewr.OK {
		t.Fatalf("enter world: %+v %v", ewr, err)
	}
	e, ok := hub.EntityByCharacterID(aria.ID)
	if !ok {
		t.Fatal("Aria is not in the world")
	}
	drop := ground.Drop(e.Zone, 100, 1, false, float32(e.Pos.X), float32(e.Pos.Y), float32(e.Pos.Z), aria.ID)
	if drop.Serial == 0 {
		t.Fatal("the drop has no serial")
	}

	failed := false
	restore := txn.SetAfterCommitHookForTest(func(context.Context) error {
		if failed {
			return nil
		}
		failed = true
		return errors.New("injected: the commit's answer was lost")
	})
	defer restore()
	pick := func(id int64) *PickUpResult {
		t.Helper()
		pkt := doSend(t, conn, r, OpPickUp, (&PickUpRequest{CharacterName: "Aria", GroundItemID: id}).Encode())
		for pkt.Opcode != OpPickUpResult {
			conn.SetReadDeadline(time.Now().Add(2 * time.Second))
			next, err := proto.Read(r, nil, nil)
			if err != nil {
				t.Fatalf("reading: %v", err)
			}
			pkt = next
		}
		pr, err := DecodePickUpResult(pkt.Data)
		if err != nil {
			t.Fatalf("decoding: %v", err)
		}
		return pr
	}
	if pr := pick(drop.ID); pr.Code != 0 || !failed {
		t.Fatalf("the pick whose answer was lost: %+v (hook fired %v), want it answered as done", pr, failed)
	}
	if _, still := ground.Get(drop.ID); still {
		t.Fatal("the granted item is still on the ground")
	}
	if pr := pick(drop.ID); pr.Code != grounditem.ErrNotThere {
		t.Fatalf("picking it again: %+v, want 3 (not there)", pr)
	}

	// A stale copy of the same drop: the ledger refuses it.
	fixed = drop.Serial
	stale := ground.Drop(e.Zone, 100, 1, false, float32(e.Pos.X), float32(e.Pos.Y), float32(e.Pos.Z), aria.ID)
	if pr := pick(stale.ID); pr.Code != grounditem.ErrNotThere {
		t.Fatalf("picking a stale copy: %+v, want 3", pr)
	}
	if _, still := ground.Get(stale.ID); still {
		t.Fatal("the stale copy is still on the ground")
	}
	if n := heldOf(t, inv, aria.ID, 100); n != 1 {
		t.Fatalf("Aria holds %d of the one dropped item", n)
	}
}
