package inventory

import (
	"context"
	"database/sql"
	"sync"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/testdb"
)

// Round 743: two identical store operations racing on one slot must have one
// effect. Each test holds the slot's row lock from a third connection, starts
// both racers, waits until Postgres shows both blocked, then lets them go --
// so both have read the slot before either writes, every run.

func openRaceDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("pgx", testDSN())
	if err != nil {
		t.Fatalf("opening the race connection: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

// raceTwice runs op twice at once while the row lockQuery names is held, and
// returns both results once both have finished.
func raceTwice(t *testing.T, db *sql.DB, lockQuery string, args []any, op func() error) [2]error {
	t.Helper()
	ctx := context.Background()
	hold, err := testdb.HoldRow(ctx, db, lockQuery, args...)
	if err != nil {
		t.Fatalf("holding the row: %v", err)
	}
	var errs [2]error
	var wg sync.WaitGroup
	done := make(chan struct{})
	for i := range errs {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			errs[i] = op()
		}(i)
	}
	go func() { wg.Wait(); close(done) }()
	if n, err := testdb.WaitLockWaiters(ctx, db, 2, done, 5*time.Second); err != nil {
		t.Fatalf("waiting for the racers: %v", err)
	} else {
		t.Logf("racers blocked on a lock: %d", n)
	}
	if err := hold.Commit(); err != nil {
		t.Fatalf("releasing the row: %v", err)
	}
	<-done
	return errs
}

// TestSQLRemoveItemRacedRemovesOnce: two removals of the only sword in a slot.
// Before round 743 RemoveItem read the quantity, then deleted, with no row
// lock and no affected-row check, so BOTH answered nil -- and a caller that
// credits on success (the trade, the sell) paid out twice for one item.
func TestSQLRemoveItemRacedRemovesOnce(t *testing.T) {
	store := openTestSQLStore(t, stubMaxStacks{})
	ctx := context.Background()
	if err := store.AddItem(ctx, 1, 100, 1); err != nil {
		t.Fatalf("seeding: %v", err)
	}
	db := openRaceDB(t)
	errs := raceTwice(t, db, `SELECT 1 FROM inventory_slots WHERE character_id = 1 AND slot = 0 FOR UPDATE`, nil,
		func() error { return store.RemoveItem(ctx, 1, 0, 1) })
	ok := 0
	for _, err := range errs {
		if err == nil {
			ok++
		}
	}
	if ok != 1 {
		t.Fatalf("%d of two racing removals of one item succeeded (errors %v), want exactly 1", ok, errs)
	}
}

// TestSQLMoveItemRacedMergeConserves: two identical merges of slot 0 (2x)
// onto slot 1 (2x) of a stacking item. Before round 743 both read the source,
// both added its 2 to the target, and only one delete found the source: the
// stack came out 6 from 4.
func TestSQLMoveItemRacedMergeConserves(t *testing.T) {
	store := openTestSQLStore(t, stubMaxStacks{100: 50})
	ctx := context.Background()
	if err := store.PlaceItemInstance(ctx, 1, 0, 100, 2, Instance{Durability: -1}); err != nil {
		t.Fatalf("seeding slot 0: %v", err)
	}
	if err := store.PlaceItemInstance(ctx, 1, 1, 100, 2, Instance{Durability: -1}); err != nil {
		t.Fatalf("seeding slot 1: %v", err)
	}
	db := openRaceDB(t)
	raceTwice(t, db, `SELECT 1 FROM inventory_slots WHERE character_id = 1 AND slot = 1 FOR UPDATE`, nil,
		func() error { return store.MoveItem(ctx, 1, 0, 1) })
	list, err := store.List(ctx, 1)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	total := 0
	for _, s := range list {
		total += s.Quantity
	}
	if total != 4 {
		t.Fatalf("after two racing merges the bag holds %d of the item (%+v), want the 4 it started with", total, list)
	}
}

// TestSQLSplitItemRacedSplitsOnce: two identical splits of 5 into an empty
// slot. One must win; the other finds the slot taken. Nothing is created.
func TestSQLSplitItemRacedSplitsOnce(t *testing.T) {
	store := openTestSQLStore(t, stubMaxStacks{100: 50})
	ctx := context.Background()
	if err := store.PlaceItemInstance(ctx, 1, 0, 100, 5, Instance{Durability: -1}); err != nil {
		t.Fatalf("seeding: %v", err)
	}
	db := openRaceDB(t)
	errs := raceTwice(t, db, `SELECT 1 FROM inventory_slots WHERE character_id = 1 AND slot = 0 FOR UPDATE`, nil,
		func() error { return store.SplitItem(ctx, 1, 0, 3, 2) })
	list, err := store.List(ctx, 1)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	total := 0
	for _, s := range list {
		total += s.Quantity
	}
	if total != 5 || len(list) != 2 {
		t.Fatalf("after two racing splits: %+v (errors %v), want 3 + 2", list, errs)
	}
	if (errs[0] == nil) == (errs[1] == nil) {
		t.Fatalf("racing splits answered %v, want exactly one success", errs)
	}
}
