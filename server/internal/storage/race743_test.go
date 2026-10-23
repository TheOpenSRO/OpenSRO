package storage

import (
	"context"
	"database/sql"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/testdb"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// Round 743: every warehouse action is one transaction. These run on SQL
// stores sharing one pool, as cmd/server does, and race identical requests.

type sqlWarehouse struct {
	svc       *Service
	chars     *character.SQLStore
	accounts  *account.SQLStore
	bag, wh   *inventory.SQLStore
	db        *sql.DB
	charID    int64
	accountID int64
}

type fees map[int64]int64

func (f fees) GetItem(_ context.Context, id int64) (*refdata.Item, error) {
	return &refdata.Item{ID: id, KeepingFee: f[id]}, nil
}

func newSQLWarehouse(t *testing.T) *sqlWarehouse {
	t.Helper()
	ctx := context.Background()
	db, err := txn.OpenPool(testDSN(), 8)
	if err != nil {
		t.Fatalf("OpenPool: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	accounts, err := account.NewSQLStore(db)
	if err != nil {
		t.Fatalf("account store: %v", err)
	}
	chars, err := character.NewSQLStore(db)
	if err != nil {
		t.Fatalf("character store: %v", err)
	}
	bag, err := inventory.NewSQLStoreOwned(db, generousStacks{}, inventory.DefaultTable, inventory.DefaultOwnerColumn)
	if err != nil {
		t.Fatalf("bag store: %v", err)
	}
	wh, err := inventory.NewSQLStoreOwned(db, generousStacks{}, inventory.WarehouseTable, inventory.WarehouseOwnerColumn)
	if err != nil {
		t.Fatalf("warehouse store: %v", err)
	}
	wh.SetCapacity(DefaultCapacity)
	wh.SetCapacityFunc(CapacityOf(accounts))
	if _, err := db.Exec(`TRUNCATE accounts RESTART IDENTITY CASCADE; TRUNCATE characters RESTART IDENTITY CASCADE;
		TRUNCATE inventory_slots; TRUNCATE account_storage_slots; TRUNCATE economy_ops`); err != nil {
		t.Fatalf("truncating: %v", err)
	}
	acc, err := accounts.Register(ctx, "player", "pw")
	if err != nil {
		t.Fatalf("Register: %v", err)
	}
	c, err := chars.Create(ctx, acc.ID, "Aria")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	return &sqlWarehouse{
		svc:   &Service{Bag: bag, Warehouse: wh, Gold: chars, Accounts: accounts, ChestSizes: accounts, Items: fees{100: 10}},
		chars: chars, accounts: accounts, bag: bag, wh: wh, db: db, charID: c.ID, accountID: acc.ID,
	}
}

func count(t *testing.T, st inventory.Store, owner, itemID int64) int {
	t.Helper()
	list, err := st.List(context.Background(), owner)
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

func (f *sqlWarehouse) purse(t *testing.T) int64 {
	t.Helper()
	c, err := f.chars.GetByID(context.Background(), f.charID)
	if err != nil {
		t.Fatalf("GetByID: %v", err)
	}
	return c.Gold
}

// raceTwice runs op twice at once while lockQuery's row is held, until both
// are blocked or done.
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

func oneOf(errs [2]error) bool { return (errs[0] == nil) != (errs[1] == nil) }

// Two deposits of the one sword: deposited once, the fee charged once, and
// it keeps its serial across the counter.
func TestDepositRacedDepositsOnce(t *testing.T) {
	ctx := context.Background()
	f := newSQLWarehouse(t)
	if err := f.bag.AddItem(ctx, f.charID, 100, 1); err != nil {
		t.Fatalf("seeding: %v", err)
	}
	var serial int64
	f.db.QueryRow(`SELECT serial FROM inventory_slots WHERE character_id = $1`, f.charID).Scan(&serial)
	errs := raceTwice(t, f.db, `SELECT 1 FROM inventory_slots WHERE character_id = $1 AND slot = 0 FOR UPDATE`, []any{f.charID},
		func() error { return f.svc.DepositStack(ctx, f.charID, 0, 0) })
	if !oneOf(errs) || count(t, f.bag, f.charID, 100) != 0 || count(t, f.wh, f.accountID, 100) != 1 || f.purse(t) != character.StartingGold-10 {
		t.Fatalf("two racing deposits: %v, bag %d, warehouse %d, purse %d", errs,
			count(t, f.bag, f.charID, 100), count(t, f.wh, f.accountID, 100), f.purse(t))
	}
	var moved int64
	f.db.QueryRow(`SELECT serial FROM account_storage_slots WHERE account_id = $1`, f.accountID).Scan(&moved)
	if moved != serial {
		t.Fatalf("the deposited sword is serial %d, want its own %d", moved, serial)
	}
}

// Two withdrawals of the one sword: withdrawn once.
func TestWithdrawRacedWithdrawsOnce(t *testing.T) {
	ctx := context.Background()
	f := newSQLWarehouse(t)
	if err := f.wh.AddItem(ctx, f.accountID, 100, 1); err != nil {
		t.Fatalf("seeding: %v", err)
	}
	errs := raceTwice(t, f.db, `SELECT 1 FROM account_storage_slots WHERE account_id = $1 AND slot = 0 FOR UPDATE`, []any{f.accountID},
		func() error { return f.svc.Withdraw(ctx, f.charID, 0, 1) })
	if !oneOf(errs) || count(t, f.bag, f.charID, 100) != 1 || count(t, f.wh, f.accountID, 100) != 0 {
		t.Fatalf("two racing withdrawals: %v, bag %d, warehouse %d", errs, count(t, f.bag, f.charID, 100), count(t, f.wh, f.accountID, 100))
	}
}

// Two gold deposits with the purse for one: moved once, nothing made.
func TestGoldDepositRacedWithinThePurse(t *testing.T) {
	ctx := context.Background()
	f := newSQLWarehouse(t)
	errs := raceTwice(t, f.db, `SELECT 1 FROM characters WHERE id = $1 FOR UPDATE`, []any{f.charID},
		func() error { _, err := f.svc.DepositGold(ctx, f.charID, 700); return err })
	stored, _ := f.accounts.StorageGold(ctx, f.accountID)
	if !oneOf(errs) || f.purse(t) != character.StartingGold-700 || stored != 700 {
		t.Fatalf("two racing gold deposits: %v, purse %d, stored %d", errs, f.purse(t), stored)
	}
}

// failingFee is the purse with the fee's debit refused: the purse emptied
// between the check and the charge.
type failingFee struct{ *character.SQLStore }

func (failingFee) DeductGold(context.Context, int64, int64) error {
	return character.ErrInsufficientGold
}

// A deposit whose fee cannot be taken rolls the move back -- no search for
// the item to put back.
func TestDepositUnpaidFeeRollsBack(t *testing.T) {
	ctx := context.Background()
	f := newSQLWarehouse(t)
	if err := f.bag.AddItem(ctx, f.charID, 100, 1); err != nil {
		t.Fatalf("seeding: %v", err)
	}
	f.svc.Gold = failingFee{f.chars}
	if err := f.svc.DepositStack(ctx, f.charID, 0, 0); !errors.Is(err, character.ErrInsufficientGold) {
		t.Fatalf("DepositStack: %v, want ErrInsufficientGold", err)
	}
	if count(t, f.bag, f.charID, 100) != 1 || count(t, f.wh, f.accountID, 100) != 0 {
		t.Fatal("an unpaid deposit moved the item")
	}
}

// failingStoredGold refuses the warehouse's credit.
type failingStoredGold struct{ *account.SQLStore }

func (failingStoredGold) AddStorageGold(context.Context, int64, int64) error {
	return errors.New("injected: the credit failed")
}

// A gold deposit whose credit fails leaves the purse whole.
func TestGoldDepositFailedCreditLosesNothing(t *testing.T) {
	ctx := context.Background()
	f := newSQLWarehouse(t)
	f.svc.Accounts = failingStoredGold{f.accounts}
	if _, err := f.svc.DepositGold(ctx, f.charID, 300); err == nil {
		t.Fatal("the deposit succeeded without its credit")
	}
	if f.purse(t) != character.StartingGold {
		t.Fatalf("a failed gold deposit took %d from the purse", character.StartingGold-f.purse(t))
	}
}
