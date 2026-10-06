package shop

import (
	"context"
	"database/sql"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/testdb"
	"github.com/OpenSRO/OpenSRO/server/internal/txn"
)

// Round 743: every shop action is one transaction. These run on SQL stores
// sharing one pool, as cmd/server does, and race two identical requests.

type sqlShop struct {
	svc   *Service
	chars *character.SQLStore
	inv   *inventory.SQLStore
	db    *sql.DB
	id    int64
}

func newSQLShop(t *testing.T, items stubItems) *sqlShop {
	t.Helper()
	ctx := context.Background()
	db, err := txn.OpenPool(testDSN(), 8)
	if err != nil {
		t.Fatalf("OpenPool: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	chars, err := character.NewSQLStore(db)
	if err != nil {
		t.Fatalf("character store: %v", err)
	}
	inv, err := inventory.NewSQLStoreOwned(db, stubMaxStacksFor(items), inventory.DefaultTable, inventory.DefaultOwnerColumn)
	if err != nil {
		t.Fatalf("inventory store: %v", err)
	}
	if _, err := db.Exec(`TRUNCATE characters RESTART IDENTITY CASCADE; TRUNCATE inventory_slots; TRUNCATE economy_ops`); err != nil {
		t.Fatalf("truncating: %v", err)
	}
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating Aria: %v", err)
	}
	return &sqlShop{svc: &Service{Gold: chars, Inv: inv, Items: items}, chars: chars, inv: inv, db: db, id: c.ID}
}

func (f *sqlShop) gold(t *testing.T) int64 {
	t.Helper()
	c, err := f.chars.GetByID(context.Background(), f.id)
	if err != nil {
		t.Fatalf("GetByID: %v", err)
	}
	return c.Gold
}

func (f *sqlShop) held(t *testing.T, itemID int64) int {
	t.Helper()
	list, err := f.inv.List(context.Background(), f.id)
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

// race runs op twice at once while lockQuery's row is held, until both are
// blocked or done, and returns both errors.
func race(t *testing.T, db *sql.DB, lockQuery string, args []any, op func() error) [2]error {
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
		go func(i int) { defer wg.Done(); errs[i] = op() }(i)
	}
	go func() { wg.Wait(); close(done) }()
	if _, err := testdb.WaitLockWaiters(ctx, db, 2, done, 3*time.Second); err != nil {
		t.Fatal(err)
	}
	hold.Commit()
	<-done
	return errs
}

func successes(errs [2]error) int {
	n := 0
	for _, err := range errs {
		if err == nil {
			n++
		}
	}
	return n
}

// Two sales of the one sword: one sale, paid once.
func TestShopSellRacedSellsOnce(t *testing.T) {
	ctx := context.Background()
	f := newSQLShop(t, stubItems{100: {ID: 100, Price: 890, SellPrice: 427, CanSell: true}})
	if err := f.inv.AddItem(ctx, f.id, 100, 1); err != nil {
		t.Fatalf("seeding: %v", err)
	}
	errs := race(t, f.db, `SELECT 1 FROM inventory_slots WHERE character_id = $1 AND slot = 0 FOR UPDATE`, []any{f.id},
		func() error { _, err := f.svc.Sell(ctx, f.id, 0, 1); return err })
	if successes(errs) != 1 || f.gold(t) != character.StartingGold+427 || f.held(t, 100) != 0 {
		t.Fatalf("two racing sales: %v, gold %d, held %d; want one sale, %d gold, none held",
			errs, f.gold(t), f.held(t, 100), character.StartingGold+427)
	}
}

// Two purchases with the purse for one: one item, paid once.
func TestShopBuyRacedWithinThePurse(t *testing.T) {
	ctx := context.Background()
	f := newSQLShop(t, stubItems{100: {ID: 100, Price: 600}})
	errs := race(t, f.db, `SELECT 1 FROM characters WHERE id = $1 FOR UPDATE`, []any{f.id},
		func() error { return f.svc.Buy(ctx, f.id, 100, 1) })
	if successes(errs) != 1 || f.gold(t) != character.StartingGold-600 || f.held(t, 100) != 1 {
		t.Fatalf("two racing purchases: %v, gold %d, held %d", errs, f.gold(t), f.held(t, 100))
	}
	for _, err := range errs {
		if err != nil && !errors.Is(err, character.ErrInsufficientGold) {
			t.Fatalf("the refused purchase: %v, want ErrInsufficientGold", err)
		}
	}
}

// A purchase that does not fit costs nothing (no refund step: it rolls back).
func TestShopBuyWithNoRoomCostsNothing(t *testing.T) {
	ctx := context.Background()
	f := newSQLShop(t, stubItems{100: {ID: 100, Price: 600}, 200: {ID: 200}})
	f.inv.SetCapacity(1)
	if err := f.inv.AddItem(ctx, f.id, 200, 100); err != nil { // a full stack fills the one slot
		t.Fatalf("filling the bag: %v", err)
	}
	if err := f.svc.Buy(ctx, f.id, 100, 1); !errors.Is(err, inventory.ErrNoRoom) {
		t.Fatalf("Buy into a full bag: %v, want ErrNoRoom", err)
	}
	if f.gold(t) != character.StartingGold {
		t.Fatalf("a failed purchase cost %d gold", character.StartingGold-f.gold(t))
	}
}

// failingGold refuses every credit, as a lost connection would.
type failingGold struct{ *character.SQLStore }

func (failingGold) AddGold(context.Context, int64, int64) error {
	return errors.New("injected: the credit failed")
}

// A sale whose credit fails keeps the item: the take rolls back with it.
func TestShopSellFailedCreditKeepsTheItem(t *testing.T) {
	ctx := context.Background()
	f := newSQLShop(t, stubItems{100: {ID: 100, SellPrice: 427, CanSell: true}})
	if err := f.inv.AddItem(ctx, f.id, 100, 1); err != nil {
		t.Fatalf("seeding: %v", err)
	}
	svc := &Service{Gold: failingGold{f.chars}, Inv: f.inv, Items: f.svc.Items}
	if _, err := svc.Sell(ctx, f.id, 0, 1); err == nil {
		t.Fatal("the sale succeeded without its credit")
	}
	if f.held(t, 100) != 1 || f.gold(t) != character.StartingGold {
		t.Fatalf("a failed sale: held %d, gold %d; want the sword kept and the purse unchanged", f.held(t, 100), f.gold(t))
	}
}

// Two buy backs of the one booked sale: bought back once, paid once.
func TestShopBuybackRacedBuysBackOnce(t *testing.T) {
	ctx := context.Background()
	items := stubItems{100: {ID: 100, Price: 890, SellPrice: 427, CanSell: true, TypeID1: 3, TypeID2: 1, TypeID3: 6}}
	f := newSQLShop(t, items)
	if err := f.inv.AddItem(ctx, f.id, 100, 1); err != nil {
		t.Fatalf("seeding: %v", err)
	}
	if _, book, err := f.svc.SellBooked(ctx, f.id, 0, 1); err != nil || book != 1 {
		t.Fatalf("selling: book %d, %v", book, err)
	}
	afterSale := f.gold(t)
	var wg sync.WaitGroup
	var errs [2]error
	for i := range errs {
		wg.Add(1)
		go func(i int) { defer wg.Done(); _, errs[i] = f.svc.Buyback(ctx, f.id, 0) }(i)
	}
	wg.Wait()
	if successes(errs) != 1 || f.held(t, 100) != 1 || f.gold(t) != afterSale-427 {
		t.Fatalf("two racing buy backs: %v, held %d, gold %d (after the sale %d)", errs, f.held(t, 100), f.gold(t), afterSale)
	}
}

// A buy back that cannot be paid for leaves the book and the purse as they
// were.
func TestShopBuybackShortOfGoldChangesNothing(t *testing.T) {
	ctx := context.Background()
	f := newSQLShop(t, stubItems{100: {ID: 100, SellPrice: 427, CanSell: true, TypeID1: 3, TypeID2: 1, TypeID3: 6}})
	if err := f.inv.AddItem(ctx, f.id, 100, 1); err != nil {
		t.Fatalf("seeding: %v", err)
	}
	if _, err := f.svc.Sell(ctx, f.id, 0, 1); err != nil {
		t.Fatalf("selling: %v", err)
	}
	if err := f.chars.DeductGold(ctx, f.id, f.gold(t)); err != nil {
		t.Fatalf("emptying the purse: %v", err)
	}
	if _, err := f.svc.Buyback(ctx, f.id, 0); !errors.Is(err, character.ErrInsufficientGold) {
		t.Fatalf("Buyback: %v, want ErrInsufficientGold", err)
	}
	if f.held(t, 100) != 0 {
		t.Fatal("an unpaid buy back placed the item")
	}
	if err := f.chars.AddGold(ctx, f.id, 1000); err != nil {
		t.Fatal(err)
	}
	if _, err := f.svc.Buyback(ctx, f.id, 0); err != nil {
		t.Fatalf("the entry was lost from the book: %v", err)
	}
}
