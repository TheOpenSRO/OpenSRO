package equipment

import (
	"context"
	"database/sql"
	"sync"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/testdb"
)

// raceTwice runs op twice at once while lockQuery's row is held, until both
// are blocked on a lock or done, then lets them go.
func raceTwice(t *testing.T, lockQuery string, op func() error) [2]error {
	t.Helper()
	ctx := context.Background()
	db, err := sql.Open("pgx", testDSN())
	if err != nil {
		t.Fatalf("opening: %v", err)
	}
	defer db.Close()
	hold, err := testdb.HoldRow(ctx, db, lockQuery)
	if err != nil {
		t.Fatalf("holding the row: %v", err)
	}
	var errs [2]error
	var wg sync.WaitGroup
	done := make(chan struct{})
	for i := range errs {
		wg.Add(1)
		go func(i int) { defer wg.Done(); errs[i] = op() }(i)
	}
	go func() { wg.Wait(); close(done) }()
	n, err := testdb.WaitLockWaiters(ctx, db, 2, done, 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("racers blocked on a lock: %d", n)
	hold.Commit()
	<-done
	return errs
}

// TestSQLUnequipRacedReturnsOnce: two unequips of one worn sword. Before round
// 743 Unequip read the worn row, returned the item to the bag and deleted the
// row in separate commits, so both racers returned it: two swords from one.
func TestSQLUnequipRacedReturnsOnce(t *testing.T) {
	eq, inv := openTestStores(t)
	ctx := context.Background()
	if err := inv.AddItem(ctx, 1, 100, 1); err != nil {
		t.Fatalf("seeding: %v", err)
	}
	if err := eq.Equip(ctx, 1, SlotWeapon, 0); err != nil {
		t.Fatalf("Equip: %v", err)
	}
	errs := raceTwice(t, `SELECT 1 FROM equipment_slots WHERE character_id = 1 FOR UPDATE`,
		func() error { return eq.Unequip(ctx, 1, SlotWeapon) })
	list, err := inv.List(ctx, 1)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	worn, _ := eq.Get(ctx, 1)
	if len(list) != 1 || len(worn) != 0 {
		t.Fatalf("after two racing unequips (%v): bag %+v, worn %+v; want the one sword in the bag", errs, list, worn)
	}
}

// TestSQLEquipRacedEquipsOnce: two equips of one bag sword into the weapon
// slot: worn once, gone from the bag once.
func TestSQLEquipRacedEquipsOnce(t *testing.T) {
	eq, inv := openTestStores(t)
	ctx := context.Background()
	if err := inv.AddItem(ctx, 1, 100, 1); err != nil {
		t.Fatalf("seeding: %v", err)
	}
	errs := raceTwice(t, `SELECT 1 FROM inventory_slots WHERE character_id = 1 AND slot = 0 FOR UPDATE`,
		func() error { return eq.Equip(ctx, 1, SlotWeapon, 0) })
	list, _ := inv.List(ctx, 1)
	worn, _ := eq.Get(ctx, 1)
	if len(list) != 0 || len(worn) != 1 {
		t.Fatalf("after two racing equips (%v): bag %+v, worn %+v; want the sword worn", errs, list, worn)
	}
}
